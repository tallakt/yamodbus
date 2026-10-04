defmodule Modbus.Memory do
  @moduledoc """
  The Modbus data model in memory, as a handler for `Modbus.Server`: coils, discrete inputs, holding
  registers and input registers, and files of records. A simulator for a device, or a stand-in in
  tests.

      iex> {:ok, memory} = Modbus.Memory.start_link(holding_registers: 100)
      iex> Modbus.Memory.put(memory, :holding_register, 10, [0x12, 1000, 3])
      :ok
      iex> Modbus.Memory.handle_request(1, {:read_holding_registers, 10, 3}, memory)
      {:ok, [18, 1000, 3]}
      iex> Modbus.Memory.handle_request(1, {:read_holding_registers, 99, 2}, memory)
      {:error, {:exception, :illegal_data_address}}
      iex> Modbus.Memory.handle_request(1, {:mask_write_register, 10, 0xF2, 0x25}, memory)
      :ok
      iex> Modbus.Memory.get(memory, :holding_register, 10)
      [0x17]

  Serve it with `Modbus.Server.start_link(handler: {Modbus.Memory, memory})`. Every unit sees the same
  tables; for several units, start a memory for each and pick by unit in a function handler.

  It answers the functions that read and write the data model: 1 to 6, 15 and 16, Mask Write
  Register (22), Read/Write Multiple Registers (23), Read FIFO Queue (24) and the file records (20 and
  21). Any other request is `:illegal_function`, and an address past the end of its table is
  `:illegal_data_address`, as the spec has it.

  A FIFO queue is in the holding registers: the count at the pointer address, and the values after
  it.

  ## Options

    * `:coils`, `:discrete_inputs`, `:holding_registers`, `:input_registers` - how many of each, from
      address 0 (default 65536, all of them)
    * `:files` - how many files, numbered from 1, each of 10,000 records (default 10, at most 100).
      Any client may write every record, which then takes memory: 10 files take up to about 6 MB,
      100 files ten times that
    * `:name` - to register the process
  """

  use GenServer
  import Bitwise

  @behaviour Modbus.Server

  @tables [:coil, :discrete_input, :holding_register, :input_register]

  @typedoc "A table of the data model."
  @type table :: :coil | :discrete_input | :holding_register | :input_register

  @doc false
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Starts a memory, every coil and input false and every register 0, with the options above."
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Modbus.Client.unknown!(opts, [
      :coils,
      :discrete_inputs,
      :holding_registers,
      :input_registers,
      :files,
      :name
    ])

    sizes =
      for {table, key} <-
            Enum.zip(@tables, [:coils, :discrete_inputs, :holding_registers, :input_registers]),
          into: %{} do
        size = Keyword.get(opts, key, 65536)

        if not (is_integer(size) and size in 0..65536),
          do: raise(ArgumentError, "#{key}: must be 0 to 65536, got: #{inspect(size)}")

        {table, size}
      end

    files = Keyword.get(opts, :files, 10)

    if not (is_integer(files) and files in 0..100),
      do: raise(ArgumentError, "files: must be 0 to 100, got: #{inspect(files)}")

    name = if opts[:name], do: [name: opts[:name]], else: []
    GenServer.start_link(__MODULE__, %{sizes: sizes, files: files}, name)
  end

  @doc """
  The values of `count` entries of a table from `address`.

      iex> {:ok, memory} = Modbus.Memory.start_link()
      iex> Modbus.Memory.put(memory, :coil, 3, true)
      iex> Modbus.Memory.get(memory, :coil, 2, 3)
      [false, true, false]
  """
  @spec get(GenServer.server(), table, Modbus.address(), pos_integer) :: [boolean | Modbus.word()]
  def get(memory, table, address, count \\ 1) when table in @tables,
    do: GenServer.call(memory, {:get, table, address, count})

  @doc """
  Sets entries of a table from `address`: booleans for coils and discrete inputs, words for
  registers. Raises `ArgumentError` for a value that doesn't fit, or an address past the end.
  """
  @spec put(
          GenServer.server(),
          table,
          Modbus.address(),
          [boolean | Modbus.word()] | boolean | Modbus.word()
        ) :: :ok
  def put(memory, table, address, values) when table in @tables do
    case GenServer.call(memory, {:put, table, address, List.wrap(values)}) do
      :ok -> :ok
      {:error, message} -> raise ArgumentError, message
    end
  end

  @impl Modbus.Server
  def handle_request(_unit, request, memory), do: GenServer.call(memory, {:request, request})

  @impl GenServer
  def init(config), do: {:ok, Map.put(config, :data, %{})}

  @impl GenServer
  def handle_call({:get, table, address, count}, _from, s),
    do: {:reply, read(s, table, address, count), s}

  def handle_call({:put, table, address, values}, _from, s) do
    cond do
      not inside?(s, table, address, length(values)) ->
        {:reply, {:error, "#{table} #{address}..#{address + length(values) - 1} is past the end"},
         s}

      not Enum.all?(values, &fits?(table, &1)) ->
        {:reply, {:error, "not values for #{table}: #{inspect(values)}"}, s}

      true ->
        {:reply, :ok, write(s, table, address, values)}
    end
  end

  def handle_call({:request, request}, _from, s) do
    {result, s} = request(s, request)
    {:reply, result, s}
  end

  defp request(s, {kind, address, count})
       when kind in [
              :read_coils,
              :read_discrete_inputs,
              :read_holding_registers,
              :read_input_registers
            ] do
    table = table(kind)

    if inside?(s, table, address, count),
      do: {{:ok, read(s, table, address, count)}, s},
      else: address(s)
  end

  defp request(s, {:write_single_coil, address, value}), do: store(s, :coil, address, [value])

  defp request(s, {:write_single_register, address, value}),
    do: store(s, :holding_register, address, [value])

  defp request(s, {:write_multiple_coils, address, values}), do: store(s, :coil, address, values)

  defp request(s, {:write_multiple_registers, address, values}),
    do: store(s, :holding_register, address, values)

  defp request(s, {:mask_write_register, address, and_mask, or_mask}) do
    if inside?(s, :holding_register, address, 1) do
      [current] = read(s, :holding_register, address, 1)
      value = (current &&& and_mask) ||| (or_mask &&& bnot(and_mask) &&& 0xFFFF)
      {:ok, write(s, :holding_register, address, [value])}
    else
      address(s)
    end
  end

  # The write comes before the read, as the spec has it.
  defp request(s, {:read_write_multiple_registers, read, count, write, values}) do
    if inside?(s, :holding_register, read, count) and
         inside?(s, :holding_register, write, length(values)) do
      s = write(s, :holding_register, write, values)
      {{:ok, read(s, :holding_register, read, count)}, s}
    else
      address(s)
    end
  end

  defp request(s, {:read_fifo_queue, address}) do
    if inside?(s, :holding_register, address, 1) do
      [count] = read(s, :holding_register, address, 1)

      cond do
        count > 31 ->
          {{:error, {:exception, :illegal_data_value}}, s}

        count == 0 ->
          {{:ok, []}, s}

        inside?(s, :holding_register, address + 1, count) ->
          {{:ok, read(s, :holding_register, address + 1, count)}, s}

        true ->
          address(s)
      end
    else
      address(s)
    end
  end

  defp request(s, {:read_file_record, groups}) do
    if Enum.all?(groups, fn {file, _record, _count} -> file <= s.files end),
      do: {{:ok, for({file, record, count} <- groups, do: records(s, file, record, count))}, s},
      else: address(s)
  end

  defp request(s, {:write_file_record, groups}) do
    if Enum.all?(groups, fn {file, _record, _values} -> file <= s.files end) do
      data =
        for {file, record, values} <- groups,
            {value, i} <- Enum.with_index(values, record),
            reduce: s.data do
          data -> Map.put(data, {:file, file, i}, value)
        end

      {:ok, %{s | data: data}}
    else
      address(s)
    end
  end

  defp request(s, _request), do: {{:error, {:exception, :illegal_function}}, s}

  defp store(s, table, address, values) do
    if inside?(s, table, address, length(values)),
      do: {:ok, write(s, table, address, values)},
      else: address(s)
  end

  defp address(s), do: {{:error, {:exception, :illegal_data_address}}, s}

  defp table(:read_coils), do: :coil
  defp table(:read_discrete_inputs), do: :discrete_input
  defp table(:read_holding_registers), do: :holding_register
  defp table(:read_input_registers), do: :input_register

  defp inside?(s, table, address, count),
    do: is_integer(address) and address >= 0 and count >= 1 and address + count <= s.sizes[table]

  defp read(s, table, address, count) do
    blank = if table in [:coil, :discrete_input], do: false, else: 0
    for a <- address..(address + count - 1)//1, do: Map.get(s.data, {table, a}, blank)
  end

  defp records(s, file, record, count),
    do: for(r <- record..(record + count - 1)//1, do: Map.get(s.data, {:file, file, r}, 0))

  defp write(s, table, address, values) do
    data =
      values
      |> Enum.with_index(address)
      |> Enum.reduce(s.data, fn {v, a}, data -> Map.put(data, {table, a}, v) end)

    %{s | data: data}
  end

  defp fits?(table, value) when table in [:coil, :discrete_input], do: is_boolean(value)
  defp fits?(_table, value), do: is_integer(value) and value in 0..65535
end
