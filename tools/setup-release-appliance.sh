#!/usr/bin/env bash
# Configure the Debian appliance as a read-only signed-release server.
set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }

REPO=$(cd "$(dirname "$0")/.." && pwd)
CONF=/etc/chickenblocker-release
DATA=/var/lib/chickenblocker-release
PUBLIC=$DATA/public
KEY=$CONF/signing-key.pem
PUB=$CONF/signing-public.pem
SERVICE_USER=cb-release
ZT_IP=${CB_RELEASE_BIND_IP:-10.11.133.222}
PORT=${CB_RELEASE_PORT:-8443}

command -v python3 >/dev/null || { echo "ERROR: python3 is required" >&2; exit 1; }
command -v openssl >/dev/null || { echo "ERROR: openssl is required" >&2; exit 1; }

id "$SERVICE_USER" >/dev/null 2>&1 || \
  useradd --system --home-dir "$DATA" --shell /usr/sbin/nologin "$SERVICE_USER"
install -d -o root -g root -m 0700 "$CONF"
install -d -o root -g root -m 0755 "$DATA" "$PUBLIC" "$PUBLIC/payloads"

if [[ ! -f $KEY ]]; then
  umask 077
  openssl genrsa -out "$KEY" 3072
fi
chmod 0600 "$KEY"
chown root:root "$KEY"
openssl rsa -in "$KEY" -pubout -out "$PUB" >/dev/null 2>&1
chmod 0644 "$PUB"
chown root:root "$PUB"
install -m 0644 -o root -g root "$PUB" "$PUBLIC/signing-public.pem"

install -m 0755 -o root -g root "$REPO/tools/publish-release.py" \
  /usr/local/sbin/cb-publish-release

cat > /etc/systemd/system/chickenblocker-release.service <<EOF
[Unit]
Description=ChickenBlocker signed release service
After=network-online.target zerotier-one.service
Wants=network-online.target

[Service]
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=/usr/bin/python3 -m http.server $PORT --bind $ZT_IP --directory $PUBLIC
Restart=always
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now chickenblocker-release

echo "Signing public-key fingerprint:"
openssl pkey -pubin -in "$PUB" -outform DER | sha256sum
echo
echo "Release URL: http://$ZT_IP:$PORT"
echo "Publish with: cb-publish-release --bundle DIR --sequence N"
echo "Firewall port $PORT to the ZeroTier interface before relying on this service."
