# 守护进程通过图形界面完成目标选择和管理员授权。

param(
    [switch]$ElevatedRelaunch,
    [switch]$RestartExisting
)

# StartWatchdog.vbs 已使用 ExecutionPolicy Bypass 启动，无需用户手工修改执行策略。
# 目标程序通过首次运行向导或托盘菜单中的“设置启动程序”进行配置。

$WatchdogRoot = $PSScriptRoot
$UserConfigPath = Join-Path $PSScriptRoot "watchdog.config.json"
$Script:ConfigWasLoaded = $false
$Script:ConfigLoadError = $null
$Script:AutoDiscoveredTarget = $false
$Script:StartWithWindows = $false

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
        $savedConfiguration = Get-Content -LiteralPath $UserConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $savedTargets = @(
            WdGetConfigValue $savedConfiguration "Targets" @()
        )

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
        if ($Apps.Count -eq 0) {
            throw "配置文件中没有有效的启动程序。"
        }

        $Script:StartWithWindows = [bool](WdGetConfigValue $savedConfiguration "StartWithWindows" $false)
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
#                     $true=显示器数量/分辨率/主屏/排列顺序变化并稳定后重启
#                     $false=显示器变化时不重启（推荐仅 Unity 多屏 kiosk 程序启用）
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

        public static string GetActiveMonitorFingerprint()
        {
            List<string> parts = new List<string>();
            int index = 0;

            MonitorEnumProc callback = delegate(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData)
            {
                MONITORINFOEX info = new MONITORINFOEX();
                info.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));

                if (GetMonitorInfo(hMonitor, ref info))
                {
                    parts.Add(String.Format(
                        "{0}|{1}|{2}|{3},{4},{5},{6}",
                        index,
                        info.szDevice,
                        info.dwFlags,
                        info.rcMonitor.left,
                        info.rcMonitor.top,
                        info.rcMonitor.right - info.rcMonitor.left,
                        info.rcMonitor.bottom - info.rcMonitor.top
                    ));
                }
                else
                {
                    parts.Add(String.Format(
                        "{0}|UNKNOWN|0|{1},{2},{3},{4}",
                        index,
                        lprcMonitor.left,
                        lprcMonitor.top,
                        lprcMonitor.right - lprcMonitor.left,
                        lprcMonitor.bottom - lprcMonitor.top
                    ));
                }

                index++;
                return true;
            };

            if (!EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero))
            {
                return null;
            }

            if (parts.Count == 0)
            {
                return "NO_ACTIVE_MONITORS";
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
    try {
        return [WatchdogWin32.DisplayAPI]::GetActiveMonitorFingerprint()
    }
    catch {
        WdWriteLog "DISPLAY-CHANGE: Failed to read display topology - $($_.Exception.Message)" "DarkYellow"
        return $null
    }
}

function WdIsDisplayChangeRestartEnabled {
    param($Config)

    if ($null -eq $Config) { return $false }
    if ($Config.ContainsKey("Once") -and [bool]$Config.Once) { return $false }
    if (-not $Config.ContainsKey("RestartOnDisplayChange")) { return $false }
    return [bool]$Config.RestartOnDisplayChange
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
        [bool]$Fullscreen
    )

    if ($null -eq $ProcessObj) { return }

    $hwnd = WdWaitForWindowHandle -ProcessObj $ProcessObj -TimeoutMs $WD_REPAIR_WINDOW_HANDLE_TIMEOUT_MS
    if ($hwnd -eq [IntPtr]::Zero) {
        WdWriteLog "DISPLAY: Window handle not ready, skipping repair." "DarkGray"
        return
    }

    $winRect = New-Object WatchdogWin32.DisplayAPI+RECT
    [WatchdogWin32.DisplayAPI]::GetWindowRect($hwnd, [ref]$winRect) | Out-Null

    $hMonitor = [WatchdogWin32.DisplayAPI]::MonitorFromWindow($hwnd, $MONITOR_NEAREST)
    $mi = New-Object WatchdogWin32.DisplayAPI+MONITORINFO
    $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mi)
    [WatchdogWin32.DisplayAPI]::GetMonitorInfo($hMonitor, [ref]$mi) | Out-Null

    $mLeft = $mi.rcMonitor.left
    $mTop = $mi.rcMonitor.top
    $mWidth = $mi.rcMonitor.right - $mi.rcMonitor.left
    $mHeight = $mi.rcMonitor.bottom - $mi.rcMonitor.top

    $isFullscreen = (
        [Math]::Abs($winRect.left - $mLeft) -le $WD_FULLSCREEN_TOLERANCE_PX -and
        [Math]::Abs($winRect.top - $mTop) -le $WD_FULLSCREEN_TOLERANCE_PX -and
        [Math]::Abs(($winRect.right - $winRect.left) - $mWidth) -le $WD_FULLSCREEN_TOLERANCE_PX -and
        [Math]::Abs(($winRect.bottom - $winRect.top) - $mHeight) -le $WD_FULLSCREEN_TOLERANCE_PX
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
            $shortcut.Arguments -eq "`"$launcherPath`"" -and
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
        $shortcut.Arguments = "`"$launcherPath`""
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
        [bool]$StartWithWindows = $Script:StartWithWindows
    )

    if ($null -eq $AppConfigurations -or $AppConfigurations.Count -eq 0) {
        throw "请至少添加一个要监控的程序。"
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
        Version          = 3
        StartWithWindows = $StartWithWindows
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

    if ($newApps.Count -eq 0) {
        throw "请至少添加一个要监控的程序。"
    }
    return $newApps
}

function WdResetMonitoringState {
    foreach ($variableName in @(
            "RestartStats", "LaunchTime", "DisplayRepairDone", "FocusLastTime",
            "LastStartAttempt", "LastStartedProcessId", "ThrottleWarned", "MissingLogged",
            "HangFailCount", "FastExitFailCount", "FastExitHandledLaunch", "ScheduledLaunch",
            "DisplayChangeRestartInProgress"
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
    param($Entries, [bool]$StartWithWindows)

    $newApps = WdConvertConfigurationEntriesToApps -Entries $Entries
    WdSaveUserConfiguration -AppConfigurations $newApps -StartWithWindows $StartWithWindows
    WdSetStartupEnabled -Enabled $StartWithWindows
    $script:Apps = $newApps
    $Script:ConfigWasLoaded = $true
    $Script:ConfigLoadError = $null
    $Script:AutoDiscoveredTarget = $false
    $Script:StartWithWindows = $StartWithWindows
    WdResetMonitoringState
    WdWriteLog "UI: Saved $($newApps.Count) monitoring target(s)." "DarkGreen"
}

function WdRequestElevatedRestart {
    if (WdTestIsAdministrator) {
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
        $Script:ExitRequested = $true
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
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "$Operation 需要管理员权限。是否现在授权并重启守护进程？",
        "需要管理员授权",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        [void](WdRequestElevatedRestart)
    }
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

    $form = New-Object System.Windows.Forms.Form
    $form.Text = if ($FirstRun) { "首次设置守护程序" } else { "守护程序设置" }
    $form.StartPosition = "CenterScreen"
    $form.ClientSize = New-Object System.Drawing.Size(980, 620)
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.FormBorderStyle = "FixedDialog"
    $form.TopMost = $true
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $form.BackColor = [System.Drawing.Color]::White
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

    $title = New-Object System.Windows.Forms.Label
    $title.Text = if ($FirstRun) { "选择要启动和监控的程序" } else { "启动程序设置" }
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(22, 18)
    $title.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 13, [System.Drawing.FontStyle]::Bold)
    [void]$form.Controls.Add($title)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = "可同时管理多个程序；配置文件与 Watchdog.ps1 放在同一目录，便于复制部署。"
    $hint.AutoSize = $true
    $hint.Location = New-Object System.Drawing.Point(24, 49)
    $hint.ForeColor = [System.Drawing.Color]::DimGray
    [void]$form.Controls.Add($hint)

    $listLabel = New-Object System.Windows.Forms.Label
    $listLabel.Text = "启动程序列表"
    $listLabel.AutoSize = $true
    $listLabel.Location = New-Object System.Drawing.Point(22, 84)
    $listLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
    [void]$form.Controls.Add($listLabel)

    $list = New-Object System.Windows.Forms.ListView
    $list.View = [System.Windows.Forms.View]::Details
    $list.FullRowSelect = $true
    $list.GridLines = $false
    $list.HideSelection = $false
    $list.MultiSelect = $false
    $list.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $list.Location = New-Object System.Drawing.Point(22, 108)
    $list.Size = New-Object System.Drawing.Size(390, 402)
    $list.Anchor = "Top,Bottom,Left"
    [void]$list.Columns.Add("程序", 125)
    [void]$list.Columns.Add("路径", 145)
    [void]$list.Columns.Add("状态", 60)
    [void]$list.Columns.Add("置顶", 55)
    [void]$form.Controls.Add($list)

    $add = New-Object System.Windows.Forms.Button
    $add.Text = "添加程序..."
    $add.Location = New-Object System.Drawing.Point(22, 520)
    $add.Size = New-Object System.Drawing.Size(105, 32)
    $add.Anchor = "Bottom,Left"
    $add.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $add.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(190, 198, 207)
    [void]$form.Controls.Add($add)

    $remove = New-Object System.Windows.Forms.Button
    $remove.Text = "删除"
    $remove.Location = New-Object System.Drawing.Point(136, 520)
    $remove.Size = New-Object System.Drawing.Size(78, 32)
    $remove.Anchor = "Bottom,Left"
    $remove.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $remove.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(190, 198, 207)
    [void]$form.Controls.Add($remove)

    $editorLabel = New-Object System.Windows.Forms.Label
    $editorLabel.Text = "程序配置"
    $editorLabel.AutoSize = $true
    $editorLabel.Location = New-Object System.Drawing.Point(438, 84)
    $editorLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
    [void]$form.Controls.Add($editorLabel)

    $pathLabel = New-Object System.Windows.Forms.Label
    $pathLabel.Text = "程序路径"
    $pathLabel.AutoSize = $true
    $pathLabel.Location = New-Object System.Drawing.Point(438, 112)
    [void]$form.Controls.Add($pathLabel)
    $pathBox = New-Object System.Windows.Forms.TextBox
    $pathBox.Location = New-Object System.Drawing.Point(510, 108)
    $pathBox.Size = New-Object System.Drawing.Size(340, 26)
    $pathBox.Anchor = "Top,Left,Right"
    [void]$form.Controls.Add($pathBox)
    $browse = New-Object System.Windows.Forms.Button
    $browse.Text = "浏览..."
    $browse.Location = New-Object System.Drawing.Point(858, 106)
    $browse.Size = New-Object System.Drawing.Size(92, 30)
    $browse.Anchor = "Top,Right"
    [void]$form.Controls.Add($browse)

    $argsLabel = New-Object System.Windows.Forms.Label
    $argsLabel.Text = "启动参数"
    $argsLabel.AutoSize = $true
    $argsLabel.Location = New-Object System.Drawing.Point(438, 151)
    [void]$form.Controls.Add($argsLabel)
    $argsBox = New-Object System.Windows.Forms.TextBox
    $argsBox.Location = New-Object System.Drawing.Point(510, 147)
    $argsBox.Size = New-Object System.Drawing.Size(440, 26)
    $argsBox.Anchor = "Top,Left,Right"
    [void]$form.Controls.Add($argsBox)

    $firstLabel = New-Object System.Windows.Forms.Label
    $firstLabel.Text = "首次启动延迟"
    $firstLabel.AutoSize = $true
    $firstLabel.Location = New-Object System.Drawing.Point(438, 190)
    [void]$form.Controls.Add($firstLabel)
    $firstBox = New-Object System.Windows.Forms.NumericUpDown
    $firstBox.Minimum = 0; $firstBox.Maximum = 86400; $firstBox.Width = 90
    $firstBox.Location = New-Object System.Drawing.Point(530, 186)
    [void]$form.Controls.Add($firstBox)
    $firstUnit = New-Object System.Windows.Forms.Label
    $firstUnit.Text = "秒"
    $firstUnit.AutoSize = $true
    $firstUnit.Location = New-Object System.Drawing.Point(625, 190)
    [void]$form.Controls.Add($firstUnit)

    $restartLabel = New-Object System.Windows.Forms.Label
    $restartLabel.Text = "异常重启延迟"
    $restartLabel.AutoSize = $true
    $restartLabel.Location = New-Object System.Drawing.Point(680, 190)
    [void]$form.Controls.Add($restartLabel)
    $restartBox = New-Object System.Windows.Forms.NumericUpDown
    $restartBox.Minimum = 0; $restartBox.Maximum = 86400; $restartBox.Width = 90
    $restartBox.Location = New-Object System.Drawing.Point(772, 186)
    [void]$form.Controls.Add($restartBox)
    $restartUnit = New-Object System.Windows.Forms.Label
    $restartUnit.Text = "秒"
    $restartUnit.AutoSize = $true
    $restartUnit.Location = New-Object System.Drawing.Point(867, 190)
    [void]$form.Controls.Add($restartUnit)

    $minLabel = New-Object System.Windows.Forms.Label
    $minLabel.Text = "最短运行时间"
    $minLabel.AutoSize = $true
    $minLabel.Location = New-Object System.Drawing.Point(438, 229)
    [void]$form.Controls.Add($minLabel)
    $minBox = New-Object System.Windows.Forms.NumericUpDown
    $minBox.Minimum = 0; $minBox.Maximum = 86400; $minBox.Width = 90
    $minBox.Location = New-Object System.Drawing.Point(530, 225)
    [void]$form.Controls.Add($minBox)
    $minUnit = New-Object System.Windows.Forms.Label
    $minUnit.Text = "秒（快速退出判定）"
    $minUnit.AutoSize = $true
    $minUnit.Location = New-Object System.Drawing.Point(625, 229)
    [void]$form.Controls.Add($minUnit)

    $options = @(
        @{ Text = "窗口置顶（全局单选）"; Key = "FocusTop" },
        @{ Text = "全屏模式"; Key = "Fullscreen" },
        @{ Text = "强制显示模式"; Key = "ForceDisplayMode" },
        @{ Text = "隐藏窗口启动"; Key = "HideWindow" },
        @{ Text = "隐藏鼠标光标"; Key = "HideCursor" },
        @{ Text = "仅启动一次"; Key = "Once" },
        @{ Text = "异常时结束进程树"; Key = "KillTreeOnHang" },
        @{ Text = "显示器变化时重启"; Key = "RestartOnDisplayChange" },
        @{ Text = "允许多实例"; Key = "AllowMultiInstance" }
    )
    $checkBoxes = @{}
    for ($optionIndex = 0; $optionIndex -lt $options.Count; $optionIndex++) {
        $option = $options[$optionIndex]
        $check = New-Object System.Windows.Forms.CheckBox
        $check.Text = $option.Text
        $check.AutoSize = $true
        $check.Location = New-Object System.Drawing.Point((438 + (($optionIndex % 2) * 245)), (267 + ([int]($optionIndex / 2) * 29)))
        [void]$form.Controls.Add($check)
        $checkBoxes[$option.Key] = $check
    }

    $status = New-Object System.Windows.Forms.Label
    $status.AutoSize = $false
    $status.Size = New-Object System.Drawing.Size(928, 30)
    $status.Location = New-Object System.Drawing.Point(22, 560)
    $status.Anchor = "Bottom,Left,Right"
    $status.ForeColor = [System.Drawing.Color]::DarkGoldenrod
    if ($Script:ConfigLoadError) { $status.Text = "配置文件无法读取，请检查列表后重新保存。" }
    elseif ($FirstRun) { $status.Text = "首次运行请添加至少一个程序。" }
    [void]$form.Controls.Add($status)

    $autoStart = New-Object System.Windows.Forms.CheckBox
    $autoStart.Text = "自动启动"
    $autoStart.AutoSize = $true
    $autoStart.Checked = [bool]$Script:StartWithWindows
    $autoStart.Location = New-Object System.Drawing.Point(438, 520)
    $autoStart.Anchor = "Bottom,Left"
    [void]$form.Controls.Add($autoStart)

    $elevate = New-Object System.Windows.Forms.Button
    $elevate.Text = "管理员授权"
    $elevate.Location = New-Object System.Drawing.Point(640, 516)
    $elevate.Size = New-Object System.Drawing.Size(105, 32)
    $elevate.Anchor = "Bottom,Right"
    $elevate.Visible = -not (WdTestIsAdministrator)
    $elevate.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $elevate.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(190, 142, 50)
    [void]$form.Controls.Add($elevate)

    $save = New-Object System.Windows.Forms.Button
    $save.Text = "保存全部"
    $save.Location = New-Object System.Drawing.Point(755, 516)
    $save.Size = New-Object System.Drawing.Size(95, 32)
    $save.Anchor = "Bottom,Right"
    $save.BackColor = [System.Drawing.Color]::FromArgb(28, 102, 196)
    $save.ForeColor = [System.Drawing.Color]::White
    $save.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $save.FlatAppearance.BorderSize = 0
    [void]$form.Controls.Add($save)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = if ($FirstRun) { "退出" } else { "取消" }
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancel.Location = New-Object System.Drawing.Point(858, 516)
    $cancel.Size = New-Object System.Drawing.Size(92, 32)
    $cancel.Anchor = "Bottom,Right"
    $cancel.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $cancel.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(190, 198, 207)
    [void]$form.Controls.Add($cancel)

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
            WdApplyAppConfigurations -Entries $entries -StartWithWindows $autoStart.Checked
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
    $elevate.Add_Click({
        try {
            [void](& $saveEditor)
            WdApplyAppConfigurations -Entries $entries -StartWithWindows $autoStart.Checked
            $form.Tag = "saved"
        }
        catch {
            $status.ForeColor = [System.Drawing.Color]::Firebrick
            $status.Text = "保存失败：$($_.Exception.Message)"
            WdWriteLog "UI: Saving before elevation failed - $($_.Exception.Message)" "DarkYellow"
        }
        [void](WdRequestElevatedRestart)
        if ($Script:ExitRequested) { $form.Close() }
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
    $needsSetup = (-not $Script:ConfigWasLoaded) -or (-not $hasValidTarget)

    if (-not $needsSetup) { return $true }

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
                $Script:ExitRequested = $true
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
    if (-not $Script:TrayNotifyIcon) { return }
    try { [System.Windows.Forms.Application]::DoEvents() } catch {}
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
        WdSaveUserConfiguration -AppConfigurations $Apps -StartWithWindows $Script:StartWithWindows
        $Script:AutoDiscoveredTarget = $false
        WdWriteLog "UI: Local executable auto-detected and saved." "DarkGreen"
    }
    WdSetStartupEnabled -Enabled $Script:StartWithWindows
}
catch {
    WdWriteLog "UI: Configuration/startup synchronization failed - $($_.Exception.Message)" "Red"
    WdOfferAuthorizationForError -Exception $_.Exception -Operation "保存配置或设置开机自启动"
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
WdWriteLog "INFO: Disable flag path = $DisableFlag" "DarkGray"
WdWriteLog "INFO: Task Manager open state is treated as disable flag" "DarkGray"
WdWriteLog "INFO: Check interval = $CheckInterval sec, Max retry/hour = $MaxRetryInHour" "DarkGray"
WdWriteLog "INFO: Log max size = ${MaxLogSizeMB}MB, Backups = $MaxLogBackups" "DarkGray"
WdWriteLog "INFO: GC collect every $GCCollectEvery iterations (~$($GCCollectEvery * $CheckInterval) sec)" "DarkGray"
WdWriteLog "INFO: Min restart gap = $MinRestartGapSeconds sec, Display loop repair = $DisplayLoopRepair" "DarkGray"
WdWriteLog "INFO: Hang restart threshold = $HangConsecutiveFailuresToRestart consecutive failures" "DarkGray"
WdWriteLog "INFO: Display change debounce = $DisplayChangeDebounceSeconds sec" "DarkGray"
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
$DisplayTopologyFingerprint = WdGetDisplayTopologyFingerprint
$PendingDisplayTopologyFingerprint = $null
$DisplayChangeDetectedAt = $null
$DisplayChangeRestartInProgress = @{}
if ($DisplayTopologyFingerprint) {
    WdWriteLog "DISPLAY-CHANGE: Initial topology fingerprint = [$DisplayTopologyFingerprint]" "DarkGray"
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
                $currentDisplayTopology = WdGetDisplayTopologyFingerprint
                if ($currentDisplayTopology) {
                    $DisplayTopologyFingerprint = $currentDisplayTopology
                    $PendingDisplayTopologyFingerprint = $null
                    $DisplayChangeDetectedAt = $null
                    $DisplayChangeRestartInProgress.Clear()
                }
                $FirstRun = $false
                WdWaitWithControlPolling -Milliseconds ($CheckInterval * 1000)
                continue
            }

            $anyCursorHideNeeded = $false
            $monitoringPaused = $false

            $currentDisplayTopology = WdGetDisplayTopologyFingerprint
            if ($currentDisplayTopology) {
                if ([string]::IsNullOrWhiteSpace($DisplayTopologyFingerprint)) {
                    $DisplayTopologyFingerprint = $currentDisplayTopology
                    WdWriteLog "DISPLAY-CHANGE: Topology baseline captured = [$DisplayTopologyFingerprint]" "DarkGray"
                }
                elseif ($currentDisplayTopology -ne $DisplayTopologyFingerprint) {
                    if ($PendingDisplayTopologyFingerprint -ne $currentDisplayTopology) {
                        $PendingDisplayTopologyFingerprint = $currentDisplayTopology
                        $DisplayChangeDetectedAt = Get-Date
                        WdWriteLog "DISPLAY-CHANGE: Topology changed; waiting $DisplayChangeDebounceSeconds sec for stability. Old=[$DisplayTopologyFingerprint] New=[$currentDisplayTopology]" "Yellow"
                    }
                    elseif ($DisplayChangeDetectedAt -and
                        ((Get-Date) - $DisplayChangeDetectedAt).TotalSeconds -ge $DisplayChangeDebounceSeconds) {

                        WdWriteLog "DISPLAY-CHANGE: Topology stable; restarting enabled targets." "Yellow"
                        $restartCount = 0

                        foreach ($RestartPath in $Apps.Keys) {
                            $RestartConfig = $Apps[$RestartPath]
                            if (-not (WdIsDisplayChangeRestartEnabled -Config $RestartConfig)) {
                                continue
                            }

                            if (WdIsBrowserUrl -Path $RestartPath) {
                                try { $RestartFileName = "[$(([System.Uri]$RestartPath).Host)]" }
                                catch { $RestartFileName = $RestartPath }
                            }
                            else {
                                $RestartFileName = [System.IO.Path]::GetFileName($RestartPath)
                            }

                            $restartProcs = WdGetTargetProcess -Path $RestartPath
                            if (-not $restartProcs) {
                                WdWriteLog "DISPLAY-CHANGE: $RestartFileName is not running; existing monitor flow will launch it if needed." "DarkGray"
                                continue
                            }

                            $restartFirstProc = if ($restartProcs -is [array]) { $restartProcs[0] } else { $restartProcs }
                            $restartPid = WdGetProcessId $restartFirstProc
                            if (WdScheduleDisplayChangeRestart `
                                    -Path $RestartPath `
                                    -Config $RestartConfig `
                                    -FileName $RestartFileName `
                                    -ProcessId $restartPid `
                                    -ScheduledLaunch $ScheduledLaunch `
                                    -LaunchTime $LaunchTime `
                                    -DisplayRepairDone $DisplayRepairDone `
                                    -HangFailCount $HangFailCount `
                                    -DisplayChangeRestartInProgress $DisplayChangeRestartInProgress) {
                                $restartCount++
                            }

                            if ($restartProcs) {
                                $restartProcs | ForEach-Object {
                                    WdDisposeProcessResult $_
                                }
                            }
                        }

                        WdWriteLog "DISPLAY-CHANGE: Restart scheduling complete. Targets restarted=$restartCount." "DarkGreen"
                        $DisplayTopologyFingerprint = $currentDisplayTopology
                        $PendingDisplayTopologyFingerprint = $null
                        $DisplayChangeDetectedAt = $null
                    }
                }
                elseif ($PendingDisplayTopologyFingerprint) {
                    WdWriteLog "DISPLAY-CHANGE: Topology returned to baseline before debounce elapsed; restart canceled." "DarkGray"
                    $PendingDisplayTopologyFingerprint = $null
                    $DisplayChangeDetectedAt = $null
                }
            }

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
                    $currentDisplayTopology = WdGetDisplayTopologyFingerprint
                    if ($currentDisplayTopology) {
                        $DisplayTopologyFingerprint = $currentDisplayTopology
                        $PendingDisplayTopologyFingerprint = $null
                        $DisplayChangeDetectedAt = $null
                        $DisplayChangeRestartInProgress.Clear()
                    }
                    $monitoringPaused = $true
                    break
                }

                $allowMultiInstance = if ($Config.ContainsKey("AllowMultiInstance")) { [bool]$Config.AllowMultiInstance } else { $false }
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
    WdDisposeTrayIcon
    WdStopControlListeners
    WdCloseLogWriter
    try { WdRestoreSystemCursor } catch {}

    if ($Script:MutexOwned) {
        try { $Script:Mutex.ReleaseMutex() } catch {}
    }
    try { $Script:Mutex.Dispose() } catch {}
}
