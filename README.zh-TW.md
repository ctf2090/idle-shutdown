# idle-shutdown

[English](README.md) | [繁體中文](README.zh-TW.md)

用於 Linux VM 的閒置自動關機工具，重點支援 SSH 與 RDP 使用情境。

本專案以 Debian 套件形式發佈（`Architecture: all`），內容包含：
- `idle-shutdown.sh` 決策引擎
- systemd timer/service 單元檔
- SSH/RDP 活動 marker 輔助程式
- 打包、smoke test 與 release 自動化

## 功能說明

`idle-shutdown` 會依照閒置策略決定是否關機：
- `connections` 模式：只要有已建立的 SSH/RDP TCP 連線就視為活躍。
- `activity` 模式：即使連線仍存在，也以使用者活動 marker 判斷是否閒置並關機。
- 預設模式是 `activity`（由 `/etc/default/idle-shutdown` 設定）：會透過 hook 追蹤實際使用者輸入訊號，SSH 以 prompt 週期（按 Enter 後）活動為準，RDP 以鍵盤/滑鼠事件為準。

這適合雲端 VM 情境，在不影響實際使用中的連線前提下控制成本。

## 運作方式

主要 runtime 元件：
- `idle-shutdown.timer`：週期性觸發 `idle-shutdown.service`。
- `idle-shutdown.service`：執行 `/usr/local/sbin/idle-shutdown.sh`。
- `idle-rdp-disconnect-watch.service`：RDP 中斷時清除過期 marker。
- `idle-ssh-disconnect-watch.service`：SSH 中斷時清除過期 marker。
- `idle-ssh-tty-audit-watch.service`：追蹤 Linux audit TTY 事件並更新 SSH marker。
- `/etc/profile.d/idle-terminal-activity.sh`：由 shell 活動更新 SSH marker mtime。
- `/usr/local/sbin/idle-ssh-tty-audit-enable.sh`：讓 `/etc/pam.d/sshd` 與 tty-audit 設定保持一致。
- `/usr/local/sbin/idle-rdp-input-watch.sh`：由桌面輸入事件更新 RDP marker mtime。

第二次開機 gate：
- 腳本會透過 `PROVISIONING_DONE_BOOT_ID_PATH` 做啟用門檻。
- 若 marker 檔不存在，腳本會直接結束，不執行關機判斷。
- 目的是避免在第一次開機 provisioning 期間被誤觸發關機。

## SSH/RDP 輸入 Hook

`idle-shutdown` 會用 marker 檔案表示最近的使用者輸入活動。

SSH 鍵盤活動 hook：
- 檔案：`/etc/profile.d/idle-terminal-activity.sh`
- 觸發模型：在互動式 SSH `pts/*` shell 注入 `PROMPT_COMMAND`。
- 行為：每次進入 prompt 週期時更新 marker mtime（通常是按 Enter 後），不是每個 raw key event 都記錄。
- Marker 路徑：
  - 優先：`/run/user/<uid>/idle-terminal-activity-ssh-<tty_tag>`
  - 備援：`/tmp/idle-terminal-activity-<uid>-ssh-<tty_tag>`

SSH raw key 活動 hook（預設啟用）：
- 檔案：`/usr/local/sbin/idle-ssh-tty-audit-enable.sh`、`/usr/local/sbin/idle-ssh-tty-audit-watch.sh`
- 觸發模型：`sshd` 的 `pam_tty_audit` + watcher 讀取 `auditd` TTY 記錄（`type=TTY`）。
- 行為：在每次按鍵類事件更新同一組 SSH marker（包含 `vim` 這類全螢幕 TUI 程式）。
- 注意：這是加強機制，會與既有 `PROMPT_COMMAND` 並行，不是取代。

RDP 鍵盤/滑鼠活動 hook：
- 檔案：`/usr/local/sbin/idle-rdp-input-watch.sh`（由桌面 autostart 啟動）。
- 觸發模型：在 GUI session 監聽 `xinput test-xi2 --root` 事件流。
- 行為：遇到 XI2 鍵盤/按鍵/滑鼠移動事件就更新 marker mtime。
- Marker 路徑：
  - 優先：`/run/user/<uid>/idle-rdp-input-activity`
  - 備援：`/tmp/idle-rdp-input-activity-<uid>`

Marker 清理 hook：
- SSH disconnect watcher（`idle-ssh-disconnect-watch.service`）會追 journal/auth log，移除已關閉 session 的 SSH marker。
- RDP disconnect watcher（`idle-rdp-disconnect-watch.service`）會追 `xrdp-sesman` log，在確認 TCP 斷線後移除單一使用者或全部 RDP marker。

`IDLE_MODE=activity` 下的判斷方式：
- `idle-shutdown.sh` 讀取 marker mtime，計算 `now - mtime` 的 idle 秒數。
- 以所有有效 marker 中「最近一次活動」作為使用者活躍時間。
- marker 消失或超過 `IDLE_MINUTES` 時，觸發關機。

## 專案結構

- `idle-shutdown.sh`：主要判斷邏輯。
- `systemd/`：systemd 單元檔來源。
- `assets/`：打包的 runtime 設定/腳本（default env、profile/autostart/watch scripts）。
- `debian/`：Debian 打包 metadata。
- `test/idle-shutdown-smoke.sh`：以 mock 指令執行功能 smoke test。
- `export-idle-shutdown-assets.py`：將本地 assets 匯出到打包 staging tree。
- `.github/workflows/deb-package.yml`：套件 CI workflow。

## Runtime 設定

預設設定檔：`assets/etc/default/idle-shutdown`（安裝後為 `/etc/default/idle-shutdown`）。

主要參數：
- `IDLE_SHUTDOWN_ENABLED`（預設 `1`）：全域開關。
- `IDLE_MINUTES`（設定檔預設 `15`；腳本 fallback `20`）：閒置門檻。
- `IDLE_MODE`（`connections` 或 `activity`，設定檔預設 `activity`）。
- `BOOT_GRACE_MINUTES`（設定檔預設 `0`）：額外開機寬限時間。
- `STATUS_PERIOD_MINUTES`（預設 `3`）：週期性狀態日誌間隔。
- `RDP_TCP_PORT`（預設 `3389`）：檢查已建立 RDP 連線的 TCP port。
- `RDP_DISCONNECT_GRACE_SECONDS`（預設 `90`）：清理過期 RDP marker 的寬限秒數。
- `XRDP_SESMAN_LOG_PATH`、`SSH_LOG_UNIT`、`SSH_AUTH_LOG_PATH`：watcher 日誌來源。
- `SSH_TTY_AUDIT_ENABLED`（預設 `1`）：啟用 `pam_tty_audit` 與 tty-audit marker watcher。
- `SSH_TTY_AUDIT_LOG_PATH`（預設 `/var/log/audit/audit.log`）：tty 事件 audit log 來源。
- `SSH_TTY_AUDIT_LOG_PASSWD`（預設 `0`）：除非明確需求，應維持 `0` 以避免記錄密碼字元。
- `SSH_TTY_AUDIT_MIN_TOUCH_INTERVAL_SEC`（預設 `1`）：每個 `(uid, tty)` marker 更新去抖間隔。
- `IDLE_SHUTDOWN_STATE_DIR`（腳本 fallback `/var/lib/idle-shutdown`）。
- `PROVISIONING_DONE_BOOT_ID_PATH`（腳本 fallback `$IDLE_SHUTDOWN_STATE_DIR/provisioning_done_boot_id`）。

## 本地開發

前置需求（Ubuntu/Debian）：

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  build-essential debhelper devscripts dh-python dpkg-dev python3
```

執行檢查：

```bash
make check
```

只跑功能 smoke：

```bash
make idle-smoke
```

建置套件：

```bash
make DEB_ARCH=all deb-build
```

建置 + 套件 smoke test：

```bash
make DEB_ARCH=all deb-smoke
```

建置產物會放到 `release/`。

## Release 流程

執行完整本地 release：

```bash
make release
```

`make release` 會做：
1. 解析/重用/建立 release tag（`idle-shutdown-v*`）
2. 執行 `make check`
3. 執行 `make DEB_ARCH=all deb-smoke`
4. 建立/更新 annotated tag metadata

Tag 與版本規則：
- Debian 套件版本會和 release tag 同步為 `<tag-version>-1`。
- 若 tag 已存在於其他 commit，會自動遞增版本。

## 在目標 VM 安裝

從本地建置或下載的套件安裝：

```bash
sudo apt-get install -y ./idle-shutdown_<version>_all.deb
```

安裝後 postinst 會 enable/start：
- `idle-shutdown.timer`
- `idle-rdp-disconnect-watch.service`
- `idle-ssh-disconnect-watch.service`
- `idle-ssh-tty-audit-watch.service`

驗證：

```bash
systemctl status idle-shutdown.timer
systemctl status idle-rdp-disconnect-watch.service
systemctl status idle-ssh-disconnect-watch.service
systemctl status idle-ssh-tty-audit-watch.service
journalctl -u idle-shutdown.service -n 100 --no-pager
```

非我們 GCE cloud-init 佈署流程的手動安裝注意：
- 請確認 `PROVISIONING_DONE_BOOT_ID_PATH` 存在，且內容與目前 `/proc/sys/kernel/random/boot_id` 不同；否則腳本會依設計持續跳過判斷。

## CI/CD

`idle-shutdown` 在本 repo 有獨立 GitHub Actions workflow：
- Workflow：`.github/workflows/deb-package.yml`
- 在 push/PR/manual trigger 執行 `check + deb-smoke`
- 上傳 `.deb/.changes/.buildinfo` artifact
- tag push（`idle-shutdown-v*`）時，附加套件檔案到 GitHub Release
