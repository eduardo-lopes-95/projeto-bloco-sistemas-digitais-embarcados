`timescale 1ns/1ps
// Replays packets produced by the actual Assembly client under QEMU.
module tb_assembly_replay;
    reg clk=0, rst=0, sclk=0, cs=1, mosi=0;
    wire miso, alert, valid;
    always #18.5 clk=~clk;
    spi_image_top dut(clk,rst,sclk,cs,mosi,miso,alert,valid);
    reg [7:0] data[0:19629]; // 19200 pixels + BEGIN payload 16 + 23*18 headers/CRC
    reg [7:0] answer[0:36];
    reg [7:0] dummy;
    reg [15:0] crc;
    integer pos=0, size, i, count=0;
    reg [1023:0] file_name;
    function [15:0] update_crc;
        input [15:0] c0; input [7:0] b;
        reg [15:0] c; integer t;
        begin
            c=c0^{b,8'd0};
            for(t=0;t<8;t=t+1) c=c[15] ? (c<<1)^16'h1021 : c<<1;
            update_crc=c;
        end
    endfunction
    task transfer;
        input [7:0] b; output [7:0] r;
        integer t;
        begin
            for(t=7;t>=0;t=t-1) begin
                mosi=b[t]; #600; sclk=1; #100; r[t]=miso; #500; sclk=0;
            end
            #600;
        end
    endtask
    initial begin
        if(!$value$plusargs("FILE=%s",file_name)) $fatal(1,"pass +FILE=assembly_commands.hex");
        $readmemh(file_name,data);
        #100; rst=1; #1200;
        while(pos<19630) begin
            size=18+{data[pos+11],data[pos+10]};
            cs=0; #1200;
            for(i=0;i<size;i=i+1) transfer(data[pos+i],dummy);
            cs=1; #150000;
            cs=0; #1200; transfer(8'hf0,answer[0]);
            for(i=1;i<37;i=i+1) transfer(0,answer[i]);
            cs=1; #1200;
            crc=16'hffff;
            for(i=5;i<35;i=i+1) crc=update_crc(crc,answer[i]);
            if({answer[36],answer[35]}!==crc || answer[15]!==0 ||
                answer[8]!==data[pos+3] || answer[13]!==count)
                $fatal(1,"Assembly packet %0d not accepted",count);
            pos=pos+size; count=count+1;
        end
        if(!valid || !alert || answer[16]!=1 || answer[17]!=1 ||
           {answer[24],answer[23],answer[22],answer[21]}!=19200 ||
           {answer[28],answer[27],answer[26],answer[25]}!=9601)
            $fatal(1,"full frame majority/result mismatch");
        $display("PASS: Assembly -> SPI RTL: 23 packets, 19200 pixels, 9601 bright -> empty");
        $finish;
    end
    initial begin #1000000000; $fatal(1,"watchdog"); end
endmodule
