defmodule Modbus.SerialTest do
  use ExUnit.Case, async: true

  alias Modbus.{Client, Memory, PDU, RTU, Server}
  alias Modbus.Test.Pty

  @moduletag :socat

  defp line(mode, server_opts \\ [], client_opts \\ [], client? \\ true) do
    {a, b} = Pty.pair()
    memory = start_supervised!({Memory, holding_registers: 100, coils: 100}, id: make_ref())

    server =
      start_supervised!(
        {Server, [{mode, b}, units: [3], handler: {Memory, memory}] ++ server_opts},
        id: make_ref()
      )

    client =
      if client?,
        do: start_supervised!({Client, [{mode, a}, timeout: 1000] ++ client_opts}, id: make_ref())

    %{client: client, server: server, memory: memory, a: a}
  end

  for mode <- [:rtu, :ascii] do
    describe "#{mode}" do
      test "reads and writes" do
        %{client: client, memory: memory} = line(unquote(mode))
        assert :ok = Client.write_multiple_registers(client, 3, 10, [1, 2, 3])
        assert {:ok, [1, 2, 3]} = Client.read_holding_registers(client, 3, 10, 3)
        assert :ok = Client.write_single_coil(client, 3, 7, true)
        assert Memory.get(memory, :coil, 7) == [true]

        assert Client.read_holding_registers(client, 3, 99, 2) ==
                 {:error, {:exception, :illegal_data_address}}

        # one at a time on the line, each waiting its turn within its timeout
        refs =
          for i <- 1..10,
              do: Client.send_request(client, 3, {:write_single_register, i, i}, timeout: 5000)

        for ref <- refs, do: assert_receive({Client, ^ref, :ok}, 6000)
        assert {:ok, Enum.to_list(1..10)} == Client.read_holding_registers(client, 3, 1, 10)
      end

      test "a unit the server doesn't have gets no answer" do
        %{client: client} = line(unquote(mode))
        assert Client.read_holding_registers(client, 9, 0, 1, timeout: 300) == {:error, :timeout}
        assert {:ok, [0]} = Client.read_holding_registers(client, 3, 0, 1)
      end

      test "a broadcast write is acted on, and not answered" do
        %{client: client, memory: memory} = line(unquote(mode), [], turnaround: 50)
        assert Client.write_single_register(client, 0, 5, 77) == :ok
        Process.sleep(50)
        assert Memory.get(memory, :holding_register, 5) == [77]
        assert Client.request(client, 3, {:diagnostics, 0x0F, [0]}) == {:ok, [1]}
      end
    end
  end

  test "units a serial line doesn't have, and broadcast reads" do
    %{client: client} = line(:rtu)
    assert Client.read_holding_registers(client, 248, 0, 1) == {:error, :invalid_unit}
    assert Client.read_holding_registers(client, 0, 0, 1) == {:error, :invalid_unit}
  end

  test "diagnostics: the counters" do
    %{client: client} = line(:rtu)
    assert Client.request(client, 3, {:diagnostics, 0, [0xA537, 1]}) == {:ok, [0xA537, 1]}
    assert {:error, {:exception, _}} = Client.read_holding_registers(client, 3, 99, 2)
    assert Client.read_holding_registers(client, 9, 0, 1, timeout: 300) == {:error, :timeout}

    # The bus messages it heard: the three requests (it doesn't hear its own answers) and this one;
    # to this server, three and the next one; one exception.
    assert Client.request(client, 3, {:diagnostics, 0x0B, [0]}) == {:ok, [4]}
    assert Client.request(client, 3, {:diagnostics, 0x0E, [0]}) == {:ok, [4]}
    assert Client.request(client, 3, {:diagnostics, 0x0D, [0]}) == {:ok, [1]}
    assert Client.request(client, 3, {:diagnostics, 0x0C, [0]}) == {:ok, [0]}
    assert Client.request(client, 3, {:diagnostics, 0x0A, [0]}) == {:ok, [0]}
    assert Client.request(client, 3, {:diagnostics, 0x0D, [0]}) == {:ok, [0]}
    assert Client.request(client, 3, {:diagnostics, 2, [0]}) == {:ok, [0]}

    assert Client.request(client, 3, {:diagnostics, 0x0B, [1]}) ==
             {:error, {:exception, :illegal_data_value}}

    assert Client.request(client, 3, {:diagnostics, 99, [0]}) ==
             {:error, {:exception, :illegal_function}}

    # Change ASCII Input Delimiter means nothing on RTU.
    assert Client.request(client, 3, {:diagnostics, 3, [0x2100]}) ==
             {:error, {:exception, :illegal_function}}
  end

  test "an ASCII server won't take a delimiter that comes inside frames" do
    %{client: client} = line(:ascii)

    for char <- [?0, ?A, ?f, ?:, ?\r] do
      assert Client.request(client, 3, {:diagnostics, 3, [char * 256]}) ==
               {:error, {:exception, :illegal_data_value}}
    end

    assert {:ok, [0]} = Client.read_holding_registers(client, 3, 0, 1)
  end

  test "Restart Communications Option puts the ASCII delimiter back to a line feed" do
    %{a: a} = line(:ascii, [], [], false)
    {:ok, uart} = Circuits.UART.start_link()
    :ok = Circuits.UART.open(uart, a, speed: 19200, data_bits: 7, parity: :even, active: true)

    send_frame = fn pdu, delimiter ->
      Circuits.UART.write(uart, Modbus.ASCII.encode(3, pdu, delimiter))
    end

    send_frame.(PDU.encode_request({:diagnostics, 3, [?! * 256]}), ?\n)
    assert receive_until(uart, ?\n) =~ ~r/^:03080003/
    send_frame.(PDU.encode_request({:diagnostics, 1, [0]}), ?!)
    assert receive_until(uart, ?\n) =~ ~r/^:03080001/
    send_frame.(PDU.encode_request({:read_holding_registers, 0, 1}), ?\n)
    assert receive_until(uart, ?\n) == Modbus.ASCII.encode(3, <<3, 2, 0, 0>>)
  end

  test "authorize: decides on the diagnostics a serial server answers itself" do
    allowed? = fn nil, _unit, request ->
      not match?({:diagnostics, _, _}, request) and request != :get_comm_event_log
    end

    %{client: client} = line(:rtu, authorize: allowed?)

    assert Client.request(client, 3, {:diagnostics, 4, [0]}) ==
             {:error, {:exception, :illegal_function}}

    assert Client.request(client, 3, :get_comm_event_log) ==
             {:error, {:exception, :illegal_function}}

    # not in listen only mode
    assert {:ok, [0]} = Client.read_holding_registers(client, 3, 0, 1)
    assert {:ok, %{status: 0}} = Client.request(client, 3, :get_comm_event_counter)
  end

  test "an adapter's echo is never taken for the device's answer" do
    {a, b} = Pty.pair()
    {:ok, device} = Circuits.UART.start_link()
    :ok = Circuits.UART.open(device, b, speed: 19200, active: true)

    for echo <- [true, false] do
      id = make_ref()
      client = start_supervised!({Client, rtu: a, echo: echo, timeout: 300}, id: id)
      # the adapter echoes the request, and the device is dead
      task = Task.async(fn -> Client.write_single_register(client, 3, 1, 7) end)
      Circuits.UART.write(device, receive_bytes(device, 8))
      result = Task.await(task)
      if echo, do: assert(result == {:error, :timeout}), else: assert(result == :ok)
      stop_supervised!(id)
    end
  end

  test "an adapter's echo, then the device's answer" do
    {a, b} = Pty.pair()
    {:ok, device} = Circuits.UART.start_link()
    :ok = Circuits.UART.open(device, b, speed: 19200, active: true)
    client = start_supervised!({Client, rtu: a, echo: true})

    task = Task.async(fn -> Client.read_holding_registers(client, 3, 0, 1) end)
    request = receive_bytes(device, 8)
    Circuits.UART.write(device, request <> RTU.encode(3, <<3, 2, 0, 42>>))
    assert Task.await(task) == {:ok, [42]}
  end

  test "an ASCII server told to end frames with another character" do
    %{client: client} = line(:ascii)
    assert Client.request(client, 3, {:diagnostics, 3, [?! * 256]}) == {:ok, [?! * 256]}
    # This client ends its frames with a line feed, which the server no longer looks for.
    assert Client.read_holding_registers(client, 3, 0, 1, timeout: 300) == {:error, :timeout}
  end

  test "listen only mode, until a restart" do
    %{client: client} = line(:rtu)
    assert Client.request(client, 3, {:diagnostics, 4, [0]}, timeout: 300) == {:error, :timeout}
    assert Client.read_holding_registers(client, 3, 0, 1, timeout: 300) == {:error, :timeout}
    assert Client.request(client, 3, {:diagnostics, 1, [0]}, timeout: 300) == {:error, :timeout}
    assert {:ok, [0]} = Client.read_holding_registers(client, 3, 0, 1)

    # Newest first: this request, the read, the restart and its request, the read in listen only
    # mode, entering it, and the request that did.
    assert {:ok, %{events: [0x80, 0x40, 0x80, 0x00, 0xA0, 0xA0, 0x04, 0x80]}} =
             Client.request(client, 3, :get_comm_event_log)
  end

  test "the comm event counter and log" do
    %{client: client} = line(:rtu)
    {:ok, _} = Client.read_holding_registers(client, 3, 0, 1)
    {:ok, _} = Client.read_holding_registers(client, 3, 0, 1)
    {:error, _} = Client.read_holding_registers(client, 3, 99, 2)

    assert Client.request(client, 3, :get_comm_event_counter) ==
             {:ok, %{status: 0, event_count: 2}}

    assert {:ok, log} = Client.request(client, 3, :get_comm_event_log)
    assert %{status: 0, event_count: 2, message_count: 5} = log
    # Newest first: this request's receive, then the counter's send and receive, the exception's
    # send (a read exception) and receive, and so on.
    assert [0x80, 0x40, 0x80, 0x41, 0x80, 0x40, 0x80, 0x40, 0x80] = log.events
  end

  test "the server passes over noise and finds the frame after it" do
    %{a: a} = line(:rtu, [], [], false)
    {:ok, uart} = Circuits.UART.start_link()
    :ok = Circuits.UART.open(uart, a, speed: 19200, active: true)

    frame = RTU.encode(3, PDU.encode_request({:read_holding_registers, 0, 1}))
    Circuits.UART.write(uart, <<0x11, 0x55, 0xFF>> <> frame)
    assert receive_bytes(uart, 7) == RTU.encode(3, <<3, 2, 0, 0>>)
  end

  test "a device that isn't there" do
    client = start_supervised!({Client, rtu: "/dev/no_such_tty", backoff: {50, 50}})
    assert Client.read_holding_registers(client, 1, 0, 1) == {:error, :closed}
    assert {:disconnected, _reason} = Client.status(client)
  end

  defp receive_until(uart, delimiter, buffer \\ <<>>) do
    if String.contains?(buffer, <<delimiter>>) do
      buffer
    else
      receive do
        {:circuits_uart, _, data} when is_binary(data) ->
          receive_until(uart, delimiter, buffer <> data)
      after
        1000 -> buffer
      end
    end
  end

  defp receive_bytes(uart, n, buffer \\ <<>>) do
    if byte_size(buffer) >= n do
      buffer
    else
      receive do
        {:circuits_uart, _, data} when is_binary(data) -> receive_bytes(uart, n, buffer <> data)
      after
        1000 -> buffer
      end
    end
  end
end
