# BarPilot

Organize macOS menu-bar icons, keep frequently used items visible and put overflow in a second row.

**系統效率系列：選單列圖示整理與多螢幕布局。** Interfaces support English, Traditional Chinese and Simplified Chinese.

## Features

- Separate visible, stored and hidden items; search and reorder entries.
- Use display layouts and a second row when the menu bar runs out of space.
- Open settings from the menu-bar control and choose your own login-item preference.

## Build and test

Requires macOS 26+, Xcode 27/Swift 6 and Python 3. This repository includes its required shared packages; keep `Shared/` and `scripts/` beside `BarPilot/`.

```sh
cd BarPilot
APP_UI_LANGUAGE=zh-Hant swift test -j 4
bash Scripts/build.sh release
```

The app bundle is written to `BarPilot/dist/BarPilot.app`. Building does not install or launch it. See [SIGNING.md](SIGNING.md) for ad-hoc development and your own signing identity.

## Use and limitations

Accessibility is required for ordering and some menu-bar interactions. Features that capture icon imagery need screen-recording access. Avoid running another menu-bar manager simultaneously. System-owned items and macOS changes can limit placement.

## Development and license

This app is under active development. Report the macOS version, reproduction steps and actual validation results with changes. Use synthetic data for file, clipboard and permission tests. Validate interface catalogs from the repository root with `python3 scripts/localization/check-catalogs.py`.

Original maintained code is **GPL-3.0-only**. Keep the separate dependency/data notices listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). See [LICENSE](LICENSE) and [CONTRIBUTING.md](CONTRIBUTING.md).
