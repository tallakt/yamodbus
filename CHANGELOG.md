# Changelog

## 0.1.0

The first release: the Modbus application protocol with every public function
code, as a client and a server, over TCP, TLS (Modbus/TCP Security, with roles
from client certificates) and serial lines in RTU and ASCII. The TCP client has
many requests on the way at once, and reconnects by itself; the server takes a
handler, or `Modbus.Memory` for the data model. Serial lines need circuits_uart,
an optional dependency. Nothing logs.
