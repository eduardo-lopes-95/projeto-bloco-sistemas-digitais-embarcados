#!/usr/bin/env python3
"""Prove a physical wire between header pin 19 (GPIO10) and pin 21 (GPIO9),
independently of SPI. Temporarily drives GPIO10 as output and reads GPIO9 as
input; if they are jumpered together the reading follows what we drive.

Run with SPI still enabled is fine; this reclaims the two pins as GPIO only for
the duration of the test, then the kernel restores them.

  python3 wire_check.py
"""
import argparse
import subprocess
import sys
import time

# Defaults: header pin 19 (GPIO10, MOSI) driven -> header pin 21 (GPIO9, MISO) read.
DRIVE_DEFAULT = '10'
READ_DEFAULT = '9'


def pinctrl(*args):
    return subprocess.run(['pinctrl', *args], capture_output=True, text=True)


def read_level(pin):
    out = pinctrl('get', pin).stdout
    # e.g. "9: ip -- | hi // ..."  -> level is 'hi' or 'lo'
    for tok in out.replace('|', ' ').split():
        if tok in ('hi', 'lo'):
            return tok
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--drive', default=DRIVE_DEFAULT,
                    help='BCM number of the pin to drive (default 10 = header pin 19)')
    ap.add_argument('--read', default=READ_DEFAULT,
                    help='BCM number of the pin to read (default 9 = header pin 21)')
    ap.add_argument('--restore', default='a0',
                    help="function to restore pins to afterwards (default a0 = SPI)")
    ap.add_argument('--selftest', action='store_true',
                    help='drive and read the SAME pin (no wire needed); must PASS')
    args = ap.parse_args()
    drive_pin, read_pin = args.drive, args.read
    if args.selftest:
        read_pin = drive_pin   # loop a pin onto itself to validate the method

    if pinctrl('help').returncode != 0:
        print('pinctrl not available (need Raspberry Pi OS Bookworm).', file=sys.stderr)
        return 2
    try:
        # For a two-pin test, the read pin is an input. For selftest the same
        # pin is driven and read back, so skip the input-mode step.
        if not args.selftest:
            pinctrl('set', read_pin, 'ip')
        results = {}
        for drive in ('dh', 'dl'):          # drive high, drive low
            pinctrl('set', drive_pin, 'op', drive)
            time.sleep(0.05)
            results[drive] = read_level(read_pin)
        print(f'drove GPIO{drive_pin} high -> GPIO{read_pin} read {results["dh"]}')
        print(f'drove GPIO{drive_pin} low  -> GPIO{read_pin} read {results["dl"]}')
        if results['dh'] == 'hi' and results['dl'] == 'lo':
            print(f'PASS: GPIO{read_pin} follows GPIO{drive_pin} '
                  '-> the wire between these two pins conducts.')
            rc = 0
        elif results['dh'] == results['dl']:
            print(f'FAIL: GPIO{read_pin} does not follow GPIO{drive_pin} (stuck '
                  f'{results["dh"]}). No conductive path between these two pins '
                  '(open wire, wrong pins, or bad contact).')
            rc = 1
        else:
            print('INCONCLUSIVE: unexpected readings; check wiring.')
            rc = 1
    finally:
        # Restore both pins to the requested function (a0 = SPI ALT0).
        pinctrl('set', drive_pin, args.restore)
        pinctrl('set', read_pin, args.restore)
    return rc


if __name__ == '__main__':
    raise SystemExit(main())
