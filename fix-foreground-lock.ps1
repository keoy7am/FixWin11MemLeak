# 修 Windows 11 25H2 核心權杖(Toke)洩漏:把「即時」ForegroundLockTimeout 設成 0。
# win32kfull 在 ForegroundLockTimeout 非 0 時,每開一個子程式就多參照一份父程式的權杖且不釋放。
# 登入時系統會把即時值改回 2147483647,所以每次登入後都要再設一次(-Install 建登入排程)。
#
#   pwsh -File fix-foreground-lock.ps1            立刻套用並顯示前後值
#   pwsh -File fix-foreground-lock.ps1 -Install   套用並建立「登入後 1 分鐘自動套用」的排程工作
#   pwsh -File fix-foreground-lock.ps1 -Status    只顯示目前即時值與排程狀態
#   pwsh -File fix-foreground-lock.ps1 -Undo      改回 200000(Windows 預設)並移除排程工作
param([switch]$Install, [switch]$Undo, [switch]$Status)

Add-Type -Namespace FixWin11 -Name Spi -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint action, uint uiParam, ref uint value, uint winIni);
[DllImport("user32.dll", EntryPoint = "SystemParametersInfo")] public static extern bool SetValue(uint action, uint uiParam, IntPtr value, uint winIni);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@

$SPI_GET = 0x2000   # SPI_GETFOREGROUNDLOCKTIMEOUT
$SPI_SET = 0x2001   # SPI_SETFOREGROUNDLOCKTIMEOUT
$SPIF_SENDCHANGE = 2
$TaskName = 'FixWin11ForegroundLock'

function Get-Live {
    $v = 0
    [void][FixWin11.Spi]::SystemParametersInfo($SPI_GET, 0, [ref]$v, 0)
    $v
}

if ($Status) {
    "ForegroundLockTimeout live: $(Get-Live)"
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) { "排程工作:$($t.State)" } else { '排程工作:未建立' }
    return
}

$target = if ($Undo) { 200000 } else { 0 }
$before = Get-Live
# 只有「可以切換前景」的程式能改這個值;背景啟動時先送一次 Shift 鍵,讓本程式成為最後一個有輸入的程式,失敗就重試。
for ($i = 0; $i -lt 60 -and (Get-Live) -ne $target; $i++) {
    [FixWin11.Spi]::keybd_event(0x10, 0, 0, [UIntPtr]::Zero)
    [FixWin11.Spi]::keybd_event(0x10, 0, 2, [UIntPtr]::Zero)
    [void][FixWin11.Spi]::SetValue($SPI_SET, 0, [IntPtr]$target, $SPIF_SENDCHANGE)
    if ((Get-Live) -ne $target) { Start-Sleep -Seconds 2 }
}
$after = Get-Live
"ForegroundLockTimeout live: $before -> $after"
if ($after -ne $target) { Write-Warning '沒有套用成功:這個值只能由可切換前景的程式修改。請在前景的 PowerShell 視窗手動執行一次。' }

if ($Undo) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    '已移除登入排程'
}
elseif ($Install) {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument "-NoProfile -WindowStyle Hidden -File `"$PSCommandPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
    $trigger.Delay = 'PT1M'
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Description '登入後把 ForegroundLockTimeout 即時值設為 0,避免 Windows 11 25H2 權杖洩漏' -Force | Out-Null
    "已建立登入排程 $TaskName(登入後 1 分鐘執行,腳本位置 $PSCommandPath)"
}
