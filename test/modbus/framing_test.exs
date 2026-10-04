defmodule Modbus.FramingTest do
  use ExUnit.Case, async: true

  alias Modbus.{ASCII, PDU, RTU, TCP}

  describe "TCP" do
    test "frames one after another, and a part of one" do
      a = TCP.encode(1, 1, <<3, 0, 0, 0, 1>>)
      b = TCP.encode(2, 1, <<3, 0, 1, 0, 1>>)
      <<part::binary-size(4), _::binary>> = b

      assert {:ok, {1, 1, <<3, 0, 0, 0, 1>>}, rest} = TCP.decode(a <> part)
      assert rest == part
      assert TCP.decode(rest) == :more
    end

    test "a frame of another protocol is discarded whole" do
      other = <<7::16, 1::16, 3::16, 1, 2, 3>>
      next = TCP.encode(8, 1, <<7>>)
      assert TCP.decode(other <> next) == {:discard, next}
    end

    test "a length that can't be Modbus's is an error" do
      assert TCP.decode(<<1::16, 0::16, 0::16, 1>>) == {:error, :invalid_length}
      assert TCP.decode(<<1::16, 0::16, 1::16, 1>>) == {:error, :invalid_length}
      assert TCP.decode(<<1::16, 0::16, 255::16, 1>>) == {:error, :invalid_length}
      assert {:ok, _, _} = TCP.decode(<<1::16, 0::16, 254::16, 1, 3, 0::2016>>)
    end
  end

  describe "RTU" do
    test "a request, found by its length" do
      frame = RTU.encode(17, <<16, 0, 1, 0, 2, 4, 0, 10, 1, 2>>)
      assert RTU.split(frame <> <<1, 2>>, [&PDU.request_length/1]) == {:ok, frame, <<1, 2>>}
      assert RTU.split(binary_part(frame, 0, 5), [&PDU.request_length/1]) == :more
    end

    test "bytes that start no frame are passed over one at a time" do
      frame = RTU.encode(1, <<3, 0, 0, 0, 1>>)
      assert RTU.split(<<0xFF, 0xFF>> <> frame, [&PDU.request_length/1]) == :skip
      assert RTU.split(<<0xFF>> <> frame, [&PDU.request_length/1]) == :skip
      assert RTU.split(frame, [&PDU.request_length/1]) == {:ok, frame, <<>>}
    end

    test "a server hears requests and others' answers on the same line" do
      lengths = [&PDU.request_length/1, &PDU.response_length(nil, &1)]
      request = RTU.encode(5, <<3, 0, 0, 0, 1>>)
      answer = RTU.encode(5, <<3, 2, 0, 42>>)
      assert {:ok, ^request, rest} = RTU.split(request <> answer, lengths)
      assert {:ok, ^answer, <<>>} = RTU.split(rest, lengths)
    end

    test "noise before a frame for a unit that reads as an unknown function code" do
      lengths = [&PDU.request_length/1, &PDU.response_length(nil, &1)]
      frame = RTU.encode(50, <<3, 0, 0, 0, 1>>)
      assert RTU.split(<<0x11>> <> frame, lengths) == :unknown
      assert RTU.resync(<<0x11>> <> frame, lengths) == 1
      assert RTU.resync(<<0x11, 0x32, 0x55>>, lengths) == nil
      assert RTU.split(frame, lengths) == {:ok, frame, <<>>}
    end

    test "the CRC from a table gives the spec's" do
      assert RTU.crc(<<>>) == 0xFFFF
      assert RTU.crc(<<1, 3, 0, 0, 0, 10>>) == 0xCDC5
    end

    test "only silence can end a frame whose length nothing tells" do
      frame = RTU.encode(1, <<100, 1, 2, 3>>)
      assert RTU.split(frame, [&PDU.request_length/1]) == :unknown
      assert RTU.decode(frame) == {:ok, 1, <<100, 1, 2, 3>>}
    end
  end

  describe "an adapter's echo" do
    test "is passed over, in as many pieces as it comes" do
      assert Modbus.Serial.strip_echo(<<>>, <<1, 2>>) == {<<>>, <<1, 2>>}
      assert Modbus.Serial.strip_echo(<<1, 2, 3>>, <<1, 2, 3, 9>>) == {<<>>, <<9>>}
      assert Modbus.Serial.strip_echo(<<1, 2, 3>>, <<1>>) == {<<2, 3>>, <<>>}
      assert Modbus.Serial.strip_echo(<<2, 3>>, <<2, 3, 4>>) == {<<>>, <<4>>}
    end

    test "that doesn't come as sent isn't waited for" do
      assert Modbus.Serial.strip_echo(<<1, 2, 3>>, <<7, 8>>) == {<<>>, <<7, 8>>}
    end
  end

  describe "ASCII" do
    test "a frame between colon and line feed" do
      frame = ASCII.encode(1, <<3, 0, 0, 0, 1>>)
      assert ASCII.split("junk" <> frame <> ":01", ?\n) == {:skip, frame <> ":01"}
      assert ASCII.split(frame <> ":01", ?\n) == {:ok, frame, ":01"}
      assert ASCII.split(":0103", ?\n) == :more
      assert ASCII.split("", ?\n) == :more
    end

    test "a colon starts a frame afresh" do
      frame = ASCII.encode(1, <<3, 0, 0, 0, 1>>)
      assert ASCII.split(":0103" <> frame, ?\n) == {:skip, frame}
    end

    test "another delimiter" do
      frame = ASCII.encode(1, <<3, 0, 0, 0, 1>>, ?!)
      assert String.ends_with?(frame, "\r!")
      assert ASCII.split(frame, ?!) == {:ok, frame, <<>>}
      assert ASCII.decode(frame) == {:ok, 1, <<3, 0, 0, 0, 1>>}
    end

    test "lower case hex is read too" do
      assert ASCII.decode(":1103006b00037e\r\n") == {:ok, 17, <<3, 0, 107, 0, 3>>}
    end

    test "a frame too long is dropped" do
      long = ":" <> String.duplicate("00", 300)
      assert ASCII.split(long, ?\n) == {:skip, <<>>}
    end
  end
end
