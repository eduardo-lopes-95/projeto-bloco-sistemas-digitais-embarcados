`timescale 1ns/1ps
// Focused testbench for the project goal: deciding whether the feed bowl is EMPTY.
//
// bowl_state semantics (see gray_bowl_detector.v):
//   0 = not_empty   (bright pixels are the minority)
//   1 = empty       (bright pixels are the majority)  <-- the alert condition
//   2 = tie/unknown (bright == dark)
//
// This bench is self-contained: it drives the SPI slave directly and does NOT
// depend on any externally generated *.hex file, closing the gap where
// tb_assembly_replay is silently skipped when assembly_commands.hex is absent.
//
// It exercises, on top of what tb_spi_image already covers:
//   - EMPTY decided by the smallest possible margin (majority by a single pixel)
//   - NOT_EMPTY decided by the smallest possible margin
//   - a genuine MULTI-BLOCK frame (pixels split across several 0x11 commands)
//     so the empty verdict is validated across block boundaries and offsets.
module tb_bowl_empty;
    parameter HALF_PERIOD_NS = 600;

    // Small even frame so majority/minority margins are exact and easy to reason
    // about: WIDTH*HEIGHT = 24 pixels total.
    localparam WIDTH  = 6;
    localparam HEIGHT = 4;
    localparam TOTAL  = WIDTH*HEIGHT; // 24

    reg clk=0, rst=0, sclk=0, cs=1, mosi=0;
    wire miso, alert, valid;
    always #18.5 clk=~clk;

    spi_image_top #(.WIDTH(WIDTH),.HEIGHT(HEIGHT))
        dut(clk,rst,sclk,cs,mosi,miso,alert,valid);

    // Waveform dump for GTKWave. Pass +NODUMP to disable.
    initial begin
        if (!$test$plusargs("NODUMP")) begin
            $dumpfile("build/tb_bowl_empty.vcd");
            $dumpvars(0, tb_bowl_empty);
        end
    end

    reg [7:0] pkt[0:1050], answer[0:36];
    reg [15:0] crc;
    integer n, t, checks=0;
    reg [7:0] received;

    localparam [7:0] DARK  = 8'd100; // == threshold, NOT counted as bright
    localparam [7:0] LIGHT = 8'd200; // >  threshold, counted as bright

    function [15:0] update_crc;
        input [15:0] c0; input [7:0] b;
        reg [15:0] c; integer k;
        begin
            c=c0^{b,8'd0};
            for(k=0;k<8;k=k+1) c=c[15] ? (c<<1)^16'h1021 : c<<1;
            update_crc=c;
        end
    endfunction

    task transfer;
        input [7:0] b; output [7:0] r;
        integer k;
        begin
            for(k=7;k>=0;k=k-1) begin
                mosi=b[k]; #(HALF_PERIOD_NS); sclk=1; #100; r[k]=miso;
                #(HALF_PERIOD_NS-100); sclk=0;
            end
            #600;
        end
    endtask

    task header;
        input [7:0] op; input [15:0] seq, len; input [31:0] off;
        integer k;
        begin
            for(k=0;k<1051;k=k+1) pkt[k]=0;
            pkt[0]=8'h42; pkt[1]=8'h57; pkt[2]=1; pkt[3]=op;
            pkt[4]=7; pkt[8]=seq[7:0]; pkt[9]=seq[15:8];
            pkt[10]=len[7:0]; pkt[11]=len[15:8];
            for(k=0;k<4;k=k+1) pkt[12+k]=(off>>(8*k));
            n=16+len;
        end
    endtask

    task send;
        integer k;
        begin
            crc=16'hffff;
            for(k=0;k<n;k=k+1) crc=update_crc(crc,pkt[k]);
            pkt[n]=crc[7:0]; pkt[n+1]=crc[15:8];
            cs=0; #1200;
            for(k=0;k<n+2;k=k+1) transfer(pkt[k],received);
            cs=1; #120000;
        end
    endtask

    task read_response;
        integer k;
        begin
            cs=0; #1200;
            transfer(8'hf0,answer[0]);
            for(k=1;k<37;k=k+1) transfer(0,answer[k]);
            cs=1; #1200;
            crc=16'hffff;
            for(k=5;k<35;k=k+1) crc=update_crc(crc,answer[k]);
            if(answer[5]!==8'h42 || answer[6]!==8'h52 ||
               {answer[36],answer[35]}!==crc) $fatal(1,"response framing/CRC");
            checks=checks+1;
        end
    endtask

    task begin_frame;
        begin
            // frame_id is fixed (header() sets pkt[4]=7) and shared by BEGIN/BLOCK/END,
            // matching how the RTL binds current_id at BEGIN and checks it per block.
            // BEGIN payload: width, height, format=1, threshold=100, total=WIDTH*HEIGHT
            header(8'h10,1,16,0);
            pkt[16]=WIDTH[7:0];  pkt[17]=WIDTH[15:8];
            pkt[18]=HEIGHT[7:0]; pkt[19]=HEIGHT[15:8];
            pkt[20]=1;                 // format GRAY8
            pkt[22]=8'd100;            // threshold
            pkt[28]=TOTAL[7:0]; pkt[29]=TOTAL[15:8];
            send; read_response;
            if(answer[15]!=0) $fatal(1,"BEGIN rejected");
        end
    endtask

    // Send the whole frame as ONE block with `bright_count` light pixels,
    // then END + GET_RESULT and check the empty/not_empty verdict.
    task run_single_block;
        input integer bright_count;
        input [1:0] expected_state; // 0 not_empty, 1 empty, 2 tie
        begin
            begin_frame;
            header(8'h11,2,TOTAL,0);
            for(t=0;t<TOTAL;t=t+1) pkt[16+t]=(t<bright_count)?LIGHT:DARK;
            send; read_response;
            if(answer[15]!=0 || answer[29]!=TOTAL) $fatal(1,"single-block ACK/offset");
            header(8'h12,3,0,0); send; read_response;
            // answer[] keeps the 5-byte read prefix, so envelope byte X is at answer[5+X]:
            //   status  = envelope[10] = answer[15]
            //   state   = envelope[12] = answer[17]
            //   n (low) = envelope[16] = answer[21]
            if(answer[15]!=0) $fatal(1,"END rejected");
            if(answer[17]!=expected_state)
                $fatal(1,"state mismatch: got %0d expected %0d",answer[17],expected_state);
            // pixels_total echoed little-endian in field n (envelope 16..19 = answer 21..24).
            if({answer[24],answer[23],answer[22],answer[21]}!=TOTAL)
                $fatal(1,"pixels_total mismatch: got %0d expected %0d",
                       {answer[24],answer[23],answer[22],answer[21]},TOTAL);
            header(8'h13,4,0,0); send; read_response;
            if(!valid || answer[17]!=expected_state) $fatal(1,"GET_RESULT verdict");
            // O_alert must be high ONLY when the bowl is empty (state 1).
            if(expected_state==1 && !alert) $fatal(1,"alert not asserted on EMPTY");
            if(expected_state!=1 && alert)  $fatal(1,"alert asserted when NOT empty");
        end
    endtask

    // Send the frame split into several blocks to exercise offsets/sequence,
    // with `bright_count` light pixels placed at the very start of the frame.
    task run_multi_block;
        input integer bright_count;
        input [1:0] expected_state;
        integer sent, blk, seq, k, gidx;
        begin
            begin_frame;
            sent=0; seq=2;
            while(sent<TOTAL) begin
                blk=(TOTAL-sent>=8)?8:(TOTAL-sent); // 8-pixel blocks (last smaller)
                header(8'h11,seq[15:0],blk,sent);
                for(k=0;k<blk;k=k+1) begin
                    gidx=sent+k;
                    pkt[16+k]=(gidx<bright_count)?LIGHT:DARK;
                end
                send; read_response;
                if(answer[15]!=0 || answer[29]!=(sent+blk))
                    $fatal(1,"multi-block ACK/offset at sent=%0d",sent);
                sent=sent+blk; seq=seq+1;
            end
            header(8'h12,seq[15:0],0,0); send; read_response;
            if(answer[15]!=0) $fatal(1,"multi-block END rejected");
            if(answer[17]!=expected_state)
                $fatal(1,"multi-block verdict mismatch: got %0d expected %0d",
                       answer[17],expected_state);
            if(expected_state==1 && !alert) $fatal(1,"multi-block alert not asserted on EMPTY");
            if(expected_state!=1 && alert)  $fatal(1,"multi-block alert on NOT empty");
        end
    endtask

    initial begin
        #100; rst=1; #1000;

        // Sanity: GET_INFO answers before any frame.
        header(1,0,0,0); send; read_response;
        if(answer[15]!=0) $fatal(1,"GET_INFO");

        // --- Single-block empty/not_empty margin cases (TOTAL=24) ---
        // 13 light vs 11 dark -> majority light by 1 -> EMPTY.
        run_single_block(13, 1);
        // 11 light vs 13 dark -> minority light -> NOT_EMPTY.
        run_single_block(11, 0);
        // 12 vs 12 -> tie -> unknown.
        run_single_block(12, 2);
        // all light -> EMPTY (extreme).
        run_single_block(24, 1);
        // all dark -> NOT_EMPTY (extreme).
        run_single_block(0, 0);

        // --- Multi-block frames (blocks of 8 pixels: 8+8+8) ---
        // 13 light -> EMPTY across three blocks.
        run_multi_block(13, 1);
        // 12 light -> tie across three blocks.
        run_multi_block(12, 2);
        // 5 light -> NOT_EMPTY across three blocks.
        run_multi_block(5, 0);

        $display("PASS: %0d CRC-checked responses; EMPTY/NOT_EMPTY/tie by 1-pixel margin, extremes, single- and multi-block",checks);
        $finish;
    end

    initial begin #2000000000; $fatal(1,"watchdog"); end
endmodule
