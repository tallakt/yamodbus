defmodule Modbus.Server.Line do
  @moduledoc false
  # A server on a serial line, RTU or ASCII. It hears every frame on the line, the requests to other
  # units and their answers too, and keeps the diagnostic counters and event log of the serial line
  # spec (Appendix A) and the application protocol (functions 8, 11 and 12).
  use GenServer

  import Bitwise

  alias Modbus.{ASCII, PDU, RTU, Serial}
  alias Modbus.Server.Request

  @broadcast [
    :write_single_coil,
    :write_single_register,
    :write_multiple_coils,
    :write_multiple_registers,
    :write_file_record,
    :mask_write_register,
    :custom
  ]

  # The diagnostics sub-functions that return a counter.
  @counters %{
    0x0B => :bus_message,
    0x0C => :bus_communication_error,
    0x0D => :bus_exception_error,
    0x0E => :server_message,
    0x0F => :server_no_response,
    0x10 => :server_nak,
    0x11 => :server_busy,
    0x12 => :bus_character_overrun
  }
  @zero Map.new(Map.values(@counters), &{&1, 0})

  # The diagnostics, and the comm event functions, a serial server answers itself.
  @own [:get_comm_event_counter, :get_comm_event_log]

  # What can't end an ASCII frame: a hex digit, the colon or CR all come inside one.
  @in_frame ~c"0123456789ABCDEFabcdef:\r"

  def config!(transport, opts) do
    known =
      [:handler, :authorize, :identification, :units, :speed, :data_bits, :parity, :stop_bits] ++
        [:handler_timeout, :echo, :name, transport]

    Modbus.Client.unknown!(opts, known)
    device = Keyword.fetch!(opts, transport)

    if not is_binary(device),
      do: raise(ArgumentError, "#{transport}: must be a device name, got: #{inspect(device)}")

    units = List.wrap(Keyword.get(opts, :units, []))

    if units == [] or not Enum.all?(units, &(is_integer(&1) and &1 in 1..247)),
      do:
        raise(
          ArgumentError,
          "units: must be the unit ids to answer, 1 to 247, got: #{inspect(units)}"
        )

    line =
      Modbus.Client.Line.config!(
        transport,
        device,
        Keyword.take(opts, [:speed, :data_bits, :parity, :stop_bits, :echo])
      )

    Map.merge(line, %{units: MapSet.new(units), backoff: {100, 5000}})
  end

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    s =
      Map.merge(config, %{
        uart: nil,
        status: :connecting,
        buffer: <<>>,
        silencer: nil,
        garbage: false,
        counters: @zero,
        events: [],
        event_count: 0,
        listen_only: false,
        delimiter: ?\n,
        echoing: <<>>,
        scanned: 0,
        delay: 100
      })

    {:ok, open(s)}
  end

  @impl true
  def handle_call(:port, _from, s), do: {:reply, nil, s}

  @impl true
  def handle_info({:circuits_uart, uart, data}, %{uart: uart} = s) when is_binary(data) do
    _ = if s.silencer, do: Process.cancel_timer(s.silencer)
    silence = if s.mode == :ascii, do: 1000, else: s.silence
    {echoing, data} = Serial.strip_echo(s.echoing, data)
    s = %{s | silencer: Process.send_after(self(), :silence, silence), echoing: echoing}
    {:noreply, frames(%{s | buffer: s.buffer <> data})}
  end

  def handle_info({:circuits_uart, uart, {:error, reason}}, %{uart: uart} = s),
    do: {:noreply, drop(s, reason)}

  def handle_info({:EXIT, uart, reason}, %{uart: uart} = s),
    do: {:noreply, drop(%{s | uart: nil}, reason)}

  def handle_info(:reopen, %{status: {:disconnected, _}} = s), do: {:noreply, open(s)}
  def handle_info(:silence, s), do: {:noreply, silence(%{s | silencer: nil})}
  def handle_info(_message, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s), do: if(s.uart, do: Serial.close(s.uart))

  defp frames(%{mode: :rtu} = s) do
    lengths = [&PDU.request_length/1, &PDU.response_length(nil, &1)]

    case RTU.split(s.buffer, lengths) do
      {:ok, frame, rest} ->
        {:ok, unit, pdu} = RTU.decode(frame)
        frames(frame(%{s | buffer: rest, garbage: false, scanned: 0}, unit, pdu))

      :skip ->
        <<_byte, rest::binary>> = s.buffer
        frames(%{garbled(s) | buffer: rest, scanned: 0})

      _more_or_unknown when byte_size(s.buffer) > 256 ->
        %{count(s, :bus_character_overrun) | buffer: <<>>, scanned: 0}

      :unknown when byte_size(s.buffer) >= s.scanned + 8 ->
        resync(s, lengths)

      _more_or_unknown ->
        s
    end
  end

  defp frames(%{mode: :ascii} = s) do
    case ASCII.split(s.buffer, s.delimiter) do
      {:ok, frame, rest} ->
        case ASCII.decode(frame) do
          {:ok, unit, pdu} -> frames(frame(%{s | buffer: rest}, unit, pdu))
          {:error, _} -> frames(%{count(s, :bus_communication_error) | buffer: rest})
        end

      {:skip, rest} ->
        frames(%{s | buffer: rest})

      :more ->
        s
    end
  end

  # A frame of unknown length at the start may be noise before a frame of known length: looking
  # for one costs a CRC at each place it could start, so it's done every 8 bytes, not every byte.
  defp resync(s, lengths) do
    case RTU.resync(s.buffer, lengths) do
      nil ->
        %{s | scanned: byte_size(s.buffer)}

      at ->
        <<_noise::binary-size(at), rest::binary>> = s.buffer
        frames(%{garbled(s) | buffer: rest, scanned: 0})
    end
  end

  # A run of bytes that start no frame counts as one communication error.
  defp garbled(%{garbage: true} = s), do: s
  defp garbled(s), do: %{count(s, :bus_communication_error) | garbage: true}

  # Silence ends an RTU frame whose length nothing told, or gives up on a partial one.
  defp silence(%{mode: :rtu, buffer: buffer} = s) when buffer != <<>> do
    lengths = [&PDU.request_length/1, &PDU.response_length(nil, &1)]

    case {RTU.decode(buffer), RTU.resync(buffer, lengths)} do
      {{:ok, unit, pdu}, _} ->
        frame(%{s | buffer: <<>>, scanned: 0}, unit, pdu)

      {_noise, nil} ->
        %{garbled(s) | buffer: <<>>, garbage: false, scanned: 0}

      {_noise, at} ->
        <<_noise::binary-size(at), rest::binary>> = buffer
        silence(frames(%{garbled(s) | buffer: rest, scanned: 0}))
    end
  end

  defp silence(%{mode: :ascii, buffer: buffer} = s) when buffer != <<>>,
    do: %{count(s, :bus_communication_error) | buffer: <<>>}

  defp silence(s), do: s

  defp frame(s, unit, pdu) do
    s = count(s, :bus_message)

    if unit == 0 or MapSet.member?(s.units, unit), do: request(s, unit, pdu), else: s
  end

  defp request(s, unit, pdu) do
    s = s |> count(:server_message) |> event(0x80 ||| broadcast_bit(unit) ||| listen_bit(s))
    decoded = Request.decode(pdu)

    cond do
      s.listen_only -> listening(s, unit, decoded)
      unit == 0 -> broadcast(s, decoded)
      true -> addressed(s, unit, decoded)
    end
  end

  # In listen only mode only a Restart Communications Option is acted on, and nothing is answered.
  defp listening(s, unit, {:ok, {:diagnostics, 1, [data]} = request}) when data in [0, 0xFF00] do
    if Request.allowed?(s, nil, unit, request),
      do: restart(s, data),
      else: count(s, :server_no_response)
  end

  defp listening(s, _unit, _decoded), do: count(s, :server_no_response)

  defp addressed(s, unit, {:ok, request}), do: authorized(s, unit, request)
  defp addressed(s, unit, {:error, response}), do: reply(s, unit, nil, response)

  # A broadcast is acted on if it's a write, and never answered.
  defp broadcast(s, {:ok, request}) do
    s = count(s, :server_no_response)

    if is_tuple(request) and elem(request, 0) in @broadcast do
      case PDU.decode_response(request, Request.respond(s, nil, 0, request)) do
        {:error, {:exception, _}} -> count(s, :bus_exception_error)
        _ok -> %{s | event_count: s.event_count + 1}
      end
    else
      s
    end
  end

  defp broadcast(s, {:error, _response}),
    do: s |> count(:server_no_response) |> count(:bus_exception_error)

  defp broadcast(s, nil), do: count(s, :server_no_response)

  # authorize: decides on what the server answers itself as on what goes to the handler, which
  # Request.respond/4 asks it about.
  defp authorized(s, unit, request) do
    own? = request in @own or match?({:diagnostics, _, _}, request)

    if own? and not Request.allowed?(s, nil, unit, request),
      do: reply(s, unit, request, PDU.encode_response(request, {:error, {:exception, 1}})),
      else: respond(s, unit, request)
  end

  defp respond(s, unit, {:diagnostics, sub, data} = request),
    do: diagnostics(s, unit, request, sub, data)

  defp respond(s, unit, :get_comm_event_counter = request),
    do:
      reply(
        s,
        unit,
        request,
        PDU.encode_response(request, {:ok, %{status: 0, event_count: s.event_count}})
      )

  defp respond(s, unit, :get_comm_event_log = request) do
    log = %{
      status: 0,
      event_count: s.event_count,
      message_count: s.counters.bus_message,
      events: s.events
    }

    reply(s, unit, request, PDU.encode_response(request, {:ok, log}))
  end

  defp respond(s, unit, request),
    do: reply(s, unit, request, Request.respond(s, nil, unit, request))

  defp diagnostics(s, unit, request, sub, data) do
    answer = fn result -> reply(s, unit, request, PDU.encode_response(request, result)) end
    diagnose(s, answer, sub, data)
  end

  # A sub-function the server knows, with the data it takes; the answer is sent by answer/1, which
  # gives the state after it.
  defp diagnose(_s, answer, 0, data), do: answer.({:ok, data})

  defp diagnose(_s, answer, 1, [option]) when option in [0, 0xFF00],
    do: answer.({:ok, [option]}) |> restart(option)

  defp diagnose(_s, answer, 2, [0]), do: answer.({:ok, [0]})

  # A delimiter that can come inside a frame would leave the server unable to read one again, a
  # Restart Communications Option included.
  defp diagnose(%{mode: :ascii}, answer, 3, [delimiter])
       when (delimiter &&& 0xFF) == 0 and (delimiter >>> 8) in @in_frame,
       do: answer.({:error, {:exception, :illegal_data_value}})

  defp diagnose(%{mode: :ascii}, answer, 3, [delimiter]) when (delimiter &&& 0xFF) == 0,
    do: %{answer.({:ok, [delimiter]}) | delimiter: delimiter >>> 8}

  defp diagnose(s, _answer, 4, [0]),
    do: %{count(s, :server_no_response) | listen_only: true} |> event(0x04)

  defp diagnose(_s, answer, 10, [0]), do: %{answer.({:ok, [0]}) | counters: @zero, event_count: 0}

  defp diagnose(s, answer, sub, [0]) when is_map_key(@counters, sub),
    do: answer.({:ok, [rem(s.counters[@counters[sub]], 65536)]})

  defp diagnose(_s, answer, 20, [0]) do
    s = answer.({:ok, [0]})
    %{s | counters: %{s.counters | bus_character_overrun: 0}}
  end

  defp diagnose(_s, answer, sub, _data)
       when sub in [1, 2, 4, 10, 20] or is_map_key(@counters, sub),
       do: answer.({:error, {:exception, :illegal_data_value}})

  defp diagnose(_s, answer, _sub, _data), do: answer.({:error, {:exception, :illegal_function}})

  # Restart Communications Option: out of listen only mode, the counters cleared, the ASCII
  # delimiter back to a line feed, and the event log cleared too if asked.
  defp restart(s, option) do
    events = if option == 0xFF00, do: [], else: s.events

    %{s | listen_only: false, counters: @zero, event_count: 0, events: events, delimiter: ?\n}
    |> event(0x00)
  end

  defp reply(s, unit, request, response) do
    Process.sleep(s.gap)

    frame =
      case s.mode do
        :rtu -> RTU.encode(unit, response)
        :ascii -> ASCII.encode(unit, response)
      end

    case Serial.write(s.uart, frame) do
      :ok -> sent(%{s | echoing: if(s.echo, do: frame, else: <<>>)}, request, response)
      {:error, reason} -> drop(s, reason)
    end
  end

  defp sent(s, _request, <<function, code>>) when function >= 0x80 do
    s = count(s, :bus_exception_error)
    s = if code == 6, do: count(s, :server_busy), else: s
    s = if code == 7, do: count(s, :server_nak), else: s

    bit =
      cond do
        code in 1..3 -> 0x01
        code == 4 -> 0x02
        code in 5..6 -> 0x04
        code == 7 -> 0x08
        true -> 0
      end

    event(s, 0x40 ||| bit ||| listen_bit(s))
  end

  defp sent(s, request, _response) do
    s = if request == :get_comm_event_counter, do: s, else: %{s | event_count: s.event_count + 1}
    event(s, 0x40 ||| listen_bit(s))
  end

  defp count(s, counter), do: %{s | counters: Map.update!(s.counters, counter, &(&1 + 1))}

  defp event(s, event), do: %{s | events: Enum.take([event | s.events], 64)}

  defp broadcast_bit(0), do: 0x40
  defp broadcast_bit(_unit), do: 0
  defp listen_bit(%{listen_only: true}), do: 0x20
  defp listen_bit(_s), do: 0

  defp open(s) do
    case Serial.open(s.device, s) do
      {:ok, uart} -> %{s | uart: uart, status: :connected, delay: 100}
      {:error, reason} -> drop(s, reason)
    end
  end

  defp drop(s, reason) do
    if s.uart, do: Serial.close(s.uart)
    Process.send_after(self(), :reopen, s.delay)
    %{s | uart: nil, status: {:disconnected, reason}, buffer: <<>>, delay: min(s.delay * 2, 5000)}
  end
end
