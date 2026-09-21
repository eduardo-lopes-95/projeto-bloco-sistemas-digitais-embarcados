// Linux AArch64, no libc. All SPI packet construction and CRC run in Assembly.
// Usage: spi_image_client frame.bowl result.bin threshold /dev/spidev0.0
//        spi_image_client frame.bowl commands.bin threshold --emit
// --emit writes command packets only, for offline RTL replay (no hardware I/O).
.global _start
.section .rodata
usage: .ascii "usage: spi_image_client INPUT OUTPUT THRESHOLD DEVICE|--emit\n"
.equ usage_len, .-usage
failure: .ascii "spi_image_client: invalid input, I/O or protocol failure\n"
.equ failure_len, .-failure
emit_name: .asciz "--emit"
sleep_time: .quad 0, 1000000
.section .data
mode: .byte 0
bits: .byte 8
.balign 4
speed: .word 100000 // conservative bring-up rate; raise only after measurements
.section .bss
.balign 16
frame: .skip 19248
packet: .skip 1042
reply_tx: .skip 37
reply_rx: .skip 37
xfer: .skip 32
begin_data: .skip 16
scratch: .skip 16
.section .text
_start:
    ldr x0, [sp]
    cmp x0, #5
    b.ne show_usage
    ldr x27, [sp, #16] // input
    ldr x20, [sp, #24] // output pathname until opened
    ldr x1, [sp, #32]  // threshold
    ldr x21, [sp, #40] // device or --emit
    mov w28, #0
    ldrb w2, [x1]
    cbz w2, fail
parse_threshold:
    ldrb w2, [x1], #1
    cbz w2, threshold_done
    sub w2, w2, #'0'
    cmp w2, #9
    b.hi fail
    mov w3, #10
    madd w28, w28, w3, w2
    cmp w28, #255
    b.hi fail
    b parse_threshold
threshold_done:
    mov x0, #-100
    mov x1, x27
    mov x2, #0
    mov x3, #0
    mov x8, #56
    svc #0
    tbnz x0, #63, fail
    mov x19, x0
    ldr x1, =frame
    mov x2, #19248
    bl read_exact
    mov x0, x19
    ldr x1, =scratch
    mov x2, #1
    mov x8, #63
    svc #0
    cbnz x0, fail // no trailing bytes
    mov x0, x19
    mov x8, #57
    svc #0
    ldr x27, =frame
    ldr w0, [x27]
    ldr w1, =0x4c574f42
    cmp w0, w1
    b.ne fail
    ldr w0, [x27, #4]
    ldr w1, =0x00300101 // header size 48, format 1, version 1
    cmp w0, w1
    b.ne fail
    ldr w0, [x27, #12]
    ldr w1, =0x007800a0
    cmp w0, w1
    b.ne fail
    ldr w0, [x27, #16]
    mov w10, #19200
    cmp w0, w10
    b.ne fail
    ldr w0, [x27, #20]
    cbnz w0, fail
    ldr x0, [x27, #40]
    cbnz x0, fail
    ldr w23, [x27, #8]
    mov x22, #0
    mov x0, x21
    ldr x1, =emit_name
compare_emit:
    ldrb w2, [x0], #1
    ldrb w3, [x1], #1
    cmp w2, w3
    b.ne open_spi
    cbnz w2, compare_emit
    mov x22, #1
    b open_output
open_spi:
    mov x0, #-100
    mov x1, x21
    mov x2, #2
    mov x3, #0
    mov x8, #56
    svc #0
    tbnz x0, #63, fail
    mov x21, x0
    ldr x1, =0x40016b01
    ldr x2, =mode
    bl config_ioctl
    ldr x1, =0x40016b03
    ldr x2, =bits
    bl config_ioctl
    ldr x1, =0x40046b04
    ldr x2, =speed
    bl config_ioctl
open_output:
    // OUTPUT is a new temporary file supplied by the supervisor, never INPUT.
    mov x0, #-100
    mov x1, x20
    mov x2, #193 // O_WRONLY|O_CREAT|O_EXCL: never truncate an existing file
    mov x3, #384 // 0600
    mov x8, #56
    svc #0
    tbnz x0, #63, fail
    mov x20, x0
    mov w24, #0
    mov w0, #1 // GET_INFO
    mov w1, #0
    mov w2, #0
    mov x3, #0
    bl command
    cbnz x22, make_begin
    ldr x9, =reply_rx+5
    ldr w0, [x9, #16]
    ldr w1, =0x424f574c
    cmp w0, w1
    b.ne fail
    ldr w0, [x9, #20]
    cmp w0, #1024
    b.lo fail
    ldr w0, [x9, #24]
    cmp w0, #1
    b.ne fail
make_begin:
    // BEGIN rejects/aborts a stale reception. Retry uses a new frame_id.
    // No unconditional ABORT: keep the previous valid result between frames.
    ldr x3, =begin_data
    mov w0, #160
    strh w0, [x3]
    mov w0, #120
    strh w0, [x3, #2]
    mov w0, #1
    strb w0, [x3, #4]
    strb w28, [x3, #6]
    mov w0, #19200
    str w0, [x3, #12]
    mov w0, #0x10
    mov w1, #16
    mov w2, #0
    bl command
    mov w25, #0
block_loop:
    mov w0, #19200
    sub w26, w0, w25
    mov w0, #1024
    cmp w26, w0
    csel w26, w26, w0, lo
    add x3, x27, #48
    add x3, x3, x25
    mov w0, #0x11
    mov w1, w26
    mov w2, w25
    bl command
    add w25, w25, w26
    cbnz x22, block_next
    ldr x9, =reply_rx+5
    ldr w0, [x9, #24]
    cmp w0, w25
    b.ne fail
block_next:
    mov w10, #19200
    cmp w25, w10
    b.lo block_loop
    mov w0, #0x12
    mov w1, #0
    mov w2, #0
    mov x3, #0
    bl command
    mov w0, #0x13
    mov w1, #0
    mov w2, #0
    mov x3, #0
    bl command
    cbnz x22, success
    ldr x1, =reply_rx+5
    ldrb w0, [x1, #11]
    cmp w0, #1
    b.ne fail
    ldrb w0, [x1, #12]
    cmp w0, #2
    b.hi fail
    ldr w0, [x1, #16]
    mov w10, #19200
    cmp w0, w10
    b.ne fail
    ldr w0, [x1, #20]
    mov w10, #19200
    cmp w0, w10
    b.hi fail
    mov x0, x20
    mov x2, #32
    bl write_all
success:
    mov x0, x20
    mov x8, #57
    svc #0
    tbnz x0, #63, fail
    mov x0, #0
    mov x8, #93
    svc #0

// command(op, len, offset, payload); preserves x19-x28 except sequence x24.
command:
    stp x29, x30, [sp, #-48]!
    stp x0, x1, [sp, #16]
    ldr x9, =packet
    mov w10, #0x5742
    strh w10, [x9]
    mov w10, #1
    strb w10, [x9, #2]
    strb w0, [x9, #3]
    str w23, [x9, #4]
    strh w24, [x9, #8]
    strh w1, [x9, #10]
    str w2, [x9, #12]
    mov x10, #0
copy_payload:
    cmp x10, x1
    b.hs payload_copied
    ldrb w11, [x3, x10]
    add x12, x9, #16
    strb w11, [x12, x10]
    add x10, x10, #1
    b copy_payload
payload_copied:
    add x1, x1, #16
    mov x0, x9
    bl crc16
    ldr x9, =packet
    ldr x10, [sp, #24]
    add x10, x10, #16
    strh w0, [x9, x10]
    add x2, x10, #2
    cbz x22, command_live
    mov x0, x20
    mov x1, x9
    bl write_all
    b command_done
command_live:
    mov x0, x9
    mov x1, #0
    bl transfer
    mov x0, #100 // bounded polling: ~100ms plus transfer overhead
    str x0, [sp, #32]
poll_reply:
    ldr x0, =sleep_time
    mov x1, #0
    mov x8, #101
    svc #0
    ldr x0, =reply_tx
    mov w9, #0xf0
    strb w9, [x0]
    ldr x1, =reply_rx
    mov x2, #37
    bl transfer
    ldr x0, =reply_rx+5
    mov x1, #30
    bl crc16
    ldr x9, =reply_rx+5
    ldrh w10, [x9, #30]
    cmp w0, w10
    b.ne retry_reply
    ldrh w10, [x9]
    mov w11, #0x5242
    cmp w10, w11
    b.ne retry_reply
    ldrb w10, [x9, #2]
    cmp w10, #1
    b.ne retry_reply
    ldrb w10, [x9, #3]
    ldr w11, [sp, #16]
    cmp w10, w11
    b.ne retry_reply
    ldr w10, [x9, #4]
    cmp w10, w23
    b.ne retry_reply
    ldrh w10, [x9, #8]
    cmp w10, w24
    b.ne retry_reply
    ldrb w10, [x9, #10]
    cmp w10, #1
    b.eq retry_reply
    cbnz w10, fail
    ldrh w10, [x9, #28]
    cbnz w10, fail
    b command_done
retry_reply:
    ldr x0, [sp, #32]
    subs x0, x0, #1
    str x0, [sp, #32]
    b.ne poll_reply
    b fail
command_done:
    add w24, w24, #1
    ldp x29, x30, [sp], #48
    ret

// CRC16/CCITT-FALSE, x0=buffer x1=length -> w0=CRC.
crc16:
    mov w4, #0xffff
    mov w7, #0x1021
crc_next:
    cbz x1, crc_done
    ldrb w2, [x0], #1
    eor w4, w4, w2, lsl #8
    mov w3, #8
crc_bit:
    and w5, w4, #0x8000
    lsl w4, w4, #1
    cbz w5, crc_no_xor
    eor w4, w4, w7
crc_no_xor:
    and w4, w4, #0xffff
    subs w3, w3, #1
    b.ne crc_bit
    sub x1, x1, #1
    b crc_next
crc_done:
    mov w0, w4
    ret

config_ioctl:
    mov x0, x21
    mov x8, #29
    svc #0
    tbnz x0, #63, fail
    ret
// x0=TX pointer x1=RX pointer x2=len; spi_ioc_transfer is 32 bytes.
transfer:
    ldr x9, =xfer
    stp xzr, xzr, [x9]
    stp xzr, xzr, [x9, #16]
    str x0, [x9]
    str x1, [x9, #8]
    str w2, [x9, #16]
    mov x12, x2
    ldr x10, =speed
    ldr w10, [x10]
    str w10, [x9, #20]
    mov w10, #8
    strb w10, [x9, #26]
    mov x0, x21
    ldr x1, =0x40206b00
    mov x2, x9
    mov x8, #29
    svc #0
    cmp x0, x12
    b.ne fail
    ret
read_exact:
    mov x9, x0
read_loop:
    mov x0, x9
    mov x8, #63
    svc #0
    cmn x0, #4
    b.eq read_loop
    cmp x0, #0
    b.le fail
    add x1, x1, x0
    subs x2, x2, x0
    b.ne read_loop
    ret
write_all:
    mov x9, x0
write_loop:
    mov x0, x9
    mov x8, #64
    svc #0
    cmn x0, #4
    b.eq write_loop
    cmp x0, #0
    b.le fail
    add x1, x1, x0
    subs x2, x2, x0
    b.ne write_loop
    ret
show_usage:
    mov x0, #2
    ldr x1, =usage
    mov x2, #usage_len
    mov x8, #64
    svc #0
    b exit_error
fail:
    mov x0, #2
    ldr x1, =failure
    mov x2, #failure_len
    mov x8, #64
    svc #0
exit_error:
    mov x0, #1
    mov x8, #93
    svc #0
