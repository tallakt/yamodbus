defmodule Modbus.Client.Line do
  @moduledoc false
  # A client on a serial line, RTU or ASCII: one request at a time, each sent only after the line has
  # been quiet for 3.5 characters, its answer found by the length its function code gives and checked
  # by CRC or LRC. Bytes that aren't the answer, such as a late one to an earlier request, are passed
  # over.
  use GenServer

  alias Modbus.{ASCII, PDU, RTU, Serial}

  # The requests that may be broadcast: writes, and the user's own.
  @broadcast [
    :write_single_coil,
    :write_single_register,
    :write_multiple_coils,
    :write_multiple_registers,
    :write_file_record,
    :mask_write_register,
    :custom
  ]

  def config!(transport, device, opts) do
    speed = Keyword.get(opts, :speed, 19200)
    data_bits = Keyword.get(opts, :data_bits, if(transport == :ascii, do: 7, else: 8))
    parity = Keyword.get(opts, :parity, :even)
    stop_bits = Keyword.get(opts, :stop_bits, 1)

    check!(is_integer(speed) and speed > 0, "speed: must be a baud rate", speed)
    check!(data_bits in [7, 8], "data_bits: must be 7 or 8", data_bits)
    check!(parity in [:even, :odd, :none], "parity: must be :even, :odd or :none", parity)
    check!(stop_bits in [1, 2], "stop_bits: must be 1 or 2", stop_bits)

    echo = Keyword.get(opts, :echo, false)
    check!(is_boolean(echo), "echo: must be a boolean", echo)

    if transport == :rtu and data_bits != 8,
      do: raise(ArgumentError, "RTU sends 8 data bits, got data_bits: #{data_bits}")

    gap = div(RTU.frame_gap(speed) + 999, 1000)

    %{
      mode: transport,
      device: device,
      speed: speed,
      data_bits: data_bits,
      parity: parity,
      stop_bits: stop_bits,
      echo: echo,
      gap: if(transport == :rtu, do: gap, else: 0),
      silence: Modbus.Client.positive!(opts, :silence, max(20, 2 * gap)),
      turnaround: Modbus.Client.positive!(opts, :turnaround, 100)
    }
  end

  defp check!(true, _message, _value), do: :ok

  defp check!(false, message, value),
    do: raise(ArgumentError, "#{message}, got: #{inspect(value)}")

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    s =
      Map.merge(config, %{
        uart: nil,
        status: :connecting,
        queue: :queue.new(),
        current: nil,
        buffer: <<>>,
        quiet: now(),
        echoing: <<>>,
        sender: nil,
        silencer: nil,
        delay: elem(config.backoff, 0)
      })

    {:ok, open(s)}
  end

  @impl true
  def handle_call({:request, unit, request, pdu, timeout}, from, s),
    do: {:noreply, submit(s, entry(unit, request, pdu, timeout, {:call, from}, s))}

  def handle_call(:status, _from, s), do: {:reply, s.status, s}

  @impl true
  def handle_cast({:request, unit, request, pdu, timeout, to, ref}, s),
    do: {:noreply, submit(s, entry(unit, request, pdu, timeout, {:send, to, ref}, s))}

  @impl true
  def handle_info({:circuits_uart, uart, data}, %{uart: uart} = s) when is_binary(data),
    do: {:noreply, received(s, data)}

  def handle_info({:circuits_uart, uart, {:error, reason}}, %{uart: uart} = s),
    do: {:noreply, drop(s, reason)}

  def handle_info({:EXIT, uart, reason}, %{uart: uart} = s),
    do: {:noreply, drop(%{s | uart: nil}, reason)}

  def handle_info(:reopen, %{status: {:disconnected, _}} = s), do: {:noreply, open(s)}
  def handle_info(:send, s), do: {:noreply, next(%{s | sender: nil})}
  def handle_info(:silence, s), do: {:noreply, silence(%{s | silencer: nil})}
  def handle_info({:expire, id}, s), do: {:noreply, expire(s, id)}

  def handle_info({:broadcast, id}, %{current: %{id: id} = entry} = s) do
    _ = Process.cancel_timer(entry.timer)
    reply(entry, :ok)
    {:noreply, next(%{s | current: nil})}
  end

  def handle_info(_message, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s), do: if(s.uart, do: Serial.close(s.uart))

  defp entry(unit, request, pdu, timeout, reply, s) do
    %{
      id: make_ref(),
      unit: unit,
      request: request,
      pdu: pdu,
      timeout: timeout || s.timeout,
      reply: reply,
      timer: nil
    }
  end

  defp submit(s, entry) do
    cond do
      match?({:disconnected, _}, s.status) ->
        reply(entry, {:error, :closed})
        s

      entry.unit in 248..255 or (entry.unit == 0 and not broadcast?(entry.request)) ->
        reply(entry, {:error, :invalid_unit})
        s

      true ->
        timer = Process.send_after(self(), {:expire, entry.id}, entry.timeout)
        next(%{s | queue: :queue.in(%{entry | timer: timer}, s.queue)})
    end
  end

  defp broadcast?(request) when is_tuple(request), do: elem(request, 0) in @broadcast
  defp broadcast?(_request), do: false

  # Sends the next request once the line is free and has been quiet long enough.
  defp next(%{status: :connected, current: nil, sender: nil} = s) do
    wait = s.quiet + s.gap - now()

    cond do
      :queue.is_empty(s.queue) -> s
      wait > 0 -> %{s | sender: Process.send_after(self(), :send, wait)}
      true -> transmit(s)
    end
  end

  defp next(s), do: s

  defp transmit(s) do
    {{:value, entry}, queue} = :queue.out(s.queue)
    s = %{s | queue: queue, buffer: <<>>}

    frame =
      case s.mode do
        :rtu -> RTU.encode(entry.unit, entry.pdu)
        :ascii -> ASCII.encode(entry.unit, entry.pdu)
      end

    case Serial.write(s.uart, frame) do
      :ok ->
        sending = Serial.send_time(byte_size(frame), s)
        echoing = if s.echo, do: frame, else: <<>>
        s = %{s | current: entry, quiet: now() + sending, echoing: echoing}

        _ =
          if entry.unit == 0,
            do: Process.send_after(self(), {:broadcast, entry.id}, sending + s.turnaround)

        s

      {:error, reason} ->
        drop(%{s | queue: :queue.in_r(entry, s.queue)}, reason)
    end
  end

  defp received(s, data) do
    _ = if s.silencer, do: Process.cancel_timer(s.silencer)
    # An adapter that echoes gives back the request first: never to be taken for the answer, which
    # for a write is the same bytes.
    {echoing, data} = Serial.strip_echo(s.echoing, data)

    s = %{
      s
      | quiet: now(),
        echoing: echoing,
        silencer: Process.send_after(self(), :silence, s.silence)
    }

    case s.current do
      %{unit: unit} when unit != 0 -> answer(%{s | buffer: s.buffer <> data})
      # Nobody asked: a late answer, or a device that talks out of turn.
      _ -> s
    end
  end

  defp answer(%{mode: :rtu, current: entry} = s) do
    case RTU.split(s.buffer, [&PDU.response_length(entry.request, &1)]) do
      {:ok, frame, rest} ->
        case RTU.decode(frame) do
          {:ok, unit, pdu} when unit == entry.unit -> done(s, pdu)
          _other -> answer(%{s | buffer: rest})
        end

      :skip ->
        <<_byte, rest::binary>> = s.buffer
        answer(%{s | buffer: rest})

      _more_or_unknown ->
        s
    end
  end

  defp answer(%{mode: :ascii, current: entry} = s) do
    case ASCII.split(s.buffer, ?\n) do
      {:ok, frame, rest} ->
        case ASCII.decode(frame) do
          {:ok, unit, pdu} when unit == entry.unit -> done(s, pdu)
          _other -> answer(%{s | buffer: rest})
        end

      {:skip, rest} ->
        answer(%{s | buffer: rest})

      :more ->
        s
    end
  end

  # Quiet on the line ends a frame of a length nothing told.
  defp silence(%{mode: :rtu, current: %{unit: unit}, buffer: buffer} = s)
       when unit != 0 and buffer != <<>> do
    case RTU.decode(buffer) do
      {:ok, ^unit, pdu} -> done(s, pdu)
      _other -> %{s | buffer: <<>>}
    end
  end

  defp silence(%{mode: :rtu} = s), do: %{s | buffer: <<>>}
  defp silence(s), do: s

  defp done(%{current: entry} = s, pdu) do
    _ = Process.cancel_timer(entry.timer)
    reply(entry, PDU.decode_response(entry.request, pdu))
    next(%{s | current: nil, buffer: <<>>})
  end

  defp expire(%{current: %{id: id} = entry} = s, id) do
    reply(entry, {:error, :timeout})
    next(%{s | current: nil, buffer: <<>>})
  end

  defp expire(s, id) do
    {expired, kept} = s.queue |> :queue.to_list() |> Enum.split_with(&(&1.id == id))
    Enum.each(expired, &reply(&1, {:error, :timeout}))
    %{s | queue: :queue.from_list(kept)}
  end

  defp open(s) do
    case Serial.open(s.device, s) do
      {:ok, uart} ->
        next(%{s | uart: uart, status: :connected, delay: elem(s.backoff, 0), quiet: now()})

      {:error, reason} ->
        drop(s, reason)
    end
  end

  # Fails everything waiting and opens the port again after the backoff delay.
  defp drop(s, reason) do
    if s.uart, do: Serial.close(s.uart)
    _ = if s.sender, do: Process.cancel_timer(s.sender)

    for entry <- List.wrap(s.current) ++ :queue.to_list(s.queue) do
      _ = Process.cancel_timer(entry.timer)
      reply(entry, {:error, :closed})
    end

    {_first, longest} = s.backoff
    Process.send_after(self(), :reopen, s.delay)

    %{
      s
      | uart: nil,
        status: {:disconnected, reason},
        current: nil,
        queue: :queue.new(),
        buffer: <<>>,
        sender: nil,
        delay: min(s.delay * 2, longest)
    }
  end

  defp reply(%{reply: {:call, from}}, result), do: GenServer.reply(from, result)
  defp reply(%{reply: {:send, to, ref}}, result), do: send(to, {Modbus.Client, ref, result})

  defp now, do: System.monotonic_time(:millisecond)
end
