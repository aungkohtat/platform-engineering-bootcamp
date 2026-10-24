#!/usr/bin/env bash
# Every node, optional: a Beszel agent so the hub on the lab host graphs each VM.
# WebSocket mode: the agent dials the hub. The reverse (hub dialing NODE_IP:45876) is
# blocked when the hub runs on macOS, whose Local Network privacy stops unsigned
# background services from opening LAN connections.
# Inputs (from the Vagrantfile): NODE_IP, BESZEL_KEY (the hub's public key),
# BESZEL_TOKEN (a universal token from the hub), BESZEL_HUB_URL.
set -euo pipefail
: "${BESZEL_TOKEN:?set BESZEL_TOKEN to a universal token from the hub}"
: "${BESZEL_HUB_URL:?set BESZEL_HUB_URL, e.g. http://192.168.1.120:8090}"

VERSION=0.21.0
ARCH=$(dpkg --print-architecture)
# Pinned from beszel_${VERSION}_checksums.txt so a swapped release asset fails the build.
case "$ARCH" in
    amd64) SHA256=898d67d456a4feed7d651bbac22def5eb41840d4f3d9bf058a5ed37c8c815599 ;;
    arm64) SHA256=82804205a370a790679e836c3c3d658bc804205517e1c3f676dba9fad064ade5 ;;
    *)
        echo "no beszel-agent build pinned for ${ARCH}" >&2
        exit 1
        ;;
esac

TARBALL=/tmp/beszel-agent.tar.gz
curl -fsSL -o "$TARBALL" \
    "https://github.com/henrygd/beszel/releases/download/v${VERSION}/beszel-agent_linux_${ARCH}.tar.gz"
echo "${SHA256}  ${TARBALL}" | sha256sum -c -
tar -xzf "$TARBALL" -C /usr/local/bin beszel-agent
rm -f "$TARBALL"

id beszel >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin beszel

# LISTEN keeps the SSH fallback on the LAN IP only, not the shared VirtualBox NAT address.
install -m 0640 -o root -g beszel /dev/null /etc/beszel-agent.env
printf 'KEY="%s"\nTOKEN="%s"\nHUB_URL="%s"\nLISTEN="%s:45876"\nDATA_DIR=/var/lib/beszel-agent\n' \
    "$BESZEL_KEY" "$BESZEL_TOKEN" "$BESZEL_HUB_URL" "$NODE_IP" >/etc/beszel-agent.env

cat >/etc/systemd/system/beszel-agent.service <<'EOF'
[Unit]
Description=Beszel agent
Wants=network-online.target
After=network-online.target

[Service]
User=beszel
StateDirectory=beszel-agent
EnvironmentFile=/etc/beszel-agent.env
ExecStart=/usr/local/bin/beszel-agent
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable beszel-agent
systemctl restart beszel-agent
