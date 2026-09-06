# 守护进程通过图形界面完成目标选择和管理员授权。

param(
    [switch]$ElevatedRelaunch,
    [switch]$RestartExisting,
    [switch]$Unattended
)

# StartWatchdog.vbs 已使用 ExecutionPolicy Bypass 启动，无需用户手工修改执行策略。
# 目标程序通过首次运行向导或托盘菜单中的“设置启动程序”进行配置。

$WatchdogRoot = $PSScriptRoot
$UserConfigPath = Join-Path $PSScriptRoot "watchdog.config.json"
$Script:ConfigWasLoaded = $false
$Script:ConfigLoadError = $null
$Script:AutoDiscoveredTarget = $false
$Script:StartWithWindows = $true
$Script:DisableLockScreen = $false
$Script:DisableLockScreenWasConfigured = $false
$Script:EnableMagicWake = $true
$Script:UserInteractionActive = $false
$Script:DisplayEventQuietUntil = [DateTime]::MinValue

function WdGetConfigValue {
    param($Source, [string]$Name, $DefaultValue)

    if ($null -eq $Source) { return $DefaultValue }
    if ($Source -is [System.Collections.IDictionary]) {
        if ($Source.Contains($Name)) { return $Source[$Name] }
        return $DefaultValue
    }

    $property = $Source.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $DefaultValue
}

function WdNewAppConfiguration {
    param($Source)

    return @{
        First                  = [int](WdGetConfigValue $Source "First" 1)
        Restart                = [int](WdGetConfigValue $Source "Restart" 5)
        Arguments              = [string](WdGetConfigValue $Source "Arguments" "")
        Once                   = [bool](WdGetConfigValue $Source "Once" $false)
        HideWindow             = [bool](WdGetConfigValue $Source "HideWindow" $false)
        FocusTop               = [bool](WdGetConfigValue $Source "FocusTop" $false)
        Fullscreen             = [bool](WdGetConfigValue $Source "Fullscreen" $false)
        ForceDisplayMode       = [bool](WdGetConfigValue $Source "ForceDisplayMode" $false)
        PythonExe              = [string](WdGetConfigValue $Source "PythonExe" "")
        ConsoleMode            = [string](WdGetConfigValue $Source "ConsoleMode" "Auto")
        AllowMultiInstance     = [bool](WdGetConfigValue $Source "AllowMultiInstance" $false)
        KillTreeOnHang         = [bool](WdGetConfigValue $Source "KillTreeOnHang" $true)
        MinUpSeconds           = [int](WdGetConfigValue $Source "MinUpSeconds" 15)
        Browser                = [string](WdGetConfigValue $Source "Browser" "auto")
        HideCursor             = [bool](WdGetConfigValue $Source "HideCursor" $false)
        RestartOnDisplayChange = [bool](WdGetConfigValue $Source "RestartOnDisplayChange" $false)
        UnityDisplayRecovery   = [bool](WdGetConfigValue $Source "UnityDisplayRecovery" $true)
    }
}

function WdResolveStoredTargetPath {
    param([string]$StoredPath)

    if ([string]::IsNullOrWhiteSpace($StoredPath) -or $StoredPath -imatch '^https?://') {
        return $StoredPath
    }

    $expandedPath = [Environment]::ExpandEnvironmentVariables($StoredPath)
    if (-not [System.IO.Path]::IsPathRooted($expandedPath)) {
        $expandedPath = Join-Path $PSScriptRoot $expandedPath
    }
    return [System.IO.Path]::GetFullPath($expandedPath)
}

function WdGetPortableTargetPath {
    param([string]$TargetPath)

    if ([string]::IsNullOrWhiteSpace($TargetPath) -or $TargetPath -imatch '^https?://') {
        return $TargetPath
    }

    $fullTargetPath = [System.IO.Path]::GetFullPath($TargetPath)
    $rootPrefix = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if ($fullTargetPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return ".\" + $fullTargetPath.Substring($rootPrefix.Length)
    }
    return $fullTargetPath
}

function WdGetLocalExecutableCandidates {
    $helperExecutablePattern = '^(?:Watchdog|UnityCrashHandler\d*|CrashReportClient|CrashHandler|unins\d*|uninstall|updater?|repair|installer|setup)(?:[-_.].*)?\.exe$'
    return @(
        Get-ChildItem -LiteralPath $PSScriptRoot -Filter "*.exe" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch $helperExecutablePattern -and $_.Name -notmatch '\.vshost\.exe$' } |
            Sort-Object Name
    )
}

$Apps = [ordered]@{}
$configurationExists = Test-Path -LiteralPath $UserConfigPath

if ($configurationExists) {
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $configurationJson = [System.IO.File]::ReadAllText($UserConfigPath, $utf8)
        $savedConfiguration = $configurationJson | ConvertFrom-Json -ErrorAction Stop
        $targetsProperty = $savedConfiguration.PSObject.Properties["Targets"]
        if (-not $targetsProperty) {
            throw "配置文件缺少启动程序列表。"
        }
        $savedTargets = @($targetsProperty.Value)

        $Apps = [ordered]@{}
        foreach ($savedTarget in $savedTargets) {
            $savedPath = WdResolveStoredTargetPath ([string](WdGetConfigValue $savedTarget "Path" ""))
            if ([string]::IsNullOrWhiteSpace($savedPath)) { continue }
            $Apps[$savedPath] = WdNewAppConfiguration -Source $savedTarget
        }
        $topmostTargetAssigned = $false
        foreach ($savedPath in @($Apps.Keys)) {
            if (-not [bool]$Apps[$savedPath].FocusTop) { continue }
            if ($topmostTargetAssigned) {
                $Apps[$savedPath].FocusTop = $false
            }
            else {
                $topmostTargetAssigned = $true
            }
        }
        if ($savedTargets.Count -gt 0 -and $Apps.Count -eq 0) {
            throw "启动程序列表中没有有效路径。"
        }
        $Script:StartWithWindows = [bool](WdGetConfigValue $savedConfiguration "StartWithWindows" $false)
        $magicWakeProperty = $savedConfiguration.PSObject.Properties["EnableMagicWake"]
        if ($magicWakeProperty) {
            $Script:EnableMagicWake = [bool]$magicWakeProperty.Value
        }
        $disableLockScreenProperty = $savedConfiguration.PSObject.Properties["DisableLockScreen"]
        if ($disableLockScreenProperty) {
            $Script:DisableLockScreen = [bool]$disableLockScreenProperty.Value
            $Script:DisableLockScreenWasConfigured = $true
        }
        $Script:ConfigWasLoaded = $true
    }
    catch {
        $Script:ConfigLoadError = $_.Exception.Message
    }
}

if (-not $Script:ConfigWasLoaded) {
    $localExecutables = @(WdGetLocalExecutableCandidates)
    $autoDetectedExecutable = $null

    if ($localExecutables.Count -eq 1) {
        $autoDetectedExecutable = $localExecutables[0]
    }
    if ($autoDetectedExecutable) {
        $Apps[$autoDetectedExecutable.FullName] = WdNewAppConfiguration -Source $null
        if (-not $configurationExists -and -not $Script:ConfigLoadError) {
            $Script:ConfigWasLoaded = $true
            $Script:AutoDiscoveredTarget = $true
        }
    }
    elseif ($localExecutables.Count -gt 0) {
        # 多个候选全部带入列表，由用户确认后统一保存。
        foreach ($localExecutable in $localExecutables) {
            $Apps[$localExecutable.FullName] = WdNewAppConfiguration -Source $null
        }
    }
}
#
# 紧急停用：
#   在程序目录创建 disable.flag
#   或直接打开任务管理器
#   Watchdog 检测到后将停止拉起目标程序，仅记录日志
# 启动程序列表字段说明：
# First:              首次启动延迟秒数
# Restart:            异常重启前等待秒数
# Arguments:          传递给程序的额外参数
# Once:               $false=持续监控  $true=仅启动一次
# HideWindow:         $true=隐藏窗口启动  $false=正常显示
# FocusTop:           $true=允许置顶并抢焦点（全局最多一个目标）
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
# RestartOnDisplayChange:
#                     $true=显示器数量/分辨率/旋转方向/主屏/排列顺序变化并稳定后重启
#                     也响应系统亮屏/显示变化通知；Unity 持续未全屏时直接重启，无需另开恢复选项。
#                     $false=不强制重启；UnityDisplayRecovery 仍可刷新全屏并在失败后重启。
# UnityDisplayRecovery:
#                     默认 $true：Unity 显示变化或全屏持续异常时先刷新全屏，复查仍异常才重启。
#                     不依赖 RestartOnDisplayChange；显式打开后仍会在显示变化时重启。
#                     根据同目录 UnityPlayer.dll 和对应的 *_Data 目录识别 Unity 程序。
#                     窗口化 Unity 请关闭；仅启动一次、隐藏窗口、多实例或强制窗口化时不启用。
# Browser:            网页 URL 条目专用，指定打开浏览器
#                     	auto=自动检测（优先 Chrome，其次 Edge）
#                     	chrome=Google Chrome
#                     	msedge=Microsoft Edge

# =================== 1. 全局配置 ===================
$LogPath = Join-Path $WatchdogRoot "watchdog_log.txt"
$DisableFlag = Join-Path $WatchdogRoot "disable.flag"

$MaxLogSizeMB = 10
$MaxLogBackups = 3
$CheckInterval = 3
$MaxRetryInHour = 10
$GCCollectEvery = 100

# 连续 N 次检测到不响应后才执行挂死重启，避免偶发卡顿触发误重启
$HangConsecutiveFailuresToRestart = 3

# 启动后最短再次尝试间隔，避免同一轮/短时间重复拉起
$MinRestartGapSeconds = 2

# 启动后延迟 N 秒再做第一次窗口模式修复
$FullscreenRepairDelay = 4

# 是否每轮巡检都持续修复窗口模式（生产默认建议 false）
$DisplayLoopRepair = $false

# 显示器拓扑变化后等待系统稳定 N 秒，再重启显式启用的目标程序
$DisplayChangeDebounceSeconds = 10

# Unity 初始化宽限、连续异常次数，以及显示恢复重启的最短间隔。
$UnityDisplayStartupGraceSeconds = 20
$UnityDisplayMismatchChecks = 3
$UnityDisplayRepairGraceSeconds = 5
$DisplayRecoveryCooldownSeconds = 60

# 结束进程后等待其真正退出的最长秒数
$ProcessStopTimeoutSeconds = 10

# 显示器变化重启时，旧进程长时间不退出后的放弃秒数
$DisplayRestartGiveUpSeconds = 30

# 显示器变化重启等待旧进程退出期间，重新尝试结束进程的间隔秒数
$DisplayRestartRetrySeconds = 5

# 快速崩溃退避重启的最大等待秒数
$FastExitMaxBackoffSeconds = 300

# 同一程序两次抢焦点之间最短间隔秒数
$FocusCooldownSeconds = 30

# 脚本类进程尽量按完整路径匹配
$MatchFullPathForScripts = $true

# 脚本类命令行匹配时是否需要严格引号边界（为兼容复杂场景默认 false）
$StrictScriptPathBoundary = $false

# 看门狗界面：隐藏自身 PowerShell 控制台，并在通知区域显示托盘图标。
$HideWatchdogConsole = $true
$ShowTrayIcon = $true
$TrayIconPath = Join-Path $PSScriptRoot "watchdog.ico"  # 文件不存在时使用 Windows 系统图标

# TCP / UDP 远程控制。两种协议可使用相同端口号。
# 支持的 UTF-8 纯文本指令：reboot、shutdown、restart、VOL ...；心跳：ping、heartbeat
$ControlEnabled = $true
$ControlListenAddress = "0.0.0.0"
$ControlPort = 55555
$ControlMaxMessageBytes = 256

# TCP 空闲连接超时秒数；0 表示 Watchdog 不主动断开空闲连接。
$ControlTcpIdleTimeoutSeconds = 0

# 未带换行符的 TCP 数据若只是已知指令的前缀，最多等待这么久；之后静默丢弃。
$ControlTcpPartialCommandTimeoutMilliseconds = 500

# 无换行的数字类指令等待短暂稳定，避免 VOL SET 50 被 TCP 分包成 VOL SET 5 和 0。
$ControlTcpCommandSettleMilliseconds = 75

# 允许发送控制指令的远端 IP。空数组表示允许所有来源；生产环境建议填写固定管理端 IP。
# 示例：@("127.0.0.1", "192.168.1.10")
$ControlAllowedRemoteAddresses = @()

# =================== 1.5 Win32 / 时序常量 ===================
# ShowWindow nCmdShow 命令
$SW_RESTORE = 9            # 若最小化则还原，否则激活并显示

# SetWindowPos uFlags
$SWP_NOSIZE = 0x0001       # 保持当前大小
$SWP_NOMOVE = 0x0002       # 保持当前位置
$SWP_NOZORDER = 0x0004       # 保持当前 Z 序
$SWP_FRAMECHANGED = 0x0020       # 应用 SetWindowLong 的样式变更
$SWP_SHOWWINDOW = 0x0040       # 显示窗口
$SWP_TOPMOST_FLAGS = $SWP_NOSIZE -bor $SWP_NOMOVE   # 置顶/解除置顶时使用

# SetWindowPos hWndInsertAfter 特殊句柄
$HWND_TOP = [IntPtr]::Zero   # Z 序最前（非置顶）
$HWND_TOPMOST = [IntPtr]-1       # 置顶（始终位于普通窗口之上）
$HWND_NOTOPMOST = [IntPtr]-2       # 解除置顶

# GetWindowLong / SetWindowLong 索引
$GWL_STYLE = -16          # 窗口样式

# 窗口样式位掩码
$WS_CAPTION = 0x00C00000   # 标题栏（含边框）
$WS_THICKFRAME = 0x00040000   # 可调大小边框
$WS_SYSMENU = 0x00080000   # 系统菜单
$WS_MINIMIZEBOX = 0x00020000   # 最小化按钮
$WS_MAXIMIZEBOX = 0x00010000   # 最大化按钮
$WS_OVERLAPPEDWINDOW = $WS_CAPTION -bor $WS_THICKFRAME -bor $WS_SYSMENU -bor $WS_MINIMIZEBOX -bor $WS_MAXIMIZEBOX

# MonitorFromWindow dwFlags
$MONITOR_NEAREST = 0x00000002   # 返回与窗口距离最近的监视器

# 键盘 / 鼠标事件常量
$VK_MENU = 0x12         # Alt 键虚拟键码
$KEYEVENTF_KEYUP = 0x0002       # 键释放事件标志
$MOUSEEVENTF_MOVE = 0x0001       # 鼠标移动事件标志

# 系统光标常量
$OCR_NORMAL = 32512        # 标准箭头光标资源 ID
$SPI_SETCURSORS = 0x0057       # SystemParametersInfo：重置光标方案
$WD_CURSOR_SIZE = 32           # 透明光标位图的宽高（像素，32x32）

# 时序常量（毫秒）
$WD_WINDOW_HANDLE_POLL_MS = 100        # WdWaitForWindowHandle 的轮询间隔
$WD_FOCUS_SETTLE_MS = 150        # 置顶后等待窗口完成激活的延迟
$WD_INITIAL_FOCUS_DELAY_MS = 500        # 进程启动后首次抢焦点前的等待时间
$WD_FOCUS_WINDOW_HANDLE_TIMEOUT_MS = 1200       # 抢焦点等待窗口句柄的最长时间
$WD_REPAIR_WINDOW_HANDLE_TIMEOUT_MS = 1500      # 修复窗口模式等待窗口句柄的最长时间

# 全屏检测与窗口模式修复
$WD_FULLSCREEN_TOLERANCE_PX = 4         # 全屏判定允许的像素误差
$WD_WINDOWED_MAX_W = 1280         # 窗口模式修复的最大默认宽度
$WD_WINDOWED_MAX_H = 720          # 窗口模式修复的最大默认高度
$WD_WINDOWED_MIN_W = 640          # 窗口模式修复的最小默认宽度
$WD_WINDOWED_MIN_H = 480          # 窗口模式修复的最小默认高度
$WD_WINDOWED_MARGIN = 100          # 窗口模式修复时距屏幕边缘的间距

# =================== 2. 核心保护：防止 Watchdog 自身多开 ===================
if ($RestartExisting) {
    $watchdogCommandPattern = '(?i)-File\s+["'']?[^"'']*[\\/]Watchdog\.ps1["'']?(?:\s|$)'
    $existingInstances = @(
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.Name -match '^(?:powershell|pwsh)\.exe$' -and
                $_.CommandLine -match $watchdogCommandPattern
            }
    )
    foreach ($existingInstance in $existingInstances) {
        Stop-Process -Id $existingInstance.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if ($existingInstances.Count -gt 0) {
        Start-Sleep -Milliseconds 500
    }
}

$mutexIdentity = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\').ToLowerInvariant()
$mutexHasher = [System.Security.Cryptography.SHA256]::Create()
try {
    $mutexHashBytes = $mutexHasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($mutexIdentity))
    $mutexHash = ([System.BitConverter]::ToString($mutexHashBytes)).Replace('-', '').Substring(0, 24)
}
finally {
    $mutexHasher.Dispose()
}
$Script:MutexName = "Local\WindowsWatchdog_$mutexHash"
$Script:MutexOwned = $false
$Script:Mutex = New-Object System.Threading.Mutex($false, $Script:MutexName)
try {
    $mutexWaitMilliseconds = if ($ElevatedRelaunch) { 15000 } else { 0 }
    $Script:MutexOwned = $Script:Mutex.WaitOne($mutexWaitMilliseconds)
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
$Script:ExitRequested = $false

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

    # 移除通知区域图标及右键菜单
    try {
        if ($Script:DisplayEventMonitor) {
            $Script:DisplayEventMonitor.Dispose()
            $Script:DisplayEventMonitor = $null
        }
    }
    catch {}

    try {
        if (Get-Command WdDisposeTrayIcon -ErrorAction SilentlyContinue) {
            WdDisposeTrayIcon
        }
    }
    catch {}

    # 关闭 TCP / UDP 控制监听器
    try {
        if (Get-Command WdStopControlListeners -ErrorAction SilentlyContinue) {
            WdStopControlListeners
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
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

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

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct MONITORINFOEX
        {
            public int cbSize;
            public RECT rcMonitor;
            public RECT rcWork;
            public int dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            public string szDevice;
        }

        // Fixed-size DEVMODEW (wingdi.h); unused fields retain their native padding.
        [StructLayout(LayoutKind.Explicit, Size = 220)]
        public struct DEVMODEW
        {
            [FieldOffset(68)] public ushort dmSize;
            [FieldOffset(72)] public uint dmFields;
            [FieldOffset(84)] public uint dmDisplayOrientation;
            [FieldOffset(172)] public uint dmPelsWidth;
            [FieldOffset(176)] public uint dmPelsHeight;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT { public int x, y; }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern bool EnumDisplaySettingsEx(string device, int mode, ref DEVMODEW settings, uint flags);

        [DllImport("user32.dll")]
        public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);

        [DllImport("user32.dll")]
        public static extern bool ClientToScreen(IntPtr hWnd, ref POINT point);

        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);

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

        public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData);

        [DllImport("user32.dll")]
        public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX lpmi);

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

        [DllImport("user32.dll")]
        private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr dpiContext);

        public static IntPtr EnterPerMonitorDpiAwareness()
        {
            try
            {
                // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
                return SetThreadDpiAwarenessContext(new IntPtr(-4));
            }
            catch (EntryPointNotFoundException)
            {
                return IntPtr.Zero;
            }
        }

        public static void RestoreThreadDpiAwareness(IntPtr previousContext)
        {
            if (previousContext == IntPtr.Zero) return;
            try { SetThreadDpiAwarenessContext(previousContext); }
            catch (EntryPointNotFoundException) { }
        }

        public static string GetActiveMonitorFingerprint()
        {
            List<string> parts = new List<string>();
            int index = 0;
            bool complete = true;

            MonitorEnumProc callback = delegate(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData)
            {
                MONITORINFOEX info = new MONITORINFOEX();
                info.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));

                if (GetMonitorInfo(hMonitor, ref info))
                {
                    DEVMODEW mode = new DEVMODEW();
                    mode.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODEW));
                    if (!EnumDisplaySettingsEx(info.szDevice, -1, ref mode, 0)) { complete = false; return false; }
                    parts.Add(String.Format(
                        "{0}|{1}|{2}|{3},{4},{5},{6}|mode={7}x{8}|rotation={9}",
                        index,
                        info.szDevice,
                        info.dwFlags,
                        info.rcMonitor.left,
                        info.rcMonitor.top,
                        info.rcMonitor.right - info.rcMonitor.left,
                        info.rcMonitor.bottom - info.rcMonitor.top,
                        mode.dmPelsWidth, mode.dmPelsHeight, mode.dmDisplayOrientation
                    ));
                }
                else
                {
                    complete = false;
                    return false;
                }

                index++;
                return true;
            };

            if (!EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero))
            {
                return null;
            }

            if (!complete || parts.Count == 0)
            {
                return null;
            }

            return String.Join("||", parts.ToArray());
        }
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

# =================== 3.1 Windows Core Audio API 注入 ===================
if (-not ([System.Management.Automation.PSTypeName]'WatchdogAudio.AudioAPI').Type) {
    $audioApiCode = @"
using System;
using System.Runtime.InteropServices;

namespace WatchdogAudio
{
    enum EDataFlow { eRender = 0, eCapture = 1, eAll = 2 }
    enum ERole { eConsole = 0, eMultimedia = 1, eCommunications = 2 }

    [Flags]
    enum CLSCTX : uint
    {
        InprocServer = 0x1,
        InprocHandler = 0x2,
        LocalServer = 0x4,
        RemoteServer = 0x10,
        All = InprocServer | InprocHandler | LocalServer | RemoteServer
    }

    [ComImport]
    [Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumerator { }

    [ComImport]
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(EDataFlow dataFlow, uint stateMask, IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice device);
    }

    [ComImport]
    [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig]
        int Activate(ref Guid iid, CLSCTX clsCtx, IntPtr activationParams,
            [MarshalAs(UnmanagedType.IUnknown)] out object interfacePointer);
    }

    [ComImport]
    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int GetChannelCount(out uint channelCount);
        [PreserveSig] int SetMasterVolumeLevel(float levelDb, ref Guid eventContext);
        [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid eventContext);
        [PreserveSig] int GetMasterVolumeLevel(out float levelDb);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig] int SetChannelVolumeLevel(uint channel, float levelDb, ref Guid eventContext);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, ref Guid eventContext);
        [PreserveSig] int GetChannelVolumeLevel(uint channel, out float levelDb);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid eventContext);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
    }

    public sealed class AudioState
    {
        public int Volume { get; set; }
        public bool Muted { get; set; }
    }

    public static class AudioAPI
    {
        static IAudioEndpointVolume GetEndpoint(out object enumeratorObject, out object deviceObject)
        {
            enumeratorObject = null;
            deviceObject = null;
            IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
            enumeratorObject = enumerator;
            IMMDevice device;
            int hr = enumerator.GetDefaultAudioEndpoint(EDataFlow.eRender, ERole.eMultimedia, out device);
            deviceObject = device;
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);

            Guid iid = typeof(IAudioEndpointVolume).GUID;
            object endpointObject;
            hr = device.Activate(ref iid, CLSCTX.All, IntPtr.Zero, out endpointObject);
            if (hr != 0)
            {
                Release(endpointObject);
                Marshal.ThrowExceptionForHR(hr);
            }

            return (IAudioEndpointVolume)endpointObject;
        }

        static void Release(object value)
        {
            if (value != null && Marshal.IsComObject(value))
                Marshal.FinalReleaseComObject(value);
        }

        public static AudioState GetState()
        {
            object enumerator = null;
            object device = null;
            IAudioEndpointVolume endpoint = null;
            try
            {
                endpoint = GetEndpoint(out enumerator, out device);
                float scalar;
                bool muted;
                int hr = endpoint.GetMasterVolumeLevelScalar(out scalar);
                if (hr != 0) Marshal.ThrowExceptionForHR(hr);
                hr = endpoint.GetMute(out muted);
                if (hr != 0) Marshal.ThrowExceptionForHR(hr);
                return new AudioState
                {
                    Volume = (int)Math.Round(scalar * 100.0, MidpointRounding.AwayFromZero),
                    Muted = muted
                };
            }
            finally
            {
                Release(endpoint);
                Release(device);
                Release(enumerator);
            }
        }

        public static AudioState SetVolume(int percent)
        {
            percent = Math.Max(0, Math.Min(100, percent));
            object enumerator = null;
            object device = null;
            IAudioEndpointVolume endpoint = null;
            try
            {
                endpoint = GetEndpoint(out enumerator, out device);
                Guid context = Guid.Empty;
                int hr = endpoint.SetMasterVolumeLevelScalar(percent / 100.0f, ref context);
                if (hr != 0) Marshal.ThrowExceptionForHR(hr);
            }
            finally
            {
                Release(endpoint);
                Release(device);
                Release(enumerator);
            }
            return GetState();
        }

        public static AudioState AdjustVolume(int delta)
        {
            AudioState current = GetState();
            return SetVolume(current.Volume + delta);
        }

        public static AudioState SetMute(bool muted)
        {
            object enumerator = null;
            object device = null;
            IAudioEndpointVolume endpoint = null;
            try
            {
                endpoint = GetEndpoint(out enumerator, out device);
                Guid context = Guid.Empty;
                int hr = endpoint.SetMute(muted, ref context);
                if (hr != 0) Marshal.ThrowExceptionForHR(hr);
            }
            finally
            {
                Release(endpoint);
                Release(device);
                Release(enumerator);
            }
            return GetState();
        }
    }
}
"@
    try {
        Add-Type -TypeDefinition $audioApiCode -Language CSharp -ErrorAction Stop
    }
    catch {
        Write-Host "WARNING: Failed to load Core Audio API type: $($_.Exception.Message)"
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
    $writer = $Script:LogWriter
    $Script:LogWriter = $null
    if (-not $writer) { return }

    # Keep cleanup steps independent: a failed Flush must not prevent Close/Dispose.
    try { $writer.Flush() } catch {}
    try { $writer.Close() } catch {}
    try { $writer.Dispose() } catch {}
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
    $Line = "[$Stamp] $Message"

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
            # Release the failed writer before AppendAllText opens the same file.
            WdCloseLogWriter
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

function WdIsTaskManagerRunning {
    # 独立封装，确保 Get-Process 返回的进程句柄一定会被释放，
    # 避免任务管理器长期开着时 Watchdog 每轮巡检都泄漏一个句柄。
    $procs = $null
    try {
        $procs = Get-Process -Name "taskmgr" -ErrorAction SilentlyContinue
        return [bool]$procs
    }
    finally {
        if ($procs) {
            @($procs) | ForEach-Object { try { $_.Dispose() } catch {} }
        }
    }
}

function WdGetDisableReason {
    if (Test-Path $DisableFlag) {
        return "disable.flag"
    }

    if (WdIsTaskManagerRunning) {
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

function WdGetDisplayTopologyFingerprint {
    $previousDpiContext = [IntPtr]::Zero
    try {
        $previousDpiContext = [WatchdogWin32.DisplayAPI]::EnterPerMonitorDpiAwareness()
        return [WatchdogWin32.DisplayAPI]::GetActiveMonitorFingerprint()
    }
    catch {
        WdWriteLog "DISPLAY-CHANGE: Failed to read display topology - $($_.Exception.Message)" "DarkYellow"
        return $null
    }
    finally {
        [WatchdogWin32.DisplayAPI]::RestoreThreadDpiAwareness($previousDpiContext)
    }
}

function WdIsDisplayChangeRestartEnabled {
    param($Config, [string]$Path = "")

    if ($null -eq $Config) { return $false }
    if ($Config.ContainsKey("Once") -and [bool]$Config.Once) { return $false }
    return ([bool]$Config.RestartOnDisplayChange -or (WdIsUnityDisplayRecoveryEnabled -Path $Path -Config $Config))
}

function WdIsUnityDisplayRecoveryEnabled {
    param([string]$Path, $Config)

    if (-not $Config -or (-not [bool](WdGetConfigValue $Config "UnityDisplayRecovery" $true) -and
            -not [bool]$Config.RestartOnDisplayChange) -or
        [bool]$Config.Once -or [bool]$Config.HideWindow -or [bool]$Config.AllowMultiInstance -or
        ([bool]$Config.ForceDisplayMode -and -not [bool]$Config.Fullscreen) -or
        -not $Path.EndsWith(".exe", [StringComparison]::OrdinalIgnoreCase)) { return $false }

    $directory = [IO.Path]::GetDirectoryName($Path)
    $dataDirectory = Join-Path $directory ([IO.Path]::GetFileNameWithoutExtension($Path) + "_Data")
    return ((Test-Path -LiteralPath (Join-Path $directory "UnityPlayer.dll") -PathType Leaf) -and
        (Test-Path -LiteralPath $dataDirectory -PathType Container))
}

function WdGetFullscreenObservation {
    param($ProcessObj)

    $previousDpiContext = [IntPtr]::Zero
    try {
        $previousDpiContext = [WatchdogWin32.DisplayAPI]::EnterPerMonitorDpiAwareness()
        $ProcessObj.Refresh()
        $hwnd = [IntPtr]$ProcessObj.MainWindowHandle
        if ($hwnd -eq [IntPtr]::Zero -or [WatchdogWin32.DisplayAPI]::IsIconic($hwnd) -or
            -not [WatchdogWin32.DisplayAPI]::IsWindowVisible($hwnd)) { return $null }

        $rect = New-Object WatchdogWin32.DisplayAPI+RECT
        $origin = New-Object WatchdogWin32.DisplayAPI+POINT
        $monitor = [WatchdogWin32.DisplayAPI]::MonitorFromWindow($hwnd, $MONITOR_NEAREST)
        $info = New-Object WatchdogWin32.DisplayAPI+MONITORINFO
        $info.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($info)
        if ($monitor -eq [IntPtr]::Zero -or
            -not [WatchdogWin32.DisplayAPI]::GetMonitorInfo($monitor, [ref]$info) -or
            -not [WatchdogWin32.DisplayAPI]::GetClientRect($hwnd, [ref]$rect) -or
            -not [WatchdogWin32.DisplayAPI]::ClientToScreen($hwnd, [ref]$origin)) { return $null }

        $width = $rect.right - $rect.left
        $height = $rect.bottom - $rect.top
        $monitorWidth = $info.rcMonitor.right - $info.rcMonitor.left
        $monitorHeight = $info.rcMonitor.bottom - $info.rcMonitor.top
        if ($width -le 0 -or $height -le 0 -or $monitorWidth -le 0 -or $monitorHeight -le 0) { return $null }

        return @{
            Matches = (WdTestFullscreenClientBounds -Left $origin.x -Top $origin.y -Width $width -Height $height `
                -MonitorLeft $info.rcMonitor.left -MonitorTop $info.rcMonitor.top -MonitorWidth $monitorWidth -MonitorHeight $monitorHeight)
            Details = "client=${width}x${height}@$($origin.x),$($origin.y); monitor=${monitorWidth}x${monitorHeight}@$($info.rcMonitor.left),$($info.rcMonitor.top)"
        }
    }
    catch { return $null }
    finally { [WatchdogWin32.DisplayAPI]::RestoreThreadDpiAwareness($previousDpiContext) }
}

function WdTestFullscreenClientBounds {
    param([int]$Left, [int]$Top, [int]$Width, [int]$Height,
        [int]$MonitorLeft, [int]$MonitorTop, [int]$MonitorWidth, [int]$MonitorHeight)

    return ($Width -gt 0 -and $Height -gt 0 -and $MonitorWidth -gt 0 -and $MonitorHeight -gt 0 -and
        [Math]::Abs($Left - $MonitorLeft) -le $WD_FULLSCREEN_TOLERANCE_PX -and
        [Math]::Abs($Top - $MonitorTop) -le $WD_FULLSCREEN_TOLERANCE_PX -and
        [Math]::Abs($Width - $MonitorWidth) -le $WD_FULLSCREEN_TOLERANCE_PX -and
        [Math]::Abs($Height - $MonitorHeight) -le $WD_FULLSCREEN_TOLERANCE_PX)
}

function WdUpdateFullscreenHealth {
    param([hashtable]$States, [string]$Path, [int]$ProcessId, $Observation,
        [bool]$DisplayStable, [DateTime]$Now = (Get-Date))

    if (-not $States.ContainsKey($Path) -or $States[$Path].ProcessId -ne $ProcessId) {
        $States[$Path] = @{ ProcessId = $ProcessId; FirstSeen = $Now; Failures = 0; RepairAt = $null }
        if ($Observation) {
            WdWriteLog "DISPLAY-HEALTH: PID=$ProcessId; fullscreen=$($Observation.Matches); $($Observation.Details)" "DarkGray"
        }
    }
    $state = $States[$Path]
    if ($null -ne $Observation -and $Observation.Matches) {
        if ($state.RepairAt) {
            WdWriteLog "DISPLAY-RECOVERY: PID=$ProcessId client bounds recovered without restart; $($Observation.Details)" "Green"
        }
        $state.RepairAt = $null
    }
    if (-not $DisplayStable -or $null -eq $Observation -or $Observation.Matches -or
        ($state.RepairAt -and ($Now - $state.RepairAt).TotalSeconds -lt $UnityDisplayRepairGraceSeconds) -or
        ($Now - $state.FirstSeen).TotalSeconds -lt $UnityDisplayStartupGraceSeconds) {
        $state.Failures = 0
        return $false
    }
    $state.Failures = [int]$state.Failures + 1
    return ($state.Failures -ge $UnityDisplayMismatchChecks)
}

function WdCanScheduleDisplayRecovery {
    param([string]$Path, [hashtable]$LastRecovery, [hashtable]$InProgress,
        [int]$AttemptsThisHour, [DateTime]$Now = (Get-Date))

    if ($InProgress.ContainsKey($Path) -or $AttemptsThisHour -ge $MaxRetryInHour) { return $false }
    return (-not $LastRecovery.ContainsKey($Path) -or
        ($Now - $LastRecovery[$Path]).TotalSeconds -ge $DisplayRecoveryCooldownSeconds)
}

function WdUpdateDisplayTopologyState {
    param([hashtable]$State, [string]$Fingerprint, [DateTime]$Now = (Get-Date), [bool]$DisplayEvent = $false)

    if ([string]::IsNullOrWhiteSpace($Fingerprint)) {
        # 断屏/查询失败不属于稳定状态；恢复后重新计时，包括恢复到原分辨率。
        $State.Pending = "UNAVAILABLE"
        $State.ChangedAt = $null
        return $false
    }
    if (-not $State.Baseline) {
        $State.Baseline = $Fingerprint
    }
    if ($DisplayEvent) {
        $State.Pending = $Fingerprint
        $State.ChangedAt = $Now
        WdWriteLog "DISPLAY-CHANGE: Display notification received; waiting $DisplayChangeDebounceSeconds sec even if resolution is unchanged." "Yellow"
        return $false
    }
    if ($Fingerprint -eq $State.Baseline -and -not $State.Pending) { return $false }
    if ($State.Pending -ne $Fingerprint -or -not $State.ChangedAt) {
        $State.Pending = $Fingerprint
        $State.ChangedAt = $Now
        WdWriteLog "DISPLAY-CHANGE: Waiting $DisplayChangeDebounceSeconds sec for stability. Baseline=[$($State.Baseline)] New=[$Fingerprint]" "Yellow"
        return $false
    }
    if (($Now - $State.ChangedAt).TotalSeconds -lt $DisplayChangeDebounceSeconds) { return $false }
    $State.Baseline = $Fingerprint
    $State.Pending = $null
    $State.ChangedAt = $null
    return $true
}

function WdGetConfigInt {
    param(
        $Config,
        [string]$Name,
        [int]$DefaultValue,
        [int]$Minimum = 0
    )

    if ($Config -and $Config.ContainsKey($Name) -and $null -ne $Config[$Name]) {
        try { return [Math]::Max($Minimum, [int]$Config[$Name]) }
        catch {}
    }

    return [Math]::Max($Minimum, $DefaultValue)
}

function WdTestProcessIdAlive {
    param([int]$ProcessId)

    if ($ProcessId -le 0) { return $false }
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($proc) {
        try { $proc.Dispose() } catch {}
        return $true
    }

    return $false
}

function WdGetProcessStartTimeSafe {
    param($ProcessObj)

    try {
        if ($ProcessObj -is [System.Diagnostics.Process]) {
            return $ProcessObj.StartTime
        }

        if ($ProcessObj.PSObject.Properties.Name -contains "CreationDate" -and $ProcessObj.CreationDate) {
            if ($ProcessObj.CreationDate -is [DateTime]) {
                return $ProcessObj.CreationDate
            }
            return [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$ProcessObj.CreationDate)
        }
    }
    catch {}

    return [DateTime]::MaxValue
}

function WdGetPreferredProcess {
    param(
        $Processes,
        [int]$PreferredProcessId = 0
    )

    if (-not $Processes) { return $null }
    $items = @($Processes)
    if ($items.Count -eq 0) { return $null }

    if ($PreferredProcessId -gt 0) {
        $preferred = $items | Where-Object { (WdGetProcessId $_) -eq $PreferredProcessId } | Select-Object -First 1
        if ($preferred) { return $preferred }
    }

    return $items |
        Sort-Object @{ Expression = { WdGetProcessStartTimeSafe $_ } }, @{ Expression = { WdGetProcessId $_ } } |
        Select-Object -First 1
}

function WdGetFastExitBackoffSeconds {
    param(
        [int]$FailureCount,
        [int]$BaseDelaySeconds
    )

    $base = [Math]::Max(1, $BaseDelaySeconds)
    $power = [Math]::Min(8, [Math]::Max(0, $FailureCount - 1))
    $delay = $base * [Math]::Pow(2, $power)
    return [int][Math]::Min($FastExitMaxBackoffSeconds, [Math]::Max($base, $delay))
}

function WdScheduleDisplayChangeRestart {
    param(
        [string]$Path,
        $Config,
        [string]$FileName,
        [int]$ProcessId,
        [hashtable]$ScheduledLaunch,
        [hashtable]$LaunchTime,
        [hashtable]$DisplayRepairDone,
        [hashtable]$HangFailCount,
        [hashtable]$DisplayChangeRestartInProgress
    )

    if ($ProcessId -le 0) { return $false }

    $restartDelay = WdGetConfigInt -Config $Config -Name "Restart" -DefaultValue 0 -Minimum 0
    $killTree = if ($Config.ContainsKey("KillTreeOnHang")) { [bool]$Config.KillTreeOnHang } else { $true }
    $now = Get-Date

    WdWriteLog "DISPLAY-CHANGE: Restarting $FileName (PID:$ProcessId); relaunch scheduled in $restartDelay sec." "Yellow"
    $stopSucceeded = WdStopProcessTreeSafe -ProcessId $ProcessId -KillTree $killTree
    # Unity 退出/启动可能广播它自己的显示模式切换，避免被当作下一次开屏。
    $Script:DisplayEventQuietUntil = (Get-Date).AddSeconds($UnityDisplayStartupGraceSeconds)

    $ScheduledLaunch[$Path] = (Get-Date).AddSeconds($restartDelay)
    if ($LaunchTime.ContainsKey($Path)) { $LaunchTime.Remove($Path) }
    if ($DisplayRepairDone.ContainsKey($Path)) { $DisplayRepairDone.Remove($Path) }
    $HangFailCount[$Path] = 0

    $DisplayChangeRestartInProgress[$Path] = @{
        ProcessId    = $ProcessId
        StartedAt    = $now
        LastKillAt   = $now
        Attempts     = 1
        KillTree     = $killTree
        FileName     = $FileName
        StopSucceeded = $stopSucceeded
    }

    return $true
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

# 统一释放 WdGetTargetProcess 返回的进程对象。该函数对 .exe 类目标返回
# System.Diagnostics.Process，对脚本类(.py/.bat)与浏览器 URL 类目标返回
# Microsoft.Management.Infrastructure.CimInstance（Win32_Process）。
# 此前全文各处的释放逻辑只判断了 Process 类型，CimInstance 从未被释放，
# 导致长期监控脚本类/URL类条目时持续泄漏 WMI/COM 资源。
function WdDisposeProcessResult {
    param($ProcessObj)
    if ($null -eq $ProcessObj) { return }
    if ($ProcessObj -is [System.Diagnostics.Process]) {
        try { $ProcessObj.Dispose() } catch {}
    }
    elseif ($ProcessObj -is [Microsoft.Management.Infrastructure.CimInstance]) {
        try { $ProcessObj.Dispose() } catch {}
    }
}

function WdGetTargetProcess {
    param(
        [string]$Path
    )

    # 使用 PowerShell 自动变量 $PID，避免为读取当前 PID 创建临时 Process 对象。
    $NormalizedPath = WdNormalizePathSafe $Path

    if (WdIsBrowserUrl -Path $Path) {
        $browserProcesses = @()
        $cimCandidates = @()
        try {
            $profileBase = Join-Path $WatchdogRoot "browser_profiles"
            $profileDir = (Join-Path $profileBase (WdSanitizeForPath -Url $Path)).ToLowerInvariant()

            # MainWindowHandle can temporarily be zero while Chromium creates or recreates
            # its window, so use every browser PID for the narrow CIM command-line query.
            $browserProcesses = @(Get-Process -Name "chrome", "msedge" -ErrorAction SilentlyContinue)
            $candidateIds = @($browserProcesses |
                Where-Object { $_.Id -ne $PID } |
                ForEach-Object { $_.Id })

            if ($candidateIds.Count -eq 0) { return $null }

            $idFilter = ($candidateIds | ForEach-Object { "ProcessId=$_" }) -join " OR "
            $cimCandidates = @(Get-CimInstance Win32_Process -Filter $idFilter -ErrorAction SilentlyContinue)
            $matches = @()
            foreach ($candidate in $cimCandidates) {
                $procName = $candidate.Name.ToLowerInvariant() -replace '\.exe$', ''
                $cmdLine = if ($candidate.CommandLine) { $candidate.CommandLine.ToLowerInvariant() } else { "" }
                if (($procName -eq "chrome" -or $procName -eq "msedge") -and
                    $cmdLine.Contains($profileDir) -and
                    $cmdLine -notmatch '--type=') {
                    $matches += $candidate
                }
                else {
                    WdDisposeProcessResult $candidate
                }
            }

            return $matches
        }
        catch {
            $cimCandidates | ForEach-Object { WdDisposeProcessResult $_ }
            return $null
        }
        finally {
            $browserProcesses | ForEach-Object { WdDisposeProcessResult $_ }
        }
    }

    try {
        if ($Path.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase)) {
            $exeName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
            $processCandidates = @(Get-Process -Name $exeName -ErrorAction SilentlyContinue)
            $matches = @()
            foreach ($candidate in $processCandidates) {
                $isMatch = $false
                try {
                    $isMatch = ($candidate.Id -ne $PID -and $candidate.Path -and
                        (WdNormalizePathSafe $candidate.Path) -eq $NormalizedPath)
                }
                catch {}

                if ($isMatch) {
                    $matches += $candidate
                }
                else {
                    WdDisposeProcessResult $candidate
                }
            }
            return $matches
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

            $nameProcesses = @()
            $cimCandidates = @()
            try {
                # Resolve the inexpensive local process list first, then query CommandLine
                # only for the resulting PIDs instead of scanning Win32_Process by name.
                $nameProcesses = @(Get-Process -Name "$SearchName*" -ErrorAction SilentlyContinue)
                $candidateIds = @($nameProcesses |
                    Where-Object { $_.Id -ne $PID } |
                    ForEach-Object { $_.Id })

                if ($candidateIds.Count -eq 0) { return $null }

                $idFilter = ($candidateIds | ForEach-Object { "ProcessId=$_" }) -join " OR "
                $cimCandidates = @(Get-CimInstance Win32_Process -Filter $idFilter -ErrorAction SilentlyContinue)
                $matches = @()
                foreach ($candidate in $cimCandidates) {
                    $isMatch = if ($MatchFullPathForScripts) {
                        $candidate.CommandLine -and
                        (WdIsScriptPathInCommandLine -CommandLine $candidate.CommandLine -TargetPath $Path)
                    }
                    else {
                        $nameNeedle = [System.IO.Path]::GetFileName($Path).ToLowerInvariant()
                        $candidate.CommandLine -and $candidate.CommandLine.ToLowerInvariant().Contains($nameNeedle)
                    }

                    if ($isMatch) {
                        $matches += $candidate
                    }
                    else {
                        WdDisposeProcessResult $candidate
                    }
                }

                return $matches
            }
            catch {
                $cimCandidates | ForEach-Object { WdDisposeProcessResult $_ }
                return $null
            }
            finally {
                $nameProcesses | ForEach-Object { WdDisposeProcessResult $_ }
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
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hash = ($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Url)) |
        ForEach-Object { $_.ToString("x2") }) -join ''
    $md5.Dispose()
    $short = $hash.Substring(0, 8)
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
    foreach ($p in $edgePaths) { if (Test-Path $p) { return $p } }
    return "chrome.exe"
}

function WdWaitForWindowHandle {
    param(
        $ProcessObj,
        [int]$TimeoutMs = 5000
    )

    $elapsed = 0
    $hwnd = [IntPtr]::Zero

    while ($ProcessObj -and $elapsed -lt $TimeoutMs) {
        try {
            $ProcessObj.Refresh()
            if ($null -ne $ProcessObj.MainWindowHandle) {
                $hwnd = [IntPtr]$ProcessObj.MainWindowHandle
            }
        }
        catch {
            $hwnd = [IntPtr]::Zero
            break
        }

        if ($hwnd -ne [IntPtr]::Zero) {
            return $hwnd
        }

        Start-Sleep -Milliseconds $WD_WINDOW_HANDLE_POLL_MS
        $elapsed += $WD_WINDOW_HANDLE_POLL_MS
    }

    return $hwnd
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

    $hwnd = WdWaitForWindowHandle -ProcessObj $ProcessObj -TimeoutMs $WD_FOCUS_WINDOW_HANDLE_TIMEOUT_MS
    if ($null -eq $hwnd -or $hwnd -eq [IntPtr]::Zero) { return $false }

    if (WdIsWindowForeground -Hwnd $hwnd) { return $true }

    $currentThreadId = [WatchdogWin32.DisplayAPI]::GetCurrentThreadId()
    $targetThreadId = [WatchdogWin32.DisplayAPI]::GetWindowThreadProcessId($hwnd, [IntPtr]::Zero)
    $attached = $false
    $success = $false

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
        [bool]$Fullscreen,
        [switch]$ForceRefresh
    )

    if ($null -eq $ProcessObj) { return $false }

    $previousDpiContext = [IntPtr]::Zero
    try {
        # Watchdog 由隐藏 PowerShell 宿主运行，而 Unity 通常是 Per-Monitor DPI Aware。
        # 在相同 DPI 上下文内读取和设置跨进程窗口，避免 150%/200% 缩放导致半屏。
        $previousDpiContext = [WatchdogWin32.DisplayAPI]::EnterPerMonitorDpiAwareness()

    $hwnd = WdWaitForWindowHandle -ProcessObj $ProcessObj -TimeoutMs $WD_REPAIR_WINDOW_HANDLE_TIMEOUT_MS
    if ($hwnd -eq [IntPtr]::Zero) {
        WdWriteLog "DISPLAY: Window handle not ready, skipping repair." "DarkGray"
        return $false
    }

    $winRect = New-Object WatchdogWin32.DisplayAPI+RECT
    if (-not [WatchdogWin32.DisplayAPI]::GetWindowRect($hwnd, [ref]$winRect)) {
        WdWriteLog "DISPLAY: Failed to read the target window rectangle." "DarkYellow"
        return $false
    }

    $hMonitor = [WatchdogWin32.DisplayAPI]::MonitorFromWindow($hwnd, $MONITOR_NEAREST)
    if ($hMonitor -eq [IntPtr]::Zero) {
        WdWriteLog "DISPLAY: No monitor is available for the target window." "DarkYellow"
        return $false
    }
    $mi = New-Object WatchdogWin32.DisplayAPI+MONITORINFO
    $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mi)
    if (-not [WatchdogWin32.DisplayAPI]::GetMonitorInfo($hMonitor, [ref]$mi)) {
        WdWriteLog "DISPLAY: Failed to read monitor bounds." "DarkYellow"
        return $false
    }

    $mLeft = $mi.rcMonitor.left
    $mTop = $mi.rcMonitor.top
    $mWidth = $mi.rcMonitor.right - $mi.rcMonitor.left
    $mHeight = $mi.rcMonitor.bottom - $mi.rcMonitor.top
    if ($mWidth -le 0 -or $mHeight -le 0) {
        WdWriteLog "DISPLAY: Monitor bounds are not ready (${mWidth}x${mHeight})." "DarkYellow"
        return $false
    }

    $isFullscreen = (
        [Math]::Abs($winRect.left - $mLeft) -le $WD_FULLSCREEN_TOLERANCE_PX -and
        [Math]::Abs($winRect.top - $mTop) -le $WD_FULLSCREEN_TOLERANCE_PX -and
        [Math]::Abs(($winRect.right - $winRect.left) - $mWidth) -le $WD_FULLSCREEN_TOLERANCE_PX -and
        [Math]::Abs(($winRect.bottom - $winRect.top) - $mHeight) -le $WD_FULLSCREEN_TOLERANCE_PX
    )

    if ($Fullscreen -and (-not $isFullscreen -or $ForceRefresh)) {
        WdWriteLog "DISPLAY: Forcing fullscreen for PID $($ProcessObj.Id)..." "Yellow"
        $curStyle = [WatchdogWin32.DisplayAPI]::GetWindowLong($hwnd, $GWL_STYLE)
        $newStyle = $curStyle -band (-bnot $WS_OVERLAPPEDWINDOW)
        [WatchdogWin32.DisplayAPI]::SetWindowLong($hwnd, $GWL_STYLE, $newStyle) | Out-Null
        [WatchdogWin32.DisplayAPI]::ShowWindow($hwnd, $SW_RESTORE) | Out-Null
        $fullscreenApplied = [WatchdogWin32.DisplayAPI]::SetWindowPos(
            $hwnd, $HWND_TOP,
            $mLeft, $mTop, $mWidth, $mHeight,
            ($SWP_FRAMECHANGED -bor $SWP_SHOWWINDOW -bor $SWP_NOZORDER)
        )
        if (-not $fullscreenApplied) {
            WdWriteLog "DISPLAY: Failed to resize PID $($ProcessObj.Id) to fullscreen." "DarkYellow"
            return $false
        }
        WdWriteLog "DISPLAY: Fullscreen applied ($mWidth x $mHeight)." "Green"
    }
    elseif (-not $Fullscreen -and $isFullscreen) {
        WdWriteLog "DISPLAY: Forcing windowed for PID $($ProcessObj.Id)..." "Yellow"
        $curStyle = [WatchdogWin32.DisplayAPI]::GetWindowLong($hwnd, $GWL_STYLE)
        $newStyle = $curStyle -bor $WS_OVERLAPPEDWINDOW
        [WatchdogWin32.DisplayAPI]::SetWindowLong($hwnd, $GWL_STYLE, $newStyle) | Out-Null

        $winW = [Math]::Min($WD_WINDOWED_MAX_W, [Math]::Max($WD_WINDOWED_MIN_W, $mWidth - $WD_WINDOWED_MARGIN))
        $winH = [Math]::Min($WD_WINDOWED_MAX_H, [Math]::Max($WD_WINDOWED_MIN_H, $mHeight - $WD_WINDOWED_MARGIN))
        $winX = $mLeft + [int](($mWidth - $winW) / 2)
        $winY = $mTop + [int](($mHeight - $winH) / 2)

        [WatchdogWin32.DisplayAPI]::ShowWindow($hwnd, $SW_RESTORE) | Out-Null
        [WatchdogWin32.DisplayAPI]::SetWindowPos(
            $hwnd, $HWND_TOP,
            $winX, $winY, $winW, $winH,
            ($SWP_FRAMECHANGED -bor $SWP_SHOWWINDOW -bor $SWP_NOZORDER)
        ) | Out-Null
        WdWriteLog "DISPLAY: Windowed applied (${winW}x${winH} @ $winX,$winY)." "Green"
    }

    return $true
    }
    finally {
        [WatchdogWin32.DisplayAPI]::RestoreThreadDpiAwareness($previousDpiContext)
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
        [bool]$KillTree,
        [int]$TimeoutSeconds = $ProcessStopTimeoutSeconds,
        [int]$PollMilliseconds = 250
    )

    if ($ProcessId -le 0) { return $false }

    if (-not (WdTestProcessIdAlive -ProcessId $ProcessId)) {
        return $true
    }

    try {
        if ($KillTree) {
            $output = & taskkill.exe /PID $ProcessId /T /F 2>&1
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                $message = (($output | ForEach-Object { [string]$_ }) -join " ").Trim()
                if ([string]::IsNullOrWhiteSpace($message)) { $message = "exit code $exitCode" }
                WdWriteLog "STOP: taskkill failed for PID=$ProcessId - $message" "DarkYellow"
            }
        }
        else {
            Stop-Process -Id $ProcessId -Force -ErrorAction Stop
        }
    }
    catch {
        WdWriteLog "STOP: Failed to request stop for PID=$ProcessId - $($_.Exception.Message)" "DarkYellow"
    }

    $deadline = (Get-Date).AddSeconds([Math]::Max(0, $TimeoutSeconds))
    while ((Get-Date) -lt $deadline) {
        if (-not (WdTestProcessIdAlive -ProcessId $ProcessId)) {
            WdWriteLog "STOP: PID=$ProcessId exited." "DarkGray"
            return $true
        }
        Start-Sleep -Milliseconds ([Math]::Max(50, $PollMilliseconds))
    }

    if (-not (WdTestProcessIdAlive -ProcessId $ProcessId)) {
        WdWriteLog "STOP: PID=$ProcessId exited." "DarkGray"
        return $true
    }

    WdWriteLog "STOP: PID=$ProcessId still running after $TimeoutSeconds sec." "Red"
    return $false
}

function WdIsProcessMissing {
    param([string]$Path)
    $procs = WdGetTargetProcess -Path $Path
    $count = if ($procs) { ($procs | Measure-Object).Count } else { 0 }

    if ($procs) {
        $procs | ForEach-Object { WdDisposeProcessResult $_ }
    }

    return ($count -eq 0)
}

function WdStartVisibleExeAsDesktopUser {
    param(
        [string]$Path,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [int]$ProcessLookupTimeoutMs = 10000
    )

    # Watchdog 可能因为修改开机启动/锁屏设置而通过 UAC 提权。直接 Start-Process
    # 会让 Unity 继承高完整性令牌，与用户双击或 Windows Startup 快捷方式启动不同。
    # Shell.Application 由桌面 Explorer 代理启动，因此目标返回普通用户令牌和桌面上下文。
    $shellApplication = $null
    try {
        $shellApplication = New-Object -ComObject Shell.Application -ErrorAction Stop
        $shellArguments = if ([string]::IsNullOrWhiteSpace($Arguments)) { "" } else { $Arguments }
        [void]$shellApplication.ShellExecute($Path, $shellArguments, $WorkingDirectory, "open", 1)

        $deadline = (Get-Date).AddMilliseconds([Math]::Max(1000, $ProcessLookupTimeoutMs))
        do {
            if ($Script:ExitRequested) { return $null }
            Start-Sleep -Milliseconds 100

            $startedProcesses = @(WdGetTargetProcess -Path $Path)
            if ($startedProcesses.Count -gt 0) {
                $startedProcess = $startedProcesses |
                    Sort-Object @{ Expression = { WdGetProcessStartTimeSafe $_ }; Descending = $true } |
                    Select-Object -First 1
                $startedPid = WdGetProcessId $startedProcess
                foreach ($candidate in $startedProcesses) {
                    if ((WdGetProcessId $candidate) -ne $startedPid) {
                        WdDisposeProcessResult $candidate
                    }
                }
                return $startedProcess
            }
        } while ((Get-Date) -lt $deadline)

        throw "Explorer accepted the launch request, but the target process was not detected within $ProcessLookupTimeoutMs ms."
    }
    finally {
        if ($shellApplication -and [System.Runtime.InteropServices.Marshal]::IsComObject($shellApplication)) {
            try { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shellApplication) } catch {}
        }
    }
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
        $browserExe = WdResolveBrowserExe -Browser $Browser
        $profileBase = Join-Path $WatchdogRoot "browser_profiles"
        $profileDir = Join-Path $profileBase (WdSanitizeForPath -Url $Path)

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
            WdOfferAuthorizationForError -Exception $_.Exception -Operation "启动 $FileName"
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
            $argText = if ([string]::IsNullOrWhiteSpace($Arguments)) { "" } else { " $Arguments" }
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
            WdOfferAuthorizationForError -Exception $_.Exception -Operation "启动 $FileName"
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
            $pyExe = WdGetPythonInterpreter -HideWindow:$HideWindow -PythonExe $PythonExe
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
            WdOfferAuthorizationForError -Exception $_.Exception -Operation "启动 $FileName"
            return $null
        }
        finally {
            if (-not $startSucceeded -and $proc) { try { $proc.Dispose() } catch {} }
        }
    }

    $proc = $null
    $startSucceeded = $false
    try {
        $cmdLine = if ([string]::IsNullOrWhiteSpace($Arguments)) { $Path } else { "$Path $Arguments" }
        WdWriteLog "START: Launching [$FileName] CMD=[$cmdLine]" "DarkCyan"

        $splat = @{
            FilePath         = $Path
            WorkingDirectory = $Dir
            PassThru         = $true
            ErrorAction      = 'Stop'
        }
        # 可见 GUI 程序不显式传入 STARTF_USESHOWWINDOW/SW_SHOWNORMAL，使 Unity 的
        # 创建方式与资源管理器或 Windows “启动”快捷方式直接启动保持一致。
        if ($HideWindow) {
            $splat.WindowStyle = 'Hidden'
        }
        if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
            $splat.ArgumentList = $Arguments
        }
        if (-not $HideWindow) {
            WdWriteLog "START: Using the Explorer desktop context for [$FileName]." "DarkCyan"
            $proc = WdStartVisibleExeAsDesktopUser `
                -Path $Path `
                -Arguments $Arguments `
                -WorkingDirectory $Dir
        }
        else {
            $proc = Start-Process @splat
        }

        if (-not $proc) {
            throw "The target process was not returned after launch."
        }

        WdWriteProcessStartLog -FileName $FileName -Proc $proc `
            -Details "Hide=$HideWindow, FocusTop=$FocusTop, Fullscreen=$Fullscreen, ExplorerDesktopLaunch=$(-not $HideWindow)"

        if ($FocusTop -and -not $HideWindow -and $proc) {
            Start-Sleep -Milliseconds $WD_INITIAL_FOCUS_DELAY_MS
            [void](WdSetWindowToForeground -ProcessObj $proc)
        }

        $startSucceeded = $true
        return $proc
    }
    catch {
        WdWriteLog "FAILED: $FileName - $($_.Exception.Message)" "Red"
        WdOfferAuthorizationForError -Exception $_.Exception -Operation "启动 $FileName"
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
        $RestartStats, $LaunchTime, $DisplayRepairDone, $HangFailCount, $LastStartedProcessId, $FastExitHandledLaunch
    )
    $proc = $null
    try {
        # Count every actual launch attempt, including failures, so a broken path or
        # permission error cannot bypass MaxRetryInHour and retry indefinitely.
        $RestartStats[$StatKey] = [int]$RestartStats[$StatKey] + 1
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

        if ($proc) {
            $LaunchTime[$Path] = Get-Date
            if (WdIsDisplayChangeRestartEnabled -Path $Path -Config $Config) {
                $Script:DisplayEventQuietUntil = (Get-Date).AddSeconds($UnityDisplayStartupGraceSeconds)
            }
            $DisplayRepairDone[$Path] = $false
            $HangFailCount[$Path] = 0
            $LastStartedProcessId[$Path] = $proc.Id
            if ($FastExitHandledLaunch) { $FastExitHandledLaunch[$Path] = $false }
            if ($IsOnce) { $RestartStats[$OnceKey] = $true }
        }
    }
    finally {
        if ($proc) { try { $proc.Dispose() } catch {} }
    }
}

# =================== 5.1 TCP / UDP 控制 ===================
$Script:ControlTcpListener = $null
$Script:ControlUdpClient = $null
$Script:ControlTcpClients = New-Object System.Collections.ArrayList
$Script:PendingControlRestart = $false
$Script:PendingSystemPowerAction = $null

function WdTestControlRemoteAllowed {
    param([System.Net.IPAddress]$RemoteAddress)

    if ($null -eq $RemoteAddress) { return $false }
    if (@($ControlAllowedRemoteAddresses).Count -eq 0) { return $true }

    $remoteText = $RemoteAddress.ToString()
    foreach ($allowedAddress in @($ControlAllowedRemoteAddresses)) {
        if ($remoteText.Equals(([string]$allowedAddress).Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function WdFormatVolumeState {
    param($State)

    if ($null -eq $State) { return "ERR volume state unavailable" }
    $muteValue = if ([bool]$State.Muted) { 1 } else { 0 }
    return "VOL $([int]$State.Volume) MUTE $muteValue"
}

function WdInvokeVolumeCommand {
    param([string]$Command)

    if (-not ([System.Management.Automation.PSTypeName]'WatchdogAudio.AudioAPI').Type) {
        return "ERR volume control unavailable"
    }

    $normalized = ([regex]::Replace($Command.Trim(), '\s+', ' ')).ToUpperInvariant()
    try {
        if ($normalized -eq "VOL GET") {
            return WdFormatVolumeState -State ([WatchdogAudio.AudioAPI]::GetState())
        }

        if ($normalized -match '^VOL (SET|INC|DEC) ([0-9]{1,3})$') {
            $operation = $Matches[1]
            $amount = [int]$Matches[2]
            if ($amount -lt 0 -or $amount -gt 100) {
                return "ERR volume value must be between 0 and 100"
            }

            $state = switch ($operation) {
                "SET" { [WatchdogAudio.AudioAPI]::SetVolume($amount) }
                "INC" { [WatchdogAudio.AudioAPI]::AdjustVolume($amount) }
                "DEC" { [WatchdogAudio.AudioAPI]::AdjustVolume(-$amount) }
            }
            WdWriteLog "CONTROL: Applied [$normalized]." "DarkCyan"
            return WdFormatVolumeState -State $state
        }

        if ($normalized -match '^VOL MUTE ([01])$') {
            $muted = ($Matches[1] -eq "1")
            $state = [WatchdogAudio.AudioAPI]::SetMute($muted)
            WdWriteLog "CONTROL: Applied [$normalized]." "DarkCyan"
            return WdFormatVolumeState -State $state
        }

        return "ERR VOL syntax: VOL GET | VOL SET/INC/DEC 0-100 | VOL MUTE 0/1"
    }
    catch {
        WdWriteLog "CONTROL: Volume command failed - $($_.Exception.Message)" "Red"
        return "ERR volume control failed"
    }
}

function WdTestCompleteVolumeCommand {
    param([string]$Command)

    $normalized = [regex]::Replace($Command.Trim(), '\s+', ' ')
    return ($normalized -match '^(?i:VOL GET)$' -or
        $normalized -match '^(?i:VOL (SET|INC|DEC) [0-9]{1,3})$' -or
        $normalized -match '^(?i:VOL MUTE [01])$')
}

function WdTestControlCommandPrefix {
    param([string]$Candidate)

    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $true }
    $normalized = ([regex]::Replace($Candidate.TrimStart(), '\s+', ' ')).ToLowerInvariant()
    $templates = @(
        "ping", "heartbeat", "reboot", "shutdown", "restart",
        "vol get", "vol set 000", "vol inc 000", "vol dec 000", "vol mute 0", "vol mute 1"
    )

    foreach ($template in $templates) {
        if ($template.StartsWith($normalized, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return ($normalized -match '^vol (set|inc|dec) [0-9]{1,3}$')
}

function WdGetControlResponse {
    param(
        [string]$Command,
        [string]$Protocol,
        [System.Net.IPAddress]$RemoteAddress
    )

    $source = if ($RemoteAddress) { $RemoteAddress.ToString() } else { "unknown" }
    if (-not (WdTestControlRemoteAllowed -RemoteAddress $RemoteAddress)) {
        WdWriteLog "CONTROL: Rejected $Protocol command from unauthorized source [$source]." "Red"
        return "ERR source not allowed"
    }

    $normalizedCommand = if ($null -eq $Command) { "" } else { $Command.Trim().ToLowerInvariant() }
    if ($normalizedCommand -match '^vol(?:\s|$)') {
        return WdInvokeVolumeCommand -Command $Command
    }

    switch ($normalizedCommand) {
        { $_ -in @("ping", "heartbeat") } {
            return "pong"
        }
        "restart" {
            $Script:PendingControlRestart = $true
            WdWriteLog "CONTROL: Accepted restart command via $Protocol from [$source]." "Yellow"
            return "OK restart accepted"
        }
        "reboot" {
            if ($Script:PendingSystemPowerAction) {
                return "ERR system power action already pending"
            }
            $Script:PendingSystemPowerAction = "reboot"
            WdWriteLog "CONTROL: Accepted reboot command via $Protocol from [$source]." "Red"
            return "OK reboot accepted"
        }
        "shutdown" {
            if ($Script:PendingSystemPowerAction) {
                return "ERR system power action already pending"
            }
            $Script:PendingSystemPowerAction = "shutdown"
            WdWriteLog "CONTROL: Accepted shutdown command via $Protocol from [$source]." "Red"
            return "OK shutdown accepted"
        }
        default {
            return $null
        }
    }
}

function WdSendTcpControlResponse {
    param($State, [string]$Response)

    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Response + "`r`n")
        $State.Stream.Write($bytes, 0, $bytes.Length)
        $State.Stream.Flush()
    }
    catch {
        WdWriteLog "CONTROL: Failed to send TCP response - $($_.Exception.Message)" "DarkYellow"
    }
}

function WdCloseTcpControlClient {
    param($State)

    if ($null -eq $State) { return }
    try { $State.Stream.Dispose() } catch {}
    try { $State.Client.Close() } catch {}
    try { $State.Client.Dispose() } catch {}
    [void]$Script:ControlTcpClients.Remove($State)
}

function WdPollControlListeners {
    if (-not $ControlEnabled) { return }

    if ($Script:ControlUdpClient) {
        try {
            while ($Script:ControlUdpClient.Available -gt 0) {
                $remoteEndpoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
                $payload = $Script:ControlUdpClient.Receive([ref]$remoteEndpoint)
                $response = if ($payload.Length -gt $ControlMaxMessageBytes) {
                    "ERR message too large"
                }
                else {
                    $command = [System.Text.Encoding]::UTF8.GetString($payload)
                    WdGetControlResponse -Command $command -Protocol "UDP" -RemoteAddress $remoteEndpoint.Address
                }

                if ($null -ne $response) {
                    try {
                        $responseBytes = [System.Text.Encoding]::UTF8.GetBytes($response + "`r`n")
                        [void]$Script:ControlUdpClient.Send($responseBytes, $responseBytes.Length, $remoteEndpoint)
                    }
                    catch {
                        WdWriteLog "CONTROL: Failed to send UDP response to [$remoteEndpoint] - $($_.Exception.Message)" "DarkYellow"
                    }
                }
            }
        }
        catch {
            WdWriteLog "CONTROL: UDP polling failed - $($_.Exception.Message)" "Red"
        }
    }

    if (-not $Script:ControlTcpListener) { return }

    try {
        while ($Script:ControlTcpListener.Pending()) {
            $client = $Script:ControlTcpListener.AcceptTcpClient()
            if ($Script:ControlTcpClients.Count -ge 32) {
                try { $client.Close() } catch {}
                WdWriteLog "CONTROL: Rejected TCP connection because the client limit was reached." "DarkYellow"
                continue
            }

            $client.NoDelay = $true
            $client.Client.SetSocketOption(
                [System.Net.Sockets.SocketOptionLevel]::Socket,
                [System.Net.Sockets.SocketOptionName]::KeepAlive,
                $true
            )
            $remoteEndpoint = $client.Client.RemoteEndPoint
            $state = [PSCustomObject]@{
                Client        = $client
                Stream        = $client.GetStream()
                Buffer        = New-Object System.Text.StringBuilder
                ConnectedAt   = Get-Date
                LastActivity  = Get-Date
                RemoteAddress = $remoteEndpoint.Address
                TooLarge      = $false
            }
            [void]$Script:ControlTcpClients.Add($state)
        }
    }
    catch {
        WdWriteLog "CONTROL: TCP accept failed - $($_.Exception.Message)" "Red"
    }

    foreach ($state in @($Script:ControlTcpClients)) {
        $shouldClose = $false
        try {
            # SelectRead + Available=0 means the peer closed the connection gracefully.
            if ($state.Client.Client.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead) -and
                $state.Client.Client.Available -eq 0) {
                $shouldClose = $true
            }

            while ($state.Stream.DataAvailable) {
                $readBuffer = [byte[]]::new(256)
                $readCount = $state.Stream.Read($readBuffer, 0, $readBuffer.Length)
                if ($readCount -le 0) {
                    $shouldClose = $true
                    break
                }

                $state.LastActivity = Get-Date
                [void]$state.Buffer.Append([System.Text.Encoding]::UTF8.GetString($readBuffer, 0, $readCount))
                if ($state.Buffer.Length -gt $ControlMaxMessageBytes) {
                    $state.TooLarge = $true
                    break
                }
            }

            if ($state.TooLarge) {
                WdSendTcpControlResponse -State $state -Response "ERR message too large"
                [void]$state.Buffer.Clear()
                $state.TooLarge = $false
            }

            # TCP 是字节流：按 CR/LF 拆分多条消息，并保留尚未完整的尾部数据。
            $messages = New-Object System.Collections.ArrayList
            $bufferText = $state.Buffer.ToString()
            $delimiterIndex = $bufferText.IndexOfAny([char[]]"`r`n")
            while ($delimiterIndex -ge 0) {
                $message = $bufferText.Substring(0, $delimiterIndex)
                if (-not [string]::IsNullOrWhiteSpace($message)) {
                    [void]$messages.Add($message)
                }

                $nextIndex = $delimiterIndex + 1
                while ($nextIndex -lt $bufferText.Length -and
                    ($bufferText[$nextIndex] -eq "`r" -or $bufferText[$nextIndex] -eq "`n")) {
                    $nextIndex++
                }
                $bufferText = $bufferText.Substring($nextIndex)
                $delimiterIndex = $bufferText.IndexOfAny([char[]]"`r`n")
            }
            [void]$state.Buffer.Clear()
            [void]$state.Buffer.Append($bufferText)

            # 保持兼容：单条完整的已知指令无需换行符也会立即执行。
            $candidate = $state.Buffer.ToString().Trim().ToLowerInvariant()
            $knownCommands = @("ping", "heartbeat", "reboot", "shutdown", "restart")
            if ($candidate -in $knownCommands) {
                [void]$messages.Add($state.Buffer.ToString())
                [void]$state.Buffer.Clear()
            }
            elseif ((WdTestCompleteVolumeCommand -Command $candidate) -and
                ((Get-Date) - $state.LastActivity).TotalMilliseconds -ge $ControlTcpCommandSettleMilliseconds) {
                [void]$messages.Add($state.Buffer.ToString())
                [void]$state.Buffer.Clear()
            }
            elseif (-not [string]::IsNullOrWhiteSpace($candidate)) {
                # TCP 可能把上一段未知数据与心跳粘在一起。仅允许安全的心跳做后缀恢复，
                # reboot/shutdown/restart 必须完整、独立匹配，避免任意数据误触发系统操作。
                $heartbeatSuffix = @("heartbeat", "ping") |
                    Where-Object { $candidate.EndsWith($_, [System.StringComparison]::OrdinalIgnoreCase) } |
                    Select-Object -First 1

                if ($heartbeatSuffix) {
                    [void]$messages.Add($heartbeatSuffix)
                    [void]$state.Buffer.Clear()
                }
                else {
                    $isKnownPrefix = WdTestControlCommandPrefix -Candidate $candidate

                    if (-not $isKnownPrefix -or
                        ((Get-Date) - $state.LastActivity).TotalMilliseconds -ge $ControlTcpPartialCommandTimeoutMilliseconds) {
                        # 不能识别的数据直接丢弃，不能污染下一条指令。
                        [void]$state.Buffer.Clear()
                    }
                }
            }

            foreach ($message in $messages) {
                $response = WdGetControlResponse -Command $message -Protocol "TCP" -RemoteAddress $state.RemoteAddress
                if ($null -ne $response) {
                    WdSendTcpControlResponse -State $state -Response $response
                }
            }

            if ($ControlTcpIdleTimeoutSeconds -gt 0 -and
                ((Get-Date) - $state.LastActivity).TotalSeconds -ge $ControlTcpIdleTimeoutSeconds) {
                WdWriteLog "CONTROL: Closing idle TCP client [$($state.RemoteAddress)] after $ControlTcpIdleTimeoutSeconds sec." "DarkGray"
                $shouldClose = $true
            }
        }
        catch {
            WdWriteLog "CONTROL: TCP client processing failed - $($_.Exception.Message)" "DarkYellow"
            $shouldClose = $true
        }

        if ($shouldClose) {
            WdCloseTcpControlClient -State $state
        }
    }
}

function WdStartControlListeners {
    if (-not $ControlEnabled) {
        WdWriteLog "CONTROL: TCP / UDP control is disabled." "DarkGray"
        return $true
    }

    try {
        $bindAddress = [System.Net.IPAddress]::Parse($ControlListenAddress)
        $tcpListener = [System.Net.Sockets.TcpListener]::new($bindAddress, $ControlPort)
        $tcpListener.Server.ExclusiveAddressUse = $true
        $tcpListener.Start()

        $udpEndpoint = [System.Net.IPEndPoint]::new($bindAddress, $ControlPort)
        $udpClient = [System.Net.Sockets.UdpClient]::new($bindAddress.AddressFamily)
        $udpClient.Client.ExclusiveAddressUse = $true
        $udpClient.Client.Bind($udpEndpoint)

        $Script:ControlTcpListener = $tcpListener
        $Script:ControlUdpClient = $udpClient
        WdWriteLog "CONTROL: TCP and UDP listening on ${ControlListenAddress}:$ControlPort." "Green"
        if (@($ControlAllowedRemoteAddresses).Count -eq 0) {
            WdWriteLog "CONTROL: WARNING - all remote IP addresses are allowed." "DarkYellow"
        }
        return $true
    }
    catch {
        WdWriteLog "CONTROL: Failed to start TCP / UDP listeners on ${ControlListenAddress}:$ControlPort - $($_.Exception.Message)" "Red"
        WdStopControlListeners
        return $false
    }
}

function WdStopControlListeners {
    foreach ($state in @($Script:ControlTcpClients)) {
        WdCloseTcpControlClient -State $state
    }
    try { $Script:ControlTcpClients.Clear() } catch {}

    if ($Script:ControlTcpListener) {
        try { $Script:ControlTcpListener.Stop() } catch {}
        $Script:ControlTcpListener = $null
    }
    if ($Script:ControlUdpClient) {
        try { $Script:ControlUdpClient.Close() } catch {}
        try { $Script:ControlUdpClient.Dispose() } catch {}
        $Script:ControlUdpClient = $null
    }
}

function WdRestartTopmostApps {
    $restartCount = 0

    foreach ($path in $Apps.Keys) {
        $config = $Apps[$path]
        if (-not $config.ContainsKey("FocusTop") -or -not [bool]$config.FocusTop) { continue }

        if (WdIsBrowserUrl -Path $path) {
            try { $fileName = "[$(([System.Uri]$path).Host)]" }
            catch { $fileName = $path }
        }
        else {
            $fileName = [System.IO.Path]::GetFileName($path)
        }

        $restartDelay = WdGetConfigInt -Config $config -Name "Restart" -DefaultValue 0 -Minimum 0
        $killTree = if ($config.ContainsKey("KillTreeOnHang")) { [bool]$config.KillTreeOnHang } else { $true }
        $processes = WdGetTargetProcess -Path $path

        WdWriteLog "CONTROL: Restarting topmost target $fileName; relaunch scheduled in $restartDelay sec." "Yellow"
        foreach ($process in @($processes)) {
            $processId = WdGetProcessId $process
            if ($processId -gt 0) {
                [void](WdStopProcessTreeSafe -ProcessId $processId -KillTree $killTree)
            }
            WdDisposeProcessResult $process
        }

        foreach ($key in @($RestartStats.Keys)) {
            if ([string]$key -like "${path}::H*") { $RestartStats.Remove($key) }
        }
        $RestartStats["${path}::Once"] = $false
        $ScheduledLaunch[$path] = (Get-Date).AddSeconds($restartDelay)
        [void]$LaunchTime.Remove($path)
        [void]$DisplayRepairDone.Remove($path)
        $HangFailCount[$path] = 0
        $FastExitFailCount[$path] = 0
        [void]$FastExitHandledLaunch.Remove($path)
        [void]$LastStartAttempt.Remove($path)
        [void]$DisplayChangeRestartInProgress.Remove($path)
        $restartCount++
    }

    WdWriteLog "CONTROL: Topmost target restart scheduling complete. Targets=$restartCount." "DarkGreen"
}

function WdInvokePendingControlActions {
    if ($Script:PendingSystemPowerAction) {
        $action = $Script:PendingSystemPowerAction
        $Script:PendingSystemPowerAction = $null
        $Script:PendingControlRestart = $false
        $shutdownExe = Join-Path $env:SystemRoot "System32\shutdown.exe"
        $arguments = if ($action -eq "reboot") { "/r /t 0 /f" } else { "/s /t 0 /f" }

        try {
            WdWriteLog "CONTROL: Executing system $action." "Red"
            Start-Process -FilePath $shutdownExe -ArgumentList $arguments -ErrorAction Stop | Out-Null
        }
        catch {
            WdWriteLog "CONTROL: Failed to execute system $action - $($_.Exception.Message)" "Red"
        }
        return
    }

    if ($Script:PendingControlRestart) {
        $Script:PendingControlRestart = $false
        WdRestartTopmostApps
    }
}

# =================== 5.2 界面配置 / 权限 ===================
function WdTestIsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function WdSetAuthorizationControlsVisible {
    param([bool]$Visible)

    if ($Script:TrayElevateMenuItem -and -not $Script:TrayElevateMenuItem.IsDisposed) {
        $Script:TrayElevateMenuItem.Visible = $Visible
    }
}

function WdGetRegistryValue {
    param([string]$Path, [string]$Name)

    try {
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    }
    catch {
        return $null
    }
}

function WdSetRegistryDword {
    param([string]$Path, [string]$Name, [int]$Value)

    if (-not (Test-Path -LiteralPath $Path)) {
        [void](New-Item -Path $Path -Force -ErrorAction Stop)
    }
    [void](New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType DWord -Force -ErrorAction Stop)
}

function WdSetRegistryString {
    param([string]$Path, [string]$Name, [AllowEmptyString()][string]$Value)

    if (-not (Test-Path -LiteralPath $Path)) {
        [void](New-Item -Path $Path -Force -ErrorAction Stop)
    }
    [void](New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType String -Force -ErrorAction Stop)
}

function WdRemoveRegistryValue {
    param([string]$Path, [string]$Name)

    if (Test-Path -LiteralPath $Path) {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction SilentlyContinue
    }
}

function WdTestLockScreenSettingMatches {
    param([bool]$Disabled)

    $personalizationPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
    $systemPolicyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    $desktopPath = "HKCU:\Control Panel\Desktop"
    $userPolicyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System"

    $noLockScreen = WdGetRegistryValue -Path $personalizationPath -Name "NoLockScreen"
    $inactivityTimeout = WdGetRegistryValue -Path $systemPolicyPath -Name "InactivityTimeoutSecs"
    $screenSaveActive = WdGetRegistryValue -Path $desktopPath -Name "ScreenSaveActive"
    $screenSaverIsSecure = WdGetRegistryValue -Path $desktopPath -Name "ScreenSaverIsSecure"
    $disableLockWorkstation = WdGetRegistryValue -Path $userPolicyPath -Name "DisableLockWorkstation"

    if ($Disabled) {
        return (
            [int]$noLockScreen -eq 1 -and
            [int]$inactivityTimeout -eq 0 -and
            [string]$screenSaveActive -eq "0" -and
            [string]$screenSaverIsSecure -eq "0" -and
            [int]$disableLockWorkstation -eq 1
        )
    }

    return ([int]$noLockScreen -ne 1 -and [int]$disableLockWorkstation -ne 1)
}

function WdInvokePowerConfiguration {
    param([bool]$DisableLockScreen)

    $powercfgPath = Join-Path $env:SystemRoot "System32\powercfg.exe"
    $timeouts = if ($DisableLockScreen) {
        @(
            @("monitor-timeout-ac", "0"), @("monitor-timeout-dc", "0"),
            @("standby-timeout-ac", "0"), @("standby-timeout-dc", "0")
        )
    }
    else {
        @(
            @("monitor-timeout-ac", "10"), @("monitor-timeout-dc", "5"),
            @("standby-timeout-ac", "30"), @("standby-timeout-dc", "15")
        )
    }

    foreach ($timeout in $timeouts) {
        & $powercfgPath /change $timeout[0] $timeout[1] | Out-Null
        if ($LASTEXITCODE -ne 0) {
            WdWriteLog "UI: Power setting update failed: $($timeout[0])." "DarkYellow"
        }
    }
}

function WdGetPhysicalNetworkAdapters {
    $adapters = @()
    try {
        $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.MacAddress) } |
            Select-Object Name, InterfaceDescription, MacAddress, ifIndex)
    }
    catch {
        $adapters = @(Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.PhysicalAdapter -and -not [string]::IsNullOrWhiteSpace([string]$_.MACAddress) } |
            ForEach-Object {
                [pscustomobject]@{
                    Name = if ($_.NetConnectionID) { $_.NetConnectionID } else { $_.Name }
                    InterfaceDescription = $_.Name
                    MacAddress = $_.MACAddress
                    ifIndex = $_.Index
                }
            })
    }
    return @($adapters | Sort-Object Name, MacAddress)
}

function WdSetFastStartupDisabled {
    if (-not (WdTestIsAdministrator)) { throw "修改 Windows 快速启动设置需要管理员权限。" }
    $powerPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
    WdSetRegistryDword -Path $powerPath -Name "HiberbootEnabled" -Value 0
    $current = WdGetRegistryValue -Path $powerPath -Name "HiberbootEnabled"
    if ([int]$current -ne 0) { throw "Windows 快速启动设置更新后校验失败。" }
    WdWriteLog "WAKE: Windows Fast Startup disabled." "DarkGreen"
}

function WdTestMagicWakeSettingMatches {
    $fastStartup = WdGetRegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled"
    if ($null -eq $fastStartup -or [int]$fastStartup -ne 0) {
        return $false
    }

    $adapters = @(WdGetPhysicalNetworkAdapters)
    if ($adapters.Count -eq 0) { return $true }
    $wakeArmed = ""
    try {
        $wakeArmed = (& (Join-Path $env:SystemRoot "System32\powercfg.exe") /devicequery wake_armed 2>$null) -join "`n"
    }
    catch {}

    foreach ($adapter in $adapters) {
        $isArmed = $wakeArmed -match [regex]::Escape([string]$adapter.InterfaceDescription)
        $advancedMatches = $true
        try {
            $advanced = @(Get-NetAdapterAdvancedProperty -Name ([string]$adapter.Name) -AllProperties -ErrorAction Stop |
                Where-Object {
                    ($_.DisplayName -match '(?i)wake\s*on\s*magic|magic\s*packet|shutdown.*wake|PME|魔法数据包|关机.*唤醒' -or
                        $_.RegistryKeyword -match '(?i)wakeonmagic|magicpacket|s5wake|shutdownwake|enablepme|modernstandbywol') -and
                    @($_.ValidDisplayValues | Where-Object { $_ -match '(?i)^enabled$|^on$|^yes$|启用|开启|打开|是|true|1' }).Count -gt 0
                })
            if ($advanced.Count -gt 0) {
                $advancedMatches = @($advanced | Where-Object {
                        $_.DisplayValue -notmatch '(?i)^enabled$|^on$|^yes$|启用|开启|打开|是|true|1'
                    }).Count -eq 0
            }
        }
        catch { $advancedMatches = $false }
        if (-not $isArmed -or -not $advancedMatches) { return $false }
    }
    return $true
}

function WdSetAdapterMagicWake {
    param($Adapter, [bool]$Enabled)

    $adapterName = [string]$Adapter.Name
    $displayName = [string]$Adapter.InterfaceDescription
    $changed = $false
    $powerState = if ($Enabled) { 'Enabled' } else { 'Disabled' }
    try {
        try {
            Set-NetAdapterPowerManagement -Name $adapterName `
                -WakeOnMagicPacket $powerState `
                -WakeOnPattern $powerState `
                -NoRestart -ErrorAction Stop
        }
        catch {
            Set-NetAdapterPowerManagement -InterfaceDescription $displayName `
                -WakeOnMagicPacket $powerState `
                -WakeOnPattern $powerState `
                -NoRestart -ErrorAction Stop
        }
        $changed = $true
    }
    catch {
        WdWriteLog "WAKE: Power-management setting skipped for [$displayName] - $($_.Exception.Message)" "DarkYellow"
    }
    try {
        $advanced = @(Get-NetAdapterAdvancedProperty -Name $adapterName -AllProperties -ErrorAction Stop |
            Where-Object {
                ($_.DisplayName -match '(?i)wake\s*on\s*magic|magic\s*packet|shutdown.*wake|PME|魔法数据包|关机.*唤醒' -or
                    $_.RegistryKeyword -match '(?i)wakeonmagic|magicpacket|s5wake|shutdownwake|enablepme|modernstandbywol') -and
                @($_.ValidDisplayValues | Where-Object { $_ -match '(?i)^enabled$|^on$|^yes$|启用|开启|打开|是|true|1' }).Count -gt 0
            })
        foreach ($property in $advanced) {
            try {
                $valuePattern = if ($Enabled) { '(?i)^enabled$|^on$|^yes$|启用|开启|打开|是|true|1' } else { '(?i)^disabled$|^off$|^no$|禁用|关闭|否|false|0' }
                $displayValue = @($property.ValidDisplayValues | Where-Object { $_ -match $valuePattern }) | Select-Object -First 1
                if (-not $displayValue) { $displayValue = @($property.ValidDisplayValues) | Select-Object -First 1 }
                if (-not $displayValue) { continue }
                Set-NetAdapterAdvancedProperty -Name $adapterName -DisplayName $property.DisplayName -DisplayValue $displayValue -NoRestart -ErrorAction Stop
                $changed = $true
            }
            catch {
                WdWriteLog "WAKE: Property [$($property.DisplayName)] skipped for [$displayName] - $($_.Exception.Message)" "DarkYellow"
            }
        }
    }
    catch {
        WdWriteLog "WAKE: Advanced property update skipped for [$displayName] - $($_.Exception.Message)" "DarkYellow"
    }

    try {
        $powercfgPath = Join-Path $env:SystemRoot "System32\powercfg.exe"
        $deviceNames = @($displayName, $adapterName) | Select-Object -Unique
        foreach ($deviceName in $deviceNames) {
            if ($Enabled) {
                & $powercfgPath /deviceenablewake $deviceName | Out-Null
            }
            else {
                & $powercfgPath /devicedisablewake $deviceName | Out-Null
            }
            if ($LASTEXITCODE -eq 0) { $changed = $true; break }
        }
    }
    catch {
        WdWriteLog "WAKE: Device wake update skipped for [$displayName] - $($_.Exception.Message)" "DarkYellow"
    }
    return $changed
}

function WdApplyMagicWakeSettings {
    param([bool]$Enabled)

    if (-not $Enabled) { WdWriteLog "WAKE: Automatic Magic Packet configuration is disabled." "DarkGray"; return }
    if (WdTestMagicWakeSettingMatches) { return }
    if (-not (WdTestIsAdministrator)) { throw "启用网卡魔法唤醒需要管理员权限。" }

    WdSetFastStartupDisabled
    $adapters = @(WdGetPhysicalNetworkAdapters)
    if ($adapters.Count -eq 0) {
        WdWriteLog "WAKE: No physical network adapter with a MAC address was found." "DarkYellow"
        return
    }
    foreach ($adapter in $adapters) {
        $adapterChanged = WdSetAdapterMagicWake -Adapter $adapter -Enabled $true
        $adapterMac = ([string]$adapter.MacAddress).ToUpperInvariant()
        WdWriteLog "WAKE: Adapter [$($adapter.Name)] MAC [$adapterMac] configured=$adapterChanged." $(if ($adapterChanged) { "DarkGreen" } else { "DarkYellow" })
    }
    WdWriteLog "WAKE: Magic Packet enabled for $($adapters.Count) physical adapter(s)." "DarkGreen"
}

function WdSetLockScreenDisabled {
    param([bool]$Disabled)

    if (WdTestLockScreenSettingMatches -Disabled $Disabled) { return }
    if (-not (WdTestIsAdministrator)) {
        throw "修改 Windows 锁屏设置需要管理员权限。"
    }

    $personalizationPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
    $systemPolicyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    $desktopPath = "HKCU:\Control Panel\Desktop"
    $userPolicyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System"

    if ($Disabled) {
        WdSetRegistryDword -Path $personalizationPath -Name "NoLockScreen" -Value 1
        WdSetRegistryDword -Path $systemPolicyPath -Name "InactivityTimeoutSecs" -Value 0
        WdSetRegistryString -Path $desktopPath -Name "ScreenSaveActive" -Value "0"
        WdSetRegistryString -Path $desktopPath -Name "ScreenSaverIsSecure" -Value "0"
        WdSetRegistryDword -Path $userPolicyPath -Name "DisableLockWorkstation" -Value 1
    }
    else {
        WdRemoveRegistryValue -Path $personalizationPath -Name "NoLockScreen"
        WdRemoveRegistryValue -Path $systemPolicyPath -Name "InactivityTimeoutSecs"
        WdRemoveRegistryValue -Path $desktopPath -Name "ScreenSaveActive"
        WdRemoveRegistryValue -Path $desktopPath -Name "ScreenSaverIsSecure"
        WdRemoveRegistryValue -Path $userPolicyPath -Name "DisableLockWorkstation"
    }

    WdInvokePowerConfiguration -DisableLockScreen $Disabled
    if (-not (WdTestLockScreenSettingMatches -Disabled $Disabled)) {
        throw "Windows 锁屏设置更新后校验失败。"
    }
    WdWriteLog "UI: Disable Windows lock screen = $Disabled" "DarkGreen"
}

function WdGetStartupShortcutPath {
    $startupDirectory = [Environment]::GetFolderPath('Startup')
    if ([string]::IsNullOrWhiteSpace($startupDirectory)) {
        throw "无法获取当前用户的 Windows 启动目录。"
    }
    return Join-Path $startupDirectory "Watchdog.lnk"
}

function WdTestStartupEnabled {
    $shell = $null
    $shortcut = $null
    try {
        $shortcutPath = WdGetStartupShortcutPath
        if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
            return $false
        }

        $launcherPath = Join-Path $PSScriptRoot "StartWatchdog.vbs"
        $expectedWscriptPath = Join-Path $env:SystemRoot "System32\wscript.exe"
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        return (
            $shortcut.TargetPath -ieq $expectedWscriptPath -and
            $shortcut.Arguments -eq "`"$launcherPath`" /unattended" -and
            $shortcut.WorkingDirectory -ieq $PSScriptRoot
        )
    }
    catch {
        return $false
    }
    finally {
        if ($shortcut -and [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
        }
        if ($shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

function WdSetStartupEnabled {
    param([bool]$Enabled)

    $shortcutPath = WdGetStartupShortcutPath
    if (-not $Enabled) {
        if (Test-Path -LiteralPath $shortcutPath) {
            Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction Stop
            WdWriteLog "UI: Windows startup shortcut removed." "DarkGreen"
        }
        return
    }

    $launcherPath = Join-Path $PSScriptRoot "StartWatchdog.vbs"
    if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
        throw "未找到启动程序：$launcherPath"
    }
    if (WdTestStartupEnabled) {
        return
    }

    $wscriptPath = Join-Path $env:SystemRoot "System32\wscript.exe"
    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $wscriptPath
        $shortcut.Arguments = "`"$launcherPath`" /unattended"
        $shortcut.WorkingDirectory = $PSScriptRoot
        $shortcut.Description = "Windows Watchdog"
        $shortcut.IconLocation = "$wscriptPath,0"
        $shortcut.WindowStyle = 7
        $shortcut.Save()
    }
    finally {
        if ($shortcut -and [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
        }
        if ($shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }

    if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
        throw "开机自启动快捷方式创建失败。"
    }
    WdWriteLog "UI: Windows startup shortcut points to [$launcherPath]." "DarkGreen"
}

function WdSaveUserConfiguration {
    param(
        [System.Collections.IDictionary]$AppConfigurations,
        [bool]$StartWithWindows = $Script:StartWithWindows,
        [bool]$DisableLockScreen = $Script:DisableLockScreen,
        [bool]$EnableMagicWake = $Script:EnableMagicWake
    )

    if ($null -eq $AppConfigurations) {
        throw "启动程序列表无效。"
    }

    $configurationDirectory = Split-Path $UserConfigPath -Parent
    WdEnsureDirectory -Path $configurationDirectory

    $targets = New-Object System.Collections.ArrayList
    foreach ($targetPath in $AppConfigurations.Keys) {
        $targetConfig = [ordered]@{ Path = (WdGetPortableTargetPath -TargetPath ([string]$targetPath)) }
        $appConfig = WdNewAppConfiguration -Source $AppConfigurations[$targetPath]
        foreach ($key in $appConfig.Keys) {
            $targetConfig[$key] = $appConfig[$key]
        }
        [void]$targets.Add($targetConfig)
    }

    $payload = [ordered]@{
        Version          = 4
        StartWithWindows = $StartWithWindows
        DisableLockScreen = $DisableLockScreen
        EnableMagicWake  = $EnableMagicWake
        Targets          = @($targets)
    }
    $json = $payload | ConvertTo-Json -Depth 8
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($UserConfigPath, $json, $utf8)
}

function WdConvertConfigurationEntriesToApps {
    param($Entries)

    $newApps = [ordered]@{}
    $topmostTargetAssigned = $false
    foreach ($entry in @($Entries)) {
        $targetPath = [string](WdGetConfigValue $entry "Path" "")
        $targetPath = $targetPath.Trim()
        if ([string]::IsNullOrWhiteSpace($targetPath)) {
            throw "启动程序路径不能为空。"
        }

        if ($targetPath -imatch '^https?://') {
            $targetUri = $null
            if (-not [Uri]::TryCreate($targetPath, [UriKind]::Absolute, [ref]$targetUri) -or
                @('http', 'https') -notcontains $targetUri.Scheme.ToLowerInvariant()) {
                throw "网址格式无效：$targetPath"
            }
            $targetPath = $targetUri.AbsoluteUri
        }
        else {
            if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
                throw "程序文件不存在：$targetPath"
            }
            $targetPath = (Get-Item -LiteralPath $targetPath -ErrorAction Stop).FullName
        }

        if ($newApps.Contains($targetPath)) {
            throw "启动程序重复：$targetPath"
        }

        $sourceConfig = WdGetConfigValue $entry "Config" $entry
        $appConfig = WdNewAppConfiguration -Source $sourceConfig
        if ([bool]$appConfig.FocusTop) {
            if ($topmostTargetAssigned) {
                $appConfig.FocusTop = $false
            }
            else {
                $topmostTargetAssigned = $true
            }
        }
        $newApps[$targetPath] = $appConfig
    }

    return $newApps
}

function WdResetMonitoringState {
    foreach ($variableName in @(
            "RestartStats", "LaunchTime", "DisplayRepairDone", "FocusLastTime",
            "LastStartAttempt", "LastStartedProcessId", "ThrottleWarned", "MissingLogged",
            "HangFailCount", "FastExitFailCount", "FastExitHandledLaunch", "ScheduledLaunch",
            "DisplayChangeRestartInProgress", "FullscreenHealth", "DisplayRecoveryLastAttempt", "DisplayRecoveryPending"
        )) {
        $variable = Get-Variable -Name $variableName -Scope Script -ErrorAction SilentlyContinue
        if ($variable -and $variable.Value -and $variable.Value.PSObject.Methods["Clear"]) {
            $variable.Value.Clear()
        }
    }
    Set-Variable -Name FirstRun -Value $true -Scope Script
    $Script:AuthorizationPromptShown = $false
}

function WdApplyAppConfigurations {
    param($Entries, [bool]$StartWithWindows, [bool]$DisableLockScreen, [bool]$EnableMagicWake)

    $newApps = WdConvertConfigurationEntriesToApps -Entries $Entries
    WdSaveUserConfiguration `
        -AppConfigurations $newApps `
        -StartWithWindows $StartWithWindows `
        -DisableLockScreen $DisableLockScreen `
        -EnableMagicWake $EnableMagicWake
    WdSetStartupEnabled -Enabled $StartWithWindows
    WdSetLockScreenDisabled -Disabled $DisableLockScreen
    WdApplyMagicWakeSettings -Enabled $EnableMagicWake
    $script:Apps = $newApps
    $Script:ConfigWasLoaded = $true
    $Script:ConfigLoadError = $null
    $Script:AutoDiscoveredTarget = $false
    $Script:StartWithWindows = $StartWithWindows
    $Script:DisableLockScreen = $DisableLockScreen
    $Script:DisableLockScreenWasConfigured = $true
    $Script:EnableMagicWake = $EnableMagicWake
    WdResetMonitoringState
    WdWriteLog "UI: Saved $($newApps.Count) monitoring target(s)." "DarkGreen"
}

function WdRequestElevatedRestart {
    if (WdTestIsAdministrator) {
        WdSetAuthorizationControlsVisible -Visible $false
        [System.Windows.Forms.MessageBox]::Show(
            "当前已经是管理员权限运行。", "守护进程",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return $false
    }

    try {
        $powershellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        $arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -ElevatedRelaunch"
        Start-Process -FilePath $powershellPath -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -ErrorAction Stop | Out-Null
        WdWriteLog "UI: User approved UAC; elevated Watchdog restart requested." "DarkGreen"
        WdSetAuthorizationControlsVisible -Visible $false
        WdRequestExit -Reason "elevated restart"
        return $true
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "未能获得管理员授权。请在系统提示中确认后重试。$([Environment]::NewLine)$($_.Exception.Message)",
            "需要授权",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        WdWriteLog "UI: Elevated restart was cancelled or failed - $($_.Exception.Message)" "DarkYellow"
        return $false
    }
}

function WdOfferAuthorizationForError {
    param([System.Exception]$Exception, [string]$Operation)

    if (-not $Script:UserInteractionActive) {
        WdWriteLog "UI: Administrator authorization deferred because no user action is active ($Operation)." "DarkYellow"
        return
    }
    if ($Script:AuthorizationPromptShown -or $Script:ExitRequested -or (WdTestIsAdministrator)) {
        return
    }

    $isAuthorizationError = $false
    $currentException = $Exception
    while ($currentException) {
        if ($currentException -is [System.ComponentModel.Win32Exception] -and
            (@(5, 740) -contains $currentException.NativeErrorCode)) {
            $isAuthorizationError = $true
            break
        }
        if ($currentException.Message -match "access.*denied|拒绝访问|需要提升|elevation|管理员权限") {
            $isAuthorizationError = $true
            break
        }
        $currentException = $currentException.InnerException
    }
    if (-not $isAuthorizationError) { return }

    $Script:AuthorizationPromptShown = $true
    WdWriteLog "UI: User action requires administrator authorization ($Operation)." "DarkYellow"
    [void](WdRequestElevatedRestart)
}

function WdInitializeSettingsControls {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if (([Management.Automation.PSTypeName]'WatchdogUI.CompactButton').Type) { return }
    $settingsControlsCode = @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace WatchdogUI
{
    internal static class PaintKit
    {
        internal static readonly Color Ink = Color.FromArgb(32, 39, 54);
        internal static readonly Color Muted = Color.FromArgb(113, 122, 139);
        internal static readonly Color Accent = Color.FromArgb(78, 91, 235);
        internal static readonly Color Border = Color.FromArgb(224, 228, 236);
        internal static GraphicsPath Round(Rectangle r, int radius)
        {
            int d = Math.Max(2, Math.Min(radius * 2, Math.Min(r.Width, r.Height)));
            GraphicsPath p = new GraphicsPath();
            p.AddArc(r.Left, r.Top, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Top, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure(); return p;
        }
        internal static void Box(Graphics g, Rectangle r, int radius, Color fill, Color stroke)
        {
            if (r.Width < 2 || r.Height < 2) return;
            using (GraphicsPath p = Round(r, radius))
            using (Brush b = new SolidBrush(fill))
            { g.FillPath(b, p); if (stroke != Color.Empty) using (Pen pen = new Pen(stroke)) g.DrawPath(pen, p); }
        }
    }

    public sealed class CompactButton : Button
    {
        private bool hover;
        public CompactButton() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true); }
        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(Parent == null ? SystemColors.Control : Parent.BackColor);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Color fill = Enabled ? (hover ? FlatAppearance.MouseOverBackColor : BackColor) : Color.FromArgb(241, 243, 247);
            PaintKit.Box(e.Graphics, new Rectangle(0, 0, Width - 1, Height - 1), Math.Max(4, DeviceDpi / 16), fill, Color.Empty);
            TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, Enabled ? ForeColor : PaintKit.Muted,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
            if (Focused && ShowFocusCues)
                using (GraphicsPath p = PaintKit.Round(Rectangle.Inflate(ClientRectangle, -3, -3), 4))
                using (Pen pen = new Pen(PaintKit.Accent)) e.Graphics.DrawPath(pen, p);
        }
    }

    public sealed class Toggle : CheckBox
    {
        public Toggle() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true); Cursor = Cursors.Hand; }
        public override Size GetPreferredSize(Size proposedSize)
        { return new Size(Math.Max(MinimumSize.Width, TextRenderer.MeasureText(Text, Font).Width + 50 * DeviceDpi / 96), Math.Max(MinimumSize.Height, 30 * DeviceDpi / 96)); }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(Parent == null ? BackColor : Parent.BackColor);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            int s = Math.Max(16, 18 * DeviceDpi / 96), w = s * 2 - 4;
            Rectangle track = new Rectangle(Width - w - 2, (Height - s) / 2, w, s);
            Color color = !Enabled ? Color.FromArgb(230, 233, 239) : Checked ? PaintKit.Accent : Color.FromArgb(197, 204, 217);
            PaintKit.Box(e.Graphics, track, s / 2, color, Color.Empty);
            int knob = s - 6, x = Checked ? track.Right - knob - 3 : track.Left + 3;
            using (Brush b = new SolidBrush(Color.White)) e.Graphics.FillEllipse(b, x, track.Top + 3, knob, knob);
            TextRenderer.DrawText(e.Graphics, Text, Font, new Rectangle(0, 0, Math.Max(0, track.Left - 10), Height),
                Enabled ? PaintKit.Ink : PaintKit.Muted, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
            if (Focused && ShowFocusCues)
                using (GraphicsPath p = PaintKit.Round(Rectangle.Inflate(ClientRectangle, -1, -1), 4))
                using (Pen pen = new Pen(PaintKit.Border)) e.Graphics.DrawPath(pen, p);
        }
        protected override void OnCheckedChanged(EventArgs e) { Invalidate(); base.OnCheckedChanged(e); }
    }

    public class Field : UserControl
    {
        protected Control Input;
        protected int SuffixWidth;
        public Field() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true); Height = 34; MinimumSize = new Size(40, 32); BackColor = Color.White; }
        protected void Attach(Control input)
        {
            Input = input; Controls.Add(input);
            input.Enter += delegate { Invalidate(); }; input.Leave += delegate { Invalidate(); };
            TabStop = false; PerformLayout();
        }
        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            if (Input != null) { int gap = 10 * DeviceDpi / 96; Input.SetBounds(gap, Math.Max(2, (Height - Input.PreferredSize.Height) / 2), Math.Max(10, Width - gap * 2 - SuffixWidth), Input.PreferredSize.Height); }
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(Parent == null ? SystemColors.Control : Parent.BackColor);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            PaintKit.Box(e.Graphics, new Rectangle(0, 0, Width - 1, Height - 1), Math.Max(4, DeviceDpi / 16), BackColor, ContainsFocus ? PaintKit.Accent : PaintKit.Border);
            if (SuffixWidth > 0) TextRenderer.DrawText(e.Graphics, "s", Font, new Rectangle(Width - SuffixWidth - 8, 0, SuffixWidth, Height), PaintKit.Muted, TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter);
        }
    }
    public sealed class TextField : Field
    {
        private TextBox editor;
        public TextField()
        {
            editor = new TextBox(); editor.BorderStyle = BorderStyle.None; editor.BackColor = Color.White;
            editor.TextChanged += delegate { OnTextChanged(EventArgs.Empty); }; Attach(editor);
        }
        public override string Text { get { return editor == null ? base.Text : editor.Text; } set { if (editor == null) base.Text = value; else editor.Text = value; } }
    }
    internal sealed class QuietNumber : NumericUpDown
    {
        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            foreach (Control child in Controls) { if (child is TextBox) child.SetBounds(0, 0, Width, Height); else child.Visible = false; }
        }
    }
    public sealed class NumberField : Field
    {
        private QuietNumber editor;
        public NumberField()
        { editor = new QuietNumber(); editor.BorderStyle = BorderStyle.None; editor.BackColor = Color.White; SuffixWidth = 16; Attach(editor); }
        public decimal Value { get { return editor.Value; } set { editor.Value = value; } }
        public decimal Minimum { get { return editor.Minimum; } set { editor.Minimum = value; } }
        public decimal Maximum { get { return editor.Maximum; } set { editor.Maximum = value; } }
    }

    public sealed class ProgramList : ListView
    {
        public ProgramList() { OwnerDraw = true; HeaderStyle = ColumnHeaderStyle.None; DoubleBuffered = true; }
        protected override void OnDrawColumnHeader(DrawListViewColumnHeaderEventArgs e) { }
        protected override void OnDrawSubItem(DrawListViewSubItemEventArgs e) { }
        protected override void OnDrawItem(DrawListViewItemEventArgs e)
        {
            Graphics g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
            float scale = DeviceDpi / 96f;
            // Paint only inside the invalidated item. Clear old rounded edges before changing selection.
            Rectangle item = new Rectangle(e.Bounds.Left, e.Bounds.Top, Math.Min(e.Bounds.Width, ClientSize.Width), e.Bounds.Height);
            using (Brush background = new SolidBrush(BackColor)) g.FillRectangle(background, item);
            Rectangle row = new Rectangle(item.Left + 1, item.Top + 2, Math.Max(1, item.Width - 3), item.Height - 4);
            Color fill = e.Item.Selected ? Color.FromArgb(235, 237, 255) : BackColor;
            PaintKit.Box(g, row, (int)(7 * scale), fill, e.Item.Selected ? Color.FromArgb(215, 220, 255) : Color.Empty);
            int iconSize = (int)(30 * scale), gap = (int)(10 * scale);
            Rectangle icon = new Rectangle(row.Left + gap, row.Top + (row.Height - iconSize) / 2, iconSize, iconSize);
            PaintKit.Box(g, icon, (int)(7 * scale), e.Item.Selected ? PaintKit.Accent : Color.FromArgb(226, 230, 239), Color.Empty);
            TextRenderer.DrawText(g, ">_", Font, icon, e.Item.Selected ? Color.White : PaintKit.Muted, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            int left = icon.Right + gap, width = Math.Max(1, row.Right - left - gap);
            string status = e.Item.SubItems.Count > 2 ? e.Item.SubItems[2].Text : "";
            if (status != "待修复" && e.Item.SubItems.Count > 3 && !String.IsNullOrEmpty(e.Item.SubItems[3].Text)) status = "置顶";
            int statusWidth = String.IsNullOrEmpty(status) ? 0 : (int)(46 * scale);
            Rectangle name = new Rectangle(left, row.Top + (int)(7 * scale), width, (int)(21 * scale));
            TextRenderer.DrawText(g, e.Item.Text, Font, name, PaintKit.Ink, TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            if (statusWidth > 0)
            {
                Rectangle badge = new Rectangle(row.Right - gap - statusWidth, name.Bottom, statusWidth, (int)(18 * scale));
                using (Font small = new Font(Font.FontFamily, Math.Max(7, Font.Size - 1)))
                    TextRenderer.DrawText(g, status, small, badge, status == "待修复" ? Color.FromArgb(178, 104, 22) : PaintKit.Muted, TextFormatFlags.Right | TextFormatFlags.VerticalCenter);
            }
            if (e.Item.SubItems.Count > 1)
            {
                Rectangle path = new Rectangle(left, name.Bottom, Math.Max(1, width - statusWidth), (int)(18 * scale));
                using (Font small = new Font(Font.FontFamily, Math.Max(7, Font.Size - 1)))
                    TextRenderer.DrawText(g, e.Item.SubItems[1].Text, small, path, PaintKit.Muted, TextFormatFlags.SingleLine | TextFormatFlags.PathEllipsis);
            }
        }
        protected override void OnSelectedIndexChanged(EventArgs e) { base.OnSelectedIndexChanged(e); Invalidate(); }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }
        protected override bool ShowFocusCues { get { return false; } }
    }

    public sealed class NetworkList : ListView
    {
        public NetworkList() { OwnerDraw = true; DoubleBuffered = true; }
        protected override void OnDrawColumnHeader(DrawListViewColumnHeaderEventArgs e)
        {
            e.Graphics.FillRectangle(SystemBrushes.Window, e.Bounds);
            TextRenderer.DrawText(e.Graphics, e.Header.Text, Font, Rectangle.Inflate(e.Bounds, -8, 0), PaintKit.Muted, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
            using (Pen p = new Pen(PaintKit.Border)) e.Graphics.DrawLine(p, e.Bounds.Left, e.Bounds.Bottom - 1, e.Bounds.Right, e.Bounds.Bottom - 1);
        }
        protected override void OnDrawItem(DrawListViewItemEventArgs e) { }
        protected override void OnDrawSubItem(DrawListViewSubItemEventArgs e)
        {
            using (Brush b = new SolidBrush(e.Item.Selected ? Color.FromArgb(235, 237, 255) : Color.White)) e.Graphics.FillRectangle(b, e.Bounds);
            TextRenderer.DrawText(e.Graphics, e.SubItem.Text, Font, Rectangle.Inflate(e.Bounds, -8, 0), PaintKit.Ink, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        }
    }
}
"@
    $settingsReferences = @(
        [Windows.Forms.Button].Assembly.Location, [Windows.Forms.Message].Assembly.Location,
        [Drawing.Graphics].Assembly.Location, [Drawing.Color].Assembly.Location,
        [ComponentModel.Component].Assembly.Location
        [Drawing.Graphics].GetInterfaces() | ForEach-Object { $_.Assembly.Location }
    ) | Select-Object -Unique
    Add-Type -TypeDefinition $settingsControlsCode -Language CSharp -ReferencedAssemblies $settingsReferences -ErrorAction Stop
}

function WdNewSettingsView {
    param([switch]$FirstRun)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    WdInitializeSettingsControls
    $ui = @{}
    $ink = [Drawing.ColorTranslator]::FromHtml('#202736')
    $muted = [Drawing.ColorTranslator]::FromHtml('#717A8B')
    $accent = [Drawing.ColorTranslator]::FromHtml('#4E5BEB')
    $border = [Drawing.ColorTranslator]::FromHtml('#DCE3ED')
    $canvas = [Drawing.ColorTranslator]::FromHtml('#F6F7FB')
    $form = New-Object Windows.Forms.Form
    $ui.Form = $form
    $form.Text = if ($FirstRun) { '看门狗 · 首次设置' } else { '看门狗 · 设置' }
    $form.StartPosition = 'CenterScreen'
    $form.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
    $form.AutoScaleMode = 'Dpi'
    $form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9.5)
    $ownedFonts = New-Object System.Collections.ArrayList
    [void]$ownedFonts.Add($form.Font)
    $form.ForeColor = $ink
    $form.BackColor = $canvas
    $form.FormBorderStyle = 'Sizable'
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $area = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
    $tallLayout = $area.Height -gt $area.Width
    $form.MinimumSize = New-Object Drawing.Size(($(if ($tallLayout) { 720 } else { 960 })), ($(if ($tallLayout) { 1280 } else { 640 })))
    $form.ClientSize = New-Object Drawing.Size(($(if ($tallLayout) { [Math]::Min(900, $area.Width - 32) } else { [Math]::Min(1120, $area.Width - 32) })), ($(if ($tallLayout) { [Math]::Min(1280, $area.Height - 64) } else { [Math]::Min(660, $area.Height - 64) })))
    $form.SuspendLayout()

    $newLabel = {
        param([string]$Text, [single]$Size = 9.5, [bool]$Bold = $false)
        $control = New-Object Windows.Forms.Label
        $control.Text = $Text
        $control.AutoSize = $true
        $control.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 3)
        $style = if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
        $control.Font = New-Object Drawing.Font('Microsoft YaHei UI', $Size, $style)
        [void]$ownedFonts.Add($control.Font)
        return $control
    }
    $newButton = {
        param([string]$Text, [bool]$Primary = $false)
        $control = New-Object WatchdogUI.CompactButton
        $control.Text = $Text
        $control.AutoSize = $true
        $control.AutoSizeMode = 'GrowAndShrink'
        $control.MinimumSize = New-Object Drawing.Size(68, 30)
        $control.Padding = New-Object Windows.Forms.Padding(9, 2, 9, 2)
        $control.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 0)
        $control.FlatStyle = 'Flat'
        $control.FlatAppearance.BorderSize = if ($Primary) { 0 } else { 1 }
        $control.FlatAppearance.BorderColor = $border
        $control.BackColor = if ($Primary) { $accent } else { [Drawing.Color]::White }
        $control.ForeColor = if ($Primary) { [Drawing.Color]::White } else { $ink }
        $control.FlatAppearance.MouseOverBackColor = if ($Primary) { [Drawing.Color]::FromArgb(29, 78, 216) } else { [Drawing.Color]::FromArgb(239, 244, 252) }
        $control.Cursor = [Windows.Forms.Cursors]::Hand
        return $control
    }
    $newStack = {
        $control = New-Object Windows.Forms.TableLayoutPanel
        $control.ColumnCount = 1
        $control.RowCount = 0
        $control.AutoSize = $true
        $control.AutoSizeMode = 'GrowAndShrink'
        $control.Dock = 'Top'
        $control.Margin = New-Object Windows.Forms.Padding(0)
        [void]$control.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
        return $control
    }
    $append = {
        param($Parent, $Child)
        $row = $Parent.RowCount
        $Parent.RowCount++
        [void]$Parent.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
        [void]$Parent.Controls.Add($Child, 0, $row)
    }
    $newFlow = {
        $control = New-Object Windows.Forms.FlowLayoutPanel
        $control.AutoSize = $true
        $control.AutoSizeMode = 'GrowAndShrink'
        $control.Dock = 'Top'
        $control.WrapContents = $true
        $control.Margin = New-Object Windows.Forms.Padding(0)
        return $control
    }

    $root = New-Object Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'
    $root.Padding = New-Object Windows.Forms.Padding(12, 8, 12, 8)
    $root.ColumnCount = 1; $root.RowCount = 3
    [void]$root.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    [void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
    [void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    [void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
    [void]$form.Controls.Add($root)
    $header = & $newFlow
    $header.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 8)
    $brand = & $newLabel '看门狗' 14 $true
    $brand.Margin = New-Object Windows.Forms.Padding(0, 0, 12, 0)
    [void]$header.Controls.Add($brand)
    $subtitle = & $newLabel '程序守护 / 设置'
    $subtitle.Margin = New-Object Windows.Forms.Padding(0, 5, 0, 0)
    $subtitle.ForeColor = $muted
    [void]$header.Controls.Add($subtitle)
    [void]$root.Controls.Add($header, 0, 0)

    $body = New-Object Windows.Forms.TableLayoutPanel
    $body.Dock = 'Fill'; $body.Margin = New-Object Windows.Forms.Padding(0)
    $body.ColumnCount = 2; $body.RowCount = 1
    [void]$body.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 34)))
    [void]$body.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 66)))
    [void]$body.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    [void]$root.Controls.Add($body, 0, 1)
    $ui.Body = $body

    $library = New-Object Windows.Forms.TableLayoutPanel
    $library.BackColor = $canvas
    $library.Padding = New-Object Windows.Forms.Padding(10)
    $library.Dock = 'Fill'; $library.ColumnCount = 1; $library.RowCount = 4
    $library.Margin = New-Object Windows.Forms.Padding(0, 0, 12, 0)
    [void]$library.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    foreach ($rowType in @('AutoSize', 'AutoSize', 'Percent', 'AutoSize')) {
        [void]$library.RowStyles.Add((New-Object Windows.Forms.RowStyle($rowType, 100)))
    }
    $libraryHeading = & $newFlow
    $libraryTitle = & $newLabel '启动程序' 10 $true
    $libraryTitle.Margin = New-Object Windows.Forms.Padding(0, 5, 24, 4)
    [void]$libraryHeading.Controls.Add($libraryTitle)
    $ui.Add = & $newButton '+ 添加' $false
    [void]$libraryHeading.Controls.Add($ui.Add)
    [void]$library.Controls.Add($libraryHeading, 0, 0)
    $ui.ListHint = & $newLabel '选择程序编辑 · 支持拖入 EXE' 8.5
    $ui.ListHint.ForeColor = $muted
    [void]$library.Controls.Add($ui.ListHint, 0, 1)
    $listHost = New-Object Windows.Forms.Panel
    $listHost.Dock = 'Fill'; $listHost.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 6)
    $list = New-Object WatchdogUI.ProgramList
    $list.BackColor = $canvas
    $list.Dock = 'Fill'; $list.View = 'Details'; $list.BorderStyle = 'None'
    $list.FullRowSelect = $true; $list.HideSelection = $false
    $list.MultiSelect = $false; $list.AllowDrop = $true; $list.ShowItemToolTips = $true
    foreach ($column in @('程序', '路径', '状态', '置顶')) { [void]$list.Columns.Add($column) }
    $rowImages = New-Object Windows.Forms.ImageList
    $rowImages.ImageSize = New-Object Drawing.Size(1, 58)
    $list.SmallImageList = $rowImages
    [void]$listHost.Controls.Add($list)
    $ui.EmptyList = & $newLabel "还没有启动程序`r`n`r`n点击「+ 添加」开始设置。"
    $ui.EmptyList.AutoSize = $false; $ui.EmptyList.Dock = 'Fill'
    $ui.EmptyList.TextAlign = 'MiddleCenter'; $ui.EmptyList.ForeColor = $muted
    $ui.EmptyList.Enabled = $false # Allow drops to reach the underlying program list.
    [void]$list.Controls.Add($ui.EmptyList)
    $ui.EmptyList.BringToFront()
    [void]$library.Controls.Add($listHost, 0, 2)
    $libraryActions = & $newFlow
    $ui.Remove = & $newButton '移除程序'
    [void]$libraryActions.Controls.Add($ui.Remove)
    [void]$library.Controls.Add($libraryActions, 0, 3)
    $ui.List = $list
    [void]$body.Controls.Add($library, 0, 0)

    $right = New-Object Windows.Forms.TableLayoutPanel
    $right.Dock = 'Fill'; $right.BackColor = [Drawing.Color]::White
    $right.Margin = New-Object Windows.Forms.Padding(0)
    $right.Padding = New-Object Windows.Forms.Padding(12, 8, 12, 8)
    $right.ColumnCount = 1; $right.RowCount = 1
    [void]$right.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    [void]$right.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    $pageHost = New-Object Windows.Forms.TableLayoutPanel
    $pageHost.Dock = 'Fill'; $pageHost.Margin = New-Object Windows.Forms.Padding(0)
    $pageHost.ColumnCount = 2; $pageHost.RowCount = 1
    [void]$right.Controls.Add($pageHost, 0, 0)
    [void]$body.Controls.Add($right, 1, 0)
    foreach ($pageName in @('ProgramPage', 'HostPage')) {
        $page = New-Object Windows.Forms.Panel
        $page.Dock = 'Fill'; $page.AutoScroll = $false
        $page.Margin = New-Object Windows.Forms.Padding(0)
        [void]$pageHost.Controls.Add($page)
        $ui[$pageName] = $page
    }
    $program = & $newStack
    $program.Padding = New-Object Windows.Forms.Padding(0, 0, 8, 0)
    [void]$ui.ProgramPage.Controls.Add($program)
    & $append $program (& $newLabel '程序配置' 12 $true)
    & $append $program (& $newLabel '启动方式' 10 $true)
    & $append $program (& $newLabel '程序路径或网址')
    $pathRow = New-Object Windows.Forms.TableLayoutPanel
    $pathRow.Dock = 'Top'; $pathRow.AutoSize = $true; $pathRow.ColumnCount = 2; $pathRow.RowCount = 1
    $pathRow.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 5)
    [void]$pathRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    [void]$pathRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
    $ui.PathBox = New-Object WatchdogUI.TextField
    $ui.PathBox.Dock = 'Fill'; $ui.PathBox.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 0)
    $ui.Browse = & $newButton '浏览…'
    $ui.Browse.Margin = New-Object Windows.Forms.Padding(0)
    [void]$pathRow.Controls.Add($ui.PathBox, 0, 0); [void]$pathRow.Controls.Add($ui.Browse, 1, 0)
    & $append $program $pathRow
    & $append $program (& $newLabel '启动参数')
    $ui.ArgsBox = New-Object WatchdogUI.TextField
    $ui.ArgsBox.Dock = 'Top'; $ui.ArgsBox.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 5)
    & $append $program $ui.ArgsBox
    $timing = & $newFlow
    foreach ($field in @(@('FirstBox', '首次启动延迟'), @('RestartBox', '异常重启延迟'), @('MinBox', '最短运行时间'))) {
        $group = & $newStack
        $group.Dock = 'None'; $group.Margin = New-Object Windows.Forms.Padding(0, 0, 10, 4)
        & $append $group (& $newLabel $field[1])
        $number = New-Object WatchdogUI.NumberField
        $number.Minimum = 0; $number.Maximum = 86400; $number.Width = 108
        $number.Margin = New-Object Windows.Forms.Padding(0)
        $ui[$field[0]] = $number
        & $append $group $number
        [void]$timing.Controls.Add($group)
    }
    & $append $program $timing
    $ui.CheckBoxes = @{}
    $optionGroups = @(
        @{ Title = '显示与恢复'; Options = @(
            @('Fullscreen', '全屏模式'), @('ForceDisplayMode', '强制显示模式'),
            @('FocusTop', '窗口置顶（全局单选）'), @('HideCursor', '隐藏鼠标光标'),
            @('RestartOnDisplayChange', '显示器变化时重启'), @('UnityDisplayRecovery', 'Unity 全屏异常恢复')) },
        @{ Title = '运行策略'; Options = @(
            @('HideWindow', '隐藏窗口启动'), @('Once', '仅启动一次'),
            @('KillTreeOnHang', '异常时结束进程树'), @('AllowMultiInstance', '允许多实例')) }
    )
    $optionFlows = @()
    foreach ($group in $optionGroups) {
        $label = & $newLabel $group.Title 10 $true
        $label.Margin = New-Object Windows.Forms.Padding(0, 6, 0, 2)
        & $append $program $label
        $flow = & $newFlow
        foreach ($option in $group.Options) {
            $check = New-Object WatchdogUI.Toggle
            $check.Text = $option[1]; $check.AutoSize = $false
            $check.Margin = New-Object Windows.Forms.Padding(0, 0, 12, 0)
            [void]$flow.Controls.Add($check)
            $ui.CheckBoxes[$option[0]] = $check
        }
        & $append $program $flow
        $optionFlows += $flow
        if ($group.Title -eq '显示与恢复') {
            $ui.RecoveryHint = & $newLabel '开启「显示器变化时重启」后，Unity 持续未全屏也会直接重启；否则先尝试恢复全屏。'
            $ui.RecoveryHint.ForeColor = $muted
            $ui.RecoveryHint.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 0)
            & $append $program $ui.RecoveryHint
        }
    }

    $hostContent = & $newStack
    $hostContent.Padding = New-Object Windows.Forms.Padding(0, 0, 12, 8)
    [void]$ui.HostPage.Controls.Add($hostContent)
    & $append $hostContent (& $newLabel '主机设置' 12 $true)
    & $append $hostContent (& $newLabel '无人值守' 10 $true)
    foreach ($option in @(@('AutoStart', '随 Windows 自动启动', $Script:StartWithWindows),
            @('DisableLockScreen', '禁用 Windows 锁屏', $Script:DisableLockScreen),
            @('MagicWake', '允许魔法唤醒', $Script:EnableMagicWake))) {
        $check = New-Object WatchdogUI.Toggle
        $check.Text = $option[1]; $check.AutoSize = $true; $check.Checked = [bool]$option[2]
        $check.Dock = 'Top'
        $check.Margin = New-Object Windows.Forms.Padding(0, 2, 0, 2)
        $ui[$option[0]] = $check
        & $append $hostContent $check
    }
    $ui.WakeHint = & $newLabel '魔法唤醒会配置网卡与设备唤醒，并关闭 Windows 快速启动。'
    $ui.WakeHint.ForeColor = $muted
    & $append $hostContent $ui.WakeHint
    $networkLabel = & $newLabel '物理网卡' 10 $true
    $networkLabel.Margin = New-Object Windows.Forms.Padding(0, 12, 0, 6)
    & $append $hostContent $networkLabel
    $ui.AdapterList = New-Object WatchdogUI.NetworkList
    $ui.AdapterList.View = 'Details'; $ui.AdapterList.FullRowSelect = $true
    $ui.AdapterList.HideSelection = $false; $ui.AdapterList.MultiSelect = $false
    $ui.AdapterList.BorderStyle = 'None'; $ui.AdapterList.Dock = 'Top'
    $ui.AdapterList.Height = 64
    $ui.AdapterList.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 8)
    [void]$ui.AdapterList.Columns.Add('网卡'); [void]$ui.AdapterList.Columns.Add('物理 MAC 地址')
    & $append $hostContent $ui.AdapterList
    $ui.CopyMac = & $newButton '复制 MAC 地址'
    & $append $hostContent $ui.CopyMac

    $footer = New-Object Windows.Forms.TableLayoutPanel
    $footer.AutoSize = $true; $footer.Dock = 'Fill'
    $footer.ColumnCount = 2; $footer.RowCount = 1
    $footer.Margin = New-Object Windows.Forms.Padding(0, 6, 0, 0)
    [void]$footer.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    [void]$footer.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
    $ui.Status = & $newLabel '保存后立即生效' 8.5
    $ui.Status.ForeColor = $muted
    $ui.Status.Anchor = 'Left'
    [void]$footer.Controls.Add($ui.Status, 0, 0)
    $actions = & $newFlow
    $actions.FlowDirection = 'RightToLeft'
    $actions.WrapContents = $false
    $actions.Dock = 'None'
    $ui.Save = & $newButton '保存配置' $true
    $ui.Cancel = & $newButton $(if ($FirstRun) { '退出设置' } else { '取消' })
    $ui.Cancel.DialogResult = 'Cancel'
    [void]$actions.Controls.Add($ui.Save); [void]$actions.Controls.Add($ui.Cancel)
    [void]$footer.Controls.Add($actions, 1, 0)
    [void]$root.Controls.Add($footer, 0, 2)

    $ui.ProgramContent = $program
    $ui.HostContent = $hostContent
    $ui.PageHost = $pageHost

    $layoutState = @{ Compact = $null; Busy = $false }
    $adaptLayout = {
        if ($layoutState.Busy -or $form.IsDisposed) { return }
        $layoutState.Busy = $true
        try {
            $scale = $form.DeviceDpi / 96.0
            $compact = $tallLayout
            if ($layoutState.Compact -ne $compact) {
                $body.SuspendLayout()
                $body.ColumnStyles.Clear(); $body.RowStyles.Clear()
                $pageHost.ColumnStyles.Clear(); $pageHost.RowStyles.Clear()
                if ($compact) {
                    $body.ColumnCount = 1; $body.RowCount = 2
                    $body.SetCellPosition($right, (New-Object Windows.Forms.TableLayoutPanelCellPosition(0, 1)))
                    [void]$body.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
                    [void]$body.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', (210 * $scale))))
                    [void]$body.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
                    $library.Margin = New-Object Windows.Forms.Padding(0, 0, 0, (12 * $scale))
                    $pageHost.ColumnCount = 1; $pageHost.RowCount = 2
                    $pageHost.SetCellPosition($ui.ProgramPage, (New-Object Windows.Forms.TableLayoutPanelCellPosition(0, 0)))
                    $pageHost.SetCellPosition($ui.HostPage, (New-Object Windows.Forms.TableLayoutPanelCellPosition(0, 1)))
                    [void]$pageHost.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
                    [void]$pageHost.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', (520 * $scale))))
                    [void]$pageHost.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
                    $ui.HostPage.Margin = New-Object Windows.Forms.Padding(0, (12 * $scale), 0, 0)
                }
                else {
                    $body.ColumnCount = 2; $body.RowCount = 1
                    $body.SetCellPosition($right, (New-Object Windows.Forms.TableLayoutPanelCellPosition(1, 0)))
                    [void]$body.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', (220 * $scale))))
                    [void]$body.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
                    [void]$body.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
                    $library.Margin = New-Object Windows.Forms.Padding(0, 0, (12 * $scale), 0)
                    $pageHost.ColumnCount = 2; $pageHost.RowCount = 1
                    $pageHost.SetCellPosition($ui.ProgramPage, (New-Object Windows.Forms.TableLayoutPanelCellPosition(0, 0)))
                    $pageHost.SetCellPosition($ui.HostPage, (New-Object Windows.Forms.TableLayoutPanelCellPosition(1, 0)))
                    [void]$pageHost.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 60)))
                    [void]$pageHost.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 40)))
                    [void]$pageHost.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
                    $ui.HostPage.Margin = New-Object Windows.Forms.Padding((12 * $scale), 0, 0, 0)
                }
                $layoutState.Compact = $compact
                $body.ResumeLayout($true)
            }
            $ui.ListHint.Visible = -not $compact
            if ($compact) { $body.RowStyles[0].Height = 244 * $scale }
            foreach ($flow in $optionFlows) {
                # Child flow bounds can still reflect the previous size during a parent resize.
                $flowWidth = $ui.ProgramPage.ClientSize.Width - $program.Padding.Horizontal
                $columns = if ($flowWidth -ge 340 * $scale) { 2 } else { 1 }
                $optionWidth = [Math]::Max(120, [int][Math]::Floor($flowWidth / $columns) - [int](12 * $scale))
                foreach ($check in $flow.Controls) {
                    $check.Size = New-Object Drawing.Size($optionWidth, (28 * $scale))
                }
                $flow.AutoSize = $false
                $flow.Height = [int][Math]::Ceiling($flow.Controls.Count / [double]$columns) * (28 * $scale)
                $flow.PerformLayout()
            }
            $listWidth = [Math]::Max(1, $list.ClientSize.Width - 1)
            $list.Columns[0].Width = [int]$listWidth
            $list.Columns[1].Width = 0
            $list.Columns[2].Width = 0
            $list.Columns[3].Width = 0
            $adapterWidth = [Math]::Max(180, $ui.AdapterList.ClientSize.Width - (22 * $scale))
            $ui.AdapterList.Columns[0].Width = [int]($adapterWidth * 0.46)
            $ui.AdapterList.Columns[1].Width = [int]($adapterWidth * 0.54)
            foreach ($pair in @(@($ui.RecoveryHint, $ui.ProgramPage), @($ui.WakeHint, $ui.HostPage), @($ui.Status, $footer), @($ui.ListHint, $library))) {
                $wrapWidth = if ($pair[0] -eq $ui.Status) {
                    [Math]::Max(100, $footer.ClientSize.Width - $actions.Width - 20 * $scale)
                } else { [Math]::Max(100, $pair[1].ClientSize.Width - 48 * $scale) }
                $pair[0].AutoSize = $false
                $pair[0].MaximumSize = New-Object Drawing.Size($wrapWidth, 0)
                $textSize = [Windows.Forms.TextRenderer]::MeasureText($pair[0].Text, $pair[0].Font,
                    (New-Object Drawing.Size($wrapWidth, 32767)), [Windows.Forms.TextFormatFlags]::WordBreak)
                $pair[0].Size = New-Object Drawing.Size($wrapWidth, $textSize.Height)
            }
            if ($compact) { $pageHost.RowStyles[0].Height = [Math]::Max(520 * $scale, $program.Height + 2 * $scale) }
        }
        finally { $layoutState.Busy = $false }
    }.GetNewClosure()
    $body.Add_SizeChanged($adaptLayout)
    $list.Add_SizeChanged($adaptLayout)
    $ui.AdapterList.Add_SizeChanged($adaptLayout)
    $ui.ProgramPage.Add_SizeChanged($adaptLayout)
    $ui.HostPage.Add_VisibleChanged($adaptLayout)
    $ui.Status.Add_TextChanged($adaptLayout)
    foreach ($flow in $optionFlows) { $flow.Add_SizeChanged($adaptLayout) }
    $form.Add_Shown({
        $screenArea = [Windows.Forms.Screen]::FromControl($form).WorkingArea
        $form.MinimumSize = New-Object Drawing.Size(([Math]::Min($form.MinimumSize.Width, $screenArea.Width)), ([Math]::Min($form.MinimumSize.Height, $screenArea.Height)))
        $form.Size = New-Object Drawing.Size(([Math]::Min($form.Width, $screenArea.Width)), ([Math]::Min($form.Height, $screenArea.Height)))
        if ($form.StartPosition -ne [Windows.Forms.FormStartPosition]::Manual) {
            $form.Location = New-Object Drawing.Point(($screenArea.Left + [int](($screenArea.Width - $form.Width) / 2)), ($screenArea.Top + [int](($screenArea.Height - $form.Height) / 2)))
        }
        & $adaptLayout
    }.GetNewClosure())
    $form.Add_Disposed({
        $rowImages.Dispose()
        foreach ($ownedFont in $ownedFonts) { $ownedFont.Dispose() }
    }.GetNewClosure())
    $form.ResumeLayout($true)
    & $adaptLayout
    return $ui
}

function WdShowSettingsWindow {
    param([switch]$FirstRun)

    if ($Script:SettingsWindowOpen) {
        try {
            $Script:SettingsForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            $Script:SettingsForm.Activate()
        }
        catch {}
        return $false
    }

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $previousUserInteraction = $Script:UserInteractionActive
    $Script:UserInteractionActive = $true
    $Script:AuthorizationPromptShown = $false

    $view = WdNewSettingsView -FirstRun:$FirstRun
    $form = $view.Form
    $Script:SettingsWindowOpen = $true
    $Script:SettingsForm = $form
    $entries = New-Object System.Collections.ArrayList
    foreach ($appPath in $Apps.Keys) {
        [void]$entries.Add([pscustomobject]@{
            Path   = [string]$appPath
            Config = WdNewAppConfiguration -Source $Apps[$appPath]
        })
    }
    $state = [pscustomobject]@{ SelectedIndex = -1; Loading = $false }

    $list = $view.List
    $add = $view.Add
    $remove = $view.Remove
    $pathBox = $view.PathBox
    $browse = $view.Browse
    $argsBox = $view.ArgsBox
    $firstBox = $view.FirstBox
    $restartBox = $view.RestartBox
    $minBox = $view.MinBox
    $checkBoxes = $view.CheckBoxes
    $adapterList = $view.AdapterList
    $copyMac = $view.CopyMac
    $magicWake = $view.MagicWake
    $status = $view.Status
    $autoStart = $view.AutoStart
    $disableLockScreen = $view.DisableLockScreen
    $save = $view.Save
    $cancel = $view.Cancel
    if ($Script:ConfigLoadError) {
        $status.ForeColor = [Drawing.Color]::Firebrick
        $status.Text = "配置文件无法读取，请检查列表后重新保存。"
    }
    elseif ($FirstRun -and $entries.Count -eq 0) { $status.Text = "当前没有启动程序。添加程序后，看门狗将按配置运行。" }
    $adapters = @(WdGetPhysicalNetworkAdapters)
    foreach ($adapter in $adapters) {
        $item = New-Object System.Windows.Forms.ListViewItem([string]$adapter.Name)
        [void]$item.SubItems.Add(([string]$adapter.MacAddress).ToUpperInvariant())
        $item.Tag = [string]$adapter.MacAddress
        [void]$adapterList.Items.Add($item)
    }
    if ($adapterList.Items.Count -gt 0) { $adapterList.Items[0].Selected = $true }
    $copyMac.Add_Click({
        if ($adapterList.SelectedItems.Count -eq 0) { return }
        $mac = [string]$adapterList.SelectedItems[0].Tag
        if (-not [string]::IsNullOrWhiteSpace($mac)) {
            [System.Windows.Forms.Clipboard]::SetText($mac)
            $status.ForeColor = [System.Drawing.Color]::DarkGreen
            $status.Text = "已复制物理网卡 MAC 地址：$mac"
        }
    })

    $setEditorEnabled = {
        $enabled = $state.SelectedIndex -ge 0 -and $state.SelectedIndex -lt $entries.Count
        foreach ($control in @($pathBox, $browse, $argsBox, $firstBox, $restartBox, $minBox) + @($checkBoxes.Values)) {
            $control.Enabled = $enabled
        }
        $remove.Enabled = $enabled
    }.GetNewClosure()

    $loadEditor = {
        $wasLoading = $state.Loading
        $state.Loading = $true
        try {
            if ($state.SelectedIndex -lt 0 -or $state.SelectedIndex -ge $entries.Count) {
                $pathBox.Text = ""; $argsBox.Text = ""
                $firstBox.Value = 1; $restartBox.Value = 5; $minBox.Value = 15
                foreach ($check in $checkBoxes.Values) { $check.Checked = $false }
                $checkBoxes["KillTreeOnHang"].Checked = $true
                & $setEditorEnabled
                return
            }
            $entry = $entries[$state.SelectedIndex]
            $config = WdNewAppConfiguration -Source $entry.Config
            $pathBox.Text = [string]$entry.Path
            $argsBox.Text = $config.Arguments
            $firstBox.Value = [Math]::Max($firstBox.Minimum, [Math]::Min($firstBox.Maximum, $config.First))
            $restartBox.Value = [Math]::Max($restartBox.Minimum, [Math]::Min($restartBox.Maximum, $config.Restart))
            $minBox.Value = [Math]::Max($minBox.Minimum, [Math]::Min($minBox.Maximum, $config.MinUpSeconds))
            foreach ($key in $checkBoxes.Keys) { $checkBoxes[$key].Checked = [bool](WdGetConfigValue $config $key $false) }
            & $setEditorEnabled
        }
        finally { $state.Loading = $wasLoading }
    }.GetNewClosure()

    $saveEditor = {
        if ($state.SelectedIndex -lt 0 -or $state.SelectedIndex -ge $entries.Count) { return $true }
        $entries[$state.SelectedIndex].Path = $pathBox.Text.Trim()
        $config = WdNewAppConfiguration -Source $entries[$state.SelectedIndex].Config
        $config.Arguments = $argsBox.Text
        $config.First = [int]$firstBox.Value
        $config.Restart = [int]$restartBox.Value
        $config.MinUpSeconds = [int]$minBox.Value
        foreach ($key in $checkBoxes.Keys) { $config[$key] = [bool]$checkBoxes[$key].Checked }
        $entries[$state.SelectedIndex].Config = $config
        if ($state.SelectedIndex -lt $list.Items.Count) {
            $displayPath = [string]$entries[$state.SelectedIndex].Path
            $displayName = $displayPath
            if ($displayPath -notmatch '^https?://') {
                try { $displayName = [System.IO.Path]::GetFileName($displayPath) } catch {}
            }
            if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = "未命名程序" }
            $list.Items[$state.SelectedIndex].Text = $displayName
            $list.Items[$state.SelectedIndex].SubItems[1].Text = $displayPath
            $list.Items[$state.SelectedIndex].ToolTipText = $displayPath
            $list.Items[$state.SelectedIndex].SubItems[2].Text = if ($displayPath -imatch '^https?://') { "网址" } elseif (Test-Path -LiteralPath $displayPath -PathType Leaf) { "就绪" } else { "待修复" }
            $list.Items[$state.SelectedIndex].SubItems[3].Text = if ([bool]$config.FocusTop) { "是" } else { "" }
        }
        return $true
    }.GetNewClosure()

    $refreshList = {
        $wasLoading = $state.Loading
        $state.Loading = $true
        $list.BeginUpdate()
        try {
            $list.Items.Clear()
            $view.EmptyList.Visible = ($entries.Count -eq 0)
            for ($entryIndex = 0; $entryIndex -lt $entries.Count; $entryIndex++) {
                $entry = $entries[$entryIndex]
                $displayPath = [string]$entry.Path
                $displayName = $displayPath
                if ($displayPath -notmatch '^https?://') {
                    try { $displayName = [System.IO.Path]::GetFileName($displayPath) } catch {}
                }
                if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = "未命名程序" }
                $statusText = if ($displayPath -imatch '^https?://') { "网址" } elseif (Test-Path -LiteralPath $displayPath -PathType Leaf) { "就绪" } else { "待修复" }
                $item = New-Object System.Windows.Forms.ListViewItem($displayName)
                $item.ToolTipText = $displayPath
                [void]$item.SubItems.Add($displayPath)
                [void]$item.SubItems.Add($statusText)
                [void]$item.SubItems.Add($(if ([bool]$entry.Config.FocusTop) { "是" } else { "" }))
                [void]$list.Items.Add($item)
            }
            if ($state.SelectedIndex -ge 0 -and $state.SelectedIndex -lt $list.Items.Count) {
                $list.Items[$state.SelectedIndex].Selected = $true
                $list.Items[$state.SelectedIndex].Focused = $true
            }
        }
        finally {
            $list.EndUpdate()
            $state.Loading = $wasLoading
        }
    }.GetNewClosure()

    $addExecutablePaths = {
        param([string[]]$Paths)

        [void](& $saveEditor)
        $knownPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $entries) {
            $entryPath = [string]$entry.Path
            if ([string]::IsNullOrWhiteSpace($entryPath) -or $entryPath -imatch '^https?://') { continue }
            try { $entryPath = [System.IO.Path]::GetFullPath($entryPath) } catch {}
            [void]$knownPaths.Add($entryPath)
        }

        $addedCount = 0
        $skippedCount = 0
        foreach ($droppedPath in @($Paths)) {
            if ([string]::IsNullOrWhiteSpace($droppedPath) -or
                [System.IO.Path]::GetExtension($droppedPath) -ine '.exe' -or
                -not (Test-Path -LiteralPath $droppedPath -PathType Leaf)) {
                $skippedCount++
                continue
            }

            try {
                $executablePath = (Get-Item -LiteralPath $droppedPath -ErrorAction Stop).FullName
                if (-not $knownPaths.Add($executablePath)) {
                    $skippedCount++
                    continue
                }
                [void]$entries.Add([pscustomobject]@{
                    Path   = $executablePath
                    Config = WdNewAppConfiguration -Source $null
                })
                $addedCount++
            }
            catch {
                $skippedCount++
            }
        }

        if ($addedCount -gt 0) {
            $state.SelectedIndex = $entries.Count - 1
            & $refreshList
            & $loadEditor
            $status.ForeColor = [System.Drawing.Color]::DarkGreen
            $status.Text = "已添加 $addedCount 个程序。请点击保存全部应用配置。"
        }
        else {
            $status.ForeColor = [System.Drawing.Color]::DarkGoldenrod
            $status.Text = "未添加程序：仅接受存在且未重复的 .exe 文件。"
        }
        if ($addedCount -gt 0 -and $skippedCount -gt 0) {
            $status.Text += " 已忽略 $skippedCount 个无效或重复文件。"
        }
    }.GetNewClosure()

    $browse.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = "选择要监控的程序"
        $dialog.Filter = "程序和脚本 (*.exe;*.bat;*.cmd;*.py)|*.exe;*.bat;*.cmd;*.py|所有文件 (*.*)|*.*"
        $dialog.CheckFileExists = $true
        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $pathBox.Text = $dialog.FileName }
        $dialog.Dispose()
    })
    $checkBoxes["FocusTop"].Add_CheckedChanged({
        if ($state.Loading -or $state.SelectedIndex -lt 0 -or $state.SelectedIndex -ge $entries.Count) { return }

        $currentConfig = WdNewAppConfiguration -Source $entries[$state.SelectedIndex].Config
        $currentConfig.FocusTop = [bool]$checkBoxes["FocusTop"].Checked
        $entries[$state.SelectedIndex].Config = $currentConfig
        if ($state.SelectedIndex -lt $list.Items.Count) {
            $list.Items[$state.SelectedIndex].SubItems[3].Text = if ($currentConfig.FocusTop) { "是" } else { "" }
        }
        if (-not $currentConfig.FocusTop) {
            $status.ForeColor = [System.Drawing.Color]::DimGray
            $status.Text = "已取消当前程序的窗口置顶。"
            return
        }

        for ($entryIndex = 0; $entryIndex -lt $entries.Count; $entryIndex++) {
            if ($entryIndex -eq $state.SelectedIndex) { continue }
            $entryConfig = WdNewAppConfiguration -Source $entries[$entryIndex].Config
            if ([bool]$entryConfig.FocusTop) {
                $entryConfig.FocusTop = $false
                $entries[$entryIndex].Config = $entryConfig
                if ($entryIndex -lt $list.Items.Count) { $list.Items[$entryIndex].SubItems[3].Text = "" }
            }
        }
        $status.ForeColor = [System.Drawing.Color]::DarkGreen
        $status.Text = "已将当前程序设为唯一置顶目标。"
    })
    $add.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = "添加要监控的程序"
        $dialog.Filter = "程序和脚本 (*.exe;*.bat;*.cmd;*.py)|*.exe;*.bat;*.cmd;*.py|所有文件 (*.*)|*.*"
        $dialog.CheckFileExists = $true
        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            [void](& $saveEditor)
            [void]$entries.Add([pscustomobject]@{ Path = $dialog.FileName; Config = WdNewAppConfiguration -Source $null })
            $state.SelectedIndex = $entries.Count - 1
            & $refreshList; & $loadEditor
        }
        $dialog.Dispose()
    })
    $list.Add_DragEnter({
        param($sender, $eventArgs)

        $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::None
        if (-not $eventArgs.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { return }
        $droppedPaths = @($eventArgs.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
        if (@($droppedPaths | Where-Object {
                    [System.IO.Path]::GetExtension([string]$_) -ieq '.exe' -and
                    (Test-Path -LiteralPath ([string]$_) -PathType Leaf)
                }).Count -gt 0) {
            $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::Copy
        }
    })
    $list.Add_DragDrop({
        param($sender, $eventArgs)

        if (-not $eventArgs.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { return }
        try {
            $droppedPaths = [string[]]@($eventArgs.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
            & $addExecutablePaths -Paths $droppedPaths
        }
        catch {
            $status.ForeColor = [System.Drawing.Color]::Firebrick
            $status.Text = "拖入程序失败：$($_.Exception.Message)"
        }
    })
    $remove.Add_Click({
        if ($state.SelectedIndex -lt 0 -or $state.SelectedIndex -ge $entries.Count) { return }
        [void]$entries.RemoveAt($state.SelectedIndex)
        $state.SelectedIndex = [Math]::Min($state.SelectedIndex, $entries.Count - 1)
        & $refreshList; & $loadEditor
    })
    $list.Add_SelectedIndexChanged({
        if ($state.Loading -or $list.SelectedIndices.Count -eq 0) { return }
        [void](& $saveEditor)
        $state.SelectedIndex = $list.SelectedIndices[0]
        & $loadEditor
    })
    $save.Add_Click({
        try {
            [void](& $saveEditor)
            WdApplyAppConfigurations `
                -Entries $entries `
                -StartWithWindows $autoStart.Checked `
                -DisableLockScreen $disableLockScreen.Checked `
                -EnableMagicWake $magicWake.Checked
            $form.Tag = "saved"
            $status.ForeColor = [System.Drawing.Color]::DarkGreen
            $status.Text = "已保存 $($entries.Count) 个启动程序，监控已立即更新。"
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        }
        catch {
            $status.ForeColor = [System.Drawing.Color]::Firebrick
            $status.Text = "保存失败：$($_.Exception.Message)"
            WdOfferAuthorizationForError -Exception $_.Exception -Operation "保存看门狗配置"
            $form.DialogResult = [System.Windows.Forms.DialogResult]::None
            if ($Script:ExitRequested) { $form.Close() }
        }
    })
    $form.AcceptButton = $save
    $form.CancelButton = $cancel
    if ($entries.Count -gt 0) { $state.SelectedIndex = 0 }
    & $refreshList; & $loadEditor
    try {
        [void]$form.ShowDialog()
        return ($form.Tag -eq "saved")
    }
    finally {
        $Script:SettingsForm = $null
        $Script:SettingsWindowOpen = $false
        $Script:UserInteractionActive = $previousUserInteraction
        $form.Dispose()
    }
}

function WdEnsureConfiguredTarget {
    $hasValidTarget = $false
    foreach ($currentPath in $Apps.Keys) {
        if ($currentPath -imatch '^https?://' -or (Test-Path -LiteralPath $currentPath -PathType Leaf)) {
            $hasValidTarget = $true
            break
        }
    }
    $needsSetup = (-not $Script:ConfigWasLoaded) -or
        ($Apps.Count -gt 0 -and -not $hasValidTarget)

    if (-not $needsSetup) { return $true }
    if ($Unattended) {
        WdWriteLog "UI: Setup is required, but unattended startup will not display a window." "DarkYellow"
        return $true
    }

    try {
        $saved = WdShowSettingsWindow -FirstRun
        if ($saved) { return $true }
    }
    catch {
        WdWriteLog "UI: Settings window failed - $($_.Exception.Message)" "Red"
    }

    $Script:ExitRequested = $true
    return $false
}

# =================== 5.3 托盘图标 ===================
$Script:TrayNotifyIcon = $null
$Script:TrayContextMenu = $null
$Script:TrayExitMenuItem = $null
$Script:TraySettingsMenuItem = $null
$Script:TrayElevateMenuItem = $null
$Script:TrayOwnedIcon = $null

function WdRequestExit {
    param([string]$Reason = "user request")

    if ($Script:ExitRequested) { return }

    $Script:ExitRequested = $true
    try { WdWriteLog "TRAY: Exit requested ($Reason)." "Yellow" } catch {}

    # 立即隐藏图标并关闭菜单，给用户明确的退出反馈。完整 Dispose 由主循环
    # finally 执行，避免在 ToolStripMenuItem.Click 回调内释放正在执行的控件。
    if ($Script:TrayExitMenuItem) {
        try { $Script:TrayExitMenuItem.Enabled = $false } catch {}
    }
    if ($Script:TraySettingsMenuItem) {
        try { $Script:TraySettingsMenuItem.Enabled = $false } catch {}
    }
    if ($Script:TrayElevateMenuItem) {
        try { $Script:TrayElevateMenuItem.Enabled = $false } catch {}
    }
    if ($Script:TrayContextMenu) {
        try { $Script:TrayContextMenu.Close() } catch {}
    }
    if ($Script:TrayNotifyIcon) {
        try { $Script:TrayNotifyIcon.Visible = $false } catch {}
    }

    # ShowDialog 会形成嵌套的 WinForms 消息循环。如果设置窗口正打开，
    # 只设 ExitRequested 无法让主循环继续到 finally，必须主动关闭该对话框。
    $settingsForm = $Script:SettingsForm
    if ($settingsForm) {
        try {
            if (-not $settingsForm.IsDisposed) {
                $settingsForm.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
                $settingsForm.Close()
            }
        }
        catch {
            try {
                $closeSettingsForm = [Action]{ $settingsForm.Close() }
                $settingsForm.BeginInvoke($closeSettingsForm) | Out-Null
            }
            catch {}
        }
    }
}

function WdHideWatchdogConsoleWindow {
    if (-not $HideWatchdogConsole) { return }

    try {
        $consoleWindow = [WatchdogWin32.DisplayAPI]::GetConsoleWindow()
        if ($consoleWindow -ne [IntPtr]::Zero) {
            [void][WatchdogWin32.DisplayAPI]::ShowWindow($consoleWindow, 0)
        }
    }
    catch {
        WdWriteLog "TRAY: Failed to hide PowerShell console - $($_.Exception.Message)" "DarkYellow"
    }
}

function WdInitializeTrayIcon {
    if (-not $ShowTrayIcon) { return $true }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop

        $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
        $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
        $settingsMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
        $elevateMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
        $exitMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem

        $settingsMenuItem.Text = "设置启动程序..."
        $settingsMenuItem.add_Click({
                [void](WdShowSettingsWindow)
            })
        [void]$contextMenu.Items.Add($settingsMenuItem)

        $elevateMenuItem.Text = "管理员授权并重启"
        $elevateMenuItem.Visible = -not (WdTestIsAdministrator)
        $elevateMenuItem.add_Click({
                [void](WdRequestElevatedRestart)
            })
        [void]$contextMenu.Items.Add($elevateMenuItem)
        [void]$contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

        $exitMenuItem.Text = "退出"
        $exitMenuItem.add_Click({
                WdRequestExit -Reason "tray menu"
            })
        [void]$contextMenu.Items.Add($exitMenuItem)

        $ownedIcon = $null
        if (-not [string]::IsNullOrWhiteSpace($TrayIconPath) -and (Test-Path -LiteralPath $TrayIconPath)) {
            $ownedIcon = New-Object System.Drawing.Icon($TrayIconPath)
            $notifyIcon.Icon = $ownedIcon
        }
        else {
            $notifyIcon.Icon = [System.Drawing.SystemIcons]::Shield
        }

        $notifyIcon.Text = "守护进程"
        $notifyIcon.ContextMenuStrip = $contextMenu
        $notifyIcon.add_DoubleClick({
                [void](WdShowSettingsWindow)
            })
        $notifyIcon.Visible = $true

        $Script:TrayNotifyIcon = $notifyIcon
        $Script:TrayContextMenu = $contextMenu
        $Script:TraySettingsMenuItem = $settingsMenuItem
        $Script:TrayElevateMenuItem = $elevateMenuItem
        $Script:TrayExitMenuItem = $exitMenuItem
        $Script:TrayOwnedIcon = $ownedIcon
        if ($ElevatedRelaunch) {
            $notifyIcon.BalloonTipTitle = "守护进程"
            $notifyIcon.BalloonTipText = "管理员授权已完成。"
            $notifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
            $notifyIcon.ShowBalloonTip(3000)
        }
        WdWriteLog "TRAY: Notification icon initialized." "DarkGray"
        return $true
    }
    catch {
        WdWriteLog "TRAY: Failed to initialize notification icon - $($_.Exception.Message)" "DarkYellow"
        WdDisposeTrayIcon
        return $false
    }
}

function WdPumpTrayEvents {
    if (-not $Script:TrayNotifyIcon -and -not $Script:DisplayEventMonitor) { return }
    try { [System.Windows.Forms.Application]::DoEvents() } catch {}
}

function WdInitializeDisplayEventMonitor {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        if (-not ([System.Management.Automation.PSTypeName]'WatchdogWin32.DisplayEventMonitor').Type) {
            $displayEventCode = @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace WatchdogWin32
{
    // An invisible top-level window receives broadcast messages, including while the tray is disabled.
    public sealed class DisplayEventMonitor : NativeWindow, IDisposable
    {
        private static readonly Guid SessionDisplay = new Guid("2B84C20E-AD23-4DDF-93DB-05FFBD7EFCA5");
        private IntPtr powerRegistration;
        private int lastPowerState = -1;
        private bool pending;
        public bool PowerNotificationsAvailable { get { return powerRegistration != IntPtr.Zero; } }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr RegisterPowerSettingNotification(IntPtr recipient, ref Guid setting, uint flags);
        [DllImport("user32.dll")]
        private static extern bool UnregisterPowerSettingNotification(IntPtr handle);

        public DisplayEventMonitor()
        {
            CreateParams parameters = new CreateParams();
            parameters.Caption = "Watchdog Display Events";
            parameters.Style = 0; // No WS_VISIBLE: no user-facing window or focus change.
            parameters.ExStyle = 0x80; // WS_EX_TOOLWINDOW
            CreateHandle(parameters);
            try
            {
                Guid setting = SessionDisplay;
                powerRegistration = RegisterPowerSettingNotification(Handle, ref setting, 0);
            }
            catch (EntryPointNotFoundException) { }
        }

        public bool ConsumeChange()
        {
            bool changed = pending;
            pending = false;
            return changed;
        }

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == 0x007E) pending = true; // WM_DISPLAYCHANGE
            if (message.Msg == 0x0218 && message.WParam.ToInt64() == 0x8013 && message.LParam != IntPtr.Zero)
            {
                // POWERBROADCAST_SETTING: GUID (16 bytes), DWORD length, DWORD data.
                Guid setting = (Guid)Marshal.PtrToStructure(message.LParam, typeof(Guid));
                if (setting == SessionDisplay && Marshal.ReadInt32(message.LParam, 16) == 4)
                {
                    int state = Marshal.ReadInt32(message.LParam, 20);
                    if (state >= 0 && state <= 2)
                    {
                        // The initial notification establishes state, not a spurious power-on event.
                        if (lastPowerState >= 0 && lastPowerState != 1 && state == 1) pending = true;
                        lastPowerState = state;
                    }
                }
            }
            base.WndProc(ref message);
        }

        public void Dispose()
        {
            if (powerRegistration != IntPtr.Zero)
            {
                UnregisterPowerSettingNotification(powerRegistration);
                powerRegistration = IntPtr.Zero;
            }
            DestroyHandle();
        }
    }
}
"@
            $displayEventReferences = @(
                [System.Windows.Forms.NativeWindow].Assembly.Location
                [System.Windows.Forms.Message].Assembly.Location
            ) | Select-Object -Unique
            Add-Type -TypeDefinition $displayEventCode -Language CSharp -ReferencedAssemblies $displayEventReferences -ErrorAction Stop
        }
        $Script:DisplayEventMonitor = New-Object WatchdogWin32.DisplayEventMonitor
        WdWriteLog "DISPLAY-EVENTS: Hidden listener ready; power notifications=$($Script:DisplayEventMonitor.PowerNotificationsAvailable)." "DarkGray"
    }
    catch {
        WdWriteLog "DISPLAY-EVENTS: Listener unavailable; continuing topology and fullscreen polling. $($_.Exception.Message)" "DarkYellow"
    }
}

function WdConsumeDisplayEvent {
    if ($Script:DisplayEventMonitor -and $Script:DisplayEventMonitor.ConsumeChange()) {
        if ($Script:DisplayEventQuietUntil -and (Get-Date) -lt $Script:DisplayEventQuietUntil) {
            WdWriteLog "DISPLAY-EVENTS: Notification during our own display recovery ignored; topology and fullscreen polling remain active." "DarkGray"
            return $false
        }
        return $true
    }
    return $false
}

function WdDisposeTrayIcon {
    if ($Script:TrayNotifyIcon) {
        try { $Script:TrayNotifyIcon.Visible = $false } catch {}
        try { $Script:TrayNotifyIcon.Dispose() } catch {}
        $Script:TrayNotifyIcon = $null
    }
    if ($Script:TrayExitMenuItem) {
        try { $Script:TrayExitMenuItem.Dispose() } catch {}
        $Script:TrayExitMenuItem = $null
    }
    if ($Script:TrayElevateMenuItem) {
        try { $Script:TrayElevateMenuItem.Dispose() } catch {}
        $Script:TrayElevateMenuItem = $null
    }
    if ($Script:TraySettingsMenuItem) {
        try { $Script:TraySettingsMenuItem.Dispose() } catch {}
        $Script:TraySettingsMenuItem = $null
    }
    if ($Script:TrayContextMenu) {
        try { $Script:TrayContextMenu.Dispose() } catch {}
        $Script:TrayContextMenu = $null
    }
    if ($Script:TrayOwnedIcon) {
        try { $Script:TrayOwnedIcon.Dispose() } catch {}
        $Script:TrayOwnedIcon = $null
    }
    try { [System.Windows.Forms.Application]::DoEvents() } catch {}
}

function WdWaitWithControlPolling {
    param([int]$Milliseconds)

    $deadline = (Get-Date).AddMilliseconds([Math]::Max(0, $Milliseconds))
    do {
        WdPumpTrayEvents
        if ($Script:ExitRequested) { break }

        WdPollControlListeners
        WdInvokePendingControlActions

        $remaining = [int][Math]::Ceiling(($deadline - (Get-Date)).TotalMilliseconds)
        if ($remaining -gt 0) {
            Start-Sleep -Milliseconds ([Math]::Min(100, $remaining))
        }
    } while ((Get-Date) -lt $deadline -and -not $Script:ExitRequested)
}

# =================== 6. 初始化 ===================
WdEnsureDirectory -Path $WatchdogRoot
if (-not $Script:DisableLockScreenWasConfigured) {
    $Script:DisableLockScreen = WdTestLockScreenSettingMatches -Disabled $true
}
WdOpenLogWriter
$trayInitialized = [bool](WdInitializeTrayIcon)
$targetConfigured = WdEnsureConfiguredTarget
if (-not $targetConfigured -or $Script:ExitRequested) {
    if (-not $targetConfigured -and -not $Script:ConfigWasLoaded) {
        try { WdWriteLog "UI: No valid monitoring target was selected; Watchdog will exit." "DarkYellow" } catch {}
    }
    WdInvokeShutdownCleanup
    exit 0
}

try {
    if ($Script:AutoDiscoveredTarget) {
        WdSaveUserConfiguration -AppConfigurations $Apps -StartWithWindows $Script:StartWithWindows -EnableMagicWake $Script:EnableMagicWake
        $Script:AutoDiscoveredTarget = $false
        WdWriteLog "UI: Local executable auto-detected and saved." "DarkGreen"
    }
    WdSetStartupEnabled -Enabled $Script:StartWithWindows
    WdSetLockScreenDisabled -Disabled $Script:DisableLockScreen
    WdApplyMagicWakeSettings -Enabled $Script:EnableMagicWake
}
catch {
    WdWriteLog "UI: Configuration/startup synchronization failed - $($_.Exception.Message)" "Red"
    WdOfferAuthorizationForError -Exception $_.Exception -Operation "保存配置或更新 Windows 系统设置"
    if ($Script:ExitRequested) {
        WdInvokeShutdownCleanup
        exit 0
    }
}

if (-not $ShowTrayIcon -or $trayInitialized) {
    WdHideWatchdogConsoleWindow
}
elseif ($HideWatchdogConsole) {
    WdWriteLog "TRAY: Console remains visible because tray initialization failed." "DarkYellow"
}

WdWriteLog "=== Watchdog Service Active (Monitor Count: $($Apps.Count)) ===" "Yellow"
WdWriteLog "INFO: Portable configuration path = $UserConfigPath" "DarkGray"
WdWriteLog "INFO: Start with Windows = $Script:StartWithWindows" "DarkGray"
WdWriteLog "INFO: Magic wake enabled = $Script:EnableMagicWake" "DarkGray"
WdWriteLog "INFO: Disable flag path = $DisableFlag" "DarkGray"
WdWriteLog "INFO: Task Manager open state is treated as disable flag" "DarkGray"
WdWriteLog "INFO: Check interval = $CheckInterval sec, Max retry/hour = $MaxRetryInHour" "DarkGray"
WdWriteLog "INFO: Log max size = ${MaxLogSizeMB}MB, Backups = $MaxLogBackups" "DarkGray"
WdWriteLog "INFO: GC collect every $GCCollectEvery iterations (~$($GCCollectEvery * $CheckInterval) sec)" "DarkGray"
WdWriteLog "INFO: Min restart gap = $MinRestartGapSeconds sec, Display loop repair = $DisplayLoopRepair" "DarkGray"
WdWriteLog "INFO: Hang restart threshold = $HangConsecutiveFailuresToRestart consecutive failures" "DarkGray"
WdWriteLog "INFO: Display change debounce = $DisplayChangeDebounceSeconds sec" "DarkGray"
WdWriteLog "INFO: Unity display recovery = refresh fullscreen then verify; startup grace=${UnityDisplayStartupGraceSeconds}s, mismatch checks=$UnityDisplayMismatchChecks, repair grace=${UnityDisplayRepairGraceSeconds}s, restart cooldown=${DisplayRecoveryCooldownSeconds}s" "DarkGray"
WdWriteLog "INFO: Process stop timeout = $ProcessStopTimeoutSeconds sec, Fast-exit max backoff = $FastExitMaxBackoffSeconds sec" "DarkGray"
WdWriteLog "INFO: Control commands = reboot, shutdown, restart, VOL GET/SET/INC/DEC/MUTE; heartbeat = ping / heartbeat (TCP / UDP UTF-8 text)" "DarkGray"
WdWriteLog "INFO: Console hidden = $HideWatchdogConsole, Tray icon = $ShowTrayIcon" "DarkGray"

$startupCursorRestoreNeeded = $false
foreach ($startupPath in $Apps.Keys) {
    $startupConfig = $Apps[$startupPath]
    if ($startupPath.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase) -and
        $startupConfig.ContainsKey("HideCursor") -and [bool]$startupConfig.HideCursor) {
        $startupCursorRestoreNeeded = $true
        break
    }
}
if ($startupCursorRestoreNeeded) {
    WdWriteLog "CURSOR: HideCursor is configured; restoring cursor once at startup." "DarkGray"
    try {
        [WatchdogWin32.DisplayAPI]::SystemParametersInfo($SPI_SETCURSORS, 0, [IntPtr]::Zero, 0) | Out-Null
        $Script:CursorHiddenApplied = $false
    }
    catch {
        WdWriteLog "CURSOR: Startup cursor restore failed - $($_.Exception.Message)" "DarkYellow"
    }
}

$FirstRun = $true
$RestartStats = @{}
$LaunchTime = @{}
$DisplayRepairDone = @{}
$FocusLastTime = @{}
$LastStartAttempt = @{}
$LastStartedProcessId = @{}
$ThrottleWarned = @{}
$MissingLogged = @{}
$HangFailCount = @{}
$FastExitFailCount = @{}
$FastExitHandledLaunch = @{}
$ScheduledLaunch = @{}   # Path -> [DateTime] of next permitted launch attempt
$Script:GCCounter = 0
$DisplayTopologyState = @{ Baseline = (WdGetDisplayTopologyFingerprint); Pending = $null; ChangedAt = $null }
$DisplayChangeRestartInProgress = @{}
$FullscreenHealth = @{}
$DisplayRecoveryLastAttempt = @{}
$DisplayRecoveryPending = @{}
WdInitializeDisplayEventMonitor
if ($DisplayTopologyState.Baseline) {
    WdWriteLog "DISPLAY-CHANGE: Initial topology fingerprint = [$($DisplayTopologyState.Baseline)]" "DarkGray"
}
[void](WdStartControlListeners)

# =================== 7. 主循环 ===================
try {
    while (-not $Script:ExitRequested) {
        WdWaitWithControlPolling -Milliseconds 200  # preventive: guards against CPU spin and keeps control responsive
        if ($Script:ExitRequested) { break }
        try {
            WdRotateLog
            $CurrentHour = (Get-Date).Hour
            WdCleanupRestartStats -Table $RestartStats -CurrentHour $CurrentHour
            WdCleanupRestartStats -Table $ThrottleWarned -CurrentHour $CurrentHour

            $disableReason = WdGetDisableReason
            if (WdUpdateDisableState -DisableReason $disableReason) {
                $FullscreenHealth.Clear()
                $DisplayRecoveryPending.Clear()
                [void](WdConsumeDisplayEvent)
                $currentDisplayTopology = WdGetDisplayTopologyFingerprint
                if ($currentDisplayTopology) {
                    $DisplayTopologyState.Baseline = $currentDisplayTopology
                    $DisplayTopologyState.Pending = $null
                    $DisplayTopologyState.ChangedAt = $null
                    $DisplayChangeRestartInProgress.Clear()
                }
                $FirstRun = $false
                WdWaitWithControlPolling -Milliseconds ($CheckInterval * 1000)
                continue
            }

            $anyCursorHideNeeded = $false
            $monitoringPaused = $false

            $currentDisplayTopology = WdGetDisplayTopologyFingerprint
            if (WdUpdateDisplayTopologyState -State $DisplayTopologyState -Fingerprint $currentDisplayTopology -DisplayEvent (WdConsumeDisplayEvent)) {
                WdWriteLog "DISPLAY-CHANGE: Topology stable; queuing enabled targets for recovery." "Yellow"
                foreach ($restartPath in $Apps.Keys) {
                    if (WdIsDisplayChangeRestartEnabled -Path $restartPath -Config $Apps[$restartPath]) {
                        $DisplayRecoveryPending[$restartPath] = $true
                    }
                }
            }
            $displayStable = ($currentDisplayTopology -and -not $DisplayTopologyState.Pending)
            foreach ($Path in $Apps.Keys) {
                $procs = $null
                $FirstProc = $null
                $mainProc = $null
                try {
                    $Config = $Apps[$Path]
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
                    $isExe = $Path.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase)
                    $isUrl = WdIsBrowserUrl -Path $Path

                $StatKey = "${Path}::H${CurrentHour}"
                $OnceKey = "${Path}::Once"

                WdInitializeCounter -Table $RestartStats -Key $StatKey -DefaultValue 0

                $disableReason = WdGetDisableReason
                if (WdUpdateDisableState -DisableReason $disableReason) {
                    $FullscreenHealth.Clear()
                    $DisplayRecoveryPending.Clear()
                    [void](WdConsumeDisplayEvent)
                    $currentDisplayTopology = WdGetDisplayTopologyFingerprint
                    if ($currentDisplayTopology) {
                        $DisplayTopologyState.Baseline = $currentDisplayTopology
                        $DisplayTopologyState.Pending = $null
                        $DisplayTopologyState.ChangedAt = $null
                        $DisplayChangeRestartInProgress.Clear()
                    }
                    $monitoringPaused = $true
                    break
                }

                $allowMultiInstance = if ($Config.ContainsKey("AllowMultiInstance")) { [bool]$Config.AllowMultiInstance } else { $false }
                $unityDisplayRecovery = WdIsUnityDisplayRecoveryEnabled -Path $Path -Config $Config
                $killTreeOnHang = if ($Config.ContainsKey("KillTreeOnHang")) { [bool]$Config.KillTreeOnHang }     else { $true }
                $browserName = if ($Config.ContainsKey("Browser") -and
                    -not [string]::IsNullOrWhiteSpace([string]$Config.Browser)) { [string]$Config.Browser } else { "auto" }
                $minUpSeconds = WdGetConfigInt -Config $Config -Name "MinUpSeconds" -DefaultValue 5 -Minimum 1
                $hideCursor = if ($Config.ContainsKey("HideCursor") -and $isExe) { [bool]$Config.HideCursor } else { $false }

                $procs = WdGetTargetProcess -Path $Path
                $procCount = if ($procs -is [array]) { $procs.Count } elseif ($procs) { 1 } else { 0 }

                if ($DisplayChangeRestartInProgress.ContainsKey($Path)) {
                    $displayRestartState = $DisplayChangeRestartInProgress[$Path]
                    $displayRestartPid = [int]$displayRestartState.ProcessId
                    $displayRestartName = if ($displayRestartState.FileName) { [string]$displayRestartState.FileName } else { $FileName }

                    if ($displayRestartPid -le 0 -or -not (WdTestProcessIdAlive -ProcessId $displayRestartPid)) {
                        WdWriteLog "DISPLAY-CHANGE: $displayRestartName old process exited; normal relaunch flow can continue." "DarkGreen"
                        $DisplayChangeRestartInProgress.Remove($Path)
                        if ($procs) {
                            $procs | ForEach-Object {
                                WdDisposeProcessResult $_
                            }
                            $procs = $null
                        }
                        $procs = WdGetTargetProcess -Path $Path
                        $procCount = if ($procs -is [array]) { $procs.Count } elseif ($procs) { 1 } else { 0 }
                    }
                    else {
                        $now = Get-Date
                        $elapsedDisplayRestart = ($now - [DateTime]$displayRestartState.StartedAt).TotalSeconds
                        if ($elapsedDisplayRestart -ge $DisplayRestartGiveUpSeconds) {
                            WdWriteLog "CRITICAL: DISPLAY-CHANGE: $displayRestartName PID=$displayRestartPid still running after $([int]$elapsedDisplayRestart)s; giving up pending restart state." "Red"
                            $DisplayChangeRestartInProgress.Remove($Path)
                        }
                        else {
                            $lastKillAt = [DateTime]$displayRestartState.LastKillAt
                            if (($now - $lastKillAt).TotalSeconds -ge $DisplayRestartRetrySeconds) {
                                $displayRestartState.Attempts = [int]$displayRestartState.Attempts + 1
                                $displayRestartState.LastKillAt = $now
                                WdWriteLog "DISPLAY-CHANGE: $displayRestartName PID=$displayRestartPid still running; retrying stop attempt $($displayRestartState.Attempts)." "DarkYellow"
                                $stopAgain = WdStopProcessTreeSafe -ProcessId $displayRestartPid -KillTree ([bool]$displayRestartState.KillTree)
                                $displayRestartState.StopSucceeded = $stopAgain
                                $DisplayChangeRestartInProgress[$Path] = $displayRestartState
                            }
                            else {
                                WdWriteLog "DISPLAY-CHANGE: Waiting for $displayRestartName PID=$displayRestartPid to exit after scheduled restart." "DarkGray"
                            }

                            if ($procs) {
                                $procs | ForEach-Object {
                                    WdDisposeProcessResult $_
                                }
                                $procs = $null
                            }
                            continue
                        }
                    }
                }

                if ($procCount -eq 0) {
                    $HangFailCount[$Path] = 0
                    [void]$FullscreenHealth.Remove($Path)
                    if ((WdIsDisplayChangeRestartEnabled -Path $Path -Config $Config) -and -not $displayStable) {
                        continue # 显示尚未稳定时，避免 Unity 再次用临时显示参数启动。
                    }
                    [void]$DisplayRecoveryPending.Remove($Path)

                    # 节流检查放在这里：只拦截"确实缺失、即将重新拉起"的动作。
                    # 之前放在最前面会导致节流命中后，哪怕程序本轮其实已经在
                    # 正常运行，挂死检测/抢焦点/光标隐藏/全屏修复等常规监控
                    # 也会被一并跳过，直到下一个整点才恢复。
                    if ($RestartStats[$StatKey] -ge $MaxRetryInHour) {
                        if (-not $ThrottleWarned.ContainsKey($StatKey)) {
                            WdWriteLog "CRITICAL: $FileName failed too many times this hour ($($RestartStats[$StatKey])/$MaxRetryInHour). Skipping until next hour..." "Red"
                            $ThrottleWarned[$StatKey] = $true
                        }
                        continue
                    }

                    if ($Config.Once -and $RestartStats.ContainsKey($OnceKey) -and $RestartStats[$OnceKey]) {
                        continue
                    }

                    if ($LaunchTime.ContainsKey($Path) -and $LaunchTime[$Path] -and
                        (-not $FastExitHandledLaunch.ContainsKey($Path) -or -not $FastExitHandledLaunch[$Path])) {
                        $upSeconds = ((Get-Date) - $LaunchTime[$Path]).TotalSeconds
                        if ($upSeconds -ge 0 -and $upSeconds -lt $minUpSeconds) {
                            WdInitializeCounter -Table $FastExitFailCount -Key $Path -DefaultValue 0
                            $FastExitFailCount[$Path] = [int]$FastExitFailCount[$Path] + 1
                            $FastExitHandledLaunch[$Path] = $true
                            $baseRestartDelay = WdGetConfigInt -Config $Config -Name "Restart" -DefaultValue 1 -Minimum 1
                            $backoffSeconds = WdGetFastExitBackoffSeconds -FailureCount ([int]$FastExitFailCount[$Path]) -BaseDelaySeconds $baseRestartDelay
                            $ScheduledLaunch[$Path] = (Get-Date).AddSeconds($backoffSeconds)
                            WdWriteLog "FAST-EXIT: $FileName exited after $([int]$upSeconds)s (< ${minUpSeconds}s). Backoff restart in $backoffSeconds sec (failure #$($FastExitFailCount[$Path]))." "Red"
                            continue
                        }
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
                        $WaitTime = if ($FirstRun) {
                            WdGetConfigInt -Config $Config -Name "First" -DefaultValue 0 -Minimum 0
                        }
                        else {
                            WdGetConfigInt -Config $Config -Name "Restart" -DefaultValue 0 -Minimum 0
                        }
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
                        -DisplayRepairDone $DisplayRepairDone -HangFailCount $HangFailCount `
                        -LastStartedProcessId $LastStartedProcessId -FastExitHandledLaunch $FastExitHandledLaunch
                }
                else {
                    if ($LaunchTime.ContainsKey($Path) -and $LaunchTime[$Path] -and
                        ((Get-Date) - $LaunchTime[$Path]).TotalSeconds -ge $minUpSeconds) {
                        if ($FastExitFailCount.ContainsKey($Path) -and [int]$FastExitFailCount[$Path] -gt 0) {
                            WdWriteLog "FAST-EXIT-RECOVERED: $FileName has stayed up for at least ${minUpSeconds}s; reset fast-exit counter." "DarkGreen"
                        }
                        $FastExitFailCount[$Path] = 0
                        $FastExitHandledLaunch[$Path] = $true
                    }

                    $MissingLogged[$Path] = $false
                    $ScheduledLaunch[$Path] = $null  # process is running; clear any pending launch schedule
                    if (-not $allowMultiInstance -and $procCount -gt 1) {
                        WdWriteLog "CONFLICT: $procCount instances of $FileName detected. Cleaning up extra instances..." "Magenta"
                        $preferredPid = if ($LastStartedProcessId.ContainsKey($Path)) { [int]$LastStartedProcessId[$Path] } else { 0 }
                        $keepProc = WdGetPreferredProcess -Processes $procs -PreferredProcessId $preferredPid
                        $keepPid = if ($keepProc) { WdGetProcessId $keepProc } else { 0 }
                        if ($keepPid -gt 0) {
                            WdWriteLog "CONFLICT: Keeping PID=$keepPid for $FileName." "DarkMagenta"
                        }

                        @($procs) | Where-Object { (WdGetProcessId $_) -ne $keepPid } | ForEach-Object {
                            $TargetID = WdGetProcessId $_
                            try {
                                if (WdStopProcessTreeSafe -ProcessId $TargetID -KillTree $true) {
                                    WdWriteLog "CLEANUP: Killed extra instance PID=$TargetID for $FileName" "DarkMagenta"
                                }
                                else {
                                    WdWriteLog "CLEANUP: Failed to confirm extra instance PID=$TargetID stopped for $FileName" "Red"
                                }
                            }
                            catch {}
                        }
                    }

                    $preferredPid = if ($LastStartedProcessId.ContainsKey($Path)) { [int]$LastStartedProcessId[$Path] } else { 0 }
                    $FirstProc = WdGetPreferredProcess -Processes $procs -PreferredProcessId $preferredPid
                    if ($null -eq $FirstProc) {
                        if ($procs) {
                            $procs | ForEach-Object {
                                WdDisposeProcessResult $_
                            }
                        }
                        continue
                    }

                    $TargetID = WdGetProcessId $FirstProc
                    $mainProc = Get-Process -Id $TargetID -ErrorAction SilentlyContinue

                    if ($null -eq $mainProc) {
                        if ($procs) {
                            $procs | ForEach-Object {
                                WdDisposeProcessResult $_
                            }
                        }
                        continue
                    }

                    try {
                        # 持续检查实际客户区；统一通过刷新、复查、重启处理 Unity 全屏异常。
                        $fullscreenMismatch = $false
                        $fullscreenObservation = $null
                        if ($unityDisplayRecovery) {
                            $fullscreenObservation = WdGetFullscreenObservation -ProcessObj $mainProc
                            $fullscreenMismatch = WdUpdateFullscreenHealth -States $FullscreenHealth -Path $Path `
                                -ProcessId $TargetID -Observation $fullscreenObservation -DisplayStable ([bool]$displayStable)
                        }
                        $recoveryRequested = ($DisplayRecoveryPending.ContainsKey($Path) -or $fullscreenMismatch)
                        if ($recoveryRequested -and $displayStable -and
                            (WdCanScheduleDisplayRecovery -Path $Path -LastRecovery $DisplayRecoveryLastAttempt `
                                -InProgress $DisplayChangeRestartInProgress -AttemptsThisHour ([int]$RestartStats[$StatKey]))) {
                            $reason = if ($fullscreenMismatch) { "FULLSCREEN-MISMATCH: $($fullscreenObservation.Details)" } else { "stable display change; $($fullscreenObservation.Details)" }
                            $explicitDisplayRestart = [bool]$Config.RestartOnDisplayChange
                            if ($unityDisplayRecovery -and -not $explicitDisplayRestart -and -not $FullscreenHealth[$Path].RepairAt) {
                                WdWriteLog "DISPLAY-RECOVERY: Refreshing fullscreen for $FileName PID=$TargetID; reason=$reason" "Yellow"
                                $repairApplied = WdRepairWindowDisplayMode -ProcessObj $mainProc -Fullscreen $true -ForceRefresh
                                $Script:DisplayEventQuietUntil = (Get-Date).AddSeconds($UnityDisplayRepairGraceSeconds)
                                $FullscreenHealth[$Path].RepairAt = Get-Date
                                $FullscreenHealth[$Path].Failures = 0
                                [void]$DisplayRecoveryPending.Remove($Path)
                                WdWriteLog "DISPLAY-RECOVERY: Fullscreen refresh applied=$repairApplied; rechecking after $UnityDisplayRepairGraceSeconds sec." "DarkGray"
                                continue
                            }
                            WdWriteLog "DISPLAY-RECOVERY: $FileName PID=$TargetID; reason=$reason" "Yellow"
                            if (WdScheduleDisplayChangeRestart -Path $Path -Config $Config -FileName $FileName `
                                -ProcessId $TargetID -ScheduledLaunch $ScheduledLaunch -LaunchTime $LaunchTime `
                                -DisplayRepairDone $DisplayRepairDone -HangFailCount $HangFailCount `
                                -DisplayChangeRestartInProgress $DisplayChangeRestartInProgress) {
                                $DisplayRecoveryLastAttempt[$Path] = Get-Date
                                [void]$FullscreenHealth.Remove($Path)
                                [void]$DisplayRecoveryPending.Remove($Path)
                            }
                            continue
                        }

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

                            $hangStopSucceeded = WdStopProcessTreeSafe -ProcessId $TargetID -KillTree $killTreeOnHang
                            # Schedule relaunch after the configured Restart delay (non-blocking)
                            $hangRestartDelay = WdGetConfigInt -Config $Config -Name "Restart" -DefaultValue 0 -Minimum 0
                            $ScheduledLaunch[$Path] = (Get-Date).AddSeconds($hangRestartDelay)
                            if ($hangStopSucceeded) {
                                WdWriteLog "HANG: $FileName relaunch scheduled in $hangRestartDelay sec." "DarkYellow"
                            }
                            else {
                                WdWriteLog "HANG: Stop for $FileName PID=$TargetID did not confirm exit; relaunch remains scheduled in $hangRestartDelay sec." "Red"
                            }
                            continue
                        }
                        elseif ($isExe -and $HangFailCount.ContainsKey($Path) -and [int]$HangFailCount[$Path] -gt 0) {
                            WdWriteLog "HANG-RECOVERED: $FileName (PID:$TargetID) responding again; reset consecutive hang counter." "DarkGreen"
                            $HangFailCount[$Path] = 0
                        }

                        if (-not $unityDisplayRecovery -and $Config.ContainsKey("ForceDisplayMode") -and [bool]$Config.ForceDisplayMode -and -not [bool]$Config.HideWindow) {
                            $needRepair = $false

                            if (-not $DisplayRepairDone.ContainsKey($Path) -or -not $DisplayRepairDone[$Path]) {
                                if ($LaunchTime.ContainsKey($Path) -and $LaunchTime[$Path] -and
                                    ((Get-Date) - $LaunchTime[$Path]).TotalSeconds -ge $FullscreenRepairDelay) {
                                    $needRepair = $true
                                }
                            }
                            elseif ($DisplayLoopRepair) {
                                $needRepair = $true
                            }

                            if ($needRepair) {
                                $DisplayRepairDone[$Path] = [bool](WdRepairWindowDisplayMode -ProcessObj $mainProc -Fullscreen ([bool]$Config.Fullscreen))
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
                                try {
                                    if ($null -ne $mainProc.MainWindowHandle) {
                                        $fgHwnd = [IntPtr]$mainProc.MainWindowHandle
                                    }
                                }
                                catch {} # process may have just exited; leave fgHwnd as Zero
                                if ($fgHwnd -ne [IntPtr]::Zero -and (WdIsWindowForeground -Hwnd $fgHwnd)) {
                                    # Already in foreground; reset cooldown to skip redundant attempts
                                    $FocusLastTime[$Path] = Get-Date
                                }
                                elseif (WdSetWindowToForeground -ProcessObj $mainProc) {
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

                    WdDisposeProcessResult $FirstProc
                    $FirstProc = $null
                }

                }
                finally {
                    if ($mainProc) {
                        try { $mainProc.Dispose() } catch {}
                        $mainProc = $null
                    }
                    if ($FirstProc) {
                        WdDisposeProcessResult $FirstProc
                        $FirstProc = $null
                    }
                    if ($procs) {
                        $procs | ForEach-Object {
                            WdDisposeProcessResult $_
                        }
                        $procs = $null
                    }
                }
            }

            if ($monitoringPaused) {
                $FirstRun = $false
                WdWaitWithControlPolling -Milliseconds ($CheckInterval * 1000)
                continue
            }

            $disableReason = WdGetDisableReason
            if (WdUpdateDisableState -DisableReason $disableReason) {
                $FirstRun = $false
                WdWaitWithControlPolling -Milliseconds ($CheckInterval * 1000)
                continue
            }

            $FirstRun = $false

            if ($anyCursorHideNeeded) {
                WdHideSystemCursor
            }
            else {
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

        WdWaitWithControlPolling -Milliseconds ($CheckInterval * 1000)
    }
}
finally {
    try { WdWriteLog "=== Watchdog shutting down. Releasing resources... ===" "Yellow" } catch {}
    WdInvokeShutdownCleanup
}
