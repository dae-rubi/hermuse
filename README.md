# Hermuse

**Hermuse = Hermes + Muse.** Repo ini berisi script dan panduan untuk menjalankan Hermes Agent (AI agent dari Nous Research) + 9Router + Telegram gateway di server sendiri — replika persis dari stack yang berjalan di VM Muse.

**Hasil akhirnya:** bot Telegram AI pribadi yang online 24/7 dan bisa kamu chat kapan saja, plus dashboard model yang bisa dibuka dari browser.

## Mulai dari sini (pemula)

Yang kamu butuhkan:

- VM Linux seperti VM Muse (Ubuntu 22.04/24.04; 2 vCPU / 4 GB RAM cukup)
- Akun Cloudflare gratis (untuk tunnel dashboard)
- Bot Telegram (bikin gratis via [@BotFather](https://t.me/BotFather))

Belum pernah install apa-apa? Ikuti urutan ini:

1. `bash scripts/install.sh` — install otomatis semuanya (dependensi, Hermes, 9Router)
2. `hermes setup --portal` — login model; `hermes gateway setup` — sambungkan bot Telegram
3. `bash scripts/setup-tunnel.sh <nama-pages-project> <nama-d1>` — pasang tunnel Cloudflare
4. Ikuti [Urutan boot](#urutan-boot-yang-benar) di bawah, lalu pasang watchdog di cron

Sudah paham dan mau langsung pakai script operasionalnya? Lihat tabel [Layout file](#layout-file).

## Arsitektur

```
Telegram (kamu)
   │ polling
   ▼
Hermes gateway  ──▶  model:
   (run-hermes.sh)        ├─▶ Nous (langsung, via OAuth / API key)
                          └─▶ 9Router  (127.0.0.1:20128, OpenAI-compatible)

Browser (internet)
   │ HTTPS biasa
   ▼
<project-kamu>.pages.dev  (Cloudflare Pages Functions)
   │ antrean request/response
   ▼
D1  (tabel tunnel_requests / tunnel_responses)
   ▲ polling HTTPS tiap ~400ms
   │
tunnel-client.mjs  (di VM)
   │ forward
   ▼
9Router di 127.0.0.1:20128
```

9Router hanya di-bind ke `127.0.0.1` (aman, tidak terekspos). Tunnel polling
dipakai karena di jaringan VM asal WebSocket, QUIC/UDP, dan koneksi `cloudflared`
ke edge semuanya gagal — lihat [arsip kegagalan](docs/arsip-tunnel-gagal.md).
Di VM/jaringan normal, `cloudflared` biasa kemungkinan justru lebih sederhana.

## Deploy ke Koyeb (tanpa VM sendiri)

Kalau tidak punya VM, seluruh stack bisa jalan 24/7 di [Koyeb](https://www.koyeb.com)
sebagai **satu container**: 9Router + Hermes gateway di dalamnya, HTTPS-nya
disediakan Koyeb (jadi tunnel Cloudflare di atas tidak diperlukan).

```
Browser  ──HTTPS──▶  <app>-<org>.koyeb.app
                          │  (Koyeb terminasi TLS, forward ke $PORT)
                          ▼
                     container Koyeb
                       ├─ 9router  -p $PORT -H 0.0.0.0   (dashboard + /v1)
                       └─ hermes gateway run  ──polling──▶ Telegram
                              └─ OPENAI_BASE_URL=http://127.0.0.1:$PORT/v1
```

Cara deploy:

```bash
export KOYEB_API_TOKEN='<token dari app.koyeb.com/settings/api>'
export TELEGRAM_BOT_TOKEN='<token @BotFather>'
export TELEGRAM_ALLOWED_USERS='123456789'      # numeric ID kamu (default-deny)
export NINEROUTER_PASSWORD='<password dashboard>'
export KOYEB_VOLUME=hermuse-data               # opsional tapi disarankan
bash scripts/deploy-koyeb.sh
```

Script-nya idempotent: sekali jalan membuat app + service, jalan berikutnya
meng-update dan redeploy service yang sama. Koyeb yang mem-build `Dockerfile`
di repo ini langsung dari GitHub, jadi tiap push ke `main` = redeploy otomatis.

Environment variable yang dikenali container:

| Variable | Default | Keterangan |
|---|---|---|
| `PORT` | `8000` (diisi Koyeb) | Port publik; 9Router bind ke sini. |
| `NINEROUTER_PASSWORD` | — | **Wajib.** Password dashboard 9Router (publik di Koyeb). |
| `TELEGRAM_BOT_TOKEN` | — | Tanpa ini gateway tidak dijalankan. |
| `TELEGRAM_ALLOWED_USERS` | — | Allowlist numeric ID; wajib, default-deny. |
| `HERMUSE_MODEL` / `HERMUSE_MODEL_PROVIDER` | — / `openai-api` | Set `model.default` & `model.provider` Hermes saat boot. |
| `HERMUSE_ROUTER_ENABLED` | `1` | `0` = tanpa 9Router (Hermes langsung ke provider). |
| `HERMUSE_GATEWAY_ENABLED` | `1` | `0` = hanya 9Router. |
| `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `NOUS_API_KEY`, `BRAVE_API_KEY` | — | Diteruskan ke `.env` Hermes kalau di-set. |

Catatan penting:

- **State Hermes ada di `/opt/data`** (sesi, memori, skills, `.env`). Filesystem
  container ephemeral — tanpa volume, semuanya hilang tiap redeploy. Set
  `KOYEB_VOLUME` supaya script membuat & memasang volume persisten ke sana.
- **Dashboard 9Router publik** di URL Koyeb. Selain `NINEROUTER_PASSWORD`, kamu
  bisa menambah basic auth di level Koyeb: `koyeb service update hermuse/hermuse
  --auth 'admin:{{secret.hermuse-9router-password}}'`.
- Secret (`TELEGRAM_BOT_TOKEN`, `NINEROUTER_PASSWORD`) disimpan sebagai **Koyeb
  secret**, bukan plaintext di definisi service.
- Test lokal sebelum deploy:
  `docker build -t hermuse . && docker run --rm -p 8000:8000 -e PORT=8000 -e NINEROUTER_PASSWORD=... hermuse`

## Layout file

| File | Peran |
|---|---|
| `run-hermes.sh` | Menjalankan Hermes CLI via venv provisioned (set `HERMES_HOME`, `no_proxy` minimal). Sesuaikan `HERMES_VENV` / `HERMES_SRC` di atas file. |
| `start-gateway.sh` | Menjalankan Telegram gateway detached (`setsid`+`nohup`). |
| `start-9router.sh` | Supervisor 9Router: bind `127.0.0.1:20128`, auto-restart saat crash. Password dashboard dibaca dari file `.dashboard-pw` (600). |
| `start-pages-tunnel.sh` | Supervisor tunnel client (`tunnel-client.mjs`), auto-restart. |
| `restart-9router.sh` | Kill proses 9Router lama (pola aman, anti self-kill) + jalankan supervisor detached. |
| `restart-tunnel.sh` | Kill tunnel client lama + jalankan supervisor detached. |
| `watchdog.sh` | Cek 9Router, tunnel client, gateway; restart yang mati. Untuk cron. |
| `tunnel-client.mjs` | Client polling: ambil antrean dari Pages, forward ke 9Router lokal, kirim respons balik. |
| `tunnel/` | Skema D1 (`schema.sql`) + Pages Functions + `wrangler.toml.example`. |
| `scripts/install.sh` | Install dari nol: dependensi, Node.js LTS, Hermes, 9Router. |
| `scripts/setup-tunnel.sh` | Setup tunnel: generate key → buat D1 → deploy Pages → set secret. |
| `docs/arsip-tunnel-gagal.md` | Arsip: `cloudflared` & Tailscale yang gagal di jaringan VM asal. |
| `Dockerfile` | Image Koyeb: base image resmi Hermes + 9Router. |
| `docker/hermuse-start.sh` | Entrypoint container: tulis `.env`, jalankan 9Router di `$PORT` + gateway Telegram. |
| `scripts/deploy-koyeb.sh` | Deploy/update app + service Koyeb (secret, volume, health check). |

## Urutan boot yang benar

Jalankan berurutan (cukup sekali; supervisor + watchdog yang menjaga sisanya):

```bash
# 1. 9Router dulu (supervisor detached, auto-restart)
bash restart-9router.sh

# 2. Tunnel client (butuh TUNNEL_BASE_URL atau file .tunnel-url)
export TUNNEL_BASE_URL='https://<project-kamu>.pages.dev'
bash restart-tunnel.sh

# 3. Telegram gateway (detached)
bash start-gateway.sh
```

Verifikasi:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:20128/dashboard  # harus 200
pgrep -f "tunnel-client.mjs"     # harus ada PID
ps aux | grep "[g]ateway.*run"   # harus ada proses gateway
```

Lalu buka `https://<project-kamu>.pages.dev` di browser — dashboard 9Router
harus muncul. Kalau dapat `504 tunnel timeout (client offline?)`, berarti
tunnel client belum jalan.

## Watchdog (cron tiap 5 menit)

```bash
crontab -e
# tambahkan baris ini (sesuaikan path):
*/5 * * * * /path/ke/Hermuse/watchdog.sh
```

Watchdog mengecek tiga hal — 9Router (`curl` ke `/dashboard`), tunnel client
(`pgrep tunnel-client.mjs`), gateway Telegram (`gateway.*run`) — dan me-restart
yang mati via script `restart-*`. Ia diam (tidak menulis log) kalau semua sehat;
hanya mencatat saat benar-benar me-restart.

> Untuk cron: simpan URL tunnel di file `.tunnel-url` (chmod 600) di folder ini,
> karena cron tidak mewarisi environment variable interaktif:
> `echo -n 'https://<project-kamu>.pages.dev' > .tunnel-url && chmod 600 .tunnel-url`

## Install dari nol

Belum punya apa-apa? Mulai dari sini:

```bash
bash scripts/install.sh        # dependensi + Node.js + Hermes + 9Router + hermes doctor
```

Lalu setup provider model & Telegram gateway (wizard):

```bash
hermes setup --portal   # login Nous via OAuth (atau: hermes model untuk pilih provider)
hermes gateway setup    # isi token bot Telegram + allowlist numeric ID
```

Terakhir, setup tunnel Cloudflare-nya:

```bash
CLOUDFLARE_API_TOKEN='<token>' bash scripts/setup-tunnel.sh <nama-pages-project> <nama-d1>
```

(Token Cloudflare dipakai transient saja — tidak disimpan di file mana pun.)

## Yang gagal di jaringan ini (arsip)

Di jaringan VM asal, dua pendekatan standar **gagal total**:

- **Cloudflare Tunnel (`cloudflared`)** — QUIC/UDP diblokir, TLS ke edge IP di-intercept, proxy menolak CONNECT ke port 7844.
- **Tailscale** — control plane gagal menembus jaringan (HTTP 400 akibat MITM).

Detail + contoh config yang disanitasi: [docs/arsip-tunnel-gagal.md](docs/arsip-tunnel-gagal.md).
Di VM/jaringan normal keduanya kemungkinan justru cara termudah.

## Keamanan — jangan dilewatkan

- File berisi secret **selalu `chmod 600`** dan **tidak pernah di-commit**:
  `.env`, `.tunnel-key`, `.tunnel-url`, `.dashboard-pw`, `wrangler.toml`
  (sudah tercakup di `.gitignore`).
- Telegram gateway: **default-deny**. Hanya numeric ID di `TELEGRAM_ALLOWED_USERS`
  yang bisa memakai bot (`TELEGRAM_BOT_TOKEN` + `TELEGRAM_ALLOWED_USERS` di `.env`).
- **Ganti password dashboard 9Router dari default** segera setelah install —
  apalagi URL tunnel-nya publik.
- Jangan expose port 20128 ke internet tanpa proteksi; 9Router di-bind ke
  `127.0.0.1` saja.
- Kalau token bot Telegram bocor: `/revoke` di @BotFather, ganti di `.env`,
  restart gateway.
