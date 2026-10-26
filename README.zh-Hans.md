# BarPilot

[English](README.md) · [繁體中文](README.zh-Hant.md) · [**简体中文**](README.zh-Hans.md)

![BarPilot banner](assets/hero.svg)

![preview](https://img.shields.io/badge/release-0.5.2--preview.1-50c8e8?style=flat-square) ![GPLv3](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)

**让 Mac 菜单栏井然有序。** 个人 macOS 工具系列的独立 App。

## 主要功能

- 将图标分为常驻、收纳及隐藏；支持搜索与排序。
- 按屏幕应用布局，图标放不下时可用第二行。
- 从菜单栏图标控制，并自行设置登录时启动。

## 安装预览版

从 [Releases](https://github.com/yoko1234p/BarPilot/releases/tag/v0.5.2-preview.1) 下载 macOS ZIP，解压后将 `BarPilot.app` 移至“应用程序”。预览版使用临时签名，**未经 Apple 公证**。首次打开时在 Finder 右键选择“打开”；若系统阻止，请到“系统设置 → 隐私与安全性 → 仍要打开”核对。只授予所需权限，覆盖现用版本前先备份本地数据。

## 从源代码构建

```sh
cd BarPilot
APP_UI_LANGUAGE=zh-Hant swift test -j 4
bash Scripts/build.sh release
```

所需的本地 `Shared/` 包和构建工具已包含在仓库；构建不会自动安装或启动应用。

## 系统要求与限制

macOS 26 或更高版本；源代码构建需 Xcode 27／Swift 6 和 Python 3。 排序需要辅助功能权限；捕获图标可能需要屏幕录制权限。系统图标和 macOS 更新可能限制位置；避免同时运行其他菜单栏管理工具。

## 参与及授权

原创应用代码按 GPL-3.0-only 发布；附带的第三方及数据许可须分别保留。详见 [LICENSE](LICENSE)、[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)、[CONTRIBUTING.md](CONTRIBUTING.md) 和 [SECURITY.md](SECURITY.md)。
