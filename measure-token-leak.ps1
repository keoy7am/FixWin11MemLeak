# 量核心 paged pool 的 Toke(權杖)用量,並測「每開一個子程式會不會漏」。唯讀,一般權限即可。
#
#   pwsh -File measure-token-leak.ps1           顯示目前 Toke / SeAt 用量與 paged pool 前幾名
#   pwsh -File measure-token-leak.ps1 -Test 500 開 500 次子程式,比較前後 Toke,算每次漏多少
param([int]$Test = 0, [int]$Top = 8)

Add-Type -Namespace FixWin11 -Name Pool -MemberDefinition @'
[DllImport("ntdll.dll")] public static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
'@

# SystemPoolTagInformation(22)。64 位元 SYSTEM_POOLTAG 每筆 40 bytes,陣列從 offset 8 開始:
# Tag(4) PagedAllocs(4) PagedFrees(4) pad(4) PagedUsed(8) NonPagedAllocs(4) NonPagedFrees(4) NonPagedUsed(8)
function Get-PoolTags {
    $len = 1 -shl 20
    for ($i = 0; $i -lt 6; $i++) {
        $buf = [Runtime.InteropServices.Marshal]::AllocHGlobal($len)
        $ret = 0
        $st = [FixWin11.Pool]::NtQuerySystemInformation(22, $buf, $len, [ref]$ret)
        if ($st -eq 0) { break }
        [Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
        $len = [Math]::Max($ret, $len * 2)
    }
    if ($st -ne 0) { throw ('NtQuerySystemInformation 失敗 0x{0:X}' -f $st) }
    try {
        $count = [Runtime.InteropServices.Marshal]::ReadInt32($buf, 0)
        for ($k = 0; $k -lt $count; $k++) {
            $o = 8 + $k * 40
            $tag = New-Object byte[] 4
            [Runtime.InteropServices.Marshal]::Copy([IntPtr]($buf.ToInt64() + $o), $tag, 0, 4)
            [pscustomobject]@{
                Tag      = [Text.Encoding]::ASCII.GetString($tag)
                PagedKB  = [Math]::Round([Runtime.InteropServices.Marshal]::ReadInt64($buf, $o + 16) / 1KB, 1)
                PagedNum = [Runtime.InteropServices.Marshal]::ReadInt32($buf, $o + 4) - [Runtime.InteropServices.Marshal]::ReadInt32($buf, $o + 8)
            }
        }
    }
    finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buf) }
}

function Get-Toke { (Get-PoolTags | Where-Object Tag -eq 'Toke').PagedKB }

if ($Test -gt 0) {
    $before = Get-Toke
    for ($i = 0; $i -lt $Test; $i++) { & cmd.exe /c exit; & pwsh -NoProfile -Command 1 | Out-Null }
    $after = Get-Toke
    $per = [Math]::Round(($after - $before) / ($Test * 2), 2)
    "開了 $($Test * 2) 個子程式:Toke $before KB -> $after KB,平均每個 $per KB"
    if ($per -gt 0.5) { '看起來仍在洩漏(修好後應接近 0;背景程式會造成少量雜訊)' } else { '沒有明顯洩漏' }
    return
}

$tags = Get-PoolTags
$toke = $tags | Where-Object Tag -eq 'Toke'
$seat = $tags | Where-Object Tag -eq 'SeAt'
"Toke(權杖):$([Math]::Round($toke.PagedKB / 1KB, 1)) MB,$($toke.PagedNum) 個未釋放配置"
"SeAt(權杖安全屬性):$([Math]::Round($seat.PagedKB / 1KB, 1)) MB"
"--- paged pool 前 $Top 名(MB)"
$tags | Sort-Object PagedKB -Descending | Select-Object -First $Top Tag, @{n = 'MB'; e = { [Math]::Round($_.PagedKB / 1KB, 1) } } | Format-Table -AutoSize | Out-String -Width 80
