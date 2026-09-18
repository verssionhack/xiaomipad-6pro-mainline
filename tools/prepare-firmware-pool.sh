#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Assemble the build's firmware pool (tools/local/firmware-liuqin) from the
# tracked, authoritative firmware tree (device/firmware). No stock-ROM access is
# needed: every pool object byte-for-byte equals a device/firmware file, so the
# pool is fully reproducible from git.
#
# The pool re-lays device/firmware/usr/lib/firmware into the per-component tree
# that tools/build-liuqin-firmware-prep.sh verifies:
#
#   touch-nt36532/vendor/firmware            <- novatek/liuqin
#   bt-qca6490/vendor/bt_firmware/image      <- qca
#   wlan-qca6490/upstream/WCN6855/hw2.0      <- ath11k/WCN6855/hw2.0 (minus board.bin)
#   wlan-qca6490/vendor/firmware_mnt/.../bd_m81.elf  <- ath11k/WCN6855/hw2.0/board.bin
#   regulatory/upstream                      <- regulatory.db{,.p7s}
#   dsp-sm8475/vendor/qcom/sm8475/liuqin     <- qcom/sm8475/liuqin (minus a730_zap.mbn)
#   gpu-adreno730/vendor                     <- a730_zap.mbn + updates/qcom/{gmu,a730_sqe}
#
# The two renames (board.bin -> bd_m81.elf, and a730_zap.mbn moving to the GPU
# component) are the only places the pool layout diverges from the firmware
# layout.
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
die() { printf 'prepare-firmware-pool: %s\n' "$*" >&2; exit 1; }

[ "$#" = 2 ] || die 'usage: prepare-firmware-pool.sh FIRMWARE_TREE OUT_POOL   (FIRMWARE_TREE = device/firmware, OUT_POOL = tools/local/firmware-liuqin)'
# Resolve to absolute paths: copy_dir() cd's into the source dir, which would
# otherwise break a relative OUT_POOL.
fw=$(realpath -m -- "$1")
out=$(realpath -m -- "$2")

src="$fw/usr/lib/firmware"
[ -d "$src" ] || die "firmware tree is unavailable: $src"
[ -f "$fw/firmware.manifest" ] || die "firmware.manifest is missing under $fw"

copy_dir() { # src_dir dst_dir [exclude-regex]
	local s=$1 d=$2 ex=${3:-}
	mkdir -p -- "$d"
	(cd -- "$s" && for f in *; do
		[ -f "$f" ] || continue
		if [ -n "$ex" ] && printf '%s\n' "$f" | grep -Eq "$ex"; then
			continue
		fi
		cp -a -- "$f" "$d/"
	done)
}
copy_one() { # src_file dst_file
	mkdir -p -- "$(dirname -- "$2")"
	cp -a -- "$1" "$2"
}

rm -rf -- "$out"
copy_dir   "$src/novatek/liuqin"                              "$out/touch-nt36532/vendor/firmware"
copy_dir   "$src/qca"                                         "$out/bt-qca6490/vendor/bt_firmware/image"
copy_dir   "$src/ath11k/WCN6855/hw2.0"                        "$out/wlan-qca6490/upstream/WCN6855/hw2.0" '^board\.bin$'
copy_one   "$src/ath11k/WCN6855/hw2.0/board.bin"              "$out/wlan-qca6490/vendor/firmware_mnt/image/qca6490/bd_m81.elf"
copy_one   "$src/regulatory.db"                               "$out/regulatory/upstream/regulatory.db"
copy_one   "$src/regulatory.db.p7s"                           "$out/regulatory/upstream/regulatory.db.p7s"
copy_dir   "$src/qcom/sm8475/liuqin"                          "$out/dsp-sm8475/vendor/qcom/sm8475/liuqin" '^a730_zap\.mbn$'
copy_one   "$src/qcom/sm8475/liuqin/a730_zap.mbn"             "$out/gpu-adreno730/vendor/a730_zap.mbn"
copy_one   "$src/updates/qcom/gmu_gen70000.bin"               "$out/gpu-adreno730/vendor/gmu_gen70000.bin"
copy_one   "$src/updates/qcom/a730_sqe.fw"                    "$out/gpu-adreno730/vendor/a730_sqe.fw"

count=$(find "$out" -type f | wc -l | tr -d ' ')
[ "$count" = 186 ] || die "expected 186 pool files, got $count"
printf 'prepare-firmware-pool: OK -> %s (%s files)\n' "$out" "$count"
