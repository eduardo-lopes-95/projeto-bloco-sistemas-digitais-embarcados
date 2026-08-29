// =============================================================================
// Módulo: video_overlay
// Projeto: Dog Bowl Detector v2.0 - Pipeline de Visão Computacional
// Descrição: Desenha elementos visuais sobre a imagem HDMI em tempo real:
//
//   1. Bounding Box (retângulo) ao redor da ROI
//      - Cor dinâmica: VERDE = pote OK, VERMELHO = pote vazio
//      - Espessura parametrizável da borda
//
//   2. Indicador de status no canto superior esquerdo
//      - Quadrado sólido colorido (16x16 pixels) como "semáforo"
//
//   O overlay opera no domínio do pixel de saída HDMI (1280x720),
//   então as coordenadas da ROI precisam ser mapeadas do espaço da
//   câmera (640x480) para o espaço HDMI (considerando offset de
//   centralização).
//
// Latência: 1 ciclo de clock (saídas registradas)
// =============================================================================

module video_overlay #(
    parameter H_RES       = 1280,
    parameter V_RES       = 720,
    // Offset de centralização da imagem 640x480 dentro do frame 1280x720
    parameter IMG_OFFSET_X = 320,   // (1280-640)/2 = 320
    parameter IMG_OFFSET_Y = 120,   // (720-480)/2 = 120
    // ROI no espaço da câmera (640x480)
    parameter ROI_X0      = 160,
    parameter ROI_Y0      = 120,
    parameter ROI_WIDTH   = 320,
    parameter ROI_HEIGHT  = 240,
    // Aparência
    parameter BORDER_W    = 3,      // Espessura da borda em pixels
    parameter STATUS_SIZE = 16      // Tamanho do indicador de status
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        de_in,
    input  wire        vs_in,
    input  wire        hs_in,
    input  wire [23:0] rgb_in,       // Pixel RGB888 original
    input  wire        alerta_vazio, // Estado do detector
    input  wire [3:0]  confidence,   // Nível de confiança (0-15)
    output reg  [23:0] rgb_out,      // Pixel com overlay aplicado
    output reg         de_out,
    output reg         vs_out,
    output reg         hs_out
);

    // =========================================================================
    // Coordenadas da ROI no espaço HDMI (1280x720)
    // =========================================================================
    localparam BOX_X0 = IMG_OFFSET_X + ROI_X0;
    localparam BOX_Y0 = IMG_OFFSET_Y + ROI_Y0;
    localparam BOX_X1 = BOX_X0 + ROI_WIDTH  - 1;  // Canto inferior direito X
    localparam BOX_Y1 = BOX_Y0 + ROI_HEIGHT - 1;  // Canto inferior direito Y

    // Indicador de status: canto superior esquerdo com margem
    localparam STATUS_X0 = 16;
    localparam STATUS_Y0 = 16;
    localparam STATUS_X1 = STATUS_X0 + STATUS_SIZE - 1;
    localparam STATUS_Y1 = STATUS_Y0 + STATUS_SIZE - 1;

    // =========================================================================
    // Contadores de posição do pixel HDMI
    // =========================================================================
    reg [10:0] h_cnt;
    reg [10:0] v_cnt;
    reg        vs_prev;
    reg        de_prev;

    wire vs_rising  = vs_in & ~vs_prev;
    wire de_falling = ~de_in & de_prev;

    // =========================================================================
    // Detecção de bordas do bounding box
    // =========================================================================
    wire in_box_h = (h_cnt >= BOX_X0) && (h_cnt <= BOX_X1);
    wire in_box_v = (v_cnt >= BOX_Y0) && (v_cnt <= BOX_Y1);

    // Borda superior
    wire on_top_border = in_box_h &&
                         (v_cnt >= BOX_Y0) && (v_cnt < (BOX_Y0 + BORDER_W));

    // Borda inferior
    wire on_bottom_border = in_box_h &&
                            (v_cnt > (BOX_Y1 - BORDER_W)) && (v_cnt <= BOX_Y1);

    // Borda esquerda
    wire on_left_border = in_box_v &&
                          (h_cnt >= BOX_X0) && (h_cnt < (BOX_X0 + BORDER_W));

    // Borda direita
    wire on_right_border = in_box_v &&
                           (h_cnt > (BOX_X1 - BORDER_W)) && (h_cnt <= BOX_X1);

    wire on_border = on_top_border | on_bottom_border | on_left_border | on_right_border;

    // =========================================================================
    // Indicador de status (quadrado sólido)
    // =========================================================================
    wire on_status = (h_cnt >= STATUS_X0) && (h_cnt <= STATUS_X1) &&
                     (v_cnt >= STATUS_Y0) && (v_cnt <= STATUS_Y1);

    // =========================================================================
    // Seleção de cores
    // =========================================================================
    // Bounding box: Verde (#00FF00) quando OK, Vermelho (#FF0000) quando alerta
    wire [23:0] border_color = alerta_vazio ? 24'hFF0000 : 24'h00FF00;

    // Status: mesma lógica, mas com borda branca de 1 pixel
    wire on_status_border = on_status &&
                            ((h_cnt == STATUS_X0) || (h_cnt == STATUS_X1) ||
                             (v_cnt == STATUS_Y0) || (v_cnt == STATUS_Y1));
    wire on_status_fill   = on_status && !on_status_border;

    wire [23:0] status_color = on_status_border ? 24'hFFFFFF : border_color;

    // =========================================================================
    // Barra de confiança (horizontal, abaixo do status)
    // 4 pixels de altura, comprimento proporcional ao confidence (0-15)
    // =========================================================================
    localparam BAR_Y0 = STATUS_Y1 + 4;
    localparam BAR_Y1 = BAR_Y0 + 3;
    localparam BAR_X0 = STATUS_X0;
    localparam BAR_MAX_W = 64;  // Largura máxima da barra (4px por nível)

    wire [10:0] bar_width = {7'd0, confidence} << 2;  // confidence * 4
    wire on_bar = (v_cnt >= BAR_Y0) && (v_cnt <= BAR_Y1) &&
                  (h_cnt >= BAR_X0) && (h_cnt < (BAR_X0 + bar_width));

    // Cor da barra: gradiente de verde (baixo) para vermelho (alto)
    wire [23:0] bar_color = (confidence > 4'd10) ? 24'hFF4400 :
                            (confidence > 4'd5)  ? 24'hFFAA00 :
                                                   24'h44FF00;

    // =========================================================================
    // Contadores e saída
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt   <= 11'd0;
            v_cnt   <= 11'd0;
            vs_prev <= 1'b0;
            de_prev <= 1'b0;
            rgb_out <= 24'd0;
            de_out  <= 1'b0;
            vs_out  <= 1'b0;
            hs_out  <= 1'b0;
        end else begin
            vs_prev <= vs_in;
            de_prev <= de_in;

            // Contadores de posição
            if (vs_rising) begin
                v_cnt <= 11'd0;
                h_cnt <= 11'd0;
            end else if (de_in) begin
                h_cnt <= h_cnt + 1'b1;
            end else if (de_falling) begin
                v_cnt <= v_cnt + 1'b1;
                h_cnt <= 11'd0;
            end

            // Composição do pixel de saída (prioridade: status > barra > borda > original)
            if (de_in) begin
                if (on_status)
                    rgb_out <= status_color;
                else if (on_bar)
                    rgb_out <= bar_color;
                else if (on_border)
                    rgb_out <= border_color;
                else
                    rgb_out <= rgb_in;
            end else begin
                rgb_out <= 24'd0;
            end

            // Sinais de controle passados adiante
            de_out <= de_in;
            vs_out <= vs_in;
            hs_out <= hs_in;
        end
    end

endmodule
