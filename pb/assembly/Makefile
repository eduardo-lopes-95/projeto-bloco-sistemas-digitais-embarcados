# TP4: Android -> AArch64 SPI client -> FPGA.
# Native Pi: make; cross-build: make PREFIX=aarch64-linux-gnu
PREFIX ?=
TOOL_PREFIX = $(if $(PREFIX),$(PREFIX)-,)
AS = $(TOOL_PREFIX)as
LD = $(TOOL_PREFIX)ld
OBJDUMP = $(TOOL_PREFIX)objdump
GDB ?= gdb-multiarch
# On a native AArch64 host (e.g. Raspberry Pi) run the ELF directly; on other
# architectures emulate with qemu-aarch64. Override with QEMU= if needed.
HOST_ARCH := $(shell uname -m)
ifeq ($(filter aarch64 arm64,$(HOST_ARCH)),)
QEMU ?= qemu-aarch64
else
QEMU ?=
endif
PYTHON ?= python3
ASFLAGS = -g
LDFLAGS = --static
BUILD_DIR = build
OBJ_DIR = $(BUILD_DIR)/obj
BIN_DIR = $(BUILD_DIR)/bin
DISASM_DIR = disasm
SOURCES = spi_image_client.s
OBJECTS = $(patsubst %.s,$(OBJ_DIR)/%.o,$(SOURCES))
BINARIES = $(patsubst %.s,$(BIN_DIR)/%,$(SOURCES))
BIN ?= spi_image_client
# Example: make run ARGS='frame.bowl commands.bin 100 --emit'
ARGS ?=

.PHONY: all dirs spi_image_client disasm dump symbols headers debug gdbconnect run test test-assembly clean clean-obj info deps
all: $(BINARIES)
spi_image_client: $(BIN_DIR)/spi_image_client

dirs:
	mkdir -p $(OBJ_DIR) $(BIN_DIR) $(DISASM_DIR)

$(OBJ_DIR)/%.o: %.s | dirs
	$(AS) $(ASFLAGS) -o $@ $<

$(BIN_DIR)/%: $(OBJ_DIR)/%.o | dirs
	$(LD) $(LDFLAGS) -o $@ $<

disasm: all
	$(OBJDUMP) -d -S $(BIN_DIR)/spi_image_client > $(DISASM_DIR)/spi_image_client.txt

dump: $(BIN_DIR)/$(BIN)
	$(OBJDUMP) -d -S $<

symbols: $(BIN_DIR)/$(BIN)
	$(OBJDUMP) -t $<

headers: $(BIN_DIR)/$(BIN)
	$(OBJDUMP) -x $<

debug: $(BIN_DIR)/$(BIN)
ifeq ($(strip $(QEMU)),)
	@echo "native AArch64 host: use '$(GDB) $< --args $< $(ARGS)' directly (no qemu gdbstub)"; exit 1
else
	$(QEMU) -g 1234 $< $(ARGS)
endif

gdbconnect: $(BIN_DIR)/$(BIN)
	$(GDB) $< -ex "target remote localhost:1234" -ex "layout asm"

run: $(BIN_DIR)/$(BIN)
	$(QEMU) $< $(ARGS)

test:
	$(PYTHON) -m unittest discover -s tests -p test_pipeline.py -v

test-assembly: all
	$(PYTHON) tests/test_assembly_client.py

clean:
	rm -rf -- build disasm

clean-obj:
	rm -rf -- build/obj

info:
	@echo "Sources: $(SOURCES)"
	$(AS) --version
	$(LD) --version

deps:
	@echo "spi_image_client.s -> $(OBJ_DIR)/spi_image_client.o -> $(BIN_DIR)/spi_image_client"
