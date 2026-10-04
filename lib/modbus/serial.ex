defmodule Modbus.Serial do
  @moduledoc false
  # The serial port, through circuits_uart, an optional dependency: its C program runs as a port, an
  # OS process of its own, so a crash in it closes the port rather than taking down the BEAM. The
  # UART's process is linked to the one that opens it, which traps exits to hear of its end.
  @compile {:no_warn_undefined, Circuits.UART}

  def available?, do: Code.ensure_loaded?(Circuits.UART)

  # Opens `device` for the calling process, which then gets {:circuits_uart, uart, data} messages.
  def open(device, config) do
    if available?() do
      {:ok, uart} = Circuits.UART.start_link()

      options = [
        speed: config.speed,
        data_bits: config.data_bits,
        parity: config.parity,
        stop_bits: config.stop_bits,
        flow_control: :none,
        active: true,
        id: :pid
      ]

      opened(uart, call(fn -> Circuits.UART.open(uart, device, options) end))
    else
      {:error, :circuits_uart_missing}
    end
  end

  defp opened(uart, :ok), do: {:ok, uart}

  defp opened(uart, {:error, reason}) do
    close(uart)
    {:error, reason}
  end

  def write(uart, data), do: call(fn -> Circuits.UART.write(uart, data) end)

  def close(uart) do
    Process.unlink(uart)
    _ = call(fn -> Circuits.UART.stop(uart) end)
    :ok
  end

  # The UART's process may be gone or hung; neither may take its owner down.
  defp call(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:uart, reason}}
  end

  # Passes over the echo of what was just sent, on an adapter that echoes: {what's still to come of
  # it, the data after it}. Data that isn't the echo, as after a collision on the line, ends the
  # wait for it.
  def strip_echo(<<>>, data), do: {<<>>, data}

  def strip_echo(echo, data) do
    size = min(byte_size(echo), byte_size(data))
    <<head::binary-size(size), still::binary>> = echo

    case data do
      <<^head::binary-size(size), rest::binary>> -> {still, rest}
      _other -> {<<>>, data}
    end
  end

  # How many bits a character takes on the line: start, data, parity and stop bits.
  def char_bits(config),
    do: 1 + config.data_bits + if(config.parity == :none, do: 0, else: 1) + config.stop_bits

  # How long `bytes` take to send, in milliseconds, rounded up.
  def send_time(bytes, config),
    do: div(bytes * char_bits(config) * 1000 + config.speed - 1, config.speed)
end
