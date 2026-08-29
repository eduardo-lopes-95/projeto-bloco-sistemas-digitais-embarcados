// -----------------------------------------------------------------------------
// Módulo: detector_top
// Projeto: Dog Bowl Detector - FSM Hierárquica
// Descrição: Módulo top-level que instancia e interconecta os sub-módulos
//            pixel_counter e fsm_detector, formando o sistema completo
//            de detecção de pote vazio.
// -----------------------------------------------------------------------------
// Hierarquia:
//   detector_top
//   ├── pixel_counter   (datapath - contagem de pixels claros)
//   └── fsm_detector    (controle - máquina de estados)
// -----------------------------------------------------------------------------

module detector_top #(
    parameter THRESHOLD_BRIGHTNESS = 8'd100,
    parameter PIXEL_THRESHOLD      = 32'd20000,
    parameter COUNTER_WIDTH        = 32
)(
    input  wire        clk,          // Pixel clock
    input  wire        rst_n,        // Reset ativo baixo
    input  wire        vsync,        // Vertical sync (indica fim/início de frame)
    input  wire        de,           // Data enable (pixel válido)
    input  wire [7:0]  pixel_green,  // Canal verde do pixel (proxy de brilho)
    output wire        alerta_vazio  // Saída: 1 = pote vazio detectado
);

    // Sinais internos de interconexão
    wire                      counter_enable;
    wire                      counter_clear;
    wire [COUNTER_WIDTH-1:0]  pixel_count;

    // ---------------------------------------------------------
    // Instância do Datapath: Contador de Pixels Claros
    // ---------------------------------------------------------
    pixel_counter #(
        .THRESHOLD_BRIGHTNESS (THRESHOLD_BRIGHTNESS),
        .COUNTER_WIDTH        (COUNTER_WIDTH)
    ) u_pixel_counter (
        .clk         (clk),
        .rst_n       (rst_n),
        .enable      (counter_enable),
        .clear       (counter_clear),
        .pixel_green (pixel_green),
        .count       (pixel_count)
    );

    // ---------------------------------------------------------
    // Instância do Controle: FSM do Detector
    // ---------------------------------------------------------
    fsm_detector #(
        .COUNTER_WIDTH   (COUNTER_WIDTH),
        .PIXEL_THRESHOLD (PIXEL_THRESHOLD)
    ) u_fsm_detector (
        .clk            (clk),
        .rst_n          (rst_n),
        .vsync          (vsync),
        .de             (de),
        .pixel_count    (pixel_count),
        .counter_enable (counter_enable),
        .counter_clear  (counter_clear),
        .alerta_vazio   (alerta_vazio)
    );

endmodule
