// =============================================================================
// Módulo: detection_engine
// Projeto: Dog Bowl Detector v2.0 - Pipeline de Visão Computacional
// Descrição: Motor de detecção robusto com múltiplas camadas de proteção
//            contra falsos positivos/negativos:
//
//   1. Contagem de pixels válidos (pós-erosão, dentro da ROI) por frame
//   2. Dual threshold (histerese de Schmitt):
//      - THRESHOLD_HIGH: limiar para ativar alerta
//      - THRESHOLD_LOW:  limiar para desativar alerta
//      Evita oscilação quando contagem está próxima do limiar.
//   3. Confirmação temporal multi-frame:
//      - FRAMES_TO_ALERT: N frames consecutivos acima para confirmar alerta
//      - FRAMES_TO_CLEAR: M frames consecutivos abaixo para limpar alerta
//      Evita flickering causado por variações momentâneas.
//
// Saídas de debug:
//   - debug_count:      contagem do último frame (para visualização/UART)
//   - debug_confidence: nível de confiança (0-15, quantos frames confirmam)
//
// Latência: 0 clocks adicionais (opera no domínio de frame, não de pixel)
// =============================================================================

module detection_engine #(
    parameter COUNTER_WIDTH      = 20,
    parameter THRESHOLD_HIGH     = 20'd8000,   // Ativar alerta se count > HIGH
    parameter THRESHOLD_LOW      = 20'd4000,   // Desativar alerta se count < LOW
    parameter FRAMES_TO_ALERT    = 4'd3,       // Frames consecutivos para confirmar
    parameter FRAMES_TO_CLEAR    = 4'd5        // Frames consecutivos para limpar
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     vsync,         // VSYNC (borda rising = fim de frame)
    input  wire                     pixel_valid,   // Pixel que passou pela erosão + ROI
    output reg                      alerta_vazio,  // 1 = pote vazio confirmado
    output reg  [COUNTER_WIDTH-1:0] debug_count,   // Contagem do último frame
    output reg  [3:0]               debug_confidence // Nível de confiança (0-15)
);

    // =========================================================================
    // Registros internos
    // =========================================================================
    reg [COUNTER_WIDTH-1:0] pixel_count;     // Contador de pixels no frame atual
    reg [3:0]               alert_counter;   // Frames consecutivos acima do threshold
    reg [3:0]               clear_counter;   // Frames consecutivos abaixo do threshold
    reg                     vsync_prev;      // VSYNC anterior para detecção de borda

    // =========================================================================
    // Detecção de borda do VSYNC
    // =========================================================================
    wire vsync_rising = vsync & ~vsync_prev;

    // =========================================================================
    // Estado interno: indica se estamos "tendendo" para alerta
    // Usado para selecionar qual threshold aplicar (histerese)
    // =========================================================================
    wire [COUNTER_WIDTH-1:0] active_threshold = alerta_vazio ? THRESHOLD_LOW : THRESHOLD_HIGH;

    // =========================================================================
    // Lógica principal
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_count      <= {COUNTER_WIDTH{1'b0}};
            alert_counter    <= 4'd0;
            clear_counter    <= 4'd0;
            alerta_vazio     <= 1'b0;
            vsync_prev       <= 1'b0;
            debug_count      <= {COUNTER_WIDTH{1'b0}};
            debug_confidence <= 4'd0;
        end else begin
            vsync_prev <= vsync;

            // =============================================================
            // Fim de frame: avalia contagem acumulada
            // =============================================================
            if (vsync_rising) begin
                // Salva contagem para debug
                debug_count <= pixel_count;

                // ---------------------------------------------------------
                // Máquina de decisão com histerese
                // ---------------------------------------------------------
                if (!alerta_vazio) begin
                    // --- ESTADO NORMAL: verificando se deve alertar ---
                    if (pixel_count > THRESHOLD_HIGH) begin
                        // Frame indica pote vazio
                        alert_counter <= alert_counter + 1'b1;
                        clear_counter <= 4'd0;

                        // Confirmação: N frames consecutivos → ativa alerta
                        if (alert_counter >= (FRAMES_TO_ALERT - 1)) begin
                            alerta_vazio  <= 1'b1;
                            alert_counter <= 4'd0;
                        end
                    end else begin
                        // Frame normal: reseta contador de alerta
                        alert_counter <= 4'd0;
                    end
                end else begin
                    // --- ESTADO ALERTA: verificando se deve limpar ---
                    if (pixel_count < THRESHOLD_LOW) begin
                        // Frame indica pote cheio
                        clear_counter <= clear_counter + 1'b1;
                        alert_counter <= 4'd0;

                        // Confirmação: M frames consecutivos → limpa alerta
                        if (clear_counter >= (FRAMES_TO_CLEAR - 1)) begin
                            alerta_vazio  <= 1'b0;
                            clear_counter <= 4'd0;
                        end
                    end else begin
                        // Frame ainda indica vazio: reseta contador de clear
                        clear_counter <= 4'd0;
                    end
                end

                // Saída de confiança: quantos frames confirmam o estado
                if (alerta_vazio)
                    debug_confidence <= clear_counter;  // Frames tentando limpar
                else
                    debug_confidence <= alert_counter;  // Frames tentando alertar

                // Reset do contador de pixels para próximo frame
                pixel_count <= {COUNTER_WIDTH{1'b0}};

            end else if (pixel_valid) begin
                // =============================================================
                // Durante o frame: acumula pixels válidos
                // =============================================================
                pixel_count <= pixel_count + 1'b1;
            end
        end
    end

endmodule
