# Installation Steps

Initial installation and first boot have been tested on a 256 GB unit. The
128 GB and 512 GB variants are admitted by the rules in the
[installation guide](FLASHING.md) but have not been tested on real hardware.
This remains an experimental device port. Keep the tablet attended and prepare a recovery plan.

## Requirements

- Xiaomi Pad 6 Pro (liuqin) with a userdata partition of at least 16 GiB.
  Modified partition layouts are rejected.
- Unlocked bootloader, slot A active, and the device in Fastboot mode.
- Battery at least 30 percent charged.
- Linux host with Python 3.11 or newer, Android platform-tools and USB networking.
- Personal files backed up outside the tablet. Installation erases all userdata.
- A matching original Xiaomi Fastboot ROM and an Android recovery plan prepared
  before installation. The installer does not back up personal userdata.

Download all files from the same release. If the system archive is split, join it
in the bundle directory:

```sh
if [ ! -f rootfs.tar.gz ]; then
  cat rootfs.tar.gz.part-* > rootfs.tar.gz
fi
```

Images are verified automatically before any device access. Before the
installation starts, confirm the erasure interactively by typing `YES`
(scripts and non-interactive shells pass `--yes` explicitly):

```sh
python3 install.py --bundle . --serial DEVICE_SERIAL \
  --backup /path/to/new-private-backup --erase-userdata
```

Use `python3 install.py --bundle . --check` for an optional local-only check.
Locally built or CI-generated bundles that have not passed device testing require
`--allow-unverified` for an explicitly attended test.

The installer boots `installer.img` in RAM, waits for its USB network, backs up
boot_a, boot_b and persist, verifies those backups, then installs the rootfs and
provisions this tablet's calibration and addresses. It formats userdata as ext4,
writes boot_a only after root installation succeeds, and reboots. It does not
switch slots, relock the bootloader, modify the partition table or write persist.
Keep the backup directory private. The USB rescue shell has no authentication:
use a direct, trusted USB connection, not a shared network.

USB networking normally obtains an address through DHCP. `--host-address` selects
the host's USB address when automatic route selection is unsuitable. If the
installer cannot establish its control channel it stops; do not blindly retry
after a partial installation. Preserve the error output and backup first.

## Desktop Diagnostics

For an attended installation test, add `--enable-rescue` to the installation
command to make the rescue shell available from the first boot. This is an
explicit opt-in to unauthenticated root access, not the default installation.

On the tablet, enable the rescue shell with:

```sh
sudo liuqin-rescue on
```

Check it with `liuqin-rescue status`. This grants unauthenticated root access
at `192.168.7.2:2323` and remains enabled across boots. Use only a trusted
connection; do not expose or forward this port to other networks. After
diagnostics, run `sudo liuqin-rescue off` on the tablet to disable it and
close existing rescue connections. Release images leave it disabled by default.

## Recovery

Returning to Android erases the Ubuntu installation and requires a compatible
original Fastboot ROM, including its userdata initialization. Restoring boot_a
alone is not a complete Android recovery.

Use the original ROM's full clean-flash procedure, not its keep-data or relock
variant. Preserve the anti-rollback checks. Never restore another tablet's
persist or calibration. Keep the bootloader unlocked while non-stock images
remain. The original ROM is an upstream input, not duplicated in this repository.

Android recovery still requires independent device testing. Successful Ubuntu
installation does not establish that Android recovery has been validated.
