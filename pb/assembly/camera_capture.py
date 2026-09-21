"""Capture/convert only; FPGA classifies and AArch64 Assembly controls SPI.

Requires ffmpeg and the native build/bin/spi_image_client on the Raspberry.
No notification is sent by this process. Temporary files are private per cycle.
"""
import argparse
import binascii
import json
import os
from pathlib import Path
import secrets
import struct
import subprocess
import tempfile
import time
import urllib.request

FRAME_HEADER = struct.Struct('<4sBBHIHHIIQQQ')
PIXELS = 160 * 120


def make_frame(pixels, frame_id, session_id, capture_ns):
    if len(pixels) != PIXELS:
        raise ValueError('FRAME_SIZE')
    return FRAME_HEADER.pack(b'BOWL', 1, 1, 48, frame_id, 160, 120,
                             PIXELS, 0, capture_ns, session_id, 0) + pixels


def parse_reply(data, frame_id):
    if len(data) != 32:
        raise ValueError('REPLY_SIZE')
    if binascii.crc_hqx(data[:30], 0xffff) != int.from_bytes(data[30:], 'little'):
        raise ValueError('SPI_CRC')
    if data[:4] != b'BR\x01\x13' or int.from_bytes(data[4:8], 'little') != frame_id:
        raise ValueError('REPLY_ID')
    # GET_INFO, BEGIN, 19 blocks, END, GET_RESULT: final sequence 22.
    if int.from_bytes(data[8:10], 'little') != 22:
        raise ValueError('REPLY_SEQUENCE')
    if data[10:12] != b'\x00\x01' or data[12] > 2 or any(data[13:16]):
        raise ValueError('FPGA_INVALID')
    total, bright, offset = struct.unpack_from('<III', data, 16)
    if total != PIXELS or offset != PIXELS or bright > total or data[28:30] != b'\x00\x00':
        raise ValueError('REPLY_COUNTS')
    return {'valid': True, 'bowl_state': ('not_empty', 'empty', 'unknown')[data[12]],
            'pixels_total': total, 'pixels_bright': bright, 'error': 'NONE'}


def publish(path, result):
    path = Path(path)
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent,
                                     prefix=path.name+'.', delete=False) as out:
        tmp = Path(out.name)
        try:
            json.dump(result, out)
            out.write('\n')
            out.flush()
            os.fsync(out.fileno())
        except BaseException:
            tmp.unlink(missing_ok=True)
            raise
    try:
        os.replace(tmp, path)
        if hasattr(os, 'O_DIRECTORY'):
            directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
    finally:
        tmp.unlink(missing_ok=True)


def acquire(url, directory, crop):
    request = urllib.request.Request(url, headers={'Cache-Control': 'no-cache'})
    started = time.monotonic()
    # Limit both bytes and overall reception time, not just socket inactivity.
    with urllib.request.urlopen(request, timeout=5) as response:
        if response.status != 200:
            raise ValueError('CAMERA_HTTP')
        image = bytearray()
        while True:
            chunk = response.read(65536)
            if time.monotonic()-started > 10:
                raise TimeoutError('CAMERA_TIMEOUT')
            if not chunk:
                break
            image.extend(chunk)
            if len(image) > 5*1024*1024:
                raise ValueError('CAMERA_SIZE')
    source = directory / 'capture.image'
    raw = directory / 'frame.gray'
    source.write_bytes(image)
    filters = (f'crop={crop},' if crop else '') + 'scale=160:120'
    subprocess.run(['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error',
                    '-y', '-i', str(source), '-vf', filters, '-frames:v', '1',
                    '-pix_fmt', 'gray', '-f', 'rawvideo', str(raw)],
                   check=True, timeout=15, capture_output=True)
    pixels = raw.read_bytes()
    if len(pixels) != PIXELS:
        raise ValueError('FRAME_SIZE')
    return pixels


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True, help='verified snapshot URL from IP Webcam')
    parser.add_argument('--threshold', type=int, required=True, choices=range(256), metavar='0..255')
    parser.add_argument('--crop', help='ROI width:height:x:y; calibrate with phone images')
    parser.add_argument('--device', default='/dev/spidev0.0')
    parser.add_argument('--client', type=Path, default=Path(__file__).parent/'build/bin/spi_image_client')
    parser.add_argument('--output', type=Path, default=Path('/dev/shm/bowl_result.json'))
    parser.add_argument('--interval', type=float, default=2.0)
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args()
    if args.interval <= 0:
        parser.error('interval must be positive')
    if args.crop:
        values = args.crop.split(':')
        if len(values) != 4 or not all(x.isdecimal() for x in values) or min(map(int, values[:2])) <= 0:
            parser.error('crop must be positive width:height and nonnegative x:y')
    # Linux process lock avoids multiple publishers; imported here for host tests.
    import fcntl
    with open(str(args.output)+'.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        session = secrets.randbits(64)
        frame_id = 0
        while True:
            start = time.monotonic_ns()
            frame_id += 1
            if frame_id > 0xffffffff:
                session = secrets.randbits(64)
                frame_id = 1
            result = {'schema_version': 1, 'session_id': f'{session:016x}',
                      'frame_id': frame_id, 'capture_monotonic_ns': start}
            stage_error = 'ACQUISITION_FAILED'
            try:
                with tempfile.TemporaryDirectory(prefix='bowl-') as tmp:
                    directory = Path(tmp)
                    pixels = acquire(args.url, directory, args.crop)
                    packet = directory/'frame.bowl'
                    packet.write_bytes(make_frame(pixels, frame_id, session, start))
                    reply = directory/'reply.bin'
                    stage_error = 'SPI_CLIENT_FAILED'
                    subprocess.run([str(args.client.resolve()), str(packet), str(reply),
                                    str(args.threshold), args.device], check=True, timeout=15,
                                   capture_output=True)
                    stage_error = 'REPLY_INVALID'
                    result.update(parse_reply(reply.read_bytes(), frame_id))
            except (OSError, ValueError, TimeoutError, subprocess.SubprocessError) as exc:
                # Do not log URL credentials or raw subprocess stderr.
                result.update(valid=False, bowl_state='unknown', pixels_total=0,
                              pixels_bright=0, error=stage_error, error_type=type(exc).__name__)
            result['publish_monotonic_ns'] = time.monotonic_ns()
            publish(args.output, result)
            print(json.dumps(result), flush=True)
            if args.once:
                return 0 if result['valid'] else 1
            time.sleep(max(0, args.interval-(time.monotonic_ns()-start)/1e9))


if __name__ == '__main__':
    raise SystemExit(main())
