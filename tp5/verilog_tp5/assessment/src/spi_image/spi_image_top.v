`timescale 1ns/1ps
module spi_image_top #(
    parameter WIDTH=160, HEIGHT=120
)(
    input wire I_clk, I_rst_n,
    input wire I_spi_sclk, I_spi_cs_n, I_spi_mosi,
    output wire O_spi_miso,
    output wire O_alert, O_result_valid
);
    localparam IDLE=0, DISPATCH=1, READ_PIXEL=2, LOAD_PIXEL=3, EMIT_PIXEL=4,
               FINISH_BLOCK=5, FINISH_FRAME=6, WAIT_FRAME=7, REPLY_CRC=8;
    reg [3:0] state;
    wire rx_valid, selected, deselected, partial_byte;
    wire [7:0] rx_byte;
    wire [15:0] byte_index;
    // Response bytes kept as small byte arrays (32 B each) instead of 256-bit
    // vectors with variable part-selects, which synthesize as large muxes.
    reg [7:0] resp_mem[0:31], snap_mem[0:31], draft_mem[0:31];
    wire [7:0] tx_byte = (read_reply && byte_index>=5 && byte_index<37)
                          ? snap_mem[byte_index-5] : 8'd0;
    spi_slave_mode0 spi(I_clk,I_rst_n,I_spi_sclk,I_spi_cs_n,I_spi_mosi,
                       tx_byte,O_spi_miso,rx_valid,selected,deselected,partial_byte,
                       rx_byte,byte_index);
    reg [7:0] header[0:15];
    // BEGIN payload header (16 B) captured separately so the big payload RAM
    // never needs combinational multi-address reads (keeps BSRAM inference).
    reg [7:0] bhdr[0:15];
    // Frame pixel buffer: single synchronous write + single synchronous read
    // with a registered address -> inferred as BSRAM on Gowin, not registers.
    reg [7:0] payload[0:1023];
    reg [7:0] payload_rd;
    reg [15:0] count, payload_len, rx_crc, received_crc;
    reg read_reply, malformed, ignore_command;
    reg [31:0] current_id, offset;
    reg [15:0] last_seq, cursor;
    reg frame_open;
    reg [7:0] threshold, buffered_pixel;
    reg start_frame, abort_frame, end_frame, pixel_valid;
    wire active, valid, detector_error;
    wire [1:0] bowl;
    wire [31:0] result_id, total, bright;
    wire [31:0] cmd_id={header[7],header[6],header[5],header[4]};
    wire [15:0] cmd_seq={header[9],header[8]};
    wire [31:0] cmd_offset={header[15],header[14],header[13],header[12]};
    reg [5:0] crc_index;
    reg [15:0] reply_crc;
    integer i;

    function [15:0] crc_byte;
        input [15:0] crc;
        input [7:0] data;
        reg [15:0] c;
        integer k;
        begin
            c=crc ^ {data,8'd0};
            for(k=0;k<8;k=k+1)
                c=c[15] ? (c<<1)^16'h1021 : c<<1;
            crc_byte=c;
        end
    endfunction

    gray_bowl_detector #(.EXPECTED_PIXELS(WIDTH*HEIGHT)) detector(
        I_clk,I_rst_n,start_frame,abort_frame,end_frame,pixel_valid,
        buffered_pixel,threshold,current_id,active,valid,detector_error,
        bowl,result_id,total,bright);
    assign O_alert=valid && bowl==1;
    assign O_result_valid=valid;

    task reply;
        input [7:0] status;
        input [15:0] err;
        input is_result;
        input [31:0] n, b, next_offset;
        integer t;
        begin
            for(t=0;t<32;t=t+1) draft_mem[t]<=0;
            draft_mem[0]<=8'h42; draft_mem[1]<=8'h52; draft_mem[2]<=1;
            draft_mem[3]<=header[3];
            draft_mem[4]<=cmd_id[7:0];   draft_mem[5]<=cmd_id[15:8];
            draft_mem[6]<=cmd_id[23:16]; draft_mem[7]<=cmd_id[31:24];
            draft_mem[8]<=cmd_seq[7:0];  draft_mem[9]<=cmd_seq[15:8];
            draft_mem[10]<=status;
            draft_mem[11]<={7'd0,is_result};
            draft_mem[12]<=is_result ? {6'd0,bowl} : 8'd2;
            draft_mem[16]<=n[7:0];   draft_mem[17]<=n[15:8];
            draft_mem[18]<=n[23:16]; draft_mem[19]<=n[31:24];
            draft_mem[20]<=b[7:0];   draft_mem[21]<=b[15:8];
            draft_mem[22]<=b[23:16]; draft_mem[23]<=b[31:24];
            draft_mem[24]<=next_offset[7:0];   draft_mem[25]<=next_offset[15:8];
            draft_mem[26]<=next_offset[23:16]; draft_mem[27]<=next_offset[31:24];
            draft_mem[28]<=err[7:0]; draft_mem[29]<=err[15:8];
            reply_crc<=16'hffff; crc_index<=0; state<=REPLY_CRC;
        end
    endtask
    task reject;
        input [15:0] err;
        begin
            frame_open<=0; abort_frame<=1;
            reply(2,err,0,0,0,offset);
        end
    endtask

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            state<=IDLE;
            count<=0; payload_len<=0; rx_crc<=16'hffff;
            received_crc<=0; read_reply<=0; malformed<=0; ignore_command<=0;
            current_id<=0; offset<=0; last_seq<=0; cursor<=0;
            frame_open<=0; threshold<=0; buffered_pixel<=0;
            start_frame<=0; abort_frame<=0; end_frame<=0; pixel_valid<=0;
            reply_crc<=16'hffff; crc_index<=0; payload_rd<=0;
            for(i=0;i<16;i=i+1) begin header[i]<=0; bhdr[i]<=0; end
            for(i=0;i<32;i=i+1) begin resp_mem[i]<=0; snap_mem[i]<=0; draft_mem[i]<=0; end
        end else begin
            start_frame<=0; abort_frame<=0; end_frame<=0; pixel_valid<=0;
            if(selected) begin
                count<=0; payload_len<=0; rx_crc<=16'hffff;
                received_crc<=0; read_reply<=0; malformed<=0;
                for(i=0;i<32;i=i+1) snap_mem[i]<=resp_mem[i];
                ignore_command<=(state!=IDLE);
            end
            if(rx_valid) begin
                if(count==0 && rx_byte==8'hf0) read_reply<=1;
                if(!read_reply && !(count==0 && rx_byte==8'hf0) && !ignore_command) begin
                    if(count<16) begin
                        header[count]<=rx_byte;
                        rx_crc<=crc_byte(rx_crc,rx_byte);
                        if(count==10) payload_len[7:0]<=rx_byte;
                        if(count==11) begin
                            payload_len[15:8]<=rx_byte;
                            if({rx_byte,payload_len[7:0]}>1024) malformed<=1;
                        end
                    end else if(count < 16+payload_len && count<1040) begin
                        payload[count-16]<=rx_byte;
                        // BEGIN header is 16 B; capture into a small array so the
                        // big payload RAM stays a clean single-read/single-write.
                        if(count-16 < 16) bhdr[count-16]<=rx_byte;
                        rx_crc<=crc_byte(rx_crc,rx_byte);
                    end else if(count==16+payload_len) received_crc[7:0]<=rx_byte;
                    else if(count==17+payload_len) received_crc[15:8]<=rx_byte;
                    else malformed<=1;
                end
                if(count!=16'hffff) count<=count+1;
                else malformed<=1;
            end
            if(deselected && !read_reply && !ignore_command && (count!=0 || partial_byte) && state==IDLE) begin
                if(partial_byte) malformed<=1;
                state<=DISPATCH;
            end

            // Synchronous read port for the pixel buffer (registered address).
            payload_rd<=payload[cursor];

            case(state)
                IDLE: begin end
                DISPATCH: begin
                    if(malformed || count!=18+payload_len || payload_len>1024 ||
                       header[0]!=8'h42 || header[1]!=8'h57 || header[2]!=1)
                        reject(1);
                    else if(rx_crc!=received_crc) reject(2);
                    else if(header[3]!=8'h11 && cmd_offset!=0) reject(3);
                    else case(header[3])
                        8'h01: if(payload_len!=0) reject(1);
                               else reply(0,0,0,32'h424f574c,1024,1);
                        8'h14: begin
                            if(payload_len!=0) reject(1);
                            else begin
                                frame_open<=0; offset<=0; abort_frame<=1;
                                reply(0,0,0,0,0,0);
                            end
                        end
                        8'h10: begin
                            if(frame_open || payload_len!=16 ||
                               {bhdr[1],bhdr[0]}!=WIDTH ||
                               {bhdr[3],bhdr[2]}!=HEIGHT || bhdr[4]!=1 ||
                               bhdr[5]!=0 || bhdr[7]!=0 || bhdr[8]!=0 ||
                               bhdr[9]!=0 || bhdr[10]!=0 || bhdr[11]!=0 ||
                               {bhdr[15],bhdr[14],bhdr[13],bhdr[12]}!=WIDTH*HEIGHT)
                                reject(3);
                            else begin
                                current_id<=cmd_id; last_seq<=cmd_seq; offset<=0;
                                threshold<=bhdr[6]; frame_open<=1; start_frame<=1;
                                reply(0,0,0,0,0,0);
                            end
                        end
                        8'h11: begin
                            if(!frame_open || cmd_id!=current_id || cmd_seq!=last_seq+16'd1 ||
                               payload_len==0 || cmd_offset!=offset || offset+payload_len>WIDTH*HEIGHT)
                                reject(3);
                            // cursor already 0 here; wait in READ_PIXEL one cycle
                            // for payload_rd to present payload[0].
                            else begin cursor<=0; last_seq<=cmd_seq; state<=READ_PIXEL; end
                        end
                        8'h12: begin
                            if(!frame_open || cmd_id!=current_id || cmd_seq!=last_seq+16'd1 ||
                               payload_len!=0 || offset!=WIDTH*HEIGHT) reject(3);
                            else begin
                                end_frame<=1; frame_open<=0; last_seq<=cmd_seq;
                                state<=FINISH_FRAME;
                            end
                        end
                        8'h13: begin
                            if(payload_len!=0 || frame_open || !valid || cmd_id!=result_id)
                                reply(2,4,0,0,0,offset);
                            else reply(0,0,1,total,bright,offset);
                        end
                        default: reject(5);
                    endcase
                end
                // payload_rd continuously tracks payload[cursor] with one cycle
                // of RAM read latency. Read pipeline:
                //   READ_PIXEL: cursor holds the address; wait one cycle.
                //   LOAD_PIXEL: payload_rd now == payload[cursor]; capture it.
                //   EMIT_PIXEL: buffered_pixel is stable; pulse pixel_valid.
                READ_PIXEL: state<=LOAD_PIXEL;
                LOAD_PIXEL: begin buffered_pixel<=payload_rd; state<=EMIT_PIXEL; end
                EMIT_PIXEL: begin
                    pixel_valid<=1;
                    if(cursor+1==payload_len) state<=FINISH_BLOCK;
                    else begin cursor<=cursor+1; state<=READ_PIXEL; end
                end
                FINISH_BLOCK: begin
                    offset<=offset+payload_len;
                    reply(0,0,0,0,0,offset+payload_len);
                end
                FINISH_FRAME: state<=WAIT_FRAME;
                WAIT_FRAME: begin
                    if(detector_error) reject(4);
                    else reply(0,0,valid,total,bright,offset);
                end
                REPLY_CRC: begin
                    if(crc_index<30) begin
                        reply_crc<=crc_byte(reply_crc,draft_mem[crc_index]);
                        crc_index<=crc_index+1;
                    end else begin
                        for(i=0;i<30;i=i+1) resp_mem[i]<=draft_mem[i];
                        resp_mem[30]<=reply_crc[7:0]; resp_mem[31]<=reply_crc[15:8];
                        state<=IDLE;
                    end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
