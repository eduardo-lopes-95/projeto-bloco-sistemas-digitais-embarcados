#!/usr/bin/env python3
"""Gera um frame .bowl sintetico de 19248 bytes para testar o spi_image_client
sem a camera (camera_capture.py). O cabecalho reproduz exatamente o que o
cliente Assembly valida no inicio de _start:

  offset 0  : magic  0x4c574f42  ("BOWL")
  offset 4  : 0x00300101  (header size 48, format 1, version 1)
  offset 8  : frame_id (u32, little-endian) -- escolha livre, != 0
  offset 12 : 0x007800a0  (largura 160 = 0x00A0, altura 120 = 0x0078)
  offset 16 : 19200  (u32, contagem de pixels)
  offset 20 : 0  (u32)
  offset 40 : 0  (u64)
  offset 48+: 19200 bytes de pixels GRAY8

Uso:
  python3 make_test_frame.py empty  frame_empty.bowl   # todos claros (pote vazio)
  python3 make_test_frame.py full   frame_full.bowl    # todos escuros (pote cheio)
  python3 make_test_frame.py --level 200 out.bowl      # nivel de cinza custom
"""
import argparse
import struct
import sys

WIDTH, HEIGHT = 160, 120
NPIX = WIDTH * HEIGHT            # 19200
HDR = 48
TOTAL = HDR + NPIX              # 19248


def build(level, frame_id=1):
    hdr = bytearray(HDR)
    struct.pack_into('<I', hdr, 0, 0x4C574F42)   # "BOWL"
    struct.pack_into('<I', hdr, 4, 0x00300101)   # header 48, format 1, version 1
    struct.pack_into('<I', hdr, 8, frame_id)      # frame_id
    struct.pack_into('<I', hdr, 12, 0x007800A0)   # 160 x 120 (dimensoes)
    struct.pack_into('<I', hdr, 16, NPIX)         # 19200 pixels
    # offsets 20 e 40 ja sao zero (bytearray inicia em 0)
    pixels = bytes([level & 0xFF]) * NPIX
    return bytes(hdr) + pixels


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('preset', nargs='?', choices=['empty', 'full', 'custom'],
                    default='custom',
                    help="empty=claro (255), full=escuro (0), custom=usa --level")
    ap.add_argument('output')
    ap.add_argument('--level', type=int, default=None,
                    help='nivel de cinza 0..255 para todos os pixels (preset custom)')
    ap.add_argument('--frame-id', type=int, default=1)
    args = ap.parse_args()

    if args.preset == 'empty':
        level = 255
    elif args.preset == 'full':
        level = 0
    else:
        if args.level is None:
            print('custom exige --level 0..255', file=sys.stderr)
            return 2
        level = args.level

    data = build(level, args.frame_id)
    assert len(data) == TOTAL, len(data)
    with open(args.output, 'wb') as f:
        f.write(data)
    print(f'gravado {args.output}: {len(data)} bytes, nivel={level}, '
          f'frame_id={args.frame_id} ({WIDTH}x{HEIGHT} GRAY8)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
