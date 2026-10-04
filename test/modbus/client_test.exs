defmodule Modbus.ClientTest do
  use ExUnit.Case, async: true

  alias Modbus.{Client, TCP}

  # A server played by the test, a frame at a time, to answer as no proper server would.
  defp listen do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    {listen, port}
  end

  defp accept(listen) do
    {:ok, socket} = :gen_tcp.accept(listen, 2000)
    socket
  end

  defp next_frame(socket, timeout \\ 2000) do
    with {:ok, <<transaction::16, 0::16, length::16>>} <- :gen_tcp.recv(socket, 6, timeout),
         {:ok, <<unit, pdu::binary>>} <- :gen_tcp.recv(socket, length, timeout) do
      {transaction, unit, pdu}
    end
  end

  defp answer(socket, transaction, unit, pdu),
    do: :ok = :gen_tcp.send(socket, TCP.encode(transaction, unit, pdu))

  defp client(port, opts \\ []) do
    start_supervised!({Client, [tcp: "127.0.0.1", port: port] ++ opts}, id: make_ref())
  end

  defp results(refs) do
    for ref <- refs do
      assert_receive {Client, ^ref, result}, 2000
      result
    end
  end

  test "several requests on the way at once, answered in any order" do
    {listen, port} = listen()
    client = client(port, max_pending: 3)
    refs = for i <- 0..4, do: Client.send_request(client, 1, {:read_holding_registers, i, 1})
    socket = accept(listen)

    first = for _ <- 1..3, do: next_frame(socket)
    # no more than max_pending on the way
    assert next_frame(socket, 100) == {:error, :timeout}

    for {transaction, unit, <<3, address::16, 1::16>>} <- Enum.reverse(first),
        do: answer(socket, transaction, unit, <<3, 2, address + 100::16>>)

    rest = for _ <- 1..2, do: next_frame(socket)

    for {transaction, unit, <<3, address::16, 1::16>>} <- rest,
        do: answer(socket, transaction, unit, <<3, 2, address + 100::16>>)

    assert results(refs) == for(i <- 0..4, do: {:ok, [i + 100]})
    # each its own transaction id
    assert Enum.uniq_by(first ++ rest, &elem(&1, 0)) |> length() == 5
  end

  test "an answer from another unit than the one asked doesn't fit" do
    {listen, port} = listen()
    client = client(port)
    task = Task.async(fn -> Client.read_coils(client, 3, 0, 1) end)
    socket = accept(listen)
    {transaction, 3, _pdu} = next_frame(socket)
    answer(socket, transaction, 5, <<1, 1, 1>>)
    assert Task.await(task) == {:error, {:invalid_response, <<1, 1, 1>>}}

    # and the connection goes on
    task = Task.async(fn -> Client.read_coils(client, 3, 0, 1) end)
    {transaction, 3, _pdu} = next_frame(socket)
    answer(socket, transaction, 3, <<1, 1, 1>>)
    assert Task.await(task) == {:ok, [true]}
  end

  test "check_unit: false takes the answer of a device that doesn't copy the unit id back" do
    {listen, port} = listen()
    client = client(port, check_unit: false)
    task = Task.async(fn -> Client.read_coils(client, 3, 0, 1) end)
    socket = accept(listen)
    {transaction, 3, _pdu} = next_frame(socket)
    answer(socket, transaction, 255, <<1, 1, 1>>)
    assert Task.await(task) == {:ok, [true]}
  end

  test "an answer that doesn't fit its request" do
    {listen, port} = listen()
    client = client(port)
    task = Task.async(fn -> Client.read_holding_registers(client, 1, 0, 2) end)
    socket = accept(listen)
    {transaction, unit, _pdu} = next_frame(socket)
    answer(socket, transaction, unit, <<4, 4, 0, 1, 0, 2>>)
    assert Task.await(task) == {:error, {:invalid_response, <<4, 4, 0, 1, 0, 2>>}}

    task = Task.async(fn -> Client.read_holding_registers(client, 1, 0, 2) end)
    {transaction, unit, _pdu} = next_frame(socket)
    answer(socket, transaction, unit, <<3, 2, 0, 1>>)
    assert Task.await(task) == {:error, {:invalid_response, <<3, 2, 0, 1>>}}
  end

  test "an exception" do
    {listen, port} = listen()
    client = client(port)
    task = Task.async(fn -> Client.write_single_register(client, 1, 0, 5) end)
    socket = accept(listen)
    {transaction, unit, _pdu} = next_frame(socket)
    answer(socket, transaction, unit, <<0x86, 2>>)
    assert Task.await(task) == {:error, {:exception, :illegal_data_address}}
  end

  test "an answer after its request timed out is dropped, and the connection goes on" do
    {listen, port} = listen()
    client = client(port)
    slow = Client.send_request(client, 1, {:read_coils, 0, 1}, timeout: 1000)
    fast = Client.send_request(client, 1, {:read_coils, 1, 1})
    socket = accept(listen)
    {t1, _, _} = next_frame(socket)
    {t2, _, _} = next_frame(socket)
    answer(socket, t2, 1, <<1, 1, 0>>)
    assert results([fast]) == [{:ok, [false]}]
    assert results([slow]) == [{:error, :timeout}]

    answer(socket, t1, 1, <<1, 1, 1>>)
    task = Task.async(fn -> Client.read_coils(client, 1, 2, 1) end)
    {t3, _, _} = next_frame(socket)
    assert t3 not in [t1, t2]
    answer(socket, t3, 1, <<1, 1, 1>>)
    assert Task.await(task) == {:ok, [true]}
    refute_received {Client, _, _}
  end

  test "two requests in a row that time out with nothing heard mean the connection is dead" do
    {listen, port} = listen()
    client = client(port, backoff: {10, 10})
    socket = accept(listen)

    for _ <- 1..2 do
      task = Task.async(fn -> Client.read_coils(client, 1, 0, 1, timeout: 100) end)
      {_transaction, _unit, _pdu} = next_frame(socket)
      assert Task.await(task) == {:error, :timeout}
    end

    assert :gen_tcp.recv(socket, 0, 1000) == {:error, :closed}

    # and it connects again
    socket = accept(listen)
    task = Task.async(fn -> Client.read_coils(client, 1, 0, 1) end)
    {transaction, unit, _pdu} = next_frame(socket)
    answer(socket, transaction, unit, <<1, 1, 1>>)
    assert Task.await(task) == {:ok, [true]}
  end

  test "a device that trickles bytes, never a whole frame, doesn't keep a dead connection" do
    {listen, port} = listen()
    client = client(port, backoff: {10, 10})
    socket = accept(listen)

    # the header of a frame of 254 bytes, then one byte every 10 ms of it
    :ok = :gen_tcp.send(socket, <<0::16, 0::16, 254::16>>)

    spawn_link(fn ->
      for _ <- 1..100, do: :gen_tcp.send(socket, <<0>>) && Process.sleep(10)
    end)

    for _ <- 1..2 do
      task = Task.async(fn -> Client.read_coils(client, 1, 0, 1, timeout: 100) end)
      assert Task.await(task) == {:error, :timeout}
    end

    assert closed?(socket)
    assert accept(listen)
  end

  defp closed?(socket) do
    case :gen_tcp.recv(socket, 0, 1000) do
      {:error, :closed} -> true
      {:ok, _request} -> closed?(socket)
      {:error, :timeout} -> false
    end
  end

  test "a slow device, answering after its requests time out, keeps its connection" do
    {listen, port} = listen()
    client = client(port)
    socket = accept(listen)

    for i <- 1..3 do
      task = Task.async(fn -> Client.read_coils(client, 1, i, 1, timeout: 100) end)
      {transaction, unit, _pdu} = next_frame(socket)
      assert Task.await(task) == {:error, :timeout}
      answer(socket, transaction, unit, <<1, 1, 1>>)
    end

    task = Task.async(fn -> Client.read_coils(client, 1, 0, 1) end)
    {transaction, unit, _pdu} = next_frame(socket)
    answer(socket, transaction, unit, <<1, 1, 0>>)
    assert Task.await(task) == {:ok, [false]}
  end

  test "frames of another protocol are dropped" do
    {listen, port} = listen()
    client = client(port)
    task = Task.async(fn -> Client.read_coils(client, 1, 0, 1) end)
    socket = accept(listen)
    {transaction, unit, _pdu} = next_frame(socket)
    :ok = :gen_tcp.send(socket, <<transaction::16, 7::16, 4::16, unit, 1, 1, 0>>)
    answer(socket, transaction, unit, <<1, 1, 1>>)
    assert Task.await(task) == {:ok, [true]}
  end

  test "a header that can't be Modbus's closes the connection" do
    {listen, port} = listen()
    client = client(port, backoff: {10, 10})
    task = Task.async(fn -> Client.read_coils(client, 1, 0, 1) end)
    socket = accept(listen)
    {transaction, _unit, _pdu} = next_frame(socket)
    :ok = :gen_tcp.send(socket, <<transaction::16, 0::16, 60_000::16, 1>>)
    assert Task.await(task) == {:error, :closed}
    assert :gen_tcp.recv(socket, 0, 1000) == {:error, :closed}
    assert accept(listen)
  end

  test "with nothing to connect to, requests fail at once, and it keeps trying" do
    {listen, port} = listen()
    :gen_tcp.close(listen)
    client = client(port, backoff: {20, 20})

    assert Client.read_coils(client, 1, 0, 1) == {:error, :closed}
    assert Client.status(client) == {:disconnected, :econnrefused}
    {time, {:error, :closed}} = :timer.tc(fn -> Client.read_coils(client, 1, 0, 1) end)
    assert time < 50_000

    {:ok, listen} = :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true])
    socket = accept(listen)
    wait_until(fn -> Client.status(client) == :connected end)
    task = Task.async(fn -> Client.read_coils(client, 1, 0, 1) end)
    {transaction, unit, _pdu} = next_frame(socket)
    answer(socket, transaction, unit, <<1, 1, 1>>)
    assert Task.await(task) == {:ok, [true]}
  end

  test "an IPv6 address, as a string or a tuple" do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, :inet6, ip: {0, 0, 0, 0, 0, 0, 0, 1}, active: false])

    {:ok, port} = :inet.port(listen)

    for host <- ["::1", {0, 0, 0, 0, 0, 0, 0, 1}] do
      client = client_for(host, port)
      task = Task.async(fn -> Client.read_coils(client, 1, 0, 1) end)
      socket = accept(listen)
      {transaction, unit, _pdu} = next_frame(socket)
      answer(socket, transaction, unit, <<1, 1, 1>>)
      assert Task.await(task) == {:ok, [true]}
    end
  end

  defp client_for(host, port),
    do: start_supervised!({Client, tcp: host, port: port}, id: make_ref())

  test "requests wait for the first connection" do
    {listen, port} = listen()
    client = client(port)
    assert Client.status(client) in [:connecting, :connected]
    task = Task.async(fn -> Client.read_coils(client, 1, 0, 1) end)
    socket = accept(listen)
    {transaction, unit, _pdu} = next_frame(socket)
    answer(socket, transaction, unit, <<1, 1, 1>>)
    assert Task.await(task) == {:ok, [true]}
  end

  test "a lost connection fails the requests on the way" do
    {listen, port} = listen()
    client = client(port)
    ref = Client.send_request(client, 1, {:read_coils, 0, 1})
    socket = accept(listen)
    {_transaction, _unit, _pdu} = next_frame(socket)
    :gen_tcp.close(socket)
    assert results([ref]) == [{:error, :closed}]
  end

  test "the caller never exits, even when the client is gone" do
    {listen, port} = listen()
    {:ok, client} = Client.start_link(tcp: "127.0.0.1", port: port)
    Process.unlink(client)
    accept(listen)
    Process.exit(client, :kill)
    assert Client.read_coils(client, 1, 0, 1) == {:error, :closed}
  end

  test "send_request answers another process" do
    {listen, port} = listen()
    client = client(port)
    me = self()
    other = spawn(fn -> receive(do: (message -> send(me, {:got, message}))) end)
    ref = Client.send_request(client, 1, {:read_coils, 0, 1}, to: other)
    socket = accept(listen)
    {transaction, unit, _pdu} = next_frame(socket)
    answer(socket, transaction, unit, <<1, 1, 1>>)
    assert_receive {:got, {Client, ^ref, {:ok, [true]}}}
  end

  test "requests that don't fit the protocol raise in the caller, and are never sent" do
    {_listen, port} = listen()
    client = client(port)
    assert_raise ArgumentError, fn -> Client.read_holding_registers(client, 1, 0, 126) end
    assert_raise ArgumentError, fn -> Client.read_coils(client, 256, 0, 1) end

    assert_raise ArgumentError, fn ->
      Client.request(client, 1, {:read_coils, 0, 1}, timeout: 0)
    end

    assert_raise ArgumentError, fn -> Client.start_link(tcp: "x", rtu: "/dev/x") end
    assert_raise ArgumentError, fn -> Client.start_link(tcp: "x", speed: 9600) end
    assert_raise ArgumentError, fn -> Client.start_link(tcp: "x", check_unit: :no) end
    assert_raise ArgumentError, fn -> Client.start_link(rtu: "/dev/x", check_unit: false) end
    assert_raise ArgumentError, fn -> Client.start_link(tls: "x") end
    assert_raise ArgumentError, fn -> Client.start_link(tcp: "x", ssl: [verify: :verify_none]) end
  end

  test "many callers share a client" do
    {:ok, memory} = Modbus.Memory.start_link()
    {:ok, server} = Modbus.Server.start_link(port: 0, handler: {Modbus.Memory, memory})
    client = client(Modbus.Server.port(server), max_pending: 8)

    1..200
    |> Task.async_stream(fn i ->
      :ok = Client.write_single_register(client, 1, i, i * 3)
      Client.read_holding_registers(client, 1, i, 1)
    end)
    |> Enum.with_index(1)
    |> Enum.each(fn {{:ok, result}, i} -> assert result == {:ok, [i * 3]} end)
  end

  test "device identification over as many requests as it takes" do
    long = String.duplicate("x", 200)
    objects = %{0 => "Acme", 1 => "PD-100", 2 => "2.11", 3 => long, 4 => long, 0x80 => "secret"}

    {:ok, server} =
      Modbus.Server.start_link(port: 0, handler: fn _, _ -> :ok end, identification: objects)

    client = client(Modbus.Server.port(server))

    assert Client.read_device_identification(client, 1) ==
             {:ok, Map.take(objects, [0, 1, 2])}

    assert Client.read_device_identification(client, 1, :regular) ==
             {:ok, Map.take(objects, [0, 1, 2, 3, 4])}

    assert Client.read_device_identification(client, 1, :extended) == {:ok, objects}

    assert {:ok, %{conformity_level: 0x83, objects: [{4, ^long}], more_follows: false}} =
             Client.request(client, 1, {:read_device_identification, :individual, 4})

    assert Client.request(client, 1, {:read_device_identification, :individual, 9}) ==
             {:error, {:exception, :illegal_data_address}}
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end
end
