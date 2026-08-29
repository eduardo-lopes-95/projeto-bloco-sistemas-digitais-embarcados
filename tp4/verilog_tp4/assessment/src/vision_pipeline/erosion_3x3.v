// =============================================================================
// Módulo: erosion_3x3
// Projeto: Dog Bowl Detector v2.0 - Pipeline de Visão Computacional
// Descrição: Filtro morfológico de erosão com kernel 3x3 aplicado sobre
//            imagem binária (pixels acima/abaixo de um limiar de brilho).
//
//            A erosão remove pixels isolados (ruído "sal") e encolhe
//            regiões brilhantes. Um pixel central só sobrevive se TODOS
//            os 9 pixels na vizinhança 3x3 estiverem acima do threshold.
//
//            Utiliza 2 line buffers (RAM de porta simples) para manter 3
//            linhas simultâneas, formando a janela de convolução 3x3.
//
// Inferência de BSRAM:
//   - Cada line buffer tem UMA escrita e UMA leitura síncrona por ciclo,
//     no mesmo endereço, sem escrita cruzada entre buffers. Esse padrão é
//     reconhecido pela síntese Gowin como Block SRAM (semi-dual port).
//   - A cadeia de linhas é formada encadeando os dados lidos, não
//     promovendo o conteúdo de um buffer para o outro dentro da RAM.
//
// Recursos:
//   - 2 × H_RES × 8 bits em BSRAM (ex.: 2 × 640 × 8 = 10240 bits)
//   - ~200 LUTs para controle e comparadores
//
// Latência: 2 linhas + 2 pixels (delay inerente da janela 3x3)
// =============================================================================

module erosion_3x3 #(
    parameter H_RES     = 640,      // Resolução horizontal (largura da linha)
    parameter ADDR_W    = 10,       // Largura do endereço (2^10 = 1024 >= 640)
    parameter THRESHOLD = 8'd100    // Limiar de binarização
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       de_in,        // Data enable (pixel válido na entrada)
    input  wire       vs_in,        // Vertical sync
    input  wire [7:0] gray_in,      // Pixel grayscale de entrada
    output reg        pixel_valid,  // 1 = pixel sobreviveu à erosão
    output reg        de_out,       // Data enable (atrasado pela pipeline)
    output reg        vs_out        // Vertical sync (atrasado pela pipeline)
);

    // =========================================================================
    // Line Buffers - Armazenam 2 linhas anteriores.
    // line_buf1 -> linha imediatamente anterior (meio da janela)
    // line_buf0 -> duas linhas atrás (topo da janela)
    // Cada RAM: 1 escrita + 1 leitura por ciclo -> inferência de BSRAM.
    // =========================================================================
    reg [7:0] line_buf0 [0:H_RES-1];
    reg [7:0] line_buf1 [0:H_RES-1];

    // Saídas registradas de leitura das RAMs (obrigatório para BSRAM síncrona)
    reg [7:0] rd0;   // valor lido de line_buf0 (linha -2)
    reg [7:0] rd1;   // valor lido de line_buf1 (linha -1)

    // =========================================================================
    // Endereçamento e controle
    // =========================================================================
    reg [ADDR_W-1:0] addr;     // Endereço de coluna (compartilhado leitura/escrita)
    reg              vs_prev;
    wire vs_rising = vs_in & ~vs_prev;

    // =========================================================================
    // Janela 3x3: 3 linhas x 3 colunas
    // rowN_c0 = coluna atual, _c1 = coluna anterior, _c2 = 2 colunas atrás
    // =========================================================================
    reg [7:0] row0_c0, row0_c1, row0_c2;  // Linha -2 (topo)
    reg [7:0] row1_c0, row1_c1, row1_c2;  // Linha -1 (meio)
    reg [7:0] row2_c0, row2_c1, row2_c2;  // Linha atual

    // =========================================================================
    // Binarização: cada pixel da janela comparado com threshold
    // =========================================================================
    wire bin_00 = (row0_c2 > THRESHOLD);
    wire bin_01 = (row0_c1 > THRESHOLD);
    wire bin_02 = (row0_c0 > THRESHOLD);
    wire bin_10 = (row1_c2 > THRESHOLD);
    wire bin_11 = (row1_c1 > THRESHOLD);  // Pixel central
    wire bin_12 = (row1_c0 > THRESHOLD);
    wire bin_20 = (row2_c2 > THRESHOLD);
    wire bin_21 = (row2_c1 > THRESHOLD);
    wire bin_22 = (row2_c0 > THRESHOLD);

    // Erosão: AND de todos os 9 pixels binários
    wire eroded = bin_00 & bin_01 & bin_02 &
                  bin_10 & bin_11 & bin_12 &
                  bin_20 & bin_21 & bin_22;

    // =========================================================================
    // Pipeline de sinais de controle
    // =========================================================================
    reg [2:0] de_pipe;
    reg [2:0] vs_pipe;
    reg [1:0] line_valid;   // 2 = já temos 3 linhas disponíveis

    // =========================================================================
    // Bloco de leitura/escrita das RAMs (porta simples síncrona)
    // Escrita: line_buf1 recebe o pixel atual; line_buf0 recebe o que estava
    //          em line_buf1 no ciclo (valor lido rd1). Como rd1 é a saída
    //          registrada da leitura anterior, não há leitura+escrita cruzada
    //          combinacional no mesmo array.
    // =========================================================================
    always @(posedge clk) begin
        if (de_in) begin
            // Leitura síncrona (endereço atual)
            rd0 <= line_buf0[addr];
            rd1 <= line_buf1[addr];

            // Escrita síncrona (mesmo endereço)
            line_buf0[addr] <= rd1;      // linha -1 do ciclo anterior desce p/ -2
            line_buf1[addr] <= gray_in;  // pixel atual vira linha -1
        end
    end

    // =========================================================================
    // Lógica de controle e formação da janela
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            addr         <= {ADDR_W{1'b0}};
            vs_prev      <= 1'b0;
            pixel_valid  <= 1'b0;
            de_out       <= 1'b0;
            vs_out       <= 1'b0;
            de_pipe      <= 3'b0;
            vs_pipe      <= 3'b0;
            line_valid   <= 2'd0;
            row0_c0 <= 8'd0; row0_c1 <= 8'd0; row0_c2 <= 8'd0;
            row1_c0 <= 8'd0; row1_c1 <= 8'd0; row1_c2 <= 8'd0;
            row2_c0 <= 8'd0; row2_c1 <= 8'd0; row2_c2 <= 8'd0;
        end else begin
            vs_prev <= vs_in;

            // Reset de frame no VSYNC rising
            if (vs_rising) begin
                addr       <= {ADDR_W{1'b0}};
                line_valid <= 2'd0;
            end

            if (de_in) begin
                // Colunas atuais da janela vêm das leituras registradas.
                // rd0/rd1 refletem o endereço lido no ciclo anterior; para
                // alinhamento usamos os valores correntes das RAMs.
                row0_c0 <= rd0;      // linha -2
                row1_c0 <= rd1;      // linha -1
                row2_c0 <= gray_in;  // linha atual

                // Shift horizontal: forma as 3 colunas
                row0_c1 <= row0_c0; row0_c2 <= row0_c1;
                row1_c1 <= row1_c0; row1_c2 <= row1_c1;
                row2_c1 <= row2_c0; row2_c2 <= row2_c1;

                // Incrementa endereço de coluna
                if (addr == H_RES - 1)
                    addr <= {ADDR_W{1'b0}};
                else
                    addr <= addr + 1'b1;

                // Resultado da erosão válido após 2 linhas preenchidas
                pixel_valid <= eroded & (line_valid == 2'd2);
            end else begin
                pixel_valid <= 1'b0;

                // Fim de linha (de_in caiu): conta linha e reseta endereço
                if (de_pipe[0] && !de_in) begin
                    if (line_valid < 2'd2)
                        line_valid <= line_valid + 1'b1;
                    addr <= {ADDR_W{1'b0}};
                end
            end

            // Pipeline de sinais de controle
            de_pipe <= {de_pipe[1:0], de_in};
            vs_pipe <= {vs_pipe[1:0], vs_in};
            de_out  <= de_pipe[2];
            vs_out  <= vs_pipe[2];
        end
    end

endmodule
