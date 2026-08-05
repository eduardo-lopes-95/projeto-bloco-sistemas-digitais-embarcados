// -----------------------------------------------------------------------------
// Módulo: pixel_counter
// Projeto: Dog Bowl Detector - FSM Hierárquica
// Descrição: Conta pixels claros (brilho > limiar) durante o período ativo
//            do frame (quando DE está em nível alto).
// -----------------------------------------------------------------------------

module pixel_counter #(
    parameter THRESHOLD_BRIGHTNESS = 8'd100,  // Limiar de brilho para pixel "claro"
    parameter COUNTER_WIDTH        = 32       // Largura do contador
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      enable,      // Habilita contagem (DE ativo)
    input  wire                      clear,       // Zera o contador (novo frame)
    input  wire [7:0]                pixel_green, // Canal verde do pixel (usado como brilho)
    output wire [COUNTER_WIDTH-1:0]  count        // Contagem acumulada
);

    reg [COUNTER_WIDTH-1:0] counter;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counter <= {COUNTER_WIDTH{1'b0}};
        end else if (clear) begin
            counter <= {COUNTER_WIDTH{1'b0}};
        end else if (enable) begin
            if (pixel_green > THRESHOLD_BRIGHTNESS) begin
                counter <= counter + 1'b1;
            end
        end
    end

    assign count = counter;

endmodule
