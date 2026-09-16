#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Extract the Kali Linux Rolling arm64 rootfs from the pinned tarball.
#
# Two stages, each independently gated:
#   1. verify the tarball byte identity (size + sha256);
#   2. extract base and emit a tree manifest (path, mode, owner, sha256)
#      for comparison and pinning.
#
# Stage 2 needs real root so device nodes, ownership and xattrs survive.  Run
# it as:  sudo tools/build-liuqin-kali-rootfs.sh extract
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
input_dir=${KALI_ROOT_INPUT:-"$project_root/tools/local/kali-rootfs-arm64"}
tarball=$input_dir/kali-rootfs-arm64.tar.gz
tarball_url=${KALI_ROOTFS_URL:-https://kali.download/kali-images/kali-2026.01/kali-linux-rolling-main-default_arm64-rootfs.tar.gz}
tarball_bytes=2147483648
tarball_sha256=PLACEHOLDER_KALI_ROOTFS_SHA256
rootfs=${KALI_ROOT_ROOTFS:-"$input_dir/rootfs"}

die() { printf 'build-liuqin-kali-rootfs: %s\n' "$*" >&2; exit 1; }

verify_tarball() {
	[ -f "$tarball" ] || die "Tarball is unavailable: $tarball (re-download from https://kali.download/)"
	[ "$(stat -c %s "$tarball")" = "$tarball_bytes" ] || die "Tarball size differs from $tarball_bytes"
	printf '%s  %s\n' "$tarball_sha256" "$tarball" | sha256sum -c --quiet - ||
		die 'Tarball sha256 mismatch; do not use this file'
}

download_tarball() {
	mkdir -p "$input_dir"
	exec 9>"$input_dir/.download.lock"
	flock -n 9 || die 'another tarball download owns this input directory'
	if [ -f "$tarball" ]; then
		verify_tarball
		printf 'Using cached Kali rootfs tarball\n'
		return
	fi
	command -v curl >/dev/null || die 'curl is required'
	# A mirror override must supply the same pinned bytes, never a different release.
	curl --fail --location --continue-at - --output "$tarball.part" "$tarball_url"
	[ "$(stat -c %s "$tarball.part")" = "$tarball_bytes" ] || die 'downloaded tarball size mismatch'
	printf '%s  %s\n' "$tarball_sha256" "$tarball.part" | sha256sum -c --quiet - ||
		die 'downloaded tarball hash mismatch; remove the .part file before retrying'
	mv "$tarball.part" "$tarball"
	printf 'Kali rootfs tarball downloaded and verified\n'
}

extract_rootfs() {
	[ "$(id -u)" = 0 ] || die "stage 2 must run as real root (sudo $0 extract)"
	[ -f "$tarball" ] || download_tarball
	verify_tarball
	[ ! -e "$rootfs" ] || die "refusing to overwrite an existing rootfs: $rootfs"
	tar -xzf "$tarball" -C "$rootfs" --numeric-owner --same-owner
	write_manifest
}

write_manifest() {
	# The tree is root-owned with unreadable directories (e.g. apt lists
	# partial/); an unprivileged run sees a partial tree.  Require real root
	# and treat any find failure as fatal -- a truncated manifest is a false
	# identity, worse than none.
	[ "$(id -u)" = 0 ] || die "manifest stage must run as real root (sudo $0 manifest)"
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
	[ "$entries" -ge 100000 ] ||
		{ rm -f "$tmp"; die "manifest is implausibly small: $entries entries"; }
	mv "$tmp" "$manifest"
	chmod 0644 "$manifest"
	printf 'tree manifest: %s (%s entries)\n' "$manifest" "$entries"
	sha256sum "$manifest"
}

case ${1:-} in
download) download_tarball ;;
verify-tarball) verify_tarball; printf 'Tarball verified: %s bytes, %s\n' "$tarball_bytes" "$tarball_sha256" ;;
extract) extract_rootfs ;;
manifest) [ -d "$rootfs" ] || die "rootfs is unavailable: $rootfs"; write_manifest ;;
*) die 'usage: build-liuqin-kali-rootfs.sh download|verify-tarball|extract|manifest' ;;
esac
