defmodule Modbus.TLSTest do
  use ExUnit.Case, async: true

  alias Modbus.{Client, Server}

  @rsa [key: {:rsa, 2048, 65537}, digest: :sha256]
  @san {:Extension, {2, 5, 29, 17}, false, [{:iPAddress, <<127, 0, 0, 1>>}]}

  # RSA keys take a while to make, so each set of certificates is made once.
  setup_all do
    %{pki: Map.new(["Viewer", "Operator", nil, :other], &{&1, pki(&1)})}
  end

  # Certificates for a server and a client, each from a CA of its own, the client's with a role.
  defp pki(:other), do: pki("Operator")

  defp pki(role) do
    extensions =
      if role,
        do: [
          {:Extension, {1, 3, 6, 1, 4, 1, 50316, 802, 1}, false,
           <<12, byte_size(role), role::binary>>}
        ],
        else: []

    :public_key.pkix_test_data(%{
      server_chain: %{root: @rsa, intermediates: [], peer: @rsa ++ [extensions: [@san]]},
      client_chain: %{root: @rsa, intermediates: [], peer: @rsa ++ [extensions: extensions]}
    })
  end

  defp server(pki, opts \\ []) do
    test = self()

    authorize = fn role, unit, request ->
      send(test, {:role, role})
      role == "Operator" or elem(request, 0) == :read_holding_registers or unit == 99
    end

    opts =
      [port: 0, handler: fn _, _ -> {:ok, [7]} end, ssl: pki.server_config, authorize: authorize] ++
        opts

    start_supervised!({Server, opts}, id: make_ref())
  end

  defp client(server, ssl, opts \\ []) do
    opts =
      Keyword.merge([tls: "127.0.0.1", port: Server.port(server), ssl: ssl, timeout: 1000], opts)

    start_supervised!({Client, opts}, id: make_ref())
  end

  test "the role in the client's certificate decides what it may do", %{pki: pkis} do
    pki = pkis["Viewer"]
    client = client(server(pki), pki.client_config)

    assert Client.read_holding_registers(client, 1, 0, 1) == {:ok, [7]}
    assert_received {:role, "Viewer"}

    assert Client.read_input_registers(client, 1, 0, 1) ==
             {:error, {:exception, :illegal_function}}

    operator = pkis["Operator"]
    client = client(server(operator), operator.client_config)
    assert Client.read_input_registers(client, 1, 0, 1) == {:ok, [7]}
    assert_received {:role, "Operator"}
  end

  test "a role that isn't a whole UTF8String is no role" do
    role = &Modbus.Security.role_value/1
    assert role.(<<12, 8, "Operator">>) == "Operator"
    long = String.duplicate("r", 200)
    assert role.(<<12, 0x81, 200, long::binary>>) == long

    assert role.(<<12, 0x82, 300::16, String.duplicate("r", 300)::binary>>) ==
             String.duplicate("r", 300)

    for value <- [
          <<12, 0x82>>,
          <<12, 0x81>>,
          <<12, 9, "Operator">>,
          <<12, 7, "Operator">>,
          <<19, 1, ?a>>,
          <<12, 2, 0xFF, 0xFE>>,
          <<>>,
          :not_der
        ] do
      assert role.(value) == nil, inspect(value)
    end
  end

  test "a certificate without a role has a role of nil", %{pki: pkis} do
    pki = pkis[nil]
    client = client(server(pki), pki.client_config)
    assert Client.read_holding_registers(client, 1, 0, 1) == {:ok, [7]}
    assert_received {:role, nil}
  end

  test "TLS 1.2 works as well as 1.3", %{pki: pkis} do
    pki = pkis["Operator"]
    client = client(server(pki), pki.client_config ++ [versions: [:"tlsv1.2"]])
    assert Client.read_holding_registers(client, 1, 0, 1) == {:ok, [7]}
  end

  test "a client without a certificate can't connect", %{pki: pkis} do
    pki = pkis["Operator"]
    ssl = Keyword.take(pki.client_config, [:cacerts])
    client = client(server(pki), ssl, backoff: {1000, 1000}, timeout: 5000)

    # Over TLS 1.3 the client finishes its handshake before the server refuses it, with an alert
    # that may come after the connection has closed.
    assert Client.read_holding_registers(client, 1, 0, 1) == {:error, :closed}
    assert {:disconnected, reason} = Client.status(client)
    assert match?({:tls_alert, _}, reason) or reason == :closed
  end

  test "a client that doesn't trust the server's certificate won't talk to it", %{pki: pkis} do
    pki = pkis["Operator"]
    other = pkis[:other]
    ssl = Keyword.put(pki.client_config, :cacerts, other.client_config[:cacerts])
    client = client(server(pki), ssl, backoff: {1000, 1000}, timeout: 5000)

    assert Client.read_holding_registers(client, 1, 0, 1) == {:error, :closed}
    assert {:disconnected, {:tls_alert, _}} = Client.status(client)
  end

  test "a plain TCP client, or one that never finishes its handshake, is closed", %{pki: pkis} do
    pki = pkis["Operator"]
    server = server(pki, handshake_timeout: 200)

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, Server.port(server), [:binary, active: false])

    :ok = :gen_tcp.send(socket, Modbus.TCP.encode(1, 1, <<3, 0, 0, 0, 1>>))

    assert closed?(socket)

    {:ok, silent} =
      :gen_tcp.connect({127, 0, 0, 1}, Server.port(server), [:binary, active: false])

    assert closed?(silent)
  end

  # Closed within a second, after whatever alert the server sends.
  defp closed?(socket) do
    case :gen_tcp.recv(socket, 0, 1000) do
      {:error, :closed} -> true
      {:ok, _alert} -> closed?(socket)
      {:error, :timeout} -> false
    end
  end

  test "a TLS server needs its certificate, and what to check clients' against", %{pki: pkis} do
    pki = pkis["Operator"]
    handler = fn _, _ -> :ok end

    assert_raise ArgumentError, ~r/its certificate/, fn ->
      Server.start_link(
        port: 0,
        handler: handler,
        ssl: Keyword.take(pki.server_config, [:cacerts])
      )
    end

    assert_raise ArgumentError, ~r/checked against/, fn ->
      Server.start_link(
        port: 0,
        handler: handler,
        ssl: Keyword.take(pki.server_config, [:cert, :key])
      )
    end
  end
end
