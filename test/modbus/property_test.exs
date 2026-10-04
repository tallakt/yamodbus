defmodule Modbus.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Modbus.{ASCII, Client, Memory, PDU, RTU, Server, TCP}

  # Each property runs a hundred or more cases, FUZZ_RUNS cases, or for FUZZ_SECONDS:
  #
  #     FUZZ_RUNS=10000 mix test test/modbus/property_test.exs
  #     FUZZ_SECONDS=600 mix test test/modbus/property_test.exs
  @moduletag timeout: :infinity

  defp runs(n) do
    cond do
      System.get_env("FUZZ_SECONDS") -> 1_000_000_000
      runs = System.get_env("FUZZ_RUNS") -> String.to_integer(runs)
      true -> n
    end
  end

  defp run_time do
    if seconds = System.get_env("FUZZ_SECONDS"), do: String.to_integer(seconds) * 1000
  end

  defp address, do: integer(0..65535)
  defp word, do: integer(0..65535)
  defp words(min, max), do: list_of(word(), min_length: min, max_length: max)
  defp bits(min, max), do: list_of(boolean(), min_length: min, max_length: max)

  defp file_group(values) do
    bind(integer(1..65535), fn file ->
      bind(values, fn {count, value} ->
        map(integer(0..(10_000 - count)), &{file, &1, value})
      end)
    end)
  end

  # Every request the protocol can carry, within its limits.
  defp request do
    one_of([
      map({address(), integer(1..2000)}, fn {a, n} -> {:read_coils, a, n} end),
      map({address(), integer(1..2000)}, fn {a, n} -> {:read_discrete_inputs, a, n} end),
      map({address(), integer(1..125)}, fn {a, n} -> {:read_holding_registers, a, n} end),
      map({address(), integer(1..125)}, fn {a, n} -> {:read_input_registers, a, n} end),
      map({address(), boolean()}, fn {a, v} -> {:write_single_coil, a, v} end),
      map({address(), word()}, fn {a, v} -> {:write_single_register, a, v} end),
      map({address(), bits(1, 1968)}, fn {a, v} -> {:write_multiple_coils, a, v} end),
      map({address(), words(1, 123)}, fn {a, v} -> {:write_multiple_registers, a, v} end),
      map({address(), word(), word()}, fn {a, x, y} -> {:mask_write_register, a, x, y} end),
      map({address(), integer(1..125), address(), words(1, 121)}, fn {r, n, w, v} ->
        {:read_write_multiple_registers, r, n, w, v}
      end),
      map(address(), &{:read_fifo_queue, &1}),
      map(
        list_of(file_group(map(integer(1..10), &{&1, &1})), min_length: 1, max_length: 5),
        &{:read_file_record, &1}
      ),
      map(
        list_of(file_group(map(words(1, 10), &{length(&1), &1})), min_length: 1, max_length: 5),
        &{:write_file_record, &1}
      ),
      map({member_of([:basic, :regular, :extended, :individual]), integer(0..255)}, fn {c, o} ->
        {:read_device_identification, c, o}
      end),
      constant(:read_exception_status),
      map({member_of([1, 2, 3, 4, 10, 11, 12, 13, 14, 15, 16, 17, 18, 20]), word()}, fn {s, w} ->
        {:diagnostics, s, [w]}
      end),
      map({member_of([0, 5, 19, 21, 65535]), words(0, 10)}, fn {s, d} -> {:diagnostics, s, d} end),
      constant(:get_comm_event_counter),
      constant(:get_comm_event_log),
      constant(:report_server_id),
      map({member_of([13, 0, 15, 255]), binary(max_length: 20)}, fn {m, d} ->
        {:encapsulated_interface_transport, m, d}
      end),
      map({member_of([65, 72, 100, 110, 9, 127]), binary(max_length: 20)}, fn {f, d} ->
        {:custom, f, d}
      end)
    ])
  end

  # A result that answers a request.
  defp result({kind, _, n}) when kind in [:read_coils, :read_discrete_inputs],
    do: map(bits(n, n), &{:ok, &1})

  defp result({kind, _, n}) when kind in [:read_holding_registers, :read_input_registers],
    do: map(words(n, n), &{:ok, &1})

  defp result({:read_write_multiple_registers, _, n, _, _}), do: map(words(n, n), &{:ok, &1})
  defp result({:read_fifo_queue, _}), do: map(words(0, 31), &{:ok, &1})

  defp result({:read_file_record, groups}),
    do: fixed_list(for({_, _, n} <- groups, do: words(n, n))) |> map(&{:ok, &1})

  defp result(:read_exception_status), do: map(integer(0..255), &{:ok, &1})

  defp result({:diagnostics, sub, [_]})
       when sub in [1, 2, 3, 4, 10, 11, 12, 13, 14, 15, 16, 17, 18, 20],
       do: map(word(), &{:ok, [&1]})

  # Return Query Data is answered with its own data.
  defp result({:diagnostics, 0, data}), do: constant({:ok, data})
  defp result({:diagnostics, _, _}), do: map(words(0, 10), &{:ok, &1})

  defp result(:get_comm_event_counter),
    do: map({word(), word()}, fn {s, c} -> {:ok, %{status: s, event_count: c}} end)

  defp result(:get_comm_event_log) do
    map({word(), word(), word(), list_of(integer(0..255), max_length: 64)}, fn {s, e, m, l} ->
      {:ok, %{status: s, event_count: e, message_count: m, events: l}}
    end)
  end

  defp result(:report_server_id), do: map(binary(max_length: 40), &{:ok, &1})

  defp result({:read_device_identification, _, _}) do
    objects = list_of({integer(0..255), binary(max_length: 20)}, max_length: 8)

    map({integer(0..255), boolean(), integer(0..255), objects}, fn {l, m, n, o} ->
      {:ok, %{conformity_level: l, more_follows: m, next_object_id: n, objects: o}}
    end)
  end

  defp result({kind, _, _}) when kind in [:encapsulated_interface_transport, :custom],
    do: map(binary(max_length: 40), &{:ok, &1})

  defp result(_write), do: constant(:ok)

  defp exception,
    do:
      map(
        member_of([1, 2, 3, 4, 5, 6, 8, 10, 11, 7, 99]),
        &{:error, {:exception, Modbus.exception_name(&1)}}
      )

  property "every request survives encoding and decoding" do
    check all request <- request(), max_runs: runs(100), max_run_time: run_time() do
      pdu = PDU.encode_request(request)
      assert byte_size(pdu) <= 253
      assert PDU.decode_request(pdu) == {:ok, request}
      assert PDU.request_length(pdu) in [{:ok, byte_size(pdu)}, :unknown]
    end
  end

  property "every result survives encoding and decoding" do
    check all request <- request(),
              result <- one_of([result(request), exception()]),
              max_runs: runs(100),
              max_run_time: run_time() do
      pdu = PDU.encode_response(request, result)
      assert byte_size(pdu) <= 253
      assert PDU.decode_response(request, pdu) == result
      assert PDU.response_length(request, pdu) in [{:ok, byte_size(pdu)}, :unknown]
    end
  end

  property "any bytes decode to a request or an exception, and never raise" do
    check all pdu <- binary(max_length: 260), max_runs: runs(2000), max_run_time: run_time() do
      case PDU.decode_request(pdu) do
        {:ok, request} ->
          assert PDU.decode_request(PDU.encode_request(request)) == {:ok, request}

        {:error, exception} ->
          assert exception in [:illegal_function, :illegal_data_value, :illegal_data_address]
      end
    end
  end

  property "any bytes decode to a result for any request, and never raise" do
    check all request <- request(),
              pdu <- binary(max_length: 260),
              max_runs: runs(100),
              max_run_time: run_time() do
      assert match?({:ok, _}, PDU.decode_response(request, pdu)) or
               match?(:ok, PDU.decode_response(request, pdu)) or
               match?({:error, _}, PDU.decode_response(request, pdu))
    end
  end

  property "the framings never raise on any bytes" do
    check all bytes <- binary(max_length: 600), max_runs: runs(1000), max_run_time: run_time() do
      TCP.decode(bytes)
      RTU.decode(bytes)
      RTU.split(bytes, [&PDU.request_length/1, &PDU.response_length(nil, &1)])
      ASCII.decode(bytes)
      ASCII.split(bytes, ?\n)
    end
  end

  property "frames split anywhere come back whole, over TCP, RTU and ASCII" do
    check all requests <- list_of(request(), min_length: 1, max_length: 6),
              cuts <- list_of(integer(1..40), max_length: 10),
              max_runs: runs(100),
              max_run_time: run_time() do
      pdus = Enum.map(requests, &PDU.encode_request/1)

      tcp = pdus |> Enum.with_index() |> Enum.map(fn {pdu, i} -> TCP.encode(i, 1, pdu) end)
      assert reassemble(chunks(Enum.join(tcp), cuts), &tcp_frame/1) == tcp

      known = Enum.reject(pdus, &(PDU.request_length(&1) == :unknown))
      rtu = Enum.map(known, &RTU.encode(1, &1))
      assert reassemble(chunks(Enum.join(rtu), cuts), &rtu_frame/1) == rtu

      ascii = Enum.map(pdus, &ASCII.encode(1, &1))
      assert reassemble(chunks(Enum.join(ascii), cuts), &ascii_frame/1) == ascii
    end
  end

  defp chunks(bytes, []), do: [bytes]

  defp chunks(bytes, [cut | cuts]) do
    if cut >= byte_size(bytes) do
      [bytes]
    else
      <<chunk::binary-size(cut), rest::binary>> = bytes
      [chunk | chunks(rest, cuts)]
    end
  end

  defp reassemble(chunks, frame) do
    {frames, <<>>} =
      Enum.reduce(chunks, {[], <<>>}, fn chunk, {frames, buffer} ->
        {new, rest} = take(buffer <> chunk, frame, [])
        {frames ++ new, rest}
      end)

    frames
  end

  defp take(buffer, frame, frames) do
    case frame.(buffer) do
      {:ok, one, rest} -> take(rest, frame, frames ++ [one])
      :more -> {frames, buffer}
    end
  end

  defp tcp_frame(buffer) do
    case TCP.decode(buffer) do
      {:ok, {_, _, pdu}, rest} ->
        {:ok, binary_part(buffer, 0, byte_size(buffer) - byte_size(rest)) |> tap(fn _ -> pdu end),
         rest}

      :more ->
        :more
    end
  end

  defp rtu_frame(buffer) do
    case RTU.split(buffer, [&PDU.request_length/1]) do
      {:ok, frame, rest} -> {:ok, frame, rest}
      :more -> :more
    end
  end

  defp ascii_frame(buffer) do
    case ASCII.split(buffer, ?\n) do
      {:ok, frame, rest} -> {:ok, frame, rest}
      :more -> :more
    end
  end

  describe "a server under fire" do
    setup do
      memory = start_supervised!({Memory, holding_registers: 100})

      server =
        start_supervised!({Server, port: 0, address: {127, 0, 0, 1}, handler: {Memory, memory}})

      %{server: server, port: Server.port(server)}
    end

    property "answers every well framed request, whatever its PDU", %{port: port} do
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

      check all pdu <- binary(min_length: 1, max_length: 253),
                max_runs: runs(500),
                max_run_time: run_time() do
        :ok = :gen_tcp.send(socket, TCP.encode(9, 1, pdu))
        assert {:ok, <<9::16, 0::16, length::16>>} = :gen_tcp.recv(socket, 6, 1000)
        assert {:ok, <<1, answer::binary>>} = :gen_tcp.recv(socket, length, 1000)
        <<function, _::binary>> = pdu
        assert <<answered, _::binary>> = answer
        assert answered in [function, Bitwise.bor(function, 0x80)]
      end
    end

    property "stays up whatever comes over a connection", %{server: server, port: port} do
      check all bytes <- binary(min_length: 1, max_length: 600),
                max_runs: runs(200),
                max_run_time: run_time() do
        socket = connect(port)
        :gen_tcp.send(socket, bytes)
        :gen_tcp.close(socket)
      end

      client = start_supervised!({Client, tcp: "127.0.0.1", port: port})
      assert {:ok, [0]} = Client.read_holding_registers(client, 1, 0, 1)
      assert Process.alive?(server)
    end
  end

  # A connection each case: closed with a reset, so it leaves no TIME_WAIT behind, and the OS's
  # ports last a run of hours. Should they run out all the same, it waits for them.
  defp connect(port, tries \\ 60) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, linger: {true, 0}]) do
      {:ok, socket} ->
        socket

      {:error, :eaddrnotavail} when tries > 0 ->
        Process.sleep(1000)
        connect(port, tries - 1)
    end
  end

  property "a client survives any answer" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    client = start_supervised!({Client, tcp: "127.0.0.1", port: port, backoff: {1, 1}})
    {:ok, socket} = :gen_tcp.accept(listen, 1000)

    check all request <- request(),
              answer <- binary(min_length: 1, max_length: 253),
              max_runs: runs(300),
              max_run_time: run_time() do
      ref = Client.send_request(client, 1, request)
      {:ok, <<transaction::16, _::32>>} = :gen_tcp.recv(socket, 6, 1000)
      {:ok, _rest} = :gen_tcp.recv(socket, 0, 1000)
      :ok = :gen_tcp.send(socket, TCP.encode(transaction, 1, answer))
      assert_receive {Client, ^ref, result}, 1000
      assert result == PDU.decode_response(request, answer)
    end

    assert Process.alive?(client)
  end
end
