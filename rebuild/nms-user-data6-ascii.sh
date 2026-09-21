#!/bin/bash
# NMS droplet bootstrap template (ASCII-only per P70: DO user-data mangles
# non-ASCII into C1 control chars, which makes docker compose reject the YAML).
# Template copy lives in-repo with __NODE_PASS__/__AUTHORIZED_KEY__/__SSHD_PORT__
# placeholders and zero credentials; scripts/soak/rebuild/s2-nms.sh instantiates
# it into $REBUILD_DIR/nms-user-data6-ascii.sh (via lib/env.sh
# instantiate_user_data) before `vpsctl create -user-data`. s2-repair.sh replays
# the same instantiated runtime copy. Do not put real secrets in this file.
set -Eeuxo pipefail
STATUS=/var/log/bootstrap-status
emit() { printf '%s t=%s\n' "$1" "$(date +%s)" > "$STATUS"; }
trap 'emit "BOOTSTRAP-FAILED rc=$? line=$LINENO"' ERR
mkdir -p /var/log/soak
exec > /var/log/bootstrap.log 2>&1
emit "STAGE=init"
# (ascii-only: non-ascii comment dropped)
(setsid python3 -m http.server 18081 --directory /var/log --bind 0.0.0.0 >/dev/null 2>&1 &)
export DEBIAN_FRONTEND=noninteractive
mkdir -p /var/log/soak /opt/nms/agents /opt/nms/backups /root/.ssh
chmod 700 /root/.ssh
echo '__AUTHORIZED_KEY__' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
# (v3.4 bootstrap-log leak seal #1: chpasswd under xtrace echoes the plaintext password
#  into the log that 18081 used to serve publicly — no-x the sensitive span.)
set +x
echo 'root:__NODE_PASS__' | chpasswd
set -x
# v3.4 high-port sshd (zero-firewall baseline): Ubuntu 24.04 ships ssh.socket
# (socket activation) which ignores Port in sshd_config (P7) — disable socket
# activation, run ssh.service directly, then bind the drill port.
# NMS hardening (v3.4): pubkey-only root (break-glass leg keeps working via key;
# password stays valid on the DO console only). Nodes keep password auth
# (product behavior, see node-user-data template).
systemctl disable --now ssh.socket 2>/dev/null || true
systemctl enable ssh.service >/dev/null 2>&1 || true
cat > /etc/ssh/sshd_config.d/99-soak.conf <<'SSHEOF'
Port __SSHD_PORT__
PasswordAuthentication no
PermitRootLogin prohibit-password
SSHEOF
systemctl restart ssh.service || systemctl restart sshd
emit "STAGE=apt"
timeout 300 apt-get update -y
timeout 600 apt-get install -y docker.io docker-compose-v2 stunnel4 python3 wireguard-tools
systemctl enable --now docker
cat > /opt/nms/docker-compose.yml <<'COMPOSEEOF'
# PG+TimescaleDB, same as local dev (nms-deploy 6.1 plan A).
# Bind 127.0.0.1 only (#43); remote debug via SSH tunnel.
# Explicit project name nms to avoid compose namespace clash.
name: nms

services:
  timescaledb:
    image: timescale/timescaledb:2.17.2-pg16
    container_name: nms-timescaledb
    environment:
      POSTGRES_USER: nms
      POSTGRES_PASSWORD: nms
      POSTGRES_DB: nms
    ports:
      - "127.0.0.1:5432:5432"
    volumes:
      - nms_pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U nms -d nms"]
      interval: 5s
      timeout: 5s
      retries: 12
    restart: unless-stopped

volumes:
  nms_pgdata:

COMPOSEEOF
emit "STAGE=compose"
cd /opt/nms && docker compose up -d
sleep 10
docker exec nms-timescaledb pg_isready -U nms || true
cat > /opt/nms/.env <<'ENVEOF'
PG_DSN=postgres://nms:nms@localhost:5432/nms?sslmode=disable
# v3.4: :80 binds the WG tunnel address ONLY (single-listener product, user-ratified).
# Public :80 is gone from the root; NMS-local consumers curl 10.100.0.1:80 too.
HTTP_ADDR=10.100.0.1:80
AGENT_PATH=/opt/nms/agents/nms-agent-linux
ENVEOF
emit "STAGE=wireguard"
# WG overlay (v3.4): single edge orchestrator<->NMS. Keys arrive via user-data
# placeholders (quoted heredoc body: never echoed by xtrace into bootstrap.log).
mkdir -p /etc/wireguard
cat > /etc/wireguard/wg0.conf <<'WGEOF'
[Interface]
Address = 10.100.0.1/24
ListenPort = 51820
MTU = 1420
PrivateKey = __WG_PRIV__
[Peer]
PublicKey = __WG_PEER_PUB__
AllowedIPs = 10.100.0.2/32
WGEOF
chmod 600 /etc/wireguard/wg0.conf
systemctl enable --now wg-quick@wg0
emit "STAGE=unit"
cat > /etc/systemd/system/nms.service <<'UNITEOF'
# NMS server systemd unit (nms-deploy 5).
# /etc/systemd/system/nms.service.
# postgresql.service only relevant for plan B; plan A (Docker PG) relies on
# NMS 60s PG-wait retry (#42) -- keeping this line is harmless, do not rely on it.
# v3.4: nms binds 10.100.0.1:80 (wg0) — Require wg0 so it never starts into a
# missing address (bind-fail crash loop).
[Unit]
Description=NMS (Network Management System)
Requires=wg-quick@wg0.service
After=network.target wg-quick@wg0.service postgresql.service

[Service]
Type=simple
WorkingDirectory=/opt/nms
EnvironmentFile=/opt/nms/.env
ExecStart=/opt/nms/nms
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target

UNITEOF
systemctl daemon-reload
systemctl enable --now nms
sleep 3
systemctl is-active nms || true
emit "STAGE=stunnel"
openssl req -new -x509 -days 30 -nodes -subj "/CN=soak-nms" -keyout /etc/ssl/private/stunnel.key -out /etc/ssl/private/stunnel.crt
cat /etc/ssl/private/stunnel.key /etc/ssl/private/stunnel.crt > /etc/ssl/private/stunnel.pem
chmod 600 /etc/ssl/private/stunnel.pem
echo 'ENABLED=1' > /etc/default/stunnel4
cat > /etc/stunnel/ssh-443.conf <<'STCONF'
cert = /etc/ssl/private/stunnel.pem
key = /etc/ssl/private/stunnel.pem
[ssh-443]
accept = 443
connect = 127.0.0.1:__SSHD_PORT__
STCONF
systemctl restart stunnel4 || stunnel4 /etc/stunnel/ssh-443.conf
# (v3.4 leak seal #2: 18081 binds loopback only and serves /var/log/soak — bootstrap.log
#  is not in that tree and secrets never echo (quoted heredocs + chpasswd no-x), so the
#  ISS-008 defensive scrub was removed: sed -i swaps the log inode while the exec redirect
#  still points at the old one, orphaning every later line incl. the BOOTSTRAP-OK marker.)
emit "BOOTSTRAP-OK"
mkdir -p /var/log/soak
(setsid python3 -m http.server 18081 --directory /var/log/soak --bind 127.0.0.1 >/dev/null 2>&1 &)
