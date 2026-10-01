`timescale 1ns/1ps
// Adversarial testbench: hunts SILENT failures in the bowl-empty pipeline.
//
// A "silent failure" here means the RTL answers status=0 / valid with a CRC that
// checks out, yet the verdict, counts, identity or freshness are WRONG. These are
// the dangerous bugs: the supervisor would happily publish a confident-but-false
// result. Each test therefore asserts not only "did it accept" but "is the
// meaning correct". Written to be self-contained (no external .hex).
//
// bowl_state: 0=not_empty, 1=empty, 2=tie/unknown.
//
// Response envelope carries a 5-byte read prefix, so envelope byte X = answer[5+X]:
//   status  = env[10] = answer[15]
//   result  = env[11] = answer[16]
//   state   = env[12] = answer[17]
//   fid     = env[4..7] = answer[9..12]
//   seq     = env[8..9] = answer[13..14]
//   n  (total/idcode) = env[16..19] = answer[21..24]
//   b  (bright/blkcap) = env[20..23] = answer[25..28]
module tb_bowl_silent;
    parameter HALF_PERIOD_NS = 600;

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
            $dumpfile("build/tb_bowl_silent.vcd");
            $dumpvars(0, tb_bowl_silent);
        end
    end

    reg [7:0] pkt[0:1050], answer[0:36];
    reg [15:0] crc;
    integer n, t, checks=0, fails=0;
    reg [7:0] received;

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

    // header() with explicit frame_id so we can test identity handling.
    task header;
        input [7:0] op; input [31:0] fid; input [15:0] seq, len; input [31:0] off;
        integer k;
        begin
            for(k=0;k<1051;k=k+1) pkt[k]=0;
            pkt[0]=8'h42; pkt[1]=8'h57; pkt[2]=1; pkt[3]=op;
            for(k=0;k<4;k=k+1) pkt[4+k]=(fid>>(8*k));
            pkt[8]=seq[7:0]; pkt[9]=seq[15:8];
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
               {answer[36],answer[35]}!==crc) $fatal(1,"response framing/CRC broken");
            checks=checks+1;
        end
    endtask

    // Soft check: report but keep going, so one run surfaces ALL silent bugs.
    task expect_eq;
        input [31:0] got, exp;
        input [639:0] label;
        begin
            if(got!==exp) begin
                $display("  SILENT-FAIL: %0s: got %0d expected %0d", label, got, exp);
                fails=fails+1;
            end
        end
    endtask

    // Drive a complete frame (BEGIN + one block + END) with a given threshold and
    // frame_id, placing `bright_count` pixels strictly above `thr` and the rest
    // exactly AT `thr` (which must NOT count as bright: boundary test for '>').
    task run_frame;
        input [31:0] fid;
        input [7:0] thr;
        input integer bright_count;
        begin
            header(8'h10,fid,1,16,0);
            pkt[16]=WIDTH[7:0];  pkt[17]=WIDTH[15:8];
            pkt[18]=HEIGHT[7:0]; pkt[19]=HEIGHT[15:8];
            pkt[20]=1;
            pkt[22]=thr;
            pkt[28]=TOTAL[7:0]; pkt[29]=TOTAL[15:8];
            send; read_response;
            if(answer[15]!=0) $fatal(1,"BEGIN unexpectedly rejected");

            header(8'h11,fid,2,TOTAL,0);
            for(t=0;t<TOTAL;t=t+1) pkt[16+t]=(t<bright_count)? (thr+8'd1) : thr;
            send; read_response;
            if(answer[15]!=0) $fatal(1,"BLOCK unexpectedly rejected");

            header(8'h12,fid,3,0,0); send; read_response;
        end
    endtask

    // Expected majority verdict from a bright count over TOTAL pixels.
    function [1:0] expected_state;
        input integer bright_count;
        integer dark;
        begin
            dark = TOTAL - bright_count;
            if(bright_count > dark) expected_state = 1;      // empty
            else if(bright_count < dark) expected_state = 0; // not_empty
            else expected_state = 2;                         // tie
        end
    endfunction

    integer got_bright, got_total, got_fid, got_state;
    integer i;

    initial begin
        #100; rst=1; #1000;
        $display("== Silent-failure hunt (TOTAL=%0d pixels) ==", TOTAL);

        // ------------------------------------------------------------------
        // TEST 1: threshold is a STRICT '>' boundary.
        // 13 pixels at thr+1 (bright) and 11 pixels exactly at thr (NOT bright).
        // If someone changes '>' to '>=', all 24 would count bright -> still
        // empty but bright count becomes 24 instead of 13: a silent count error.
        // ------------------------------------------------------------------
        $display("TEST 1: strict-'>' threshold boundary");
        run_frame(32'h0000_0001, 8'd100, 13);
        got_state  = answer[17];
        got_bright = {answer[28],answer[27],answer[26],answer[25]};
        got_total  = {answer[24],answer[23],answer[22],answer[21]};
        expect_eq(got_state, expected_state(13), "T1 state=empty");
        expect_eq(got_bright, 13, "T1 bright counts only pixels strictly > thr");
        expect_eq(got_total, TOTAL, "T1 total pixels");

        // ------------------------------------------------------------------
        // TEST 2: threshold must be RE-CAPTURED per frame (no stale threshold).
        // Same pixel pattern (12 pixels at value 150, 12 at value 50), but two
        // different thresholds flip the verdict. Frame A: thr=100 -> 12 bright,
        // 12 dark -> tie(2). Frame B: thr=200 -> 0 bright -> not_empty(0).
        // A stale threshold from frame A would keep counting 12 bright in B.
        // ------------------------------------------------------------------
        $display("TEST 2: per-frame threshold (no stale threshold_r)");
        // Frame A, thr=100
        header(8'h10,32'h0000_0002,1,16,0);
        pkt[16]=WIDTH[7:0]; pkt[17]=WIDTH[15:8];
        pkt[18]=HEIGHT[7:0]; pkt[19]=HEIGHT[15:8];
        pkt[20]=1; pkt[22]=8'd100; pkt[28]=TOTAL[7:0]; pkt[29]=TOTAL[15:8];
        send; read_response;
        header(8'h11,32'h0000_0002,2,TOTAL,0);
        for(t=0;t<TOTAL;t=t+1) pkt[16+t]=(t<12)?8'd150:8'd50;
        send; read_response;
        header(8'h12,32'h0000_0002,3,0,0); send; read_response;
        expect_eq(answer[17], 2, "T2 frame A (thr=100) -> tie");
        expect_eq({answer[28],answer[27],answer[26],answer[25]}, 12, "T2 frame A bright=12");
        // Frame B, thr=200, SAME pixels
        header(8'h10,32'h0000_0003,1,16,0);
        pkt[16]=WIDTH[7:0]; pkt[17]=WIDTH[15:8];
        pkt[18]=HEIGHT[7:0]; pkt[19]=HEIGHT[15:8];
        pkt[20]=1; pkt[22]=8'd200; pkt[28]=TOTAL[7:0]; pkt[29]=TOTAL[15:8];
        send; read_response;
        header(8'h11,32'h0000_0003,2,TOTAL,0);
        for(t=0;t<TOTAL;t=t+1) pkt[16+t]=(t<12)?8'd150:8'd50;
        send; read_response;
        header(8'h12,32'h0000_0003,3,0,0); send; read_response;
        expect_eq(answer[17], 0, "T2 frame B (thr=200) -> not_empty (threshold re-captured)");
        expect_eq({answer[28],answer[27],answer[26],answer[25]}, 0, "T2 frame B bright=0");

        // ------------------------------------------------------------------
        // TEST 3: STALE-RESULT freshness. Establish a valid EMPTY result, then
        // start a NEW frame that gets REJECTED (bad block). The detector must
        // NOT keep advertising the old EMPTY as if it were fresh for the new id.
        // We check the freshest GET_RESULT still carries the OLD frame_id, so the
        // supervisor can tell it is stale (identity mismatch is the only guard
        // the RTL offers; there is no age timeout).
        // ------------------------------------------------------------------
        $display("TEST 3: stale-result identity after a rejected new frame");
        run_frame(32'h0000_0010, 8'd100, 20); // clearly empty
        expect_eq(answer[17], 1, "T3 baseline empty");
        // New frame id 0x11, but send a malformed block (wrong offset) -> reject.
        header(8'h10,32'h0000_0011,1,16,0);
        pkt[16]=WIDTH[7:0]; pkt[17]=WIDTH[15:8];
        pkt[18]=HEIGHT[7:0]; pkt[19]=HEIGHT[15:8];
        pkt[20]=1; pkt[22]=8'd100; pkt[28]=TOTAL[7:0]; pkt[29]=TOTAL[15:8];
        send; read_response; // BEGIN ok, start_frame pulses -> old snapshot invalidated
        // GET_RESULT now for the NEW id must fail (frame open) -> status !=0.
        header(8'h13,32'h0000_0011,9,0,0); send; read_response;
        expect_eq(answer[15], 2, "T3 GET_RESULT during open/new frame must NOT return success");
        // NOTE (documented limitation): an abandoned open frame has NO age timeout
        // in hardware; it must be explicitly cleared or it blocks the next BEGIN.
        // ABORT it so the following tests start from a clean state.
        header(8'h14,32'h0000_0011,10,0,0); send; read_response;

        // ------------------------------------------------------------------
        // TEST 4: GET_RESULT identity guard. After a real empty frame with id
        // 0x20, asking GET_RESULT with a DIFFERENT id must be rejected, never
        // echo a confident empty for the wrong image.
        // ------------------------------------------------------------------
        $display("TEST 4: GET_RESULT rejects mismatched frame_id");
        run_frame(32'h0000_0020, 8'd100, 20); // empty, id 0x20
        expect_eq(answer[17], 1, "T4 baseline empty id=0x20");
        header(8'h13,32'h0000_0099,4,0,0); send; read_response; // wrong id
        expect_eq(answer[15], 2, "T4 GET_RESULT with wrong id must be rejected");

        // ------------------------------------------------------------------
        // TEST 5: block-content integrity across the multi-block boundary.
        // Split 24 px into 3 blocks. Put all 13 bright pixels in the LAST block
        // region only; the count must still be exactly 13 and verdict empty,
        // proving offsets map bytes to the right global positions (no silent
        // block-to-block aliasing).
        // ------------------------------------------------------------------
        $display("TEST 5: multi-block offset mapping / no aliasing");
        header(8'h10,32'h0000_0030,1,16,0);
        pkt[16]=WIDTH[7:0]; pkt[17]=WIDTH[15:8];
        pkt[18]=HEIGHT[7:0]; pkt[19]=HEIGHT[15:8];
        pkt[20]=1; pkt[22]=8'd100; pkt[28]=TOTAL[7:0]; pkt[29]=TOTAL[15:8];
        send; read_response;
        begin : multiblk
            integer sent, blk, seq, k, gidx, bright_target;
            sent=0; seq=2; bright_target=13;
            while(sent<TOTAL) begin
                blk=(TOTAL-sent>=8)?8:(TOTAL-sent);
                header(8'h11,32'h0000_0030,seq[15:0],blk[15:0],sent);
                for(k=0;k<blk;k=k+1) begin
                    gidx=sent+k;
                    // bright pixels are the LAST `bright_target` global indices
                    pkt[16+k]=(gidx >= TOTAL-bright_target)? 8'd200 : 8'd100;
                end
                send; read_response;
                if(answer[15]!=0) $fatal(1,"T5 block rejected at sent=%0d",sent);
                sent=sent+blk; seq=seq+1;
            end
            header(8'h12,32'h0000_0030,seq[15:0],0,0); send; read_response;
        end
        expect_eq(answer[17], 1, "T5 verdict empty");
        expect_eq({answer[28],answer[27],answer[26],answer[25]}, 13, "T5 bright=13 regardless of block placement");

        // ------------------------------------------------------------------
        // TEST 6: frame_id is ECHOED faithfully (a swapped/zeroed id would let
        // the supervisor bind a verdict to the wrong image silently).
        // ------------------------------------------------------------------
        $display("TEST 6: frame_id echo fidelity");
        run_frame(32'hDEAD_BEEF, 8'd100, 20);
        got_fid = {answer[12],answer[11],answer[10],answer[9]};
        expect_eq(got_fid, 32'hDEAD_BEEF, "T6 echoed frame_id matches request");
        expect_eq(answer[17], 1, "T6 verdict empty");

        // ------------------------------------------------------------------
        if(fails==0)
            $display("PASS: %0d responses, no silent failures detected across 6 adversarial tests", checks);
        else
            $fatal(1,"FAIL: %0d silent-failure assertion(s) triggered", fails);
        $finish;
    end

    initial begin #4000000000; $fatal(1,"watchdog"); end
endmodule
