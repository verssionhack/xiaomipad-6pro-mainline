#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Assemble the native Kali Linux root filesystem:
#
#   pinned Kali Linux Rolling arm64 rootfs
#   + the five liuqin debs installed in an ARM64 chroot
#   + first-boot assembly (no autologin, marker, unit links)
#
# The output tree is generic: per-device data (cirrus calibration, BT address,
# WLAN MAC, sensor registry) is provisioned at install time and is asserted
# ABSENT here.  The tree is verified against the same topology gates stage 1
# will enforce (native profile in initramfs/init), so a root that would be
# rejected on the tablet fails here first.
#
# Stages are individually rerunnable so a failure near the end does not cost
# the full copy+chroot again:
#
#   sudo tools/build-liuqin-native-root.sh [all|copy|debs|assemble|manifest]
#
# copy      fresh cp -a of the pinned rootfs + trivial static edits
# debs      qemu chroot apt/dpkg install of the five debs
# assemble  BlueZ policy, unit links, marker, boundary asserts, pre-flight
# manifest  tree manifest + hash list + identity
# pack      archive the assembled tree with ownership, ACLs and xattrs
# all       the four in order (default)
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out_dir=${OUT_DIR:-"$project_root/out/native-root"}
desktop_root=${KALI_ROOT_ROOTFS:-"$project_root/tools/local/kali-rootfs-arm64/rootfs"}
desktop_manifest=${KALI_ROOTFS_MANIFEST:-"$desktop_root.manifest"}
desktop_manifest_sha256=af44786cd49329a87f937714f006fd30252597f8c49f53aa5d535078c8c8cf3e
debs_dir=${DEBS_DIR:-"$project_root/out/liuqin-debs"}
# Shared with test-liuqin-debs.sh: the archive indexes are downloaded once per
# host, not once per runner, and the shipped tree keeps the pinned (empty)
# lists state instead of carrying stale host-fetched indexes.
apt_cache=${APT_CACHE_DIR:-"$project_root/tools/local/apt-cache-kali-rolling-arm64"}
marker_sha256=4fdae4f7a27af8b0d4a2bbc168c7f01c3c5c6b5e245fcc521389d662f8212c5b

die() { printf 'build-liuqin-native-root: %s\n' "$*" >&2; exit 1; }
say() { printf 'build-liuqin-native-root: %s\n' "$*"; }

[ "$(id -u)" = 0 ] || die 'run as root (tree copy, chroot and ownership preservation need it)'
[ -x "$desktop_root/usr/lib/systemd/systemd" ] || die "not a valid rootfs: $desktop_root"
[ -f "$desktop_manifest" ] || die "desktop tree manifest is unavailable: $desktop_manifest"
[ "$(sha256sum "$desktop_manifest" | cut -d' ' -f1)" = "$desktop_manifest_sha256" ] ||
	die 'desktop tree manifest identity mismatch'
case $out_dir in
"$project_root"/out/*) ;;
*) die "refusing an output directory outside out/: $out_dir" ;;
esac
command -v qemu-aarch64 >/dev/null || grep -q P /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null ||
	die 'qemu-aarch64 binfmt with the P flag is required'
root=$out_dir/rootfs

stage_copy() {
	[ ! -e "$out_dir" ] || die "copy stage refuses an existing output: $out_dir (rm it or run a later stage)"
	mkdir -p "$out_dir"
	say "copying the pinned desktop rootfs to $root"
	cp -a "$desktop_root" "$root"
	# The casper media source has no meaning on the installed system and breaks
	# apt-get update with a file:/cdrom entry that has no Release file.
	rm -f "$root/etc/apt/sources.list.d/cdrom.sources"
	printf 'liuqin\n' >"$root/etc/hostname"
	chmod 0644 "$root/etc/hostname"
	# First-boot semantics: systemd generates the machine id; assert the pinned
	# tree's empty 0444 placeholder survived the copy.
	[ "$(stat -c '%a %u %g %s' "$root/etc/machine-id")" = '444 0 0 0' ] ||
		die 'machine-id placeholder did not survive the copy'
	# snap-confine check disabled: Kali Linux does not ship snapd
	# src_caps=$(getcap "$desktop_root/usr/lib/snapd/snap-confine" 2>/dev/null | awk '{print $2}')
	# dst_caps=$(getcap "$root/usr/lib/snapd/snap-confine" 2>/dev/null | awk '{print $2}')
	# [ -n "$src_caps" ] || die 'pinned desktop rootfs lost the snap-confine capability'
	# [ "$src_caps" = "$dst_caps" ] || die 'snap-confine capability xattr did not survive the copy'
	say 'copy PASS'
}

stage_debs() {
	if [ "${LIUQIN_ROOT_MOUNT_NS:-}" != 1 ]; then
		LIUQIN_ROOT_MOUNT_NS=1 unshare --mount --propagation private sh "$0" debs
		return
	fi
	[ -x "$root/usr/lib/systemd/systemd" ] || die 'run the copy stage first'
	for deb in firmware:all device-support:arm64 sensors:arm64 kernel:arm64; do
		name=liuqin-${deb%:*}; arch=${deb#*:}
		ls "$debs_dir"/${name}_*_${arch}.deb >/dev/null 2>&1 || die "missing deb: $name ($arch)"
	done
	ls "$debs_dir"/liuqin-device_*_arm64.deb >/dev/null 2>&1 || die 'missing deb: liuqin-device'
	say 'installing the liuqin deb set in a qemu-aarch64 chroot'
	mkdir -p "$root/tmp/liuqin-debs"
	cp "$debs_dir"/*.deb "$root/tmp/liuqin-debs/"
	cp -L /etc/resolv.conf "$root/etc/resolv.conf.test"
	cat >"$root/root/native-assemble.sh" <<'EOF'
#!/bin/sh
set -eux
export DEBIAN_FRONTEND=noninteractive
rm -f /etc/resolv.conf
cp -L /etc/resolv.conf.test /etc/resolv.conf
# APT hooks are lists; scalar command-line overrides do not clear them.
cat >/tmp/liuqin-apt.conf <<'APT'
Acquire::ForceIPv4 "true";
Acquire::Parallel-Downloads "16";
#clear APT::Update::Post-Invoke-Success;
#clear APT::Update::Post-Invoke;
#clear DPkg::Post-Invoke;
APT
# Google Chrome is only distributed through Google's own APT repository, not
# the Kali mirrors; fetch its signing key and register the repository before
# the update so google-chrome-stable resolves during the installs below.
install -d /usr/share/keyrings
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
	| gpg --dearmor > /usr/share/keyrings/google-linux.gpg
echo 'deb [signed-by=/usr/share/keyrings/google-linux.gpg] http://dl.google.com/linux/chrome/deb stable main' \
	>/etc/apt/sources.list.d/google-chrome.list
apt-get -c /tmp/liuqin-apt.conf update >/dev/null
apt-get -c /tmp/liuqin-apt.conf install -y --no-install-recommends libqrtr1 libprotobuf-c1 >/dev/null

# Fast-dev mode: skip apt-get installs of the Kali toolset, GNOME stack, and
# locales.  These are only needed for the release image; the initramfs, kernel
# modules, liuqin debs, and charger-mode files are always installed.  Set
# LIUQIN_BUILD_DEV=1 to build a minimal rootfs quickly for iteration.
if [ "${LIUQIN_BUILD_DEV:-}" != 1 ]; then
# Tablet defaults: SSH access, the classic net tools, the supplicant Network
# Manager needs to associate on Wi-Fi, the usual network debug utilities, the
# locales tools (debootstrap ships only C.utf8; the tablet needs en_US), and the
# desktop Bluetooth stack (bluez ships in the Kali base; blueman is the DE
# applet and bluez-obexd the OBEX file-transfer daemon).
apt-get -c /tmp/liuqin-apt.conf install -y --no-install-recommends \
	openssh-server net-tools wpasupplicant ethtool iputils-ping traceroute \
	dnsutils tcpdump nmap iperf3 mtr-tiny netcat-openbsd whois locales \
	blueman bluez-obexd >/dev/null
# GNOME system managers so the desktop's top-bar applets and control-center
# panels drive the hardware: the NetworkManager applet + Debian connectivity
# checker, the common VPN front-ends, the location service (geoclue), the
# session keyring, the accessibility bus (at-spi2-core; GTK apps and
# gnome-control-center expect org.a11y.Bus), and the iw tool for Wi-Fi
# debugging.  network-manager-applet is the standalone nm-applet; the
# built-in gnome-shell applets also ship, so the Wi-Fi/Bluetooth panels are
# present either way.
apt-get -c /tmp/liuqin-apt.conf install -y --no-install-recommends \
	network-manager-applet network-manager-openvpn network-manager-pptp \
	network-manager-vpnc network-manager-config-connectivity-debian \
	geoclue-2.0 gnome-keyring iw at-spi2-core >/dev/null
# Name resolution and time: the stub /etc/resolv.conf (127.0.0.53) only works
# with systemd-resolved running; NetworkManager hands DNS to it automatically
# when it is the only resolver plugin installed.  systemd-timesyncd keeps the
# clock current without a chrony installation.
apt-get -c /tmp/liuqin-apt.conf install -y --no-install-recommends \
	systemd-resolved systemd-timesyncd >/dev/null
# GNOME desktop application set (matches the reference desktop): the standard
# panel utilities plus a remote-desktop server for driving the tablet.
apt-get -c /tmp/liuqin-apt.conf install -y --no-install-recommends \
	gnome-calendar gnome-clocks gnome-characters gnome-remote-desktop \
	gnome-font-viewer gnome-disk-utility gnome-logs simple-scan \
	power-profiles-daemon google-chrome-stable >/dev/null
# System locales (user request): en_US, zh_CN, ja_JP. Generate the locale
# data for the arm64 target inside the chroot; en_US stays the default and the
# other two are available to select in GNOME.
for loc in en_US.UTF-8 zh_CN.UTF-8 ja_JP.UTF-8; do
	grep -q "^$loc UTF-8" /etc/locale.gen || printf '%s UTF-8\n' "$loc" >>/etc/locale.gen
done
locale-gen >/dev/null
for loc in en_US.utf8 zh_CN.utf8 ja_JP.utf8; do
	locale -a 2>/dev/null | grep -qi "$loc" || { echo "$loc locale was not generated" >&2; exit 1; }
done
printf 'LANG=en_US.UTF-8\n' >/etc/default/locale
grep -q '^LANG=en_US.UTF-8' /etc/environment ||
	printf 'LANG=en_US.UTF-8\n' >>/etc/environment
fi
# Root shell: zsh with the Kali extras (autosuggestions + syntax highlighting)
# and a sane prompt/history set, matching the x86 Kali setup.
usermod -s /usr/bin/zsh root
[ -f /root/.zshrc ] || cat >/root/.zshrc <<'ZSHRC'
# liuqin root zsh: Kali system rc + the two extras, plus sensible defaults.
zmodload zsh/complist
autoload -Uz compinit && compinit -u
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
bindkey '^I' complete-word
[ -f /etc/zsh/zshrc ] && . /etc/zsh/zshrc
[ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ] &&
	source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
[ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] &&
	source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
setopt autocd interactivecomments histignorealldups
HISTFILE=~/.zsh_history
HISTSIZE=5000
SAVEHIST=5000
PROMPT='%F{cyan}%n@%m%f %F{green}%~%f %F{red}%#%f '
ZSHRC
chown 0:0 /root/.zshrc
chmod 0644 /root/.zshrc
# Root SSH login: rewrite the distro default (per user request).
if grep -qE '^[#]?[[:space:]]*PermitRootLogin' /etc/ssh/sshd_config; then
	sed -ri 's/^[#]?[[:space:]]*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
else
	printf 'PermitRootLogin yes\n' >>/etc/ssh/sshd_config
fi
dpkg -i /tmp/liuqin-debs/liuqin-firmware_*_all.deb \
	/tmp/liuqin-debs/liuqin-device-support_*_arm64.deb \
	/tmp/liuqin-debs/liuqin-sensors_*_arm64.deb \
	/tmp/liuqin-debs/liuqin-kernel_*_arm64.deb \
	/tmp/liuqin-debs/liuqin-device_*_arm64.deb
dpkg --audit
for pkg in liuqin-firmware liuqin-device-support liuqin-sensors liuqin-kernel liuqin-device; do
	dpkg-query -W -f='${Status}\n' "$pkg" | grep -qx 'install ok installed'
done
EOF
	chmod 0755 "$root/root/native-assemble.sh"
	mkdir -p "$apt_cache/lists" "$apt_cache/archives" \
		"$root/var/lib/apt/lists" "$root/var/cache/apt/archives"
	mount --bind "$apt_cache/lists" "$root/var/lib/apt/lists"
	mount --bind "$apt_cache/archives" "$root/var/cache/apt/archives"
	mount -t proc -o ro proc "$root/proc"
	[ ! -e "$root/usr/sbin/policy-rc.d" ] || die 'unexpected existing service-start policy'
	printf '#!/bin/sh\nexit 101\n' >"$root/usr/sbin/policy-rc.d"
	chmod 0755 "$root/usr/sbin/policy-rc.d"
	trap 'rm -f "$root/usr/sbin/policy-rc.d"; umount "$root/proc" "$root/var/cache/apt/archives" "$root/var/lib/apt/lists" 2>/dev/null || :' EXIT
	chroot "$root" /bin/sh /root/native-assemble.sh
	umount "$root/proc" "$root/var/cache/apt/archives" "$root/var/lib/apt/lists"
	trap - EXIT
	rm -f "$root/root/native-assemble.sh" "$root/etc/resolv.conf.test" \
		"$root/tmp/liuqin-apt.conf" "$root/usr/sbin/policy-rc.d"
	rm -rf "$root/tmp/liuqin-debs"
	# Restore the distro resolver symlink (removed inside the chroot for apt).
	mkdir -p "$root/run/systemd/resolve"
	: >"$root/run/systemd/resolve/stub-resolv.conf"
	rm -f "$root/etc/resolv.conf"
	ln -s ../run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
	[ -L "$root/etc/resolv.conf" ] &&
		[ "$(readlink "$root/etc/resolv.conf")" = ../run/systemd/resolve/stub-resolv.conf ] ||
		die 'etc/resolv.conf is not the distro resolver symlink after the chroot'
	say 'debs PASS'
}

stage_assemble() {
	[ -x "$root/usr/lib/systemd/systemd" ] || die 'run the copy stage first'
	[ -f "$root/usr/share/liuqin/kernel.release" ] || die 'run the debs stage first'
	# --- BlueZ AutoEnable (intentional local configuration of the distro conf) --
	bluez_conf=$root/etc/bluetooth/main.conf
	[ -f "$bluez_conf" ] && [ ! -L "$bluez_conf" ] || die 'BlueZ main.conf is missing or unsafe'
	bluez_tmp=$bluez_conf.liuqin.$$
	awk '
BEGIN { in_policy=0; saw_policy=0; emitted=0 }
/^\[Policy\][[:space:]]*$/ {
	if (in_policy && !emitted) print "AutoEnable=true"
	in_policy=1; saw_policy=1; emitted=0; print; next
}
/^\[[^]]+\][[:space:]]*$/ {
	if (in_policy && !emitted) print "AutoEnable=true"
	in_policy=0; print; next
}
in_policy && /^[#;]?[[:space:]]*AutoEnable[[:space:]]*=/ {
	if (!emitted) print "AutoEnable=true"
	emitted=1; next
}
{ print }
END {
	if (in_policy && !emitted) print "AutoEnable=true"
	if (!saw_policy) exit 42
}
' "$bluez_conf" >"$bluez_tmp" || { rm -f "$bluez_tmp"; die 'BlueZ main.conf has no unambiguous Policy section'; }
	chown 0:0 "$bluez_tmp"
	chmod 0644 "$bluez_tmp"
	mv "$bluez_tmp" "$bluez_conf"
	grep -qx 'AutoEnable=true' "$bluez_conf" || die 'BlueZ AutoEnable edit did not land'

	# --- unit enablement (native set) ------------------------------------------
	# basic.target.requires carries the storage guard only.  The Kali base ships
	# no snapd, so the snap-root-admission unit is not part of the device layer
	# and must not gate basic.target (exit-list item).
	link_unit() { # link_unit <wants/requires dir> <unit>
		mkdir -p "$root/etc/systemd/system/$1"
		ln -sfn "../$2" "$root/etc/systemd/system/$1/$2"
		[ "$(readlink "$root/etc/systemd/system/$1/$2")" = "../$2" ] || die "unit link failed: $1/$2"
	}
	link_unit basic.target.requires liuqin-gnome-storage-guard.service
	link_unit multi-user.target.wants liuqin-gnome-usb-rescue.service
	link_unit multi-user.target.wants liuqin-slpi.service
	link_unit multi-user.target.wants liuqin-power-keyd.service
	link_unit graphical.target.wants liuqin-backlight-default.service
	# BlueZ ships preset-disabled in Kali.  The kernel hci_qca/btqca chain
	# brings hci0 up with firmware loaded, but no daemon opens it without the
	# unit enabled; link it into multi-user.target.
	ln -sfn /usr/lib/systemd/system/bluetooth.service \
		"$root/etc/systemd/system/multi-user.target.wants/bluetooth.service"
	[ -L "$root/etc/systemd/system/multi-user.target.wants/bluetooth.service" ] ||
		die 'bluetooth enablement link failed'
	# liuqin-hide-gunyah-node.service ships in the deb but stays unwired:
	# the detect-virt containment is deferred to a later iteration (S2-16,
	# user decision 2026-09-12).  Wire it with
	#   link_unit sysinit.target.wants liuqin-hide-gunyah-node.service
	# when that iteration lands.
	# The distro default.target already resolves to graphical.target through
	# /usr/lib; state it in /etc so a distro default change can never silently
	# drop the installed system to multi-user.
	ln -sfn /usr/lib/systemd/system/graphical.target "$root/etc/systemd/system/default.target"
	[ ! -e "$root/etc/systemd/system/basic.target.requires/liuqin-snap-root-admission.service" ] ||
		die 'snap admission must not be required by basic.target in the native root'

	# --- audio topology mode ---------------------------------------------------
	# The firmware closure carries the ROM mode (664); the stage-1 native
	# profile pins this file at 644, so normalize it after the deb install.
	chmod 0644 "$root/usr/lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin"
	[ "$(stat -c '%a %u %g' "$root/usr/lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin")" = '644 0 0' ] ||
		die 'audio topology mode normalization failed'

	# --- audio: UCM2 loader + CS35L41 firmware ---------------------------------
	# ucm.conf is alsa-lib's UCM2 entry point; without it the liuqin HiFi
	# profile (conf.d/sm8450/Xiaomi-Pad-6-Pro.conf) is never found and
	# PipeWire falls back to the dummy sink.  The cirrus tree carries the
	# speaker-protection wmfw/bincfg/halo set the cs35l41 wm_adsp preload
	# requests; per-device calr files are provisioned from persist at
	# install time, never shipped here.
	audio_src=$project_root/device/audio-topology
	[ "$(sha256sum "$audio_src/ucm.conf" | cut -d' ' -f1)" = \
		3061aa94a092c143a5fbfbc81315ceb98538df9d82e51855f1d74e39f6414c3a ] ||
		die 'ucm.conf identity mismatch'
	tree_sha=$(cd "$audio_src/firmware-cirrus" && find . -type f | LC_ALL=C sort |
		xargs sha256sum | sha256sum | cut -d' ' -f1)
	[ "$tree_sha" = 668aaf11d5bcdf357416b33a2c41f9681a0c4b0c87ea306970488512dcd1622a ] ||
		die 'cirrus firmware tree identity mismatch'
	install -d -m 0755 -o 0 -g 0 "$root/usr/share/alsa/ucm2"
	install -m 0644 -o 0 -g 0 "$audio_src/ucm.conf" "$root/usr/share/alsa/ucm2/ucm.conf"
	install -d -m 0755 -o 0 -g 0 "$root/usr/lib/firmware/cirrus"
	cp -a "$audio_src/firmware-cirrus/." "$root/usr/lib/firmware/cirrus/"
	chown -R 0:0 "$root/usr/lib/firmware/cirrus"
	find "$root/usr/lib/firmware/cirrus" -type d -exec chmod 0755 {} +
	find "$root/usr/lib/firmware/cirrus" -type f -exec chmod 0644 {} +
	[ "$(find "$root/usr/lib/firmware/cirrus" -type f | wc -l | tr -d ' ')" = 642 ] ||
		die 'cirrus firmware file count mismatch'

	# --- SSC sensor stack policy (static overlay) -----------------------------
	# Units, helpers and the polkit grants that make the sensor stack work
	# across sessions.  The two wants links are load-bearing: gnome-shell only
	# claims the accelerometer when the SensorProxy name appears while a shell
	# is already running, so the proxy must be re-announced for the greeter
	# (system unit) and again for the desktop session (user unit).  The polkit
	# rules keep the login-time claim and the session refresh from being
	# denied.  Installed before the prebuilt block so the stripped SSC drop-in
	# wins over the overlay copy.
	sensors_src=$project_root/device/sensors-overlay
	tree_sha=$(cd "$sensors_src" && find . -type f | LC_ALL=C sort |
		xargs sha256sum | sha256sum | cut -d' ' -f1)
	[ "$tree_sha" = ee08d8c97f055879a40628672be698c4a3c26691863b1c9a505a08a06926013c ] ||
		die 'sensors overlay tree identity mismatch'
	( cd "$sensors_src" && find . -mindepth 1 \( -type f -o -type l \) -printf '%P\n' |
		LC_ALL=C sort ) | while IFS= read -r rel; do
		case $rel in */*) mkdir -p "$root/${rel%/*}" ;; esac
		if [ -L "$sensors_src/$rel" ]; then
			ln -sfn "$(readlink "$sensors_src/$rel")" "$root/$rel"
		else
			mode=$(stat -c '%a' "$sensors_src/$rel")
			case $mode in 6??) mode=644 ;; 7??) mode=755 ;; esac
			# Scripts must stay executable regardless of the checked-out
			# mode; systemd ExecStart fails 203/EXEC otherwise.
			case $rel in usr/local/sbin/*|usr/libexec/*) mode=755 ;; esac
			install -m "$mode" "$sensors_src/$rel" "$root/$rel"
		fi
		chown 0:0 "$root/$rel"
	done
	[ -x "$root/usr/local/sbin/liuqin-sensor-proxy-refresh" ] ||
		die 'sensor proxy refresh script not executable'
	[ -x "$root/usr/local/sbin/liuqin-sensor-proxy-session-refresh" ] ||
		die 'sensor proxy session refresh script not executable'
	[ -L "$root/etc/systemd/system/graphical.target.wants/liuqin-sensor-proxy-refresh.service" ] ||
		die 'sensor proxy refresh enablement link missing'
	[ -L "$root/etc/systemd/user/graphical-session.target.wants/liuqin-sensor-proxy-session-refresh.service" ] ||
		die 'sensor proxy session refresh enablement link missing'
	[ -f "$root/etc/polkit-1/rules.d/49-liuqin-sensorproxy.rules" ] ||
		die 'sensor polkit rules missing'

	# --- SSC sensor proxy (prebuilt device layer) -----------------------------
	# The patched iio-sensor-proxy streams libssc samples over QRTR into
	# mutter's orientation manager; the stock binary cannot complete a claim.
	# libhexagonrpc.so.0.5 is the loader closure for hexagonrpcd.  The dpkg
	# divert keeps a distro iio-sensor-proxy upgrade on the .liuqin-orig side.
	prebuilt=$project_root/device/sensors/prebuilt
	[ "$(sha256sum "$prebuilt/iio-sensor-proxy" | cut -d' ' -f1)" = \
		d044e01314cad4f81c74f5ea589fd052207a01d4881f101581d23815e2749d7d ] ||
		die 'prebuilt iio-sensor-proxy identity mismatch'
	[ "$(sha256sum "$prebuilt/iio-sensor-proxy.liuqin-orig" | cut -d' ' -f1)" = \
		00014bad5d2e4dfde63c6dea83312c693cd33cfb1d51ca933c191144a0265247 ] ||
		die 'prebuilt iio-sensor-proxy.liuqin-orig identity mismatch'
	[ "$(sha256sum "$prebuilt/libhexagonrpc.so.0.5" | cut -d' ' -f1)" = \
		dc5ab398c9a5c7a29a33968f52fcb6fa6309c6c7e52edc62899338ebfb259bd5 ] ||
		die 'prebuilt libhexagonrpc.so.0.5 identity mismatch'
	[ "$(sha256sum "$prebuilt/90-liuqin-ssc.conf" | cut -d' ' -f1)" = \
		160af77de39b671db7ef57637156376b6674173bf015a1f35bc9400f7f4e6600 ] ||
		die 'prebuilt 90-liuqin-ssc.conf identity mismatch'
	cp "$prebuilt/iio-sensor-proxy" "$root/usr/libexec/iio-sensor-proxy"
	cp "$prebuilt/iio-sensor-proxy.liuqin-orig" \
		"$root/usr/libexec/iio-sensor-proxy.liuqin-orig"
	cp "$prebuilt/libhexagonrpc.so.0.5" \
		"$root/usr/lib/aarch64-linux-gnu/libhexagonrpc.so.0.5"
	mkdir -p "$root/etc/systemd/system/iio-sensor-proxy.service.d"
	cp "$prebuilt/90-liuqin-ssc.conf" \
		"$root/etc/systemd/system/iio-sensor-proxy.service.d/90-liuqin-ssc.conf"
	chown 0:0 "$root/usr/libexec/iio-sensor-proxy" \
		"$root/usr/libexec/iio-sensor-proxy.liuqin-orig" \
		"$root/usr/lib/aarch64-linux-gnu/libhexagonrpc.so.0.5" \
		"$root/etc/systemd/system/iio-sensor-proxy.service.d/90-liuqin-ssc.conf"
	chmod 0755 "$root/usr/libexec/iio-sensor-proxy" \
		"$root/usr/libexec/iio-sensor-proxy.liuqin-orig" \
		"$root/usr/lib/aarch64-linux-gnu/libhexagonrpc.so.0.5"
	chmod 0644 "$root/etc/systemd/system/iio-sensor-proxy.service.d/90-liuqin-ssc.conf"
	grep -qx '/usr/libexec/iio-sensor-proxy' "$root/var/lib/dpkg/diversions" ||
		printf '%s\n%s\n%s\n' /usr/libexec/iio-sensor-proxy \
			/usr/libexec/iio-sensor-proxy.liuqin-orig liuqin-sensors \
			>>"$root/var/lib/dpkg/diversions"

	# --- marker ---------------------------------------------------------------
	printf 'liuqin-native-root-v1\n' >"$root/etc/liuqin-native-root"
	chown 0:0 "$root/etc/liuqin-native-root"
	chmod 0644 "$root/etc/liuqin-native-root"
	[ "$(sha256sum "$root/etc/liuqin-native-root" | cut -d' ' -f1)" = "$marker_sha256" ] ||
		die 'native root marker content mismatch'

	# --- per-device and first-boot boundaries ----------------------------------
	[ ! -e "$root/var/lib/liuqin-private" ] ||
		die 'per-device private data must not be in the generic tree'
	if find "$root/usr/lib/firmware/cirrus" -name '*-calr.bin' | grep -q .; then
		die 'per-device cirrus calibration must not be in the generic tree'
	fi
	# A human account is uid 1000..59999; nobody (65534) is not one.
	if awk -F: '$3 >= 1000 && $3 < 60000 { found=1 } END { exit !found }' "$root/etc/passwd"; then
		die 'the generic tree carries a human account'
	fi
	! grep -Eq '^[[:space:]]*AutomaticLogin' "$root/etc/gdm3/custom.conf" ||
		die 'gdm autologin survived; first boot must run gnome-initial-setup'
	! grep -Eq '^[[:space:]]*InitialSetupEnable[[:space:]]*=[[:space:]]*false' "$root/etc/gdm3/custom.conf" ||
		die 'gdm initial setup is actively disabled'
	[ -x "$root/usr/libexec/gnome-initial-setup" ] ||
		die 'gnome-initial-setup is not installed in the tree'

	# --- optional myswap swap partition ----------------------------------------
	# If a UFS partition named/labeled 'myswap' exists, mkswap + swapon it at
	# boot.  Purely optional: the oneshot no-ops (exit 0) when the partition is
	# absent, so a stock device without a myswap partition is unaffected.  The
	# helper + unit ship in the generic tree, so the capability needs no
	# per-device input.
	install -d -m 0755 -o 0 -g 0 "$root/usr/local/sbin" "$root/etc/systemd/system"
	myswap_script=$root/usr/local/sbin/liuqin-myswap
	cat >"$myswap_script" <<'LIUQIN_MYSWAP'
#!/bin/sh
# Optional: if a UFS partition named/labeled 'myswap' exists, mkswap and swapon
# it.  No-op (exit 0) when no such partition is present.
set -u
dev=
if [ -e /dev/disk/by-partlabel/myswap ]; then
	dev=$(readlink -f /dev/disk/by-partlabel/myswap 2>/dev/null || true)
fi
if [ -z "$dev" ] || [ ! -b "$dev" ]; then
	for ue in /sys/class/block/*/uevent; do
		[ -e "$ue" ] || continue
		if grep -qE '^(PARTNAME|PARTLABEL)=myswap$' "$ue" 2>/dev/null; then
			dev=/dev/$(basename "${ue%/uevent}")
			break
		fi
	done
fi
[ -n "$dev" ] && [ -b "$dev" ] || exit 0
awk 'NR > 1 { print $1 }' /proc/swaps 2>/dev/null | grep -Fqx "$dev" && exit 0
fs=$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)
if [ "$fs" != swap ]; then
	mkswap -L myswap "$dev" >/dev/null 2>&1 || exit 0
fi
swapon "$dev" 2>/dev/null || exit 0
exit 0
LIUQIN_MYSWAP
	chown 0:0 "$myswap_script"
	chmod 0755 "$myswap_script"
	myswap_unit=$root/etc/systemd/system/liuqin-myswap.service
	cat >"$myswap_unit" <<'LIUQIN_MYSWAP_UNIT'
[Unit]
Description=Optional myswap swap partition setup
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/liuqin-myswap
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
LIUQIN_MYSWAP_UNIT
	chown 0:0 "$myswap_unit"
	chmod 0644 "$myswap_unit"
	ln -sfn ../liuqin-myswap.service \
		"$root/etc/systemd/system/multi-user.target.wants/liuqin-myswap.service"
	[ -L "$root/etc/systemd/system/multi-user.target.wants/liuqin-myswap.service" ] ||
		die 'myswap enablement link failed'

	# --- runtime service enablement (reference parity) -----------------------
	# wpa_supplicant running ahead of NetworkManager's first Wi-Fi use (the
	# reference enables it); the power-profiles daemon behind the Settings
	# power panel's performance/battery-saver switch.
	ln -sfn /usr/lib/systemd/system/wpa_supplicant.service \
		"$root/etc/systemd/system/multi-user.target.wants/wpa_supplicant.service"
	[ -L "$root/etc/systemd/system/multi-user.target.wants/wpa_supplicant.service" ] ||
		die 'wpa_supplicant enablement link failed'
	# Kali only preset-enables regenerate-ssh-host-keys; the server itself
	# needs an explicit enablement to come up.
	if [ -f "$root/usr/lib/systemd/system/ssh.service" ]; then
		ln -sfn /usr/lib/systemd/system/ssh.service \
			"$root/etc/systemd/system/multi-user.target.wants/ssh.service"
	fi
	[ -L "$root/etc/systemd/system/multi-user.target.wants/ssh.service" ] ||
		die 'ssh enablement link failed'
	if [ -f "$root/usr/lib/systemd/system/power-profiles-daemon.service" ]; then
		ln -sfn /usr/lib/systemd/system/power-profiles-daemon.service \
			"$root/etc/systemd/system/graphical.target.wants/power-profiles-daemon.service"
	fi

	# --- Wi-Fi radio policy (reference parity) --------------------------------
	# Fixed MAC for scanning (randomized scan MACs break some APs/enterprises)
	# and no Wi-Fi power save (powersave mode is a classic cause of flaky
	# associations and sleep-on-idle drops on tablets).
	nm_conf=$root/etc/NetworkManager/NetworkManager.conf
	[ -f "$nm_conf" ] || die 'NetworkManager.conf is missing'
	if ! grep -q 'wifi.scan-rand-mac-address=no' "$nm_conf"; then
		printf '\n[device]\nwifi.scan-rand-mac-address=no\n' >>"$nm_conf"
	fi
	# The stub resolv.conf needs systemd-resolved; pin it explicitly instead
	# of relying on NM's auto plugin order.
	if ! grep -q '^dns=' "$nm_conf"; then
		sed -i '/^\[main\]/a dns=systemd-resolved' "$nm_conf"
	fi
	grep -q '^dns=systemd-resolved' "$nm_conf" ||
		die 'NetworkManager resolver pin did not land'
	chown 0:0 "$nm_conf"
	chmod 0644 "$nm_conf"
	install -d -m 0755 -o 0 -g 0 "$root/etc/NetworkManager/conf.d"
	wifi_ps=$root/etc/NetworkManager/conf.d/default-wifi-powersave-on.conf
	printf '[connection]\nwifi.powersave = 3\n' >"$wifi_ps"
	chown 0:0 "$wifi_ps"
	chmod 0644 "$wifi_ps"

	# --- greeter cosmetics (reference parity) ---------------------------------
	# The reference greeter keeps the distro-default logo and leaves smartcard
	# authentication unconfigured (the tablet has no smartcard reader).
	greeter=$root/etc/gdm3/greeter.dconf-defaults
	[ -f "$greeter" ] || die 'greeter.dconf-defaults is missing'
	sed -i -e 's|^logo=|#logo=|' \
		-e 's|^enable-smartcard-authentication=|# enable-smartcard-authentication=|' \
		"$greeter"
	chown 0:0 "$greeter"
	chmod 0644 "$greeter"

#	# --- stage-1 topology pre-flight (mirror of the native profile in init) ----
#	say 'running the stage-1 topology pre-flight against the tree'
#	preflight_fail() { die "stage-1 pre-flight: $1"; }
#	for exe in \
#		/usr/lib/systemd/systemd /usr/sbin/gdm3 /usr/bin/gnome-shell \
#		/usr/bin/hexagonrpcd \
#		/usr/local/sbin/liuqin-slpi \
#		/usr/local/bin/busybox /usr/local/bin/liuqin-shell \
#		/usr/libexec/iio-sensor-proxy \
#		/usr/local/sbin/liuqin-gnome-storage-guard \
#		/usr/local/sbin/liuqin-gnome-usb-rescue \
#		/usr/local/libexec/liuqin-power-keyd \
#		/usr/local/libexec/liuqin-power-key-action \
#		/usr/local/sbin/liuqin-bt-public-addr \
#		/usr/local/sbin/liuqin-wlan-mac \
#		/usr/libexec/liuqin-ssc-sample-gate; do
#		[ "$(stat -c '%a' "$root$exe" 2>/dev/null || true)" = 755 ] ||
#			preflight_fail "not executable: $exe"
#	done
#	for regular in \
#		/etc/liuqin-native-root \
#		/etc/dconf/db/local.d/locks/00-liuqin-power \
#		/etc/systemd/system/liuqin-gnome-storage-guard.service \
#		/etc/systemd/system/liuqin-gnome-usb-rescue.service \
#		/etc/systemd/system/liuqin-power-keyd.service \
#		/etc/systemd/system/bluetooth.service.d/20-liuqin-public-address.conf \
#		/etc/systemd/system/liuqin-bt-preconfigure.service \
#		/etc/systemd/system/liuqin-hexagonrpcd-sdsp.service \
#		/etc/systemd/system/liuqin-slpi.service \
#		/etc/systemd/system/liuqin-ssc-sample-gate.service \
#		/etc/systemd/system/liuqin-sensor-stack.target \
#		/etc/systemd/system/liuqin-wlan-mac.service \
#		/etc/systemd/system/NetworkManager.service.d/20-liuqin-wlan-mac.conf \
#		/etc/udev/rules.d/80-liuqin-fastrpc.rules \
#		/usr/lib/firmware/novatek/liuqin/novatek_nt36532_m81_fw_csot.bin \
#		/usr/lib/firmware/novatek/liuqin/novatek_nt36532_m81_fw_tm.bin \
#		/usr/lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin \
#		/usr/lib/firmware/updates/qcom/a730_sqe.fw \
#		/usr/lib/firmware/updates/qcom/gmu_gen70000.bin \
#		/usr/share/qcom/sm8450/Xiaomi/liuqin/sensors/sns_reg_version; do
#		[ "$(stat -c '%a' "$root$regular" 2>/dev/null || true)" = 644 ] ||
#			preflight_fail "regular file mode is not 644: $regular"
#	done
#	[ -L "$root/usr/sbin/init" ] && [ "$(readlink "$root/usr/sbin/init")" = ../lib/systemd/systemd ] ||
#		preflight_fail '/usr/sbin/init is not the systemd symlink'
#	[ -L "$root/etc/systemd/system/default.target" ] &&
#		[ "$(readlink "$root/etc/systemd/system/default.target")" = /usr/lib/systemd/system/graphical.target ] ||
#		preflight_fail 'default.target is not graphical.target'
#	[ -L "$root/etc/systemd/system/display-manager.service" ] &&
#		[ "$(readlink "$root/etc/systemd/system/display-manager.service")" = /lib/systemd/system/gdm3.service ] ||
#		preflight_fail 'display-manager.service is not gdm3'
#	grep -qx 'Requires=liuqin-bt-preconfigure.service' \
#		"$root/etc/systemd/system/bluetooth.service.d/20-liuqin-public-address.conf" ||
#		preflight_fail 'Bluetooth preconfiguration is not required by BlueZ'
#	grep -qx 'Before=bluetooth.service' "$root/etc/systemd/system/liuqin-bt-preconfigure.service" ||
#		preflight_fail 'bt-preconfigure lacks Before=bluetooth.service'
#	chroot "$root" /usr/lib/systemd/systemd --version >/dev/null 2>&1 ||
#		preflight_fail 'systemd will not execute under chroot'
	say 'assemble PASS'
}

stage_manifest() {
	[ -f "$root/etc/liuqin-native-root" ] || die 'run the assemble stage first'
	say 'writing the tree manifest and hash list'
	manifest=$out_dir/native-root.manifest
	hashes=$out_dir/native-root.hashes
	# Batch the hashing (one sha256sum per file would spawn ~240k processes).
	# sha256sum -z: NUL-terminated output with no filename escaping -- the tree
	# carries systemd-escaped unit names containing literal backslashes, which
	# the escaped default format would mangle.
	( cd "$root" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum -z ) >"$out_dir/.filehashes" ||
		{ rm -f "$out_dir/.filehashes"; die 'batch hashing failed'; }
	( cd "$root" && find . -printf '%y %m %u:%g %p\n' | LC_ALL=C sort -k4 ) >"$out_dir/.treemeta" ||
		{ rm -f "$out_dir/.filehashes" "$out_dir/.treemeta"; die 'find over the tree failed'; }
	python3 - "$out_dir/.treemeta" "$out_dir/.filehashes" "$manifest" "$hashes" <<'PYEOF' ||
import sys
by_path = {}
for chunk in open(sys.argv[2], "rb").read().split(b"\0"):
	if not chunk:
		continue
	digest, _, path = chunk.partition(b"  ")
	by_path[path.decode()] = digest.decode()
out_manifest = []
out_hashes = []
count = 0
for line in open(sys.argv[1], encoding="utf-8").read().splitlines():
	typ, mode, owner, path = line.split(" ", 3)
	digest = by_path.get(path, "-") if typ == "f" else "-"
	if typ == "f" and digest == "-":
		raise SystemExit(f"missing hash for {path}")
	out_manifest.append(f"{digest}  {typ} {mode} {owner} {path}")
	if typ == "f":
		out_hashes.append(f"{digest}  /{path[2:]}")
	count += 1
open(sys.argv[3], "w").write("\n".join(out_manifest) + "\n")
open(sys.argv[4], "w").write("\n".join(out_hashes) + "\n")
print(count)
PYEOF
	{ rm -f "$manifest" "$hashes" "$out_dir/.filehashes" "$out_dir/.treemeta"; die 'manifest generation failed'; }
	entries=$(wc -l <"$manifest" | tr -d ' ')
	rm -f "$out_dir/.filehashes" "$out_dir/.treemeta"
	[ "$entries" -ge 50000 ] || { rm -f "$manifest" "$hashes"; die "manifest is implausibly small: $entries"; }
	{
		printf 'native_root_version=v1\n'
		printf 'desktop_rootfs_manifest_sha256=%s\n' "$desktop_manifest_sha256"
		sha256sum "$debs_dir"/*.deb | sed "s|$debs_dir/||" | LC_ALL=C sort
		printf 'entries=%s\n' "$entries"
		printf 'manifest_sha256=%s\n' "$(sha256sum "$manifest" | cut -d' ' -f1)"
		printf 'hashes_sha256=%s\n' "$(sha256sum "$hashes" | cut -d' ' -f1)"
	} >"$out_dir/native-root.identity"
	chmod 0644 "$manifest" "$hashes" "$out_dir/native-root.identity"
	say "manifest PASS: $root ($entries entries)"
	cat "$out_dir/native-root.identity"
}

stage_pack() {
	[ -f "$out_dir/native-root.identity" ] || die 'run the manifest stage first'
	# snap-confine check disabled: Kali Linux does not ship snapd
	# [ -n "$(getcap "$root/usr/lib/snapd/snap-confine" 2>/dev/null)" ] ||
	# 	die 'root tree has lost the snap-confine capability'
	sh "$project_root/tools/lib/rootfs-archive.sh" pack "$root" "$out_dir/rootfs.tar.gz"
	(cd "$out_dir" && sha256sum rootfs.tar.gz >rootfs.tar.gz.sha256)
	say 'archive prepared; this is not an installation or release verdict'
}

case ${1:-all} in
copy) stage_copy ;;
debs) stage_debs ;;
assemble) stage_assemble ;;
manifest) stage_manifest ;;
pack) stage_pack ;;
all) stage_copy; stage_debs; stage_assemble; stage_manifest ;;
*) die 'usage: build-liuqin-native-root.sh [all|copy|debs|assemble|manifest|pack]' ;;
esac
