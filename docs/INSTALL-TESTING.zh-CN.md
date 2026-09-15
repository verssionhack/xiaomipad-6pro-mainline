# 安装步骤

[English](INSTALL-TESTING.md)

首次安装和首次启动已在 256 GB 机型完成真机验证；128 GB 与 512 GB 变体按
[安装指南](FLASHING.zh-CN.md)的规则放行但未逐一真机验证。本项目仍属于实验性设备移植，
安装时请保持有人在场，并准备恢复条件。

## 准备

- Xiaomi Pad 6 Pro（liuqin）；userdata 分区不小于 16 GiB，自定义分区布局会被拒绝。
- Bootloader 已解锁，A 槽处于活动状态，平板进入 Fastboot，电量至少 30%。
- Linux 主机、Python 3.11 或更新版本、Android platform-tools，以及正常的 USB 网络支持。
- 个人文件已备份到平板以外；安装会清空整个 userdata，安装器不会备份个人文件。
- 已准备适配本机、满足防回滚要求的原厂 Fastboot ROM，并明确如何恢复 Android。

## 执行安装

下载同一版本的全部文件，在安装包目录执行。若系统归档分卷提供，先合并：

```sh
if [ ! -f rootfs.tar.gz ]; then
  cat rootfs.tar.gz.part-* > rootfs.tar.gz
fi
```

安装器会在访问设备前自动校验镜像，无需重复校验。开始安装前需交互输入
`YES` 确认清空数据（脚本或无交互环境显式加 `--yes`）：

```sh
python3 install.py --bundle . --serial DEVICE_SERIAL \
  --backup /path/to/new-private-backup --erase-userdata
```

只检查文件、不访问设备时使用 `python3 install.py --bundle . --check`。
自行构建或 CI 生成的未验收包，需要在有人在场的测试中显式添加 `--allow-unverified`。

安装器临时启动 installer.img，等待 USB 网络，备份并校验 boot_a、boot_b 与 persist；
随后下载并校验系统归档，格式化 userdata，安装系统并提取本机校准和地址。
根文件系统安装成功且卸载后，才写入 boot_a 并重启。不会修改分区表、写入 persist、
自动切换槽位或重新锁定 Bootloader。备份必须放在安装包目录以外，并保持私密。

USB 网络通常通过 DHCP 配置；必要时可用 `--host-address` 指定主机 USB 网卡地址。
安装 RAM 环境的救援 shell 没有身份认证，只能使用可信的直连 USB，不要接入共享网络。
失败后先保留报错与备份，确认已完成哪些步骤，不要直接反复重跑。

## 桌面诊断

有人在场的安装测试可在安装命令后添加 `--enable-rescue`，让救援通道从首次启动即可使用。
该选项会开放免认证 root 访问，仅适用于可信连接；默认安装不启用。

也可以在平板上手动开启：

```sh
sudo liuqin-rescue on
```

使用 `liuqin-rescue status` 查看状态。开启后，`192.168.7.2:2323` 提供救援访问，重启后仍然有效。
不要将此端口转发或暴露到其他网络。诊断结束后，在平板上执行 `sudo liuqin-rescue off` 关闭通道；
现有救援连接也会断开。

## 恢复 Android

恢复会清除 Ubuntu，需要使用匹配的原厂 Fastboot ROM 完成系统恢复和 userdata 初始化。
仅还原 boot_a 不等于恢复 Android。

使用原厂完整清刷流程，不用保留数据或重新上锁的变体；保留原厂防回滚检查。
不得恢复其他平板的 persist 或校准。在仍有非原厂镜像时保持 Bootloader 解锁。
原厂 ROM 从上游取得，不在本项目重复托管。

Android 恢复路线仍待独立真机验证，不应将 Ubuntu 安装通过等同于恢复已验证。
