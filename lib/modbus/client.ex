defmodule Modbus.Client do
  @moduledoc """
  A connection to a Modbus device, over TCP, TLS, or a serial line in RTU or ASCII.

      iex> {:ok, memory} = Modbus.Memory.start_link()
      iex> {:ok, server} = Modbus.Server.start_link(port: 0, handler: {Modbus.Memory, memory})
      iex> {:ok, client} = Modbus.Client.start_link(tcp: "127.0.0.1", port: Modbus.Server.port(server))
      iex> Modbus.Client.write_multiple_registers(client, 1, 100, [1500, 7])
      :ok
      iex> Modbus.Client.read_holding_registers(client, 1, 100, 2)
      {:ok, [1500, 7]}
      iex> Modbus.Client.read_coils(client, 1, 70_000, 1)
      ** (ArgumentError) an address is 0 to 65535, got: 70000

  `start_link/1` returns at once, and the client connects in the background: a request made while
  it's connecting waits for the connection. Every request gets its answer within its timeout, as a
  value: the client never exits the caller, and it never logs. The results and errors are those
  listed in `Modbus`.

  ## Many requests at once

  Over TCP, up to `:max_pending` requests are on the way at once, matched to their answers by
  transaction id; more wait in the client, within their own timeouts. Callers may share a client,
  and `send_request/4` lets one process have many requests out:

      ref1 = Modbus.Client.send_request(client, 1, {:read_holding_registers, 0, 100})
      ref2 = Modbus.Client.send_request(client, 1, {:read_coils, 0, 16})
      # the caller then gets
      {Modbus.Client, ^ref1, {:ok, registers}}
      {Modbus.Client, ^ref2, {:ok, coils}}

  An answer must fit its request, coming from the unit asked, or the result is
  `{:error, {:invalid_response, pdu}}`: an answer meant for one request is never taken for another's. An answer that comes after its request timed
  out is dropped.

  A serial line carries one request at a time, so there they wait their turn.

  ## Connections

  The client reconnects by itself when the connection drops, after 100 ms at first and up to 5
  seconds between attempts (`:backoff`). While it's down, requests fail at once with
  `{:error, :closed}`, and `status/1` says why. Two requests in a row that time out with nothing at
  all heard from the device since the first was sent mean the connection is dead, as one that a
  rebooted device or a broken cable left half open, and the client reconnects. A device that's only
  slow, its answers coming after their timeouts, keeps its connection.

  ## Serial lines

  RTU and ASCII need [circuits_uart](https://hex.pm/packages/circuits_uart) among the application's
  dependencies:

      {:circuits_uart, "~> 1.5"}

  Unit 0 broadcasts a write to every device on the line: nothing answers, and the result is `:ok`
  once the turnaround delay has passed. Units 248 to 255 are reserved there.

  ## Options

    * `:tcp`, `:tls`, `:rtu` or `:ascii` - the host (a name, or an address as a string or tuple), or
      the serial device, such as `"/dev/ttyUSB0"` (one of them is required)
    * `:port` - 502, or 802 for TLS
    * `:timeout` - how long a request may take, in ms, waiting its turn included (default 1000)
    * `:max_pending` - how many requests may be on the way at once over TCP or TLS (default 4)
    * `:check_unit` - over TCP or TLS, whether an answer must come from the unit asked, as the spec
      has it, since a server copies the unit id back (default true); `false` for a device that
      doesn't, whose answers are then matched by transaction id alone. A serial line always checks
      it, as it's what the devices on the line are told apart by
    * `:connect_timeout` - in ms (default 5000)
    * `:backoff` - `{first, longest}` wait between attempts to connect, in ms (default `{100, 5000}`)
    * `:ssl` - for TLS, options for `:ssl.connect/3`, such as `certfile:`, `keyfile:` and
      `cacertfile:`; see "Security" below
    * `:speed` (19200), `:data_bits` (8, or 7 for ASCII), `:parity` (`:even`, `:odd` or `:none`)
      and `:stop_bits` (1) - for serial lines; with no parity the spec asks for 2 stop bits
    * `:turnaround` - how long a broadcast leaves the devices to act on it, in ms (default 100)
    * `:echo` - `true` for a serial adapter that echoes what it sends, as some RS-485 adapters do:
      the client passes over the echo, which for a write is the same bytes as the device's answer
      and would otherwise pass for it
    * `:silence` - on an RTU line, the quiet that ends a frame whose length its function code
      doesn't tell, as a custom one, in ms (default 20, or more at speeds where 3.5 characters take
      longer)
    * `:name` - to register the process

  ## Security

  `tls:` is Modbus/TCP Security: the frames of Modbus TCP inside TLS 1.2 or later, where client and
  server each prove who they are by certificate. The client checks the server's certificate against
  `:cacerts` or `:cacertfile` in `:ssl`, and needs a certificate of its own (`:certfile` or `:cert`,
  with its key). That certificate may carry the client's role, which the server uses to decide what
  it may do (see `Modbus.Server`).

      Modbus.Client.start_link(tls: "10.0.0.5",
        ssl: [certfile: "client.pem", keyfile: "client.key", cacertfile: "plant-ca.pem"])

  The other TLS options pass through to `:ssl`; by default only TLS 1.2 and 1.3 are offered, and no
  cipher suite that relies on SHA-1, as the spec asks.
  """

  alias Modbus.PDU

  @backoff {100, 5_000}

  @doc false
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Starts a client, linked to the caller, with the options above. It returns at once, and connects in
  the background. Raises `ArgumentError` for options that don't make sense.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    {module, config} = config!(opts)
    name = if opts[:name], do: [name: opts[:name]], else: []
    GenServer.start_link(module, config, name)
  end

  @doc """
  Sends a request to unit `unit` and waits for its result; see `Modbus` for both. `timeout:` in
  `opts` overrides the client's for this request.

      Modbus.Client.request(client, 1, {:read_input_registers, 0, 10}, timeout: 500)
  """
  @spec request(GenServer.server(), Modbus.unit(), Modbus.request(), keyword) :: Modbus.result()
  def request(client, unit, request, opts \\ []) do
    {pdu, timeout} = prepare!(unit, request, opts)

    try do
      GenServer.call(client, {:request, unit, request, pdu, timeout}, call_timeout(timeout))
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, _reason -> {:error, :closed}
    end
  end

  @doc """
  Sends a request without waiting for it, and returns a reference. The result comes as a message to
  the caller, or to the process `to:` in `opts`:

      {Modbus.Client, ref, result}

  It comes within the timeout, unless the client itself stops; monitor the client to hear of that.
  """
  @spec send_request(GenServer.server(), Modbus.unit(), Modbus.request(), keyword) :: reference
  def send_request(client, unit, request, opts \\ []) do
    {pdu, timeout} = prepare!(unit, request, opts)
    ref = make_ref()
    to = Keyword.get(opts, :to, self())
    GenServer.cast(client, {:request, unit, request, pdu, timeout, to, ref})
    ref
  end

  @doc """
  Whether the client is connected: `:connected`, `:connecting`, or `{:disconnected, reason}` with
  the reason it last couldn't connect or lost its connection, such as `:econnrefused`. A serial
  client is connected while its port is open.
  """
  @spec status(GenServer.server()) :: :connected | :connecting | {:disconnected, term}
  def status(client), do: GenServer.call(client, :status)

  @doc "Closes the connection and stops the client."
  @spec stop(GenServer.server()) :: :ok
  def stop(client), do: GenServer.stop(client)

  @doc "Reads `count` coils from `address`, 1 to 2000 of them."
  @spec read_coils(GenServer.server(), Modbus.unit(), Modbus.address(), pos_integer, keyword) ::
          {:ok, [boolean]} | {:error, Modbus.error()}
  def read_coils(client, unit, address, count, opts \\ []),
    do: request(client, unit, {:read_coils, address, count}, opts)

  @doc "Reads `count` discrete inputs from `address`, 1 to 2000 of them."
  @spec read_discrete_inputs(
          GenServer.server(),
          Modbus.unit(),
          Modbus.address(),
          pos_integer,
          keyword
        ) ::
          {:ok, [boolean]} | {:error, Modbus.error()}
  def read_discrete_inputs(client, unit, address, count, opts \\ []),
    do: request(client, unit, {:read_discrete_inputs, address, count}, opts)

  @doc "Reads `count` holding registers from `address`, 1 to 125 of them."
  @spec read_holding_registers(
          GenServer.server(),
          Modbus.unit(),
          Modbus.address(),
          pos_integer,
          keyword
        ) ::
          {:ok, [Modbus.word()]} | {:error, Modbus.error()}
  def read_holding_registers(client, unit, address, count, opts \\ []),
    do: request(client, unit, {:read_holding_registers, address, count}, opts)

  @doc "Reads `count` input registers from `address`, 1 to 125 of them."
  @spec read_input_registers(
          GenServer.server(),
          Modbus.unit(),
          Modbus.address(),
          pos_integer,
          keyword
        ) ::
          {:ok, [Modbus.word()]} | {:error, Modbus.error()}
  def read_input_registers(client, unit, address, count, opts \\ []),
    do: request(client, unit, {:read_input_registers, address, count}, opts)

  @doc "Turns one coil on or off."
  @spec write_single_coil(GenServer.server(), Modbus.unit(), Modbus.address(), boolean, keyword) ::
          :ok | {:error, Modbus.error()}
  def write_single_coil(client, unit, address, value, opts \\ []),
    do: request(client, unit, {:write_single_coil, address, value}, opts)

  @doc "Writes one holding register."
  @spec write_single_register(
          GenServer.server(),
          Modbus.unit(),
          Modbus.address(),
          Modbus.word(),
          keyword
        ) ::
          :ok | {:error, Modbus.error()}
  def write_single_register(client, unit, address, value, opts \\ []),
    do: request(client, unit, {:write_single_register, address, value}, opts)

  @doc "Writes coils from `address`, 1 to 1968 of them."
  @spec write_multiple_coils(
          GenServer.server(),
          Modbus.unit(),
          Modbus.address(),
          [boolean],
          keyword
        ) ::
          :ok | {:error, Modbus.error()}
  def write_multiple_coils(client, unit, address, values, opts \\ []),
    do: request(client, unit, {:write_multiple_coils, address, values}, opts)

  @doc "Writes holding registers from `address`, 1 to 123 of them."
  @spec write_multiple_registers(
          GenServer.server(),
          Modbus.unit(),
          Modbus.address(),
          [Modbus.word()],
          keyword
        ) ::
          :ok | {:error, Modbus.error()}
  def write_multiple_registers(client, unit, address, values, opts \\ []),
    do: request(client, unit, {:write_multiple_registers, address, values}, opts)

  @doc """
  Changes some bits of a holding register and leaves the rest: the register becomes
  `(current AND and_mask) OR (or_mask AND NOT and_mask)`.
  """
  @spec mask_write_register(
          GenServer.server(),
          Modbus.unit(),
          Modbus.address(),
          Modbus.word(),
          Modbus.word(),
          keyword
        ) ::
          :ok | {:error, Modbus.error()}
  def mask_write_register(client, unit, address, and_mask, or_mask, opts \\ []),
    do: request(client, unit, {:mask_write_register, address, and_mask, or_mask}, opts)

  @doc """
  Writes holding registers from `write`, 1 to 121 of them, then reads `count` from `read`, in one
  request.
  """
  @spec read_write_multiple_registers(
          GenServer.server(),
          Modbus.unit(),
          Modbus.address(),
          pos_integer,
          Modbus.address(),
          [Modbus.word()],
          keyword
        ) ::
          {:ok, [Modbus.word()]} | {:error, Modbus.error()}
  def read_write_multiple_registers(client, unit, read, count, write, values, opts \\ []),
    do: request(client, unit, {:read_write_multiple_registers, read, count, write, values}, opts)

  @doc "Reads the FIFO queue whose count is in the register at `address`, up to 31 values."
  @spec read_fifo_queue(GenServer.server(), Modbus.unit(), Modbus.address(), keyword) ::
          {:ok, [Modbus.word()]} | {:error, Modbus.error()}
  def read_fifo_queue(client, unit, address, opts \\ []),
    do: request(client, unit, {:read_fifo_queue, address}, opts)

  @doc """
  Reads groups of file records, each `{file, record, count}`, and gives a list of registers for
  each group.
  """
  @spec read_file_record(
          GenServer.server(),
          Modbus.unit(),
          [{pos_integer, non_neg_integer, pos_integer}],
          keyword
        ) ::
          {:ok, [[Modbus.word()]]} | {:error, Modbus.error()}
  def read_file_record(client, unit, groups, opts \\ []),
    do: request(client, unit, {:read_file_record, groups}, opts)

  @doc "Writes groups of file records, each `{file, record, [word]}`."
  @spec write_file_record(
          GenServer.server(),
          Modbus.unit(),
          [{pos_integer, non_neg_integer, [Modbus.word()]}],
          keyword
        ) ::
          :ok | {:error, Modbus.error()}
  def write_file_record(client, unit, groups, opts \\ []),
    do: request(client, unit, {:write_file_record, groups}, opts)

  @doc """
  Reads the identification of a device, all of a category, `:basic` (the default), `:regular` or
  `:extended`, as a map of object ids to their values. It asks as many times as it takes, as the
  device says more follows. A device that has less than the category asked for gives what it has.

      {:ok, %{0 => "Acme", 1 => "PD-100", 2 => "2.11"}} =
        Modbus.Client.read_device_identification(client, 1)

  The objects of the basic category are 0, the vendor name; 1, the product code; and 2, the major
  and minor revision.
  """
  @spec read_device_identification(
          GenServer.server(),
          Modbus.unit(),
          :basic | :regular | :extended,
          keyword
        ) ::
          {:ok, %{byte => binary}} | {:error, Modbus.error()}
  def read_device_identification(client, unit, category \\ :basic, opts \\ [])
      when category in [:basic, :regular, :extended],
      do: identification(client, unit, category, opts, 0, %{}, 0)

  # A device that keeps saying more follows, going in circles, is stopped after 256 requests.
  defp identification(_client, _unit, _category, _opts, _from, _objects, 256),
    do: {:error, {:invalid_response, <<>>}}

  defp identification(client, unit, category, opts, from, objects, asked) do
    case request(client, unit, {:read_device_identification, category, from}, opts) do
      {:ok, %{objects: new} = answer} ->
        objects = Enum.into(new, objects)

        if answer.more_follows and answer.next_object_id > from,
          do:
            identification(
              client,
              unit,
              category,
              opts,
              answer.next_object_id,
              objects,
              asked + 1
            ),
          else: {:ok, objects}

      error ->
        error
    end
  end

  defp prepare!(unit, request, opts) do
    if not (is_integer(unit) and unit in 0..255),
      do: raise(ArgumentError, "a unit id is 0 to 255, got: #{inspect(unit)}")

    timeout = Keyword.get(opts, :timeout)

    if timeout != nil and not (is_integer(timeout) and timeout > 0),
      do:
        raise(ArgumentError, "timeout: must be a positive number of ms, got: #{inspect(timeout)}")

    {PDU.encode_request(request), timeout}
  end

  # The client answers within the request's timeout; the margin is for a client that's swamped.
  defp call_timeout(nil), do: :infinity
  defp call_timeout(timeout), do: timeout + 1000

  defp config!(opts) do
    if not Keyword.keyword?(opts), do: raise(ArgumentError, "expected a keyword list of options")

    transports = for key <- [:tcp, :tls, :rtu, :ascii], Keyword.has_key?(opts, key), do: key

    case transports do
      [transport] ->
        config!(transport, Keyword.fetch!(opts, transport), opts)

      _ ->
        raise ArgumentError, "give one of tcp:, tls:, rtu: or ascii:, got: #{inspect(transports)}"
    end
  end

  defp config!(transport, host, opts) when transport in [:tcp, :tls] do
    known = [:port, :timeout, :max_pending, :check_unit, :connect_timeout, :backoff, :ssl, :name]
    unknown!(opts, [transport | known])
    port = Keyword.get(opts, :port, if(transport == :tls, do: 802, else: 502))

    config = %{
      transport: transport,
      host: host!(host),
      port: check!(port, is_integer(port) and port in 0..65535, "port: must be 0 to 65535"),
      timeout: positive!(opts, :timeout, 1000),
      max_pending:
        check!(
          Keyword.get(opts, :max_pending, 4),
          &(&1 in 1..65535),
          "max_pending: must be 1 to 65535"
        ),
      check_unit:
        check!(
          Keyword.get(opts, :check_unit, true),
          &is_boolean/1,
          "check_unit: must be a boolean"
        ),
      connect_timeout: positive!(opts, :connect_timeout, 5000),
      backoff: backoff!(Keyword.get(opts, :backoff, @backoff)),
      ssl: ssl!(transport, Keyword.get(opts, :ssl, []))
    }

    {Modbus.Client.Network, config}
  end

  defp config!(transport, device, opts) when transport in [:rtu, :ascii] do
    known = [
      :speed,
      :data_bits,
      :parity,
      :stop_bits,
      :timeout,
      :turnaround,
      :silence,
      :echo,
      :backoff,
      :name
    ]

    unknown!(opts, [transport | known])

    if not is_binary(device),
      do: raise(ArgumentError, "#{transport}: must be a device name, got: #{inspect(device)}")

    config = Modbus.Client.Line.config!(transport, device, opts)

    {Modbus.Client.Line,
     Map.merge(config, %{
       timeout: positive!(opts, :timeout, 1000),
       backoff: backoff!(Keyword.get(opts, :backoff, @backoff))
     })}
  end

  # An address as a string, IPv6 included, is taken as the address; anything else is a name.
  defp host!(host) when is_binary(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} -> address
      {:error, _not_an_address} -> String.to_charlist(host)
    end
  end

  defp host!(host) when is_tuple(host) and tuple_size(host) in [4, 8], do: host

  defp host!(host),
    do: raise(ArgumentError, "a host is a name or an address, got: #{inspect(host)}")

  defp ssl!(:tcp, []), do: []
  defp ssl!(:tcp, _ssl), do: raise(ArgumentError, "ssl: is for tls:, not tcp:")

  defp ssl!(:tls, ssl) do
    if not Keyword.keyword?(ssl), do: raise(ArgumentError, "ssl: must be a keyword list")

    if ssl[:verify] != :verify_none and not Keyword.has_key?(ssl, :cacerts) and
         not Keyword.has_key?(ssl, :cacertfile),
       do:
         raise(
           ArgumentError,
           "tls: needs ssl: [cacerts: ...] or [cacertfile: ...] to check the server's certificate"
         )

    Modbus.Security.client_options(ssl)
  end

  @doc false
  def unknown!(opts, known) do
    case Enum.uniq(Keyword.keys(opts)) -- known do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown options: #{inspect(unknown)}"
    end
  end

  @doc false
  def positive!(opts, key, default) do
    value = Keyword.get(opts, key, default)
    check!(value, is_integer(value) and value > 0, "#{key}: must be a positive integer")
  end

  @doc false
  def backoff!({first, longest} = backoff)
      when is_integer(first) and first > 0 and is_integer(longest) and longest >= first,
      do: backoff

  def backoff!(backoff),
    do: raise(ArgumentError, "backoff: must be {first, longest} in ms, got: #{inspect(backoff)}")

  defp check!(value, ok, message) when is_function(ok, 1), do: check!(value, ok.(value), message)
  defp check!(value, true, _message), do: value

  defp check!(value, _false, message),
    do: raise(ArgumentError, "#{message}, got: #{inspect(value)}")
end
