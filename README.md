# FixWin11MemLeak

Windows 11 25H2 上,核心分頁記憶體(paged pool)的 `Toke` 標籤會一直長,committed memory 跟著被咬住,只有重新開機能清。用 AI agent、Git Bash、PowerShell 等會大量開子程式的工具時特別明顯。這個 repo 放一支修正腳本與排程。

## 問題

- `win32kfull!CForegroundLaunch::_CheckAllowForeground` 在 `ForegroundLockTimeout` 不是 0 時,每次有程式建立子程式,就對父程式的主要權杖多呼叫一次 `PsReferencePrimaryToken`,但不釋放。
- 每份洩漏約 2–3 KB,程式結束也不會放。agent 一天開上百萬次子程式時,一兩天就累積數 GB。
- 登入時系統的 `LoadCPUserPreferences` 會把即時值寫成 2147483647(最容易觸發的值),登錄檔裡設 0 沒用,要在登入後再改「即時值」。
- 這是社群分析,Microsoft 尚未確認或修正。

### 本機實測(2026-11-08)

- Windows 11 25H2,build 26200.9711;即時值 2147483647。
- 開機約 37 小時後 `Toke` 4.7 GB、`SeAt` 0.8 GB,paged pool 共約 11 GB;重新開機後 `Toke` 約 10 MB。
- 登出不會清掉,要「重新啟動」。
- 套用後(即時值 0),從 Git Bash 各開 300 次 `bash -c true`、`rtk ls`、`git status`、`pwsh -c 1`,`Toke` 前後都在 ±0.05 MB 內;套用前同樣的測試每次約漏 1.5–5 KB。

## 用法

```powershell
pwsh -File fix-foreground-lock.ps1 -Install   # 立刻套用,並建立「每次登入後 1 分鐘自動套用」的排程
pwsh -File fix-foreground-lock.ps1 -Status    # 看目前即時值與排程
pwsh -File fix-foreground-lock.ps1            # 只套用一次
pwsh -File fix-foreground-lock.ps1 -Undo      # 改回 Windows 預設 200000 並移除排程
```

- 一般使用者權限即可,不需要系統管理員。
- 這個值只有「可以切換前景」的程式能改,背景執行(例如排程)直接呼叫會被系統忽略。腳本會先送一次 Shift 鍵讓自己成為最後一個有輸入的程式,失敗就每 2 秒重試,最多約 2 分鐘;仍失敗會印警告,請在前景的 PowerShell 視窗手動執行一次。
- 排程工作名稱 `FixWin11ForegroundLock`,登入後延遲 1 分鐘執行,避免被登入流程再次覆寫。
- 排程指向腳本目前所在路徑;搬動資料夾後要重跑 `-Install`。

## 副作用

- **任何程式都能直接搶到前景。** 值為 0 時,背景程式要求切到最前面不會被擋,也不會只在工作列閃爍;打字時可能被突然彈出的視窗搶走焦點。
- **套用時會模擬按一次 Shift 鍵。** 登入後 1 分鐘若正在打字或玩遊戲,可能感覺到一次多餘的 Shift(通常無影響;遊戲若把 Shift 綁成動作會觸發一下)。
- **不會釋放已經漏掉的權杖。** 套用前漏掉的要「重新啟動」才會清;用「關機」且開著快速啟動時,核心狀態會被保存,洩漏也會留著。可用系統管理員執行 `powercfg /h off` 關閉快速啟動(會一併停用休眠)。
- Windows 更新若修正了這個 bug,或改了登入時的行為,本修正可能變得不必要或失效;用 `-Status` 和下面的驗證方式確認。

## 驗證

1. `-Status` 顯示即時值為 0。
2. 用工具量 paged pool 的 `Toke` 標籤(例如 PoolMon,或以 `NtQuerySystemInformation(SystemPoolTagInformation)` 讀取),大量開子程式前後比較;修好後應接近不變。

## 參考

- https://github.com/gunrgbcr/windows-token-leak-logon-fix
- https://github.com/git-for-windows/git/issues/6471
- https://github.com/git-for-windows/git/issues/6499
- https://github.com/melodic-software/claude-code-plugins/issues/4372
- https://github.com/openai/codex/issues/54400
- https://blog.shukebeta.com/2026/10/12/windows-11-eating-2-gb-a-day-of-paged-pool-under-git-bash-set-foregroundlocktimeout-to-0-the-live-value
