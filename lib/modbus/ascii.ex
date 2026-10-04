defmodule Modbus.ASCII do
  @moduledoc """
  Modbus ASCII, on serial lines: each byte of the unit id, the PDU and an LRC as two hexadecimal
  digits, between a colon and a carriage return and line feed.

      iex> frame = Modbus.ASCII.encode(17, <<3, 0, 107, 0, 3>>)
      ":1103006B00037E\\r\\n"
      iex> Modbus.ASCII.decode(frame)
      {:ok, 17, <<3, 0, 107, 0, 3>>}

  A frame is at most 513 characters. A server can be told to end frames with another character than
  the line feed, by the diagnostics sub-function 3, Change ASCII Input Delimiter.
  """

  import Bitwise

  # The colon, the unit id, a PDU of 253 bytes and the LRC as hex, CR and the delimiter.
  @longest 513

  @doc """
  The LRC of the spec: the two's complement of the sum of the bytes.

      iex> Modbus.ASCII.lrc(<<17, 3, 0, 107, 0, 3>>)
      0x7E
  """
  @spec lrc(binary) :: byte
  def lrc(data), do: 0x100 - rem(sum(data, 0), 0x100) &&& 0xFF

  defp sum(<<byte, rest::binary>>, sum), do: sum(rest, sum + byte)
  defp sum(<<>>, sum), do: sum

  @doc """
  A PDU as a frame for unit `unit`, ended with CR and `delimiter` (a line feed by default).
  """
  @spec encode(Modbus.unit(), binary, byte) :: binary
  def encode(unit, pdu, delimiter \\ ?\n) when unit in 0..255 and byte_size(pdu) in 1..253 do
    data = <<unit, pdu::binary>>
    ":" <> Base.encode16(<<data::binary, lrc(data)>>) <> <<?\r, delimiter>>
  end

  @doc """
  The unit id and PDU of a whole frame, from its colon to its delimiter. `{:error, :checksum}` if
  the LRC is wrong, `{:error, :invalid}` if it isn't a frame at all.

      iex> Modbus.ASCII.decode(":1103006B00037F\\r\\n")
      {:error, :checksum}
      iex> Modbus.ASCII.decode(":11030\\r\\n")
      {:error, :invalid}
  """
  @spec decode(binary) :: {:ok, Modbus.unit(), binary} | {:error, :checksum | :invalid}
  def decode(frame) when byte_size(frame) in 9..@longest do
    size = byte_size(frame) - 3

    with <<?:, hex::binary-size(size), ?\r, _delimiter>> <- frame,
         {:ok, <<unit, pdu::binary>> = bytes} when byte_size(pdu) >= 2 <-
           Base.decode16(hex, case: :mixed) do
      data_size = byte_size(bytes) - 1
      <<data::binary-size(data_size), lrc>> = bytes

      if lrc(data) == lrc,
        do: {:ok, unit, binary_part(pdu, 0, byte_size(pdu) - 1)},
        else: {:error, :checksum}
    else
      _ -> {:error, :invalid}
    end
  end

  def decode(_frame), do: {:error, :invalid}

  @doc false
  # The frame at the start of `buffer`, ended by `delimiter`: {:ok, frame, rest}, :more, or {:skip,
  # rest} past what can't be part of one. A colon starts a frame afresh, as the spec has it.
  def split(<<>>, _delimiter), do: :more

  def split(buffer, delimiter) do
    case :binary.match(buffer, ":") do
      :nomatch -> {:skip, <<>>}
      {0, _} -> frame(buffer, delimiter)
      {at, _} -> {:skip, binary_part(buffer, at, byte_size(buffer) - at)}
    end
  end

  # A buffer that starts with a colon: up to the delimiter, unless another colon comes first.
  defp frame(<<_colon, body::binary>> = buffer, delimiter) do
    case {:binary.match(body, <<delimiter>>), :binary.match(body, ":")} do
      {{at, _}, colon} when colon == :nomatch or elem(colon, 0) > at -> ended(buffer, body, at)
      {_delimiter, {at, _}} -> {:skip, binary_part(body, at, byte_size(body) - at)}
      {:nomatch, :nomatch} when byte_size(buffer) < @longest -> :more
      {:nomatch, :nomatch} -> {:skip, <<>>}
    end
  end

  defp ended(buffer, _body, at) when at + 2 <= @longest do
    <<frame::binary-size(at + 2), rest::binary>> = buffer
    {:ok, frame, rest}
  end

  defp ended(_buffer, body, at), do: {:skip, binary_part(body, at + 1, byte_size(body) - at - 1)}
end
