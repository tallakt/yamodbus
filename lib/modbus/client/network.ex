defmodule Modbus.Client.Network do
  @moduledoc false
  # A client over TCP or TLS: up to `max_pending` requests on the way, each under a transaction id
  # of its own, given out in turn so that a late answer can't be taken for a newer request's.
  use GenServer

  alias Modbus.{PDU, TCP}

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    s =
      Map.merge(config, %{
        socket: nil,
        connector: nil,
        status: :connecting,
        buffer: <<>>,
        next: 0,
        pending: %{},
        queue: :queue.new(),
        heard: now(),
        silent: nil,
        delay: elem(config.backoff, 0)
      })

    {:ok, connect(s)}
  end

  @impl true
  def handle_call({:request, unit, request, pdu, timeout}, from, s),
    do: {:noreply, submit(s, entry(unit, request, pdu, timeout, {:call, from}, s))}

  def handle_call(:status, _from, s), do: {:reply, s.status, s}

  @impl true
  def handle_cast({:request, unit, request, pdu, timeout, to, ref}, s),
    do: {:noreply, submit(s, entry(unit, request, pdu, timeout, {:send, to, ref}, s))}

  @impl true
  def handle_info({:connected, connector, socket}, %{connector: connector} = s) do
    s = %{s | socket: socket, connector: nil, status: :connected, buffer: <<>>, heard: now()}

    case setopts(s, active: :once) do
      :ok -> {:noreply, flush(s)}
      {:error, reason} -> {:noreply, drop(s, reason)}
    end
  end

  def handle_info({:connect_failed, connector, reason}, %{connector: connector} = s),
    do: {:noreply, drop(%{s | connector: nil}, reason)}

  def handle_info(:reconnect, %{status: {:disconnected, _}} = s), do: {:noreply, connect(s)}

  def handle_info({protocol, socket, data}, %{socket: socket} = s) when protocol in [:tcp, :ssl],
    do: {:noreply, frames(%{s | buffer: s.buffer <> data})}

  def handle_info({closed, socket}, %{socket: socket} = s)
      when closed in [:tcp_closed, :ssl_closed],
      do: {:noreply, drop(s, :closed)}

  def handle_info({error, socket, reason}, %{socket: socket} = s)
      when error in [:tcp_error, :ssl_error],
      do: {:noreply, drop(s, reason)}

  def handle_info({:expire, id}, s), do: {:noreply, expire(s, id)}

  def handle_info({:EXIT, connector, reason}, %{connector: connector} = s) when reason != :normal,
    do: {:noreply, drop(%{s | connector: nil}, reason)}

  def handle_info(_message, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s) do
    if s.connector, do: Process.exit(s.connector, :kill)
    if s.socket, do: close(s)
  end

  defp entry(unit, request, pdu, timeout, reply, s) do
    %{
      id: make_ref(),
      unit: unit,
      request: request,
      pdu: pdu,
      timeout: timeout || s.timeout,
      reply: reply,
      timer: nil,
      sent: nil
    }
  end

  defp submit(%{status: {:disconnected, _}} = s, entry) do
    reply(entry, {:error, :closed})
    s
  end

  defp submit(s, entry) do
    timer = Process.send_after(self(), {:expire, entry.id}, entry.timeout)
    flush(%{s | queue: :queue.in(%{entry | timer: timer}, s.queue)})
  end

  # Sends what waits, as far as max_pending allows.
  defp flush(%{status: :connected} = s) when map_size(s.pending) < s.max_pending do
    case :queue.out(s.queue) do
      {{:value, entry}, queue} ->
        {transaction, next} = transaction(s.next, s.pending)

        case send_frame(s, TCP.encode(transaction, entry.unit, entry.pdu)) do
          :ok ->
            pending = Map.put(s.pending, transaction, %{entry | sent: now()})
            flush(%{s | queue: queue, pending: pending, next: next})

          {:error, reason} ->
            drop(%{s | queue: :queue.in_r(entry, queue)}, reason)
        end

      {:empty, _queue} ->
        s
    end
  end

  defp flush(s), do: s

  defp transaction(id, pending) do
    next = rem(id + 1, 65536)
    if Map.has_key?(pending, id), do: transaction(next, pending), else: {id, next}
  end

  defp frames(s) do
    case TCP.decode(s.buffer) do
      # Only a whole frame shows the device is there: a trickle of bytes doesn't keep a dead
      # connection open.
      {:ok, {transaction, unit, pdu}, rest} ->
        frames(answer(%{s | buffer: rest, heard: now()}, transaction, unit, pdu))

      {:discard, rest} ->
        frames(%{s | buffer: rest, heard: now()})

      :more ->
        case setopts(s, active: :once) do
          :ok -> flush(s)
          {:error, reason} -> drop(s, reason)
        end

      {:error, :invalid_length} ->
        drop(s, :invalid_frame)
    end
  end

  # The transaction id matches an answer to its request, and the server copies the unit id back
  # from the request, as the MBAP header has it: an answer from another unit, such as a gateway
  # mixing up its devices' answers, doesn't fit, unless check_unit: false for a device that doesn't
  # copy it.
  defp answer(s, transaction, unit, pdu) do
    case Map.pop(s.pending, transaction) do
      {nil, _pending} ->
        s

      {entry, pending} ->
        _ = Process.cancel_timer(entry.timer)

        result =
          if unit == entry.unit or not s.check_unit,
            do: PDU.decode_response(entry.request, pdu),
            else: {:error, {:invalid_response, pdu}}

        reply(entry, result)
        %{s | pending: pending, delay: elem(s.backoff, 0)}
    end
  end

  defp expire(s, id) do
    case Enum.find(s.pending, fn {_transaction, entry} -> entry.id == id end) do
      {transaction, entry} ->
        reply(entry, {:error, :timeout})
        s = %{s | pending: Map.delete(s.pending, transaction)}

        # Two requests in a row timed out with nothing at all heard since the first went out: the
        # connection is dead, though TCP may not know it yet. One alone may be a slow device, whose
        # late answer then shows it's there.
        cond do
          s.heard >= entry.sent -> flush(s)
          s.silent != nil and s.heard < s.silent -> drop(s, :timeout)
          true -> flush(%{s | silent: entry.sent})
        end

      nil ->
        {expired, queue} = split_queue(s.queue, id)
        Enum.each(expired, &reply(&1, {:error, :timeout}))
        %{s | queue: queue}
    end
  end

  defp split_queue(queue, id) do
    {expired, kept} = queue |> :queue.to_list() |> Enum.split_with(&(&1.id == id))
    {expired, :queue.from_list(kept)}
  end

  # Fails everything waiting and connects again after the backoff delay.
  defp drop(s, reason) do
    _ = if s.socket, do: close(s)

    for {_transaction, entry} <- s.pending, do: fail(entry)
    for entry <- :queue.to_list(s.queue), do: fail(entry)

    {_first, longest} = s.backoff
    Process.send_after(self(), :reconnect, s.delay)

    %{
      s
      | socket: nil,
        silent: nil,
        status: {:disconnected, reason},
        buffer: <<>>,
        pending: %{},
        queue: :queue.new(),
        delay: min(s.delay * 2, longest)
    }
  end

  defp fail(entry) do
    _ = Process.cancel_timer(entry.timer)
    reply(entry, {:error, :closed})
  end

  defp reply(%{reply: {:call, from}}, result), do: GenServer.reply(from, result)
  defp reply(%{reply: {:send, to, ref}}, result), do: send(to, {Modbus.Client, ref, result})

  # Connecting takes up to connect_timeout, so a process of its own does it while the client goes on
  # taking requests.
  defp connect(s) do
    client = self()
    %{transport: transport, host: host, port: port, connect_timeout: timeout, ssl: ssl} = s
    connector = spawn_link(fn -> connector(client, transport, host, port, timeout, ssl) end)
    %{s | connector: connector, status: :connecting}
  end

  defp connector(client, transport, host, port, timeout, ssl) do
    options = [
      :binary,
      packet: :raw,
      active: false,
      nodelay: true,
      keepalive: true,
      # A frame or a few, far less than the socket's buffer, unless the server stopped reading
      # long ago: a send that blocks for a second means the connection is gone.
      send_timeout: 1000,
      send_timeout_close: true
    ]

    result =
      case transport do
        :tcp -> :gen_tcp.connect(host, port, options, timeout)
        :tls -> :ssl.connect(host, port, options ++ ssl, timeout)
      end

    case result do
      {:ok, socket} ->
        owner = if transport == :tcp, do: :gen_tcp, else: :ssl

        case owner.controlling_process(socket, client) do
          :ok -> send(client, {:connected, self(), socket})
          {:error, _reason} -> owner.close(socket)
        end

      {:error, reason} ->
        send(client, {:connect_failed, self(), reason})
    end
  end

  defp send_frame(%{transport: :tcp, socket: socket}, frame), do: :gen_tcp.send(socket, frame)
  defp send_frame(%{transport: :tls, socket: socket}, frame), do: :ssl.send(socket, frame)

  defp setopts(%{transport: :tcp, socket: socket}, opts), do: :inet.setopts(socket, opts)
  defp setopts(%{transport: :tls, socket: socket}, opts), do: :ssl.setopts(socket, opts)

  defp close(%{transport: :tcp, socket: socket}), do: :gen_tcp.close(socket)
  defp close(%{transport: :tls, socket: socket}), do: :ssl.close(socket)

  defp now, do: System.monotonic_time()
end
