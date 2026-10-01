#!/usr/bin/env bash
# check_bowl.sh -- verificacao unica, sob demanda, do monitor de racao.
#
# Faz, em sequencia, num unico comando:
#   1. garante o .venv e os pacotes Python (instala SO quando ausentes);
#   2. verifica a camera (snapshot + conversao GRAY8);
#   3. verifica a FPGA (uma transacao SPI real via cliente Assembly) e classifica;
#   4. se o pote estiver VAZIO, chama o bowl_notifier.py, que aplica a politica
#      de episodio e dispara a notificacao no celular (WhatsApp/Twilio).
#
# A logica de envio NAO e duplicada aqui: este script apenas orquestra e delega
# a notificacao ao bowl_notifier.py. Nao instala servicos systemd e nao fica em
# loop: roda uma vez e encerra.
#
# Uso:
#   bash /home/pi/pb/integration/check_bowl.sh            # verifica e, se vazio, notifica
#   bash /home/pi/pb/integration/check_bowl.sh --dry-run  # verifica mas NAO envia
#
# Codigo de saida:
#   0  -> pote VAZIO (notificacao delegada ao bowl_notifier, salvo --dry-run)
#   10 -> pote NAO vazio
#   1  -> falha (venv, camera, FPGA/SPI ou configuracao) -- detalhe na tela
set -Eeuo pipefail

APP_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)   # .../integration
ASM_DIR=$(cd -- "$APP_DIR/../assembly" && pwd)
VENV="$APP_DIR/.venv"
PY="$VENV/bin/python"
CLIENT="$ASM_DIR/build/bin/spi_image_client"
DEVICE=${DEVICE:-/dev/spidev0.0}
RESULT_JSON=/dev/shm/check_bowl_result.json
NOTIFIER_STATE="$APP_DIR/check_bowl_state.json"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

ok()   { printf '[OK] %s\n' "$*"; }
info() { printf '%s\n' "$*"; }
fail() { printf '[FALHA] %s\n' "$*" >&2; exit 1; }

# --- 1. venv e pacotes: instala SO quando ausentes --------------------------
NEED_INSTALL=0
if [[ ! -x "$PY" ]]; then
  info "venv ausente; criando em $VENV..."
  command -v python3 >/dev/null || fail "python3 nao encontrado. Instale: sudo apt install -y python3-venv"
  python3 -m venv "$VENV" || fail "nao foi possivel criar o venv"
  NEED_INSTALL=1
fi
# Confere se os pacotes de runtime importam; se nao, (re)instala do requirements.
if ! "$PY" -c 'import twilio.rest, dotenv' >/dev/null 2>&1; then
  NEED_INSTALL=1
fi
if [[ $NEED_INSTALL -eq 1 ]]; then
  info "instalando pacotes Python (requirements.txt)..."
  "$PY" -m pip install --disable-pip-version-check -r "$APP_DIR/deploy/requirements.txt" \
    || fail "falha ao instalar dependencias Python"
fi
ok "venv e pacotes prontos"

# --- config: le camera.env ---------------------------------------------------
ENV_FILE="$APP_DIR/camera.env"
[[ -f "$ENV_FILE" ]] || fail "camera.env ausente em $APP_DIR (copie de deploy/camera.env.example e preencha)"
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a
[[ -n "${CAMERA_URL:-}" ]] || fail "CAMERA_URL nao definido em camera.env"
[[ -n "${THRESHOLD:-}" ]]  || fail "THRESHOLD nao definido em camera.env"

# --- 2. verificar a camera ---------------------------------------------------
info "Verificando camera..."
"$PY" "$APP_DIR/deploy/preflight.py" camera "$APP_DIR" || fail "camera indisponivel ou imagem invalida"
ok "camera respondeu e converteu para GRAY8"

# --- 3. verificar a FPGA + classificar uma foto ------------------------------
[[ -x "$CLIENT" ]] || fail "cliente Assembly nao compilado em $CLIENT (rode: make -C $ASM_DIR)"
info "Verificando FPGA e classificando uma foto..."
RESULT=$("$PY" "$APP_DIR/camera_capture.py" \
  --url "$CAMERA_URL" --threshold "$THRESHOLD" \
  --client "$CLIENT" --device "$DEVICE" \
  --output "$RESULT_JSON" --once \
  ${CROP_ARGS:-} ${INVERT_ARGS:-} 2>/dev/null) || true
[[ -n "$RESULT" ]] || fail "cliente nao produziu resultado (verifique FPGA/fiacao SPI)"

# Extrai valid, estado e contagens do JSON (sem depender de jq).
read -r VALID STATE BRIGHT TOTAL < <("$PY" - "$RESULT" <<'PYEOF'
import json, sys
try:
    r = json.loads(sys.argv[1])
except Exception:
    print('nao unknown 0 0'); sys.exit(0)
print(('sim' if r.get('valid') else 'nao'),
      r.get('bowl_state', 'unknown'),
      r.get('pixels_bright', 0), r.get('pixels_total', 0))
PYEOF
)
[[ "$VALID" == "sim" ]] || fail "classificacao invalida; FPGA/SPI nao respondeu corretamente"
ok "FPGA respondeu: claros=$BRIGHT/$TOTAL"

# --- 4. resultado + notificacao (delegada ao bowl_notifier.py) ---------------
if [[ "$STATE" != "empty" ]]; then
  info "Pote nao esta vazio. Nada a notificar."
  exit 10
fi

info ">>> POTE VAZIO <<<"

# Monta os argumentos do notifier. --confirm 1 porque esta e uma verificacao
# unica (uma foto ja e a confirmacao); o bowl_notifier ainda aplica o controle
# de episodio via --state para nao repetir a mensagem em execucoes seguidas.
NOTIFY_ARGS=(--input "$RESULT_JSON" --state "$NOTIFIER_STATE"
             --confirm 1 --rearm 1 --max-age 3600 --once)
if [[ $DRY_RUN -eq 1 ]]; then
  info "[dry-run] delegando ao bowl_notifier sem enviar..."
  "$PY" "$APP_DIR/bowl_notifier.py" "${NOTIFY_ARGS[@]}" || fail "bowl_notifier falhou (dry-run)"
else
  info "Disparando notificacao via bowl_notifier.py..."
  "$PY" "$APP_DIR/bowl_notifier.py" "${NOTIFY_ARGS[@]}" --send || fail "bowl_notifier falhou ao enviar"
fi
exit 0
