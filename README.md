# BarPilot

[**English**](README.md) · [繁體中文](README.zh-Hant.md) · [简体中文](README.zh-Hans.md)

![BarPilot banner](assets/hero.svg)

![preview](https://img.shields.io/badge/release-0.5.2--preview.1-50c8e8?style=flat-square) ![GPLv3](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)

**Make room in your Mac menu bar.** A standalone project in the personal macOS tools collection.

## What it does

- Sort icons into visible, stored and hidden groups; search and reorder them.
- Use per-display layouts and a second row when icons exceed the available width.
- Control the app from its menu-bar icon and configure launch at login.

## Install a preview

Download the macOS ZIP from [Releases](https://github.com/yoko1234p/BarPilot/releases/tag/v0.5.2-preview.1), unzip, and move `BarPilot.app` to Applications. This preview uses ad-hoc signing and is **not notarized**. On first launch, use Finder’s **Open** context menu; if macOS blocks it, review **System Settings → Privacy & Security → Open Anyway**. Grant only the permissions you need. Do not install over a working copy without backing up local data.

## Build from source

```sh
cd BarPilot
APP_UI_LANGUAGE=zh-Hant swift test -j 4
bash Scripts/build.sh release
```

The required local `Shared/` packages and build helpers are included. Building does not install or launch the app.

## Requirements and limits

macOS 26+; Xcode 27/Swift 6 and Python 3 for source builds. Ordering needs Accessibility permission; icon capture may need Screen Recording. System-owned icons and macOS changes can limit placement. Avoid running another menu-bar manager at the same time.

## Contribute and license

Original application code is GPL-3.0-only. Keep bundled third-party and data notices; see [LICENSE](LICENSE), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), [CONTRIBUTING.md](CONTRIBUTING.md), and [SECURITY.md](SECURITY.md).
