defmodule Modbus.Server do
  @moduledoc """
  A Modbus server, on TCP, TLS, or a serial line in RTU or ASCII, that answers each request through a
  handler.

      iex> handler = fn
      ...>   _unit, {:read_input_registers, 0, 2} -> {:ok, [215, 1013]}
      ...>   _unit, _request -> {:error, {:exception, :illegal_function}}
      ...> end
      iex> {:ok, server} = Modbus.Server.start_link(port: 0, handler: handler)
      iex> {:ok, client} = Modbus.Client.start_link(tcp: "127.0.0.1", port: Modbus.Server.port(server))
      iex> Modbus.Client.read_input_registers(client, 1, 0, 2)
      {:ok, [215, 1013]}
      iex> Modbus.Client.read_coils(client, 1, 0, 8)
      {:error, {:exception, :illegal_function}}

  ## Handlers

  A handler is a function of the unit id and the request, or `{module, arg}` for a module with this
  behaviour, called as `module.handle_request(unit, request, arg)`. It gives the result a client
  would get, as listed in `Modbus`: `:ok` for a write, `{:ok, values}` for a read, and
  `{:error, {:exception, name}}` to refuse. A result that doesn't answer the request, such as the
  wrong number of registers, or a handler that raises, is answered with `:server_device_failure`.

  `Modbus.Memory` is a handler that keeps the four tables of the Modbus data model.

  A handler can be a gateway, passing requests on through a client: when that client gives
  `{:error, :timeout}` or `{:error, :closed}`, the server answers with the gateway exceptions,
  `:gateway_target_device_failed_to_respond` and `:gateway_path_unavailable`.

      {:ok, line} = Modbus.Client.start_link(rtu: "/dev/ttyUSB0")
      Modbus.Server.start_link(port: 502, handler: fn unit, request ->
        Modbus.Client.request(line, unit, request)
      end)

  A TCP connection's requests are answered in turn, and connections are served at once. A serial
  server answers one request at a time. Each request's handler runs in a short-lived process of its
  own, for `:handler_timeout` at most; one that takes longer is answered with
  `:server_device_failure`.

  ## Connections

  A server on a plant network should expect anything on its port. It takes at most `:connections`
  clients, and when one more connects, it closes the one that has gone longest without a request, as
  the TCP guide recommends: a client that reconnects without closing its old connection, or a
  stalled one, can't lock others out. It closes it among the connections of the address that holds
  the most, the new client's own first, so a host that floods the port pushes out only its own
  connections. `:allow` limits who may connect at all, which the TCP guide suggests too.

  A connection with no request for `:idle` is closed. A header that no Modbus client sends closes
  its connection; a request that breaks the rules of its function is answered with
  `:illegal_data_value` and the connection goes on.

  ## Serial lines

  A serial server answers the units in `:units` and acts on broadcasts (unit 0) without answering.
  It keeps the spec's diagnostic counters and event log itself, so it answers Diagnostics (8), Get
  Comm Event Counter (11) and Get Comm Event Log (12) without the handler, and goes into listen only
  mode when told, until a Restart Communications Option. It needs
  [circuits_uart](https://hex.pm/packages/circuits_uart) among the application's dependencies.

  ## Device identification

  With `:identification`, a map of object ids to values, the server answers Read Device
  Identification (43/14) itself, in as many responses as the objects take:

      identification: %{0 => "Acme", 1 => "PD-100", 2 => "2.11", 4 => "Pump drive"}

  Objects 0 to 2 (vendor, product code and revision) are required, 3 to 0x7F are the regular
  category, and 0x80 to 0xFF the extended. Without it, the handler gets those requests.

  ## Security

  `ssl:` makes it Modbus/TCP Security, the frames of Modbus TCP inside TLS 1.2 or later, on port 802
  by default. The server needs its certificate and key, and the certificates it trusts clients'
  certificates by; a client without a certificate the server trusts can't connect.

      Modbus.Server.start_link(handler: handler, authorize: &MyPlant.allowed?/3,
        ssl: [certfile: "server.pem", keyfile: "server.key", cacertfile: "plant-ca.pem"])

  A client's certificate may carry a role, a string in the extension with the OID
  1.3.6.1.4.1.50316.802.1. `:authorize` is a function of the role (nil if the certificate has none),
  the unit and the request, which says whether the client may make it; a request it refuses is
  answered with `:illegal_function`, as the spec has it. It works on the other transports too, with a
  role of nil.

  ## Options

    * `:handler` - a function of the unit and request, or `{module, arg}` (required)
    * `:port` - 502, or 802 with `:ssl`; 0 for any free port, see `port/1`
    * `:address` - the address to listen on, as a tuple (default all of them)
    * `:connections` - how many clients at once (default 16)
    * `:allow` - the client addresses that may connect, each an address or `{address, prefix
      length}`, as `[{{10, 0, 0, 0}, 8}]` (default any)
    * `:idle` - how long a connection may go without a request, in ms, or `:infinity` (default 60000)
    * `:ssl` - options for `:ssl.listen/2`, which make it a TLS server
    * `:handshake_timeout` - how long a TLS client has to finish its handshake, in ms (default 10000)
    * `:handler_timeout` - how long a handler may take over a request, in ms (default 10000)
    * `:rtu` or `:ascii` - a serial device, such as `"/dev/ttyS0"`, instead of a port
    * `:units` - the unit ids a serial server answers, 1 to 247 (required for serial lines)
    * `:speed` (19200), `:data_bits` (8, or 7 for ASCII), `:parity` (`:even`) and `:stop_bits` (1) -
      for serial lines
    * `:echo` - `true` for a serial adapter that echoes what it sends, as some RS-485 adapters do,
      so the server passes over its own answers
    * `:identification` - device identification objects, see above
    * `:authorize` - a function of the role, unit and request, see above
    * `:name` - to register the process
  """

  @doc """
  Answers a request to unit `unit` with the result a client gets, as listed in `Modbus`. `arg` is
  what the handler was given as `{module, arg}`.
  """
  @callback handle_request(unit :: Modbus.unit(), request :: Modbus.request(), arg :: term) ::
              Modbus.result()

  @doc false
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Starts a server, linked to the caller, with the options above. A network server is listening when
  it returns; a port that's taken is `{:error, :eaddrinuse}`. A serial server opens its port, and
  opens it again if it fails. Raises `ArgumentError` for options that don't make sense.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    if not Keyword.keyword?(opts), do: raise(ArgumentError, "expected a keyword list of options")
    name = if opts[:name], do: [name: opts[:name]], else: []

    common = %{
      handler: handler!(Keyword.get(opts, :handler)),
      authorize: authorize!(Keyword.get(opts, :authorize)),
      identification:
        if(opts[:identification], do: Modbus.Server.Identification.check!(opts[:identification])),
      handler_timeout: Modbus.Client.positive!(opts, :handler_timeout, 10_000)
    }

    case Enum.filter([:rtu, :ascii], &Keyword.has_key?(opts, &1)) do
      [] ->
        Modbus.Server.Network.start_link(Map.merge(common, network!(opts)), name)

      [transport] ->
        config = Map.merge(common, Modbus.Server.Line.config!(transport, opts))
        GenServer.start_link(Modbus.Server.Line, config, name)

      _both ->
        raise ArgumentError, "give one of rtu: or ascii:, not both"
    end
  end

  @doc """
  The port a network server listens on, which is the one the OS picked for `port: 0`.
  """
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @doc "Closes the server's port and its connections, and stops it."
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server)

  defp network!(opts) do
    known =
      [:handler, :authorize, :identification, :port, :address, :connections, :idle, :ssl] ++
        [:handshake_timeout, :handler_timeout, :allow, :name]

    Modbus.Client.unknown!(opts, known)
    ssl = Keyword.get(opts, :ssl)

    %{
      transport: if(ssl, do: :tls, else: :tcp),
      port: port!(Keyword.get(opts, :port, if(ssl, do: 802, else: 502))),
      address: address!(Keyword.get(opts, :address, {0, 0, 0, 0})),
      connections: Modbus.Client.positive!(opts, :connections, 16),
      idle: idle!(Keyword.get(opts, :idle, 60_000)),
      handshake_timeout: Modbus.Client.positive!(opts, :handshake_timeout, 10_000),
      allow: allow!(Keyword.get(opts, :allow)),
      ssl: if(ssl, do: ssl!(ssl), else: [])
    }
  end

  defp port!(port) when is_integer(port) and port in 0..65535, do: port
  defp port!(port), do: raise(ArgumentError, "port: must be 0 to 65535, got: #{inspect(port)}")

  defp address!(address) when tuple_size(address) in [4, 8], do: address

  defp address!(address),
    do: raise(ArgumentError, "address: must be an address tuple, got: #{inspect(address)}")

  defp idle!(idle) when idle == :infinity or (is_integer(idle) and idle > 0), do: idle

  defp idle!(idle) do
    raise ArgumentError,
          "idle: must be a positive number of ms or :infinity, got: #{inspect(idle)}"
  end

  defp allow!(nil), do: nil
  defp allow!(allow) when is_list(allow), do: Enum.map(allow, &allowed!/1)

  defp allow!(allow),
    do: raise(ArgumentError, "allow: must be a list of addresses, got: #{inspect(allow)}")

  defp allowed!({address, bits} = entry) when tuple_size(address) == 4 and bits in 0..32,
    do: entry

  defp allowed!({address, bits} = entry) when tuple_size(address) == 8 and bits in 0..128,
    do: entry

  defp allowed!(address) when tuple_size(address) in [4, 8], do: address

  defp allowed!(other) do
    raise ArgumentError,
          "allow: takes addresses, or {address, prefix length}, got: #{inspect(other)}"
  end

  defp ssl!(ssl) do
    if not Keyword.keyword?(ssl), do: raise(ArgumentError, "ssl: must be a keyword list")

    for {keys, what} <- [
          {[:certfile, :cert, :certs_keys], "its certificate"},
          {[:cacertfile, :cacerts],
           "the certificates that clients' certificates are checked against"}
        ],
        not Enum.any?(keys, &Keyword.has_key?(ssl, &1)) do
      raise ArgumentError, "ssl: needs #{what} (#{Enum.map_join(keys, " or ", &"#{&1}:")})"
    end

    Modbus.Security.server_options(ssl)
  end

  defp handler!({module, _arg} = handler) when is_atom(module), do: handler
  defp handler!(fun) when is_function(fun, 2), do: fun

  defp handler!(handler),
    do:
      raise(
        ArgumentError,
        "handler: must be a function of the unit and request, or {module, arg}, got: #{inspect(handler)}"
      )

  defp authorize!(nil), do: nil
  defp authorize!(fun) when is_function(fun, 3), do: fun

  defp authorize!(authorize),
    do:
      raise(
        ArgumentError,
        "authorize: must be a function of the role, unit and request, got: #{inspect(authorize)}"
      )
end
