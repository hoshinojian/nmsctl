#!/bin/bash
# NMS droplet bootstrap template (ASCII-only per P70: DO user-data mangles
# non-ASCII into C1 control chars, which makes docker compose reject the YAML).
# Template copy lives in-repo with a __NODE_PASS__ placeholder and zero
# credentials; scripts/soak/rebuild/s2-nms.sh instantiates it into
# $REBUILD_DIR/nms-user-data6-ascii.sh (replacing __NODE_PASS__ with the
# env.local NODE_PASS) before `vpsctl create -user-data`. s2-repair.sh replays
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
echo 'root:__NODE_PASS__' | chpasswd
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart ssh || systemctl restart sshd
# (Port 2222 append removed: Ubuntu 24.04 sshd is socket-activated; custom Port in sshd_config is ignored. Mgmt channel = 22.)
emit "STAGE=apt"
timeout 300 apt-get update -y
timeout 600 apt-get install -y docker.io docker-compose-v2 stunnel4 python3
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
HTTP_ADDR=:80
AGENT_PATH=/opt/nms/agents/nms-agent-linux
ENVEOF
emit "STAGE=unit"
cat > /etc/systemd/system/nms.service <<'UNITEOF'
# NMS server systemd unit (nms-deploy 5).
# /etc/systemd/system/nms.service.
# postgresql.service only relevant for plan B; plan A (Docker PG) relies on
# NMS 60s PG-wait retry (#42) -- keeping this line is harmless, do not rely on it.
[Unit]
Description=NMS (Network Management System)
After=network.target postgresql.service

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
connect = 127.0.0.1:22
STCONF
systemctl restart stunnel4 || stunnel4 /etc/stunnel/ssh-443.conf
emit "BOOTSTRAP-OK"
mkdir -p /var/log/soak
(setsid python3 -m http.server 18081 --directory /var/log/soak --bind 0.0.0.0 >/dev/null 2>&1 &)
