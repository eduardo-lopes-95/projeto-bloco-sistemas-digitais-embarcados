// =============================================================================
// Módulo: rgb2gray
// Projeto: Dog Bowl Detector v2.0 - Pipeline de Visão Computacional
// Descrição: Converte pixels RGB565 para luminância (grayscale) usando
//            coeficientes ITU-R BT.601:
//            Y = 0.299*R + 0.587*G + 0.114*B
//            Implementação em ponto fixo (8 bits fracionários):
//            Y = (77*R + 150*G + 29*B) >> 8
// Latência: 2 ciclos de clock (pipeline de 2 estágios)
// =============================================================================

module rgb2gray (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        de_in,
    input  wire        vs_in,
    input  wire        hs_in,
    input  wire [15:0] rgb565_in,   // {R[4:0], G[5:0], B[4:0]}
    output reg         de_out,
    output reg         vs_out,
    output reg         hs_out,
    output reg  [7:0]  gray_out
);

    // =========================================================================
    // Estágio 1: Expansão RGB565 → RGB888 + Multiplicação
    // =========================================================================

    // Expansão com replicação de MSBs para preencher 8 bits
    wire [7:0] r8 = {rgb565_in[15:11], rgb565_in[15:13]};  // 5 bits → 8 bits
    wire [7:0] g8 = {rgb565_in[10:5],  rgb565_in[10:9]};   // 6 bits → 8 bits
    wire [7:0] b8 = {rgb565_in[4:0],   rgb565_in[4:2]};    // 5 bits → 8 bits

    // Coeficientes BT.601 em ponto fixo Q0.8
    // 0.299 ≈ 77/256, 0.587 ≈ 150/256, 0.114 ≈ 29/256
    // Soma dos coeficientes: 77 + 150 + 29 = 256 (normalizado)
    reg [15:0] prod_r;   // 8 × 8 = 16 bits max
    reg [15:0] prod_g;
    reg [15:0] prod_b;

    // Pipeline de sinais de controle - estágio 1
    reg de_s1, vs_s1, hs_s1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod_r <= 16'd0;
            prod_g <= 16'd0;
            prod_b <= 16'd0;
            de_s1  <= 1'b0;
            vs_s1  <= 1'b0;
            hs_s1  <= 1'b0;
        end else begin
            prod_r <= r8 * 8'd77;
            prod_g <= g8 * 8'd150;
            prod_b <= b8 * 8'd29;
            de_s1  <= de_in;
            vs_s1  <= vs_in;
            hs_s1  <= hs_in;
        end
    end

    // =========================================================================
    // Estágio 2: Soma + Truncamento
    // =========================================================================

    // Soma pode ter até 17 bits (255*256 = 65280 < 2^16), então 16 bits basta
    wire [15:0] y_sum = prod_r + prod_g + prod_b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gray_out <= 8'd0;
            de_out   <= 1'b0;
            vs_out   <= 1'b0;
            hs_out   <= 1'b0;
        end else begin
            gray_out <= y_sum[15:8];  // Divide por 256 (shift right 8)
            de_out   <= de_s1;
            vs_out   <= vs_s1;
            hs_out   <= hs_s1;
        end
    end

endmodule
