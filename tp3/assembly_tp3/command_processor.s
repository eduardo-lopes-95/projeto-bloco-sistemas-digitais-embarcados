// =============================================================================
// Projeto: Dog Bowl Detector - TP3
// Arquivo: command_processor.s
// Descrição: Processador de comandos com estruturas de controle avançadas
//            em Assembly ARM64 (AArch64) para Linux.
// =============================================================================
// Demonstra:
//   1. Loops FOR completos (inicialização, condição, incremento)
//   2. Estruturas IF-ELSEIF-ELSE com múltiplas condições
//   3. Tabelas de salto (jump table) para decisões múltiplas
//   4. Rotinas de parsing para interpretação de comandos
// =============================================================================
// Contexto: O programa lê comandos de stdin e executa ações relacionadas
//           ao detector de pote. Comandos suportados:
//           "status"    - Exibe o estado atual do sensor (código 0)
//           "threshold" - Configura o limiar de detecção (código 1)
//           "blink"     - Pisca o LED N vezes como teste (código 2)
//           "log"       - Exibe histórico de eventos (código 3)
//           "reset"     - Reinicia contadores (código 4)
//           "help"      - Mostra comandos disponíveis (código 5)
// =============================================================================

.global _start

// =============================================================================
// SEÇÃO DE DADOS SOMENTE LEITURA
// =============================================================================
.section .rodata

// Mensagens do sistema
msg_prompt:     .asciz "> "
msg_prompt_len = . - msg_prompt - 1

msg_banner:     .asciz "\n=== Dog Bowl Detector - Processador de Comandos ===\n\n"
msg_banner_len = . - msg_banner - 1

msg_help:       .asciz "Comandos: status | threshold | blink | log | reset | help\n"
msg_help_len = . - msg_help - 1

msg_status_cheio:  .asciz "[STATUS] Pote: CHEIO | Sensor: OK\n"
msg_status_cheio_len = . - msg_status_cheio - 1

msg_status_vazio:  .asciz "[STATUS] Pote: VAZIO | Sensor: ALERTA!\n"
msg_status_vazio_len = . - msg_status_vazio - 1

msg_threshold:  .asciz "[THRESHOLD] Limiar atual: "
msg_threshold_len = . - msg_threshold - 1

msg_blink:      .asciz "[BLINK] LED piscando... iteracao: "
msg_blink_len = . - msg_blink - 1

msg_blink_done: .asciz "[BLINK] Teste de LED concluido.\n"
msg_blink_done_len = . - msg_blink_done - 1

msg_log_header: .asciz "[LOG] Historico de eventos (ultimos 5):\n"
msg_log_header_len = . - msg_log_header - 1

msg_log_entry:  .asciz "  Evento #"
msg_log_entry_len = . - msg_log_entry - 1

msg_log_vazio:  .asciz " -> Pote ficou VAZIO\n"
msg_log_vazio_len = . - msg_log_vazio - 1

msg_log_cheio:  .asciz " -> Pote foi ABASTECIDO\n"
msg_log_cheio_len = . - msg_log_cheio - 1

msg_reset:      .asciz "[RESET] Contadores reiniciados.\n"
msg_reset_len = . - msg_reset - 1

msg_erro_cmd:   .asciz "[ERRO] Comando desconhecido. Digite 'help'.\n"
msg_erro_cmd_len = . - msg_erro_cmd - 1

msg_newline:    .asciz "\n"

// Tabela de strings de comandos (para parsing)
cmd_status:     .asciz "status"
cmd_threshold:  .asciz "threshold"
cmd_blink:      .asciz "blink"
cmd_log:        .asciz "log"
cmd_reset:      .asciz "reset"
cmd_help:       .asciz "help"

// Tabela de ponteiros para os nomes dos comandos (6 comandos)
.balign 8
cmd_table:
    .quad cmd_status
    .quad cmd_threshold
    .quad cmd_blink
    .quad cmd_log
    .quad cmd_reset
    .quad cmd_help
cmd_count = 6

// =========================================================================
// TABELA DE SALTO (Jump Table)
// Endereços das rotinas de tratamento indexados pelo código do comando
// =========================================================================
.balign 8
jump_table:
    .quad handler_status        // índice 0 -> "status"
    .quad handler_threshold     // índice 1 -> "threshold"
    .quad handler_blink         // índice 2 -> "blink"
    .quad handler_log           // índice 3 -> "log"
    .quad handler_reset         // índice 4 -> "reset"
    .quad handler_help          // índice 5 -> "help"

// =============================================================================
// SEÇÃO DE DADOS MUTÁVEIS
// =============================================================================
.section .data
    sensor_state:   .word 0         // 0 = cheio, 1 = vazio
    threshold_val:  .word 20000     // Limiar de detecção (pixels claros)
    event_count:    .word 0         // Total de eventos registrados
    blink_count:    .word 5         // Número padrão de piscadas

// Buffer de histórico de eventos: 5 entries, cada uma é 1 byte (0=cheio, 1=vazio)
    event_log:      .byte 0, 0, 0, 0, 0

// =============================================================================
// SEÇÃO BSS (dados não inicializados)
// =============================================================================
.section .bss
    .balign 8
    input_buffer:   .skip 64        // Buffer para leitura de comandos
    num_buffer:     .skip 16        // Buffer para conversão numérica

// =============================================================================
// SEÇÃO DE CÓDIGO
// =============================================================================
.section .text

_start:
    // Exibe banner de boas-vindas
    mov x0, #1                  // stdout
    ldr x1, =msg_banner
    mov x2, #msg_banner_len
    mov x8, #64                 // sys_write
    svc #0

// =========================================================================
// LOOP PRINCIPAL DO PROCESSADOR DE COMANDOS
// Este é um loop infinito (while true) que:
//   1. Exibe prompt
//   2. Lê comando do stdin
//   3. Faz parsing do comando
//   4. Despacha via jump table
// =========================================================================
main_loop:
    // Exibe prompt "> "
    mov x0, #1
    ldr x1, =msg_prompt
    mov x2, #msg_prompt_len
    mov x8, #64
    svc #0

    // Lê input do usuário (stdin)
    mov x0, #0                  // stdin
    ldr x1, =input_buffer
    mov x2, #63                 // max 63 chars + null
    mov x8, #63                 // sys_read
    svc #0

    // x0 = bytes lidos. Se <= 0, sai (EOF/erro)
    cmp x0, #0
    ble exit_program

    // Remove newline: substitui '\n' por '\0'
    sub x0, x0, #1              // posição do último char
    ldr x1, =input_buffer
    strb wzr, [x1, x0]         // coloca \0 no lugar do \n

    // =================================================================
    // ROTINA DE PARSING: Identifica qual comando foi digitado
    // Percorre a tabela de comandos com um LOOP FOR completo
    // =================================================================
    // Equivalente em C:
    //   for (int i = 0; i < cmd_count; i++) {
    //       if (strcmp(input_buffer, cmd_table[i]) == 0) {
    //           jump_table[i]();  // despacha
    //           break;
    //       }
    //   }
    //   if (i == cmd_count) print("erro");

    ldr x10, =input_buffer      // x10 = ponteiro para input do usuário
    ldr x11, =cmd_table         // x11 = base da tabela de comandos
    mov x12, #0                 // x12 = i (inicialização do FOR)
    mov x13, #cmd_count         // x13 = limite do FOR

// =========================================================================
// [ESTRUTURA 1] LOOP FOR COMPLETO
// Inicialização: x12 = 0
// Condição: x12 < cmd_count (6)
// Incremento: x12 = x12 + 1
// Corpo: compara input com cmd_table[i] usando strcmp inline
// =========================================================================
parse_for_loop:
    cmp x12, x13               // Condição: i < cmd_count?
    b.ge parse_cmd_not_found   // Se i >= cmd_count, comando não encontrado

    // Carrega ponteiro para o nome do comando na posição i
    ldr x14, [x11, x12, lsl #3]   // x14 = cmd_table[i] (cada entry = 8 bytes)

    // Chama strcmp inline: compara x10 (input) com x14 (comando)
    mov x0, x10                // arg1 = input_buffer
    mov x1, x14                // arg2 = cmd_table[i]
    bl strcmp_inline

    // Se resultado == 0, encontrou o comando
    cbz x0, parse_cmd_found

    // Incremento do FOR
    add x12, x12, #1
    b parse_for_loop

// Comando encontrado: despacha via JUMP TABLE
parse_cmd_found:
    ldr x14, =jump_table
    ldr x14, [x14, x12, lsl #3]   // x14 = jump_table[i]
    blr x14                        // Salta para o handler
    b main_loop                    // Volta ao prompt

// Comando não encontrado: exibe erro
parse_cmd_not_found:
    mov x0, #1
    ldr x1, =msg_erro_cmd
    mov x2, #msg_erro_cmd_len
    mov x8, #64
    svc #0
    b main_loop

// =========================================================================
// [ESTRUTURA 2] IF-ELSEIF-ELSE COM MÚLTIPLAS CONDIÇÕES
// Handler do comando "status":
//   - Lê o estado do sensor
//   - IF sensor == 0 AND threshold > 10000 -> "Pote CHEIO, sensor sensível"
//   - ELSEIF sensor == 1 AND threshold > 10000 -> "Pote VAZIO, alerta!"
//   - ELSEIF sensor == 1 AND threshold <= 10000 -> "Pote VAZIO, baixa sens."
//   - ELSE -> "Pote CHEIO, modo padrão"
// =========================================================================
handler_status:
    sub sp, sp, #16
    str x30, [sp, #0]

    // Carrega estado do sensor e limiar
    ldr x2, =sensor_state
    ldr w3, [x2]                    // w3 = sensor_state (0 ou 1)
    ldr x4, =threshold_val
    ldr w5, [x4]                    // w5 = threshold_val

    // --- IF: sensor == 0 AND threshold > 10000 ---
    cmp w3, #0
    b.ne elseif_vazio_alta          // Se sensor != 0, pula para elseif

    // sensor == 0, verifica threshold
    mov w6, #10000
    cmp w5, w6
    b.le else_cheio_padrao          // Se threshold <= 10000, vai para else

    // Condição satisfeita: Pote CHEIO, sensor sensível
    mov x0, #1
    ldr x1, =msg_status_cheio
    mov x2, #msg_status_cheio_len
    mov x8, #64
    svc #0
    b handler_status_fim

    // --- ELSEIF: sensor == 1 AND threshold > 10000 ---
elseif_vazio_alta:
    cmp w3, #1
    b.ne else_cheio_padrao          // Se sensor != 1, vai para else

    mov w6, #10000
    cmp w5, w6
    b.le elseif_vazio_baixa         // Se threshold <= 10000, próximo elseif

    // Condição satisfeita: Pote VAZIO com alta sensibilidade
    mov x0, #1
    ldr x1, =msg_status_vazio
    mov x2, #msg_status_vazio_len
    mov x8, #64
    svc #0
    b handler_status_fim

    // --- ELSEIF: sensor == 1 AND threshold <= 10000 ---
elseif_vazio_baixa:
    // Já sabemos que sensor == 1 e threshold <= 10000
    mov x0, #1
    ldr x1, =msg_status_vazio
    mov x2, #msg_status_vazio_len
    mov x8, #64
    svc #0
    b handler_status_fim

    // --- ELSE: fallback (pote cheio, modo padrão) ---
else_cheio_padrao:
    mov x0, #1
    ldr x1, =msg_status_cheio
    mov x2, #msg_status_cheio_len
    mov x8, #64
    svc #0

handler_status_fim:
    ldr x30, [sp, #0]
    add sp, sp, #16
    ret

// =========================================================================
// Handler "threshold": Exibe o limiar atual
// =========================================================================
handler_threshold:
    sub sp, sp, #16
    str x30, [sp, #0]

    // Imprime prefixo "[THRESHOLD] Limiar atual: "
    mov x0, #1
    ldr x1, =msg_threshold
    mov x2, #msg_threshold_len
    mov x8, #64
    svc #0

    // Converte threshold_val para string decimal e imprime
    ldr x2, =threshold_val
    ldr w0, [x2]
    bl print_number

    // Newline
    mov x0, #1
    ldr x1, =msg_newline
    mov x2, #1
    mov x8, #64
    svc #0

    ldr x30, [sp, #0]
    add sp, sp, #16
    ret

// =========================================================================
// [ESTRUTURA 1 - SEGUNDO EXEMPLO] LOOP FOR COMPLETO
// Handler "blink": Pisca o LED N vezes usando um loop FOR
// Equivalente em C:
//   for (int i = 1; i <= blink_count; i++) {
//       printf("LED piscando... iteracao: %d\n", i);
//       delay();
//   }
// =========================================================================
handler_blink:
    sub sp, sp, #32
    str x30, [sp, #0]
    str x19, [sp, #8]
    str x20, [sp, #16]

    // Carrega número de piscadas
    ldr x2, =blink_count
    ldr w20, [x2]              // w20 = N (limite do for)

    // --- Inicialização do FOR ---
    mov w19, #1                // w19 = i = 1

blink_for_loop:
    // --- Condição do FOR: i <= N? ---
    cmp w19, w20
    b.gt blink_for_end         // Se i > N, sai do loop

    // --- Corpo do FOR ---
    // Imprime "[BLINK] LED piscando... iteracao: "
    mov x0, #1
    ldr x1, =msg_blink
    mov x2, #msg_blink_len
    mov x8, #64
    svc #0

    // Imprime o número da iteração
    mov w0, w19
    bl print_number

    // Newline
    mov x0, #1
    ldr x1, =msg_newline
    mov x2, #1
    mov x8, #64
    svc #0

    // Delay (simula o tempo do LED aceso/apagado)
    bl delay_short

    // --- Incremento do FOR: i++ ---
    add w19, w19, #1
    b blink_for_loop

blink_for_end:
    // Mensagem de conclusão
    mov x0, #1
    ldr x1, =msg_blink_done
    mov x2, #msg_blink_done_len
    mov x8, #64
    svc #0

    ldr x20, [sp, #16]
    ldr x19, [sp, #8]
    ldr x30, [sp, #0]
    add sp, sp, #32
    ret

// =========================================================================
// [ESTRUTURA 1 - TERCEIRO EXEMPLO] LOOP FOR com IF-ELSE interno
// Handler "log": Exibe histórico de eventos com loop FOR
// Equivalente em C:
//   printf("Historico:\n");
//   for (int i = 0; i < 5; i++) {
//       printf("  Evento #%d", i+1);
//       if (event_log[i] == 1)
//           printf(" -> Pote ficou VAZIO\n");
//       else
//           printf(" -> Pote foi ABASTECIDO\n");
//   }
// =========================================================================
handler_log:
    sub sp, sp, #32
    str x30, [sp, #0]
    str x19, [sp, #8]
    str x20, [sp, #16]

    // Imprime cabeçalho
    mov x0, #1
    ldr x1, =msg_log_header
    mov x2, #msg_log_header_len
    mov x8, #64
    svc #0

    // --- Inicialização do FOR ---
    mov w19, #0                // w19 = i = 0
    mov w20, #5                // w20 = limite (5 eventos)
    ldr x21, =event_log        // x21 = base do array de eventos

log_for_loop:
    // --- Condição do FOR: i < 5? ---
    cmp w19, w20
    b.ge log_for_end

    // Imprime "  Evento #"
    mov x0, #1
    ldr x1, =msg_log_entry
    mov x2, #msg_log_entry_len
    mov x8, #64
    svc #0

    // Imprime número do evento (i + 1)
    add w0, w19, #1
    bl print_number

    // --- IF-ELSE dentro do FOR ---
    // Carrega event_log[i]
    ldrb w2, [x21, w19, uxtw]     // w2 = event_log[i]

    cmp w2, #1
    b.ne log_evento_cheio

    // IF: evento == 1 (vazio)
    mov x0, #1
    ldr x1, =msg_log_vazio
    mov x2, #msg_log_vazio_len
    mov x8, #64
    svc #0
    b log_for_inc

    // ELSE: evento == 0 (cheio/abastecido)
log_evento_cheio:
    mov x0, #1
    ldr x1, =msg_log_cheio
    mov x2, #msg_log_cheio_len
    mov x8, #64
    svc #0

log_for_inc:
    // --- Incremento do FOR: i++ ---
    add w19, w19, #1
    b log_for_loop

log_for_end:
    ldr x20, [sp, #16]
    ldr x19, [sp, #8]
    ldr x30, [sp, #0]
    add sp, sp, #32
    ret

// =========================================================================
// Handler "reset": Reinicia contadores e limpa log
// Usa um LOOP FOR para zerar o array de eventos
// =========================================================================
handler_reset:
    sub sp, sp, #16
    str x30, [sp, #0]

    // Zera event_count
    ldr x1, =event_count
    str wzr, [x1]

    // Zera event_log[0..4] com loop FOR
    ldr x1, =event_log
    mov w2, #0                 // i = 0
    mov w3, #5                 // limite

reset_for_loop:
    cmp w2, w3
    b.ge reset_for_end
    strb wzr, [x1, w2, uxtw]  // event_log[i] = 0
    add w2, w2, #1             // i++
    b reset_for_loop

reset_for_end:
    // Mensagem de confirmação
    mov x0, #1
    ldr x1, =msg_reset
    mov x2, #msg_reset_len
    mov x8, #64
    svc #0

    ldr x30, [sp, #0]
    add sp, sp, #16
    ret

// =========================================================================
// Handler "help": Exibe comandos disponíveis
// =========================================================================
handler_help:
    sub sp, sp, #16
    str x30, [sp, #0]

    mov x0, #1
    ldr x1, =msg_help
    mov x2, #msg_help_len
    mov x8, #64
    svc #0

    ldr x30, [sp, #0]
    add sp, sp, #16
    ret

// =========================================================================
// [ESTRUTURA 4] ROTINA DE PARSING: strcmp_inline
// Compara duas strings byte a byte em um loop
// Entrada: x0 = string A, x1 = string B
// Saída:   x0 = 0 se iguais, != 0 se diferentes
// =========================================================================
// Equivalente em C:
//   int strcmp(char *a, char *b) {
//       for (int i = 0; ; i++) {
//           if (a[i] != b[i]) return a[i] - b[i];
//           if (a[i] == '\0') return 0;
//       }
//   }
// =========================================================================
strcmp_inline:
    mov x4, #0                 // índice i = 0

strcmp_loop:
    ldrb w2, [x0, x4]         // w2 = A[i]
    ldrb w3, [x1, x4]         // w3 = B[i]

    cmp w2, w3                 // A[i] == B[i]?
    b.ne strcmp_diff            // Se diferentes, retorna diferença

    cbz w2, strcmp_equal       // Se A[i] == '\0', strings são iguais

    add x4, x4, #1            // i++
    b strcmp_loop

strcmp_equal:
    mov x0, #0                 // Retorna 0 (iguais)
    ret

strcmp_diff:
    sub x0, x2, x3             // Retorna A[i] - B[i] (diferença)
    ret

// =========================================================================
// SUB-ROTINA: print_number
// Converte um inteiro em w0 para string decimal e imprime em stdout
// Usa um LOOP FOR reverso para extrair dígitos (divisão por 10)
// =========================================================================
print_number:
    sub sp, sp, #32
    str x30, [sp, #0]

    ldr x5, =num_buffer
    mov w6, #0                 // contador de dígitos
    add x5, x5, #15           // começa do final do buffer

    // Caso especial: número == 0
    cbz w0, print_num_zero

    // --- LOOP FOR: extrai dígitos (divide por 10 repetidamente) ---
    // for (; num > 0; num /= 10) { buffer[--pos] = '0' + (num % 10); }
print_num_div_loop:
    cbz w0, print_num_output   // Condição: num > 0?

    // Divide w0 por 10: quociente em w1, resto em w2
    mov w1, #10
    udiv w3, w0, w1            // w3 = num / 10
    msub w2, w3, w1, w0        // w2 = num - (num/10)*10 = num % 10

    // Converte dígito para ASCII e armazena
    add w2, w2, #'0'
    sub x5, x5, #1
    strb w2, [x5]

    // Atualiza: num = num / 10, dígitos++
    mov w0, w3
    add w6, w6, #1
    b print_num_div_loop

print_num_zero:
    sub x5, x5, #1
    mov w2, #'0'
    strb w2, [x5]
    mov w6, #1

print_num_output:
    // Imprime os dígitos
    mov x0, #1                 // stdout
    mov x1, x5                 // início da string numérica
    mov x2, x6                 // comprimento
    mov x8, #64                // sys_write
    svc #0

    ldr x30, [sp, #0]
    add sp, sp, #32
    ret

// =========================================================================
// SUB-ROTINA: delay_short
// Delay por busy-wait (simula tempo de LED aceso)
// Usa loop FOR com contagem regressiva
// =========================================================================
delay_short:
    ldr x1, =1000000          // ~1M iterações

delay_short_loop:
    subs x1, x1, #1           // i-- (com atualização de flags)
    b.ne delay_short_loop      // enquanto i != 0
    ret

// =========================================================================
// Saída do programa
// =========================================================================
exit_program:
    mov x0, #0                 // código de saída = 0 (sucesso)
    mov x8, #93                // sys_exit
    svc #0
