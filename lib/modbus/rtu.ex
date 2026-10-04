defmodule Modbus.RTU do
  @moduledoc """
  Modbus RTU, on serial lines: each PDU between the unit id and a CRC-16, low byte first, and frames
  apart by at least 3.5 characters of silence.

      iex> frame = Modbus.RTU.encode(1, <<3, 0, 0, 0, 10>>)
      <<1, 3, 0, 0, 0, 10, 197, 205>>
      iex> Modbus.RTU.decode(frame)
      {:ok, 1, <<3, 0, 0, 0, 10>>}

  A frame is at most 256 bytes. Neither a client nor a server here relies on timing the silence
  between frames, which the BEAM's timers and the buffering of USB serial adapters can't do to a
  fraction of a millisecond: a frame ends where its function code and byte counts say, and the CRC
  confirms it. Silence ends only the frames whose length nothing tells, and on a busy line a frame
  that doesn't check out is passed over byte by byte until one does.
  """

  import Bitwise

  @doc """
  The CRC-16 of the spec (the polynomial 0xA001, from 0xFFFF).

      iex> Modbus.RTU.crc(<<2, 7>>)
      0x1241
  """
  @spec crc(binary) :: 0..65535
  def crc(data), do: crc(data, 0xFFFF)

  # A byte at a time from a table, rather than a bit at a time.
  @table for(
           n <- 0..255,
           do:
             Enum.reduce(1..8, n, fn _bit, crc ->
               if (crc &&& 1) == 1, do: bxor(crc >>> 1, 0xA001), else: crc >>> 1
             end)
         )
         |> List.to_tuple()

  defp crc(<<byte, rest::binary>>, crc),
    do: crc(rest, bxor(crc >>> 8, elem(@table, bxor(crc, byte) &&& 0xFF)))

  defp crc(<<>>, crc), do: crc

  @doc """
  A PDU as a frame for unit `unit`.
  """
  @spec encode(Modbus.unit(), binary) :: binary
  def encode(unit, pdu) when unit in 0..255 and byte_size(pdu) in 1..253 do
    frame = <<unit, pdu::binary>>
    <<frame::binary, crc(frame)::little-16>>
  end

  @doc """
  The unit id and PDU of a whole frame, or `{:error, :checksum}` if its CRC is wrong.

      iex> Modbus.RTU.decode(<<1, 3, 0, 0, 0, 10, 197, 206>>)
      {:error, :checksum}
  """
  @spec decode(binary) :: {:ok, Modbus.unit(), binary} | {:error, :checksum}
  def decode(frame) when byte_size(frame) in 4..256 do
    size = byte_size(frame) - 2
    <<data::binary-size(size), crc::little-16>> = frame

    case {crc(data) == crc, data} do
      {true, <<unit, pdu::binary>>} -> {:ok, unit, pdu}
      {false, _data} -> {:error, :checksum}
    end
  end

  def decode(_frame), do: {:error, :checksum}

  @doc """
  The silence that separates frames, 3.5 characters of 11 bits, in microseconds: fixed at 1750 above
  19200 baud, as the spec recommends.

      iex> Modbus.RTU.frame_gap(9600)
      4011
      iex> Modbus.RTU.frame_gap(115_200)
      1750
  """
  @spec frame_gap(pos_integer) :: pos_integer
  def frame_gap(speed) when speed > 19200, do: 1750
  def frame_gap(speed) when speed > 0, do: div(38_500_000 + speed - 1, speed)

  @doc false
  # The frame at the start of `buffer`, given the functions that tell the length of a PDU from its
  # first bytes (see Modbus.PDU.request_length/1): {:ok, frame, rest} for one whose CRC checks out,
  # :more if it may yet become one, :unknown if only silence can end it, or :skip if the first byte
  # starts no frame.
  def split(buffer, lengths), do: at(buffer, lengths)

  @doc false
  # Where in `buffer`, after its first byte, a whole frame of known length starts, or nil. A start
  # that split/2 finds :unknown, a function code nothing tells the length of, is more likely noise
  # than a custom function when a frame checks out further on. It costs a CRC at each place a frame
  # could start, so a caller doesn't look for one at every byte.
  def resync(buffer, lengths) do
    size = byte_size(buffer)

    Enum.find(1..(size - 4)//1, fn offset ->
      match?({:ok, _, _}, at(binary_part(buffer, offset, size - offset), lengths))
    end)
  end

  defp at(<<_unit, pdu::binary>> = buffer, lengths) do
    lengths = for length <- lengths, do: length.(pdu)

    whole =
      Enum.find_value(lengths, fn
        {:ok, n} when n + 3 <= byte_size(buffer) and n + 3 <= 256 ->
          <<frame::binary-size(n + 3), rest::binary>> = buffer
          if match?({:ok, _, _}, decode(frame)), do: {:ok, frame, rest}

        _other ->
          nil
      end)

    cond do
      whole -> whole
      Enum.any?(lengths, &waiting?(&1, buffer)) -> :more
      :unknown in lengths and byte_size(buffer) <= 256 -> :unknown
      true -> :skip
    end
  end

  defp at(_short, _lengths), do: :more

  defp waiting?(:more, _buffer), do: true
  defp waiting?({:ok, n}, buffer), do: n + 3 > byte_size(buffer) and n + 3 <= 256
  defp waiting?(_unknown_or_invalid, _buffer), do: false
end
