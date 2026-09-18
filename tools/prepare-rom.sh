#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Extract the curated liuqin ROM inputs from a stock fastboot ROM, without
# copying any pre-made extract. Produces the four trees the build consumes:
#
#   OUT_DIR/analysis/vendor_boot/dtbs/dtb-NN.dtb   (14 DTBs from vendor_boot.img)
#   OUT_DIR/analysis/dtbo/entry.N                  (44 DTOs from dtbo.img)
#   OUT_DIR/extracted/super-work/vendor-extract/sensors   (vendor etc/sensors)
#   OUT_DIR/extracted/persist/sensors/registry   (factory sensor registry)
#
# The DTB/DTO payloads are packed little-endian FDT containers: vendor_boot's
# "dtb" component and the DTBO image body each hold N FDTs back to back. We
# split them by scanning for the FDT magic and consuming each header's
# total_size. The vendor and persist partitions are mounted read-only.
#
# Requires root (read-only loop/erofs mounts) and tools/local/aosp-mkbootimg
# (run tools/fetch-aosp-mkbootimg.sh first).
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

die() { printf 'prepare-rom: %s\n' "$*" >&2; exit 1; }
[ "$#" = 3 ] ||
	die 'usage: prepare-rom.sh ROM_DIR VENDOR_IMG OUT_DIR   (OUT_DIR = tools/local/roms/liuqin/OS2.0.203.0.VMYCNXM)'
rom_dir=$1
vendor_img=$2
out_dir=$3

persist_img="$rom_dir/images/persist.img"
dtbo_img="$rom_dir/images/dtbo.img"
vendor_boot_img="$rom_dir/images/vendor_boot.img"
unpack=$project_root/tools/local/aosp-mkbootimg/unpack_bootimg.py

[ "$(id -u)" = 0 ] || die 'run as root (read-only erofs/ext4 mounts are required)'
[ -f "$dtbo_img" ] || die "dtbo.img is unavailable: $dtbo_img"
[ -f "$vendor_boot_img" ] || die "vendor_boot.img is unavailable: $vendor_boot_img"
[ -f "$persist_img" ] || die "persist.img is unavailable: $persist_img"
[ -f "$vendor_img" ] || die "vendor partition image is unavailable: $vendor_img"
[ -f "$unpack" ] || die "unpack_bootimg.py is unavailable (run tools/fetch-aosp-mkbootimg.sh)"

rm -rf -- "$out_dir"
mkdir -p -- "$out_dir/analysis/vendor_boot/dtbs" "$out_dir/analysis/dtbo" \
	"$out_dir/extracted/super-work/vendor-extract" "$out_dir/extracted/persist"

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT HUP INT TERM

# --- vendor_boot DTBs: unpack the VNDRBOOT image, split its packed FDTs ------
python3 "$unpack" --boot_img "$vendor_boot_img" --out "$work/vb" >/dev/null
[ -f "$work/vb/dtb" ] || die 'vendor_boot image did not yield a dtb payload'

split_fdts() {
	# $1 = input file, $2 = output dir, $3 = name format (use {i} or {i:02d}).
	python3 - "$1" "$2" "$3" <<'PY'
import sys, struct, os
path, outdir, fmt = sys.argv[1], sys.argv[2], sys.argv[3]
data = open(path, 'rb').read()
n = len(data)
off = data.find(b'\xd0\x0d\xfe\xed')
count = 0
while off >= 0 and off + 64 <= n:
	total = struct.unpack_from('>I', data, off + 4)[0]
	if total < 0x10 or off + total > n:
		break
	with open(os.path.join(outdir, fmt.format(i=count)), 'wb') as f:
		f.write(data[off:off + total])
	off += total
	count += 1
if count == 0:
	raise SystemExit('no FDTs found in ' + path)
print(count)
PY
}

vb_count=$(split_fdts "$work/vb/dtb" "$out_dir/analysis/vendor_boot/dtbs" "dtb-{i:02d}.dtb")
bo_count=$(split_fdts "$dtbo_img" "$out_dir/analysis/dtbo" "entry.{i}")
printf 'vendor_boot dtbs: %s  dtbo entries: %s\n' "$vb_count" "$bo_count"
[ "$vb_count" = 14 ] || die "expected 14 vendor_boot dtbs, got $vb_count"
[ "$bo_count" = 44 ] || die "expected 44 dtbo entries, got $bo_count"

# --- vendor partition: etc/sensors (59 files) -> vendor-extract/sensors ------
mkdir -p -- "$work/vendor"
mount -t erofs -o ro,loop "$vendor_img" "$work/vendor" 2>/dev/null ||
	mount -o ro,loop "$vendor_img" "$work/vendor"
[ -d "$work/vendor/etc/sensors" ] || die "vendor partition has no etc/sensors"
cp -a "$work/vendor/etc/sensors" "$out_dir/extracted/super-work/vendor-extract/sensors"
umount "$work/vendor"
sensors_count=$(find "$out_dir/extracted/super-work/vendor-extract/sensors" -type f | wc -l | tr -d ' ')
[ "$sensors_count" = 59 ] || die "expected 59 vendor sensor config files, got $sensors_count"
printf 'vendor sensor config files: %s\n' "$sensors_count"

# --- persist partition: factory sensor registry ------------------------------
mkdir -p -- "$work/persist"
mount -o ro,loop "$persist_img" "$work/persist"
[ -d "$work/persist/sensors/registry" ] || die "persist has no sensors/registry"
mkdir -p -- "$out_dir/extracted/persist/sensors"
cp -a "$work/persist/sensors/registry" "$out_dir/extracted/persist/sensors/registry"
umount "$work/persist"
[ -f "$out_dir/extracted/persist/sensors/registry/registry/sensors_registry" ] || die 'sensors_registry missing'
[ -f "$out_dir/extracted/persist/sensors/registry/sns_reg_version" ] || die 'sns_reg_version missing'

printf 'prepare-rom: OK -> %s\n' "$out_dir"
