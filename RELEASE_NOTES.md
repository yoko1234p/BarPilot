# BarPilot v0.5.2-preview.1

## English — Full-screen playback fix

- Keep the current icon visibility while a full-screen Space temporarily hides the menu bar. BarPilot no longer treats that transition as a missing control and repeatedly reapplies its hiding policy.
- Check control reachability and saved ordering again when the active Space changes.

This macOS preview is ad-hoc signed and not notarized. Download the ZIP below, verify its SHA-256 against `SHA256SUMS`, then follow the [installation instructions](README.md#install-a-preview). The previous preview remains available for rollback.

## 繁體中文 — 全螢幕播放修正

- 全螢幕 Space 暫時收起選單列時，保留現有圖示開收狀態，避免誤判控制圖示消失而反覆套用隱藏設定。
- 切換 Space 後重新核對控制圖示及儲存的排序。

此 macOS 預覽版使用臨時簽署，未經 Apple 公證。下載 ZIP 後請對照 `SHA256SUMS` 驗證 SHA-256，並參閱[安裝說明](README.zh-Hant.md#安裝預覽版)。舊版仍可下載以便回退。

## 简体中文 — 全屏播放修复

- 全屏 Space 暂时隐藏菜单栏时，保留当前图标展开状态，避免误判控制图标消失并反复应用隐藏设置。
- 切换 Space 后重新核对控制图标和已保存的排序。

此 macOS 预览版使用临时签名，未经 Apple 公证。下载 ZIP 后请对照 `SHA256SUMS` 验证 SHA-256，并参阅[安装说明](README.zh-Hans.md#安装预览版)。旧版仍可下载以便回退。

---

# BarPilot v0.5.1-preview.1

## English — First public preview

Make room in your Mac menu bar.

- Sort icons into visible, stored and hidden groups; search and reorder them.
- Use per-display layouts and a second row when icons exceed the available width.
- Control the app from its menu-bar icon and configure launch at login.

**Install a preview:** Download the macOS ZIP from [Releases](https://github.com/yoko1234p/BarPilot/releases/tag/v0.5.1-preview.1), unzip, and move `BarPilot.app` to Applications. This preview uses ad-hoc signing and is **not notarized**. On first launch, use Finder’s **Open** context menu; if macOS blocks it, review **System Settings → Privacy & Security → Open Anyway**. Grant only the permissions you need. Do not install over a working copy without backing up local data.

**Requirements and limits:** Ordering needs Accessibility permission; icon capture may need Screen Recording. System-owned icons and macOS changes can limit placement. Avoid running another menu-bar manager at the same time.

Before installing, check the asset SHA-256 values in `SHA256SUMS`. The source ZIP and GitHub's generated source archives are provided with this release.

## 繁體中文 — 首個公開預覽版

讓 Mac 選單列有條理。

- 將圖示分為常駐、收納及隱藏；支援搜尋與排序。
- 按螢幕套用布局，圖示放不下時可用第二行。
- 從選單列圖示控制，並自行設定登入時啟動。

**安裝預覽版:** 從 [Releases](https://github.com/yoko1234p/BarPilot/releases/tag/v0.5.1-preview.1) 下載 macOS ZIP，解壓後將 `BarPilot.app` 移至「應用程式」。預覽版使用臨時簽署，**未經 Apple 公證**。首次開啟時在 Finder 按右鍵選「開啟」；若系統阻擋，請到「系統設定 → 私隱與保安 → 仍要開啟」核對。只授予所需權限，覆蓋現用版本前先備份本機資料。

**系統要求與限制:** 排序需要輔助使用權限；擷取圖示可能需要螢幕錄製權限。系統圖示和 macOS 更新可能限制位置；避免同時運行其他選單列管理工具。

安裝前請對照 `SHA256SUMS` 的 SHA-256 值。本版同時提供原始碼 ZIP 和 GitHub 自動產生的原始碼封存檔。

## 简体中文 — 首个公开预览版

让 Mac 菜单栏井然有序。

- 将图标分为常驻、收纳及隐藏；支持搜索与排序。
- 按屏幕应用布局，图标放不下时可用第二行。
- 从菜单栏图标控制，并自行设置登录时启动。

**安装预览版:** 从 [Releases](https://github.com/yoko1234p/BarPilot/releases/tag/v0.5.1-preview.1) 下载 macOS ZIP，解压后将 `BarPilot.app` 移至“应用程序”。预览版使用临时签名，**未经 Apple 公证**。首次打开时在 Finder 右键选择“打开”；若系统阻止，请到“系统设置 → 隐私与安全性 → 仍要打开”核对。只授予所需权限，覆盖现用版本前先备份本地数据。

**系统要求与限制:** 排序需要辅助功能权限；捕获图标可能需要屏幕录制权限。系统图标和 macOS 更新可能限制位置；避免同时运行其他菜单栏管理工具。

安装前请核对 `SHA256SUMS` 的 SHA-256 值。本版同时提供源代码 ZIP 和 GitHub 自动生成的源代码压缩包。
