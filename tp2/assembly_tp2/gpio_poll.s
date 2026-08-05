// -----------------------------------------------------------------------------
// Projeto: Dog Bowl Detector - Nível 2
// Arquivo: gpio_poll.s (Versão Definitiva via Memória Direta)
// -----------------------------------------------------------------------------

.global _start

.section .rodata
    gpiomem_path: .asciz "/dev/gpiomem"
    status_path:  .asciz "/dev/shm/status_pote"
    
    .balign 4
    char_vazio:   .asciz "1"
    .balign 4
    char_cheio:   .asciz "0"

.section .text
_start:
    // 1. Abrir /dev/gpiomem
    mov x0, #-100
    ldr x1, =gpiomem_path
    mov x2, #2              // O_RDWR
    orr x2, x2, #0x100000   // O_SYNC
    mov x3, #0
    mov x8, #56
    svc #0

    cmp x0, #0
    blt erro_geral
    mov x21, x0             // fd

    // 2. Mapear Memória (mmap)
    mov x0, #0
    mov x1, #4096
    mov x2, #3              // PROT_READ | PROT_WRITE
    mov x3, #1              // MAP_SHARED
    mov x4, x21
    mov x5, #0
    mov x8, #222
    svc #0

    cmp x0, #-1
    beq erro_geral
    mov x20, x0             // Endereço base do GPIO em X20

    // 3. Configurar Pinos (GPIO 21 Saída, GPIO 22 Entrada) no GPFSEL2 (0x08)
    ldr w1, [x20, #0x08]
    
    // Limpa bits do GPIO 21 (5:3) e seta para '001' (Saída)
    mov w2, #7
    lsl w2, w2, #3
    bic w1, w1, w2
    mov w2, #1
    lsl w2, w2, #3
    orr w1, w1, w2

    // Limpa bits do GPIO 22 (8:6) -> '000' (Entrada)
    mov w2, #7
    lsl w2, w2, #6
    bic w1, w1, w2

    str w1, [x20, #0x08]
    
    // Inicia X23 (Cache de Estado) com um valor inválido para forçar a primeira escrita
    mov x23, #0xFF          

main_polling_loop:
    // 4. Ler o GPIO 22 (Pino 15 Físico ligado na Tang Nano)
    ldr w1, [x20, #0x34]    // Lê o registrador GPLEV0
    mov w2, #1
    lsl w2, w2, #22
    and w1, w1, w2          // Isola apenas o bit 22
    lsr w1, w1, #22         // Normaliza para w1 = 0 ou 1

    cbnz w1, pote_vazio     // Se for 1 (Alto/Claro), vai para pote_vazio

pote_cheio:
    // Pote Escuro (Cheio) - Apaga LED e escreve "0"
    mov w2, #1
    lsl w2, w2, #21
    str w2, [x20, #0x28]    // Escreve em GPCLR0 (Apaga LED)

    cmp x23, #0
    beq delay_bloco         // Se já estava apagado, só atrasa

    mov x23, #0             // Atualiza cache
    ldr x0, =char_cheio
    bl atualizar_arquivo_status
    b delay_bloco

pote_vazio:
    // Pote Claro (Vazio) - Acende LED e escreve "1"
    mov w2, #1
    lsl w2, w2, #21
    str w2, [x20, #0x1C]    // Escreve em GPSET0 (Acende LED)

    cmp x23, #1
    beq delay_bloco         // Se já estava aceso, só atrasa

    mov x23, #1             // Atualiza cache
    ldr x0, =char_vazio
    bl atualizar_arquivo_status

delay_bloco:
    ldr x1, =10000000       // Atraso de hardware (Polling limpo)
delay_loop:
    subs x1, x1, #1
    b.ne delay_loop
    
    b main_polling_loop

// =========================================================================
// SUB-ROTINA: atualizar_arquivo_status
// =========================================================================
atualizar_arquivo_status:
    sub sp, sp, #32
    str x30, [sp, #16]
    str x0, [sp, #0]

    mov x0, #-100           
    ldr x1, =status_path    
    mov x2, #0x242          // O_WRONLY | O_CREAT | O_TRUNC
    mov x3, #0666           
    mov x8, #56
    svc #0
    
    mov x22, x0             

    mov x0, x22             
    ldr x1, [sp, #0]        
    mov x2, #1              
    mov x8, #64             
    svc #0

    mov x0, x22             
    mov x8, #57             
    svc #0

    ldr x30, [sp, #16]
    add sp, sp, #32
    ret

// =========================================================================
// Tratamento de Erros Fatais
// =========================================================================
erro_geral:
    mov x0, #1
    mov x8, #93             // sys_exit
    svc #0
