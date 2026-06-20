`timescale 1ns/1ps

module tb_testpattern;

    // 1. Sinais de Teste (Inputs = reg, Outputs = wire)
    reg pxl_clk;
    reg rst_n;
    reg [2:0] mode;
    wire de, hs, vs;
    wire [7:0] data_r, data_g, data_b;

    // 2. Instanciando o Módulo (DUT - Device Under Test)
    testpattern dut (
        .I_pxl_clk(pxl_clk),
        .I_rst_n(rst_n),
        .I_mode(mode),
        .I_single_r(8'd255),
        .I_single_g(8'd0),
        .I_single_b(8'd0),
        // Resolução VGA: Valores ajustados para 12 bits (12'd) para remover os avisos (warnings)
        .I_h_total(12'd800), .I_h_sync(12'd96), .I_h_bporch(12'd48), .I_h_res(12'd640),
        .I_v_total(12'd525), .I_v_sync(12'd2),  .I_v_bporch(12'd33), .I_v_res(12'd480),
        .I_hs_pol(1'b0), .I_vs_pol(1'b0),
        .O_de(de), .O_hs(hs), .O_vs(vs),
        .O_data_r(data_r), .O_data_g(data_g), .O_data_b(data_b)
    );

    // 3. Geração do Clock (ex: 27MHz -> ~37ns de período)
    always #18.5 pxl_clk = ~pxl_clk;

    // 4. Estímulos e Gravação da Onda
    initial begin
        // Configura o arquivo de saída para leitura no GTKWave
        $dumpfile("onda_testpattern.vcd");
        $dumpvars(0, tb_testpattern);

        // Estado Inicial
        pxl_clk = 0;
        rst_n = 0;
        mode = 3'b000; // Modo Color Bar

        $display("Iniciando simulacao do Testpattern...");

        // Libera o Reset após 100ns (simulando o botão de inicialização)
        #100;
        rst_n = 1;

        // AUMENTO CRÍTICO DE TEMPO: 20 milhões de nanossegundos (20ms)
        // Isso dá tempo para o monitor virtual passar do Vertical Sync e começar a desenhar cores
        #20000000;

        // Troca o modo de vídeo para testar a resposta do módulo dinamicamente
        $display("Trocando para Modo Gray...");
        mode = 3'b010; // Modo Gray
        
        // Dá mais 20ms de tempo para desenhar o novo padrão na onda
        #20000000;

        $display("Simulacao Concluida!");
        $finish;
    end

endmodule