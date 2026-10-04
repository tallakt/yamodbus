defmodule Modbus.PDU do
  @moduledoc """
  The protocol data unit: a function code and its data, the part of a Modbus message that is the
  same on every transport. Requests and results are those listed in `Modbus`.

      iex> Modbus.PDU.encode_request({:read_holding_registers, 107, 3})
      <<3, 0, 107, 0, 3>>
      iex> Modbus.PDU.decode_response({:read_holding_registers, 107, 3}, <<3, 6, 2, 43, 0, 0, 0, 100>>)
      {:ok, [555, 0, 100]}

  A server goes the other way, with `decode_request/1` and `encode_response/2`. Decoding checks
  everything the spec lets it: the quantities each function allows, byte counts that agree with
  them, coil values of 0xFF00 or 0, and file records within the 10,000 a file holds. A response has
  to answer its request: the same function code, the count of values asked for, the echo of a write.
  """

  import Bitwise

  # The most one request may carry, from the spec.
  @read_bits 2000
  @read_registers 125
  @write_bits 1968
  @write_registers 123
  @read_write_registers 121
  @fifo 31
  @events 64
  @records 10_000

  @categories %{basic: 1, regular: 2, extended: 3, individual: 4}
  @category_names Map.new(@categories, fn {name, code} -> {code, name} end)

  @known [1, 2, 3, 4, 5, 6, 7, 8, 11, 12, 15, 16, 17, 20, 21, 22, 23, 24, 43]

  # The diagnostics sub-functions whose data is one word, both ways. Return Query Data (0) takes
  # any, and the reserved ones are the device's business.
  @one_word [1, 2, 3, 4, 10, 11, 12, 13, 14, 15, 16, 17, 18, 20]

  @doc """
  The PDU of a request. Raises `ArgumentError` for one the protocol can't carry, such as a read of
  more registers than fit in a response.

      iex> Modbus.PDU.encode_request({:write_single_coil, 172, true})
      <<5, 0, 172, 255, 0>>
      iex> Modbus.PDU.encode_request({:write_multiple_coils, 19, [true, false, true, true, false, false, true, true, true, false]})
      <<15, 0, 19, 0, 10, 2, 205, 1>>
  """
  @spec encode_request(Modbus.request()) :: binary
  def encode_request({:read_coils, address, count}),
    do: <<1, address!(address)::16, count!(count, @read_bits, "coils to read")::16>>

  def encode_request({:read_discrete_inputs, address, count}),
    do: <<2, address!(address)::16, count!(count, @read_bits, "discrete inputs to read")::16>>

  def encode_request({:read_holding_registers, address, count}),
    do: <<3, address!(address)::16, count!(count, @read_registers, "registers to read")::16>>

  def encode_request({:read_input_registers, address, count}),
    do: <<4, address!(address)::16, count!(count, @read_registers, "registers to read")::16>>

  def encode_request({:write_single_coil, address, value}) when is_boolean(value),
    do: <<5, address!(address)::16, if(value, do: 0xFF00, else: 0)::16>>

  def encode_request({:write_single_register, address, value}),
    do: <<6, address!(address)::16, word!(value)::16>>

  def encode_request(:read_exception_status), do: <<7>>

  def encode_request({:diagnostics, sub_function, data}) when sub_function in @one_word do
    data = words!(data, 1, 1, "word of data for this sub-function")
    <<8, sub_function::16, data::binary>>
  end

  def encode_request({:diagnostics, sub_function, data}) do
    data = words!(data, 0, 125, "words of diagnostic data")
    <<8, word!(sub_function)::16, data::binary>>
  end

  def encode_request(:get_comm_event_counter), do: <<11>>
  def encode_request(:get_comm_event_log), do: <<12>>

  def encode_request({:write_multiple_coils, address, values}) do
    {count, bytes} = bits!(values, @write_bits, "coils to write")
    <<15, address!(address)::16, count::16, byte_size(bytes), bytes::binary>>
  end

  def encode_request({:write_multiple_registers, address, values}) do
    bytes = words!(values, 1, @write_registers, "registers to write")
    <<16, address!(address)::16, div(byte_size(bytes), 2)::16, byte_size(bytes), bytes::binary>>
  end

  def encode_request(:report_server_id), do: <<17>>

  def encode_request({:read_file_record, groups}) when is_list(groups) and groups != [] do
    subs =
      for group <- groups, into: <<>> do
        case group do
          {file, record, count} when is_integer(count) and count >= 1 ->
            {file, record} = file_record!(file, record, count)
            <<6, file::16, record::16, count::16>>

          other ->
            raise ArgumentError,
                  "a group of file records to read is {file, record, count}, got: #{inspect(other)}"
        end
      end

    answer = Enum.reduce(groups, 0, fn {_, _, count}, sum -> sum + 2 + 2 * count end)

    if byte_size(subs) > 245 or answer > 245,
      do: raise(ArgumentError, "too many file records to read in one request")

    <<20, byte_size(subs), subs::binary>>
  end

  def encode_request({:write_file_record, groups}) when is_list(groups) and groups != [] do
    subs =
      for group <- groups, into: <<>> do
        case group do
          {file, record, values} when is_list(values) ->
            data = words!(values, 1, 122, "words in a file record")
            {file, record} = file_record!(file, record, div(byte_size(data), 2))
            <<6, file::16, record::16, div(byte_size(data), 2)::16, data::binary>>

          other ->
            raise ArgumentError,
                  "a group of file records to write is {file, record, [word]}, got: #{inspect(other)}"
        end
      end

    if byte_size(subs) > 251,
      do: raise(ArgumentError, "too many file records to write in one request")

    <<21, byte_size(subs), subs::binary>>
  end

  def encode_request({:mask_write_register, address, and_mask, or_mask}),
    do: <<22, address!(address)::16, word!(and_mask)::16, word!(or_mask)::16>>

  def encode_request({:read_write_multiple_registers, read, count, write, values}) do
    count = count!(count, @read_registers, "registers to read")
    bytes = words!(values, 1, @read_write_registers, "registers to write")

    <<23, address!(read)::16, count::16, address!(write)::16, div(byte_size(bytes), 2)::16,
      byte_size(bytes), bytes::binary>>
  end

  def encode_request({:read_fifo_queue, address}), do: <<24, address!(address)::16>>

  def encode_request({:read_device_identification, category, object_id})
      when is_map_key(@categories, category) and object_id in 0..255,
      do: <<43, 14, @categories[category], object_id>>

  def encode_request({:encapsulated_interface_transport, mei, data})
      when mei in 0..255 and mei != 14 and is_binary(data) and byte_size(data) <= 251,
      do: <<43, mei, data::binary>>

  def encode_request({:custom, function, data})
      when function in 1..127 and is_binary(data) and byte_size(data) <= 252,
      do: <<function, data::binary>>

  def encode_request(request),
    do: raise(ArgumentError, "not a Modbus request: #{inspect(request)}")

  @doc """
  The request in a PDU, or the exception a server answers it with: `:illegal_function` for a
  function code out of range, and `:illegal_data_value` for a request that breaks the rules of its
  function, such as a byte count that doesn't match its quantity. File records that aren't there,
  past record 9999 or in file 0, are `:illegal_data_address`.

  A function code the spec doesn't define comes back as `{:custom, function_code, data}`, for the
  handler to answer or refuse.

      iex> Modbus.PDU.decode_request(<<1, 0, 19, 0, 19>>)
      {:ok, {:read_coils, 19, 19}}
      iex> Modbus.PDU.decode_request(<<3, 0, 0, 0, 200>>)
      {:error, :illegal_data_value}
      iex> Modbus.PDU.decode_request(<<65, 1, 2>>)
      {:ok, {:custom, 65, <<1, 2>>}}
  """
  @spec decode_request(binary) :: {:ok, Modbus.request()} | {:error, Modbus.exception()}
  def decode_request(<<function, data::binary>>)
      when function in 1..127 and byte_size(data) <= 252,
      do: request(function, data)

  def decode_request(<<function, _data::binary>>) when function in 1..127,
    do: {:error, :illegal_data_value}

  def decode_request(_pdu), do: {:error, :illegal_function}

  defp request(1, <<a::16, n::16>>) when n in 1..@read_bits, do: {:ok, {:read_coils, a, n}}

  defp request(2, <<a::16, n::16>>) when n in 1..@read_bits,
    do: {:ok, {:read_discrete_inputs, a, n}}

  defp request(3, <<a::16, n::16>>) when n in 1..@read_registers,
    do: {:ok, {:read_holding_registers, a, n}}

  defp request(4, <<a::16, n::16>>) when n in 1..@read_registers,
    do: {:ok, {:read_input_registers, a, n}}

  defp request(5, <<a::16, v::16>>) when v in [0xFF00, 0],
    do: {:ok, {:write_single_coil, a, v == 0xFF00}}

  defp request(6, <<a::16, v::16>>), do: {:ok, {:write_single_register, a, v}}
  defp request(7, <<>>), do: {:ok, :read_exception_status}

  defp request(8, <<sub::16, data::binary>>)
       when (sub in @one_word and byte_size(data) == 2) or
              (sub not in @one_word and rem(byte_size(data), 2) == 0),
       do: {:ok, {:diagnostics, sub, words(data)}}

  defp request(11, <<>>), do: {:ok, :get_comm_event_counter}
  defp request(12, <<>>), do: {:ok, :get_comm_event_log}

  defp request(15, <<a::16, n::16, count, bits::binary-size(count)>>)
       when n in 1..@write_bits and count == div(n + 7, 8),
       do: {:ok, {:write_multiple_coils, a, unpack(bits, n)}}

  defp request(16, <<a::16, n::16, count, data::binary-size(count)>>)
       when n in 1..@write_registers and count == 2 * n,
       do: {:ok, {:write_multiple_registers, a, words(data)}}

  defp request(17, <<>>), do: {:ok, :report_server_id}

  defp request(20, <<count, subs::binary-size(count)>>)
       when count in 7..245 and rem(count, 7) == 0 do
    groups = for <<type, file::16, record::16, n::16 <- subs>>, do: {type, file, record, n}
    answer = Enum.reduce(groups, 0, fn {_, _, _, n}, sum -> sum + 2 + 2 * n end)

    cond do
      Enum.any?(groups, fn {_, _, _, n} -> n < 1 end) or answer > 245 ->
        {:error, :illegal_data_value}

      Enum.all?(groups, fn {type, file, record, n} -> group?(type, file, record, n) end) ->
        {:ok, {:read_file_record, for({_, file, record, n} <- groups, do: {file, record, n})}}

      true ->
        {:error, :illegal_data_address}
    end
  end

  defp request(21, <<count, subs::binary-size(count)>>) when count in 9..251 do
    case write_groups(subs, []) do
      :error -> {:error, :illegal_data_value}
      groups -> write_file_record(groups)
    end
  end

  defp request(22, <<a::16, and_mask::16, or_mask::16>>),
    do: {:ok, {:mask_write_register, a, and_mask, or_mask}}

  defp request(23, <<read::16, n::16, write::16, m::16, count, data::binary-size(count)>>)
       when n in 1..@read_registers and m in 1..@read_write_registers and count == 2 * m,
       do: {:ok, {:read_write_multiple_registers, read, n, write, words(data)}}

  defp request(24, <<a::16>>), do: {:ok, {:read_fifo_queue, a}}

  defp request(43, <<14, code, object>>) when code in 1..4,
    do: {:ok, {:read_device_identification, @category_names[code], object}}

  defp request(43, <<mei, data::binary>>) when mei != 14,
    do: {:ok, {:encapsulated_interface_transport, mei, data}}

  defp request(function, _data) when function in @known, do: {:error, :illegal_data_value}
  defp request(function, data), do: {:ok, {:custom, function, data}}

  defp group?(type, file, record, n), do: type == 6 and file >= 1 and record + n <= @records

  defp write_file_record(groups) do
    if Enum.all?(groups, fn {type, file, record, values} ->
         group?(type, file, record, length(values))
       end),
       do: {:ok, {:write_file_record, for({_, f, r, v} <- groups, do: {f, r, v})}},
       else: {:error, :illegal_data_address}
  end

  defp write_groups(<<>>, groups), do: Enum.reverse(groups)

  defp write_groups(
         <<type, file::16, record::16, n::16, data::binary-size(2 * n), rest::binary>>,
         groups
       )
       when n >= 1,
       do: write_groups(rest, [{type, file, record, words(data)} | groups])

  defp write_groups(_subs, _groups), do: :error

  @doc """
  The PDU of a server's response to a request, from the result its handler gave. Raises
  `ArgumentError` for a result that doesn't answer the request, such as the wrong number of
  registers.

      iex> Modbus.PDU.encode_response({:read_coils, 19, 10}, {:ok, [true, false, true, true, false, false, true, true, true, false]})
      <<1, 2, 205, 1>>
      iex> Modbus.PDU.encode_response({:write_single_register, 1, 3}, :ok)
      <<6, 0, 1, 0, 3>>
      iex> Modbus.PDU.encode_response({:read_coils, 1185, 1}, {:error, {:exception, :illegal_data_address}})
      <<129, 2>>
  """
  @spec encode_response(Modbus.request(), Modbus.result()) :: binary
  def encode_response(request, {:error, {:exception, exception}}),
    do: <<function(request) ||| 0x80, Modbus.exception_code(exception)>>

  def encode_response({kind, _address, count} = request, {:ok, values})
      when kind in [:read_coils, :read_discrete_inputs] and length(values) == count do
    {_count, bytes} = bits!(values, @read_bits, "coils or inputs read")
    <<function(request), byte_size(bytes), bytes::binary>>
  end

  def encode_response({kind, _address, count} = request, {:ok, values})
      when kind in [:read_holding_registers, :read_input_registers] and length(values) == count,
      do: registers(function(request), values)

  def encode_response({kind, _, _} = request, :ok)
      when kind in [:write_single_coil, :write_single_register],
      do: encode_request(request)

  def encode_response(:read_exception_status, {:ok, byte}) when byte in 0..255, do: <<7, byte>>

  def encode_response({:diagnostics, sub_function, _data}, {:ok, data})
      when sub_function in @one_word,
      do:
        <<8, sub_function::16, words!(data, 1, 1, "word of data for this sub-function")::binary>>

  def encode_response({:diagnostics, sub_function, _data}, {:ok, data}),
    do: <<8, sub_function::16, words!(data, 0, 125, "words of diagnostic data")::binary>>

  def encode_response(:get_comm_event_counter, {:ok, %{status: status, event_count: count}}),
    do: <<11, word!(status)::16, word!(count)::16>>

  def encode_response(:get_comm_event_log, {:ok, %{events: events} = log})
      when length(events) <= @events do
    events = for event <- events, into: <<>>, do: <<byte!(event)>>

    <<12, byte_size(events) + 6, word!(log.status)::16, word!(log.event_count)::16,
      word!(log.message_count)::16, events::binary>>
  end

  def encode_response({:write_multiple_coils, address, values}, :ok),
    do: <<15, address::16, length(values)::16>>

  def encode_response({:write_multiple_registers, address, values}, :ok),
    do: <<16, address::16, length(values)::16>>

  def encode_response(:report_server_id, {:ok, data})
      when is_binary(data) and byte_size(data) <= 251,
      do: <<17, byte_size(data), data::binary>>

  def encode_response({:read_file_record, groups}, {:ok, records})
      when length(records) == length(groups) do
    subs =
      for {{_file, _record, count}, values} <- Enum.zip(groups, records), into: <<>> do
        if not is_list(values) or length(values) != count,
          do:
            raise(
              ArgumentError,
              "expected #{count} words for a file record, got: #{inspect(values)}"
            )

        data = words!(values, 1, 122, "words in a file record")
        <<byte_size(data) + 1, 6, data::binary>>
      end

    <<20, byte_size(subs), subs::binary>>
  end

  def encode_response({:write_file_record, _groups} = request, :ok), do: encode_request(request)

  def encode_response({:mask_write_register, _, _, _} = request, :ok), do: encode_request(request)

  def encode_response({:read_write_multiple_registers, _, count, _, _}, {:ok, values})
      when length(values) == count,
      do: registers(23, values)

  def encode_response({:read_fifo_queue, _address}, {:ok, values}) when length(values) <= @fifo do
    data = words!(values, 0, @fifo, "registers in a FIFO queue")
    <<24, byte_size(data) + 2::16, length(values)::16, data::binary>>
  end

  def encode_response({:read_device_identification, category, _object}, {:ok, answer}) do
    %{conformity_level: level, more_follows: more, next_object_id: next, objects: objects} =
      answer

    data =
      for {id, value} <- objects, into: <<>> do
        if not (id in 0..255 and is_binary(value) and byte_size(value) <= 255),
          do: raise(ArgumentError, "not a device identification object: #{inspect({id, value})}")

        <<id, byte_size(value), value::binary>>
      end

    pdu =
      <<43, 14, @categories[category], byte!(level), if(more, do: 0xFF, else: 0), byte!(next),
        length(objects), data::binary>>

    if byte_size(pdu) > 253, do: raise(ArgumentError, "device identification objects too long")
    pdu
  end

  def encode_response({:encapsulated_interface_transport, mei, _data}, {:ok, data})
      when is_binary(data) and byte_size(data) <= 251,
      do: <<43, mei, data::binary>>

  def encode_response({:custom, function, _data}, {:ok, data})
      when is_binary(data) and byte_size(data) <= 252,
      do: <<function, data::binary>>

  def encode_response(request, result) do
    raise ArgumentError,
          "#{inspect(result)} doesn't answer #{inspect(request)}"
  end

  @doc """
  The result in a response PDU, for the request it answers. A response that doesn't fit the request,
  in its function code, its length, or the echo of a write, is `{:error, {:invalid_response, pdu}}`.

      iex> Modbus.PDU.decode_response({:read_coils, 19, 10}, <<1, 2, 205, 1>>)
      {:ok, [true, false, true, true, false, false, true, true, true, false]}
      iex> Modbus.PDU.decode_response({:read_coils, 1185, 1}, <<129, 2>>)
      {:error, {:exception, :illegal_data_address}}
      iex> Modbus.PDU.decode_response({:read_coils, 19, 10}, <<3, 2, 0, 0>>)
      {:error, {:invalid_response, <<3, 2, 0, 0>>}}
  """
  @spec decode_response(Modbus.request(), binary) :: Modbus.result()
  def decode_response(request, pdu) do
    function = function(request)
    exception = function ||| 0x80

    result =
      case pdu do
        <<^exception, code>> -> {:error, {:exception, Modbus.exception_name(code)}}
        <<^function, data::binary>> -> response(request, data, pdu)
        _ -> :error
      end

    if result == :error, do: {:error, {:invalid_response, pdu}}, else: result
  end

  defp response({kind, _address, n}, <<count, bits::binary-size(count)>>, _pdu)
       when kind in [:read_coils, :read_discrete_inputs] and count == div(n + 7, 8),
       do: {:ok, unpack(bits, n)}

  defp response({kind, _address, n}, <<count, data::binary-size(count)>>, _pdu)
       when kind in [:read_holding_registers, :read_input_registers] and count == 2 * n,
       do: {:ok, words(data)}

  defp response({kind, _, _} = request, _data, pdu)
       when kind in [:write_single_coil, :write_single_register],
       do: echo(request, pdu)

  defp response(:read_exception_status, <<byte>>, _pdu), do: {:ok, byte}

  defp response({:diagnostics, sub, _}, <<sub::16, data::binary>>, _pdu)
       when (sub in @one_word and byte_size(data) == 2) or
              (sub not in @one_word and rem(byte_size(data), 2) == 0),
       do: {:ok, words(data)}

  defp response(:get_comm_event_counter, <<status::16, count::16>>, _pdu),
    do: {:ok, %{status: status, event_count: count}}

  defp response(
         :get_comm_event_log,
         <<count, status::16, events::16, messages::16, log::binary>>,
         _
       )
       when count == byte_size(log) + 6 and byte_size(log) <= @events,
       do:
         {:ok,
          %{
            status: status,
            event_count: events,
            message_count: messages,
            events: :binary.bin_to_list(log)
          }}

  defp response({:write_multiple_coils, address, values}, <<address::16, n::16>>, _pdu)
       when n == length(values),
       do: :ok

  defp response({:write_multiple_registers, address, values}, <<address::16, n::16>>, _pdu)
       when n == length(values),
       do: :ok

  defp response(:report_server_id, <<count, data::binary-size(count)>>, _pdu), do: {:ok, data}

  defp response({:read_file_record, groups}, <<count, subs::binary-size(count)>>, _pdu),
    do: file_records(groups, subs, [])

  defp response({kind, _} = request, _data, pdu) when kind == :write_file_record,
    do: echo(request, pdu)

  defp response({:mask_write_register, _, _, _} = request, _data, pdu), do: echo(request, pdu)

  defp response(
         {:read_write_multiple_registers, _, n, _, _},
         <<count, data::binary-size(count)>>,
         _
       )
       when count == 2 * n,
       do: {:ok, words(data)}

  defp response({:read_fifo_queue, _}, <<count::16, n::16, data::binary-size(2 * n)>>, _pdu)
       when count == 2 + 2 * n and n <= @fifo,
       do: {:ok, words(data)}

  defp response({:read_device_identification, category, _}, data, _pdu) do
    code = @categories[category]

    with <<14, ^code, level, more, next, n, objects::binary>> when more in [0, 0xFF] <- data,
         objects when length(objects) == n <- objects(objects, []) do
      {:ok,
       %{
         conformity_level: level,
         more_follows: more == 0xFF,
         next_object_id: next,
         objects: objects
       }}
    else
      _ -> :error
    end
  end

  defp response({:encapsulated_interface_transport, mei, _}, <<mei, data::binary>>, _pdu),
    do: {:ok, data}

  defp response({:custom, _function, _}, data, _pdu), do: {:ok, data}
  defp response(_request, _data, _pdu), do: :error

  defp echo(request, pdu), do: if(pdu == encode_request(request), do: :ok, else: :error)

  defp file_records([], <<>>, records), do: {:ok, Enum.reverse(records)}

  defp file_records([{_, _, n} | groups], <<length, 6, rest::binary>>, records)
       when length == 2 * n + 1 and byte_size(rest) >= 2 * n do
    <<data::binary-size(2 * n), rest::binary>> = rest
    file_records(groups, rest, [words(data) | records])
  end

  defp file_records(_groups, _subs, _records), do: :error

  defp objects(<<>>, objects), do: Enum.reverse(objects)

  defp objects(<<id, length, value::binary-size(length), rest::binary>>, objects),
    do: objects(rest, [{id, value} | objects])

  defp objects(_data, _objects), do: :error

  @doc """
  The function code of a request.

      iex> Modbus.PDU.function({:read_input_registers, 8, 1})
      4
      iex> Modbus.PDU.function({:read_device_identification, :basic, 0})
      43
  """
  @spec function(Modbus.request()) :: 1..127
  def function({:read_coils, _, _}), do: 1
  def function({:read_discrete_inputs, _, _}), do: 2
  def function({:read_holding_registers, _, _}), do: 3
  def function({:read_input_registers, _, _}), do: 4
  def function({:write_single_coil, _, _}), do: 5
  def function({:write_single_register, _, _}), do: 6
  def function(:read_exception_status), do: 7
  def function({:diagnostics, _, _}), do: 8
  def function(:get_comm_event_counter), do: 11
  def function(:get_comm_event_log), do: 12
  def function({:write_multiple_coils, _, _}), do: 15
  def function({:write_multiple_registers, _, _}), do: 16
  def function(:report_server_id), do: 17
  def function({:read_file_record, _}), do: 20
  def function({:write_file_record, _}), do: 21
  def function({:mask_write_register, _, _, _}), do: 22
  def function({:read_write_multiple_registers, _, _, _, _}), do: 23
  def function({:read_fifo_queue, _}), do: 24
  def function({:read_device_identification, _, _}), do: 43
  def function({:encapsulated_interface_transport, _, _}), do: 43
  def function({:custom, function, _}), do: function

  @doc false
  # The length of the request PDU that `pdu` begins, as far as its first bytes tell: {:ok, length},
  # :more when it needs more bytes to tell, :unknown when only silence on the line can, or :invalid
  # when it can't be a request at all.
  def request_length(<<f, _::binary>>) when f == 0 or f >= 0x80, do: :invalid
  def request_length(<<f, _::binary>>) when f in 1..6, do: {:ok, 5}
  def request_length(<<f, _::binary>>) when f in [7, 11, 12, 17], do: {:ok, 1}
  def request_length(<<8, sub::16, _::binary>>) when sub in @one_word, do: {:ok, 5}
  def request_length(<<8, _::16, _::binary>>), do: :unknown
  def request_length(<<f, _::32, count, _::binary>>) when f in [15, 16], do: {:ok, 6 + count}
  def request_length(<<f, count, _::binary>>) when f in [20, 21], do: {:ok, 2 + count}
  def request_length(<<22, _::binary>>), do: {:ok, 7}
  def request_length(<<23, _::64, count, _::binary>>), do: {:ok, 10 + count}
  def request_length(<<24, _::binary>>), do: {:ok, 3}
  def request_length(<<43, 14, _::binary>>), do: {:ok, 4}
  def request_length(<<43, _mei, _::binary>>), do: :unknown
  def request_length(<<f, _::binary>>) when f in [8, 15, 16, 20, 21, 23, 43], do: :more
  def request_length(<<>>), do: :more
  def request_length(_pdu), do: :unknown

  @doc false
  # The length of the response PDU that `pdu` begins, as request_length/1 tells it of a request,
  # knowing the request it answers, or nil for one that answers someone else.
  def response_length(_request, <<f, _::binary>>) when f in [0, 0x80], do: :invalid
  def response_length(_request, <<f, _::binary>>) when f > 0x80, do: {:ok, 2}
  def response_length({:diagnostics, 0, data}, <<8, _::binary>>), do: {:ok, 3 + 2 * length(data)}

  def response_length(_request, <<f, count, _::binary>>)
      when f in [1, 2, 3, 4, 12, 17, 20, 21, 23],
      do: {:ok, 2 + count}

  def response_length(_request, <<f, _::binary>>) when f in [5, 6, 11, 15, 16], do: {:ok, 5}
  def response_length(_request, <<7, _::binary>>), do: {:ok, 2}
  def response_length(_request, <<22, _::binary>>), do: {:ok, 7}
  def response_length(_request, <<8, sub::16, _::binary>>) when sub in @one_word, do: {:ok, 5}
  def response_length(_request, <<8, _::16, _::binary>>), do: :unknown
  def response_length(_request, <<24, count::16, _::binary>>), do: {:ok, 3 + count}
  def response_length(_request, <<43, 14, rest::binary>>), do: identification_length(rest)
  def response_length(_request, <<43, _mei, _::binary>>), do: :unknown

  def response_length(_request, <<f, _::binary>>)
      when f in [1, 2, 3, 4, 8, 12, 17, 20, 21, 23, 24, 43],
      do: :more

  def response_length(_request, <<>>), do: :more
  def response_length(_request, _pdu), do: :unknown

  defp identification_length(<<_code, _level, _more, _next, n, objects::binary>>),
    do: object_length(objects, n, 7)

  defp identification_length(_partial), do: :more

  defp object_length(_objects, 0, length), do: {:ok, length}

  defp object_length(<<_id, size, _value::binary-size(size), rest::binary>>, n, length),
    do: object_length(rest, n - 1, length + 2 + size)

  defp object_length(_objects, _n, _length), do: :more

  defp registers(function, values) do
    data = words!(values, 1, @read_registers, "registers read")
    <<function, byte_size(data), data::binary>>
  end

  defp words(data), do: for(<<word::16 <- data>>, do: word)

  defp unpack(bytes, n),
    do: Enum.take(for(<<byte <- bytes>>, i <- 0..7, do: (byte >>> i &&& 1) == 1), n)

  defp bits!(values, max, what) when is_list(values) and values != [] do
    count = length(values)
    if count > max, do: raise(ArgumentError, "at most #{max} #{what}, got: #{count}")

    bytes =
      for chunk <- Enum.chunk_every(values, 8), into: <<>> do
        byte =
          chunk
          |> Enum.with_index()
          |> Enum.reduce(0, fn
            {true, i}, byte ->
              byte ||| 1 <<< i

            {false, _i}, byte ->
              byte

            {other, _i}, _byte ->
              raise ArgumentError, "a coil is true or false, got: #{inspect(other)}"
          end)

        <<byte>>
      end

    {count, bytes}
  end

  defp bits!(values, max, what),
    do: raise(ArgumentError, "expected a list of 1 to #{max} #{what}, got: #{inspect(values)}")

  defp words!(values, min, max, what) when is_list(values) do
    count = length(values)

    if count < min or count > max,
      do: raise(ArgumentError, "expected #{min} to #{max} #{what}, got: #{count}")

    for value <- values, into: <<>>, do: <<word!(value)::16>>
  end

  defp words!(values, _min, max, what),
    do: raise(ArgumentError, "expected a list of up to #{max} #{what}, got: #{inspect(values)}")

  defp address!(address) when is_integer(address) and address in 0..65535, do: address

  defp address!(address),
    do: raise(ArgumentError, "an address is 0 to 65535, got: #{inspect(address)}")

  defp word!(word) when is_integer(word) and word in 0..65535, do: word
  defp word!(word), do: raise(ArgumentError, "a word is 0 to 65535, got: #{inspect(word)}")

  defp byte!(byte) when is_integer(byte) and byte in 0..255, do: byte
  defp byte!(byte), do: raise(ArgumentError, "expected a byte, 0 to 255, got: #{inspect(byte)}")

  defp count!(count, max, _what) when is_integer(count) and count >= 1 and count <= max, do: count

  defp count!(count, max, what),
    do: raise(ArgumentError, "expected 1 to #{max} #{what}, got: #{inspect(count)}")

  defp file_record!(file, record, count) do
    cond do
      not (is_integer(file) and file in 1..65535) ->
        raise ArgumentError, "a file number is 1 to 65535, got: #{inspect(file)}"

      not (is_integer(record) and record >= 0 and record + count <= @records) ->
        raise ArgumentError,
              "a file holds records 0 to 9999, got: #{count} from #{inspect(record)}"

      true ->
        {file, record}
    end
  end
end
