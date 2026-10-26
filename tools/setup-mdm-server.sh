#!/usr/bin/env bash
# MicroMDM server setup on mdm-appliance (run as ROOT):
#   su -c 'bash /tmp/setup-mdm-server.sh'
# Phase 2 of .kilo/plans/manual-mdm-self-restriction.md
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (su -c 'bash $0')" >&2; exit 1; }

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ZIP=/tmp/micromdm_v1.13.1.zip
ZIP_SHA=201b5c09faf55686feac4373fa5f69bd262689a9c74a3cca19d5291913650c37
ZT_IP=10.11.133.222
SERVER_URL="https://$ZT_IP"
CONF=/etc/micromdm
DATA=/var/db/micromdm

echo "==> Fetching MicroMDM v1.13.1"
if [ ! -f "$ZIP" ]; then
  curl -sL -o "$ZIP" \
    https://github.com/micromdm/micromdm/releases/download/v1.13.1/micromdm_v1.13.1.zip
fi
echo "$ZIP_SHA  $ZIP" | sha256sum -c - || { echo "checksum mismatch" >&2; exit 1; }

echo "==> Installing binaries"
unzip -o -q "$ZIP" -d /tmp/micromdm_build
install -m 0755 -o root -g root /tmp/micromdm_build/build/linux/micromdm /usr/local/bin/
install -m 0755 -o root -g root /tmp/micromdm_build/build/linux/mdmctl /usr/local/bin/

echo "==> Service user + dirs"
id micromdm >/dev/null 2>&1 || \
  useradd --system --home-dir "$DATA" --shell /usr/sbin/nologin micromdm
install -d -o micromdm -g micromdm -m 0750 "$DATA"
install -d -o root -g root -m 0755 "$CONF"

echo "==> Self-signed TLS cert (SAN: $ZT_IP, mdm-appliance.local)"
# Interim until a real domain + Let's Encrypt DNS-01 cert replaces it
# (swap the cert files + server URL later, then re-enroll).
if [ ! -f "$CONF/tls.crt" ]; then
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
    -subj "/CN=mdm-appliance" \
    -addext "subjectAltName=IP:$ZT_IP,DNS:mdm-appliance.local" \
    -keyout "$CONF/tls.key" -out "$CONF/tls.crt" >/dev/null 2>&1
fi
chown root:micromdm "$CONF/tls.key" && chmod 0640 "$CONF/tls.key"
chown root:root "$CONF/tls.crt" && chmod 0644 "$CONF/tls.crt"

echo "==> API key"
if [ ! -f "$CONF/env" ]; then
  umask 077
  {
    printf 'MICROMDM_SERVER_URL=%s\n' "$SERVER_URL"
    printf 'MICROMDM_API_KEY=%s\n' "$(openssl rand -hex 24)"
  } > "$CONF/env"
fi
chown root:root "$CONF/env" && chmod 0600 "$CONF/env"

echo "==> systemd unit"
tee /etc/systemd/system/micromdm.service >/dev/null <<EOF
[Unit]
Description=MicroMDM server
After=network-online.target zerotier-one.service
Wants=network-online.target

[Service]
User=micromdm
Group=micromdm
EnvironmentFile=$CONF/env
ExecStart=/usr/local/bin/micromdm serve \\
  -config-path $DATA \\
  -tls-cert $CONF/tls.crt \\
  -tls-key $CONF/tls.key \\
  -http-addr :443
Restart=always
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$DATA

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now micromdm
sleep 2

echo "==> Verify"
systemctl is-active micromdm
ss -ltn | grep ':443 ' || { echo "not listening on 443" >&2; exit 1; }
curl -sk "$SERVER_URL/" >/dev/null && echo "HTTPS homepage: OK"

API_KEY=$(sed -n 's/^MICROMDM_API_KEY=//p' "$CONF/env")
mdmctl config set -name mdm-appliance -api-token "$API_KEY" \
  -server-url "$SERVER_URL" -skip-verify
mdmctl get devices

echo
echo "==> DONE"
echo "  Enrollment profile: $SERVER_URL/mdm/enroll"
echo "  API key (root only): $CONF/env"
echo "  Next: APNs push cert (mdmctl mdmcert vendor/check), then enroll the Mac."
