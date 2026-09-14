# Waydroid 支持

[English](WAYDROID.md) ｜ [项目首页](../README.zh-CN.md)

本项目的设备内核已包含运行 Waydroid 所需的配置。Waydroid 用宿主 Linux
内核承载一个 Android 用户空间容器，因此需要 Binder IPC、binderfs 以及
若干通用内核特性：

| 需求 | 本内核状态 | 来源 |
|---|---|---|
| Binder IPC / binderfs | ✅ 内建 | `device/configs/liuqin-waydroid.config` |
| PSI（`/proc/pressure`） | ✅ 内建 | `device/configs/liuqin-desktop.config` |
| memfd、network namespace、cgroup freezer | ✅ 内建 | 基线配置 |
| veth | ✅ 模块 | 已随内核模块安装 |

`device/configs/liuqin-waydroid.config` 只新增 Binder 相关项；其内容由
`kernel/source.json` 锁定（`config_fragments` 与 `config_sha256`）。改动该
片段后必须用同一工具链重新生成并更新 `config_sha256`。

## 安装

Waydroid 的 Android 镜像需要联网下载（约 1 GB），请先在平板接入网络：

```sh
sudo apt update
sudo apt install waydroid
sudo waydroid init
sudo systemctl enable --now waydroid-container
```

随后从应用列表启动 Waydroid，或在图形会话中运行 `waydroid session start`。

## 已知限制

- 默认镜像**不含 Google 服务**；自行添加需遵守相应条款。
- 相机、麦克风、传感器、蜂窝电话等依赖厂商 HAL 的功能不可用，与本机
  Ubuntu 的限制一致。
- 图形经由 Mesa/Freedreno 硬件加速；部分游戏和 3D 应用的兼容性未知。
- 该功能尚未随发布包做独立真机验证，属于实验性支持。
