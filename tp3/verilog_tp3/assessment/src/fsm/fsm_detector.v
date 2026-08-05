// -----------------------------------------------------------------------------
// Módulo: fsm_detector
// Projeto: Dog Bowl Detector - FSM Hierárquica
// Descrição: Máquina de estados finitos que controla o fluxo de detecção.
//            Gerencia as fases de contagem, avaliação e geração de alerta
//            baseado na quantidade de pixels claros por frame.
// -----------------------------------------------------------------------------
// Estados:
//   IDLE      - Aguarda o primeiro VSYNC para sincronizar
//   CONTANDO  - Frame ativo, pixels sendo contados pelo pixel_counter
//   AVALIANDO - Frame terminou, compara contagem com limiar
//   ALERTA    - Pote vazio detectado (saída ativa), aguarda próximo frame
//   NORMAL    - Pote cheio (saída inativa), aguarda próximo frame
// -----------------------------------------------------------------------------

module fsm_detector #(
    parameter COUNTER_WIDTH   = 32,
    parameter PIXEL_THRESHOLD = 32'd20000  // Qtd mínima de pixels claros para alerta
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      vsync,           // Sinal VSYNC do frame
    input  wire                      de,              // Data Enable (pixels válidos)
    input  wire [COUNTER_WIDTH-1:0]  pixel_count,     // Contagem de pixels claros
    output reg                       counter_enable,  // Habilita o pixel_counter
    output reg                       counter_clear,   // Zera o pixel_counter
    output reg                       alerta_vazio     // Saída: 1 = pote vazio
);

    // Codificação de estados
    localparam [2:0] S_IDLE      = 3'b000;
    localparam [2:0] S_CONTANDO  = 3'b001;
    localparam [2:0] S_AVALIANDO = 3'b010;
    localparam [2:0] S_ALERTA    = 3'b011;
    localparam [2:0] S_NORMAL    = 3'b100;

    reg [2:0] state, next_state;

    // Detecção de bordas do VSYNC
    reg vsync_prev;
    wire vsync_rising;
    wire vsync_falling;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            vsync_prev <= 1'b0;
        else
            vsync_prev <= vsync;
    end

    assign vsync_rising  = (vsync == 1'b1) && (vsync_prev == 1'b0);
    assign vsync_falling = (vsync == 1'b0) && (vsync_prev == 1'b1);

    // ---------------------------------------------------------
    // Registro de estado (sequencial)
    // ---------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_IDLE;
        else
            state <= next_state;
    end

    // ---------------------------------------------------------
    // Lógica de próximo estado (combinacional)
    // ---------------------------------------------------------
    always @(*) begin
        next_state = state; // Default: mantém estado

        case (state)
            S_IDLE: begin
                // Aguarda qualquer borda de VSYNC para sincronizar
                if (vsync_rising || vsync_falling)
                    next_state = S_CONTANDO;
            end

            S_CONTANDO: begin
                // Quando VSYNC sobe, o frame acabou → avalia
                if (vsync_rising)
                    next_state = S_AVALIANDO;
            end

            S_AVALIANDO: begin
                // Decisão instantânea (1 clock): compara contagem com limiar
                if (pixel_count > PIXEL_THRESHOLD)
                    next_state = S_ALERTA;
                else
                    next_state = S_NORMAL;
            end

            S_ALERTA: begin
                // Permanece em ALERTA até o VSYNC cair (início do próximo frame)
                if (vsync_falling)
                    next_state = S_CONTANDO;
            end

            S_NORMAL: begin
                // Permanece em NORMAL até o VSYNC cair (início do próximo frame)
                if (vsync_falling)
                    next_state = S_CONTANDO;
            end

            default: begin
                next_state = S_IDLE;
            end
        endcase
    end

    // ---------------------------------------------------------
    // Lógica de saída (Moore - baseada apenas no estado)
    // ---------------------------------------------------------
    always @(*) begin
        // Defaults
        counter_enable = 1'b0;
        counter_clear  = 1'b0;
        alerta_vazio   = 1'b0;

        case (state)
            S_IDLE: begin
                counter_clear = 1'b1;  // Mantém contador zerado
            end

            S_CONTANDO: begin
                counter_enable = de;   // Conta apenas quando há pixel válido
            end

            S_AVALIANDO: begin
                // Não mexe no contador (leitura estável para comparação)
            end

            S_ALERTA: begin
                alerta_vazio  = 1'b1;  // ALERTA ATIVO
                counter_clear = 1'b1;  // Prepara contador para próximo frame
            end

            S_NORMAL: begin
                alerta_vazio  = 1'b0;  // Pote OK
                counter_clear = 1'b1;  // Prepara contador para próximo frame
            end

            default: begin
                counter_clear = 1'b1;
            end
        endcase
    end

endmodule
