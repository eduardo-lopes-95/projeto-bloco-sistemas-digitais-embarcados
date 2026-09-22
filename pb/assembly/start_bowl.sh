#!/usr/bin/env bash
# Run with: bash /home/pi/pb/start_bowl.sh [--prepare|--check-camera]
set -Eeuo pipefail

APP_DIR=/home/pi/pb
APP_USER=pi
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
MODE=${1:-start}

case "$MODE" in
  -h|--help)
    printf '%s\n' \
      'Uso: bash /home/pi/pb/start_bowl.sh [--prepare|--check-camera]' \
      'Sem argumentos: prepara, valida e habilita captura + WhatsApp real no boot.' \
      '--prepare: instala dependencias e cria exemplos; nao inicia servicos.' \
      '--check-camera: testa o snapshot e a conversao; nao envia mensagens.'
    exit 0 ;;
  start|--prepare|--check-camera) ;;
  *) printf 'Opcao desconhecida. Use --help.\n' >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { printf 'Use apenas uma opcao.\n' >&2; exit 2; }

if [[ "$SCRIPT_DIR" != "$APP_DIR" ]]; then
  printf 'Copie o script e os fontes para %s antes de executar.\n' "$APP_DIR" >&2
  exit 2
fi

# This mode runs as pi from systemd on EVERY service start, without sudo/apt.
if [[ "$MODE" == --check-camera ]]; then
  exec "$APP_DIR/.venv/bin/python" "$APP_DIR/deploy/preflight.py" camera "$APP_DIR"
fi

[[ $(uname -s) == Linux && $(uname -m) == aarch64 ]] || {
  printf 'Necessario Raspberry Pi OS Linux de 64 bits (aarch64).\n' >&2
  exit 2
}
if [[ $EUID -ne 0 ]]; then
  exec sudo /bin/bash "$APP_DIR/start_bowl.sh" "$@"
fi
trap 'printf "Preparacao interrompida na linha %s. Os detalhes estao acima.\n" "$LINENO" >&2' ERR

id "$APP_USER" >/dev/null
[[ -d /run/systemd/system ]] || { printf 'systemd precisa estar ativo.\n' >&2; exit 2; }
cd -- "$APP_DIR"
for source in Makefile spi_image_client.s camera_capture.py bowl_notifier.py \
  deploy/preflight.py deploy/requirements.txt deploy/camera.env.example \
  deploy/whatsapp.env.example deploy/bowl-capture.service deploy/bowl-notifier.service; do
  [[ -f "$source" ]] || { printf 'Arquivo ausente: %s\n' "$source" >&2; exit 2; }
done

# Serialize installations, without touching the locks of the running services.
exec 9>/run/lock/bowl-setup.lock
flock -n 9 || { printf 'Outra preparacao esta em andamento.\n' >&2; exit 2; }
as_pi() { runuser -u "$APP_USER" -- "$@"; }

missing=()
for package in build-essential python3 python3-venv ffmpeg; do
  if [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true) != 'install ok installed' ]]; then
    missing+=("$package")
  fi
done
if ((${#missing[@]})); then
  printf 'Instalando dependencias do sistema...\n'
  apt-get update
  apt-get install -y "${missing[@]}"
fi

for config in camera whatsapp; do
  if [[ ! -e "$config.env" ]]; then
    install -o "$APP_USER" -g "$(id -gn "$APP_USER")" -m 600 \
      "deploy/$config.env.example" "$config.env"
  fi
done

printf 'Preparando ambiente virtual e cliente Assembly...\n'
if [[ ! -x .venv/bin/python ]]; then
  as_pi python3 -m venv "$APP_DIR/.venv"
fi
# A matching manifest plus working imports avoids contacting PyPI on each run.
if ! cmp -s deploy/requirements.txt .venv/.bowl-requirements.txt || \
   ! as_pi .venv/bin/python -c 'import twilio.rest, dotenv' >/dev/null 2>&1; then
  as_pi .venv/bin/python -m pip install --disable-pip-version-check -r deploy/requirements.txt
  as_pi cp deploy/requirements.txt .venv/.bowl-requirements.txt
fi
as_pi make

if [[ "$MODE" == --prepare ]]; then
  printf '%s\n' 'Preparacao concluida. Nenhum servico foi iniciado.' \
    'Preencha /home/pi/pb/camera.env e /home/pi/pb/whatsapp.env.' \
    'Depois execute: bash /home/pi/pb/start_bowl.sh'
  exit 0
fi

as_pi .venv/bin/python deploy/preflight.py config "$APP_DIR"
getent group spi >/dev/null || { printf 'Grupo spi ausente; habilite SPI com sudo raspi-config.\n' >&2; exit 2; }
[[ -c /dev/spidev0.0 ]] || { printf 'Habilite SPI com sudo raspi-config e reinicie: /dev/spidev0.0 ausente.\n' >&2; exit 2; }
usermod -aG spi "$APP_USER"
as_pi test -r /dev/spidev0.0
as_pi test -w /dev/spidev0.0

printf 'Instalando servicos com envio real de WhatsApp...\n'
install -m 644 deploy/bowl-capture.service deploy/bowl-notifier.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable bowl-capture.service bowl-notifier.service
# Do not wait forever for a phone that is still starting. systemd retries.
# Stop notifier first so reconfiguration cannot consume a previous snapshot.
systemctl stop bowl-notifier.service
systemctl stop bowl-capture.service
systemctl start --no-block bowl-capture.service bowl-notifier.service
printf '%s\n' \
  'Inicializacao solicitada; os dois servicos tambem iniciarao no proximo boot.' \
  'A camera sera verificada antes da captura. Se indisponivel, nova tentativa em 5 s.' \
  'Confira: systemctl status bowl-capture bowl-notifier --no-pager' \
  'Logs: journalctl -u bowl-capture -u bowl-notifier -f' \
  'Resultado: cat /run/bowl/result.json' \
  'Estado WhatsApp: cat /var/lib/bowl-notifier/state.json'
