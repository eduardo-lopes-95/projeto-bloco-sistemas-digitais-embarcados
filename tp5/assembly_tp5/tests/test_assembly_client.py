"""Generates Assembly-authored SPI bytes for RTL replay.

Runs on a native AArch64 host (e.g. Raspberry Pi) by executing the client
directly, or on other hosts (x86 Linux/WSL) via qemu-aarch64. Override the
launcher with SPI_CLIENT_RUNNER, e.g. SPI_CLIENT_RUNNER='qemu-aarch64'.
"""
import binascii
import os
import platform
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

HERE=Path(__file__).resolve().parent


def find_root():
    """Locate the assembly_tp4 root, tolerating both the repo layout
    (assembly_tp4/tests/this_file) and a flat deploy layout on the Pi
    (everything in one directory). The root is where camera_capture.py lives."""
    for candidate in (HERE, HERE.parent, *HERE.parents):
        if (candidate/'camera_capture.py').is_file():
            return candidate
    raise SystemExit('error: cannot locate camera_capture.py near this test')


ROOT=find_root()
sys.path.insert(0,str(ROOT))
from camera_capture import make_frame


def find_client():
    """Find the compiled client binary in the usual build locations."""
    for path in (ROOT/'build/bin/spi_image_client',
                 ROOT/'spi_image_client',
                 HERE/'build/bin/spi_image_client'):
        if path.is_file():
            return path
    raise SystemExit(
        f"error: client binary not found under {ROOT}. Build it first:\n"
        f"  make build/bin/spi_image_client")


def runner_prefix():
    """Command prefix to launch an AArch64 binary on this host."""
    override=os.environ.get('SPI_CLIENT_RUNNER')
    if override is not None:
        return override.split()
    # Native AArch64 (Raspberry Pi): run the ELF directly, no emulation needed.
    if platform.machine().lower() in ('aarch64','arm64'):
        return []
    # Foreign architecture: fall back to QEMU user-mode emulation.
    if shutil.which('qemu-aarch64') is None:
        raise SystemExit(
            'error: not an AArch64 host and qemu-aarch64 not found. '
            'Install qemu-user-static or set SPI_CLIENT_RUNNER.')
    return ['qemu-aarch64']


def main():
    client=find_client()
    launch=runner_prefix()
    with tempfile.TemporaryDirectory() as d:
        d=Path(d)
        inp=d/'frame.bowl'; out=d/'commands.bin'
        # The final pixel changes a tie to strict majority: catches end-of-frame races.
        pixels=bytes([101])*9600+bytes([100])*9599+bytes([101])
        inp.write_bytes(make_frame(pixels,7,123,456))
        subprocess.run(launch+[str(client),str(inp),str(out),'100','--emit'],check=True)
        data=out.read_bytes()
        pos=0; packets=[]; actual=bytearray()
        while pos<len(data):
            length=int.from_bytes(data[pos+10:pos+12],'little')
            packet=data[pos:pos+18+length]
            assert len(packet)==18+length and packet[:3]==b'BW\x01'
            assert binascii.crc_hqx(packet[:-2],0xffff)==int.from_bytes(packet[-2:],'little')
            assert int.from_bytes(packet[8:10],'little')==len(packets)
            if packet[3]==0x11:
                assert int.from_bytes(packet[12:16],'little')==len(actual)
                actual.extend(packet[16:-2])
            packets.append(packet); pos+=len(packet)
        assert len(packets)==23 and actual==pixels
        assert [p[3] for p in packets]==[1,16]+[17]*19+[18,19]
        assert packets[1][22]==100
        # Emit the replay hex for the RTL testbench only when the verilog tree
        # is present (dev machine); a flat Pi deploy skips this harmlessly.
        verilog=ROOT.parent/'verilog_tp4/assessment/sim/build'
        if verilog.parent.is_dir():
            verilog.mkdir(exist_ok=True)
            (verilog/'assembly_commands.hex').write_text('\n'.join(f'{x:02x}' for x in data)+'\n')
            (verilog/'assembly_commands.size').write_text(str(len(data)))
        inp.write_bytes(inp.read_bytes()[:-1])
        bad=subprocess.run(launch+[str(client),str(inp),str(d/'bad'),'100','--emit'],capture_output=True)
        assert bad.returncode!=0 and not (d/'bad').exists()
        bad=subprocess.run(launch+[str(client),str(inp),str(d/'bad'),'256','--emit'],capture_output=True)
        assert bad.returncode!=0
        print(f'PASS: AArch64 generated {len(packets)} packets, {len(actual)} pixels; CRC, layout and input rejection')


if __name__=='__main__': main()
