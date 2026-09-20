#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Emit the tree manifest for the Kali Linux Rolling arm64 base rootfs.
#
# The base itself is debootstrapped by tools/build-liuqin-kali-base.sh (the
# project no longer mirrors a pinned tarball).  This script only fingerprints
# the resulting tree so build-liuqin-native-root.sh and build-liuqin-settings.py
# can pin and verify it.  The manifest records, per path: type, mode, owner,
# and (for regular files) sha256.
#
# The manifest pass needs real root so root-owned, unreadable files (e.g. apt
# lists partial/) are seen in full; any find or sha256 failure is fatal -- a
# truncated manifest is a false identity, worse than none.  Run as:
#
#   sudo sh tools/build-liuqin-kali-base.sh all
#   sudo sh tools/build-liuqin-kali-rootfs.sh manifest
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
input_dir=${KALI_ROOT_INPUT:-"$project_root/tools/local/kali-rootfs-arm64"}
rootfs=${KALI_ROOT_ROOTFS:-"$input_dir/rootfs"}

die() { printf 'build-liuqin-kali-rootfs: %s\n' "$*" >&2; exit 1; }

write_manifest() {
	# The tree is root-owned with unreadable directories (e.g. apt lists
	# partial/); an unprivileged run sees a partial tree.  Require real root
	# and treat any find failure as fatal -- a truncated manifest is a false
	# identity, worse than none.
	[ "$(id -u)" = 0 ] || die "manifest stage must run as real root (sudo $0 manifest)"
	# No host filesystem may be mounted into the tree (e.g. a leaked /sys or
	# /dev from build-liuqin-kali-base.sh), or host state pollutes the
	# fingerprint.  Fail loudly instead of pinning a tree that includes it.
	for leak in proc sys dev dev/pts dev/shm; do
		if mountpoint -q "$rootfs/$leak" 2>/dev/null; then
			die "rootfs/$leak is mounted; unmount host filesystems before manifesting"
		fi
	done
	manifest=${KALI_ROOTFS_MANIFEST:-"$input_dir/rootfs.manifest"}
	tmp=$manifest.tmp
	paths=$manifest.paths.tmp
	(cd "$rootfs" && find . -printf '%y %m %u:%g %p\n') >"$paths" ||
		{ rm -f "$paths"; die 'find over the rootfs failed; refusing a truncated manifest'; }
	LC_ALL=C sort -k4 "$paths" >"$paths.sorted"
	mv "$paths.sorted" "$paths"
	: >"$tmp"
	while IFS= read -r line; do
		type=${line%% *}; rest=${line#* }
		path=${rest#* }; path=${path#* }
		case $type in
		f) printf '%s  %s\n' "$(cd "$rootfs" && sha256sum "$path" | cut -d' ' -f1)" "$line" ||
			{ rm -f "$tmp" "$paths"; die "sha256 failed for $path"; } ;;
		*) printf '%s  %s\n' '-' "$line" ;;
		esac
	done <"$paths" >"$tmp"
	rm -f "$paths"
	entries=$(wc -l <"$tmp" | tr -d ' ')
	[ "$entries" -ge 50000 ] ||
		{ rm -f "$tmp"; die "manifest is implausibly small: $entries entries"; }
	mv "$tmp" "$manifest"
	chmod 0644 "$manifest"
	printf 'tree manifest: %s (%s entries)\n' "$manifest" "$entries"
	sha256sum "$manifest"
}

case ${1:-} in
manifest) [ -d "$rootfs" ] || die "rootfs is unavailable: $rootfs"; write_manifest ;;
*) die 'usage: build-liuqin-kali-rootfs.sh manifest' ;;
esac
