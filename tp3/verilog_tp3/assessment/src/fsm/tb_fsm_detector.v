// -----------------------------------------------------------------------------
// Testbench: tb_fsm_detector
// Projeto: Dog Bowl Detector - FSM Hierárquica
// Descrição: Testbench completo que exercita todas as transições da FSM
//            usando o módulo detector_top (hierárquico).
// -----------------------------------------------------------------------------
// Casos de teste:
//   1. Reset inicial → FSM em IDLE, alerta inativo
//   2. Frame claro (pote vazio) → ALERTA ativado
//   3. Frame escuro (pote cheio) → NORMAL, alerta desligado
//   4. Transição VAZIO → CHEIO (recuperação do sistema)
//   5. Frames consecutivos vazios (alerta persiste)
//   6. Frame misto (abaixo do limiar) → NORMAL
//   7. Reset abrupto no meio do frame e recuperação
// -----------------------------------------------------------------------------
// Diagrama de estados:
//
//   [IDLE] --vsync_rising--> [CONTANDO] --vsync_rising--> [AVALIANDO]
//                                 ^                            |
//                                 |               count>limiar? |
//                                 |              /              \
//                        vsync_falling      [ALERTA]       [NORMAL]
//                                 |              \              /
//                                 +---------vsync_falling------+
//
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_fsm_detector;

    // =========================================================================
    // Sinais do DUT
    // =========================================================================
    reg         clk;
    reg         rst_n;
    reg         vsync;
    reg         de;
    reg  [7:0]  pixel_green;
    wire        alerta_vazio;

    // Parâmetros de teste (limiar reduzido para simulação rápida)
    localparam PIXEL_THRESHOLD      = 32'd10;
    localparam THRESHOLD_BRIGHTNESS = 8'd100;

    // =========================================================================
    // Instância do DUT (Device Under Test) - Módulo Hierárquico Top
    // =========================================================================
    detector_top #(
        .THRESHOLD_BRIGHTNESS (THRESHOLD_BRIGHTNESS),
        .PIXEL_THRESHOLD      (PIXEL_THRESHOLD),
        .COUNTER_WIDTH        (32)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .vsync        (vsync),
        .de           (de),
        .pixel_green  (pixel_green),
        .alerta_vazio (alerta_vazio)
    );

    // =========================================================================
    // Geração de Clock: 50MHz (período = 20ns)
    // =========================================================================
    always #10 clk = ~clk;

    // =========================================================================
    // Tasks auxiliares para simular o protocolo de vídeo
    // =========================================================================

    // Envia N pixels com brilho definido (região ativa do frame)
    // Nota: #1 após posedge evita race condition na simulação
    task enviar_pixels;
        input [7:0]  brilho;
        input [31:0] quantidade;
        integer i;
        begin
            for (i = 0; i < quantidade; i = i + 1) begin
                @(posedge clk); #1;
                de = 1'b1;
                pixel_green = brilho;
            end
            @(posedge clk); #1;
            de = 1'b0;
            pixel_green = 8'd0;
        end
    endtask

    // Fim do frame: VSYNC sobe → FSM avalia (CONTANDO→AVALIANDO→ALERTA/NORMAL)
    // Mantém VSYNC alto para que o testbench possa verificar o resultado
    task fim_frame;
        begin
            @(posedge clk); #1;
            vsync = 1'b1;
            // Aguarda pipeline: +1 (vsync_prev), +1 (AVALIANDO), +1 (ALERTA/NORMAL)
            repeat (4) @(posedge clk);
        end
    endtask

    // Início do próximo frame: VSYNC desce → FSM volta para CONTANDO
    task inicio_frame;
        begin
            @(posedge clk); #1;
            vsync = 1'b0;
            repeat (3) @(posedge clk);
        end
    endtask

    // Ciclo completo de sincronização (sai de IDLE)
    task sync_sair_idle;
        begin
            @(posedge clk); #1; vsync = 1'b1;
            repeat (3) @(posedge clk);
            @(posedge clk); #1; vsync = 1'b0;
            repeat (3) @(posedge clk);
        end
    endtask

    // =========================================================================
    // Contadores de resultado
    // =========================================================================
    integer pass_count;
    integer fail_count;

    // =========================================================================
    // Sequência de Testes
    // =========================================================================
    initial begin
        $dumpfile("onda_fsm_detector.vcd");
        $dumpvars(0, tb_fsm_detector);

        // Inicialização
        clk         = 0;
        rst_n       = 0;
        vsync       = 0;
        de          = 0;
        pixel_green = 8'd0;
        pass_count  = 0;
        fail_count  = 0;

        $display("============================================================");
        $display(" TESTBENCH: Dog Bowl Detector - FSM Hierarquica");
        $display("============================================================");
        $display(" Configuracao:");
        $display("   Limiar de pixels claros: %0d", PIXEL_THRESHOLD);
        $display("   Limiar de brilho (verde): %0d", THRESHOLD_BRIGHTNESS);
        $display("============================================================");

        // =================================================================
        // TESTE 1: Reset inicial → IDLE, alerta inativo
        // =================================================================
        $display("\n[TESTE 1] Reset inicial - FSM em IDLE, alerta inativo");
        repeat (5) @(posedge clk);
        #1; rst_n = 1'b1;
        repeat (3) @(posedge clk);

        if (alerta_vazio == 1'b0) begin
            $display("  [PASS] Alerta inativo apos reset (FSM em IDLE)");
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Alerta deveria estar inativo apos reset");
            fail_count = fail_count + 1;
        end

        // Sincroniza: IDLE → CONTANDO
        sync_sair_idle();

        // =================================================================
        // TESTE 2: Frame CLARO (pote vazio) → Estado ALERTA
        // Transição: CONTANDO → AVALIANDO → ALERTA
        // =================================================================
        $display("\n[TESTE 2] Frame CLARO (20 pixels, brilho=150) -> ALERTA");
        $display("          Transicao esperada: CONTANDO -> AVALIANDO -> ALERTA");

        enviar_pixels(8'd150, 32'd20);  // 20 pixels claros > limiar de 10
        repeat (2) @(posedge clk);
        fim_frame();  // VSYNC sobe → avaliação

        if (alerta_vazio == 1'b1) begin
            $display("  [PASS] Alerta ATIVADO - pote vazio detectado (20 > 10)");
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Alerta deveria estar ativo (pixels claros = 20 > limiar 10)");
            fail_count = fail_count + 1;
        end

        inicio_frame();  // VSYNC desce → CONTANDO

        // =================================================================
        // TESTE 3: Frame ESCURO (pote cheio) → Estado NORMAL
        // Transição: CONTANDO → AVALIANDO → NORMAL
        // =================================================================
        $display("\n[TESTE 3] Frame ESCURO (20 pixels, brilho=50) -> NORMAL");
        $display("          Transicao esperada: CONTANDO -> AVALIANDO -> NORMAL");

        enviar_pixels(8'd50, 32'd20);  // 20 pixels escuros (brilho < 100, não contam)
        repeat (2) @(posedge clk);
        fim_frame();

        if (alerta_vazio == 1'b0) begin
            $display("  [PASS] Alerta DESATIVADO - pote cheio (0 pixels claros)");
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Alerta deveria estar inativo (nenhum pixel acima do limiar)");
            fail_count = fail_count + 1;
        end

        inicio_frame();

        // =================================================================
        // TESTE 4: Transição VAZIO → CHEIO (recuperação do sistema)
        // Transições: ALERTA → CONTANDO → AVALIANDO → NORMAL
        // =================================================================
        $display("\n[TESTE 4] Transicao VAZIO -> CHEIO (recuperacao do sistema)");
        $display("          Transicao esperada: ALERTA -> CONTANDO -> AVALIANDO -> NORMAL");

        // Fase A: Frame vazio (gera alerta)
        enviar_pixels(8'd200, 32'd15);  // 15 pixels muito claros > 10
        repeat (2) @(posedge clk);
        fim_frame();

        if (alerta_vazio == 1'b1) begin
            $display("  [OK] Fase A: Alerta ativado (pote vazio, 15 > 10)");
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Fase A: Alerta deveria estar ativo");
            fail_count = fail_count + 1;
        end

        inicio_frame();

        // Fase B: Frame cheio (dono abasteceu o pote)
        enviar_pixels(8'd30, 32'd25);  // 25 pixels muito escuros
        repeat (2) @(posedge clk);
        fim_frame();

        if (alerta_vazio == 1'b0) begin
            $display("  [PASS] Fase B: Alerta DESATIVADO apos reabastecimento");
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Fase B: Alerta deveria desativar apos frame escuro");
            fail_count = fail_count + 1;
        end

        inicio_frame();

        // =================================================================
        // TESTE 5: Frames CONSECUTIVOS vazios → Alerta persiste
        // Transições: ALERTA → CONTANDO → AVALIANDO → ALERTA (repetido)
        // =================================================================
        $display("\n[TESTE 5] Frames consecutivos VAZIOS -> Alerta persiste");
        $display("          Transicao: ALERTA -> CONTANDO -> AVALIANDO -> ALERTA");

        // Frame vazio 1
        enviar_pixels(8'd180, 32'd12);  // 12 > 10
        repeat (2) @(posedge clk);
        fim_frame();

        if (alerta_vazio == 1'b1) begin
            $display("  [OK] Frame 1: Alerta ativo (12 > 10)");
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Frame 1: Alerta deveria estar ativo");
            fail_count = fail_count + 1;
        end

        inicio_frame();

        // Frame vazio 2
        enviar_pixels(8'd160, 32'd18);  // 18 > 10
        repeat (2) @(posedge clk);
        fim_frame();

        if (alerta_vazio == 1'b1) begin
            $display("  [OK] Frame 2: Alerta ativo (18 > 10)");
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Frame 2: Alerta deveria continuar ativo");
            fail_count = fail_count + 1;
        end

        inicio_frame();

        // Frame vazio 3
        enviar_pixels(8'd140, 32'd25);  // 25 > 10
        repeat (2) @(posedge clk);
        fim_frame();

        if (alerta_vazio == 1'b1) begin
            $display("  [PASS] Frame 3: Alerta MANTIDO em 3 frames consecutivos");
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Frame 3: Alerta deveria persistir");
            fail_count = fail_count + 1;
        end

        inicio_frame();

        // =================================================================
        // TESTE 6: Frame MISTO (poucos claros) → Abaixo do limiar → NORMAL
        // Transição: CONTANDO → AVALIANDO → NORMAL
        // =================================================================
        $display("\n[TESTE 6] Frame MISTO (5 claros + 20 escuros) -> Abaixo do limiar");
        $display("          Contagem esperada: 5 (< limiar 10)");

        enviar_pixels(8'd150, 32'd5);   // 5 pixels claros (contam)
        enviar_pixels(8'd40,  32'd20);  // 20 pixels escuros (não contam)
        repeat (2) @(posedge clk);
        fim_frame();

        if (alerta_vazio == 1'b0) begin
            $display("  [PASS] Alerta INATIVO - claros (5) abaixo do limiar (10)");
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Alerta deveria estar inativo (5 < 10)");
            fail_count = fail_count + 1;
        end

        inicio_frame();

        // =================================================================
        // TESTE 7: Reset ABRUPTO durante contagem + recuperação
        // Transição forçada: qualquer estado → IDLE (via reset)
        // =================================================================
        $display("\n[TESTE 7] Reset ABRUPTO durante contagem + recuperacao");
        $display("          Transicao: CONTANDO -> (reset) -> IDLE");

        // Começa um frame com pixels claros
        enviar_pixels(8'd200, 32'd8);

        // Reset repentino no meio do frame!
        @(posedge clk); #1;
        rst_n = 1'b0;
        repeat (3) @(posedge clk);

        if (alerta_vazio == 1'b0) begin
            $display("  [PASS] Reset zerou FSM -> IDLE (alerta inativo)");
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Reset deveria levar alerta a zero");
            fail_count = fail_count + 1;
        end

        // Recuperação: libera reset e verifica funcionamento normal
        @(posedge clk); #1;
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        // Re-sincroniza (sai de IDLE)
        sync_sair_idle();

        // Frame vazio para confirmar recuperação
        enviar_pixels(8'd180, 32'd15);  // 15 > 10
        repeat (2) @(posedge clk);
        fim_frame();

        if (alerta_vazio == 1'b1) begin
            $display("  [PASS] Sistema RECUPERADO - detecta normalmente apos reset");
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Sistema deveria funcionar normalmente apos recuperacao");
            fail_count = fail_count + 1;
        end

        // =================================================================
        // RESULTADO FINAL
        // =================================================================
        repeat (10) @(posedge clk);
        $display("\n============================================================");
        $display(" RESULTADO FINAL");
        $display("============================================================");
        $display(" PASS: %0d", pass_count);
        $display(" FAIL: %0d", fail_count);
        $display(" TOTAL: %0d verificacoes", pass_count + fail_count);
        $display("============================================================");
        if (fail_count == 0)
            $display(" >>> TODOS OS TESTES PASSARAM <<<");
        else
            $display(" >>> EXISTEM FALHAS - VERIFICAR <<<");
        $display("============================================================");
        $finish;
    end

endmodule
