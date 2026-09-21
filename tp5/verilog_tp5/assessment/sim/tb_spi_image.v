`timescale 1ns/1ps
module tb_spi_image;
    parameter HALF_PERIOD_NS=600;
    reg clk=0, rst=0, sclk=0, cs=1, mosi=0;
    wire miso, alert, valid;
    always #18.5 clk=~clk;
    spi_image_top #(.WIDTH(4),.HEIGHT(2)) dut(clk,rst,sclk,cs,mosi,miso,alert,valid);
    reg [7:0] pkt[0:1050], answer[0:36];
    reg [15:0] crc;
    integer n,j,k,checks=0;
    reg [7:0] received;
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
                mosi=b[t]; #(HALF_PERIOD_NS); sclk=1; #100; r[t]=miso;
                #(HALF_PERIOD_NS-100); sclk=0;
            end
            #600;
        end
    endtask
    task header;
        input [7:0] op; input [15:0] seq, len; input [31:0] off;
        integer t;
        begin
            for(t=0;t<1051;t=t+1) pkt[t]=0;
            pkt[0]=8'h42; pkt[1]=8'h57; pkt[2]=1; pkt[3]=op;
            pkt[4]=7; pkt[8]=seq[7:0]; pkt[9]=seq[15:8];
            pkt[10]=len[7:0]; pkt[11]=len[15:8];
            for(t=0;t<4;t=t+1) pkt[12+t]=(off>>(8*t));
            n=16+len;
        end
    endtask
    task send;
        input corrupt;
        integer t;
        begin
            crc=16'hffff;
            for(t=0;t<n;t=t+1) crc=update_crc(crc,pkt[t]);
            pkt[n]=crc[7:0]^corrupt; pkt[n+1]=crc[15:8];
            cs=0; #1200;
            for(t=0;t<n+2;t=t+1) transfer(pkt[t],received);
            cs=1; #120000;
        end
    endtask
    task read_response;
        integer t;
        begin
            cs=0; #1200;
            transfer(8'hf0,answer[0]);
            for(t=1;t<37;t=t+1) transfer(0,answer[t]);
            cs=1; #1200;
            crc=16'hffff;
            for(t=5;t<35;t=t+1) crc=update_crc(crc,answer[t]);
            if(answer[5]!==8'h42 || answer[6]!==8'h52 ||
               {answer[36],answer[35]}!==crc) $fatal(1,"response framing/CRC");
            checks=checks+1;
        end
    endtask
    task begin_frame;
        begin
            header(8'h10,1,16,0);
            pkt[16]=4; pkt[18]=2; pkt[20]=1; pkt[22]=100; pkt[28]=8;
            send(0); read_response;
            if(answer[15]!=0) $fatal(1,"BEGIN rejected");
        end
    endtask
    task classify;
        input integer bright_count; input [1:0] expected;
        integer t;
        begin
            begin_frame;
            header(8'h11,2,8,0);
            for(t=0;t<8;t=t+1) pkt[16+t]=(t<bright_count)?101:100;
            send(0); read_response;
            if(answer[15]!=0 || answer[29]!=8) $fatal(1,"block ACK");
            header(8'h12,3,0,0); send(0); read_response;
            if(answer[15]!=0 || answer[16]!=1 || answer[17]!=expected ||
               answer[21]!=8 || answer[25]!=bright_count) $fatal(1,"classification");
            header(8'h13,4,0,0); send(0); read_response;
            if(answer[17]!=expected || !valid) $fatal(1,"GET_RESULT");
        end
    endtask
    initial begin
        #100; rst=1; #1000;
        crc=16'hffff;
        crc=update_crc(crc,"1"); crc=update_crc(crc,"2"); crc=update_crc(crc,"3");
        crc=update_crc(crc,"4"); crc=update_crc(crc,"5"); crc=update_crc(crc,"6");
        crc=update_crc(crc,"7"); crc=update_crc(crc,"8"); crc=update_crc(crc,"9");
        if(crc!=16'h29b1) $fatal(1,"CRC known vector");
        header(1,0,0,0); send(0); read_response;
        if(answer[21]!=8'h4c || answer[22]!=8'h57 || answer[15]!=0) $fatal(1,"GET_INFO");
        classify(5,1); classify(4,2); classify(3,0); classify(8,1);
        begin_frame;
        if(!alert) $fatal(1,"previous classification not persistent");
        header(8'h11,2,8,0); send(1); read_response;
        if(answer[15]!=2 || answer[33]!=2 || valid) $fatal(1,"bad CRC accepted");
        begin_frame;
        header(8'h12,2,0,0); send(0); read_response;
        if(answer[15]!=2 || valid) $fatal(1,"short frame accepted");
        begin_frame;
        header(8'h11,2,4,0); send(0); read_response;
        send(0); read_response;
        if(answer[15]!=2 || valid) $fatal(1,"duplicate block accepted");
        header(8'h14,0,0,0); send(0); read_response;
        if(valid) $fatal(1,"ABORT retains validity");
        cs=0; #1200; transfer(8'h42,received); cs=1; #120000;
        read_response;
        if(answer[15]!=2) $fatal(1,"truncated command accepted");
        // Even one partial byte must abort a transaction, including after a valid packet.
        cs=0; #1200; mosi=1; #600; sclk=1; #600; sclk=0; #600; cs=1; #120000;
        read_response;
        if(answer[15]!=2 || valid) $fatal(1,"partial byte accepted");
        begin_frame;
        header(8'h11,2,9,0); send(0); read_response;
        if(answer[15]!=2 || valid) $fatal(1,"too many pixels accepted");
        begin_frame;
        header(8'h11,2,8,1); send(0); read_response;
        if(answer[15]!=2 || valid) $fatal(1,"wrong offset accepted");
        $display("PASS: %0d CRC-checked SPI responses; majority, tie, persistence and errors",checks);
        $finish;
    end
    initial begin #1000000000; $fatal(1,"watchdog"); end
endmodule
