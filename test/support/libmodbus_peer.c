/*
 * A libmodbus peer for yamodbus's interop tests, run in a process of its own.
 *
 *     libmodbus_peer server tcp PORT
 *     libmodbus_peer server rtu DEVICE
 *     libmodbus_peer client tcp PORT
 *     libmodbus_peer client rtu DEVICE
 *
 * A server holds holding registers 0..99 of 1000 + address, input registers of
 * 2000 + address, coils of address % 3 == 0 and discrete inputs of address % 2 == 0,
 * as unit 1, and prints "ready" once it listens. A client makes a fixed series of
 * requests of unit 1 against a server of zeros, and prints one line for each result,
 * then exits.
 */

#include <errno.h>
#include <modbus.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static modbus_t *open_context(const char *transport, const char *where, int server) {
  modbus_t *ctx;

  if (strcmp(transport, "tcp") == 0) {
    ctx = modbus_new_tcp("127.0.0.1", atoi(where));
  } else {
    ctx = modbus_new_rtu(where, 19200, 'E', 8, 1);
  }

  if (ctx == NULL) {
    fprintf(stderr, "context: %s\n", modbus_strerror(errno));
    exit(1);
  }

  modbus_set_slave(ctx, 1);
  modbus_set_response_timeout(ctx, 2, 0);
  (void)server;
  return ctx;
}

static void serve(modbus_t *ctx, modbus_mapping_t *mapping) {
  uint8_t query[MODBUS_MAX_ADU_LENGTH];

  for (;;) {
    int length = modbus_receive(ctx, query);

    if (length > 0) {
      modbus_reply(ctx, query, length, mapping);
    } else if (length == -1) {
      return;
    }
  }
}

static int server(const char *transport, const char *where) {
  modbus_t *ctx = open_context(transport, where, 1);
  modbus_mapping_t *mapping = modbus_mapping_new(100, 100, 100, 100);

  for (int i = 0; i < 100; i++) {
    mapping->tab_registers[i] = 1000 + i;
    mapping->tab_input_registers[i] = 2000 + i;
    mapping->tab_bits[i] = i % 3 == 0;
    mapping->tab_input_bits[i] = i % 2 == 0;
  }

  if (strcmp(transport, "tcp") == 0) {
    int listener = modbus_tcp_listen(ctx, 1);

    if (listener == -1) {
      fprintf(stderr, "listen: %s\n", modbus_strerror(errno));
      return 1;
    }

    printf("ready\n");
    fflush(stdout);

    for (;;) {
      modbus_tcp_accept(ctx, &listener);
      serve(ctx, mapping);
      modbus_close(ctx);
    }
  } else {
    if (modbus_connect(ctx) == -1) {
      fprintf(stderr, "connect: %s\n", modbus_strerror(errno));
      return 1;
    }

    printf("ready\n");
    fflush(stdout);
    serve(ctx, mapping);
  }

  return 0;
}

static void words(const char *name, int count, const uint16_t *values) {
  if (count < 0) {
    printf("%s error %s\n", name, modbus_strerror(errno));
    return;
  }

  printf("%s ok", name);
  for (int i = 0; i < count; i++) printf(" %u", values[i]);
  printf("\n");
}

static void bits(const char *name, int count, const uint8_t *values) {
  if (count < 0) {
    printf("%s error %s\n", name, modbus_strerror(errno));
    return;
  }

  printf("%s ok", name);
  for (int i = 0; i < count; i++) printf(" %u", values[i]);
  printf("\n");
}

static void done(const char *name, int result) {
  if (result < 0) {
    printf("%s error %s\n", name, modbus_strerror(errno));
  } else {
    printf("%s ok\n", name);
  }
}

static int client(const char *transport, const char *where) {
  modbus_t *ctx = open_context(transport, where, 0);
  uint16_t registers[16];
  uint8_t coils[16];
  uint16_t written[3] = {1, 2, 3};
  uint8_t pattern[3] = {1, 0, 1};
  uint16_t pair[2] = {7, 8};

  if (modbus_connect(ctx) == -1) {
    fprintf(stderr, "connect: %s\n", modbus_strerror(errno));
    return 1;
  }

  done("write_registers", modbus_write_registers(ctx, 10, 3, written));
  words("read_registers", modbus_read_registers(ctx, 10, 3, registers), registers);
  done("write_register", modbus_write_register(ctx, 20, 0x12));
  done("mask_write_register", modbus_mask_write_register(ctx, 20, 0xF2, 0x25));
  words("read_registers", modbus_read_registers(ctx, 20, 1, registers), registers);
  done("write_bits", modbus_write_bits(ctx, 5, 3, pattern));
  bits("read_bits", modbus_read_bits(ctx, 5, 3, coils), coils);
  done("write_bit", modbus_write_bit(ctx, 9, 1));
  bits("read_bits", modbus_read_bits(ctx, 9, 1, coils), coils);
  words("write_and_read_registers",
        modbus_write_and_read_registers(ctx, 30, 2, pair, 30, 2, registers), registers);
  words("read_input_registers", modbus_read_input_registers(ctx, 0, 2, registers), registers);
  bits("read_input_bits", modbus_read_input_bits(ctx, 0, 2, coils), coils);
  words("read_registers", modbus_read_registers(ctx, 999, 2, registers), registers);

  modbus_close(ctx);
  modbus_free(ctx);
  return 0;
}

int main(int argc, char **argv) {
  if (argc != 4) {
    fprintf(stderr, "usage: libmodbus_peer server|client tcp|rtu PORT|DEVICE\n");
    return 2;
  }

  setvbuf(stdout, NULL, _IOLBF, 0);
  return strcmp(argv[1], "server") == 0 ? server(argv[2], argv[3]) : client(argv[2], argv[3]);
}
