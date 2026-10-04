defmodule Modbus do
  @moduledoc """
  Modbus as the Modbus Organization's specifications define it, in pure Elixir: the requests of the
  application protocol, over TCP, over TLS (Modbus/TCP Security), and over serial lines in RTU and
  ASCII.

    * `Modbus.Client` sends requests to a device, many at once over one TCP connection, one at a time
      on a serial line, and reconnects by itself.
    * `Modbus.Server` answers them, through a handler of yours or a `Modbus.Memory`.
    * `Modbus.PDU`, `Modbus.TCP`, `Modbus.RTU` and `Modbus.ASCII` encode and decode, for those who
      bring their own transport.

  Values are what the protocol carries and nothing more: a register is an integer from 0 to 65535, a
  coil or a discrete input is a boolean, and addresses count from 0, as on the wire. Numbers of more
  than one register, floats, word order and the "40001" way of numbering registers are left to the
  application.

  ## Requests

  A request is a tuple, and its result is the same whether a client gets it from a device or a
  server's handler gives it:

  | Request | Result |
  |---|---|
  | `{:read_coils, address, count}` | `{:ok, [boolean]}` |
  | `{:read_discrete_inputs, address, count}` | `{:ok, [boolean]}` |
  | `{:read_holding_registers, address, count}` | `{:ok, [word]}` |
  | `{:read_input_registers, address, count}` | `{:ok, [word]}` |
  | `{:write_single_coil, address, boolean}` | `:ok` |
  | `{:write_single_register, address, word}` | `:ok` |
  | `{:write_multiple_coils, address, [boolean]}` | `:ok` |
  | `{:write_multiple_registers, address, [word]}` | `:ok` |
  | `{:mask_write_register, address, and_mask, or_mask}` | `:ok` |
  | `{:read_write_multiple_registers, read_address, count, write_address, [word]}` | `{:ok, [word]}` |
  | `{:read_fifo_queue, address}` | `{:ok, [word]}` |
  | `{:read_file_record, [{file, record, count}]}` | `{:ok, [[word]]}`, one list for each group |
  | `{:write_file_record, [{file, record, [word]}]}` | `:ok` |
  | `{:read_device_identification, category, object_id}` | `{:ok, %{conformity_level: byte, more_follows: boolean, next_object_id: byte, objects: [{byte, binary}]}}` |
  | `:read_exception_status` | `{:ok, byte}` |
  | `{:diagnostics, sub_function, [word]}` | `{:ok, [word]}` |
  | `:get_comm_event_counter` | `{:ok, %{status: word, event_count: word}}` |
  | `:get_comm_event_log` | `{:ok, %{status: word, event_count: word, message_count: word, events: [byte]}}` |
  | `:report_server_id` | `{:ok, binary}` |
  | `{:encapsulated_interface_transport, mei_type, binary}` | `{:ok, binary}` |
  | `{:custom, function_code, binary}` | `{:ok, binary}` |

  The category of a device identification request is `:basic`, `:regular`, `:extended` or
  `:individual`. `:custom` is for the user-defined function codes, 65 to 72 and 100 to 110, and any
  other the spec doesn't define; its data is the bytes after the function code, both ways.

  ## Errors

    * `{:error, {:exception, name}}`: the device answered with an exception, named as in the spec,
      such as `:illegal_data_address` (see `exception_name/1`)
    * `{:error, :timeout}`: no answer in time
    * `{:error, :closed}`: there's no connection, or it was lost before the answer came
    * `{:error, {:invalid_response, pdu}}`: the answer doesn't fit the request
    * `{:error, :invalid_unit}`: a serial line client was asked for a reserved unit (248 to 255), or
      to broadcast a request that isn't a write

  A request that doesn't fit the protocol, such as reading 200 registers at once, raises
  `ArgumentError` in the caller and is never sent.
  """

  @typedoc """
  A unit id: on a serial line 1 to 247 for a device, or 0 to broadcast; over TCP any byte, 255 for a
  device on the network itself.
  """
  @type unit :: 0..255

  @typedoc "A data address, from 0."
  @type address :: 0..65535

  @typedoc "The contents of a register."
  @type word :: 0..65535

  @type request ::
          {:read_coils, address, 1..2000}
          | {:read_discrete_inputs, address, 1..2000}
          | {:read_holding_registers, address, 1..125}
          | {:read_input_registers, address, 1..125}
          | {:write_single_coil, address, boolean}
          | {:write_single_register, address, word}
          | {:write_multiple_coils, address, [boolean]}
          | {:write_multiple_registers, address, [word]}
          | {:mask_write_register, address, word, word}
          | {:read_write_multiple_registers, address, 1..125, address, [word]}
          | {:read_fifo_queue, address}
          | {:read_file_record, [{1..65535, 0..9999, pos_integer}]}
          | {:write_file_record, [{1..65535, 0..9999, [word]}]}
          | {:read_device_identification, :basic | :regular | :extended | :individual, byte}
          | :read_exception_status
          | {:diagnostics, word, [word]}
          | :get_comm_event_counter
          | :get_comm_event_log
          | :report_server_id
          | {:encapsulated_interface_transport, byte, binary}
          | {:custom, 1..127, binary}

  @typedoc "An exception, by its name in the spec, or its code if the spec has no name for it."
  @type exception ::
          :illegal_function
          | :illegal_data_address
          | :illegal_data_value
          | :server_device_failure
          | :acknowledge
          | :server_device_busy
          | :memory_parity_error
          | :gateway_path_unavailable
          | :gateway_target_device_failed_to_respond
          | byte

  @type error ::
          {:exception, exception}
          | :timeout
          | :closed
          | {:invalid_response, binary}
          | :invalid_unit

  @type result :: :ok | {:ok, term} | {:error, error}

  @exceptions %{
    1 => :illegal_function,
    2 => :illegal_data_address,
    3 => :illegal_data_value,
    4 => :server_device_failure,
    5 => :acknowledge,
    6 => :server_device_busy,
    8 => :memory_parity_error,
    10 => :gateway_path_unavailable,
    11 => :gateway_target_device_failed_to_respond
  }
  @codes Map.new(@exceptions, fn {code, name} -> {name, code} end)

  @doc """
  The name of an exception code, or the code itself if the spec has none for it.

      iex> Modbus.exception_name(2)
      :illegal_data_address
      iex> Modbus.exception_name(7)
      7
  """
  @spec exception_name(byte) :: exception
  def exception_name(code) when code in 0..255, do: Map.get(@exceptions, code, code)

  @doc """
  The code of an exception, given by name or code.

      iex> Modbus.exception_code(:gateway_target_device_failed_to_respond)
      11
      iex> Modbus.exception_code(7)
      7
  """
  @spec exception_code(exception) :: byte
  def exception_code(code) when code in 1..255, do: code

  def exception_code(name) do
    case @codes do
      %{^name => code} -> code
      _ -> raise ArgumentError, "not a Modbus exception: #{inspect(name)}"
    end
  end
end
