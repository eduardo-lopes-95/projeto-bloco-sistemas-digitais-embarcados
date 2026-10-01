import binascii
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from camera_capture import make_frame, parse_reply, publish
from bowl_notifier import NotificationPolicy


def result(frame_id=1, state='empty', valid=True):
    return dict(schema_version=1, session_id='test', frame_id=frame_id,
                capture_monotonic_ns=1_000_000_000, valid=valid,
                bowl_state=state, pixels_total=19200, pixels_bright=10000)


class PipelineTests(unittest.TestCase):
    def test_frame_format(self):
        data = make_frame(bytes([100])*19200, 17, 19, 21)
        self.assertEqual(len(data), 19248)
        self.assertEqual(data[:8], b'BOWL\x01\x01\x30\x00')
        self.assertEqual(struct.unpack_from('<IHHI', data, 8), (17,160,120,19200))
        with self.assertRaises(ValueError): make_frame(b'', 1, 1, 1)

    def test_reply_integrity_and_identity(self):
        data = bytearray(32)
        data[:4] = b'BR\x01\x13'
        struct.pack_into('<IHB', data, 4, 7, 22, 0)
        data[11:13] = b'\x01\x01'
        struct.pack_into('<III', data, 16, 19200, 9601, 19200)
        struct.pack_into('<H', data, 30, binascii.crc_hqx(data[:30], 0xffff))
        self.assertEqual(parse_reply(data, 7)['bowl_state'], 'empty')
        with self.assertRaises(ValueError): parse_reply(data, 8)
        data[20] ^= 1
        with self.assertRaises(ValueError): parse_reply(data, 7)

    def test_one_notification_per_episode(self):
        p = NotificationPolicy()
        self.assertEqual(p.observe(result(), 2_000_000_000), 'notify')
        self.assertIsNone(p.observe(result(), 2_000_000_000))
        self.assertIsNone(p.observe(result(2), 2_000_000_000))
        self.assertIsNone(p.observe(result(3, valid=False), 2_000_000_000))
        self.assertTrue(p.episode)
        self.assertIsNone(p.observe(result(4, 'unknown'), 2_000_000_000))
        self.assertEqual(p.observe(result(5, 'not_empty'), 2_000_000_000), 'rearm')
        self.assertEqual(p.observe(result(6), 2_000_000_000), 'notify')

    def test_confirmation_requires_distinct_fresh_frames(self):
        p=NotificationPolicy(confirm=3)
        self.assertIsNone(p.observe(result(), 2_000_000_000))
        self.assertIsNone(p.observe(result(), 2_000_000_000))
        self.assertIsNone(p.observe(result(2), 2_000_000_000))
        self.assertEqual(p.observe(result(3), 2_000_000_000), 'notify')
        p=NotificationPolicy()
        self.assertIsNone(p.observe(result(), 20_000_000_000))
        self.assertIsNone(p.observe(result(), 0))
        self.assertIsNone(p.observe({}, 0))

    def test_publish_replaces_whole_record(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'result.json'
            publish(path, result())
            publish(path, result(2))
            self.assertEqual(json.loads(path.read_text())['frame_id'],2)
            self.assertEqual(list(Path(d).iterdir()),[path])

    def test_invalid_types_and_gap_reset_confirmation(self):
        p=NotificationPolicy(confirm=2)
        bad=result(); bad['frame_id']='invalid'
        self.assertIsNone(p.observe(bad,2_000_000_000))
        self.assertIsNone(p.observe(result(),2_000_000_000))
        new=result(2); new['capture_monotonic_ns']=20_000_000_000
        self.assertIsNone(p.observe(new,21_000_000_000))
        new=result(3); new['capture_monotonic_ns']=22_000_000_000
        self.assertEqual(p.observe(new,23_000_000_000),'notify')


if __name__ == '__main__': unittest.main()
