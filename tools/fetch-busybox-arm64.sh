#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
download_dir="$project_root/tools/local/downloads"
extract_dir="$project_root/tools/local/busybox-arm64"
package=busybox-static_1.36.1-11_arm64.deb
url="http://archive.kali.org/kali-pool/main/b/busybox/$package"
package_sha256=PLACEHOLDER_KALI_BUSYBOX_SHA256
binary_sha256=52151e7f322f926b64049cdaa1410dc3ea6485525e0624b05813791c219ae933

mkdir -p "$download_dir" "$extract_dir"

if [ ! -f "$download_dir/$package" ] || \
	! echo "$package_sha256  $download_dir/$package" | sha256sum --check --status; then
	curl --fail --location "$url" --output "$download_dir/$package.part"
	mv "$download_dir/$package.part" "$download_dir/$package"
fi

echo "$package_sha256  $download_dir/$package" | sha256sum --check
dpkg-deb --extract "$download_dir/$package" "$extract_dir"
echo "$binary_sha256  $extract_dir/usr/bin/busybox" | sha256sum --check

dpkg-deb --field "$download_dir/$package" Package Version Architecture
file "$extract_dir/usr/bin/busybox"
