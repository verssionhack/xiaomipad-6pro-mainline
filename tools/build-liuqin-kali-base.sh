#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Build the Kali Linux Rolling arm64 base rootfs used by
# tools/build-liuqin-native-root.sh.  The project no longer mirrors a pinned
# tarball, so this reconstructs the "main + default desktop" base from the
# Kali repository:
#
#   stage 1  debootstrap the minimal arm64 base (foreign, no second stage)
#   stage 2  chroot: second stage + GNOME desktop + Kali default toolset
#
# Re-runnable: each stage is skipped when its marker is present.  Run as root
# (device-node and ownership fidelity need it):
#
#   sudo sh tools/build-liuqin-kali-base.sh [stage1|stage2|all]
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
input_dir=${KALI_ROOT_INPUT:-"$project_root/tools/local/kali-rootfs-arm64"}
rootfs=${KALI_ROOT_ROOTFS:-"$input_dir/rootfs"}
# Aliyun mirror by default (fast from the CJK network; http.kali.org is slow
# and resolves to an unrouted IPv6). Override with KALI_MIRROR if needed.
mirror=${KALI_MIRROR:-http://mirrors.aliyun.com/kali}
suite=${KALI_SUITE:-kali-rolling}
marker=$input_dir/base.installed

die() { printf 'build-liuqin-kali-base: %s\n' "$*" >&2; exit 1; }
say() { printf 'build-liuqin-kali-base: %s\n' "$*"; }

[ "$(id -u)" = 0 ] || die 'run as root (sudo $0)'
command -v debootstrap >/dev/null || die 'debootstrap is required'

stage1() {
	if [ -x "$rootfs/usr/bin/systemd" ] || [ -e "$rootfs/debootstrap/debootstrap" ]; then
		say 'stage1: base already present, skipping'
		return
	fi
	mkdir -p "$rootfs"
	say "stage1: debootstrap $suite arm64 -> $rootfs (mirror $mirror)"
	debootstrap --arch=arm64 --foreign \
		--components=main,contrib,non-free,non-free-firmware \
		"$suite" "$rootfs" "$mirror"
	say 'stage1 PASS'
}

stage2() {
	if [ -x "$rootfs/usr/lib/systemd/systemd" ] && [ -f "$marker" ]; then
		say 'stage2: desktop already installed, skipping'
		return
	fi
	[ -x "$rootfs/usr/lib/systemd/systemd" ] || [ -e "$rootfs/debootstrap/debootstrap" ] ||
		die 'run stage1 first'
	cp -L /etc/resolv.conf "$rootfs/etc/resolv.conf"
	mount -t proc proc "$rootfs/proc"
	mount -t sysfs sysfs "$rootfs/sys"
	mount --bind /dev "$rootfs/dev"
	mount --bind /dev/pts "$rootfs/dev/pts" 2>/dev/null || true
	mount -t tmpfs tmpfs "$rootfs/dev/shm" 2>/dev/null || true
	# Keep package postinst scripts from starting daemons inside the chroot;
	# they would fail without a full runtime and leave dbus-daemon (and its
	# dependents gdm3, libpam-systemd, ...) unconfigured.  systemd-tmpfiles in
	# those postinst scripts also needs /proc and /sys mounted.
	printf '#!/bin/sh\nexit 101\n' >"$rootfs/usr/sbin/policy-rc.d"
	chmod 0755 "$rootfs/usr/sbin/policy-rc.d"
	trap 'rm -f "$rootfs/usr/sbin/policy-rc.d"; umount "$rootfs/dev/shm" \
		"$rootfs/dev/pts" "$rootfs/dev" "$rootfs/sys" "$rootfs/proc" 2>/dev/null || :' EXIT
	# Enable Kali's full component set. The base debootstrap only enables main,
	# but the default metapackage depends on zenmap (non-free) and several other
	# tools land in non-free/contrib; without them the desktop install dead-ends
	# on "zenmap is not installable".
	printf 'deb %s %s main contrib non-free non-free-firmware\n' "$mirror" "$suite" \
		>"$rootfs/etc/apt/sources.list"
	# Pin apt to IPv4 (the host resolves the mirror to an unrouted IPv6, which
	# dead-ends .deb fetches on "network unreachable").
	printf 'Acquire::ForceIPv4 "true";\n' >"$rootfs/etc/apt/apt.conf.d/99-liuqin-force-ipv4"
	say 'stage2: second stage + GNOME desktop + Kali default toolset (chroot, slow under qemu)'
	chroot "$rootfs" /bin/sh -c '
		set -eu
		export DEBIAN_FRONTEND=noninteractive
		[ -x /debootstrap/debootstrap ] && /debootstrap/debootstrap --second-stage || true
		printf "liuqin\n" >/etc/hostname
		apt-get update
		# Bring any already-installed base packages to the current index before
		# resolving the desktop; a debootstrap base older than the index dead-ends
		# the resolver on exact-version deps (perl-base, libnm0, ...).
		apt-get dist-upgrade -y >/dev/null
		# Full current Kali: desktop + the default toolset, with their
		# recommended closure so the solver is not starved of hard dependencies
		# (zenmap in non-free, the GUI tools, network-manager libraries).
		apt-get install -y \
			kali-desktop-gnome kali-linux-default \
			gnome-shell gnome-control-center gnome-initial-setup \
			gdm3 network-manager
		# Desktop content the tablet runs by default: vim, EasyEffects (PipeWire
		# per-app audio), a full zsh setup (Kali ships the autosuggestions and
		# syntax-highlighting extras), the ALSA + PipeWire stack as the default
		# sound server, and an Android-like font set (Roboto + Noto CJK + emoji).
		apt-get install -y \
			vim easyeffects zsh zsh-autosuggestions zsh-syntax-highlighting \
			pipewire pipewire-pulse pipewire-alsa wireplumber libpulse0 \
			alsa-utils alsa-ucm-conf alsa-topology-conf \
			fonts-roboto fonts-noto fonts-noto-cjk fonts-noto-cjk-extra \
			fonts-noto-color-emoji fonts-droid-fallback
		apt-get -y autoremove
		apt-get clean
		rm -rf /var/lib/apt/lists/*
	'
	# The distro /etc/resolv.conf is a symlink to systemd-resolved's stub
	# (NetworkManager hands DNS to it).  The build scripts supply build-time
	# DNS by writing the host's nameserver into the stub path, which only
	# works through this symlink; a real file would pin host DNS state into
	# the manifest.
	ln -sf ../run/systemd/resolve/stub-resolv.conf "$rootfs/etc/resolv.conf"
	# Host identifiers must not be baked into the image: each tablet generates
	# its own machine-id and SSH host keys on first boot (systemd and sshd
	# both recreate missing keys).  A committed machine-id would also make the
	# native-root copy stage's empty-placeholder assertion fail.
	: >"$rootfs/etc/machine-id"
	: >"$rootfs/var/lib/dbus/machine-id"
	rm -f "$rootfs/etc/ssh/ssh_host_ecdsa_key" "$rootfs/etc/ssh/ssh_host_ed25519_key" \
		"$rootfs/etc/ssh/ssh_host_rsa_key" "$rootfs/etc/ssh/ssh_host_ed25519_key.pub" \
		"$rootfs/etc/ssh/ssh_host_ecdsa_key.pub" "$rootfs/etc/ssh/ssh_host_rsa_key.pub"
	# Unmount child mounts (dev/pts, dev/shm) before their parent (dev), and
	# include sys and proc, so no host filesystem leaks into the tree that
	# build-liuqin-kali-rootfs.sh later pins with the manifest.
	umount "$rootfs/dev/shm" "$rootfs/dev/pts" "$rootfs/dev" \
		"$rootfs/sys" "$rootfs/proc" 2>/dev/null || :
	# Clearing the EXIT trap (below) skips its rm, so remove the service-start
	# policy explicitly: the native-root builder refuses a tree that carries
	# one, and a baked-in policy-rc.d would block first-boot service startup.
	rm -f "$rootfs/usr/sbin/policy-rc.d"
	trap - EXIT
	touch "$marker"
	say 'stage2 PASS'
}

case ${1:-all} in
stage1) stage1 ;;
stage2) stage2 ;;
all) stage1; stage2 ;;
*) die 'usage: build-liuqin-kali-base.sh [stage1|stage2|all]' ;;
esac
