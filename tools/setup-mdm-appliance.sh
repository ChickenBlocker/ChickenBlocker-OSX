#!/usr/bin/env bash
# mdm-appliance setup: Phases 2-3 of .kilo/plans/mdm-appliance-install.md
# Run as ROOT on the appliance:
#   su -c 'bash /tmp/setup-mdm-appliance.sh'
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (su -c 'bash $0')" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

echo "==> Lean APT config"
tee /etc/apt/apt.conf.d/99lean >/dev/null <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
EOF

echo "==> Update + full upgrade"
apt-get update
apt-get full-upgrade -y

echo "==> Install packages (Phase 2 + avahi for mDNS)"
apt-get install --no-install-recommends -y \
  ca-certificates curl wget jq openssl gpg gpgv git rsync sqlite3 \
  unzip xz-utils zstd tmux nano openssh-server \
  util-linux parted gdisk dosfstools e2fsprogs exfatprogs ntfs-3g \
  btrfs-progs xfsprogs lvm2 cryptsetup-bin mdadm testdisk gddrescue \
  smartmontools nvme-cli hdparm bmap-tools pv mc ncdu btop \
  avahi-daemon

echo "==> Console-only boot"
systemctl set-default multi-user.target

echo "==> Hostname -> mdm-appliance + mDNS"
hostnamectl set-hostname mdm-appliance
systemctl enable --now avahi-daemon
systemctl restart avahi-daemon

echo "==> ZeroTier"
if ! command -v zerotier-cli >/dev/null 2>&1; then
  curl -s https://install.zerotier.com | bash
fi
systemctl enable --now zerotier-one
sleep 3
zerotier-cli join 743993800f857561 || echo "(already joined)"

echo
echo "==> DONE. Remaining manual steps:"
echo "  1. Authorize this member in ZeroTier Central and reserve a fixed"
echo "     10.11.133.x IP (Do Not Auto-Assign from Pool)"
echo "  2. Check: zerotier-cli listnetworks  (want REQUESTING/OK)"
echo "  3. Reboot recommended after full-upgrade: systemctl reboot"
