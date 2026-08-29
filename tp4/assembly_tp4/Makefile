# ==============================================================================
# Projeto: Dog Bowl Detector - TP3
# Arquivo: Makefile
# Descrição: Build automatizado para projetos Assembly ARM64 (AArch64)
#            com compilação incremental, organização de diretórios,
#            e targets para debug (objdump, GDB).
# ==============================================================================
# Uso:
#   make              → Compila todos os binários
#   make gpio_poll    → Compila apenas o gpio_poll
#   make disasm       → Gera disassembly (.txt) de todos os binários
#   make debug        → Inicia GDB no binário selecionado
#   make run          → Executa via QEMU user-mode (para teste em x86)
#   make clean        → Remove artefatos de compilação
#   make info         → Exibe informações do toolchain
# ==============================================================================

# ------------------------------------------------------------------------------
# TOOLCHAIN: Compilação ARM64
# ------------------------------------------------------------------------------
# Para CROSS-COMPILAÇÃO (em x86/WSL): make all PREFIX=aarch64-linux-gnu
# Para compilação NATIVA (no Raspberry Pi): make all (PREFIX vazio por padrão)
# ------------------------------------------------------------------------------
PREFIX  ?=
ifdef PREFIX
  TOOL_PREFIX = $(PREFIX)-
else
  TOOL_PREFIX =
endif

AS      = $(TOOL_PREFIX)as
LD      = $(TOOL_PREFIX)ld
OBJDUMP = $(TOOL_PREFIX)objdump
GDB     = gdb-multiarch
QEMU    = qemu-aarch64

# ------------------------------------------------------------------------------
# FLAGS DE COMPILAÇÃO
# ------------------------------------------------------------------------------
ASFLAGS  = -g                    # Inclui símbolos de debug (para GDB)
LDFLAGS  = --static              # Linkagem estática (sem dependência de .so)
QEMUFLAGS = -L /usr/aarch64-linux-gnu   # Sysroot para bibliotecas ARM64

# ------------------------------------------------------------------------------
# ORGANIZAÇÃO DE DIRETÓRIOS
# Estrutura gerada pelo Makefile:
#   assembly_tp3/
#   ├── src/          ← Código fonte (*.s) - movido manualmente se desejado
#   ├── build/
#   │   ├── obj/      ← Objetos intermediários (*.o)
#   │   └── bin/      ← Binários finais (executáveis)
#   └── disasm/       ← Saída do objdump (*.txt)
# ------------------------------------------------------------------------------
BUILD_DIR  = build
OBJ_DIR    = $(BUILD_DIR)/obj
BIN_DIR    = $(BUILD_DIR)/bin
DISASM_DIR = disasm

# ------------------------------------------------------------------------------
# FONTES E ALVOS
# Cada arquivo .s gera um binário independente (programa standalone)
# ------------------------------------------------------------------------------
SOURCES = gpio_poll.s gpio_map.s command_processor.s

# Gera lista de objetos e binários a partir das fontes
OBJECTS  = $(patsubst %.s, $(OBJ_DIR)/%.o, $(SOURCES))
BINARIES = $(patsubst %.s, $(BIN_DIR)/%, $(SOURCES))

# ==============================================================================
# TARGETS PRINCIPAIS
# ==============================================================================

# Target padrão: compila todos os binários
.PHONY: all
all: dirs $(BINARIES)
	@echo ""
	@echo "============================================"
	@echo " BUILD CONCLUIDO - Binarios em $(BIN_DIR)/"
	@echo "============================================"
	@ls -la $(BIN_DIR)/

# Cria diretórios necessários (se não existirem)
.PHONY: dirs
dirs:
	@mkdir -p $(OBJ_DIR) $(BIN_DIR) $(DISASM_DIR)

# ==============================================================================
# REGRAS DE COMPILAÇÃO INCREMENTAL
# ==============================================================================
# O make só recompila um .o se o .s correspondente foi modificado.
# Isso é compilação incremental: altera 1 arquivo, recompila apenas ele.

# Regra padrão: .s → .o (montagem)
$(OBJ_DIR)/%.o: %.s | dirs
	@echo "[AS]  $< → $@"
	$(AS) $(ASFLAGS) -o $@ $<

# Regra padrão: .o → binário (linkagem)
$(BIN_DIR)/%: $(OBJ_DIR)/%.o | dirs
	@echo "[LD]  $< → $@"
	$(LD) $(LDFLAGS) -o $@ $<

# ==============================================================================
# TARGETS DE ANÁLISE (OBJDUMP)
# ==============================================================================

# Gera disassembly de todos os binários
.PHONY: disasm
disasm: all
	@mkdir -p $(DISASM_DIR)
	@echo ""
	@echo "=== Gerando disassembly ==="
	@for bin in $(BINARIES); do \
		name=$$(basename $$bin); \
		echo "[OBJDUMP] $$bin → $(DISASM_DIR)/$$name.txt"; \
		$(OBJDUMP) -d -S $$bin > $(DISASM_DIR)/$$name.txt; \
	done
	@echo ""
	@echo "Disassembly salvo em $(DISASM_DIR)/"
	@ls -la $(DISASM_DIR)/

# Exibe o disassembly de um binário no terminal
# Uso: make dump BIN=gpio_poll
.PHONY: dump
dump: $(BIN_DIR)/$(BIN)
	$(OBJDUMP) -d -S $(BIN_DIR)/$(BIN)

# Exibe os símbolos de um binário
# Uso: make symbols BIN=gpio_poll
.PHONY: symbols
symbols: $(BIN_DIR)/$(BIN)
	$(OBJDUMP) -t $(BIN_DIR)/$(BIN)

# Exibe os headers ELF de um binário
# Uso: make headers BIN=gpio_poll
.PHONY: headers
headers: $(BIN_DIR)/$(BIN)
	$(OBJDUMP) -x $(BIN_DIR)/$(BIN)

# ==============================================================================
# TARGETS DE DEBUG (GDB)
# ==============================================================================

# Inicia GDB com o binário selecionado via QEMU gdbserver
# Uso: make debug BIN=command_processor
# Em outro terminal: make gdbconnect BIN=command_processor
.PHONY: debug
debug: $(BIN_DIR)/$(BIN)
	@echo "=== Iniciando QEMU com GDB server na porta 1234 ==="
	@echo "Em outro terminal, execute: make gdbconnect BIN=$(BIN)"
	$(QEMU) $(QEMUFLAGS) -g 1234 $(BIN_DIR)/$(BIN)

# Conecta GDB ao servidor remoto do QEMU
.PHONY: gdbconnect
gdbconnect: $(BIN_DIR)/$(BIN)
	$(GDB) $(BIN_DIR)/$(BIN) -ex "target remote localhost:1234" -ex "layout asm"

# ==============================================================================
# TARGETS DE EXECUÇÃO (QEMU USER-MODE)
# ==============================================================================

# Executa um binário via QEMU
# Uso: make run BIN=command_processor
.PHONY: run
run: $(BIN_DIR)/$(BIN)
	@echo "=== Executando $(BIN) via QEMU ==="
	$(QEMU) $(QEMUFLAGS) $(BIN_DIR)/$(BIN)

# ==============================================================================
# TARGETS DE LIMPEZA
# ==============================================================================

# Remove todos os artefatos de compilação
.PHONY: clean
clean:
	@echo "=== Limpando artefatos ==="
	rm -rf $(BUILD_DIR) $(DISASM_DIR)
	@echo "Limpo."

# Remove apenas os objetos (mantém binários)
.PHONY: clean-obj
clean-obj:
	@echo "=== Limpando objetos ==="
	rm -rf $(OBJ_DIR)

# ==============================================================================
# TARGETS DE INFORMAÇÃO
# ==============================================================================

# Exibe versão do toolchain e configuração
.PHONY: info
info:
	@echo "=== Toolchain ARM64 ==="
	@echo "Assembler:  $(AS)"
	@echo "Linker:     $(LD)"
	@echo "Objdump:    $(OBJDUMP)"
	@echo "GDB:        $(GDB)"
	@echo "QEMU:       $(QEMU)"
	@echo ""
	@echo "=== Configuração ==="
	@echo "ASFLAGS:    $(ASFLAGS)"
	@echo "LDFLAGS:    $(LDFLAGS)"
	@echo ""
	@echo "=== Fontes ==="
	@echo "$(SOURCES)"
	@echo ""
	@$(AS) --version | head -1
	@$(LD) --version | head -1

# Exibe as dependências (qual .o depende de qual .s)
.PHONY: deps
deps:
	@echo "=== Dependências (compilação incremental) ==="
	@for src in $(SOURCES); do \
		obj=$$(echo $$src | sed 's/.s$$/.o/'); \
		bin=$$(echo $$src | sed 's/.s$$//'); \
		echo "  $$src → $(OBJ_DIR)/$$obj → $(BIN_DIR)/$$bin"; \
	done

# ==============================================================================
# TARGETS INDIVIDUAIS (atalhos)
# ==============================================================================
.PHONY: gpio_poll gpio_map command_processor

gpio_poll: $(BIN_DIR)/gpio_poll
gpio_map: $(BIN_DIR)/gpio_map
command_processor: $(BIN_DIR)/command_processor
