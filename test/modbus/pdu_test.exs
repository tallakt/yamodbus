defmodule Modbus.PDUTest do
  use ExUnit.Case, async: true

  alias Modbus.PDU

  # The examples of the application protocol spec, V1.1b3, one for each function: the request, its
  # PDU, the response's PDU and the result.
  @examples [
    {{:read_coils, 19, 19}, "01 0013 0013", "01 03 CD6B05",
     {:ok,
      [true, false, true, true, false, false, true, true] ++
        [true, true, false, true, false, true, true, false] ++ [true, false, true]}},
    {{:read_discrete_inputs, 196, 22}, "02 00C4 0016", "02 03 ACDB35",
     {:ok,
      [false, false, true, true, false, true, false, true] ++
        [true, true, false, true, true, false, true, true] ++
        [true, false, true, false, true, true]}},
    {{:read_holding_registers, 107, 3}, "03 006B 0003", "03 06 022B 0000 0064",
     {:ok, [555, 0, 100]}},
    {{:read_input_registers, 8, 1}, "04 0008 0001", "04 02 000A", {:ok, [10]}},
    {{:write_single_coil, 172, true}, "05 00AC FF00", "05 00AC FF00", :ok},
    {{:write_single_register, 1, 3}, "06 0001 0003", "06 0001 0003", :ok},
    {:read_exception_status, "07", "07 6D", {:ok, 0x6D}},
    {{:diagnostics, 0, [0xA537]}, "08 0000 A537", "08 0000 A537", {:ok, [0xA537]}},
    {:get_comm_event_counter, "0B", "0B FFFF 0108", {:ok, %{status: 0xFFFF, event_count: 264}}},
    {:get_comm_event_log, "0C", "0C 08 0000 0108 0121 20 00",
     {:ok, %{status: 0, event_count: 264, message_count: 289, events: [0x20, 0]}}},
    {{:write_multiple_coils, 19,
      [true, false, true, true, false, false, true, true, true, false]}, "0F 0013 000A 02 CD01",
     "0F 0013 000A", :ok},
    {{:write_multiple_registers, 1, [10, 258]}, "10 0001 0002 04 000A 0102", "10 0001 0002", :ok},
    {{:read_file_record, [{4, 1, 2}, {3, 9, 2}]}, "14 0E 06 0004 0001 0002 06 0003 0009 0002",
     "14 0C 05 06 0DFE 0020 05 06 33CD 0040", {:ok, [[0x0DFE, 0x20], [0x33CD, 0x40]]}},
    {{:write_file_record, [{4, 7, [0x06AF, 0x04BE, 0x100D]}]},
     "15 0D 06 0004 0007 0003 06AF 04BE 100D", "15 0D 06 0004 0007 0003 06AF 04BE 100D", :ok},
    {{:mask_write_register, 4, 0xF2, 0x25}, "16 0004 00F2 0025", "16 0004 00F2 0025", :ok},
    {{:read_write_multiple_registers, 3, 6, 14, [0xFF, 0xFF, 0xFF]},
     "17 0003 0006 000E 0003 06 00FF 00FF 00FF", "17 0C 00FE 0ACD 0001 0003 000D 00FF",
     {:ok, [0xFE, 0x0ACD, 1, 3, 0x0D, 0xFF]}},
    {{:read_fifo_queue, 0x04DE}, "18 04DE", "18 0006 0002 01B8 1284", {:ok, [440, 4740]}}
  ]

  for {request, request_pdu, response_pdu, result} <- @examples do
    test "#{inspect(request)} as in the spec" do
      request = unquote(Macro.escape(request))
      request_pdu = hex(unquote(request_pdu))
      response_pdu = hex(unquote(response_pdu))
      result = unquote(Macro.escape(result))

      assert PDU.encode_request(request) == request_pdu
      assert PDU.decode_request(request_pdu) == {:ok, request}
      assert PDU.decode_response(request, response_pdu) == result
      assert PDU.encode_response(request, result) == response_pdu
    end
  end

  test "read device identification as in the spec" do
    request = {:read_device_identification, :basic, 0}
    assert PDU.encode_request(request) == hex("2B 0E 01 00")
    assert PDU.decode_request(hex("2B 0E 01 00")) == {:ok, request}

    objects = [{0, "Company identification"}, {1, "Product code XX"}, {2, "V2.11"}]

    response =
      hex("2B 0E 01 01 00 00 03") <>
        <<0, 22, "Company identification", 1, 15, "Product code XX", 2, 5, "V2.11">>

    result =
      {:ok, %{conformity_level: 1, more_follows: false, next_object_id: 0, objects: objects}}

    assert PDU.decode_response(request, response) == result
    assert PDU.encode_response(request, result) == response
  end

  test "an exception response, for any function" do
    for {request, _, _, _} <- @examples do
      function = PDU.function(request)
      pdu = <<function + 0x80, 2>>
      assert PDU.decode_response(request, pdu) == {:error, {:exception, :illegal_data_address}}
      assert PDU.encode_response(request, {:error, {:exception, 2}}) == pdu
    end

    assert PDU.decode_response({:read_coils, 0, 1}, <<0x81, 7>>) == {:error, {:exception, 7}}
    # An exception PDU is two bytes, no more.
    assert {:error, {:invalid_response, _}} =
             PDU.decode_response({:read_coils, 0, 1}, <<0x81, 2, 0>>)
  end

  describe "requests a server refuses" do
    test "a function code out of range" do
      assert PDU.decode_request(<<0, 1>>) == {:error, :illegal_function}
      assert PDU.decode_request(<<0x81, 1>>) == {:error, :illegal_function}
      assert PDU.decode_request(<<>>) == {:error, :illegal_function}
    end

    test "quantities outside what the function allows" do
      for pdu <- [
            <<1, 0::16, 0::16>>,
            <<1, 0::16, 2001::16>>,
            <<2, 0::16, 2001::16>>,
            <<3, 0::16, 0::16>>,
            <<3, 0::16, 126::16>>,
            <<4, 0::16, 126::16>>,
            <<15, 0::16, 1969::16, 247, 0::1976>>,
            <<16, 0::16, 124::16, 248, 0::1984>>,
            <<23, 0::16, 126::16, 0::16, 1::16, 2, 0::16>>,
            <<23, 0::16, 1::16, 0::16, 122::16, 244, 0::1952>>
          ] do
        assert PDU.decode_request(pdu) == {:error, :illegal_data_value}, inspect(pdu)
      end
    end

    test "byte counts that don't agree with the quantity, and lengths that are off" do
      for pdu <- [
            <<1, 0::16, 1::16, 0>>,
            <<1, 0::16>>,
            <<5, 0::16, 0x1234::16>>,
            <<6, 0::16>>,
            <<7, 0>>,
            <<8, 0::16, 1>>,
            <<15, 0::16, 10::16, 1, 0>>,
            <<15, 0::16, 10::16, 2, 0>>,
            <<16, 0::16, 2::16, 3, 0, 0, 0>>,
            <<16, 0::16, 2::16, 4, 0, 0, 0>>,
            <<20, 6, 6, 0, 1, 0, 0, 0>>,
            <<20, 7, 6, 0, 1, 0, 0, 0, 0>>,
            <<21, 9, 6, 0, 1, 0, 0, 0, 2, 0, 0>>,
            <<22, 0::16, 0::16>>,
            <<24, 0>>,
            <<43, 14, 5, 0>>,
            <<43, 14, 1>>,
            <<43>>
          ] do
        assert PDU.decode_request(pdu) == {:error, :illegal_data_value}, inspect(pdu)
      end
    end

    test "file records that aren't there" do
      # reference type 7, file 0, and record 9999 + 2
      assert PDU.decode_request(<<20, 7, 7, 1::16, 0::16, 1::16>>) ==
               {:error, :illegal_data_address}

      assert PDU.decode_request(<<20, 7, 6, 0::16, 0::16, 1::16>>) ==
               {:error, :illegal_data_address}

      assert PDU.decode_request(<<20, 7, 6, 1::16, 9999::16, 2::16>>) ==
               {:error, :illegal_data_address}

      assert PDU.decode_request(<<21, 9, 6, 0::16, 0::16, 1::16, 5::16>>) ==
               {:error, :illegal_data_address}
    end

    test "function codes the spec doesn't define are the handler's" do
      assert PDU.decode_request(<<100, 1, 2, 3>>) == {:ok, {:custom, 100, <<1, 2, 3>>}}
      assert PDU.decode_request(<<9>>) == {:ok, {:custom, 9, <<>>}}

      assert PDU.decode_request(<<43, 13, 1, 2>>) ==
               {:ok, {:encapsulated_interface_transport, 13, <<1, 2>>}}
    end
  end

  describe "responses a client refuses" do
    test "the wrong function code" do
      assert PDU.decode_response({:read_coils, 0, 8}, <<2, 1, 0>>) ==
               {:error, {:invalid_response, <<2, 1, 0>>}}
    end

    test "the wrong count of values" do
      for {request, pdu} <- [
            {{:read_coils, 0, 9}, <<1, 1, 0>>},
            {{:read_coils, 0, 8}, <<1, 1, 0, 0>>},
            {{:read_holding_registers, 0, 2}, <<3, 2, 0, 0>>},
            {{:read_holding_registers, 0, 2}, <<3, 4, 0, 0, 0>>},
            {{:read_write_multiple_registers, 0, 2, 0, [1]}, <<23, 2, 0, 0>>},
            {{:read_fifo_queue, 0}, <<24, 0, 6, 0, 1, 0, 0>>},
            {{:read_fifo_queue, 0}, <<24, 0, 66, 0, 32, 0::512>>},
            {{:read_file_record, [{1, 0, 2}]}, <<20, 4, 3, 6, 0, 0>>},
            {{:read_file_record, [{1, 0, 1}, {1, 5, 1}]}, <<20, 4, 3, 6, 0, 0>>},
            {:get_comm_event_log, <<12, 7, 0::48>>},
            {:report_server_id, <<17, 3, 1, 2>>}
          ] do
        assert PDU.decode_response(request, pdu) == {:error, {:invalid_response, pdu}},
               inspect(pdu)
      end
    end

    test "a write echoed wrong" do
      assert {:error, {:invalid_response, _}} =
               PDU.decode_response({:write_single_register, 1, 3}, <<6, 0, 1, 0, 4>>)

      assert {:error, {:invalid_response, _}} =
               PDU.decode_response({:write_single_coil, 1, true}, <<5, 0, 1, 0, 0>>)

      assert {:error, {:invalid_response, _}} =
               PDU.decode_response({:write_multiple_registers, 1, [1, 2]}, <<16, 0, 1, 0, 3>>)

      assert {:error, {:invalid_response, _}} =
               PDU.decode_response({:mask_write_register, 4, 1, 2}, <<22, 0, 4, 0, 1, 0, 3>>)
    end

    test "diagnostics answered for another sub-function" do
      assert {:error, {:invalid_response, _}} =
               PDU.decode_response({:diagnostics, 11, [0]}, <<8, 0, 12, 0, 5>>)

      assert PDU.decode_response({:diagnostics, 11, [0]}, <<8, 0, 11, 0, 5>>) == {:ok, [5]}
    end

    test "device identification that doesn't add up" do
      request = {:read_device_identification, :basic, 0}
      # two objects said, one given; then one object longer than the PDU
      for pdu <- [
            <<43, 14, 1, 1, 0, 0, 2, 0, 1, ?A>>,
            <<43, 14, 1, 1, 0, 0, 1, 0, 9, ?A>>,
            <<43, 14, 2, 1, 0, 0, 0>>
          ] do
        assert PDU.decode_response(request, pdu) == {:error, {:invalid_response, pdu}}
      end
    end
  end

  describe "requests that can't be sent" do
    test "raise in the caller" do
      for request <- [
            {:read_coils, 0, 0},
            {:read_coils, 0, 2001},
            {:read_holding_registers, -1, 1},
            {:read_holding_registers, 65536, 1},
            {:read_holding_registers, 0, 126},
            {:write_single_coil, 0, 1},
            {:write_single_register, 0, 65536},
            {:write_multiple_coils, 0, []},
            {:write_multiple_coils, 0, List.duplicate(true, 1969)},
            {:write_multiple_coils, 0, [true, :maybe]},
            {:write_multiple_registers, 0, List.duplicate(0, 124)},
            {:write_multiple_registers, 0, [1.5]},
            {:read_write_multiple_registers, 0, 1, 0, List.duplicate(0, 122)},
            {:read_file_record, []},
            {:read_file_record, [{0, 0, 1}]},
            {:read_file_record, [{1, 9999, 2}]},
            {:read_file_record, [{1, 0, 200}]},
            {:read_device_identification, :everything, 0},
            {:encapsulated_interface_transport, 14, <<>>},
            {:custom, 128, <<>>},
            {:diagnostics, 0, [70_000]},
            :nonsense
          ] do
        assert_raise ArgumentError, fn -> PDU.encode_request(request) end
      end
    end
  end

  describe "results a handler gets wrong" do
    test "raise, for the server to answer with a server device failure" do
      for {request, result} <- [
            {{:read_coils, 0, 2}, {:ok, [true]}},
            {{:read_holding_registers, 0, 1}, {:ok, [70_000]}},
            {{:read_holding_registers, 0, 1}, :ok},
            {{:write_single_coil, 0, true}, {:ok, true}},
            {{:read_fifo_queue, 0}, {:ok, List.duplicate(0, 32)}},
            {{:read_file_record, [{1, 0, 2}]}, {:ok, [[1]]}},
            {:report_server_id, {:ok, :binary.copy(<<0>>, 252)}},
            {{:read_holding_registers, 0, 1}, {:error, {:exception, :no_such_thing}}},
            {{:read_holding_registers, 0, 1}, {:error, :timeout}}
          ] do
        assert_raise ArgumentError, fn -> PDU.encode_response(request, result) end
      end
    end
  end

  test "the lengths of frames on a serial line" do
    assert PDU.request_length(<<3>>) == {:ok, 5}
    assert PDU.request_length(<<16, 0, 1, 0, 2>>) == :more
    assert PDU.request_length(<<16, 0, 1, 0, 2, 4>>) == {:ok, 10}
    assert PDU.request_length(<<8, 0, 0>>) == :unknown
    assert PDU.request_length(<<8, 0, 11>>) == {:ok, 5}
    assert PDU.request_length(<<100>>) == :unknown

    assert PDU.response_length(nil, <<0x83>>) == {:ok, 2}
    assert PDU.response_length(nil, <<3, 6>>) == {:ok, 8}
    assert PDU.response_length(nil, <<24, 0, 6>>) == {:ok, 9}
    assert PDU.response_length({:diagnostics, 0, [1, 2]}, <<8>>) == {:ok, 7}
    assert PDU.response_length(nil, <<43, 14, 1, 1, 0, 0, 1, 0, 3>>) == :more
    assert PDU.response_length(nil, <<43, 14, 1, 1, 0, 0, 1, 0, 2, ?a, ?b>>) == {:ok, 11}
    assert PDU.response_length(nil, <<43, 13>>) == :unknown
  end

  defp hex(text), do: text |> String.replace(" ", "") |> Base.decode16!()
end
