`timescale 1ns/1ps
// Oversampled mode 0, MSB first. Initial hardware target: 100 kHz.
// CS setup/hold >= 8 system cycles; each SCLK half-period >= 8 cycles.
// MISO is disabled immediately by physical CS. No claim of glitch filtering.
module spi_slave_mode0(
    input wire clk, rst_n, sclk, cs_n, mosi,
    input wire [7:0] tx_byte,
    output wire miso,
    output reg rx_valid, selected, deselected,
    output reg partial_byte,
    output reg [7:0] rx_byte,
    output reg [15:0] byte_index
);
    reg [2:0] sck_sync, cs_sync, mosi_sync;
    reg [2:0] bit_index;
    reg [7:0] rx_shift;
    reg miso_r;
    wire rise = sck_sync[2:1] == 2'b01;
    wire fall = sck_sync[2:1] == 2'b10;
    assign miso = cs_n ? 1'bz : miso_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sck_sync <= 0; cs_sync <= 7; mosi_sync <= 0;
            rx_valid <= 0; selected <= 0; deselected <= 0; partial_byte <= 0;
            rx_byte <= 0; byte_index <= 0; bit_index <= 0;
            rx_shift <= 0; miso_r <= 0;
        end else begin
            sck_sync <= {sck_sync[1:0],sclk};
            cs_sync <= {cs_sync[1:0],cs_n};
            mosi_sync <= {mosi_sync[1:0],mosi};
            rx_valid <= 0; selected <= 0; deselected <= 0;
            if (cs_sync[2:1] == 2'b10) begin
                selected <= 1; byte_index <= 0; bit_index <= 0;
                rx_shift <= 0; miso_r <= tx_byte[7];
            end else if (cs_sync[2:1] == 2'b01) begin
                deselected <= 1;
                partial_byte <= (bit_index != 0);
            end else if (!cs_sync[2]) begin
                if (rise) begin
                    rx_shift <= {rx_shift[6:0],mosi_sync[2]};
                    if (bit_index == 7) begin
                        rx_byte <= {rx_shift[6:0],mosi_sync[2]};
                        rx_valid <= 1; bit_index <= 0;
                        if (byte_index != 16'hffff) byte_index <= byte_index+1;
                    end else bit_index <= bit_index+1;
                end
                if (fall) miso_r <= tx_byte[7-bit_index];
            end
        end
    end
endmodule
