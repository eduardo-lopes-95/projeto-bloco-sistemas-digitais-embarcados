#!/usr/bin/env python3
"""Layered SPI bring-up diagnostic for the Tang Nano 4K spi_image slave.

Run ON the Raspberry Pi after wiring RPi SPI0 to the Tang. It isolates *where*
the path breaks, instead of the single "invalid input, I/O or protocol failure"
message the Assembly client prints for every error.

Stages (each depends on the previous one passing):
  0. open /dev/spidev0.0 and configure mode 0, 8 bits, 100 kHz.
  1. raw transfer: can we clock bytes at all (ioctl SPI_IOC_MESSAGE works)?
  2. GET_INFO command: does the Tang reply with a CRC-valid envelope?
  3. decode the reply and print status/fields.

Usage:
  python3 spi_diag.py                      # default /dev/spidev0.0, 100 kHz
  python3 spi_diag.py --device /dev/spidev0.0 --speed 100000 --loopback
  --loopback: expect MOSI physically tied to MISO (no Tang); checks wiring/driver.
"""
import argparse
import binascii
import sys
import time

CMD_GET_INFO = 0x01


def crc16(data):
    return binascii.crc_hqx(bytes(data), 0xffff)


def build_command(op, seq, frame_id=0, length=0, offset=0, payload=b''):
    hdr = bytearray(16)
    hdr[0:2] = b'\x57\x42'          # 'WB' little-endian magic (0x4257)
    hdr[2] = 1                       # version
    hdr[3] = op
    hdr[4:8] = frame_id.to_bytes(4, 'little')
    hdr[8:10] = seq.to_bytes(2, 'little')
    hdr[10:12] = length.to_bytes(2, 'little')
    hdr[12:16] = offset.to_bytes(4, 'little')
    body = bytes(hdr) + payload
    return body + crc16(body).to_bytes(2, 'little')


def decode_reply(rx):
    """rx is the 37-byte read starting with the 0xF0 read-marker byte.
    The 32-byte response payload begins at offset 5 (matches the RTL)."""
    r = rx[5:37]
    if len(r) != 32:
        return None, 'short read'
    if crc16(r[:30]) != int.from_bytes(r[30:32], 'little'):
        return None, 'reply CRC mismatch (Tang not driving MISO correctly?)'
    if r[0:2] != b'\x42\x52':       # 'BR'
        return None, f'bad magic {r[0:2].hex()} (expected 4252)'
    status = r[10]
    is_result = r[11]
    bowl = r[12]
    err = int.from_bytes(r[28:30], 'little')
    return {'op': r[3], 'seq': int.from_bytes(r[8:10], 'little'),
            'status': status, 'is_result': is_result, 'bowl': bowl,
            'err': err}, None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--device', default='/dev/spidev0.0')
    ap.add_argument('--speed', type=int, default=100000)
    ap.add_argument('--loopback', action='store_true',
                    help='MOSI tied to MISO, no Tang connected')
    args = ap.parse_args()

    try:
        import spidev
    except ImportError:
        print('FAIL stage 0: python3-spidev not installed.\n'
              '  sudo apt install python3-spidev', file=sys.stderr)
        return 2

    # --- Stage 0: open + configure ---
    spi = spidev.SpiDev()
    try:
        bus, dev = (int(x) for x in args.device.rsplit('spidev', 1)[1].split('.'))
        spi.open(bus, dev)
        spi.mode = 0
        spi.bits_per_word = 8
        spi.max_speed_hz = args.speed
    except (OSError, PermissionError) as e:
        print(f'FAIL stage 0: cannot open/configure {args.device}: {e}\n'
              '  check SPI is enabled and you have permission (try sudo).',
              file=sys.stderr)
        return 2
    print(f'PASS stage 0: {args.device} open, mode 0, 8 bits, {args.speed} Hz')

    # --- Stage 1: raw transfer ---
    probe = [0x55, 0xAA, 0x00, 0xFF]
    try:
        got = spi.xfer2(list(probe))
    except OSError as e:
        print(f'FAIL stage 1: SPI_IOC_MESSAGE ioctl failed: {e}', file=sys.stderr)
        spi.close()
        return 3
    print(f'PASS stage 1: raw transfer works; sent {probe} got {got}')
    if args.loopback:
        if got == list(probe):
            print('PASS loopback: MOSI->MISO wiring and driver confirmed.')
            spi.close()
            return 0
        print(f'FAIL loopback: expected {probe}, got {got}. '
              'Check MOSI/MISO wiring or driver.', file=sys.stderr)
        spi.close()
        return 4

    # --- Stage 2/3: GET_INFO against the Tang ---
    cmd = build_command(CMD_GET_INFO, seq=0)
    spi.xfer2(list(cmd))                 # send command transaction
    time.sleep(0.005)
    read = [0xF0] + [0] * 36             # 0xF0 read-marker then 36 dummy bytes
    got = spi.xfer2(list(read))
    spi.close()

    decoded, err = decode_reply(bytes(got))
    if err:
        print(f'FAIL stage 2: {err}\n  raw reply bytes: {bytes(got).hex()}',
              file=sys.stderr)
        return 5
    print(f'PASS stage 2: CRC-valid reply from Tang: {decoded}')
    if decoded['status'] != 0:
        print(f'NOTE: Tang replied with error status={decoded["status"]} '
              f'err={decoded["err"]} (envelope is valid, so SPI link is OK).')
    else:
        print('PASS stage 3: GET_INFO accepted; SPI link and slave are healthy.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
