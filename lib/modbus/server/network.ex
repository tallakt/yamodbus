defmodule Modbus.Server.Network do
  @moduledoc false
  # A server on TCP or TLS: an acceptor asks this process before it hands a client over, and each
  # client has a process of its own that reads its requests, answers them in turn, and notes in a
  # table when it last had one, so that a full server knows which connection to close. The table
  # also holds each client's address, so that one host can't push the others out.
  use GenServer

  alias Modbus.{Security, TCP}
  alias Modbus.Server.Request

  # Listens in the caller, so that a port that's taken is an error returned rather than an exit
  # (which OTP would log), then hands the socket to the server.
  def start_link(config, name) do
    inet = if tuple_size(config.address) == 8, do: [:inet6], else: []

    options =
      inet ++
        [
          :binary,
          ip: config.address,
          packet: :raw,
          active: false,
          reuseaddr: true,
          nodelay: true,
          keepalive: true,
          send_timeout: 5000,
          send_timeout_close: true,
          backlog: 128
        ]

    listening =
      case config.transport do
        :tcp -> :gen_tcp.listen(config.port, options)
        :tls -> :ssl.listen(config.port, options ++ config.ssl)
      end

    with {:ok, socket} <- listening do
      {:ok, server} = GenServer.start_link(__MODULE__, Map.put(config, :socket, socket), name)
      owner = if config.transport == :tcp, do: :gen_tcp, else: :ssl
      :ok = owner.controlling_process(socket, server)
      {:ok, server}
    end
  end

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    server = self()
    table = :ets.new(__MODULE__, [:public, :set, write_concurrency: true])
    acceptor = spawn_link(fn -> accept(server, config.transport, config.socket, config.allow) end)
    {:ok, Map.merge(config, %{acceptor: acceptor, table: table, clients: %{}})}
  end

  @impl true
  def handle_call(:port, _from, s) do
    {:ok, {_address, port}} =
      case s.transport do
        :tcp -> :inet.sockname(s.socket)
        :tls -> :ssl.sockname(s.socket)
      end

    {:reply, port, s}
  end

  # A server that's full makes room for a new client by closing a connection; see victim/2.
  def handle_call({:admit, address}, _from, s) do
    s = if map_size(s.clients) >= s.connections, do: evict(s, address), else: s

    connection =
      Map.take(s, [
        :transport,
        :handler,
        :authorize,
        :identification,
        :idle,
        :table,
        :handler_timeout
      ])

    connection = Map.put(connection, :handshake_timeout, s.handshake_timeout)
    pid = spawn_link(fn -> connection(connection) end)
    :ets.insert(s.table, {pid, now(), address})
    {:reply, {:ok, pid}, %{s | clients: Map.put(s.clients, pid, true)}}
  end

  @impl true
  def handle_info({:EXIT, acceptor, reason}, %{acceptor: acceptor} = s), do: {:stop, reason, s}

  def handle_info({:EXIT, pid, _reason}, s) do
    :ets.delete(s.table, pid)
    {:noreply, %{s | clients: Map.delete(s.clients, pid)}}
  end

  def handle_info(_message, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s) do
    _ =
      case s.transport do
        :tcp -> :gen_tcp.close(s.socket)
        :tls -> :ssl.close(s.socket)
      end

    for pid <- Map.keys(s.clients), do: Process.exit(pid, :kill)
  end

  defp evict(s, address) do
    case s.clients |> Map.keys() |> Enum.flat_map(&:ets.lookup(s.table, &1)) do
      [] ->
        s

      rows ->
        pid = victim(rows, address)
        Process.exit(pid, :kill)
        :ets.delete(s.table, pid)
        %{s | clients: Map.delete(s.clients, pid)}
    end
  end

  @doc false
  # The connection to close for a new client from `address`, of the rows {pid, last request,
  # address}: the one that has gone longest without a request, as the TCP guide recommends, of the
  # address that holds the most connections, counting the new one. On a tie, the new client's own
  # address loses one first. A host that connects again and again only pushes out its own
  # connections, never those of other hosts.
  def victim(rows, address) do
    groups = Enum.group_by(rows, &elem(&1, 2))
    held = fn {from, group} -> length(group) + if(from == address, do: 1, else: 0) end
    most = groups |> Enum.map(held) |> Enum.max()
    tied = Enum.filter(groups, &(held.(&1) == most))

    {_from, group} =
      Enum.find(tied, fn {from, _group} -> from == address end) ||
        Enum.min_by(tied, fn {_from, group} -> group |> Enum.map(&elem(&1, 1)) |> Enum.min() end)

    group |> Enum.min_by(&elem(&1, 1)) |> elem(0)
  end

  @doc false
  # Whether a client's address is among those allowed, each an address or {address, prefix length}.
  # An IPv4 client of an IPv6 server is taken as its IPv4 address.
  def allowed?(_address, nil), do: true

  def allowed?(address, allow) do
    address = plain(address)

    Enum.any?(allow, fn
      {net, bits} -> same_net?(address, net, bits)
      net -> same_net?(address, net, tuple_size(net) * if(tuple_size(net) == 4, do: 8, else: 16))
    end)
  end

  defp plain({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: {div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)}

  defp plain(address), do: address

  defp same_net?(address, net, bits) when tuple_size(address) == tuple_size(net) do
    width = if tuple_size(net) == 4, do: 32, else: 128
    shift = width - bits
    Bitwise.bsr(number(address), shift) == Bitwise.bsr(number(net), shift)
  end

  defp same_net?(_address, _net, _bits), do: false

  defp number(address) do
    size = if tuple_size(address) == 4, do: 8, else: 16

    address
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, number -> Bitwise.bor(Bitwise.bsl(number, size), part) end)
  end

  defp accept(server, transport, socket, allow) do
    accepted =
      case transport do
        :tcp -> :gen_tcp.accept(socket)
        :tls -> :ssl.transport_accept(socket)
      end

    case accepted do
      {:ok, client} ->
        hand_over(server, transport, client, allow)
        accept(server, transport, socket, allow)

      {:error, :closed} ->
        exit(:normal)

      # Out of file descriptors or memory: the clients already connected keep their connections,
      # and an accept a moment later may do better.
      {:error, reason} when reason in [:emfile, :enfile, :enobufs, :enomem, :system_limit] ->
        Process.sleep(10)
        accept(server, transport, socket, allow)

      # A client gone before it was accepted, as one that resets its connection at once
      # (:einval on macOS, :econnaborted elsewhere): on to the next, without a pause a flood of
      # them could turn into a wait for everyone else.
      {:error, _reason} ->
        accept(server, transport, socket, allow)
    end
  end

  # A client from an address that isn't allowed is closed before it takes a place.
  defp hand_over(server, transport, client, allow) do
    {owner, peername} =
      if transport == :tcp, do: {:gen_tcp, &:inet.peername/1}, else: {:ssl, &:ssl.peername/1}

    with {:ok, {address, _port}} <- peername.(client),
         true <- allowed?(address, allow),
         {:ok, pid} <- GenServer.call(server, {:admit, address}, :infinity),
         :ok <- owner.controlling_process(client, pid) do
      send(pid, {:socket, client})
    else
      _gone_not_allowed_or_failed -> owner.close(client)
    end
  end

  defp connection(c) do
    receive do
      {:socket, socket} ->
        case handshake(c, socket) do
          {:ok, socket, role} ->
            loop(Map.merge(c, %{socket: socket, role: role}), <<>>, deadline(c))

          :error ->
            :ok
        end
    after
      5000 -> :ok
    end
  end

  defp handshake(%{transport: :tcp}, socket), do: {:ok, socket, nil}

  defp handshake(%{transport: :tls} = c, socket) do
    case :ssl.handshake(socket, c.handshake_timeout) do
      {:ok, socket} ->
        {:ok, socket, Security.role(socket)}

      {:error, _reason} ->
        _ = :ssl.close(socket)
        :error
    end
  end

  defp loop(c, buffer, deadline) do
    socket = c.socket

    case setopts(c, active: :once) do
      :ok ->
        receive do
          {:tcp, ^socket, data} -> more(c, buffer <> data, deadline)
          {:ssl, ^socket, data} -> more(c, buffer <> data, deadline)
          {:tcp_closed, ^socket} -> :ok
          {:ssl_closed, ^socket} -> :ok
          {:tcp_error, ^socket, _reason} -> close(c)
          {:ssl_error, ^socket, _reason} -> close(c)
        after
          wait(deadline) -> close(c)
        end

      {:error, _reason} ->
        close(c)
    end
  end

  defp more(c, buffer, deadline) do
    case frames(c, buffer, deadline) do
      {:ok, rest, deadline} -> loop(c, rest, deadline)
      :close -> close(c)
    end
  end

  # Every whole frame in the buffer is answered in turn. A header that can't be Modbus's leaves no
  # telling where the next frame starts, so it closes the connection.
  defp frames(c, buffer, deadline) do
    case TCP.decode(buffer) do
      {:ok, {transaction, unit, pdu}, rest} ->
        :ets.update_element(c.table, self(), {2, now()})

        response =
          case Request.decode(pdu) do
            {:ok, request} -> Request.respond(c, c.role, unit, request)
            {:error, response} -> response
          end

        case send_frame(c, TCP.encode(transaction, unit, response)) do
          :ok -> frames(c, rest, deadline(c))
          {:error, _reason} -> :close
        end

      {:discard, rest} ->
        frames(c, rest, deadline)

      :more ->
        {:ok, buffer, deadline}

      {:error, :invalid_length} ->
        :close
    end
  end

  defp deadline(%{idle: :infinity}), do: :infinity
  defp deadline(%{idle: idle}), do: now() + idle

  defp wait(:infinity), do: :infinity
  defp wait(deadline), do: max(deadline - now(), 0)

  defp send_frame(%{transport: :tcp, socket: socket}, frame), do: :gen_tcp.send(socket, frame)
  defp send_frame(%{transport: :tls, socket: socket}, frame), do: :ssl.send(socket, frame)

  defp setopts(%{transport: :tcp, socket: socket}, opts), do: :inet.setopts(socket, opts)
  defp setopts(%{transport: :tls, socket: socket}, opts), do: :ssl.setopts(socket, opts)

  defp close(%{transport: :tcp, socket: socket}), do: :gen_tcp.close(socket)
  defp close(%{transport: :tls, socket: socket}), do: :ssl.close(socket)

  defp now, do: System.monotonic_time(:millisecond)
end
