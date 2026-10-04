"""A pymodbus peer for yamodbus's interop tests, run in a process of its own.

    python pymodbus_peer.py server tcp PORT
    python pymodbus_peer.py server tls PORT CERTFILE KEYFILE CAFILE
    python pymodbus_peer.py server rtu|ascii DEVICE
    python pymodbus_peer.py client tcp PORT
    python pymodbus_peer.py client tls PORT CERTFILE KEYFILE CAFILE
    python pymodbus_peer.py client rtu|ascii DEVICE

A server holds holding registers 0..99 of 1000 + address, coils of address % 3 == 0, and
device identification, and prints "ready" once it listens. A client makes a fixed series of
requests of unit 1 and prints one line for each result, then exits.
"""

import ssl
import sys

from pymodbus import FramerType, ModbusDeviceIdentification
from pymodbus.datastore import ModbusDeviceContext, ModbusSequentialDataBlock, ModbusServerContext


def server(transport, args):
    import threading
    import time

    from pymodbus.server import StartSerialServer, StartTcpServer, StartTlsServer

    store = ModbusDeviceContext(
        di=ModbusSequentialDataBlock(1, [False] * 100),
        co=ModbusSequentialDataBlock(1, [i % 3 == 0 for i in range(100)]),
        hr=ModbusSequentialDataBlock(1, [1000 + i for i in range(100)]),
        ir=ModbusSequentialDataBlock(1, [2000 + i for i in range(100)]),
    )
    context = ModbusServerContext(devices={1: store}, single=False)
    identity = ModbusDeviceIdentification(
        info_name={"VendorName": "pymodbus", "ProductCode": "PM", "MajorMinorRevision": "3.15"}
    )

    def ready():
        time.sleep(0.5)
        print("ready", flush=True)

    threading.Thread(target=ready, daemon=True).start()

    if transport == "tcp":
        StartTcpServer(context=context, identity=identity, address=("127.0.0.1", int(args[0])))
    elif transport == "tls":
        sslctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        sslctx.load_cert_chain(args[1], args[2])
        sslctx.load_verify_locations(args[3])
        sslctx.verify_mode = ssl.CERT_REQUIRED
        StartTlsServer(
            context=context, identity=identity, address=("127.0.0.1", int(args[0])), sslctx=sslctx
        )
    else:
        framer = FramerType.RTU if transport == "rtu" else FramerType.ASCII
        bits = 8 if transport == "rtu" else 7
        StartSerialServer(
            context=context,
            identity=identity,
            port=args[0],
            framer=framer,
            baudrate=19200,
            bytesize=bits,
            parity="E",
            stopbits=1,
        )


def client(transport, args):
    from pymodbus.client import ModbusSerialClient, ModbusTcpClient, ModbusTlsClient

    if transport == "tcp":
        c = ModbusTcpClient("127.0.0.1", port=int(args[0]), timeout=2)
    elif transport == "tls":
        sslctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        sslctx.load_cert_chain(args[1], args[2])
        sslctx.load_verify_locations(args[3])
        sslctx.check_hostname = False
        c = ModbusTlsClient("127.0.0.1", port=int(args[0]), sslctx=sslctx, timeout=2)
    else:
        framer = FramerType.RTU if transport == "rtu" else FramerType.ASCII
        bits = 8 if transport == "rtu" else 7
        c = ModbusSerialClient(
            args[0], framer=framer, baudrate=19200, bytesize=bits, parity="E", stopbits=1, timeout=2
        )

    c.connect()

    def show(name, response, field):
        if response.isError():
            print(name, "exception", getattr(response, "exception_code", "?"), flush=True)
        else:
            value = getattr(response, field) if field else None
            if isinstance(value, list):
                value = " ".join(str(int(v)) for v in value)
            print(name, "ok", value if value is not None else "", flush=True)

    show("write_registers", c.write_registers(10, [1, 2, 3], device_id=1), None)
    show("read_holding_registers", c.read_holding_registers(10, count=3, device_id=1), "registers")
    show("write_register", c.write_register(20, 0x12, device_id=1), None)
    show("mask_write_register", c.mask_write_register(address=20, and_mask=0xF2, or_mask=0x25, device_id=1), None)
    show("read_holding_registers", c.read_holding_registers(20, count=1, device_id=1), "registers")
    show("write_coils", c.write_coils(5, [True, False, True], device_id=1), None)
    show("read_coils", c.read_coils(5, count=3, device_id=1), "bits")
    show("write_coil", c.write_coil(9, True, device_id=1), None)
    show("read_coils", c.read_coils(9, count=1, device_id=1), "bits")
    show("readwrite_registers", c.readwrite_registers(read_address=30, read_count=2, write_address=30, values=[7, 8], device_id=1), "registers")
    show("read_input_registers", c.read_input_registers(0, count=2, device_id=1), "registers")
    show("read_discrete_inputs", c.read_discrete_inputs(0, count=2, device_id=1), "bits")
    show("read_holding_registers", c.read_holding_registers(999, count=2, device_id=1), "registers")
    c.close()


if __name__ == "__main__":
    role, transport, *rest = sys.argv[1:]
    server(transport, rest) if role == "server" else client(transport, rest)
