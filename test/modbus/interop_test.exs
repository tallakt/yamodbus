defmodule Modbus.InteropTest do
  # Against pymodbus, a Python stack written independently of this one, in a process of its own.
  # Run with PYMODBUS_PYTHON set; see test_helper.exs.
  use ExUnit.Case, async: true

  alias Modbus.{Client, Memory, Server}
  alias Modbus.Test.Pty

  @moduletag :interop
  @peer Path.expand("../support/pymodbus_peer.py", __DIR__)
  @rsa [key: {:rsa, 2048, 65537}, digest: :sha256]
  @san {:Extension, {2, 5, 29, 17}, false, [{:iPAddress, <<127, 0, 0, 1>>}]}

  # What the peer's client prints, against a Memory.
  @expected [
    "write_registers ok ",
    "read_holding_registers ok 1 2 3",
    "write_register ok ",
    "mask_write_register ok ",
    "read_holding_registers ok 23",
    "write_coils ok ",
    "read_coils ok 1 0 1 0 0 0 0 0",
    "write_coil ok ",
    "read_coils ok 1 0 0 0 0 0 0 0",
    "readwrite_registers ok 7 8",
    "read_input_registers ok 0 0",
    "read_discrete_inputs ok 0 0 0 0 0 0 0 0",
    "read_holding_registers exception 2"
  ]

  defp python, do: System.get_env("PYMODBUS_PYTHON")

  defp peer_server(args) do
    port =
      Port.open({:spawn_executable, python()}, [
        :binary,
        :stderr_to_stdout,
        args: [@peer, "server" | args]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["#{os_pid}"]) end)
    ready(port, "")
  end

  defp ready(port, output) do
    if output =~ "ready" do
      :ok
    else
      receive do
        {^port, {:data, data}} -> ready(port, output <> data)
      after
        10_000 -> flunk("pymodbus didn't start: #{output}")
      end
    end
  end

  defp peer_client(args) do
    {output, 0} = System.cmd(python(), [@peer, "client" | args], stderr_to_stdout: true)
    output |> String.split("\n") |> Enum.filter(&String.contains?(&1, [" ok", " exception"]))
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

  # What our client gets from the peer's server.
  defp check_client(client) do
    assert Client.read_holding_registers(client, 1, 0, 3) == {:ok, [1000, 1001, 1002]}
    assert Client.read_input_registers(client, 1, 98, 2) == {:ok, [2098, 2099]}
    assert Client.read_coils(client, 1, 0, 4) == {:ok, [true, false, false, true]}
    assert :ok = Client.write_multiple_registers(client, 1, 50, [5, 6])
    assert Client.read_holding_registers(client, 1, 50, 2) == {:ok, [5, 6]}
    assert :ok = Client.write_single_coil(client, 1, 1, true)
    assert Client.read_coils(client, 1, 1, 1) == {:ok, [true]}
    assert :ok = Client.mask_write_register(client, 1, 60, 0xFF00, 0x0012)
    assert Client.read_write_multiple_registers(client, 1, 70, 2, 70, [9, 10]) == {:ok, [9, 10]}

    assert Client.read_holding_registers(client, 1, 999, 1) ==
             {:error, {:exception, :illegal_data_address}}

    assert Client.read_device_identification(client, 1) ==
             {:ok, %{0 => "pymodbus", 1 => "PM", 2 => "3.15"}}
  end

  describe "TCP" do
    test "our client, pymodbus's server" do
      port = free_port()
      peer_server(["tcp", "#{port}"])
      check_client(start_supervised!({Client, tcp: "127.0.0.1", port: port}))
    end

    test "pymodbus's client, our server" do
      server = memory_server(port: 0, address: {127, 0, 0, 1})
      assert peer_client(["tcp", "#{Server.port(server)}"]) == @expected
    end
  end

  for mode <- [:rtu, :ascii] do
    describe "#{mode}" do
      @describetag :socat

      test "our client, pymodbus's server" do
        {a, b} = Pty.pair()
        peer_server(["#{unquote(mode)}", b])
        check_client(start_supervised!({Client, [{unquote(mode), a}, timeout: 2000]}))
      end

      test "pymodbus's client, our server" do
        {a, b} = Pty.pair()
        memory_server([{unquote(mode), b}, units: [1]])
        assert peer_client(["#{unquote(mode)}", a]) == @expected
      end
    end
  end

  describe "TLS" do
    setup %{tmp_dir: dir} do
      pki =
        :public_key.pkix_test_data(%{
          server_chain: %{root: @rsa, intermediates: [], peer: @rsa ++ [extensions: [@san]]},
          client_chain: %{root: @rsa, intermediates: [], peer: @rsa}
        })

      files =
        for {side, config} <- [server: pki.server_config, client: pki.client_config], into: %{} do
          {:RSAPrivateKey, key} = config[:key]
          cert = pem(dir, "#{side}.pem", [{:Certificate, config[:cert], :not_encrypted}])
          key = pem(dir, "#{side}.key", [{:RSAPrivateKey, key, :not_encrypted}])

          ca =
            pem(
              dir,
              "#{side}-ca.pem",
              for(der <- config[:cacerts], do: {:Certificate, der, :not_encrypted})
            )

          {side, [cert, key, ca]}
        end

      %{pki: pki, files: files}
    end

    @tag :tmp_dir
    test "our client, pymodbus's server", %{pki: pki, files: files} do
      port = free_port()
      peer_server(["tls", "#{port}" | files.server])

      check_client(
        start_supervised!({Client, tls: "127.0.0.1", port: port, ssl: pki.client_config})
      )
    end

    @tag :tmp_dir
    test "pymodbus's client, our server", %{pki: pki, files: files} do
      server = memory_server(port: 0, address: {127, 0, 0, 1}, ssl: pki.server_config)
      assert peer_client(["tls", "#{Server.port(server)}" | files.client]) == @expected
    end
  end

  defp pem(dir, name, entries) do
    path = Path.join(dir, name)
    File.write!(path, :public_key.pem_encode(entries))
    path
  end
end
