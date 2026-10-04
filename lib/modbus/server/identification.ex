defmodule Modbus.Server.Identification do
  @moduledoc false
  # Read Device Identification (43/14) from a map of object ids to values, as the spec has a server
  # answer it: by category, in as many responses as it takes, or one object at a time.

  # A response's header, before the objects: function code, MEI type, code, conformity level, more
  # follows, next object id and number of objects.
  @room 253 - 7

  def check!(objects) when is_map(objects) do
    for {id, value} <- objects do
      if not (is_integer(id) and id in 0..255 and is_binary(value) and
                byte_size(value) <= @room - 2),
         do:
           raise(
             ArgumentError,
             "identification: takes object ids 0 to 255 and values of up to #{@room - 2} bytes, " <>
               "got: #{inspect({id, value})}"
           )
    end

    case [0, 1, 2] -- Map.keys(objects) do
      [] ->
        objects

      missing ->
        raise ArgumentError,
              "identification: needs the basic objects 0, 1 and 2, missing: #{inspect(missing)}"
    end
  end

  def check!(objects),
    do: raise(ArgumentError, "identification: must be a map, got: #{inspect(objects)}")

  def answer(objects, {:read_device_identification, :individual, id}) do
    case objects do
      %{^id => value} -> {:ok, response(objects, false, 0, [{id, value}])}
      _ -> {:error, {:exception, :illegal_data_address}}
    end
  end

  # A category above what the device has is answered with what it has; an object that isn't there
  # starts from the beginning.
  def answer(objects, {:read_device_identification, category, from}) do
    last = min(last(category), last(level(objects)))
    ids = objects |> Map.keys() |> Enum.filter(&(&1 <= last)) |> Enum.sort()
    from = if from in ids, do: from, else: 0
    {sent, rest} = fit(Enum.drop_while(ids, &(&1 < from)), objects, @room, [])

    case rest do
      [] -> {:ok, response(objects, false, 0, sent)}
      [next | _] -> {:ok, response(objects, true, next, sent)}
    end
  end

  defp fit([id | ids], objects, room, sent) do
    size = 2 + byte_size(objects[id])

    if size <= room,
      do: fit(ids, objects, room - size, [{id, objects[id]} | sent]),
      else: {Enum.reverse(sent), [id | ids]}
  end

  defp fit([], _objects, _room, sent), do: {Enum.reverse(sent), []}

  # Individual access is always there, hence 0x80.
  defp response(objects, more, next, sent),
    do: %{
      conformity_level: 0x80 + level(objects),
      more_follows: more,
      next_object_id: next,
      objects: sent
    }

  defp level(objects) do
    cond do
      Enum.any?(Map.keys(objects), &(&1 >= 0x80)) -> 3
      Enum.any?(Map.keys(objects), &(&1 >= 3)) -> 2
      true -> 1
    end
  end

  defp last(category) when category in [:basic, 1], do: 2
  defp last(category) when category in [:regular, 2], do: 0x7F
  defp last(category) when category in [:extended, 3], do: 0xFF
end
