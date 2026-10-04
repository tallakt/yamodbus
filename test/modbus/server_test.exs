defmodule Modbus.ServerTest do
  use ExUnit.Case, async: true

  alias Modbus.{Client, Memory, Server, TCP}

  defp server(opts) do
    start_supervised!({Server, [port: 0, address: {127, 0, 0, 1}] ++ opts}, id: make_ref())
  end

  defp memory_server(opts \\ []) do
    memory = start_supervised!({Memory, [holding_registers: 1000, coils: 1000]}, id: make_ref())
    {memory, server([handler: {Memory, memory}] ++ opts)}
  end

  defp client(server),
    do: start_supervised!({Client, tcp: "127.0.0.1", port: Server.port(server)}, id: make_ref())

  # A client played by the test, to send what no proper client would.
  defp connect(server) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, Server.port(server), [:binary, active: false], 1000)

    socket
  end

  defp exchange(socket, transaction, pdu) do
    :ok = :gen_tcp.send(socket, TCP.encode(transaction, 1, pdu))
    receive_frame(socket)
  end

  defp receive_frame(socket) do
    with {:ok, <<transaction::16, 0::16, length::16>>} <- :gen_tcp.recv(socket, 6, 1000),
         {:ok, <<_unit, pdu::binary>>} <- :gen_tcp.recv(socket, length, 1000) do
      {transaction, pdu}
    end
  end

  test "every function of the data model, through a client" do
    {_memory, server} = memory_server()
    client = client(server)

    assert :ok = Client.write_single_coil(client, 1, 3, true)
    assert :ok = Client.write_multiple_coils(client, 1, 10, [true, false, true])
    assert {:ok, [false, false, false, true]} = Client.read_coils(client, 1, 0, 4)
    assert {:ok, [true, false, true]} = Client.read_coils(client, 1, 10, 3)
    assert :ok = Client.write_single_register(client, 1, 0, 0x12)
    assert :ok = Client.mask_write_register(client, 1, 0, 0xF2, 0x25)
    assert {:ok, [0x17]} = Client.read_holding_registers(client, 1, 0, 1)
    assert :ok = Client.write_multiple_registers(client, 1, 100, [2, 7, 8])
    assert {:ok, [7, 8]} = Client.read_fifo_queue(client, 1, 100)
    assert {:ok, [5, 6, 0]} = Client.read_write_multiple_registers(client, 1, 200, 3, 200, [5, 6])
    assert {:ok, [0]} = Client.read_input_registers(client, 1, 0, 1)
    assert {:ok, [false]} = Client.read_discrete_inputs(client, 1, 0, 1)
    assert :ok = Client.write_file_record(client, 1, [{2, 9998, [1, 2]}])
    assert {:ok, [[1, 2], [0]]} = Client.read_file_record(client, 1, [{2, 9998, 2}, {3, 0, 1}])

    assert Client.read_holding_registers(client, 1, 999, 2) ==
             {:error, {:exception, :illegal_data_address}}

    assert Client.read_file_record(client, 1, [{11, 0, 1}]) ==
             {:error, {:exception, :illegal_data_address}}

    assert Client.request(client, 1, :report_server_id) ==
             {:error, {:exception, :illegal_function}}
  end

  test "a handler that raises, or gives a result that doesn't answer, is a server failure" do
    handler = fn
      _unit, {:read_coils, 0, _} -> raise "oops"
      _unit, {:read_coils, 1, _} -> {:ok, [true]}
      _unit, {:read_coils, 2, _} -> exit(:gone)
      _unit, _request -> :nonsense
    end

    client = client(server(handler: handler))

    for request <- [
          {:read_coils, 0, 2},
          {:read_coils, 1, 2},
          {:read_coils, 2, 2},
          {:read_coils, 3, 2}
        ] do
      assert Client.request(client, 1, request) == {:error, {:exception, :server_device_failure}}
    end
  end

  test "a gateway's client errors are the gateway exceptions" do
    handler = fn
      _unit, {:read_coils, 0, _} -> {:error, :timeout}
      _unit, _request -> {:error, :closed}
    end

    client = client(server(handler: handler))

    assert Client.read_coils(client, 1, 0, 1) ==
             {:error, {:exception, :gateway_target_device_failed_to_respond}}

    assert Client.read_coils(client, 1, 1, 1) == {:error, {:exception, :gateway_path_unavailable}}
  end

  test "a module handler gets the unit and its arg" do
    defmodule Echo do
      @behaviour Modbus.Server
      def handle_request(unit, {:read_holding_registers, _, 2}, arg), do: {:ok, [unit, arg]}
    end

    client = client(server(handler: {Echo, 42}))
    assert Client.read_holding_registers(client, 9, 0, 2) == {:ok, [9, 42]}
  end

  test "a request that breaks its function's rules is answered, and the connection goes on" do
    {_memory, server} = memory_server()
    socket = connect(server)

    assert exchange(socket, 1, <<3, 0, 0, 0, 200>>) == {1, <<0x83, 3>>}
    assert exchange(socket, 2, <<0x83, 0>>) == {2, <<0x83, 1>>}
    assert exchange(socket, 3, <<99, 1, 2>>) == {3, <<99 + 0x80, 1>>}
    assert exchange(socket, 4, <<3, 0, 0, 0, 1>>) == {4, <<3, 2, 0, 0>>}
  end

  test "frames of another protocol get no answer" do
    {_memory, server} = memory_server()
    socket = connect(server)
    :ok = :gen_tcp.send(socket, <<1::16, 5::16, 6::16, 1, 3, 0, 0, 0, 1>>)
    assert exchange(socket, 2, <<3, 0, 0, 0, 1>>) == {2, <<3, 2, 0, 0>>}
  end

  test "a header that can't be Modbus's closes the connection" do
    {_memory, server} = memory_server()
    socket = connect(server)
    :ok = :gen_tcp.send(socket, <<1::16, 0::16, 1000::16, 1>>)
    assert :gen_tcp.recv(socket, 0, 1000) == {:error, :closed}
  end

  test "requests sent at once are answered in turn" do
    {_memory, server} = memory_server()
    socket = connect(server)
    frames = for i <- 1..50, into: <<>>, do: TCP.encode(i, 1, <<6, i::16, i::16>>)
    :ok = :gen_tcp.send(socket, frames)

    for i <- 1..50 do
      assert receive_frame(socket) == {i, <<6, i::16, i::16>>}
    end
  end

  test "a full server closes the connection that has gone longest without a request" do
    {_memory, server} = memory_server(connections: 2)
    a = connect(server)
    b = connect(server)
    Process.sleep(20)
    assert {1, _} = exchange(a, 1, <<3, 0, 0, 0, 1>>)
    c = connect(server)

    assert :gen_tcp.recv(b, 0, 1000) == {:error, :closed}
    assert {2, _} = exchange(a, 2, <<3, 0, 0, 0, 1>>)
    assert {3, _} = exchange(c, 3, <<3, 0, 0, 0, 1>>)
  end

  test "a flood of connections reset at once doesn't hold up the next client" do
    {_memory, server} = memory_server()

    for _ <- 1..300 do
      {:ok, socket} =
        :gen_tcp.connect({127, 0, 0, 1}, Server.port(server), [:binary, linger: {true, 0}])

      :gen_tcp.close(socket)
    end

    client = client(server)
    assert {:ok, [0]} = Client.read_holding_registers(client, 1, 0, 1, timeout: 500)
  end

  test "a connection without a request is closed when idle, though it trickles bytes" do
    {_memory, server} = memory_server(idle: 150)
    socket = connect(server)
    started = System.monotonic_time(:millisecond)

    for byte <- [0, 1, 0, 0] do
      :gen_tcp.send(socket, <<byte>>)
      Process.sleep(40)
    end

    assert :gen_tcp.recv(socket, 0, 1000) == {:error, :closed}
    assert System.monotonic_time(:millisecond) - started < 400
  end

  test "a full server closes a connection of the host that holds the most" do
    victim = &Modbus.Server.Network.victim/2
    a = {10, 0, 0, 1}
    b = {10, 0, 0, 2}
    c = {10, 0, 0, 3}

    # one host each: the one longest without a request
    assert victim.([{:p1, 5, a}, {:p2, 1, b}, {:p3, 9, c}], {10, 0, 0, 9}) == :p2
    # a host that already has a connection loses its own to a new one of its own
    assert victim.([{:p1, 5, a}, {:p2, 1, b}, {:p3, 9, c}], c) == :p3
    # the host with the most loses one, its oldest
    assert victim.([{:p1, 5, a}, {:p2, 1, b}, {:p3, 7, a}, {:p4, 6, a}], b) == :p1
  end

  test "allow: lets in only the addresses listed" do
    allowed? = &Modbus.Server.Network.allowed?/2
    assert allowed?.({10, 1, 2, 3}, nil)
    assert allowed?.({10, 1, 2, 3}, [{{10, 0, 0, 0}, 8}])
    refute allowed?.({11, 1, 2, 3}, [{{10, 0, 0, 0}, 8}])
    assert allowed?.({192, 168, 0, 5}, [{192, 168, 0, 5}])
    refute allowed?.({192, 168, 0, 6}, [{192, 168, 0, 5}])
    assert allowed?.({0, 0, 0, 0, 0, 0xFFFF, 0x0A01, 0x0203}, [{{10, 0, 0, 0}, 8}])
    assert allowed?.({0xFD00, 0, 0, 0, 0, 0, 0, 1}, [{{0xFD00, 0, 0, 0, 0, 0, 0, 0}, 8}])
    assert allowed?.({8, 8, 8, 8}, [{{0, 0, 0, 0}, 0}])

    {_memory, closed} = memory_server(allow: [{{10, 0, 0, 0}, 8}])
    socket = connect(closed)
    assert :gen_tcp.recv(socket, 0, 1000) == {:error, :closed}

    {_memory, open} = memory_server(allow: [{{127, 0, 0, 0}, 8}])
    assert {1, _} = exchange(connect(open), 1, <<3, 0, 0, 0, 1>>)
  end

  test "a handler that takes longer than handler_timeout is a server failure" do
    handler = fn
      _unit, {:read_coils, 0, _} -> Process.sleep(:infinity)
      _unit, {:read_coils, _, n} -> {:ok, List.duplicate(true, n)}
    end

    client = client(server(handler: handler, handler_timeout: 100))
    assert Client.read_coils(client, 1, 0, 1) == {:error, {:exception, :server_device_failure}}
    assert Client.read_coils(client, 1, 1, 1) == {:ok, [true]}
  end

  test "authorize refuses with an illegal function" do
    allowed? = fn nil, _unit, request -> elem(request, 0) in [:read_holding_registers] end
    {_memory, server} = memory_server(authorize: allowed?)
    client = client(server)

    assert {:ok, [0]} = Client.read_holding_registers(client, 1, 0, 1)

    assert Client.write_single_register(client, 1, 0, 1) ==
             {:error, {:exception, :illegal_function}}
  end

  test "a port that's taken" do
    {_memory, server} = memory_server()
    port = Server.port(server)
    Process.flag(:trap_exit, true)

    assert Server.start_link(port: port, address: {127, 0, 0, 1}, handler: fn _, _ -> :ok end) ==
             {:error, :eaddrinuse}
  end

  test "stopping closes the connections" do
    memory = start_supervised!(Memory)
    {:ok, server} = Server.start_link(port: 0, handler: {Memory, memory})
    socket = connect(server)
    assert {1, _} = exchange(socket, 1, <<3, 0, 0, 0, 1>>)
    Server.stop(server)
    assert :gen_tcp.recv(socket, 0, 1000) == {:error, :closed}
  end

  test "options that don't make sense" do
    assert_raise ArgumentError, fn -> Server.start_link(port: 0) end
    assert_raise ArgumentError, fn -> Server.start_link(port: 0, handler: fn _ -> :ok end) end

    assert_raise ArgumentError, fn ->
      Server.start_link(port: 0, handler: fn _, _ -> :ok end, idle: 0)
    end

    assert_raise ArgumentError, fn ->
      Server.start_link(handler: fn _, _ -> :ok end, ssl: [certfile: "x"])
    end

    assert_raise ArgumentError, fn ->
      Server.start_link(port: 0, handler: fn _, _ -> :ok end, identification: %{0 => "a"})
    end

    assert_raise ArgumentError, fn ->
      Server.start_link(rtu: "/dev/x", handler: fn _, _ -> :ok end)
    end

    assert_raise ArgumentError, fn ->
      Server.start_link(port: 0, handler: fn _, _ -> :ok end, allow: [{{10, 0, 0, 0}, 40}])
    end

    assert_raise ArgumentError, fn -> Memory.start_link(files: 101) end
  end
end
