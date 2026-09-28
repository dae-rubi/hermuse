#!/usr/bin/env bash
# Deploy Hermuse ke Koyeb: Koyeb yang build Dockerfile di repo ini, lalu
# menjalankan 9Router + Hermes gateway di satu container 24/7.
#
# Cara pakai:
#   export KOYEB_API_TOKEN='<token dari app.koyeb.com/settings/api>'
#   export TELEGRAM_BOT_TOKEN='...' TELEGRAM_ALLOWED_USERS='123456789'
#   export NINEROUTER_PASSWORD='<password dashboard>'
#   bash scripts/deploy-koyeb.sh [nama-app]
#
# Idempotent: dijalankan lagi = update + redeploy service yang sama.
set -euo pipefail

APP="${1:-${KOYEB_APP:-hermuse}}"
SERVICE="${KOYEB_SERVICE:-hermuse}"
REGION="${KOYEB_REGION:-was}"
INSTANCE="${KOYEB_INSTANCE_TYPE:-small}"
GIT_REPO="${KOYEB_GIT_REPO:-github.com/imkofty/Hermuse}"
GIT_BRANCH="${KOYEB_GIT_BRANCH:-main}"
VOLUME="${KOYEB_VOLUME:-}"          # kosongkan = tanpa storage persisten
VOLUME_SIZE="${KOYEB_VOLUME_SIZE:-5}"
PORT=8000

log() { printf '\033[1;32m[koyeb]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[koyeb]\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "${KOYEB_API_TOKEN:-}" ] || die "KOYEB_API_TOKEN belum di-set."
[ -n "${TELEGRAM_BOT_TOKEN:-}" ] || die "TELEGRAM_BOT_TOKEN belum di-set."
[ -n "${TELEGRAM_ALLOWED_USERS:-}" ] || die "TELEGRAM_ALLOWED_USERS belum di-set (default-deny: tanpa ini bot menolak semua orang)."
[ -n "${NINEROUTER_PASSWORD:-}" ] || die "NINEROUTER_PASSWORD belum di-set — dashboard 9Router publik di Koyeb."

if ! command -v koyeb >/dev/null 2>&1; then
  log "Menginstall Koyeb CLI..."
  curl -fsSL https://raw.githubusercontent.com/koyeb/koyeb-cli/master/install.sh | sh
  export PATH="$HOME/.koyeb/bin:$PATH"
fi

# Secret disimpan di Koyeb, bukan sebagai env plaintext di definisi service.
put_secret() {
  local name="$1" value="$2"
  if koyeb secrets get "$name" >/dev/null 2>&1; then
    printf '%s' "$value" | koyeb secrets update "$name" --value-from-stdin >/dev/null
  else
    printf '%s' "$value" | koyeb secrets create "$name" --value-from-stdin >/dev/null
  fi
  log "secret $name ok"
}

put_secret hermuse-telegram-bot-token "$TELEGRAM_BOT_TOKEN"
put_secret hermuse-9router-password "$NINEROUTER_PASSWORD"

ARGS=(
  --git "$GIT_REPO"
  --git-branch "$GIT_BRANCH"
  --git-builder docker
  --git-docker-dockerfile Dockerfile
  --regions "$REGION"
  --instance-type "$INSTANCE"
  --ports "${PORT}:http"
  --routes "/:${PORT}"
  --checks "${PORT}:tcp"
  --checks-grace-period "${PORT}=90"
  --scale 1
  --env "TELEGRAM_BOT_TOKEN={{secret.hermuse-telegram-bot-token}}"
  --env "NINEROUTER_PASSWORD={{secret.hermuse-9router-password}}"
  --env "TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS}"
)
if [ -n "${HERMUSE_MODEL:-}" ]; then
  ARGS+=(--env "HERMUSE_MODEL=${HERMUSE_MODEL}")
fi

if [ -n "$VOLUME" ]; then
  koyeb volumes get "$VOLUME" >/dev/null 2>&1 || \
    koyeb volumes create "$VOLUME" --region "$REGION" --size "$VOLUME_SIZE" >/dev/null
  # /opt/data = seluruh state Hermes (sesi, memori, skills, .env).
  ARGS+=(--volumes "${VOLUME}:/opt/data")
  log "volume $VOLUME -> /opt/data"
else
  log "tanpa volume: state Hermes hilang tiap redeploy (set KOYEB_VOLUME untuk persisten)"
fi

if koyeb service get "$APP/$SERVICE" >/dev/null 2>&1; then
  log "Update service $APP/$SERVICE..."
  koyeb service update "$APP/$SERVICE" "${ARGS[@]}" --wait
else
  log "Create app + service $APP/$SERVICE..."
  koyeb app get "$APP" >/dev/null 2>&1 || koyeb app create "$APP" >/dev/null
  koyeb service create "$SERVICE" --app "$APP" "${ARGS[@]}" --wait
fi

log "Selesai. URL publik:"
koyeb app get "$APP"
log "Log runtime: koyeb service logs $APP/$SERVICE"
