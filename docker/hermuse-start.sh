#!/bin/bash
# Entrypoint Hermuse untuk Koyeb (dan runtime container lain).
#
# Menjalankan dua proses di satu container:
#   1. 9Router  — OpenAI-compatible router + dashboard, di-bind ke $PORT
#                 (port publik Koyeb; TLS diterminasi Koyeb).
#   2. Hermes   — `hermes gateway run`, polling Telegram (outbound saja).
#
# Semua konfigurasi datang dari environment variable karena filesystem Koyeb
# ephemeral: .env dan config.yaml ditulis ulang tiap boot ke $HERMES_HOME.
set -uo pipefail

log() { printf '[hermuse] %s\n' "$*"; }
die() { printf '[hermuse] FATAL: %s\n' "$*" >&2; exit 1; }

PORT="${PORT:-8000}"
DATA_DIR="${HERMES_HOME:-/opt/data}"
ENV_FILE="$DATA_DIR/.env"
HERMES_BIN="${HERMES_BIN:-/opt/hermes/.venv/bin/hermes}"
ROUTER_ENABLED="${HERMUSE_ROUTER_ENABLED:-1}"
ROUTER_URL="http://127.0.0.1:${PORT}/v1"
GATEWAY_ENABLED="${HERMUSE_GATEWAY_ENABLED:-1}"

mkdir -p "$DATA_DIR"

# --- .env ---------------------------------------------------------------
# Upsert supaya key yang sudah ada di volume persisten tidak terduplikasi,
# dan nilai baru dari Koyeb secret selalu menang.
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

set_env_var() {
  local key="$1" value="$2" tmp
  [ -n "$value" ] || return 0
  tmp="$(mktemp)"
  grep -v "^${key}=" "$ENV_FILE" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
}

# Kredensial yang diteruskan apa adanya dari environment ke .env Hermes.
PASSTHROUGH_KEYS="TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USERS DISCORD_BOT_TOKEN \
SLACK_BOT_TOKEN OPENAI_API_KEY OPENAI_BASE_URL OPENROUTER_API_KEY \
ANTHROPIC_API_KEY NOUS_API_KEY BRAVE_API_KEY"

for key in $PASSTHROUGH_KEYS; do
  set_env_var "$key" "${!key:-}"
done

if [ "$ROUTER_ENABLED" = "1" ]; then
  # Hermes bicara ke 9Router lewat loopback; 9Router yang memegang kredensial
  # provider sebenarnya, jadi key di sisi Hermes boleh placeholder.
  set_env_var OPENAI_BASE_URL "$ROUTER_URL"
  set_env_var OPENAI_API_KEY "${OPENAI_API_KEY:-9router-local}"
fi

# --- config.yaml --------------------------------------------------------
# Image sudah men-seed config.yaml saat cont-init, jadi kita hanya menimpa
# dua field yang menentukan ke mana inference dikirim.
if [ -n "${HERMUSE_MODEL:-}" ]; then
  log "config: model.default=${HERMUSE_MODEL} provider=${HERMUSE_MODEL_PROVIDER:-openai-api}"
  "$HERMES_BIN" config set model.default "$HERMUSE_MODEL" || log "gagal set model.default"
  "$HERMES_BIN" config set model.provider "${HERMUSE_MODEL_PROVIDER:-openai-api}" || log "gagal set model.provider"
fi

# --- supervisi ----------------------------------------------------------
declare -a CHILDREN=()

shutdown() {
  log "shutting down"
  for pid in "${CHILDREN[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait
  exit 0
}
trap shutdown TERM INT

# Loop restart sederhana: proses yang mati dihidupkan lagi setelah jeda,
# tapi kalau gagal terus-menerus container dibiarkan exit supaya Koyeb
# me-restart instance-nya (dan kegagalan terlihat di health check).
supervise() {
  local name="$1"; shift
  local failures=0 started
  while true; do
    started="$(date +%s)"
    log "starting $name"
    "$@"
    log "$name exited (code $?)"
    if [ $(( $(date +%s) - started )) -ge 60 ]; then
      failures=0
    else
      failures=$(( failures + 1 ))
    fi
    if [ "$failures" -ge 5 ]; then
      die "$name crashed 5x in a row"
    fi
    sleep 5
  done
}

if [ "$ROUTER_ENABLED" = "1" ]; then
  [ -n "${NINEROUTER_PASSWORD:-}" ] || log "PERINGATAN: NINEROUTER_PASSWORD kosong — 9Router memakai password default. Dashboard-nya publik di Koyeb; set secret ini."
  export INITIAL_PASSWORD="${NINEROUTER_PASSWORD:-}"
  supervise 9router 9router -p "$PORT" -H 0.0.0.0 -n -l --skip-update &
  CHILDREN+=("$!")
fi

if [ "$GATEWAY_ENABLED" = "1" ]; then
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
    log "PERINGATAN: TELEGRAM_BOT_TOKEN kosong — gateway Telegram tidak dijalankan."
  elif [ -d /run/service ]; then
    # Di image s6, `gateway run` menyerahkan proses ke s6-supervise lalu
    # langsung return — s6 yang menjaga & me-restart-nya, bukan kita.
    log "starting gateway (supervised by s6)"
    "$HERMES_BIN" gateway run || log "gateway gagal start — lihat log di $DATA_DIR/logs/gateways/default/current"
  else
    supervise gateway "$HERMES_BIN" gateway run &
    CHILDREN+=("$!")
  fi
fi

if [ "${#CHILDREN[@]}" -eq 0 ]; then
  # Router mati & gateway dipegang s6: container tetap hidup sebagai heartbeat,
  # sama seperti CMD `gateway run` bawaan image.
  log "tidak ada proses foreground — idle (gateway dipegang s6)"
  exec sleep infinity
fi

wait -n "${CHILDREN[@]}"
log "supervisor berhenti — container exit supaya Koyeb restart instance"
shutdown
