"""FPGA notification policy. Dry-run by default; --send explicitly enables Twilio.
Provider errors are persisted as unknown and are not retried blindly.
"""
import argparse
import json
import os
from pathlib import Path
import time
from camera_capture import publish


class NotificationPolicy:
    def __init__(self, confirm=1, rearm=1, max_age=10, episode=False):
        self.confirm, self.rearm, self.max_age = confirm, rearm, max_age
        self.episode = episode
        self.last = None
        self.empty_count = self.full_count = 0
        self.session = None
        self.last_capture = None

    def observe(self, result, now_ns):
        try:
            age = (now_ns-result['capture_monotonic_ns'])/1e9
            key = (result['session_id'], result['frame_id'])
            state = result['bowl_state']
            valid = (result['schema_version'] == 1 and result['valid'] is True
                     and isinstance(key[0], str) and bool(key[0])
                     and type(key[1]) is int and 0 < key[1] <= 0xffffffff
                     and type(result['capture_monotonic_ns']) is int
                     and type(result['pixels_total']) is int
                     and type(result['pixels_bright']) is int
                     and 0 <= age <= self.max_age
                     and state in ('empty', 'not_empty')
                     and result['pixels_total'] == 19200
                     and 0 <= result['pixels_bright'] <= 19200)
        except (KeyError, TypeError, ValueError):
            valid = False
        if not valid:
            self.empty_count = self.full_count = 0
            return None
        if key == self.last:
            return None
        if self.session == key[0] and self.last is not None and key[1] <= self.last[1]:
            return None
        if (self.session != key[0] or (self.last_capture is not None and
                result['capture_monotonic_ns']-self.last_capture > self.max_age*1e9)):
            self.empty_count = self.full_count = 0
        self.session, self.last = key[0], key
        self.last_capture = result['capture_monotonic_ns']
        if state == 'empty':
            self.full_count = 0
            self.empty_count += 1
            if self.empty_count >= self.confirm and not self.episode:
                self.episode = True
                return 'notify'
        else:
            self.empty_count = 0
            self.full_count += 1
            if self.full_count >= self.rearm and self.episode:
                self.episode = False
                return 'rearm'
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, default=Path('/dev/shm/bowl_result.json'))
    parser.add_argument('--state', type=Path, default=Path('bowl_notification_state.json'))
    parser.add_argument('--confirm', type=int, default=1)
    parser.add_argument('--rearm', type=int, default=1)
    parser.add_argument('--max-age', type=float, default=10)
    parser.add_argument('--send', action='store_true')
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args()
    if min(args.confirm, args.rearm, args.max_age) <= 0:
        parser.error('counts and max-age must be positive')
    state = {'episode': False, 'status': 'idle'}
    client = None
    if args.send:
        from dotenv import load_dotenv
        from twilio.rest import Client
        load_dotenv()
        required = ('TWILIO_ACCOUNT_SID', 'TWILIO_AUTH_TOKEN', 'TWILIO_WHATSAPP_FROM', 'TWILIO_WHATSAPP_TO')
        if not all(os.getenv(x) for x in required):
            parser.error('missing Twilio credentials/from/to configuration')
        client = Client(os.environ['TWILIO_ACCOUNT_SID'], os.environ['TWILIO_AUTH_TOKEN'])
    import fcntl
    with open(str(args.state)+'.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.send and args.state.exists():
            state = json.loads(args.state.read_text(encoding='utf-8'))
        policy = NotificationPolicy(args.confirm, args.rearm, args.max_age, state['episode'])
        while True:
            try:
                result = json.loads(args.input.read_text(encoding='utf-8'))
            except (OSError, ValueError):
                result = {}
            action = policy.observe(result, time.monotonic_ns())
            if action:
                print(json.dumps({'action': action, 'dry_run': not args.send,
                                  'frame_id': result.get('frame_id')}), flush=True)
                if args.send:
                    state = {'episode': policy.episode, 'status': 'pending' if action=='notify' else 'idle',
                             'frame_id': result['frame_id'], 'session_id': result['session_id']}
                    publish(args.state, state)
                    if action == 'notify':
                        kwargs = {'from_': os.environ['TWILIO_WHATSAPP_FROM'], 'to': os.environ['TWILIO_WHATSAPP_TO']}
                        if os.getenv('TWILIO_CONTENT_SID'):
                            kwargs['content_sid'] = os.environ['TWILIO_CONTENT_SID']
                        else:
                            kwargs['body'] = 'O pote de ração está vazio. Por favor, abasteça.'
                        try:
                            message = client.messages.create(**kwargs)
                            state.update(status='accepted', sid=message.sid)
                        except Exception as exc:
                            state.update(status='unknown', error=type(exc).__name__)
                        publish(args.state, state)
            if args.once:
                return
            time.sleep(0.5)


if __name__ == '__main__':
    main()
