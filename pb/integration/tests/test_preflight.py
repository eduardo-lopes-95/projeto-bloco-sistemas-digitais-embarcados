import contextlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'deploy'))
import preflight


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.camera = ('CAMERA_URL=http://127.0.0.1:8080/shot.jpg\n'
                       'THRESHOLD=100\nCAPTURE_INTERVAL=2\nCROP_ARGS=\n')
        (self.root / 'camera.env').write_text(self.camera)
        self.whatsapp = ('TWILIO_ACCOUNT_SID=AC' + '0' * 32 + '\n'
                         'TWILIO_AUTH_TOKEN=private-test-value\n'
                         'TWILIO_WHATSAPP_FROM=whatsapp:+5511999999999\n'
                         'TWILIO_WHATSAPP_TO=whatsapp:+5511888888888\n'
                         'TWILIO_CONTENT_SID=HX' + '1' * 32 + '\n')
        (self.root / 'whatsapp.env').write_text(self.whatsapp)

    def run_check(self, mode):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            rc = preflight.main([mode, str(self.root)])
        return rc, out.getvalue()

    def test_config_does_not_access_camera_or_send(self):
        with patch('camera_capture.acquire') as acquire:
            rc, out = self.run_check('config')
        self.assertEqual(rc, 0)
        acquire.assert_not_called()
        self.assertNotIn('private-test-value', out)

    def test_placeholder_credentials_block_start(self):
        (self.root / 'whatsapp.env').write_text(self.whatsapp.replace('private-test-value', 'REPLACE_WITH_AUTH_TOKEN'))
        rc, out = self.run_check('config')
        self.assertEqual(rc, 2)
        self.assertIn('Preencha TWILIO_AUTH_TOKEN', out)

    def test_invalid_threshold_and_interval(self):
        for original, bad in [('THRESHOLD=100', 'THRESHOLD=256'),
                              ('CAPTURE_INTERVAL=2', 'CAPTURE_INTERVAL=nan'),
                              ('CAPTURE_INTERVAL=2', 'CAPTURE_INTERVAL=0')]:
            with self.subTest(bad=bad):
                (self.root / 'camera.env').write_text(self.camera.replace(original, bad))
                self.assertEqual(self.run_check('config')[0], 2)

    def test_duplicate_key_is_rejected(self):
        (self.root / 'camera.env').write_text(self.camera + 'THRESHOLD=50\n')
        self.assertEqual(self.run_check('config')[0], 2)

    def test_crop_is_passed_to_real_acquisition_interface(self):
        (self.root / 'camera.env').write_text(self.camera.replace('CROP_ARGS=', 'CROP_ARGS="--crop 640:480:0:0"'))
        with patch('camera_capture.acquire', return_value=bytes(19200)) as acquire:
            rc, out = self.run_check('camera')
        self.assertEqual(rc, 0)
        self.assertEqual(acquire.call_args.args[0], 'http://127.0.0.1:8080/shot.jpg')
        self.assertEqual(acquire.call_args.args[2], '640:480:0:0')
        self.assertIn('Camera OK', out)

    def test_camera_failure_is_retryable_without_leaking_url(self):
        with patch('camera_capture.acquire', side_effect=OSError('http://user:secret@camera')):
            rc, out = self.run_check('camera')
        self.assertEqual(rc, 1)
        self.assertIn('OSError', out)
        self.assertNotIn('secret', out)

    def test_camera_probe_does_not_require_whatsapp_credentials(self):
        (self.root / 'whatsapp.env').unlink()
        with patch('camera_capture.acquire', return_value=bytes(19200)):
            self.assertEqual(self.run_check('camera')[0], 0)

    def test_unexpected_crop_arguments_rejected(self):
        (self.root / 'camera.env').write_text(self.camera.replace('CROP_ARGS=', 'CROP_ARGS=--once'))
        self.assertEqual(self.run_check('config')[0], 2)


if __name__ == '__main__':
    unittest.main()
