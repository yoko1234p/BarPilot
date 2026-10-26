# BarPilot

[English](README.md) · [**繁體中文**](README.zh-Hant.md) · [简体中文](README.zh-Hans.md)

![BarPilot banner](assets/hero.svg)

![preview](https://img.shields.io/badge/release-0.5.3--preview.1-50c8e8?style=flat-square) ![GPLv3](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)

**讓 Mac 選單列有條理。** 個人 macOS 工具系列的獨立 App。

## 主要功能

- 將圖示分為常駐、收納及隱藏；支援搜尋與排序。
- 按螢幕套用布局，圖示放不下時可用第二行。
- 從選單列圖示控制，並自行設定登入時啟動。

## 安裝預覽版

從 [Releases](https://github.com/yoko1234p/BarPilot/releases/tag/v0.5.3-preview.1) 下載 macOS ZIP，解壓後將 `BarPilot.app` 移至「應用程式」。預覽版使用臨時簽署，**未經 Apple 公證**。首次開啟時在 Finder 按右鍵選「開啟」；若系統阻擋，請到「系統設定 → 私隱與保安 → 仍要開啟」核對。只授予所需權限，覆蓋現用版本前先備份本機資料。

## 從原始碼建置

```sh
cd BarPilot
APP_UI_LANGUAGE=zh-Hant swift test -j 4
bash Scripts/build.sh release
```

所需的本機 `Shared/` 套件和建置工具已包含在 repo；建置不會自動安裝或啟動 App。

## 系統要求與限制

macOS 26 或以上；原始碼建置需 Xcode 27／Swift 6 和 Python 3。 排序需要輔助使用權限；擷取圖示可能需要螢幕錄製權限。系統圖示和 macOS 更新可能限制位置；避免同時運行其他選單列管理工具。

## 參與及授權

原創 App 程式碼以 GPL-3.0-only 發布；附帶的第三方及資料授權須各自保留。詳見 [LICENSE](LICENSE)、[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)、[CONTRIBUTING.md](CONTRIBUTING.md) 和 [SECURITY.md](SECURITY.md)。
