// =============================================================================
// Módulo: roi_window
// Projeto: Dog Bowl Detector v2.0 - Pipeline de Visão Computacional
// Descrição: Delimita uma Região de Interesse (ROI) retangular parametrizável
//            dentro do frame de vídeo. Gera sinal roi_valid=1 apenas para
//            pixels cuja coordenada (x, y) esteja dentro da janela definida.
//
//            Isso permite focar a análise de detecção apenas na área onde
//            o pote deve estar, ignorando fundo, bordas e objetos irrelevantes.
//
// Parâmetros:
//   H_RES      - Resolução horizontal ativa (pixels por linha)
//   V_RES      - Resolução vertical ativa (linhas por frame)
//   ROI_X0     - Coordenada X do canto superior esquerdo da ROI
//   ROI_Y0     - Coordenada Y do canto superior esquerdo da ROI
//   ROI_WIDTH  - Largura da ROI em pixels
//   ROI_HEIGHT - Altura da ROI em linhas
//
// Latência: 1 ciclo de clock (saídas registradas)
// =============================================================================

module roi_window #(
    parameter H_RES      = 640,
    parameter V_RES      = 480,
    parameter ROI_X0     = 160,   // Canto superior esquerdo X
    parameter ROI_Y0     = 120,   // Canto superior esquerdo Y
    parameter ROI_WIDTH  = 320,   // Largura da ROI
    parameter ROI_HEIGHT = 240    // Altura da ROI
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vs_in,      // Vertical sync
    input  wire        de_in,      // Data enable (pixel válido)
    output reg         roi_valid,  // 1 = pixel está dentro da ROI
    output reg  [10:0] pixel_x,   // Coordenada X atual (para debug/overlay)
    output reg  [10:0] pixel_y    // Coordenada Y atual (para debug/overlay)
);

    // =========================================================================
    // Contadores de posição
    // =========================================================================
    reg [10:0] h_cnt;       // Contador horizontal (0 a H_RES-1)
    reg [10:0] v_cnt;       // Contador vertical (0 a V_RES-1)
    reg        vs_prev;     // VSYNC anterior para detecção de borda
    reg        de_prev;     // DE anterior para detecção de fim de linha

    // =========================================================================
    // Detecção de bordas
    // =========================================================================
    wire vs_rising  = vs_in & ~vs_prev;    // Início de novo frame
    wire de_falling = ~de_in & de_prev;    // Fim de linha ativa

    // =========================================================================
    // Lógica combinacional de verificação ROI
    // =========================================================================
    wire in_roi_h = (h_cnt >= ROI_X0) && (h_cnt < (ROI_X0 + ROI_WIDTH));
    wire in_roi_v = (v_cnt >= ROI_Y0) && (v_cnt < (ROI_Y0 + ROI_HEIGHT));
    wire in_roi   = in_roi_h & in_roi_v & de_in;

    // =========================================================================
    // Lógica sequencial
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt     <= 11'd0;
            v_cnt     <= 11'd0;
            vs_prev   <= 1'b0;
            de_prev   <= 1'b0;
            roi_valid <= 1'b0;
            pixel_x   <= 11'd0;
            pixel_y   <= 11'd0;
        end else begin
            vs_prev <= vs_in;
            de_prev <= de_in;

            // Reset no início de cada frame (VSYNC rising)
            if (vs_rising) begin
                h_cnt <= 11'd0;
                v_cnt <= 11'd0;
            end else if (de_in) begin
                // Durante pixel ativo: incrementa coluna
                h_cnt <= h_cnt + 1'b1;
            end else if (de_falling) begin
                // Fim da linha: reseta coluna, incrementa linha
                h_cnt <= 11'd0;
                v_cnt <= v_cnt + 1'b1;
            end

            // Saídas registradas (1 clock de latência)
            roi_valid <= in_roi;
            pixel_x   <= h_cnt;
            pixel_y   <= v_cnt;
        end
    end

endmodule
