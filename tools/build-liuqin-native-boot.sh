#!/bin/sh
# SPDX-License-Identifier: MIT
# Assemble a native boot image from kernel build outputs and a root manifest.
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out_dir=${OUT_DIR:-"$project_root/out/native-boot"}
kernel_source=${KERNEL_SOURCE:-"$project_root/../linux-sm8450-liuqin"}
kernel_out=${KERNEL_OUT:-"$project_root/out/kernel"}
native_root_hashes=${NATIVE_ROOT_HASHES:?"set NATIVE_ROOT_HASHES to the assembled root's native-root.hashes"}
audio_topology=${AUDIO_TOPOLOGY:?"set AUDIO_TOPOLOGY to the built AudioReach topology"}
firmware_pool=${FIRMWARE_POOL:?"set FIRMWARE_POOL to the prepared firmware input directory"}
wlan_tuple=${WLAN_HSP2_TUPLE:?"set WLAN_HSP2_TUPLE to the prepared WLAN tuple"}
stock_overlay_dir=${STOCK_OVERLAY_DIR:?"set STOCK_OVERLAY_DIR to the extracted stock DTBO entries"}
stock_base_dir=${STOCK_BASE_DIR:?"set STOCK_BASE_DIR to the extracted stock vendor_boot DTBs"}
mk_dir=${MKBOOTIMG_DIR:-"$project_root/tools/local/aosp-mkbootimg"}
allow_kernel_override=${LIUQIN_ALLOW_KERNEL_OVERRIDE:-0}
slot_cc=${SLOT_SUCCESS_GCC:-aarch64-linux-gnu-gcc}
dtc=$kernel_out/scripts/dtc/dtc
fdtoverlay=$kernel_out/scripts/dtc/fdtoverlay
image=${KERNEL_IMAGE:-$kernel_out/arch/arm64/boot/Image}
raw_dtb=${KERNEL_DTB:-$kernel_out/arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb}
cmdline=$(cat "$project_root/device/native-bootargs.txt")

die() { printf 'build-liuqin-native-boot: %s\n' "$*" >&2; exit 1; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

case $allow_kernel_override in 0|1) ;; *) die 'LIUQIN_ALLOW_KERNEL_OVERRIDE must be 0 or 1' ;; esac

case $out_dir in
"$project_root"/out/*) ;;
*) die "output must be below $project_root/out" ;;
esac
case $out_dir in */../*|*/..|*/./*) die 'output path must not contain traversal' ;; esac
[ ! -e "$out_dir" ] && [ ! -L "$out_dir" ] || die "output already exists: $out_dir"
for input in "$image" "$raw_dtb" "$native_root_hashes" "$audio_topology" "$dtc" "$fdtoverlay"; do
	[ -f "$input" ] || die "input missing: $input"
done
[ -d "$firmware_pool" ] && [ -d "$wlan_tuple" ] &&
	[ -d "$stock_overlay_dir" ] && [ -d "$stock_base_dir" ] || die 'firmware/ROM input directory missing'
[ "$(sha "$mk_dir/unpack_bootimg.py")" = 06b54dd9a07c5281778e29e234e76f6e3faee8bf0c904a5ef88fdee30eeed12e ] ||
	die 'unpack_bootimg.py identity mismatch'
[ "$(sha "$mk_dir/mkbootimg.py")" = 37d84b3d162e0bc62e36c1f4e1c63c85ea0caa9f29be023eb2f8efe006ad948c ] ||
	die 'mkbootimg.py identity mismatch'

python3 - "$project_root/kernel/source.json" "$kernel_source" "$kernel_out" "$native_root_hashes" \
	"$allow_kernel_override" <<'PY'
import hashlib, json, subprocess, sys
from pathlib import Path
lock = json.loads(Path(sys.argv[1]).read_text())
source, out, manifest = map(Path, sys.argv[2:5])
override = sys.argv[5] == '1'
commit = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
if override:
    # A development kernel is built from whatever the tree holds, so the product
    # pin and the worktree state are informational rather than binding.
    lock['commit'] = commit
if commit != lock['commit']:
    raise SystemExit('kernel source does not match kernel/source.json')
if not override and subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain']):
    raise SystemExit('kernel source is dirty')
if hashlib.sha256((out / '.config').read_bytes()).hexdigest() != lock['config_sha256']:
    raise SystemExit('kernel configuration differs from kernel/source.json')
# The root filesystem carries the kernel release it was assembled against; a
# development kernel changes that string, which is what --allow-kernel-override
# is for.  Under the product lock the two must still agree.
release = (out / 'include/config/kernel.release').read_bytes()
wanted = hashlib.sha256(release).hexdigest()
rows = [line.split('  ', 1) for line in manifest.read_text().splitlines()]
matches = [h for h, p in rows if p == '/usr/share/liuqin/kernel.release']
if not override and matches != [wanted]:
    raise SystemExit('root filesystem and kernel release do not match')
PY
source_epoch=$(git -C "$kernel_source" show -s --format=%ct HEAD)
charger_mode=auto
if [ -n "${INSTALLER_RUNTIME:-}" ]; then charger_mode=0; fi
mkdir -p "$out_dir"

python3 "$project_root/tools/lib/build-root-contract.py" --profile native \
	--device-layer-manifest "$native_root_hashes" --output "$out_dir/native-root.contract"

LIUQIN_STORAGE_MODE=persistent LIUQIN_ROOT_PROFILE=native LIUQIN_EMBED_ROOTFS=0 \
	LIUQIN_CHARGER_MODE="$charger_mode" \
	ROOTFS=none SOURCE_DATE_EPOCH="$source_epoch" SLOT_SUCCESS_GCC="$slot_cc" \
	TOUCH_FIRMWARE_DIR="$firmware_pool/touch-nt36532/vendor/firmware" \
	BT_FIRMWARE_DIR="$firmware_pool/bt-qca6490/vendor/bt_firmware/image" \
	WLAN_BOARD_FILE="$firmware_pool/wlan-qca6490/vendor/firmware_mnt/image/qca6490/bd_m81.elf" \
	WLAN_FIRMWARE_DIR="$firmware_pool/wlan-qca6490/upstream/WCN6855/hw2.0" \
	WLAN_HSP2_TUPLE="$wlan_tuple" \
	REGULATORY_FIRMWARE_DIR="$firmware_pool/regulatory/upstream" \
	GPU_FIRMWARE_DIR="$firmware_pool/gpu-adreno730/vendor" \
	DSP_FIRMWARE_DIR="$firmware_pool/dsp-sm8475/vendor/qcom/sm8475/liuqin" \
	AUDIO_TOPOLOGY="$audio_topology" \
	NATIVE_ROOT_CONTRACT="$out_dir/native-root.contract" NATIVE_ROOT_MANIFEST="$native_root_hashes" \
	OUT_DIR="$out_dir/initramfs" sh "$project_root/tools/lib/build-initramfs.sh"

python3 - "$out_dir/initramfs/liuqin-firstboot.cpio.gz" "$out_dir/liuqin-firstboot.cpio.gz" <<'PY'
import gzip, sys
from pathlib import Path
raw = gzip.decompress(Path(sys.argv[1]).read_bytes())
Path(sys.argv[2]).write_bytes(gzip.compress(raw, compresslevel=1, mtime=0))
PY

# ABL takes the kernel command line from /chosen; keep the boot header empty.
python3 - "$cmdline" "$out_dir/cmdline-overlay.dts" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[2]).write_text('/dts-v1/;\n/plugin/;\n/ { fragment@0 { target-path = "/chosen"; '
                           '__overlay__ { bootargs = ' + json.dumps(sys.argv[1]) + '; }; }; };\n')
PY
"$dtc" -@ -q -I dts -O dtb -o "$out_dir/cmdline-overlay.dtbo" "$out_dir/cmdline-overlay.dts"
"$fdtoverlay" -i "$raw_dtb" -o "$out_dir/input.dtb" "$out_dir/cmdline-overlay.dtbo"

KERNEL_OUT="$kernel_out" IMAGE="$image" DTB="$out_dir/input.dtb" \
	RAMDISK="$out_dir/liuqin-firstboot.cpio.gz" DTC="$dtc" FDTOVERLAY="$fdtoverlay" \
	MKBOOTIMG_DIR="$mk_dir" STOCK_OVERLAY_DIR="$stock_overlay_dir" STOCK_BASE_DIR="$stock_base_dir" \
	ABL_OVERLAY_SINK=1 ABL_DTB02_IDS=0 CMDLINE="$cmdline" HEADER_CMDLINE= \
	OUT_DIR="$out_dir/boot" sh "$project_root/tools/lib/build-bootimg.sh"
mv "$out_dir/boot/boot-liuqin-firstboot.img" "$out_dir/boot-liuqin-native.img"

{
	printf 'status=OFFLINE_BUILT\n'
	printf 'kernel_commit=%s\n' "$(git -C "$kernel_source" rev-parse HEAD)"
	printf 'source_date_epoch=%s\n' "$source_epoch"
	printf 'image_sha256=%s\n' "$(sha "$image")"
	printf 'raw_dtb_sha256=%s\n' "$(sha "$raw_dtb")"
	printf 'native_root_hashes_sha256=%s\n' "$(sha "$native_root_hashes")"
	printf 'contract_sha256=%s\n' "$(sha "$out_dir/native-root.contract")"
	printf 'ramdisk_sha256=%s\n' "$(sha "$out_dir/liuqin-firstboot.cpio.gz")"
	printf 'boot_sha256=%s\n' "$(sha "$out_dir/boot-liuqin-native.img")"
} >"$out_dir/native-boot.identity"
cat "$out_dir/native-boot.identity"
