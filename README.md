# yamodbus

[![CI](https://github.com/tallakt/yamodbus/actions/workflows/ci.yml/badge.svg)](https://github.com/tallakt/yamodbus/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/yamodbus.svg)](https://hex.pm/packages/yamodbus)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-purple.svg)](https://hexdocs.pm/yamodbus)
[![License](https://img.shields.io/hexpm/l/yamodbus.svg)](https://github.com/tallakt/yamodbus/blob/main/LICENSE)

*Implemented by AI under the supervision of Tallak Tveide.*

Yet another Modbus: an independent Modbus stack in pure Elixir, for talking to
PLCs, drives, meters and gateways.

It does what the Modbus Organization's specifications define, and nothing on
top: the application protocol, Modbus over TCP, Modbus/TCP Security (TLS), and
RTU and ASCII on serial lines. It was written from those specifications, which
are free to download at [modbus.org](https://www.modbus.org/modbus-specifications),
not from another stack's code. Registers are 16-bit words and coils are
booleans, as on the wire: floats, 32-bit numbers, word order and the "40001"
numbering are the application's business.

**Status:** clients and servers on TCP, TLS, RTU and ASCII, with every public
function code of the spec; tested against [pymodbus](https://github.com/pymodbus-dev/pymodbus)
both ways on every transport, and against [libmodbus](https://libmodbus.org) both ways on
TCP and RTU. What's left is under [What's missing](#whats-missing).

## Client

```elixir
{:ok, client} = Modbus.Client.start_link(tcp: "10.0.0.20")

{:ok, [1500, 7]} = Modbus.Client.read_holding_registers(client, 1, 100, 2)
:ok = Modbus.Client.write_single_coil(client, 1, 5, true)
{:ok, %{0 => "Acme", 1 => "PD-100", 2 => "2.11"}} = Modbus.Client.read_device_identification(client, 1)

{:error, {:exception, :illegal_data_address}} = Modbus.Client.read_coils(client, 1, 9999, 1)
{:error, :timeout} = Modbus.Client.read_coils(client, 9, 0, 1)
```

The second argument is the unit id. `Modbus.Client.request/4` sends any
request as a tuple, and `send_request/4` sends one without waiting, the result
coming as a message:

```elixir
{:ok, words} = Modbus.Client.request(client, 1, {:read_input_registers, 0, 10}, timeout: 500)

ref = Modbus.Client.send_request(client, 1, {:read_holding_registers, 0, 125})
receive do
  {Modbus.Client, ^ref, {:ok, words}} -> words
end
```

| Request | Function |
|---|---|
| `{:read_coils, address, count}`, `{:read_discrete_inputs, address, count}` | 1, 2 |
| `{:read_holding_registers, address, count}`, `{:read_input_registers, address, count}` | 3, 4 |
| `{:write_single_coil, address, boolean}`, `{:write_single_register, address, word}` | 5, 6 |
| `{:write_multiple_coils, address, [boolean]}`, `{:write_multiple_registers, address, [word]}` | 15, 16 |
| `{:mask_write_register, address, and_mask, or_mask}` | 22 |
| `{:read_write_multiple_registers, read, count, write, [word]}` | 23 |
| `{:read_fifo_queue, address}` | 24 |
| `{:read_file_record, [{file, record, count}]}`, `{:write_file_record, [{file, record, [word]}]}` | 20, 21 |
| `{:read_device_identification, category, object_id}` | 43/14 |
| `:read_exception_status`, `{:diagnostics, sub_function, [word]}`, `:get_comm_event_counter`, `:get_comm_event_log`, `:report_server_id` | 7, 8, 11, 12, 17 |
| `{:encapsulated_interface_transport, mei_type, binary}` | 43 |
| `{:custom, function_code, binary}` | user-defined, 65 to 72 and 100 to 110 |

The results, and the errors, are listed in the docs of `Modbus`. A request
that doesn't fit the protocol, such as reading 200 registers at once, raises
in the caller and is never sent.

### Many requests at once

Over TCP, up to `max_pending:` requests (4 by default) are on the way at once
on one connection, each under a transaction id of its own, so a slow device or
gateway doesn't hold up the others' answers. More wait their turn in the
client. On a serial line there's one request at a time, as the spec has it.

### Connections

`start_link/1` returns at once and connects in the background; a request made
while it's connecting waits for it. When the connection drops, the client
reconnects by itself, after 100 ms at first and up to 5 seconds between tries.
Meanwhile requests fail at once with `{:error, :closed}`, and `status/1` says
why. Two requests in a row that time out with nothing at all heard from the
device since the first was sent mean the connection is dead, as one a rebooted
device or a broken cable left half open, and the client reconnects; a device
that's only slow keeps its connection.

The client never logs, and never exits the caller: every request gets a result
within its timeout.

## Server

```elixir
{:ok, memory} = Modbus.Memory.start_link(holding_registers: 1000)
{:ok, server} = Modbus.Server.start_link(port: 502, handler: {Modbus.Memory, memory})

Modbus.Memory.put(memory, :holding_register, 0, [215, 1013])
```

A handler is a function of the unit and the request, or a module with the
`Modbus.Server` behaviour, that gives the result a client would get:

```elixir
Modbus.Server.start_link(port: 502, handler: fn
  _unit, {:read_input_registers, 0, 2} -> {:ok, [Sensor.temperature(), Sensor.pressure()]}
  _unit, _request -> {:error, {:exception, :illegal_function}}
end)
```

`Modbus.Memory` keeps the four tables of the data model and files of records,
and answers the functions that read and write them, with the exceptions the
spec gives for addresses that aren't there.

Since a handler gives what a client gets, a gateway is a few lines; a client's
timeout or lost connection becomes the gateway exceptions:

```elixir
{:ok, line} = Modbus.Client.start_link(rtu: "/dev/ttyUSB0", speed: 9600)
Modbus.Server.start_link(port: 502, handler: fn unit, request -> Modbus.Client.request(line, unit, request) end)
```

With `identification:`, a map of object ids to strings, the server answers
Read Device Identification itself, by category and over as many responses as
the objects take.

## Serial lines

```elixir
{:ok, client} = Modbus.Client.start_link(rtu: "/dev/ttyUSB0", speed: 19200, parity: :even)
{:ok, server} = Modbus.Server.start_link(ascii: "/dev/ttyS1", units: [3], handler: handler)
```

RTU and ASCII go through [circuits_uart](https://hex.pm/packages/circuits_uart),
an optional dependency that an application using them adds:

```elixir
{:circuits_uart, "~> 1.5"}
```

Its C code runs as a port, an OS process of its own, so a crash there closes
the port without taking down the BEAM; the client or server opens it again.

Neither the client nor the server times the silence between RTU frames, which
the BEAM's timers and the buffering of USB serial adapters can't do to a
fraction of a millisecond. A frame ends where its function code and byte
counts say, and the CRC confirms it; on a busy line, bytes that start no frame
are passed over until one checks out. Silence ends only frames whose length
nothing tells, such as user-defined functions.

Unit 0 broadcasts a write to every device, and a client waits out the
turnaround delay rather than an answer. A server answers its `units:`, acts on
broadcasts, and keeps the diagnostic counters and event log of the serial line
spec, answering Diagnostics (8), Get Comm Event Counter (11) and Get Comm
Event Log (12) itself, listen only mode included.

Some RS-485 adapters echo what they send. For a write, the echo is the same
bytes as the device's answer, and would pass for it though the device were
dead: `echo: true`, on a client or a server, passes over it.

## Security

Modbus/TCP Security is Modbus TCP inside TLS 1.2 or later, on port 802, with a
certificate on both sides. A client's certificate may carry a role, which the
server passes to `authorize:` with each request; one it refuses gets an
illegal function exception, as the spec has it.

```elixir
Modbus.Server.start_link(handler: handler,
  ssl: [certfile: "server.pem", keyfile: "server.key", cacertfile: "plant-ca.pem"],
  authorize: fn
    "Operator", _unit, _request -> true
    _role, _unit, request -> elem(request, 0) in [:read_holding_registers, :read_input_registers]
  end)

Modbus.Client.start_link(tls: "10.0.0.5",
  ssl: [certfile: "client.pem", keyfile: "client.key", cacertfile: "plant-ca.pem"])
```

| | Client | Server |
|---|---|---|
| TLS | 1.2 or 1.3, never older; no SHA-1 cipher suites | the same |
| Certificates | checks the server's against `cacerts`/`cacertfile`; sends its own | refuses a client without a certificate it trusts |
| Roles | carried in its certificate (OID 1.3.6.1.4.1.50316.802.1) | given to `authorize:`, nil if there's none |

The other `ssl:` options pass through to OTP's `:ssl`.

### Hostile clients and networks

A server on a plant network should expect anything on its port:

| Attack | What stops it |
|---|---|
| Many connections, or stale ones a client left behind | 16 at most; when one more comes, the one longest without a request is closed, as the TCP guide recommends, among those of the address that holds the most, so a host that floods the port pushes out only its own |
| Hosts that have no business on the port | `allow: [{{10, 0, 0, 0}, 8}]` lets in only the addresses listed, as the TCP guide suggests |
| A flood of connections reset as soon as they're made | each is passed over at once, without a pause for the next client to wait out |
| A connection that trickles bytes, or says nothing | closed after `idle:` (a minute) without a whole request; a TLS handshake has 10 seconds |
| Malformed frames | a header that isn't Modbus's closes the connection; a request that breaks its function's rules gets `:illegal_data_value`, and the connection goes on |
| A handler that crashes, hangs, or answers wrong | `:server_device_failure` for that request alone, a hanging one after `handler_timeout:` (10 seconds); a gateway's lost connection or timeout on the far side are the gateway exceptions |
| Requests sent faster than they're answered | each connection reads its next request only when it has answered the last, so TCP holds the rest back |

On a serial line, anyone on the bus can do anything; still, a server won't
take an ASCII delimiter that can come inside a frame, which would leave it
unable to read one again, and `authorize:` decides on the diagnostics it
answers itself as on everything else.

A client can meet a hostile server too. It takes only answers that fit their
request, in unit id, function code, count and the echo of a write, and drops
answers to requests it no longer waits for, so one can't be taken for another's.
A device that doesn't copy the unit id back, as the spec says it must, needs
`check_unit: false`; its answers are then matched by transaction id alone. Only
whole frames count as hearing from a device, so one that trickles bytes doesn't
keep a dead connection open.

## What's missing

- Modbus over UDP and RTU over TCP, which aren't in the specs; nor are data
  types beyond words and bits.
- A server answers a TCP connection's requests one after another, not at once.
- The serial server's character overrun count counts frames too long for the
  spec, as circuits_uart doesn't report overruns; and its diagnostic register
  is always 0.
- No RS-485 direction control beyond what the adapter does by itself.
- Tested against pymodbus and libmodbus, not against real PLCs or the Modbus
  Organization's conformance test.

## Tests

The examples in the application protocol spec are tests, one for each
function. The interop tests run the client against a
[pymodbus](https://github.com/pymodbus-dev/pymodbus) server, and pymodbus's
client against the server, over TCP, TLS, RTU and ASCII, in a separate process
from `test/support/`. They need a Python with pymodbus, and are skipped
without one:

```
python3 -m venv ~/.venvs/pymodbus && ~/.venvs/pymodbus/bin/pip install pymodbus pyserial
PYMODBUS_PYTHON=~/.venvs/pymodbus/bin/python mix test
```

The libmodbus tests do the same against a peer in `test/support/libmodbus_peer.c`, built
when the tests start, over TCP and RTU. They run where pkg-config finds libmodbus
(`brew install libmodbus`, or `apt install libmodbus-dev`), as separate processes: C only ever
runs in tests, never inside yamodbus.

The serial line tests join two pseudo-terminals with [socat](http://www.dest-unreach.org/socat/),
and are skipped where it isn't installed.

`test/modbus/property_test.exs` fuzzes with
[StreamData](https://github.com/whatyouhide/stream_data): every request and
result must encode and decode back to itself, random bytes go into every
decoder and framing, frames split anywhere must come back whole, and a running
server and client get random frames and answers. Nothing may crash. Each
property runs a hundred or more cases with `mix test`; for more:

```
FUZZ_RUNS=10000 mix test test/modbus/property_test.exs
FUZZ_SECONDS=600 mix test test/modbus/property_test.exs
```

CI also runs [Credo](https://github.com/rrrene/credo) and
[Dialyzer](https://github.com/jeremyjh/dialyxir), and on the newest Elixir
`mix test --cover` fails below 82% of the code covered (about 88% is).

## License

Copyright 2026 Tallak Tveide. Licensed under the Apache License, Version 2.0;
see [LICENSE](LICENSE) and [NOTICE](NOTICE).
