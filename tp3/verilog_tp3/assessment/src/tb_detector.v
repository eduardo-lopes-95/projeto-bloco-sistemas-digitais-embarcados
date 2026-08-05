`timescale 1ns/1ps

module tb_detector;

    // Entradas (Sinais que a câmera geraria)
    reg pix_clk;
    reg rgb_vs;
    reg rgb_de;
    reg [23:0] rgb_data;

    // Saídas (Sinal que vai para o ESP32)
    reg alerta_vazio;

    // Variáveis internas da nossa lógica
    reg [31:0] contador_fundo_pote;
    reg rgb_vs_prev;

    always @(posedge pix_clk) begin
        rgb_vs_prev <= rgb_vs;

        if (rgb_vs == 1'b1 && rgb_vs_prev == 1'b0) begin
            if (contador_fundo_pote > 5) begin // Meta reduzida para 5 no teste
                alerta_vazio <= 1'b1;
            end else begin
                alerta_vazio <= 1'b0;
            end
            contador_fundo_pote <= 0;
            
        end else if (rgb_de == 1'b1) begin
            if (rgb_data[15:8] > 8'd100) begin
                contador_fundo_pote <= contador_fundo_pote + 1;
            end
        end
    end
    
    // Gera um clock infinito (alterna a cada 10 nanosegundos)
    always #10 pix_clk = ~pix_clk;

    initial begin
        
        $dumpfile("onda_detector.vcd");
        $dumpvars(0, tb_detector);
        
        // 1. Zera tudo ao ligar
        pix_clk = 0; rgb_vs = 0; rgb_de = 0; rgb_data = 0;
        contador_fundo_pote = 0; alerta_vazio = 0; rgb_vs_prev = 0;

        $display("Iniciando Simulacao...");
        #100; // Espera um pouco

        // TESTE 1: FRAME CLARO (Pote Vazio -> Deve ligar o alerta)
        $display("Injetando pixels claros (Brilho 150)...");
        rgb_de = 1;
        rgb_data = {8'd0, 8'd150, 8'd0}; // Injeta brilho > 100
        #120; // Mantém por 6 clocks (O contador vai chegar a 6)
        rgb_de = 0; // Fim da imagem

        #50;
        $display("Enviando pulso VSYNC...");
        rgb_vs = 1; // Fim do quadro (Dispara a avaliação)
        #20;
        rgb_vs = 0;

        // TESTE 2: FRAME ESCURO (Dedo na lente -> Deve desligar o alerta)
        #100;
        $display("Injetando pixels escuros (Brilho 50)...");
        rgb_de = 1;
        rgb_data = {8'd0, 8'd150, 8'd0}; // Injeta 2 pixels claros
        #40;
        rgb_data = {8'd0, 8'd50, 8'd0};  // Cai para brilho escuro
        #80;  // Mantém os escuros por 4 clocks (Contador morre no 2)
        rgb_de = 0; // Fim da imagem

        #50;
        $display("Enviando pulso VSYNC...");
        rgb_vs = 1; // Fim do quadro (Dispara a avaliação)
        #20;
        rgb_vs = 0;

        #100;
        $display("Simulacao concluida.");
        $finish; // Encerra o teste
    end
endmodule