// =============================================================================
// Projeto: Dog Bowl Detector - TP3
// Arquivo: gpio_map.s
// Descrição: Mapeamento de pinos e registradores GPIO do Raspberry Pi Zero 2W
//            (BCM2711) com exemplos de acesso via Assembly ARM64.
// =============================================================================
//
// O Raspberry Pi Zero 2W usa o SoC BCM2710A1 (similar ao BCM2837 do Pi 3),
// com periféricos mapeados a partir do endereço base 0xFE000000 (via /dev/mem)
// ou acessíveis a partir do offset 0x00 via /dev/gpiomem (apenas GPIO).
//
// =============================================================================
// MAPA DE REGISTRADORES GPIO (BCM2835/BCM2837 - compatível RPi Zero 2W)
// =============================================================================
//
// Endereço base GPIO (via /dev/gpiomem): 0x00000000 (offset relativo)
// Endereço base GPIO (via /dev/mem):     0xFE200000 (absoluto)
//
// +--------+----------+---------------------------------------------------+
// | Offset | Nome     | Descrição                                         |
// +--------+----------+---------------------------------------------------+
// | 0x00   | GPFSEL0  | Function Select para GPIO 0-9   (3 bits/pino)     |
// | 0x04   | GPFSEL1  | Function Select para GPIO 10-19 (3 bits/pino)     |
// | 0x08   | GPFSEL2  | Function Select para GPIO 20-29 (3 bits/pino)     |
// | 0x0C   | GPFSEL3  | Function Select para GPIO 30-39 (3 bits/pino)     |
// | 0x10   | GPFSEL4  | Function Select para GPIO 40-49 (3 bits/pino)     |
// | 0x14   | GPFSEL5  | Function Select para GPIO 50-53 (3 bits/pino)     |
// +--------+----------+---------------------------------------------------+
// | 0x1C   | GPSET0   | Seta pinos GPIO 0-31 (escrita 1 = HIGH)           |
// | 0x20   | GPSET1   | Seta pinos GPIO 32-53                             |
// +--------+----------+---------------------------------------------------+
// | 0x28   | GPCLR0   | Limpa pinos GPIO 0-31 (escrita 1 = LOW)           |
// | 0x2C   | GPCLR1   | Limpa pinos GPIO 32-53                            |
// +--------+----------+---------------------------------------------------+
// | 0x34   | GPLEV0   | Lê nível atual dos pinos GPIO 0-31 (1=HIGH,0=LOW) |
// | 0x38   | GPLEV1   | Lê nível atual dos pinos GPIO 32-53               |
// +--------+----------+---------------------------------------------------+
// | 0x40   | GPEDS0   | Event Detect Status GPIO 0-31                     |
// | 0x4C   | GPREN0   | Rising Edge Detect Enable GPIO 0-31               |
// | 0x58   | GPFEN0   | Falling Edge Detect Enable GPIO 0-31              |
// | 0x64   | GPHEN0   | High Detect Enable GPIO 0-31                      |
// | 0x70   | GPLEN0   | Low Detect Enable GPIO 0-31                       |
// +--------+----------+---------------------------------------------------+
// | 0xE4   | GPPUD    | Pull-Up/Down Enable (BCM2835 legacy)              |
// | 0xE8   | GPPUDCLK0| Pull-Up/Down Clock para GPIO 0-31                |
// +--------+----------+---------------------------------------------------+
//
// =============================================================================
// MAPA DE PINOS UTILIZADOS NO PROJETO (Dog Bowl Detector)
// =============================================================================
//
// +------+--------+-------+--------+----------------------------------------+
// | GPIO | Físico | Dir.  | GPFSEL | Função no projeto                      |
// +------+--------+-------+--------+----------------------------------------+
// | 21   | Pin 40 | OUT   | FSEL2  | LED indicador local (pote vazio)       |
// | 22   | Pin 15 | IN    | FSEL2  | Sinal da FPGA (alerta_vazio)           |
// +------+--------+-------+--------+----------------------------------------+
//
// GPFSEL2 (offset 0x08) controla GPIO 20-29:
//   Cada pino usa 3 bits. Posição do pino no registrador:
//     GPIO 20: bits [2:0]
//     GPIO 21: bits [5:3]    ← LED (Saída = 001)
//     GPIO 22: bits [8:6]    ← Sinal FPGA (Entrada = 000)
//     GPIO 23: bits [11:9]
//     ...
//     GPIO 29: bits [29:27]
//
// Valores de FSEL (Function Select):
//   000 = Entrada (Input)
//   001 = Saída (Output)
//   100 = ALT0 (ex: I2C, SPI)
//   101 = ALT1
//   110 = ALT2
//   111 = ALT3
//   011 = ALT4
//   010 = ALT5
//
// =============================================================================

.global _start

// =============================================================================
// CONSTANTES DE ENDEREÇO
// =============================================================================
.equ GPFSEL0,   0x00    // Function Select GPIO 0-9
.equ GPFSEL1,   0x04    // Function Select GPIO 10-19
.equ GPFSEL2,   0x08    // Function Select GPIO 20-29
.equ GPSET0,    0x1C    // Set (ligar) GPIO 0-31
.equ GPCLR0,    0x28    // Clear (desligar) GPIO 0-31
.equ GPLEV0,    0x34    // Level (ler nível) GPIO 0-31

.equ GPIO_LED,      21  // Pino do LED (saída)
.equ GPIO_SENSOR,   22  // Pino do sensor/FPGA (entrada)

.equ MAP_SIZE,   4096   // Tamanho do mapeamento (1 página)
.equ O_RDWR,     2      // Flags de abertura: leitura e escrita
.equ O_SYNC,     0x100000
.equ PROT_RW,    3      // PROT_READ | PROT_WRITE
.equ MAP_SHARED, 1

// Syscalls Linux AArch64
.equ SYS_OPENAT, 56
.equ SYS_CLOSE,  57
.equ SYS_WRITE,  64
.equ SYS_MMAP,   222
.equ SYS_EXIT,   93
.equ AT_FDCWD,   -100

// =============================================================================
// SEÇÃO DE DADOS SOMENTE LEITURA
// =============================================================================
.section .rodata
    gpiomem_path: .asciz "/dev/gpiomem"

    msg_init:     .asciz "[GPIO] Mapeamento inicializado com sucesso.\n"
    msg_init_len = . - msg_init - 1

    msg_cfg:      .asciz "[GPIO] Pinos configurados: GPIO21=OUT, GPIO22=IN\n"
    msg_cfg_len = . - msg_cfg - 1

    msg_led_on:   .asciz "[GPIO] LED GPIO21 -> LIGADO (GPSET0 bit 21)\n"
    msg_led_on_len = . - msg_led_on - 1

    msg_led_off:  .asciz "[GPIO] LED GPIO21 -> DESLIGADO (GPCLR0 bit 21)\n"
    msg_led_off_len = . - msg_led_off - 1

    msg_read_h:   .asciz "[GPIO] Leitura GPIO22 (GPLEV0 bit 22): ALTO (1)\n"
    msg_read_h_len = . - msg_read_h - 1

    msg_read_l:   .asciz "[GPIO] Leitura GPIO22 (GPLEV0 bit 22): BAIXO (0)\n"
    msg_read_l_len = . - msg_read_l - 1

    msg_erro:     .asciz "[ERRO] Falha ao mapear GPIO.\n"
    msg_erro_len = . - msg_erro - 1

    msg_fim:      .asciz "[GPIO] Demonstracao concluida.\n"
    msg_fim_len = . - msg_fim - 1

// =============================================================================
// SEÇÃO DE CÓDIGO
// =============================================================================
.section .text

_start:
    // =========================================================================
    // ETAPA 1: Abrir /dev/gpiomem
    // =========================================================================
    // /dev/gpiomem dá acesso APENAS aos registradores GPIO sem precisar de
    // permissão root completa (não expõe toda a memória do sistema).
    // O endereço base retornado pelo mmap é o offset 0x00 = início do GPIO.

    mov x0, #AT_FDCWD           // dirfd = AT_FDCWD (caminho relativo ao cwd)
    ldr x1, =gpiomem_path      // pathname = "/dev/gpiomem"
    mov x2, #O_RDWR            // flags = O_RDWR (leitura + escrita)
    orr x2, x2, #O_SYNC        // flags |= O_SYNC (acesso sincronizado)
    mov x3, #0                  // mode = 0 (não cria arquivo)
    mov x8, #SYS_OPENAT        // syscall openat
    svc #0

    // Verifica erro (fd < 0 = falha)
    cmp x0, #0
    blt erro_fatal
    mov x19, x0                 // x19 = fd (salva file descriptor)

    // =========================================================================
    // ETAPA 2: Mapear memória GPIO via mmap
    // =========================================================================
    // mmap(addr=NULL, length=4096, prot=RW, flags=SHARED, fd, offset=0)
    // Retorna ponteiro para a região mapeada dos registradores GPIO.

    mov x0, #0                  // addr = NULL (kernel escolhe)
    mov x1, #MAP_SIZE           // length = 4096 bytes (1 página)
    mov x2, #PROT_RW            // prot = PROT_READ | PROT_WRITE
    mov x3, #MAP_SHARED         // flags = MAP_SHARED
    mov x4, x19                 // fd = file descriptor do gpiomem
    mov x5, #0                  // offset = 0 (início do GPIO)
    mov x8, #SYS_MMAP          // syscall mmap
    svc #0

    // Verifica erro (retorno == -1 = falha)
    cmn x0, #1                  // compara com -1
    beq erro_fatal
    mov x20, x0                 // x20 = BASE GPIO (ponteiro para registradores)

    // Fecha o fd (não precisamos mais dele após o mmap)
    mov x0, x19
    mov x8, #SYS_CLOSE
    svc #0

    // Imprime mensagem de sucesso
    mov x0, #1
    ldr x1, =msg_init
    mov x2, #msg_init_len
    mov x8, #SYS_WRITE
    svc #0

    // =========================================================================
    // ETAPA 3: Configurar pinos via GPFSEL2 (offset 0x08)
    // =========================================================================
    // GPFSEL2 controla GPIO 20-29. Cada pino usa 3 bits consecutivos.
    //
    // Operação: Read-Modify-Write
    //   1. LDR o valor atual de GPFSEL2
    //   2. Limpa os bits do pino alvo com BIC (bit clear)
    //   3. Seta o novo valor com ORR
    //   4. STR de volta no registrador
    //
    // GPIO 21 (bits [5:3]): setar para 001 (Saída)
    // GPIO 22 (bits [8:6]): setar para 000 (Entrada)

    // --- Lê o valor atual de GPFSEL2 ---
    ldr w1, [x20, #GPFSEL2]    // w1 = valor atual de GPFSEL2

    // --- Configura GPIO 21 como SAÍDA (001 nos bits [5:3]) ---
    // Passo 1: Limpa bits [5:3] → AND NOT com máscara 0b111 << 3
    mov w2, #7                  // w2 = 0b111 (máscara de 3 bits)
    lsl w2, w2, #3              // w2 = 0b111000 (deslocada para posição do GPIO 21)
    bic w1, w1, w2              // w1 = w1 AND NOT w2 (limpa bits [5:3])

    // Passo 2: Seta bits [5:3] = 001 (modo saída)
    mov w2, #1                  // w2 = 0b001
    lsl w2, w2, #3              // w2 = 0b001000 (deslocada para posição do GPIO 21)
    orr w1, w1, w2              // w1 = w1 OR w2 (seta bit 3)

    // --- Configura GPIO 22 como ENTRADA (000 nos bits [8:6]) ---
    // Passo 1: Limpa bits [8:6] → AND NOT com máscara 0b111 << 6
    mov w2, #7                  // w2 = 0b111
    lsl w2, w2, #6              // w2 = 0b111000000 (posição do GPIO 22)
    bic w1, w1, w2              // w1 = w1 AND NOT w2 (limpa bits [8:6])
    // Nota: não precisa de ORR porque 000 = Entrada (já zerado pelo BIC)

    // --- Escreve de volta no registrador ---
    str w1, [x20, #GPFSEL2]    // Grava a configuração no hardware

    // Imprime confirmação
    mov x0, #1
    ldr x1, =msg_cfg
    mov x2, #msg_cfg_len
    mov x8, #SYS_WRITE
    svc #0

    // =========================================================================
    // ETAPA 4A: Escrita em GPIO — Ligar LED (GPSET0)
    // =========================================================================
    // GPSET0 (offset 0x1C): Escrever 1 no bit N seta o pino N para HIGH.
    // Bits escritos como 0 são IGNORADOS (não afetam outros pinos).
    // Isso é uma operação atômica — não precisa de read-modify-write.

    mov w2, #1                  // w2 = 1
    lsl w2, w2, #GPIO_LED       // w2 = (1 << 21) = bit 21 ligado
    str w2, [x20, #GPSET0]     // Escreve em GPSET0: GPIO 21 vai para HIGH

    // Imprime ação
    mov x0, #1
    ldr x1, =msg_led_on
    mov x2, #msg_led_on_len
    mov x8, #SYS_WRITE
    svc #0

    // Delay para visualizar o LED (loop de busy-wait)
    ldr x3, =5000000
delay_on:
    subs x3, x3, #1
    b.ne delay_on

    // =========================================================================
    // ETAPA 4B: Escrita em GPIO — Desligar LED (GPCLR0)
    // =========================================================================
    // GPCLR0 (offset 0x28): Escrever 1 no bit N seta o pino N para LOW.
    // Mesma lógica do GPSET0: bits 0 são ignorados, operação atômica.

    mov w2, #1                  // w2 = 1
    lsl w2, w2, #GPIO_LED       // w2 = (1 << 21)
    str w2, [x20, #GPCLR0]     // Escreve em GPCLR0: GPIO 21 vai para LOW

    // Imprime ação
    mov x0, #1
    ldr x1, =msg_led_off
    mov x2, #msg_led_off_len
    mov x8, #SYS_WRITE
    svc #0

    // =========================================================================
    // ETAPA 4C: Leitura de GPIO — Ler sensor (GPLEV0)
    // =========================================================================
    // GPLEV0 (offset 0x34): Cada bit representa o nível ATUAL do pino.
    //   Bit N = 1 → pino N está em HIGH
    //   Bit N = 0 → pino N está em LOW
    //
    // Para isolar um bit específico:
    //   1. LDR o registrador inteiro (32 bits, todos os pinos)
    //   2. AND com máscara (1 << N) para isolar o bit
    //   3. LSR para normalizar o resultado (0 ou 1)

    ldr w1, [x20, #GPLEV0]     // w1 = valor de GPLEV0 (nível de todos os pinos)

    // Isola o bit 22 (GPIO_SENSOR)
    mov w2, #1                  // w2 = 1
    lsl w2, w2, #GPIO_SENSOR    // w2 = (1 << 22) = máscara do bit 22
    and w1, w1, w2              // w1 = w1 AND máscara (isola bit 22)
    lsr w1, w1, #GPIO_SENSOR    // w1 = resultado normalizado (0 ou 1)

    // Decide qual mensagem imprimir baseado no valor lido
    cbnz w1, leitura_alta       // Se w1 != 0 (HIGH), pula

    // GPIO 22 está LOW
    mov x0, #1
    ldr x1, =msg_read_l
    mov x2, #msg_read_l_len
    mov x8, #SYS_WRITE
    svc #0
    b fim_demonstracao

leitura_alta:
    // GPIO 22 está HIGH
    mov x0, #1
    ldr x1, =msg_read_h
    mov x2, #msg_read_h_len
    mov x8, #SYS_WRITE
    svc #0

    // =========================================================================
    // FIM DA DEMONSTRAÇÃO
    // =========================================================================
fim_demonstracao:
    mov x0, #1
    ldr x1, =msg_fim
    mov x2, #msg_fim_len
    mov x8, #SYS_WRITE
    svc #0

    // Sai com código 0
    mov x0, #0
    mov x8, #SYS_EXIT
    svc #0

    // =========================================================================
    // TRATAMENTO DE ERRO
    // =========================================================================
erro_fatal:
    mov x0, #1
    ldr x1, =msg_erro
    mov x2, #msg_erro_len
    mov x8, #SYS_WRITE
    svc #0

    mov x0, #1                  // Código de saída = 1 (erro)
    mov x8, #SYS_EXIT
    svc #0
