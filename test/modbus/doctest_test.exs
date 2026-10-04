defmodule Modbus.DocTest do
  use ExUnit.Case, async: true

  doctest Modbus
  doctest Modbus.PDU
  doctest Modbus.TCP
  doctest Modbus.RTU
  doctest Modbus.ASCII
  doctest Modbus.Client
  doctest Modbus.Server
  doctest Modbus.Memory
end
