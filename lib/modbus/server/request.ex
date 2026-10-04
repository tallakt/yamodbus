defmodule Modbus.Server.Request do
  @moduledoc false
  # What every server does with a request PDU, whatever the transport: decode it, check that the
  # client may make it, and answer from the identification objects or the handler.
  import Bitwise

  alias Modbus.PDU

  # The request in a PDU, or the exception response to one that can't be served; nil for a PDU with
  # no function code, which has nothing to answer.
  def decode(<<>>), do: nil

  def decode(<<function, _::binary>> = pdu) do
    case PDU.decode_request(pdu) do
      {:ok, request} -> {:ok, request}
      {:error, exception} -> {:error, <<function ||| 0x80, Modbus.exception_code(exception)>>}
    end
  end

  # The response PDU to a request.
  def respond(config, role, unit, request) do
    result =
      timed(config, fn ->
        cond do
          not authorized?(config.authorize, role, unit, request) ->
            {:error, {:exception, :illegal_function}}

          config.identification != nil and match?({:read_device_identification, _, _}, request) ->
            Modbus.Server.Identification.answer(config.identification, request)

          true ->
            handle(config.handler, unit, request)
        end
      end)

    encode(request, result)
  end

  # Whether the client may make a request the server answers itself, as a serial server does its
  # diagnostics.
  def allowed?(config, role, unit, request),
    do: timed(config, fn -> authorized?(config.authorize, role, unit, request) end) == true

  # The authorization and the handler run in a process of their own, for handler_timeout at most:
  # one that never returns can't hold up the connection, or a serial server, for good.
  defp timed(config, fun) do
    caller = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            fun.()
          catch
            _kind, _reason -> {:error, {:exception, :server_device_failure}}
          end

        send(caller, {ref, result})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, {:exception, :server_device_failure}}
    after
      config.handler_timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        receive do
          {^ref, result} -> result
        after
          0 -> {:error, {:exception, :server_device_failure}}
        end
    end
  end

  @doc false
  # The handler's result, or the exception for a handler that crashed. A gateway's handler may give
  # back what its own client got: a timeout or a lost connection on the far side are the gateway
  # exceptions.
  def handle(handler, unit, request) do
    case call(handler, unit, request) do
      {:error, :timeout} -> {:error, {:exception, :gateway_target_device_failed_to_respond}}
      {:error, :closed} -> {:error, {:exception, :gateway_path_unavailable}}
      result -> result
    end
  catch
    _kind, _reason -> {:error, {:exception, :server_device_failure}}
  end

  defp call({module, arg}, unit, request), do: module.handle_request(unit, request, arg)
  defp call(fun, unit, request) when is_function(fun, 2), do: fun.(unit, request)

  # A result that doesn't answer the request is the server's failure, not the client's.
  def encode(request, result) do
    PDU.encode_response(request, result)
  rescue
    ArgumentError -> PDU.encode_response(request, {:error, {:exception, :server_device_failure}})
  end

  defp authorized?(nil, _role, _unit, _request), do: true

  defp authorized?(authorize, role, unit, request) do
    authorize.(role, unit, request) == true
  catch
    _kind, _reason -> false
  end
end
