// =============================================================================
// Testbench: tb_vision_pipeline
// Projeto: Dog Bowl Detector v2.0 - Pipeline de Visão Computacional
// Descrição: Testbench completo que exercita toda a pipeline de visão
//            computacional (rgb2gray → roi_window → erosion_3x3 →
//            detection_engine) simulando frames de vídeo realistas.
//
// Casos de teste:
//   1. Reset inicial → todos os módulos em estado limpo
//   2. Frame com região brilhante uniforme na ROI → detecção após 3 frames
//   3. Frame escuro na ROI → sem detecção
//   4. Histerese: alerta não desliga com 1 frame escuro (precisa de 5)
//   5. Pixels brilhantes FORA da ROI → não devem contar
//   6. Ruído pontual (pixels isolados) → erosão deve filtrar
//   7. Transição completa: alerta → clear após 5 frames escuros
// =============================================================================

`timescale 1ns/1ps

module tb_vision_pipeline;

    // =========================================================================
    // Parâmetros do testbench
    // =========================================================================
    localparam H_RES      = 64;    // Resolução reduzida para simulação rápida
    localparam V_RES      = 48;
    localparam ROI_X0     = 16;
    localparam ROI_Y0     = 12;
    localparam ROI_WIDTH  = 32;
    localparam ROI_HEIGHT = 24;
    localparam THRESHOLD  = 8'd100;
    localparam THRESHOLD_HIGH = 20'd50;   // Reduzido para teste
    localparam THRESHOLD_LOW  = 20'd25;
    localparam FRAMES_TO_ALERT = 4'd3;
    localparam FRAMES_TO_CLEAR = 4'd5;

    // Clock: 74.25 MHz → ~13.5ns período (simplificado para 10ns)
    localparam CLK_PERIOD = 10;

    // =========================================================================
    // Sinais
    // =========================================================================
    reg         clk;
    reg         rst_n;
    reg         de_in;
    reg         vs_in;
    reg         hs_in;
    reg  [15:0] rgb565_in;

    // Saídas do rgb2gray
    wire        gray_de, gray_vs, gray_hs;
    wire [7:0]  gray_pixel;

    // Saídas do roi_window
    wire        roi_valid;
    wire [10:0] roi_px_x, roi_px_y;

    // Saídas do erosion_3x3
    wire        eroded_pixel, erode_de, erode_vs;

    // Saídas do detection_engine
    wire        alerta_vazio;
    wire [19:0] dbg_pixel_count;
    wire [3:0]  dbg_confidence;

    // =========================================================================
    // Instâncias dos módulos (DUT)
    // =========================================================================

    // Estágio 1: RGB → Grayscale
    rgb2gray u_rgb2gray (
        .clk       (clk),
        .rst_n     (rst_n),
        .de_in     (de_in),
        .vs_in     (vs_in),
        .hs_in     (hs_in),
        .rgb565_in (rgb565_in),
        .de_out    (gray_de),
        .vs_out    (gray_vs),
        .hs_out    (gray_hs),
        .gray_out  (gray_pixel)
    );

    // Estágio 2: ROI
    roi_window #(
        .H_RES      (H_RES),
        .V_RES      (V_RES),
        .ROI_X0     (ROI_X0),
        .ROI_Y0     (ROI_Y0),
        .ROI_WIDTH  (ROI_WIDTH),
        .ROI_HEIGHT (ROI_HEIGHT)
    ) u_roi_window (
        .clk       (clk),
        .rst_n     (rst_n),
        .vs_in     (gray_vs),
        .de_in     (gray_de),
        .roi_valid (roi_valid),
        .pixel_x   (roi_px_x),
        .pixel_y   (roi_px_y)
    );

    // Estágio 3: Erosão
    erosion_3x3 #(
        .H_RES     (H_RES),
        .THRESHOLD (THRESHOLD)
    ) u_erosion (
        .clk         (clk),
        .rst_n       (rst_n),
        .de_in       (gray_de),
        .vs_in       (gray_vs),
        .gray_in     (gray_pixel),
        .pixel_valid (eroded_pixel),
        .de_out      (erode_de),
        .vs_out      (erode_vs)
    );

    // Estágio 4: Detection Engine
    detection_engine #(
        .COUNTER_WIDTH   (20),
        .THRESHOLD_HIGH  (THRESHOLD_HIGH),
        .THRESHOLD_LOW   (THRESHOLD_LOW),
        .FRAMES_TO_ALERT (FRAMES_TO_ALERT),
        .FRAMES_TO_CLEAR (FRAMES_TO_CLEAR)
    ) u_detection_engine (
        .clk              (clk),
        .rst_n            (rst_n),
        .vsync            (erode_vs),
        .pixel_valid      (eroded_pixel & roi_valid),
        .alerta_vazio     (alerta_vazio),
        .debug_count      (dbg_pixel_count),
        .debug_confidence (dbg_confidence)
    );

    // =========================================================================
    // Geração de clock
    // =========================================================================
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // Tasks auxiliares para simular protocolo de vídeo
    // =========================================================================

    // Gera um pulso de VSYNC (início de frame)
    task vsync_pulse;
        begin
            @(posedge clk); #1;
            vs_in = 1'b1;
            repeat (4) @(posedge clk);
            #1; vs_in = 1'b0;
            repeat (4) @(posedge clk);
        end
    endtask

    // Envia uma linha de pixels com brilho especificado
    // brightness_mode: 0=escuro, 1=brilhante, 2=misto (alternado), 3=ruído pontual
    task send_line;
        input [10:0] line_num;
        input [1:0]  brightness_mode;
        integer col;
        reg [7:0] r_val, g_val, b_val;
        begin
            // Pequena pausa (horizontal blanking)
            repeat (4) @(posedge clk);

            for (col = 0; col < H_RES; col = col + 1) begin
                @(posedge clk); #1;
                de_in = 1'b1;

                case (brightness_mode)
                    2'd0: begin // Escuro (pote cheio - superfície escura)
                        r_val = 8'd30;
                        g_val = 8'd25;
                        b_val = 8'd20;
                    end
                    2'd1: begin // Brilhante (pote vazio - fundo claro)
                        r_val = 8'd200;
                        g_val = 8'd190;
                        b_val = 8'd180;
                    end
                    2'd2: begin // Misto (metade brilhante)
                        if (col < H_RES/2) begin
                            r_val = 8'd200;
                            g_val = 8'd190;
                            b_val = 8'd180;
                        end else begin
                            r_val = 8'd30;
                            g_val = 8'd25;
                            b_val = 8'd20;
                        end
                    end
                    2'd3: begin // Ruído pontual (1 pixel claro a cada 8)
                        if (col % 8 == 0) begin
                            r_val = 8'd220;
                            g_val = 8'd210;
                            b_val = 8'd200;
                        end else begin
                            r_val = 8'd30;
                            g_val = 8'd25;
                            b_val = 8'd20;
                        end
                    end
                endcase

                // Converte RGB888 → RGB565 para entrada
                rgb565_in = {r_val[7:3], g_val[7:2], b_val[7:3]};
            end

            @(posedge clk); #1;
            de_in = 1'b0;
            rgb565_in = 16'd0;
        end
    endtask

    // Envia um frame completo
    // roi_brightness: brilho dentro da ROI
    // bg_brightness: brilho fora da ROI
    task send_frame;
        input [1:0] roi_brightness;
        input [1:0] bg_brightness;
        integer line;
        begin
            vsync_pulse();

            for (line = 0; line < V_RES; line = line + 1) begin
                // Verifica se a linha está dentro da ROI vertical
                if (line >= ROI_Y0 && line < (ROI_Y0 + ROI_HEIGHT))
                    send_line(line, roi_brightness);
                else
                    send_line(line, bg_brightness);
            end

            // Período de blanking vertical
            repeat (20) @(posedge clk);
        end
    endtask

    // =========================================================================
    // Contadores de resultado
    // =========================================================================
    integer pass_count;
    integer fail_count;

    // =========================================================================
    // Sequência de testes
    // =========================================================================
    initial begin
        $dumpfile("onda_vision_pipeline.vcd");
        $dumpvars(0, tb_vision_pipeline);

        // Inicialização
        clk       = 0;
        rst_n     = 0;
        de_in     = 0;
        vs_in     = 0;
        hs_in     = 0;
        rgb565_in = 16'd0;
        pass_count = 0;
        fail_count = 0;

        $display("================================================================");
        $display(" TESTBENCH: Vision Pipeline v2.0 - Dog Bowl Detector");
        $display("================================================================");
        $display(" Configuracao:");
        $display("   Resolucao: %0dx%0d", H_RES, V_RES);
        $display("   ROI: (%0d,%0d) %0dx%0d", ROI_X0, ROI_Y0, ROI_WIDTH, ROI_HEIGHT);
        $display("   Threshold brilho: %0d", THRESHOLD);
        $display("   Threshold alto (ativar): %0d pixels", THRESHOLD_HIGH);
        $display("   Threshold baixo (desativar): %0d pixels", THRESHOLD_LOW);
        $display("   Frames para alertar: %0d", FRAMES_TO_ALERT);
        $display("   Frames para limpar: %0d", FRAMES_TO_CLEAR);
        $display("================================================================");

        // =================================================================
        // TESTE 1: Reset inicial
        // =================================================================
        $display("\n[TESTE 1] Reset inicial - pipeline em estado limpo");
        repeat (10) @(posedge clk);
        #1; rst_n = 1'b1;
        repeat (5) @(posedge clk);

        if (alerta_vazio == 1'b0) begin
            $display("  [PASS] Alerta inativo apos reset");
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Alerta deveria estar inativo apos reset");
            fail_count = fail_count + 1;
        end

        // =================================================================
        // TESTE 2: Frames brilhantes na ROI → alerta após 3 frames
        // =================================================================
        $display("\n[TESTE 2] 3 frames brilhantes na ROI -> alerta deve ativar");
        $display("          (confirmacao multi-frame: FRAMES_TO_ALERT = %0d)", FRAMES_TO_ALERT);

        // Frame 1: brilhante na ROI, escuro fora
        $display("  Enviando frame 1 (brilhante na ROI)...");
        send_frame(2'd1, 2'd0);

        if (alerta_vazio == 1'b0) begin
            $display("  [OK] Frame 1: alerta ainda inativo (esperado, precisa de 3)");
        end else begin
            $display("  [INFO] Frame 1: alerta ja ativo (pipeline pode ter latencia diferente)");
        end

        // Frame 2
        $display("  Enviando frame 2 (brilhante na ROI)...");
        send_frame(2'd1, 2'd0);

        if (alerta_vazio == 1'b0) begin
            $display("  [OK] Frame 2: alerta ainda inativo (esperado, precisa de 3)");
        end else begin
            $display("  [INFO] Frame 2: alerta ativo antes do esperado");
        end

        // Frame 3 → deve ativar alerta
        $display("  Enviando frame 3 (brilhante na ROI)...");
        send_frame(2'd1, 2'd0);

        if (alerta_vazio == 1'b1) begin
            $display("  [PASS] Frame 3: ALERTA ATIVADO apos 3 frames consecutivos");
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Frame 3: alerta deveria estar ativo");
            fail_count = fail_count + 1;
        end

        // =================================================================
        // TESTE 3: Frame escuro na ROI com fundo brilhante FORA
        // =================================================================
        $display("\n[TESTE 3] Frame escuro na ROI, brilhante FORA -> ROI deve filtrar");
        $display("          Pixels fora da ROI NAO devem influenciar a deteccao");

        // Primeiro precisamos limpar o alerta (5 frames escuros)
        repeat (6) send_frame(2'd0, 2'd1);  // Escuro na ROI, brilhante fora

        if (alerta_vazio == 1'b0) begin
            $display("  [PASS] Alerta INATIVO - pixels fora da ROI foram ignorados");
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Alerta deveria estar inativo (ROI escura)");
            fail_count = fail_count + 1;
        end

        // =================================================================
        // TESTE 4: Histerese - alerta não desliga com poucos frames escuros
        // =================================================================
        $display("\n[TESTE 4] Histerese: alerta persiste com menos de %0d frames escuros", FRAMES_TO_CLEAR);

        // Ativa alerta (3 frames brilhantes)
        repeat (3) send_frame(2'd1, 2'd0);

        if (alerta_vazio == 1'b1) begin
            $display("  [OK] Alerta ativado para teste de histerese");
        end else begin
            $display("  [WARN] Alerta nao ativou - teste de histerese comprometido");
        end

        // Envia apenas 2 frames escuros (menos que FRAMES_TO_CLEAR=5)
        send_frame(2'd0, 2'd0);
        send_frame(2'd0, 2'd0);

        if (alerta_vazio == 1'b1) begin
            $display("  [PASS] Histerese OK: alerta MANTIDO apos 2 frames escuros (< %0d)", FRAMES_TO_CLEAR);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Histerese falhou: alerta nao deveria desligar com 2 frames");
            fail_count = fail_count + 1;
        end

        // =================================================================
        // TESTE 5: Ruído pontual → erosão deve filtrar
        // =================================================================
        $display("\n[TESTE 5] Ruido pontual (pixels isolados) -> erosao deve eliminar");

        // Limpa estado: muitos frames escuros
        repeat (6) send_frame(2'd0, 2'd0);

        // Envia frames com ruído pontual na ROI
        repeat (4) send_frame(2'd3, 2'd0);

        if (alerta_vazio == 1'b0) begin
            $display("  [PASS] Erosao filtrou ruido pontual - alerta INATIVO");
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Erosao nao filtrou ruido - alerta nao deveria estar ativo");
            fail_count = fail_count + 1;
        end

        // =================================================================
        // TESTE 6: Transição completa alerta → clear
        // =================================================================
        $display("\n[TESTE 6] Transicao completa: ativar alerta, depois limpar com %0d frames", FRAMES_TO_CLEAR);

        // Ativa alerta
        repeat (4) send_frame(2'd1, 2'd0);

        if (alerta_vazio == 1'b1) begin
            $display("  [OK] Alerta ativado");
        end

        // Limpa com exatamente FRAMES_TO_CLEAR frames escuros
        $display("  Enviando %0d frames escuros para limpar...", FRAMES_TO_CLEAR + 1);
        repeat (FRAMES_TO_CLEAR + 1) send_frame(2'd0, 2'd0);

        if (alerta_vazio == 1'b0) begin
            $display("  [PASS] Alerta LIMPO apos %0d+ frames escuros consecutivos", FRAMES_TO_CLEAR);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Alerta deveria ter sido limpo");
            fail_count = fail_count + 1;
        end

        // =================================================================
        // TESTE 7: Reset durante operação
        // =================================================================
        $display("\n[TESTE 7] Reset abrupto durante operacao + recuperacao");

        // Coloca em estado de alerta
        repeat (4) send_frame(2'd1, 2'd0);

        // Reset
        @(posedge clk); #1;
        rst_n = 1'b0;
        repeat (5) @(posedge clk);

        if (alerta_vazio == 1'b0) begin
            $display("  [PASS] Reset zerou pipeline (alerta inativo)");
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Reset deveria zerar o alerta");
            fail_count = fail_count + 1;
        end

        // Recuperação
        @(posedge clk); #1;
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // Verifica que funciona normalmente após reset
        repeat (4) send_frame(2'd1, 2'd0);

        if (alerta_vazio == 1'b1) begin
            $display("  [PASS] Pipeline RECUPERADA - detecta normalmente apos reset");
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Pipeline deveria funcionar apos recuperacao");
            fail_count = fail_count + 1;
        end

        // =================================================================
        // RESULTADO FINAL
        // =================================================================
        repeat (20) @(posedge clk);
        $display("\n================================================================");
        $display(" RESULTADO FINAL");
        $display("================================================================");
        $display(" PASS: %0d", pass_count);
        $display(" FAIL: %0d", fail_count);
        $display(" TOTAL: %0d verificacoes", pass_count + fail_count);
        $display("================================================================");
        if (fail_count == 0)
            $display(" >>> TODOS OS TESTES PASSARAM <<<");
        else
            $display(" >>> EXISTEM FALHAS - VERIFICAR <<<");
        $display("================================================================");
        $finish;
    end

    // =========================================================================
    // Monitor de debug (opcional - descomente para debug detalhado)
    // =========================================================================
    // always @(posedge erode_vs) begin
    //     $display("  [DBG] Frame end: pixel_count=%0d, confidence=%0d, alerta=%b",
    //              dbg_pixel_count, dbg_confidence, alerta_vazio);
    // end

endmodule
