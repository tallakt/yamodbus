defmodule Modbus.Test.Pty do
  @moduledoc false
  # A serial line for tests: two pseudo-terminals joined back to back by socat, as {a, b}.
  import ExUnit.Assertions
  import ExUnit.Callbacks

  def pair do
    port =
      Port.open({:spawn_executable, System.find_executable("socat")}, [
        :binary,
        :stderr_to_stdout,
        args: ["-d", "-d", "pty,raw,echo=0", "pty,raw,echo=0"]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["#{os_pid}"]) end)
    names(port, "")
  end

  defp names(port, output) do
    case Regex.scan(~r/PTY is (\S+)/, output, capture: :all_but_first) do
      [[a], [b]] ->
        {a, b}

      _ ->
        receive do
          {^port, {:data, data}} -> names(port, output <> data)
        after
          2000 -> flunk("socat did not open a pty pair: #{output}")
        end
    end
  end
end
