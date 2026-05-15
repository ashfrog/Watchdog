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
#   或直接打开任务管理器
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
# HideCursor:         $true=程序运行期间隐藏系统鼠标光标  $false=保持系统默认光标显示
#                     （仅对 exe 类条目有效；适用于 Unity 等全屏 kiosk 程序）
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
        MinUpSeconds = 15; Browser = "auto"; HideCursor = $false
    }
    # "C:\Scripts\test.bat" = @{
    #     First = 1; Restart = 5; Arguments = ""
    #     Once = $false; HideWindow = $false; FocusTop = $false
    #     Fullscreen = $false; ForceDisplayMode = $false; PythonExe = ""
    #     ConsoleMode = "New"; AllowMultiInstance = $false; KillTreeOnHang = $true
    #     MinUpSeconds = 3; Browser = "auto"; HideCursor = $false
    # }
    # "C:\Scripts\main.py" = @{
    #     First = 1; Restart = 10; Arguments = ""
    #     Once = $false; HideWindow = $false; FocusTop = $false
    #     Fullscreen = $false; ForceDisplayMode = $false; PythonExe = "C:\Python311\python.exe"
    #     ConsoleMode = "New"; AllowMultiInstance = $false; KillTreeOnHang = $true
    #     MinUpSeconds = 5; Browser = "auto"; HideCursor = $false
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

# =================== 1.5 Win32 / 时序常量 ===================
# ShowWindow nCmdShow 命令
$SW_RESTORE              = 9            # 若最小化则还原，否则激活并显示

# SetWindowPos uFlags
$SWP_NOSIZE              = 0x0001       # 保持当前大小
$SWP_NOMOVE              = 0x0002       # 保持当前位置
$SWP_NOZORDER            = 0x0004       # 保持当前 Z 序
$SWP_FRAMECHANGED        = 0x0020       # 应用 SetWindowLong 的样式变更
$SWP_SHOWWINDOW          = 0x0040       # 显示窗口
$SWP_TOPMOST_FLAGS       = $SWP_NOSIZE -bor $SWP_NOMOVE   # 置顶/解除置顶时使用

# SetWindowPos hWndInsertAfter 特殊句柄
$HWND_TOP                = [IntPtr]::Zero   # Z 序最前（非置顶）
$HWND_TOPMOST            = [IntPtr]-1       # 置顶（始终位于普通窗口之上）
$HWND_NOTOPMOST          = [IntPtr]-2       # 解除置顶

# GetWindowLong / SetWindowLong 索引
$GWL_STYLE               = -16          # 窗口样式

# 窗口样式位掩码
$WS_CAPTION              = 0x00C00000   # 标题栏（含边框）
$WS_THICKFRAME           = 0x00040000   # 可调大小边框
$WS_SYSMENU              = 0x00080000   # 系统菜单
$WS_MINIMIZEBOX          = 0x00020000   # 最小化按钮
$WS_MAXIMIZEBOX          = 0x00010000   # 最大化按钮
$WS_OVERLAPPEDWINDOW     = $WS_CAPTION -bor $WS_THICKFRAME -bor $WS_SYSMENU -bor $WS_MINIMIZEBOX -bor $WS_MAXIMIZEBOX

# MonitorFromWindow dwFlags
$MONITOR_NEAREST         = 0x00000002   # 返回与窗口距离最近的监视器

# 键盘 / 鼠标事件常量
$VK_MENU                 = 0x12         # Alt 键虚拟键码
$KEYEVENTF_KEYUP         = 0x0002       # 键释放事件标志
$MOUSEEVENTF_MOVE        = 0x0001       # 鼠标移动事件标志

# 系统光标常量
$OCR_NORMAL              = 32512        # 标准箭头光标资源 ID
$SPI_SETCURSORS          = 0x0057       # SystemParametersInfo：重置光标方案
$WD_CURSOR_SIZE          = 32           # 透明光标位图的宽高（像素，32x32）

# 时序常量（毫秒）
$WD_WINDOW_HANDLE_POLL_MS  = 100        # WdWaitForWindowHandle 的轮询间隔
$WD_FOCUS_SETTLE_MS        = 150        # 置顶后等待窗口完成激活的延迟
$WD_INITIAL_FOCUS_DELAY_MS = 500        # 进程启动后首次抢焦点前的等待时间

# 全屏检测与窗口模式修复
$WD_FULLSCREEN_TOLERANCE_PX = 4         # 全屏判定允许的像素误差
$WD_WINDOWED_MAX_W       = 1280         # 窗口模式修复的最大默认宽度
$WD_WINDOWED_MAX_H       = 720          # 窗口模式修复的最大默认高度
$WD_WINDOWED_MIN_W       = 640          # 窗口模式修复的最小默认宽度
$WD_WINDOWED_MIN_H       = 480          # 窗口模式修复的最小默认高度
$WD_WINDOWED_MARGIN      = 100          # 窗口模式修复时距屏幕边缘的间距

# =================== 2. 核心保护：防止 Watchdog 自身多开 ===================
$Script:MutexOwned = $false
$Script:Mutex = New-Object System.Threading.Mutex($false, "Global\WindowsWatchdogServiceMutex")
try {
    $Script:MutexOwned = $Script:Mutex.WaitOne(0)
}
catch [System.Threading.AbandonedMutexException] {
    $Script:MutexOwned = $true
}

if (-not $Script:MutexOwned) {
    Write-Host "Another instance is already running. Exiting."
    $Script:Mutex.Dispose()
    exit 1
}

# =================== 2.5 退出清理钩子 ===================
$Script:ShutdownCleanupDone = $false

function WdInvokeShutdownCleanup {
    if ($Script:ShutdownCleanupDone) { return }
    $Script:ShutdownCleanupDone = $true

    # 恢复系统光标（若之前被隐藏）
    try {
        if (Get-Command WdRestoreSystemCursor -ErrorAction SilentlyContinue) {
            WdRestoreSystemCursor
        }
    }
    catch {}

    # 关闭日志写入器
    try {
        if (Get-Command WdCloseLogWriter -ErrorAction SilentlyContinue) {
            WdCloseLogWriter
        }
    }
    catch {}

    # 释放单实例互斥体
    try {
        if ($Script:Mutex) {
            if ($Script:MutexOwned) {
                try { $Script:Mutex.ReleaseMutex() } catch {}
                $Script:MutexOwned = $false
            }
            try { $Script:Mutex.Dispose() } catch {}
            $Script:Mutex = $null
        }
    }
    catch {}
}

Register-EngineEvent PowerShell.Exiting -Action {
    try { WdInvokeShutdownCleanup } catch {}
} -SupportEvent | Out-Null

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
        public static extern void mouse_event(uint dwFlags, int dx, int dy, uint dwData, UIntPtr dwExtraInfo);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern IntPtr CreateCursor(IntPtr hInst, int xHotSpot, int yHotSpot, int nWidth, int nHeight, byte[] pvANDPlane, byte[] pvXORPlane);

        [DllImport("user32.dll")]
        public static extern bool DestroyCursor(IntPtr hCursor);

        [DllImport("user32.dll")]
        public static extern bool SetSystemCursor(IntPtr hcur, uint id);

        [DllImport("user32.dll")]
        public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);
    }
}
"@
    $_addTypeFailed = $false
    try {
        Add-Type -TypeDefinition $displayApiCode -Language CSharp -ErrorAction Stop
    }
    catch {
        Write-Host "FATAL: Failed to load Win32 API type: $($_.Exception.Message)"
        $_addTypeFailed = $true
    }
    finally {
        if ($_addTypeFailed) {
            try { WdInvokeShutdownCleanup } catch {}
            exit 1
        }
    }
}

# =================== 4. 日志 StreamWriter 管理 ===================
$Script:LogWriter = $null
$Script:IsRotatingLog = $false
$Script:PathErrorLogged = @{}

function WdOpenLogWriter {
    try {
        $utf8Bom = WdGetUtf8BomEncoding
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

function WdGetUtf8BomEncoding {
    # Returns a UTF-8 encoding instance with BOM (Byte Order Mark) enabled,
    # used consistently for all log file writes.
    return New-Object System.Text.UTF8Encoding($true)
}

function WdWriteProcessStartLog {
    # Writes a SUCCESS log entry after a process is launched.
    # FileName : display name of the started app
    # Proc     : the Process object returned by Start-Process, or $null if unavailable
    # Details  : additional context string appended to the log line (e.g. hide/focus flags)
    param(
        [string]$FileName,
        $Proc,
        [string]$Details
    )
    if ($Proc) {
        WdWriteLog "SUCCESS: Started $FileName PID=$($Proc.Id) ($Details)" "Green"
    }
    else {
        WdWriteLog "SUCCESS: Started $FileName (PID unavailable) ($Details)" "Green"
    }
}

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

        $utf8Bom = WdGetUtf8BomEncoding
        [System.IO.File]::WriteAllText(
            $LogPath,
            "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === Log rotated. Backup: ${LogPath}.bak.1 ===`r`n",
            $utf8Bom
        )
    }
    catch {
        try {
            $utf8Bom = WdGetUtf8BomEncoding
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
        $utf8Bom = WdGetUtf8BomEncoding
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

function WdGetDisableReason {
    if (Test-Path $DisableFlag) {
        return "disable.flag"
    }

    if (Get-Process -Name "taskmgr" -ErrorAction SilentlyContinue) {
        return "Task Manager"
    }

    return $null
}

function WdTestDisableFlag {
    return [bool](WdGetDisableReason)
}

$Script:LastDisableReason = $null

function WdUpdateDisableState {
    param([string]$DisableReason)

    if ($DisableReason) {
        WdRestoreSystemCursor
        if ($Script:LastDisableReason -ne $DisableReason) {
            WdWriteLog "SAFE-MODE: $DisableReason detected. Monitoring paused; no app will be launched or restarted." "Yellow"
            $Script:LastDisableReason = $DisableReason
        }
        return $true
    }

    if ($Script:LastDisableReason) {
        WdWriteLog "SAFE-MODE: $($Script:LastDisableReason) cleared. Monitoring resumed." "DarkGreen"
        $Script:LastDisableReason = $null
    }

    return $false
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

# Returns the OS process ID regardless of whether the object is a
# System.Diagnostics.Process (.Id) or a CIM Win32_Process (.ProcessId).
function WdGetProcessId {
    param($ProcessObj)
    if ($ProcessObj -is [System.Diagnostics.Process]) { return $ProcessObj.Id }
    return $ProcessObj.ProcessId
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
        return Get-CimInstance Win32_Process -Filter "Name='chrome.exe' OR Name='msedge.exe'" -ErrorAction SilentlyContinue | Where-Object {
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
            $exeName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
            return Get-Process -Name $exeName -ErrorAction SilentlyContinue | Where-Object {
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

$Script:SanitizeForPathCache = @{}

function WdSanitizeForPath {
    param([string]$Url)
    if ($Script:SanitizeForPathCache.ContainsKey($Url)) {
        return $Script:SanitizeForPathCache[$Url]
    }
    # Use truncated human-readable prefix + 8-char MD5 suffix to guarantee uniqueness
    $md5    = [System.Security.Cryptography.MD5]::Create()
    $hash   = ($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Url)) |
               ForEach-Object { $_.ToString("x2") }) -join ''
    $md5.Dispose()
    $short  = $hash.Substring(0, 8)
    $prefix = ($Url -replace '^https?://', '' -replace '[^\w\-.]', '_')
    if ($prefix.Length -gt 40) { $prefix = $prefix.Substring(0, 40) }
    $result = "${prefix}_${short}"
    $Script:SanitizeForPathCache[$Url] = $result
    return $result
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
        Start-Sleep -Milliseconds $WD_WINDOW_HANDLE_POLL_MS
        try { $ProcessObj.Refresh() } catch { break }
        $elapsed += $WD_WINDOW_HANDLE_POLL_MS
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

    $hwnd = WdWaitForWindowHandle -ProcessObj $ProcessObj
    if ($hwnd -eq [IntPtr]::Zero) { return $false }

    if (WdIsWindowForeground -Hwnd $hwnd) { return $true }

    $currentThreadId = [WatchdogWin32.DisplayAPI]::GetCurrentThreadId()
    $targetThreadId  = [WatchdogWin32.DisplayAPI]::GetWindowThreadProcessId($hwnd, [IntPtr]::Zero)
    $attached = $false
    $success  = $false

    try {
        if ($currentThreadId -ne $targetThreadId -and $targetThreadId -ne 0) {
            [WatchdogWin32.DisplayAPI]::AttachThreadInput($currentThreadId, $targetThreadId, $true) | Out-Null
            $attached = $true
        }

        [WatchdogWin32.DisplayAPI]::keybd_event($VK_MENU, 0, 0, [UIntPtr]::Zero)
        [WatchdogWin32.DisplayAPI]::keybd_event($VK_MENU, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)

        [WatchdogWin32.DisplayAPI]::ShowWindow($hwnd, $SW_RESTORE) | Out-Null
        [WatchdogWin32.DisplayAPI]::SetWindowPos($hwnd, $HWND_TOPMOST, 0, 0, 0, 0, $SWP_TOPMOST_FLAGS) | Out-Null
        [WatchdogWin32.DisplayAPI]::SetForegroundWindow($hwnd) | Out-Null

        Start-Sleep -Milliseconds $WD_FOCUS_SETTLE_MS
        [WatchdogWin32.DisplayAPI]::SetWindowPos($hwnd, $HWND_NOTOPMOST, 0, 0, 0, 0, $SWP_TOPMOST_FLAGS) | Out-Null

        $success = $true
    }
    catch { $success = $false }
    finally {
        if ($attached) {
            try {
                [WatchdogWin32.DisplayAPI]::AttachThreadInput($currentThreadId, $targetThreadId, $false) | Out-Null
            }
            catch {}
        }
    }

    # SetForegroundWindow sends WM_ACTIVATE to the target window, which can cause Unity to
    # reset its cursor visible state. Unity re-hides the cursor in its WM_SETCURSOR handler,
    # but that message only fires when the mouse moves. Sending a zero-delta MOUSEEVENTF_MOVE
    # generates a synthetic WM_MOUSEMOVE → WM_SETCURSOR so Unity immediately re-applies the
    # hidden cursor without requiring physical mouse movement.
    if ($success) {
        try {
            [WatchdogWin32.DisplayAPI]::mouse_event($MOUSEEVENTF_MOVE, 0, 0, 0, [UIntPtr]::Zero)
        }
        catch {}
    }

    return $success
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
        [Math]::Abs($winRect.left                     - $mLeft)   -le $WD_FULLSCREEN_TOLERANCE_PX -and
        [Math]::Abs($winRect.top                      - $mTop)    -le $WD_FULLSCREEN_TOLERANCE_PX -and
        [Math]::Abs(($winRect.right  - $winRect.left) - $mWidth)  -le $WD_FULLSCREEN_TOLERANCE_PX -and
        [Math]::Abs(($winRect.bottom - $winRect.top)  - $mHeight) -le $WD_FULLSCREEN_TOLERANCE_PX
    )

    if ($Fullscreen -and -not $isFullscreen) {
        WdWriteLog "DISPLAY: Forcing fullscreen for PID $($ProcessObj.Id)..." "Yellow"
        $curStyle = [WatchdogWin32.DisplayAPI]::GetWindowLong($hwnd, $GWL_STYLE)
        $newStyle = $curStyle -band (-bnot $WS_OVERLAPPEDWINDOW)
        [WatchdogWin32.DisplayAPI]::SetWindowLong($hwnd, $GWL_STYLE, $newStyle) | Out-Null
        [WatchdogWin32.DisplayAPI]::ShowWindow($hwnd, $SW_RESTORE) | Out-Null
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

        $winW = [Math]::Min($WD_WINDOWED_MAX_W, [Math]::Max($WD_WINDOWED_MIN_W, $mWidth  - $WD_WINDOWED_MARGIN))
        $winH = [Math]::Min($WD_WINDOWED_MAX_H, [Math]::Max($WD_WINDOWED_MIN_H, $mHeight - $WD_WINDOWED_MARGIN))
        $winX = $mLeft + [int](($mWidth  - $winW) / 2)
        $winY = $mTop  + [int](($mHeight - $winH) / 2)

        [WatchdogWin32.DisplayAPI]::ShowWindow($hwnd, $SW_RESTORE) | Out-Null
        [WatchdogWin32.DisplayAPI]::SetWindowPos(
            $hwnd, $HWND_TOP,
            $winX, $winY, $winW, $winH,
            ($SWP_FRAMECHANGED -bor $SWP_SHOWWINDOW -bor $SWP_NOZORDER)
        ) | Out-Null
        WdWriteLog "DISPLAY: Windowed applied (${winW}x${winH} @ $winX,$winY)." "Green"
    }
}

# =================== 5.0 光标可见性管理 ===================
$Script:CursorHiddenApplied = $false

function WdHideSystemCursor {
    if ($Script:CursorHiddenApplied) { return }
    try {
        $planeSize = $WD_CURSOR_SIZE * [int]($WD_CURSOR_SIZE / 8)  # bytes per bit-plane

        $andPlane = New-Object byte[] $planeSize
        $xorPlane = New-Object byte[] $planeSize
        for ($i = 0; $i -lt $planeSize; $i++) { $andPlane[$i] = [byte]0xFF }

        $hCursor = [WatchdogWin32.DisplayAPI]::CreateCursor([IntPtr]::Zero, 0, 0, $WD_CURSOR_SIZE, $WD_CURSOR_SIZE, $andPlane, $xorPlane)
        if ($hCursor -ne [IntPtr]::Zero) {
            # SetSystemCursor takes ownership of hCursor on success; do not call DestroyCursor after that
            if ([WatchdogWin32.DisplayAPI]::SetSystemCursor($hCursor, $OCR_NORMAL)) {
                $Script:CursorHiddenApplied = $true
                WdWriteLog "CURSOR: System cursor hidden." "DarkGray"
            }
            else {
                # SetSystemCursor did not take ownership; free the handle to avoid a leak
                [WatchdogWin32.DisplayAPI]::DestroyCursor($hCursor) | Out-Null
                WdWriteLog "CURSOR: SetSystemCursor failed; cursor handle released." "DarkYellow"
            }
        }
    }
    catch {
        WdWriteLog "CURSOR: Failed to hide cursor - $($_.Exception.Message)" "DarkYellow"
    }
}

function WdRestoreSystemCursor {
    if (-not $Script:CursorHiddenApplied) { return }
    try {
        [WatchdogWin32.DisplayAPI]::SystemParametersInfo($SPI_SETCURSORS, 0, [IntPtr]::Zero, 0) | Out-Null
        $Script:CursorHiddenApplied = $false
        WdWriteLog "CURSOR: System cursor restored." "DarkGray"
    }
    catch {
        WdWriteLog "CURSOR: Failed to restore cursor - $($_.Exception.Message)" "DarkYellow"
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

        $proc = $null
        $startSucceeded = $false
        try {
            WdWriteLog "START: Launching [$FileName] via [$browserExe] Args=[$argStr]" "DarkCyan"
            $proc = Start-Process -FilePath $browserExe -ArgumentList $argStr -PassThru -ErrorAction Stop
            WdWriteProcessStartLog -FileName $FileName -Proc $proc `
                -Details "Browser=$browserExe, Fullscreen=$Fullscreen"
            $startSucceeded = $true
            return $proc
        }
        catch {
            WdWriteLog "FAILED: $FileName (browser) - $($_.Exception.Message)" "Red"
            return $null
        }
        finally {
            if (-not $startSucceeded -and $proc) { try { $proc.Dispose() } catch {} }
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

        $proc = $null
        $startSucceeded = $false
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

            WdWriteProcessStartLog -FileName $FileName -Proc $proc `
                -Details "Hide=$HideWindow, ConsoleMode=$effectiveMode, FocusTop=$FocusTop, Fullscreen=$Fullscreen"
            $startSucceeded = $true
            return $proc
        }
        catch {
            WdWriteLog "FAILED: $FileName - $($_.Exception.Message)" "Red"
            return $null
        }
        finally {
            if (-not $startSucceeded -and $proc) { try { $proc.Dispose() } catch {} }
        }
    }

    if ($Path.EndsWith(".py", [System.StringComparison]::OrdinalIgnoreCase)) {
        $proc = $null
        $startSucceeded = $false
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

            WdWriteProcessStartLog -FileName $FileName -Proc $proc `
                -Details "Hide=$HideWindow, ConsoleMode=$effectiveMode, FocusTop=$FocusTop, Fullscreen=$Fullscreen"
            $startSucceeded = $true
            return $proc
        }
        catch {
            WdWriteLog "FAILED: $FileName - $($_.Exception.Message)" "Red"
            return $null
        }
        finally {
            if (-not $startSucceeded -and $proc) { try { $proc.Dispose() } catch {} }
        }
    }

    $winStyle = if ($HideWindow) { 'Hidden' } else { 'Normal' }

    $proc = $null
    $startSucceeded = $false
    try {
        $cmdLine = if ([string]::IsNullOrWhiteSpace($Arguments)) { $Path } else { "$Path $Arguments" }
        WdWriteLog "START: Launching [$FileName] CMD=[$cmdLine]" "DarkCyan"

        $splat = @{
            FilePath         = $Path
            WorkingDirectory = $Dir
            WindowStyle      = $winStyle
            PassThru         = $true
            ErrorAction      = 'Stop'
        }
        if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
            $splat.ArgumentList = $Arguments
        }
        $proc = Start-Process @splat

        WdWriteProcessStartLog -FileName $FileName -Proc $proc `
            -Details "Hide=$HideWindow, FocusTop=$FocusTop, Fullscreen=$Fullscreen"

        if ($FocusTop -and -not $HideWindow -and $proc) {
            Start-Sleep -Milliseconds $WD_INITIAL_FOCUS_DELAY_MS
            [void](WdSetWindowToForeground -ProcessObj $proc)
        }

        $startSucceeded = $true
        return $proc
    }
    catch {
        WdWriteLog "FAILED: $FileName - $($_.Exception.Message)" "Red"
        return $null
    }
    finally {
        if (-not $startSucceeded -and $proc) { try { $proc.Dispose() } catch {} }
    }
}

# Internal helper: launch app via WdStartApp and update all tracking tables.
# Hashtable args are reference types; mutations are visible in the caller's scope.
function WdLaunchAndTrack {
    param(
        [string]$Path, $Config, [string]$FileName,
        [string]$StatKey, [string]$OnceKey, [string]$BrowserName, [bool]$IsOnce,
        $RestartStats, $LaunchTime, $DisplayRepairDone, $HangFailCount
    )
    $proc = WdStartApp `
        -Path        $Path            `
        -Arguments   $Config.Arguments `
        -FileName    $FileName        `
        -HideWindow  ([bool]$Config.HideWindow)  `
        -FocusTop    ([bool]$Config.FocusTop)    `
        -Fullscreen  ([bool]$Config.Fullscreen)  `
        -PythonExe   ([string]$Config.PythonExe) `
        -ConsoleMode (WdGetConsoleMode -Config $Config) `
        -Browser     $BrowserName
    try {
        if ($proc) {
            $RestartStats[$StatKey] = [int]$RestartStats[$StatKey] + 1
            $LaunchTime[$Path] = Get-Date
            $DisplayRepairDone[$Path] = $false
            $HangFailCount[$Path] = 0
            if ($IsOnce) { $RestartStats[$OnceKey] = $true }
        }
    }
    finally {
        if ($proc) { try { $proc.Dispose() } catch {} }
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
WdWriteLog "INFO: Task Manager open state is treated as disable flag" "DarkGray"
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
$ScheduledLaunch   = @{}   # Path -> [DateTime] of next permitted launch attempt
$Script:GCCounter  = 0

# =================== 7. 主循环 ===================
try {
    while ($true) {
        Start-Sleep -Milliseconds 200  # preventive: guards against CPU spin if an exception bypasses the end-of-loop sleep
        try {
            WdRotateLog
            $CurrentHour = (Get-Date).Hour
            WdCleanupRestartStats -Table $RestartStats -CurrentHour $CurrentHour
            WdCleanupRestartStats -Table $ThrottleWarned -CurrentHour $CurrentHour

            $disableReason = WdGetDisableReason
            if (WdUpdateDisableState -DisableReason $disableReason) {
                $FirstRun = $false
                Start-Sleep -Seconds $CheckInterval
                continue
            }

            $anyCursorHideNeeded = $false
            $monitoringPaused = $false
            foreach ($Path in $Apps.Keys) {
                $Config   = $Apps[$Path]
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

                $disableReason = WdGetDisableReason
                if (WdUpdateDisableState -DisableReason $disableReason) {
                    $monitoringPaused = $true
                    break
                }

                if ($RestartStats[$StatKey] -ge $MaxRetryInHour) {
                    if (-not $ThrottleWarned.ContainsKey($StatKey)) {
                        WdWriteLog "CRITICAL: $FileName failed too many times this hour ($($RestartStats[$StatKey])/$MaxRetryInHour). Skipping until next hour..." "Red"
                        $ThrottleWarned[$StatKey] = $true
                    }
                    continue
                }

                $allowMultiInstance = if ($Config.ContainsKey("AllowMultiInstance")) { [bool]$Config.AllowMultiInstance } else { $false }
                $killTreeOnHang     = if ($Config.ContainsKey("KillTreeOnHang"))     { [bool]$Config.KillTreeOnHang }     else { $true }
                $browserName        = if ($Config.ContainsKey("Browser") -and
                    -not [string]::IsNullOrWhiteSpace([string]$Config.Browser)) { [string]$Config.Browser } else { "auto" }
                $minUpSeconds       = if ($Config.ContainsKey("MinUpSeconds") -and
                    $null -ne $Config.MinUpSeconds) { [Math]::Max(1, [int]$Config.MinUpSeconds) } else { 5 }
                $hideCursor         = if ($Config.ContainsKey("HideCursor") -and $isExe) { [bool]$Config.HideCursor } else { $false }

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

                    # Schedule a launch if not already scheduled, then wait non-blocking
                    if ($null -eq $ScheduledLaunch[$Path]) {
                        $WaitTime = if ($FirstRun) { [int]$Config.First } else { [int]$Config.Restart }
                        $ScheduledLaunch[$Path] = (Get-Date).AddSeconds($WaitTime)
                        WdWriteLog "MISSING: $FileName, launch scheduled in $WaitTime sec..." "Cyan"
                        $MissingLogged[$Path] = $true
                        continue
                    }

                    if ((Get-Date) -lt $ScheduledLaunch[$Path]) {
                        continue  # wait period not yet elapsed; check other apps
                    }

                    # Wait period elapsed — clear schedule and attempt launch
                    $ScheduledLaunch[$Path] = $null

                    if (-not (WdIsProcessMissing -Path $Path)) {
                        $MissingLogged[$Path] = $false
                        WdWriteLog "SKIP: $FileName already started by another source during wait window." "DarkYellow"
                        continue
                    }

                    $LastStartAttempt[$Path] = Get-Date

                    WdLaunchAndTrack -Path $Path -Config $Config -FileName $FileName `
                        -StatKey $StatKey -OnceKey $OnceKey -BrowserName $browserName -IsOnce $Config.Once `
                        -RestartStats $RestartStats -LaunchTime $LaunchTime `
                        -DisplayRepairDone $DisplayRepairDone -HangFailCount $HangFailCount
                }
                else {
                    $MissingLogged[$Path] = $false
                    $ScheduledLaunch[$Path] = $null  # process is running; clear any pending launch schedule
                    if (-not $allowMultiInstance -and $procCount -gt 1) {
                        WdWriteLog "CONFLICT: $procCount instances of $FileName detected. Cleaning up extra instances..." "Magenta"
                        $procs | Select-Object -Skip 1 | ForEach-Object {
                            $TargetID = WdGetProcessId $_
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

                    $TargetID = WdGetProcessId $FirstProc
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
                            # Schedule relaunch after the configured Restart delay (non-blocking)
                            $ScheduledLaunch[$Path] = (Get-Date).AddSeconds([int]$Config.Restart)
                            WdWriteLog "HANG: $FileName relaunch scheduled in $([int]$Config.Restart) sec." "DarkYellow"
                            continue
                        }
                        elseif ($isExe -and $HangFailCount.ContainsKey($Path) -and [int]$HangFailCount[$Path] -gt 0) {
                            WdWriteLog "HANG-RECOVERED: $FileName (PID:$TargetID) responding again; reset consecutive hang counter." "DarkGreen"
                            $HangFailCount[$Path] = 0
                        }

                        if ($Config.ContainsKey("ForceDisplayMode") -and [bool]$Config.ForceDisplayMode -and -not [bool]$Config.HideWindow) {
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

                        if ($hideCursor) {
                            $anyCursorHideNeeded = $true
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

            if ($monitoringPaused) {
                $FirstRun = $false
                Start-Sleep -Seconds $CheckInterval
                continue
            }

            $disableReason = WdGetDisableReason
            if (WdUpdateDisableState -DisableReason $disableReason) {
                $FirstRun = $false
                Start-Sleep -Seconds $CheckInterval
                continue
            }

            $FirstRun = $false

            if ($anyCursorHideNeeded) {
                WdHideSystemCursor
            } else {
                WdRestoreSystemCursor
            }

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
    try { WdRestoreSystemCursor } catch {}

    if ($Script:MutexOwned) {
        try { $Script:Mutex.ReleaseMutex() } catch {}
    }
    try { $Script:Mutex.Dispose() } catch {}
}
