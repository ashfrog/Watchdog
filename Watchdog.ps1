# Watchdog (Production Hardened)
# 编码要求：UTF-8 with BOM
#
# 配置无桌面启动：Win + R -> regedit
# 路径：HKEY_CURRENT_USER\Software\Microsoft\Windows NT\CurrentVersion\Winlogon
# 键名：Shell (右键新建 字符串值)
# 数值：powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Watchdog\watchdog.ps1"
#
# 紧急停用：
#   创建文件 C:\Watchdog\disable.flag
#   Watchdog 检测到后将停止拉起目标程序，仅记录日志
#
# 启动程序列表字段说明：
# First:              首次启动延迟秒数
# Restart:            异常重启前等待秒数
# Arguments:          传递给程序的额外参数
# Once:               $false=持续监控  $true=仅启动一次
# HideWindow:         $true=隐藏窗口启动  $false=正常显示
# FocusTop:           $true=允许置顶并抢焦点（建议仅 kiosk 场景启用）
# Fullscreen:         $true=目标为全屏  $false=目标为窗口化
# ForceDisplayMode:   $true=启用显示模式修复  $false=不干预窗口模式
#                     （网页 URL 条目建议保持 $false，浏览器 --kiosk 自行管理全屏）
# PythonExe:          可选，指定 python.exe / pythonw.exe 所在路径；为空则走系统 PATH
# ConsoleMode:        控制台模式（仅脚本类有效）
#                     	Auto=按默认兼容行为启动
#                     	Shared=与 Watchdog 共用当前控制台（无控制台环境会自动回退）
#                     	New=单独新建控制台窗口
# AllowMultiInstance: $true=允许多实例并存  $false=仅保留一个
# KillTreeOnHang:     $true=挂死时结束进程树  $false=仅结束主进程
# MinUpSeconds:       启动后若很快退出，按失败重启节流处理
# Browser:            网页 URL 条目专用，指定打开浏览器
#                     	auto=自动检测（优先 Chrome，其次 Edge）
#                     	chrome=Google Chrome
#                     	msedge=Microsoft Edge
#
# 【网页 URL 支持】
#   将 http:// 或 https:// 开头的 URL 作为 Key，Watchdog 会通过 Chrome/Edge 打开并持续守护。
#   Fullscreen=$true 时以 --kiosk 模式启动（真正无边框全屏），$false 时最大化窗口。
#   每个 URL 使用独立的浏览器 Profile（存于 $WatchdogRoot\browser_profiles\），
#   进程检测仅匹配该 Profile 的主进程，不会误杀子渲染进程。

$Apps = [ordered]@{
    "https://www.baidu.com" = @{
        First = 1; Restart = 5; Arguments = ""
        Once = $false; HideWindow = $false; FocusTop = $true
        Fullscreen = $true; ForceDisplayMode = $true; PythonExe = ""
        ConsoleMode = "Auto"; AllowMultiInstance = $false; KillTreeOnHang = $true
        MinUpSeconds = 15; Browser = "auto"
    }
    # "C:\Scripts\test.bat" = @{
    #     First = 1; Restart = 5; Arguments = ""
    #     Once = $false; HideWindow = $false; FocusTop = $false
    #     Fullscreen = $false; ForceDisplayMode = $false; PythonExe = ""
    #     ConsoleMode = "New"; AllowMultiInstance = $false; KillTreeOnHang = $true
    #     MinUpSeconds = 3; Browser = "auto"
    # }
    # "C:\Scripts\main.py" = @{
    #     First = 1; Restart = 10; Arguments = ""
    #     Once = $false; HideWindow = $false; FocusTop = $false
    #     Fullscreen = $false; ForceDisplayMode = $false; PythonExe = "C:\Python311\python.exe"
    #     ConsoleMode = "New"; AllowMultiInstance = $false; KillTreeOnHang = $true
    #     MinUpSeconds = 5; Browser = "auto"
    # }
}

# =================== 1. 全局配置 ===================
$WatchdogRoot    = "C:\Watchdog"
$LogPath         = Join-Path $WatchdogRoot "watchdog_log.txt"
$DisableFlag     = Join-Path $WatchdogRoot "disable.flag"

$MaxLogSizeMB    = 10
$MaxLogBackups   = 3
$CheckInterval   = 3
$MaxRetryInHour  = 10
$GCCollectEvery  = 100

# 连续 N 次检测到不响应后才执行挂死重启，避免偶发卡顿触发误重启
$HangConsecutiveFailuresToRestart = 3

# 启动后最短再次尝试间隔，避免同一轮/短时间重复拉起
$MinRestartGapSeconds = 2

# 启动后延迟 N 秒再做第一次窗口模式修复
$FullscreenRepairDelay = 4

# 是否每轮巡检都持续修复窗口模式（生产默认建议 false）
$DisplayLoopRepair = $false

# 同一程序两次抢焦点之间最短间隔秒数
$FocusCooldownSeconds = 30

# 脚本类进程尽量按完整路径匹配
$MatchFullPathForScripts = $true

# 脚本类命令行匹配时是否需要严格引号边界（为兼容复杂场景默认 false）
$StrictScriptPathBoundary = $false

# =================== 2. 核心保护：防止 Watchdog 自身多开 ===================
$Script:MutexOwned = $false
$Script:MutexReleaseState = 0
$Script:Mutex = New-Object System.Threading.Mutex($false, "Global\WindowsWatchdogServiceMutex")
try {
    $Script:MutexOwned = $Script:Mutex.WaitOne(0)
}
catch [System.Threading.AbandonedMutexException] {
    $Script:MutexOwned = $true
}

function WdReleaseMutexSafe {
    if ([System.Threading.Interlocked]::Exchange([ref]$Script:MutexReleaseState, 1) -eq 1) { return }

    if ($Script:Mutex) {
        if ($Script:MutexOwned) {
            try { $Script:Mutex.ReleaseMutex() } catch {
                try { Write-Host "WARN: Failed to release mutex: $($_.Exception.Message)" } catch {}
            }
        }
        try { $Script:Mutex.Dispose() } catch {
            try { Write-Host "WARN: Failed to dispose mutex: $($_.Exception.Message)" } catch {}
        }
    }

    $Script:MutexOwned = $false
    $Script:Mutex = $null
}

if (-not $Script:MutexOwned) {
    Write-Host "Another instance is already running. Exiting."
    WdReleaseMutexSafe
    exit 1
}

# =================== 3. 全局 Win32 API 注入 ===================
if (-not ([System.Management.Automation.PSTypeName]'WatchdogWin32.DisplayAPI').Type) {
    $displayApiCode = @"
using System;
using System.Runtime.InteropServices;

namespace WatchdogWin32
{
    public static class DisplayAPI
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int left, top, right, bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct MONITORINFO
        {
            public int cbSize;
            public RECT rcMonitor;
            public RECT rcWork;
            public int dwFlags;
        }

        [DllImport("user32.dll")]
        public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll")]
        public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);

        [DllImport("user32.dll")]
        public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr ProcessId);

        [DllImport("kernel32.dll")]
        public static extern uint GetCurrentThreadId();

        [DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll")]
        public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

        [DllImport("user32.dll")]
        public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();
    }
}
"@
    try {
        Add-Type -TypeDefinition $displayApiCode -Language CSharp -ErrorAction Stop
    }
    catch {
        Write-Host "FATAL: Failed to load Win32 API type: $($_.Exception.Message)"
        WdReleaseMutexSafe
        exit 1
    }
}

# =================== 4. 日志 StreamWriter 管理 ===================
$Script:LogWriter = $null
$Script:IsRotatingLog = $false
$Script:PathErrorLogged = @{}

function WdOpenLogWriter {
    try {
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        $Script:LogWriter = New-Object System.IO.StreamWriter($LogPath, $true, $utf8Bom)
        $Script:LogWriter.AutoFlush = $true
    }
    catch {
        $Script:LogWriter = $null
    }
}

function WdCloseLogWriter {
    if ($Script:LogWriter) {
        try {
            $Script:LogWriter.Flush()
            $Script:LogWriter.Close()
            $Script:LogWriter.Dispose()
        }
        catch {}
        $Script:LogWriter = $null
    }
}

# =================== 5. 辅助函数 ===================

function WdRotateLog {
    if (-not (Test-Path $LogPath)) { return }
    $file = Get-Item $LogPath -ErrorAction SilentlyContinue
    if (-not $file -or $file.Length -le ($MaxLogSizeMB * 1MB)) { return }

    $Script:IsRotatingLog = $true
    WdCloseLogWriter

    try {
        for ($i = $MaxLogBackups; $i -ge 1; $i--) {
            $src = "${LogPath}.bak.$i"
            if (Test-Path $src) {
                if ($i -eq $MaxLogBackups) {
                    Remove-Item $src -Force -ErrorAction SilentlyContinue
                }
                else {
                    $dst = "${LogPath}.bak.$($i + 1)"
                    Move-Item $src $dst -Force -ErrorAction SilentlyContinue
                }
            }
        }

        Move-Item $LogPath "${LogPath}.bak.1" -Force -ErrorAction Stop

        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText(
            $LogPath,
            "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === Log rotated. Backup: ${LogPath}.bak.1 ===`r`n",
            $utf8Bom
        )
    }
    catch {
        try {
            $utf8Bom = New-Object System.Text.UTF8Encoding($true)
            [System.IO.File]::WriteAllText(
                $LogPath,
                "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === Log truncated (rotation failed: $($_.Exception.Message)) ===`r`n",
                $utf8Bom
            )
        }
        catch {}
    }
    finally {
        WdOpenLogWriter
        $Script:IsRotatingLog = $false
    }
}

function WdWriteLog {
    param(
        [string]$Message,
        [string]$Color = "White"
    )

    $Stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line  = "[$Stamp] $Message"

    try {
        Write-Host $Line -ForegroundColor $Color
    }
    catch {}

    if ($Script:IsRotatingLog) { return }

    if ($Script:LogWriter) {
        try {
            $Script:LogWriter.WriteLine($Line)
            return
        }
        catch {
            $Script:LogWriter = $null
        }
    }

    try {
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::AppendAllText($LogPath, $Line + [Environment]::NewLine, $utf8Bom)
    }
    catch {}
}

function WdEnsureDirectory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function WdNormalizePathSafe {
    param([string]$Path)
    try {
        return [System.IO.Path]::GetFullPath($Path).Trim().ToLowerInvariant()
    }
    catch {
        return $Path.Trim().ToLowerInvariant()
    }
}

function WdTestDisableFlag {
    return (Test-Path $DisableFlag)
}

function WdInitializeCounter {
    param(
        [hashtable]$Table,
        [string]$Key,
        $DefaultValue = 0
    )
    if (-not $Table.ContainsKey($Key) -or $null -eq $Table[$Key]) {
        $Table[$Key] = $DefaultValue
    }
}

function WdCleanupRestartStats {
    param(
        [hashtable]$Table,
        [int]$CurrentHour
    )
    $keys = @($Table.Keys)
    foreach ($key in $keys) {
        if ($key -match '::H(\d{1,2})$') {
            $hour = [int]$Matches[1]
            if ($hour -ne $CurrentHour) {
                $Table.Remove($key)
            }
        }
    }
}

$Script:AppConfigDefaults = [ordered]@{
    First              = 1
    Restart            = 5
    Arguments          = ""
    Once               = $false
    HideWindow         = $false
    FocusTop           = $false
    Fullscreen         = $false
    ForceDisplayMode   = $false
    PythonExe          = ""
    ConsoleMode        = "Auto"
    AllowMultiInstance = $false
    KillTreeOnHang     = $true
    MinUpSeconds       = 5
    Browser            = "auto"
}
$Script:AppConfigMin = [ordered]@{
    First        = 1
    Restart      = 1
    MinUpSeconds = 1
}

function WdResolveAppConfig {
    param(
        [string]$Path,
        [hashtable]$Config
    )

    $rawConfig = if ($null -eq $Config) { @{} } else { $Config }
    $resolved = [ordered]@{}
    foreach ($key in $Script:AppConfigDefaults.Keys) {
        $resolved[$key] = if ($rawConfig.ContainsKey($key)) { $rawConfig[$key] } else { $Script:AppConfigDefaults[$key] }
    }

    try { $resolved.First = [Math]::Max([int]$Script:AppConfigMin.First, [int]$resolved.First) } catch {
        $resolved.First = [int]$Script:AppConfigDefaults.First
        WdWriteLog "CONFIG-WARN: [$Path] invalid First value; fallback to $($resolved.First)." "DarkYellow"
    }
    try { $resolved.Restart = [Math]::Max([int]$Script:AppConfigMin.Restart, [int]$resolved.Restart) } catch {
        $resolved.Restart = [int]$Script:AppConfigDefaults.Restart
        WdWriteLog "CONFIG-WARN: [$Path] invalid Restart value; fallback to $($resolved.Restart)." "DarkYellow"
    }
    try { $resolved.MinUpSeconds = [Math]::Max([int]$Script:AppConfigMin.MinUpSeconds, [int]$resolved.MinUpSeconds) } catch {
        $resolved.MinUpSeconds = [int]$Script:AppConfigDefaults.MinUpSeconds
        WdWriteLog "CONFIG-WARN: [$Path] invalid MinUpSeconds value; fallback to $($resolved.MinUpSeconds)." "DarkYellow"
    }

    $resolved.Arguments          = [string]$resolved.Arguments
    $resolved.PythonExe          = [string]$resolved.PythonExe
    $resolved.Once               = [bool]$resolved.Once
    $resolved.HideWindow         = [bool]$resolved.HideWindow
    $resolved.FocusTop           = [bool]$resolved.FocusTop
    $resolved.Fullscreen         = [bool]$resolved.Fullscreen
    $resolved.ForceDisplayMode   = [bool]$resolved.ForceDisplayMode
    $resolved.AllowMultiInstance = [bool]$resolved.AllowMultiInstance
    $resolved.KillTreeOnHang     = [bool]$resolved.KillTreeOnHang

    $consoleMode = [string]$resolved.ConsoleMode
    if ([string]::IsNullOrWhiteSpace($consoleMode)) { $consoleMode = [string]$Script:AppConfigDefaults.ConsoleMode }
    $resolved.ConsoleMode = $consoleMode.Trim()

    $browserName = [string]$resolved.Browser
    if ([string]::IsNullOrWhiteSpace($browserName)) { $browserName = [string]$Script:AppConfigDefaults.Browser }
    $resolved.Browser = $browserName.Trim()

    if (-not (WdIsBrowserUrl -Path $Path)) {
        if ($resolved.Browser -ne [string]$Script:AppConfigDefaults.Browser) {
            WdWriteLog "CONFIG-INFO: [$Path] Browser option is only used for URL entries and will be ignored." "DarkGray"
        }
        $resolved.Browser = [string]$Script:AppConfigDefaults.Browser
    }

    return $resolved
}

function WdGetPythonInterpreter {
    param(
        [bool]$HideWindow,
        [string]$PythonExe
    )

    if (-not [string]::IsNullOrWhiteSpace($PythonExe)) {
        if ($HideWindow) {
            $dir = Split-Path $PythonExe -Parent
            $pyw = Join-Path $dir "pythonw.exe"
            if (Test-Path $pyw) { return $pyw }
        }
        if (Test-Path $PythonExe) { return $PythonExe }
    }

    if ($HideWindow) { return "pythonw.exe" }
    return "python.exe"
}

function WdGetConsoleMode {
    param([hashtable]$Config)

    if ($null -eq $Config) { return "Auto" }
    if ($Config.ContainsKey("ConsoleMode") -and -not [string]::IsNullOrWhiteSpace([string]$Config.ConsoleMode)) {
        return ([string]$Config.ConsoleMode).Trim()
    }
    return "Auto"
}

function WdIsConsoleWindowPresent {
    try {
        $h = [WatchdogWin32.DisplayAPI]::GetConsoleWindow()
        return ($h -ne [IntPtr]::Zero)
    }
    catch {
        return $false
    }
}

function WdResolveConsoleMode {
    param(
        [string]$RequestedMode,
        [bool]$HideWindow
    )

    if ($HideWindow) { return "Hidden" }

    $mode = if ([string]::IsNullOrWhiteSpace($RequestedMode)) { "Auto" } else { $RequestedMode.Trim() }

    if ($mode -ieq "Shared" -and -not (WdIsConsoleWindowPresent)) {
        WdWriteLog "START: Shared console requested but current host has no console. Fallback to New." "DarkYellow"
        return "New"
    }

    return $mode
}

function WdStartByConsoleMode {
    param(
        [string]$LaunchPath,
        [string]$LaunchArgs,
        [string]$WorkingDirectory,
        [string]$FileName,
        [string]$EffectiveMode,
        [string]$CommandPreview
    )

    $modeLower = if ([string]::IsNullOrWhiteSpace($EffectiveMode)) {
        "auto"
    }
    else {
        $EffectiveMode.Trim().ToLowerInvariant()
    }

    if ($modeLower -eq "hidden") {
        WdWriteLog "START: Launching [$FileName] hidden CMD=[$CommandPreview]" "DarkCyan"
        return Start-Process -FilePath $LaunchPath `
            -ArgumentList $LaunchArgs `
            -WorkingDirectory $WorkingDirectory `
            -WindowStyle Hidden `
            -PassThru
    }

    switch ($modeLower) {
        "shared" {
            WdWriteLog "START: Launching [$FileName] in shared console CMD=[$CommandPreview]" "DarkCyan"
            return Start-Process -FilePath $LaunchPath `
                -ArgumentList $LaunchArgs `
                -WorkingDirectory $WorkingDirectory `
                -NoNewWindow `
                -PassThru
        }
        default {
            $modeText = if ($modeLower -eq "new") { "new console" } else { "auto mode" }
            WdWriteLog "START: Launching [$FileName] in $modeText CMD=[$CommandPreview]" "DarkCyan"
            return Start-Process -FilePath $LaunchPath `
                -ArgumentList $LaunchArgs `
                -WorkingDirectory $WorkingDirectory `
                -PassThru
        }
    }
}

function WdIsScriptPathInCommandLine {
    param(
        [string]$CommandLine,
        [string]$TargetPath
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($TargetPath)) {
        return $false
    }

    $cmd = $CommandLine.ToLowerInvariant()
    $target = (WdNormalizePathSafe $TargetPath)

    if (-not $StrictScriptPathBoundary) {
        return $cmd.Contains($target)
    }

    $escaped = [Regex]::Escape($target)
    return ($cmd -match "(^|[\s`"'])$escaped($|[\s`"'])")
}

function WdGetTargetProcess {
    param(
        [string]$Path
    )

    $CurrentPID     = [System.Diagnostics.Process]::GetCurrentProcess().Id
    $NormalizedPath = WdNormalizePathSafe $Path

    if (WdIsBrowserUrl -Path $Path) {
        $profileBase = Join-Path $WatchdogRoot "browser_profiles"
        $profileDir  = (Join-Path $profileBase (WdSanitizeForPath -Url $Path)).ToLowerInvariant()
        return Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $procName = $_.Name.ToLowerInvariant() -replace '\.exe$', ''
            $cmdLine  = if ($_.CommandLine) { $_.CommandLine.ToLowerInvariant() } else { "" }
            $_.ProcessId -ne $CurrentPID -and
            ($procName -eq "chrome" -or $procName -eq "msedge") -and
            $cmdLine.Contains($profileDir) -and
            $cmdLine -notmatch '--type='
        }
    }

    try {
        if ($Path.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase)) {
            return Get-Process -ErrorAction SilentlyContinue | Where-Object {
                $_.Id -ne $CurrentPID -and $_.Path -and (WdNormalizePathSafe $_.Path) -eq $NormalizedPath
            }
        }
        else {
            $SearchName = if ($Path.EndsWith(".py", [System.StringComparison]::OrdinalIgnoreCase)) {
                "python"
            }
            elseif ($Path.EndsWith(".bat", [System.StringComparison]::OrdinalIgnoreCase) -or
                    $Path.EndsWith(".cmd", [System.StringComparison]::OrdinalIgnoreCase)) {
                "cmd"
            }
            else {
                "powershell"
            }

            $wmiFilter = "Name like '$SearchName%'"
            $candidates = Get-CimInstance Win32_Process -Filter $wmiFilter -ErrorAction SilentlyContinue |
                Where-Object { $_.ProcessId -ne $CurrentPID }

            if ($MatchFullPathForScripts) {
                return $candidates | Where-Object {
                    $_.CommandLine -and (WdIsScriptPathInCommandLine -CommandLine $_.CommandLine -TargetPath $Path)
                }
            }
            else {
                $nameNeedle = [System.IO.Path]::GetFileName($Path).ToLowerInvariant()
                return $candidates | Where-Object {
                    $_.CommandLine -and $_.CommandLine.ToLowerInvariant().Contains($nameNeedle)
                }
            }
        }
    }
    catch {
        return $null
    }
}

# =================== 5.x 浏览器 URL 辅助函数 ===================

function WdIsBrowserUrl {
    param([string]$Path)
    return ($Path -imatch '^https?://')
}

function WdSanitizeForPath {
    param([string]$Url)
    # Use truncated human-readable prefix + 8-char MD5 suffix to guarantee uniqueness
    $md5    = [System.Security.Cryptography.MD5]::Create()
    $hash   = ($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Url)) |
               ForEach-Object { $_.ToString("x2") }) -join ''
    $md5.Dispose()
    $short  = $hash.Substring(0, 8)
    $prefix = ($Url -replace '^https?://', '' -replace '[^\w\-.]', '_')
    if ($prefix.Length -gt 40) { $prefix = $prefix.Substring(0, 40) }
    return "${prefix}_${short}"
}

function WdResolveBrowserExe {
    param([string]$Browser)

    $chromePaths = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LocalAppData\Google\Chrome\Application\chrome.exe"
    )
    $edgePaths = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    )

    $pref = if ([string]::IsNullOrWhiteSpace($Browser)) { "auto" } else { $Browser.Trim().ToLowerInvariant() }

    if ($pref -in @("chrome", "google", "googlechrome")) {
        foreach ($p in $chromePaths) { if (Test-Path $p) { return $p } }
        return "chrome.exe"
    }
    if ($pref -in @("edge", "msedge", "microsoft", "microsoftedge")) {
        foreach ($p in $edgePaths) { if (Test-Path $p) { return $p } }
        return "msedge.exe"
    }
    # auto: prefer Chrome, fall back to Edge
    foreach ($p in $chromePaths) { if (Test-Path $p) { return $p } }
    foreach ($p in $edgePaths)   { if (Test-Path $p) { return $p } }
    return "chrome.exe"
}

function WdWaitForWindowHandle {
    param(
        $ProcessObj,
        [int]$TimeoutMs = 5000
    )

    $elapsed = 0
    while ($ProcessObj -and $ProcessObj.MainWindowHandle -eq [IntPtr]::Zero -and $elapsed -lt $TimeoutMs) {
        Start-Sleep -Milliseconds 100
        try { $ProcessObj.Refresh() } catch { break }
        $elapsed += 100
    }

    if ($ProcessObj) { return $ProcessObj.MainWindowHandle }
    return [IntPtr]::Zero
}

function WdIsWindowForeground {
    param($Hwnd)
    try {
        $fg = [WatchdogWin32.DisplayAPI]::GetForegroundWindow()
        return ($fg -eq $Hwnd)
    }
    catch { return $false }
}

function WdSetWindowToForeground {
    param($ProcessObj)

    if ($null -eq $ProcessObj) { return $false }

    $HWND_TOPMOST    = [IntPtr]-1
    $HWND_NOTOPMOST  = [IntPtr]-2
    $SWP_NOSIZE      = 0x0001
    $SWP_NOMOVE      = 0x0002
    $TOPMOST_FLAGS   = $SWP_NOSIZE -bor $SWP_NOMOVE
    $VK_MENU         = 0x12
    $KEYEVENTF_KEYUP = 0x0002

    $hwnd = WdWaitForWindowHandle -ProcessObj $ProcessObj
    if ($hwnd -eq [IntPtr]::Zero) { return $false }

    if (WdIsWindowForeground -Hwnd $hwnd) { return $true }

    $currentThreadId = [WatchdogWin32.DisplayAPI]::GetCurrentThreadId()
    $targetThreadId  = [WatchdogWin32.DisplayAPI]::GetWindowThreadProcessId($hwnd, [IntPtr]::Zero)
    $attached = $false

    try {
        if ($currentThreadId -ne $targetThreadId -and $targetThreadId -ne 0) {
            [WatchdogWin32.DisplayAPI]::AttachThreadInput($currentThreadId, $targetThreadId, $true) | Out-Null
            $attached = $true
        }

        [WatchdogWin32.DisplayAPI]::keybd_event($VK_MENU, 0, 0, [UIntPtr]::Zero)
        [WatchdogWin32.DisplayAPI]::keybd_event($VK_MENU, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)

        [WatchdogWin32.DisplayAPI]::ShowWindow($hwnd, 9) | Out-Null
        [WatchdogWin32.DisplayAPI]::SetWindowPos($hwnd, $HWND_TOPMOST, 0, 0, 0, 0, $TOPMOST_FLAGS) | Out-Null
        [WatchdogWin32.DisplayAPI]::SetForegroundWindow($hwnd) | Out-Null

        Start-Sleep -Milliseconds 150
        [WatchdogWin32.DisplayAPI]::SetWindowPos($hwnd, $HWND_NOTOPMOST, 0, 0, 0, 0, $TOPMOST_FLAGS) | Out-Null

        return $true
    }
    catch { return $false }
    finally {
        if ($attached) {
            try {
                [WatchdogWin32.DisplayAPI]::AttachThreadInput($currentThreadId, $targetThreadId, $false) | Out-Null
            }
            catch {}
        }
    }
}

function WdRepairWindowDisplayMode {
    param(
        $ProcessObj,
        [bool]$Fullscreen
    )

    if ($null -eq $ProcessObj) { return }

    $hwnd = WdWaitForWindowHandle -ProcessObj $ProcessObj -TimeoutMs 3000
    if ($hwnd -eq [IntPtr]::Zero) {
        WdWriteLog "DISPLAY: Window handle not ready, skipping repair." "DarkGray"
        return
    }

    $GWL_STYLE           = -16
    $WS_CAPTION          = 0x00C00000
    $WS_THICKFRAME       = 0x00040000
    $WS_SYSMENU          = 0x00080000
    $WS_MINIMIZEBOX      = 0x00020000
    $WS_MAXIMIZEBOX      = 0x00010000
    $WS_OVERLAPPEDWINDOW = $WS_CAPTION -bor $WS_THICKFRAME -bor $WS_SYSMENU -bor $WS_MINIMIZEBOX -bor $WS_MAXIMIZEBOX
    $SWP_FRAMECHANGED    = 0x0020
    $SWP_SHOWWINDOW      = 0x0040
    $SWP_NOZORDER        = 0x0004
    $MONITOR_NEAREST     = 0x00000002
    $HWND_TOP            = [IntPtr]::Zero

    $winRect = New-Object WatchdogWin32.DisplayAPI+RECT
    [WatchdogWin32.DisplayAPI]::GetWindowRect($hwnd, [ref]$winRect) | Out-Null

    $hMonitor = [WatchdogWin32.DisplayAPI]::MonitorFromWindow($hwnd, $MONITOR_NEAREST)
    $mi       = New-Object WatchdogWin32.DisplayAPI+MONITORINFO
    $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mi)
    [WatchdogWin32.DisplayAPI]::GetMonitorInfo($hMonitor, [ref]$mi) | Out-Null

    $mLeft   = $mi.rcMonitor.left
    $mTop    = $mi.rcMonitor.top
    $mWidth  = $mi.rcMonitor.right  - $mi.rcMonitor.left
    $mHeight = $mi.rcMonitor.bottom - $mi.rcMonitor.top

    $isFullscreen = (
        [Math]::Abs($winRect.left                     - $mLeft)   -le 4 -and
        [Math]::Abs($winRect.top                      - $mTop)    -le 4 -and
        [Math]::Abs(($winRect.right  - $winRect.left) - $mWidth)  -le 4 -and
        [Math]::Abs(($winRect.bottom - $winRect.top)  - $mHeight) -le 4
    )

    if ($Fullscreen -and -not $isFullscreen) {
        WdWriteLog "DISPLAY: Forcing fullscreen for PID $($ProcessObj.Id)..." "Yellow"
        $curStyle = [WatchdogWin32.DisplayAPI]::GetWindowLong($hwnd, $GWL_STYLE)
        $newStyle = $curStyle -band (-bnot $WS_OVERLAPPEDWINDOW)
        [WatchdogWin32.DisplayAPI]::SetWindowLong($hwnd, $GWL_STYLE, $newStyle) | Out-Null
        [WatchdogWin32.DisplayAPI]::ShowWindow($hwnd, 9) | Out-Null
        [WatchdogWin32.DisplayAPI]::SetWindowPos(
            $hwnd, $HWND_TOP,
            $mLeft, $mTop, $mWidth, $mHeight,
            ($SWP_FRAMECHANGED -bor $SWP_SHOWWINDOW -bor $SWP_NOZORDER)
        ) | Out-Null
        WdWriteLog "DISPLAY: Fullscreen applied ($mWidth x $mHeight)." "Green"
    }
    elseif (-not $Fullscreen -and $isFullscreen) {
        WdWriteLog "DISPLAY: Forcing windowed for PID $($ProcessObj.Id)..." "Yellow"
        $curStyle = [WatchdogWin32.DisplayAPI]::GetWindowLong($hwnd, $GWL_STYLE)
        $newStyle = $curStyle -bor $WS_OVERLAPPEDWINDOW
        [WatchdogWin32.DisplayAPI]::SetWindowLong($hwnd, $GWL_STYLE, $newStyle) | Out-Null

        $winW = [Math]::Min(1280, [Math]::Max(640, $mWidth - 100))
        $winH = [Math]::Min(720,  [Math]::Max(480, $mHeight - 100))
        $winX = $mLeft + [int](($mWidth  - $winW) / 2)
        $winY = $mTop  + [int](($mHeight - $winH) / 2)

        [WatchdogWin32.DisplayAPI]::ShowWindow($hwnd, 9) | Out-Null
        [WatchdogWin32.DisplayAPI]::SetWindowPos(
            $hwnd, $HWND_TOP,
            $winX, $winY, $winW, $winH,
            ($SWP_FRAMECHANGED -bor $SWP_SHOWWINDOW -bor $SWP_NOZORDER)
        ) | Out-Null
        WdWriteLog "DISPLAY: Windowed applied (${winW}x${winH} @ $winX,$winY)." "Green"
    }
}

function WdStopProcessTreeSafe {
    param(
        [int]$ProcessId,
        [bool]$KillTree
    )

    if ($ProcessId -le 0) { return }

    try {
        if ($KillTree) {
            & taskkill.exe /PID $ProcessId /T /F | Out-Null
        }
        else {
            Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    catch {}
}

function WdIsProcessMissing {
    param([string]$Path)
    $procs = WdGetTargetProcess -Path $Path
    $count = if ($procs) { ($procs | Measure-Object).Count } else { 0 }

    if ($procs) {
        $procs | ForEach-Object {
            if ($_ -is [System.Diagnostics.Process]) {
                try { $_.Dispose() } catch {}
            }
        }
    }

    return ($count -eq 0)
}

function WdStartApp {
    param(
        [string]$Path,
        [string]$Arguments,
        [string]$FileName,
        [bool]$HideWindow,
        [bool]$FocusTop,
        [bool]$Fullscreen,
        [string]$PythonExe,
        [string]$ConsoleMode = "Auto",
        [string]$Browser = "auto"
    )

    # ---- 网页 URL 处理 ----
    if (WdIsBrowserUrl -Path $Path) {
        $browserExe  = WdResolveBrowserExe -Browser $Browser
        $profileBase = Join-Path $WatchdogRoot "browser_profiles"
        $profileDir  = Join-Path $profileBase (WdSanitizeForPath -Url $Path)

        $browserArgs = @(
            "--user-data-dir=`"$profileDir`"",
            "--no-first-run",
            "--disable-infobars",
            "--disable-session-crashed-bubble"
        )
        if ($Fullscreen) {
            $browserArgs += "--kiosk"
        }
        else {
            $browserArgs += "--start-maximized"
        }
        if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
            $browserArgs += $Arguments
        }
        $browserArgs += "`"$Path`""
        $argStr = $browserArgs -join " "

        try {
            WdWriteLog "START: Launching [$FileName] via [$browserExe] Args=[$argStr]" "DarkCyan"
            $proc = Start-Process -FilePath $browserExe -ArgumentList $argStr -PassThru -ErrorAction Stop
            if ($proc) {
                WdWriteLog "SUCCESS: Started $FileName PID=$($proc.Id) (Browser=$browserExe, Fullscreen=$Fullscreen)" "Green"
            }
            else {
                WdWriteLog "SUCCESS: Started $FileName (PID unavailable) (Browser=$browserExe, Fullscreen=$Fullscreen)" "Green"
            }
            return $proc
        }
        catch {
            WdWriteLog "FAILED: $FileName (browser) - $($_.Exception.Message)" "Red"
            return $null
        }
    }

    if (-not (Test-Path $Path)) {
        if (-not $Script:PathErrorLogged[$Path]) {
            WdWriteLog "ERROR: Path not found [$Path]" "Red"
            $Script:PathErrorLogged[$Path] = $true
        }
        return $null
    }
    $Script:PathErrorLogged[$Path] = $false

    $Dir = [System.IO.Path]::GetDirectoryName($Path)
    $effectiveMode = WdResolveConsoleMode -RequestedMode $ConsoleMode -HideWindow:$HideWindow

    if ($Path.EndsWith(".bat", [System.StringComparison]::OrdinalIgnoreCase) -or
        $Path.EndsWith(".cmd", [System.StringComparison]::OrdinalIgnoreCase)) {

        try {
            $quotedPath = "`"$Path`""
            $argText    = if ([string]::IsNullOrWhiteSpace($Arguments)) { "" } else { " $Arguments" }
            $cmdArgs = "/c $quotedPath$argText"
            $cmdPreview = "cmd.exe $cmdArgs"
            $proc = WdStartByConsoleMode `
                -LaunchPath "cmd.exe" `
                -LaunchArgs $cmdArgs `
                -WorkingDirectory $Dir `
                -FileName $FileName `
                -EffectiveMode $effectiveMode `
                -CommandPreview $cmdPreview

            if ($proc) {
                WdWriteLog "SUCCESS: Started $FileName PID=$($proc.Id) (Hide=$HideWindow, ConsoleMode=$effectiveMode, FocusTop=$FocusTop, Fullscreen=$Fullscreen)" "Green"
            }
            else {
                WdWriteLog "SUCCESS: Started $FileName (PID unavailable) (Hide=$HideWindow, ConsoleMode=$effectiveMode, FocusTop=$FocusTop, Fullscreen=$Fullscreen)" "Green"
            }

            return $proc
        }
        catch {
            WdWriteLog "FAILED: $FileName - $($_.Exception.Message)" "Red"
            return $null
        }
    }

    if ($Path.EndsWith(".py", [System.StringComparison]::OrdinalIgnoreCase)) {
        try {
            $pyExe  = WdGetPythonInterpreter -HideWindow:$HideWindow -PythonExe $PythonExe
            $pyArgs = if ([string]::IsNullOrWhiteSpace($Arguments)) {
                "`"$Path`""
            }
            else {
                "`"$Path`" $Arguments"
            }
            $cmdPreview = "$pyExe $pyArgs"
            $proc = WdStartByConsoleMode `
                -LaunchPath $pyExe `
                -LaunchArgs $pyArgs `
                -WorkingDirectory $Dir `
                -FileName $FileName `
                -EffectiveMode $effectiveMode `
                -CommandPreview $cmdPreview

            if ($proc) {
                WdWriteLog "SUCCESS: Started $FileName PID=$($proc.Id) (Hide=$HideWindow, ConsoleMode=$effectiveMode, FocusTop=$FocusTop, Fullscreen=$Fullscreen)" "Green"
            }
            else {
                WdWriteLog "SUCCESS: Started $FileName (PID unavailable) (Hide=$HideWindow, ConsoleMode=$effectiveMode, FocusTop=$FocusTop, Fullscreen=$Fullscreen)" "Green"
            }

            return $proc
        }
        catch {
            WdWriteLog "FAILED: $FileName - $($_.Exception.Message)" "Red"
            return $null
        }
    }

    $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $StartInfo.WorkingDirectory = $Dir
    $StartInfo.UseShellExecute  = $false

    if ($HideWindow) {
        $StartInfo.CreateNoWindow = $true
        $StartInfo.WindowStyle    = [System.Diagnostics.ProcessWindowStyle]::Hidden
    }
    else {
        $StartInfo.CreateNoWindow = $false
        $StartInfo.WindowStyle    = [System.Diagnostics.ProcessWindowStyle]::Normal
    }

    $StartInfo.FileName = $Path
    $extraArgs = $Arguments
    $StartInfo.Arguments = $extraArgs

    $proc = $null
    try {
        $cmdLine = "$($StartInfo.FileName) $($StartInfo.Arguments)".Trim()
        WdWriteLog "START: Launching [$FileName] CMD=[$cmdLine]" "DarkCyan"

        $proc = [System.Diagnostics.Process]::Start($StartInfo)

        if ($proc) {
            WdWriteLog "SUCCESS: Started $FileName PID=$($proc.Id) (Hide=$HideWindow, FocusTop=$FocusTop, Fullscreen=$Fullscreen)" "Green"
        }
        else {
            WdWriteLog "SUCCESS: Started $FileName (PID unavailable) (Hide=$HideWindow, FocusTop=$FocusTop, Fullscreen=$Fullscreen)" "Green"
        }

        if ($FocusTop -and -not $HideWindow -and $proc) {
            Start-Sleep -Milliseconds 500
            [void](WdSetWindowToForeground -ProcessObj $proc)
        }

        return $proc
    }
    catch {
        WdWriteLog "FAILED: $FileName - $($_.Exception.Message)" "Red"
        if ($proc) { try { $proc.Dispose() } catch {} }
        return $null
    }
}

# =================== 5.1 Compatibility layer (legacy -> Wd* APIs) ===================
# Keep legacy function-name wrappers to preserve runtime compatibility.
# New integrations should use Wd* interface names directly.
function Open-LogWriter { return WdOpenLogWriter @PSBoundParameters }
function Close-LogWriter { return WdCloseLogWriter @PSBoundParameters }
function Write-WatchdogLog { return WdWriteLog @PSBoundParameters }
function Test-DisableFlag { return WdTestDisableFlag @PSBoundParameters }
function Initialize-CounterIfNeeded { return WdInitializeCounter @PSBoundParameters }
function Get-PythonInterpreter { return WdGetPythonInterpreter @PSBoundParameters }
function Get-ConsoleMode { return WdGetConsoleMode @PSBoundParameters }
function Test-HasConsoleWindow { return WdIsConsoleWindowPresent @PSBoundParameters }
function Resolve-EffectiveConsoleMode { return WdResolveConsoleMode @PSBoundParameters }
function Test-IsScriptPathInCommandLine { return WdIsScriptPathInCommandLine @PSBoundParameters }
function Get-TargetProcess { return WdGetTargetProcess @PSBoundParameters }
function Wait-ForWindowHandle { return WdWaitForWindowHandle @PSBoundParameters }
function Test-IsWindowForeground { return WdIsWindowForeground @PSBoundParameters }
function Set-WindowToForeground { return WdSetWindowToForeground @PSBoundParameters }
function Repair-WindowDisplayMode { return WdRepairWindowDisplayMode @PSBoundParameters }
function Stop-ProcessTreeSafe { return WdStopProcessTreeSafe @PSBoundParameters }
function Test-ProcessStillMissing { return WdIsProcessMissing @PSBoundParameters }
function Start-App { return WdStartApp @PSBoundParameters }

# =================== 6. 初始化 ===================
WdEnsureDirectory -Path $WatchdogRoot
WdOpenLogWriter

WdWriteLog "=== Watchdog Service Active (Monitor Count: $($Apps.Count)) ===" "Yellow"
WdWriteLog "INFO: Disable flag path = $DisableFlag" "DarkGray"
WdWriteLog "INFO: Check interval = $CheckInterval sec, Max retry/hour = $MaxRetryInHour" "DarkGray"
WdWriteLog "INFO: Log max size = ${MaxLogSizeMB}MB, Backups = $MaxLogBackups" "DarkGray"
WdWriteLog "INFO: GC collect every $GCCollectEvery iterations (~$($GCCollectEvery * $CheckInterval) sec)" "DarkGray"
WdWriteLog "INFO: Min restart gap = $MinRestartGapSeconds sec, Display loop repair = $DisplayLoopRepair" "DarkGray"
WdWriteLog "INFO: Hang restart threshold = $HangConsecutiveFailuresToRestart consecutive failures" "DarkGray"

$FirstRun          = $true
$RestartStats      = @{}
$LaunchTime        = @{}
$DisplayRepairDone = @{}
$FocusLastTime     = @{}
$LastStartAttempt  = @{}
$ThrottleWarned    = @{}
$MissingLogged     = @{}
$HangFailCount     = @{}
$Script:GCCounter  = 0

# =================== 7. 主循环 ===================
try {
    while ($true) {
        try {
            WdRotateLog
            $CurrentHour = (Get-Date).Hour
            WdCleanupRestartStats -Table $RestartStats -CurrentHour $CurrentHour
            WdCleanupRestartStats -Table $ThrottleWarned -CurrentHour $CurrentHour

            if (WdTestDisableFlag) {
                WdWriteLog "SAFE-MODE: Disable flag detected. Monitoring paused; no app will be launched or restarted." "Yellow"
                $FirstRun = $false
                Start-Sleep -Seconds $CheckInterval
                continue
            }

            foreach ($Path in $Apps.Keys) {
                $Config   = WdResolveAppConfig -Path $Path -Config $Apps[$Path]
                if (WdIsBrowserUrl -Path $Path) {
                    try { $FileName = "[$(([System.Uri]$Path).Host)]" }
                    catch {
                        WdWriteLog "WARN: Could not parse URL [$Path] as URI; using raw string as display name." "DarkYellow"
                        $FileName = $Path
                    }
                }
                else {
                    $FileName = [System.IO.Path]::GetFileName($Path)
                }
                $isExe    = $Path.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase)
                $isUrl    = WdIsBrowserUrl -Path $Path

                $StatKey  = "${Path}::H${CurrentHour}"
                $OnceKey  = "${Path}::Once"

                WdInitializeCounter -Table $RestartStats -Key $StatKey -DefaultValue 0

                if ($RestartStats[$StatKey] -ge $MaxRetryInHour) {
                    if (-not $ThrottleWarned.ContainsKey($StatKey)) {
                        WdWriteLog "CRITICAL: $FileName failed too many times this hour ($($RestartStats[$StatKey])/$MaxRetryInHour). Skipping until next hour..." "Red"
                        $ThrottleWarned[$StatKey] = $true
                    }
                    continue
                }

                $allowMultiInstance = [bool]$Config.AllowMultiInstance
                $killTreeOnHang = [bool]$Config.KillTreeOnHang
                $browserName = [string]$Config.Browser
                $minUpSeconds = [int]$Config.MinUpSeconds

                $procs     = WdGetTargetProcess -Path $Path
                $procCount = if ($procs -is [array]) { $procs.Count } elseif ($procs) { 1 } else { 0 }

                if ($procCount -eq 0) {
                    $HangFailCount[$Path] = 0
                    if ($Config.Once -and $RestartStats.ContainsKey($OnceKey) -and $RestartStats[$OnceKey]) {
                        continue
                    }

                    if ($LastStartAttempt.ContainsKey($Path) -and $LastStartAttempt[$Path]) {
                        $sinceLastStart = ((Get-Date) - $LastStartAttempt[$Path]).TotalSeconds
                        if ($sinceLastStart -lt $MinRestartGapSeconds) {
                            WdWriteLog "THROTTLE: $FileName skipped; only $([int]$sinceLastStart)s since last start attempt." "DarkYellow"
                            continue
                        }
                    }

                    $WaitTime = if ($FirstRun) { [int]$Config.First } else { [int]$Config.Restart }
                    if (-not $MissingLogged[$Path]) {
                        WdWriteLog "MISSING: $FileName, launch scheduled in $WaitTime sec..." "Cyan"
                        $MissingLogged[$Path] = $true
                    }
                    Start-Sleep -Seconds $WaitTime

                    if (-not (WdIsProcessMissing -Path $Path)) {
                        $MissingLogged[$Path] = $false
                        WdWriteLog "SKIP: $FileName already started by another source during wait window." "DarkYellow"
                        continue
                    }

                    $LastStartAttempt[$Path] = Get-Date

                    $proc = WdStartApp `
                        -Path        $Path `
                        -Arguments   ([string]$Config.Arguments) `
                        -FileName    $FileName `
                        -HideWindow  ([bool]$Config.HideWindow) `
                        -FocusTop    ([bool]$Config.FocusTop) `
                        -Fullscreen  ([bool]$Config.Fullscreen) `
                        -PythonExe   ([string]$Config.PythonExe) `
                        -ConsoleMode (WdGetConsoleMode -Config $Config) `
                        -Browser     $browserName

                    if ($proc) {
                        $RestartStats[$StatKey] = [int]$RestartStats[$StatKey] + 1
                        $LaunchTime[$Path] = Get-Date
                        $DisplayRepairDone[$Path] = $false
                        $HangFailCount[$Path] = 0

                        if ([bool]$Config.ForceDisplayMode -and -not [bool]$Config.HideWindow) {
                            WdRepairWindowDisplayMode -ProcessObj $proc -Fullscreen ([bool]$Config.Fullscreen)
                        }

                        if ($Config.Once) {
                            $RestartStats[$OnceKey] = $true
                        }

                        try { $proc.Dispose() } catch {}
                        $proc = $null
                    }
                }
                else {
                    $MissingLogged[$Path] = $false
                    if (-not $allowMultiInstance -and $procCount -gt 1) {
                        WdWriteLog "CONFLICT: $procCount instances of $FileName detected. Cleaning up extra instances..." "Magenta"
                        $procs | Select-Object -Skip 1 | ForEach-Object {
                            $TargetID = if ($null -ne $_.Id) { $_.Id } else { $_.ProcessId }
                            try {
                                WdStopProcessTreeSafe -ProcessId $TargetID -KillTree $true
                                WdWriteLog "CLEANUP: Killed extra instance PID=$TargetID for $FileName" "DarkMagenta"
                            }
                            catch {}

                            if ($_ -is [System.Diagnostics.Process]) {
                                try { $_.Dispose() } catch {}
                            }
                        }
                    }

                    $FirstProc = if ($procs -is [array]) { $procs[0] } else { $procs }
                    if ($null -eq $FirstProc) {
                        if ($procs) {
                            $procs | ForEach-Object {
                                if ($_ -is [System.Diagnostics.Process]) { try { $_.Dispose() } catch {} }
                            }
                        }
                        continue
                    }

                    $TargetID = if ($null -ne $FirstProc.Id) { $FirstProc.Id } else { $FirstProc.ProcessId }
                    $mainProc = Get-Process -Id $TargetID -ErrorAction SilentlyContinue

                    if ($null -eq $mainProc) {
                        if ($procs) {
                            $procs | ForEach-Object {
                                if ($_ -is [System.Diagnostics.Process]) { try { $_.Dispose() } catch {} }
                            }
                        }
                        continue
                    }

                    try {
                        if ($isExe -and -not $mainProc.Responding) {
                            WdInitializeCounter -Table $HangFailCount -Key $Path -DefaultValue 0
                            $HangFailCount[$Path]++
                            $hangFailTimes = $HangFailCount[$Path]

                            if ($hangFailTimes -lt $HangConsecutiveFailuresToRestart) {
                                WdWriteLog "HANG-WARN: $FileName (PID:$TargetID) not responding ($hangFailTimes/$HangConsecutiveFailuresToRestart). Waiting for consecutive confirmation..." "DarkYellow"
                                continue
                            }

                            WdWriteLog "HANG: $FileName (PID:$TargetID) not responding for $hangFailTimes consecutive checks. Restarting..." "Red"
                            $HangFailCount[$Path] = 0

                            WdStopProcessTreeSafe -ProcessId $TargetID -KillTree $killTreeOnHang
                            Start-Sleep -Seconds ([int]$Config.Restart)

                            if (-not (WdIsProcessMissing -Path $Path)) {
                                WdWriteLog "SKIP: $FileName recovered or restarted externally after hang handling." "DarkYellow"
                                continue
                            }

                            $LastStartAttempt[$Path] = Get-Date

                            $proc = WdStartApp `
                                -Path        $Path `
                                -Arguments   ([string]$Config.Arguments) `
                                -FileName    $FileName `
                                -HideWindow  ([bool]$Config.HideWindow) `
                                -FocusTop    ([bool]$Config.FocusTop) `
                                -Fullscreen  ([bool]$Config.Fullscreen) `
                                -PythonExe   ([string]$Config.PythonExe) `
                                -ConsoleMode (WdGetConsoleMode -Config $Config) `
                                -Browser     $browserName

                            if ($proc) {
                                $RestartStats[$StatKey] = [int]$RestartStats[$StatKey] + 1
                                $LaunchTime[$Path] = Get-Date
                                $DisplayRepairDone[$Path] = $false
                                $HangFailCount[$Path] = 0

                                if ([bool]$Config.ForceDisplayMode -and -not [bool]$Config.HideWindow) {
                                    WdRepairWindowDisplayMode -ProcessObj $proc -Fullscreen ([bool]$Config.Fullscreen)
                                }

                                try { $proc.Dispose() } catch {}
                                $proc = $null
                            }
                            continue
                        }
                        elseif ($isExe -and $HangFailCount.ContainsKey($Path) -and [int]$HangFailCount[$Path] -gt 0) {
                            WdWriteLog "HANG-RECOVERED: $FileName (PID:$TargetID) responding again; reset consecutive hang counter." "DarkGreen"
                            $HangFailCount[$Path] = 0
                        }

                        if ([bool]$Config.ForceDisplayMode -and -not [bool]$Config.HideWindow) {
                            $needRepair = $false

                            if (-not $DisplayRepairDone.ContainsKey($Path) -or -not $DisplayRepairDone[$Path]) {
                                if ($LaunchTime.ContainsKey($Path) -and $LaunchTime[$Path] -and
                                    ((Get-Date) - $LaunchTime[$Path]).TotalSeconds -ge $FullscreenRepairDelay) {
                                    $needRepair = $true
                                    $DisplayRepairDone[$Path] = $true
                                }
                            }
                            elseif ($DisplayLoopRepair) {
                                $needRepair = $true
                            }

                            if ($needRepair) {
                                WdRepairWindowDisplayMode -ProcessObj $mainProc -Fullscreen ([bool]$Config.Fullscreen)
                            }
                        }

                        if ([bool]$Config.FocusTop -and -not [bool]$Config.HideWindow -and ($isExe -or $isUrl)) {
                            $allowFocus = $true

                            if ($FocusLastTime.ContainsKey($Path) -and $FocusLastTime[$Path]) {
                                $elapsed = ((Get-Date) - $FocusLastTime[$Path]).TotalSeconds
                                if ($elapsed -lt $FocusCooldownSeconds) {
                                    $allowFocus = $false
                                }
                            }

                            if ($allowFocus) {
                                $fgHwnd = [IntPtr]::Zero
                                try { $fgHwnd = $mainProc.MainWindowHandle } catch {} # process may have just exited; leave fgHwnd as Zero
                                if ($fgHwnd -ne [IntPtr]::Zero -and (WdIsWindowForeground -Hwnd $fgHwnd)) {
                                    # Already in foreground; reset cooldown to skip redundant attempts
                                    $FocusLastTime[$Path] = Get-Date
                                } elseif (WdSetWindowToForeground -ProcessObj $mainProc) {
                                    $FocusLastTime[$Path] = Get-Date
                                    WdWriteLog "FOCUS: Brought $FileName (PID:$TargetID) to foreground." "DarkCyan"
                                }
                            }
                        }
                    }
                    finally {
                        try { $mainProc.Dispose() } catch {}
                        $mainProc = $null
                    }

                    if ($FirstProc -is [System.Diagnostics.Process]) {
                        try { $FirstProc.Dispose() } catch {}
                    }
                    $FirstProc = $null
                }

                if ($procs) {
                    $procs | ForEach-Object {
                        if ($_ -is [System.Diagnostics.Process]) { try { $_.Dispose() } catch {} }
                    }
                    $procs = $null
                }
            }

            $FirstRun = $false

            $Script:GCCounter++
            if ($Script:GCCounter -ge $GCCollectEvery) {
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
                $Script:GCCounter = 0
            }
        }
        catch {
            WdWriteLog "LOOP-ERROR: Unhandled exception in main loop: $($_.Exception.Message)" "Red"
            WdWriteLog "LOOP-ERROR: StackTrace: $($_.ScriptStackTrace)" "DarkRed"
        }

        Start-Sleep -Seconds $CheckInterval
    }
}
finally {
    try { WdWriteLog "=== Watchdog shutting down. Releasing resources... ===" "Yellow" } catch {}
    WdCloseLogWriter

    WdReleaseMutexSafe
}
