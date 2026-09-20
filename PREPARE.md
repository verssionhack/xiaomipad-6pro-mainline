# PREPARE — re-preparing the gitignored local inputs

`tools/local/` and `out/` are gitignored, so a clean pull of this branch has
**none** of them. This file documents, step by step, how to re-prepare every
gitignored *input* so the tree is buildable — by running the project's own
fetch/extract scripts or copying from a pinned local source, **not** by
copying a pre-made `tools/local/`.

## What this branch contains

- Base: upstream `f566133` (the clean pull).
- The five project commits replayed on top (`Switch OS base … Kali` →
  `Fix Kali build …` → `Add stock ROM DTB/DTBO extracts …` →
  `Extract sensor config and registry …` → `Add Kali device layer …`).
- New prep tooling: `tools/prepare-rom.sh`, `tools/prepare-firmware-pool.sh`.
- This file.

The gitignored *outputs* (`out/kernel`, `out/image`, …) are produced by the
build (see `docs/BUILD.md`); they are not "prepared" inputs.

## The gitignored inputs

| Path | What it is | Reprepared by | Bytes come from |
|------|-----------|---------------|-----------------|
| `tools/local/kali-rootfs-arm64/rootfs` | Kali Rolling arm64 base rootfs (desktop + Kali toolset), pinned by `rootfs.manifest` | `tools/build-liuqin-kali-base.sh` then `tools/build-liuqin-kali-rootfs.sh manifest` | Kali apt (default mirror `mirrors.aliyun.com/kali`) |
| `tools/local/aosp-mkbootimg/` | AOSP `mkbootimg.py` + `unpack_bootimg.py` (commit `954bc3ea`) | `tools/fetch-aosp-mkbootimg.sh` | `android.googlesource.com` (or a local AOSP tree) |
| `tools/local/busybox-arm64/usr/bin/busybox` | static AArch64 busybox, sha256 `52151e7f322f…` | `tools/fetch-busybox-arm64.sh` | Kali `busybox-static_1.36.1-11_arm64.deb` (or a local copy) |
| `tools/local/roms/liuqin/OS2.0.203.0.VMYCNXM/` | curated ROM extract: 14 DTBs, 44 DTBOs, 59 sensor config, factory registry (119 files) | `tools/prepare-rom.sh` | a stock fastboot ROM + the vendor/persist partition images |
| `tools/local/firmware-liuqin/` | 186-file firmware pool for `build-liuqin-firmware-prep.sh` | `tools/prepare-firmware-pool.sh` | tracked `device/firmware/` |
| `tools/local/installer-runtime/` | installer userspace: `tar`, `install`, `mkfs.ext4`, `e2fsck`, `getcap`, `liuqin-reboot` + their libs | `tools/lib/build-installer-runtime.py` | Kali rootfs + tracked `device/charger-mode/liuqin-charger-mode-exit.c` |
| `tools/local/sensor-stack-src/`, `tools/local/apt-cache-kali-rolling-arm64/` | sensor-stack git sources + apt cache | `tools/build-liuqin-sensors-stack.sh` | `git` (per `device/sensors/sources.manifest`) + Kali apt |

Every one of these is reproducible from **git + a stock ROM + (optionally) the
network**. The only inputs that strictly need the network are the Kali
rootfs, the busybox deb, and the AOSP mkbootimg archive.

## Repreparing (recommended order)

All commands run from the repository root. The network artifacts (#1–#3) have
two paths because `android.googlesource.com` and `archive.kali.org` are
unreliable behind the GFW. The Kali base defaults to the Aliyun mirror
(`mirrors.aliyun.com/kali`) for the same reason; override with `KALI_MIRROR`.

### 1. AOSP mkbootimg
```sh
# normal network:
tools/fetch-aosp-mkbootimg.sh
# GFW / offline — copy from any AOSP checkout:
cp -a <aosp-tree>/system/tools/mkbootimg tools/local/aosp-mkbootimg
```
Check: `python3 tools/local/aosp-mkbootimg/mkbootimg.py --help` and
`python3 tools/local/aosp-mkbootimg/unpack_bootimg.py --help` both run.
`mkbootimg.py` must be sha256 `37d84b3d162e0bc62e36c1f4e1c63c85ea0caa9f29be023eb2f8efe006ad948c`.

### 2. busybox
```sh
# normal network (fill the placeholder first, see below):
tools/fetch-busybox-arm64.sh
# GFW / offline — copy a static AArch64 busybox with the pinned hash:
install -m 0755 <path-to-static-arm64-busybox> tools/local/busybox-arm64/usr/bin/busybox
```
Check: `sha256sum tools/local/busybox-arm64/usr/bin/busybox`
= `52151e7f322f926b64049cdaa1410dc3ea6485525e0624b05813791c219ae933`,
`readelf -h … | grep Machine` = AArch64, `readelf -l … | grep -c INTERP` = 0.

### 3. Kali base rootfs
```sh
# debootstrap the arm64 base, then install the GNOME desktop + Kali toolset:
sudo tools/build-liuqin-kali-base.sh all
# emit the tree manifest that pins the resulting rootfs:
sudo tools/build-liuqin-kali-rootfs.sh manifest
```
The base is debootstrapped from the Kali repository (default mirror
`http://mirrors.aliyun.com/kali`, override with `KALI_MIRROR`) and installs
`kali-desktop-gnome` + `kali-linux-default` plus the tablet's default toolset
(vim, EasyEffects, the ALSA + PipeWire stack as the default sound server, a
full zsh setup, and an Android-like font set). Run as root so device-node and
ownership fidelity survive. The resulting tree is pinned by
`tools/local/kali-rootfs-arm64/rootfs.manifest` (path, mode, owner, sha256),
which `build-liuqin-native-root.sh` and `build-liuqin-settings.py` verify
before use. Re-running `build-liuqin-kali-base.sh` is idempotent: each stage is
skipped when its marker (`base.installed`) is present.

### 4. Stock-ROM extract (DTB / DTBO / sensor config / registry)
```sh
sudo tools/prepare-rom.sh <ROM_DIR> <VENDOR_IMG> tools/local/roms/liuqin/OS2.0.203.0.VMYCNXM
```
- `<ROM_DIR>`: a directory containing `images/dtbo.img`,
  `images/vendor_boot.img` and `images/persist.img` (a stock fastboot ROM).
- `<VENDOR_IMG>`: the vendor partition image from the same ROM (erofs), e.g.
  the `vendor_a.img` produced by unpacking `super.img`.

`prepare-rom.sh` splits the packed little-endian FDT containers (14 vendor DTBs
→ `analysis/vendor_boot/dtbs/dtb-NN.dtb`; 44 DTBOs → `analysis/dtbo/entry.N`),
mounts the vendor image read-only and copies `etc/sensors` (59 files) to
`extracted/super-work/vendor-extract/sensors`, and mounts `persist.img` to copy
the factory `sensors/registry`. It verifies the counts (14 / 44 / 59 / 2) and
requires root for the read-only loop/erofs mounts.

### 5. Firmware pool
```sh
tools/prepare-firmware-pool.sh device/firmware tools/local/firmware-liuqin
```
Re-lays the tracked `device/firmware/usr/lib/firmware` into the per-component
pool (`build-liuqin-firmware-prep.sh` verifies these exact paths). Two objects
are renamed in the process: `ath11k/WCN6855/hw2.0/board.bin` becomes
`wlan-qca6490/…/bd_m81.elf`, and `qcom/sm8475/liuqin/a730_zap.mbn` moves into
`gpu-adreno730/vendor`. No stock ROM is needed; all 186 pool files are
byte-for-byte equal to a `device/firmware` file.

### 6. Installer runtime
```sh
python3 tools/lib/build-installer-runtime.py \
  --root tools/local/kali-rootfs-arm64/rootfs --out tools/local/installer-runtime
```
Extracts the installer tools + their ELF dependencies from the Kali rootfs and
cross-compiles `device/charger-mode/liuqin-charger-mode-exit.c` into
`liuqin-reboot`. Needs `aarch64-linux-gnu-gcc` and `python3-pyelftools`.

### 7. Sensor-stack sources + apt cache
These are produced as a side effect of building the sensor stack (step
`docs/BUILD.md`): `tools/build-liuqin-sensors-stack.sh` clones the sources
named in `device/sensors/sources.manifest` into `tools/local/sensor-stack-src`
and populates `tools/local/apt-cache-kali-rolling-arm64`.

## Placeholder hashes (download path only)

One sha256 pin is left as a placeholder so the fetch script stays honest:

- `tools/fetch-busybox-arm64.sh` → `package_sha256` (sha256 of the pinned
  `busybox-static_1.36.1-11_arm64.deb`).

To use the download path, download the artifact once and replace the
`PLACEHOLDER_…` with its `sha256sum`. The *binary* pins are already set:
busybox `52151e7f322f…`, AOSP `mkbootimg.py` `37d84b3d…`. The offline/copy path
needs none of these.

## After preparation — build

With the inputs in place, produce the outputs per `docs/BUILD.md`, roughly:
kernel (`tools/build-liuqin-kernel.py`) → kernel-modules + debs
(`tools/build-liuqin-debs.sh`) → sensor stack
(`tools/build-liuqin-sensors-stack.sh`) → firmware prep
(`tools/build-liuqin-firmware-prep.sh`) → rootfs
(`tools/build-liuqin-native-root.sh assemble`) → boot + installer
(`tools/build-liuqin-native-boot.sh`) → bundle
(`python3 tools/build-liuqin-image.py --stage all`).

## Verification

```sh
# counts
[ "$(find tools/local/firmware-liuqin -type f | wc -l)" = 186 ]
[ "$(find tools/local/roms/liuqin/OS2.0.203.0.VMYCNXM -type f | wc -l)" = 119 ]
[ -x tools/local/kali-rootfs-arm64/rootfs/usr/lib/systemd/systemd ]
# pinned hashes
sha256sum tools/local/busybox-arm64/usr/bin/busybox        # 52151e7f322f…
sha256sum tools/local/firmware-liuqin/wlan-qca6490/vendor/firmware_mnt/image/qca6490/bd_m81.elf  # aa8ae92d…
readelf -h tools/local/installer-runtime/usr/sbin/liuqin-reboot | grep AArch64
```
