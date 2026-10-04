defmodule Modbus.TCP do
  @moduledoc """
  Modbus over TCP: each PDU behind a seven byte MBAP header that holds a transaction id, the
  protocol id 0, the length of what follows, and the unit id. The client picks the transaction id
  and the server echoes it, which lets the client have many requests on the way at once and tell the
  answers apart.

      iex> frame = Modbus.TCP.encode(1, 255, <<3, 0, 4, 0, 1>>)
      <<0, 1, 0, 0, 0, 6, 255, 3, 0, 4, 0, 1>>
      iex> Modbus.TCP.decode(frame <> <<0, 2>>)
      {:ok, {1, 255, <<3, 0, 4, 0, 1>>}, <<0, 2>>}

  Port 502 is Modbus's, and 802 is that of Modbus/TCP Security, the same frames over TLS.
  """

  @doc """
  A PDU as a frame, with its transaction id (0 to 65535) and unit id.
  """
  @spec encode(0..65535, Modbus.unit(), binary) :: binary
  def encode(transaction, unit, pdu)
      when transaction in 0..65535 and unit in 0..255 and byte_size(pdu) in 1..253,
      do: <<transaction::16, 0::16, byte_size(pdu) + 1::16, unit, pdu::binary>>

  @doc """
  The first frame in what has come over a connection so far:

    * `{:ok, {transaction, unit, pdu}, rest}` for a whole frame
    * `:more` for the start of one
    * `{:discard, rest}` for a frame of some other protocol than Modbus (an id other than 0), which
      the spec says to drop
    * `{:error, :invalid_length}` for a header that can't be Modbus's, after which there's no telling
      where the next frame starts

  A frame's length counts the unit id and a PDU of 1 to 253 bytes.

      iex> Modbus.TCP.decode(<<0, 1, 0, 0, 0, 6, 255, 3>>)
      :more
      iex> Modbus.TCP.decode(<<0, 1, 0, 0, 1, 0, 255, 3>>)
      {:error, :invalid_length}
  """
  @spec decode(binary) ::
          {:ok, {0..65535, Modbus.unit(), binary}, binary}
          | {:discard, binary}
          | :more
          | {:error, :invalid_length}
  def decode(<<transaction::16, protocol::16, length::16, rest::binary>>) when length in 2..254 do
    case rest do
      <<unit, pdu::binary-size(length - 1), rest::binary>> when protocol == 0 ->
        {:ok, {transaction, unit, pdu}, rest}

      <<_frame::binary-size(length), rest::binary>> ->
        {:discard, rest}

      _partial ->
        :more
    end
  end

  def decode(<<_transaction::16, _protocol::16, _length::16, _rest::binary>>),
    do: {:error, :invalid_length}

  def decode(_partial), do: :more
end
