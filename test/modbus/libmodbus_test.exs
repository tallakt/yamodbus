defmodule Modbus.LibmodbusTest do
  # Against libmodbus, the C library much Modbus equipment and software is built on, through
  # test/support/libmodbus_peer.c in a process of its own. Runs where pkg-config finds libmodbus;
  # see test_helper.exs.
  use ExUnit.Case, async: true

  alias Modbus.{Client, Memory, Server}
  alias Modbus.Test.Pty

  @moduletag :libmodbus

  # What the peer's client prints, against a Memory.
  @expected [
    "write_registers ok",
    "read_registers ok 1 2 3",
    "write_register ok",
    "mask_write_register ok",
    "read_registers ok 23",
    "write_bits ok",
    "read_bits ok 1 0 1",
    "write_bit ok",
    "read_bits ok 1",
    "write_and_read_registers ok 7 8",
    "read_input_registers ok 0 0",
    "read_input_bits ok 0 0",
    "read_registers error Illegal data address"
  ]

  setup_all do
    peer = Path.join(Mix.Project.build_path(), "libmodbus_peer")
    {flags, 0} = System.cmd("pkg-config", ["--cflags", "--libs", "libmodbus"])
    source = Path.expand("../support/libmodbus_peer.c", __DIR__)
    args = ["-o", peer, source] ++ String.split(flags)
    {output, status} = System.cmd("cc", args, stderr_to_stdout: true)
    if status != 0, do: flunk("can't build the libmodbus peer: #{output}")
    %{peer: peer}
  end

  defp peer_server(peer, args) do
    port =
      Port.open({:spawn_executable, peer}, [:binary, :stderr_to_stdout, args: ["server" | args]])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["#{os_pid}"]) end)

    receive do
      {^port, {:data, "ready" <> _}} -> :ok
    after
      5000 -> flunk("libmodbus didn't start")
    end
  end

  defp peer_client(peer, args) do
    {output, 0} = System.cmd(peer, ["client" | args], stderr_to_stdout: true)
    String.split(output, "\n", trim: true)
  end

  defp memory_server(opts) do
    memory = start_supervised!({Memory, holding_registers: 1000, coils: 100}, id: make_ref())
    start_supervised!({Server, [handler: {Memory, memory}] ++ opts}, id: make_ref())
  end

  defp free_port do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    port
  end

  # What our client gets from the peer's server. libmodbus answers no function it doesn't have,
  # such as Read Device Identification, so none is asked.
  defp check_client(client) do
    assert Client.read_holding_registers(client, 1, 0, 3) == {:ok, [1000, 1001, 1002]}
    assert Client.read_input_registers(client, 1, 98, 2) == {:ok, [2098, 2099]}
    assert Client.read_coils(client, 1, 0, 4) == {:ok, [true, false, false, true]}
    assert Client.read_discrete_inputs(client, 1, 0, 4) == {:ok, [true, false, true, false]}
    assert :ok = Client.write_multiple_registers(client, 1, 50, [5, 6])
    assert Client.read_holding_registers(client, 1, 50, 2) == {:ok, [5, 6]}
    assert :ok = Client.write_single_coil(client, 1, 1, true)
    assert :ok = Client.write_multiple_coils(client, 1, 10, [true, true, false])
    assert Client.read_coils(client, 1, 10, 3) == {:ok, [true, true, false]}
    assert :ok = Client.mask_write_register(client, 1, 5, 0xF2, 0x25)
    assert Client.read_holding_registers(client, 1, 5, 1) == {:ok, [0xE5]}
    assert Client.read_write_multiple_registers(client, 1, 70, 2, 70, [9, 10]) == {:ok, [9, 10]}

    assert Client.read_holding_registers(client, 1, 99, 2) ==
             {:error, {:exception, :illegal_data_address}}

    assert {:ok, <<_id, 0xFF, "LMB", _version::binary>>} =
             Client.request(client, 1, :report_server_id)
  end

  describe "TCP" do
    test "our client, libmodbus's server", %{peer: peer} do
      port = free_port()
      peer_server(peer, ["tcp", "#{port}"])
      check_client(start_supervised!({Client, tcp: "127.0.0.1", port: port}))
    end

    test "libmodbus's client, our server", %{peer: peer} do
      server = memory_server(port: 0, address: {127, 0, 0, 1})
      assert peer_client(peer, ["tcp", "#{Server.port(server)}"]) == @expected
    end
  end

  describe "RTU" do
    @describetag :socat

    test "our client, libmodbus's server", %{peer: peer} do
      {a, b} = Pty.pair()
      peer_server(peer, ["rtu", b])
      check_client(start_supervised!({Client, rtu: a, timeout: 2000}))
    end

    test "libmodbus's client, our server", %{peer: peer} do
      {a, b} = Pty.pair()
      memory_server(rtu: b, units: [1])
      assert peer_client(peer, ["rtu", a]) == @expected
    end
  end
end
