"""Configuration and camera checks; never sends a notification or prints secrets."""
import math
from pathlib import Path
import re
import shlex
import sys
import tempfile
from urllib.parse import urlsplit


class ConfigError(ValueError):
    """Safe diagnostic containing field names only, never credential values."""


def read_config(path):
    """Strict subset shared with systemd: KEY=value, optional outer quotes.

    No shell evaluation, interpolation, escapes or inline comments. Examples
    use this subset, so validation and systemd interpret the same values.
    """
    values = {}
    for line_number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        key, sep, value = line.partition('=')
        key, value = key.strip(), value.strip()
        if not sep or not re.fullmatch(r'[A-Z_][A-Z_0-9]*', key) or key in values:
            raise ConfigError(f'{path.name}: linha {line_number} invalida ou duplicada')
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if any(c in value for c in ('\\', '"', "'", '\x00')):
            raise ConfigError(f'{path.name}: linha {line_number} usa escape/aspas nao suportados')
        values[key] = value
    return values


def camera_settings(root):
    config = read_config(root / 'camera.env')
    url = config.get('CAMERA_URL', '')
    parsed = urlsplit(url)
    if parsed.scheme not in ('http', 'https') or not parsed.hostname:
        raise ConfigError('CAMERA_URL precisa ser uma URL HTTP(S) de snapshot')
    threshold = config.get('THRESHOLD', '')
    if not re.fullmatch(r'[0-9]{1,3}', threshold) or not 0 <= int(threshold) <= 255:
        raise ConfigError('THRESHOLD precisa estar entre 0 e 255')
    try:
        interval = float(config.get('CAPTURE_INTERVAL', ''))
    except ValueError:
        raise ConfigError('CAPTURE_INTERVAL precisa ser numerico') from None
    if not math.isfinite(interval) or interval <= 0:
        raise ConfigError('CAPTURE_INTERVAL precisa ser finito e positivo')
    crop_args = shlex.split(config.get('CROP_ARGS', ''))
    crop = None
    if crop_args:
        if len(crop_args) != 2 or crop_args[0] != '--crop':
            raise ConfigError('CROP_ARGS deve ser vazio ou --crop largura:altura:x:y')
        crop = crop_args[1]
        if not re.fullmatch(r'[0-9]+:[0-9]+:[0-9]+:[0-9]+', crop):
            raise ConfigError('Coordenadas CROP_ARGS invalidas')
        if min(map(int, crop.split(':')[:2])) <= 0:
            raise ConfigError('Largura e altura do crop precisam ser positivas')
    return url, crop


def check_whatsapp(root):
    config = read_config(root / 'whatsapp.env')
    required = ('TWILIO_ACCOUNT_SID', 'TWILIO_AUTH_TOKEN',
                'TWILIO_WHATSAPP_FROM', 'TWILIO_WHATSAPP_TO')
    for key in required:
        value = config.get(key, '')
        if not value or 'REPLACE_WITH' in value:
            raise ConfigError(f'Preencha {key} em whatsapp.env no Raspberry')
    if not re.fullmatch(r'AC[0-9a-fA-F]{32}', config['TWILIO_ACCOUNT_SID']):
        raise ConfigError('Formato de TWILIO_ACCOUNT_SID invalido')
    for key in ('TWILIO_WHATSAPP_FROM', 'TWILIO_WHATSAPP_TO'):
        if not re.fullmatch(r'whatsapp:\+[1-9][0-9]{7,14}', config[key]):
            raise ConfigError(f'{key} deve usar whatsapp:+numero com codigo do pais')
    content = config.get('TWILIO_CONTENT_SID', '')
    if content and not re.fullmatch(r'HX[0-9a-fA-F]{32}', content):
        raise ConfigError('Formato de TWILIO_CONTENT_SID invalido')
    if not content:
        print('AVISO: sem Content SID, texto livre depende da janela WhatsApp de 24 h.', flush=True)


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 2 or args[0] not in ('camera', 'config'):
        print('Uso: preflight.py camera|config APP_DIR', file=sys.stderr)
        return 2
    mode, root = args[0], Path(args[1]).resolve()
    try:
        url, crop = camera_settings(root)
        if mode == 'config':
            check_whatsapp(root)
            print('Configuracao local valida; credenciais nao foram autenticadas na Twilio.')
            return 0
    except ConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    except (OSError, ValueError) as exc:
        # Messages generated above never contain a config value; avoid parser
        # exceptions (e.g. malformed URL) including arbitrary input as well.
        print(f'Configuracao invalida ({type(exc).__name__}). Confira camera.env e whatsapp.env.', file=sys.stderr)
        return 2
    try:
        sys.path.insert(0, str(root))
        from camera_capture import acquire
        with tempfile.TemporaryDirectory(prefix='bowl-preflight-') as directory:
            pixels = acquire(url, Path(directory), crop)
        print(f'Camera OK: snapshot convertido para {len(pixels)} pixels GRAY8.', flush=True)
        return 0
    except Exception as exc:
        print(f'Camera indisponivel ou imagem invalida ({type(exc).__name__}); nova tentativa pelo servico.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
