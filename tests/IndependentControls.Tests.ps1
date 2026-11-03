# Run in a fresh Windows PowerShell 5.1 / PowerShell 7 process.
# Native window calls are mocked; loopback UDP is real. No target or power action runs.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Watchdog.ps1'
$script:productionRoot = Split-Path $scriptPath -Parent
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text.Replace('$PSScriptRoot', '$script:productionRoot')))
}
$script:assertions = 0
function Assert { param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:assertions++
}
function WdWriteLog { param($Message, $Color) }
$constantNames = @('GWL_EXSTYLE', 'WS_EX_TOPMOST', 'SWP_TOPMOST_FLAGS', 'SWP_NOACTIVATE',
    'SWP_NOSIZE', 'SWP_NOMOVE', 'HWND_TOPMOST', 'HWND_NOTOPMOST', 'FocusCooldownSeconds', 'MaxRetryInHour')
foreach ($assignment in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    if ($assignment.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $constantNames -contains $assignment.Left.VariablePath.UserPath) {
        . ([scriptblock]::Create($assignment.Extent.Text))
    }
}
Add-Type -TypeDefinition @'
using System;
namespace WatchdogWin32 {
    public static class DisplayAPI {
        public static int Style = 0;
        public static int TopmostCalls = 0;
        public static int ReleaseCalls = 0;
        public static int GetWindowLong(IntPtr window, int index) { return Style; }
        public static bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int w, int h, uint flags) {
            if (after == new IntPtr(-1)) { Style |= 8; TopmostCalls++; }
            if (after == new IntPtr(-2)) { Style &= ~8; ReleaseCalls++; }
            return true;
        }
    }
}
'@
$window = [pscustomobject]@{ Handle = [IntPtr]42 }
$Script:TopmostWindows = @{}
$Script:StartWithWindows = $true; $Script:DisableLockScreen = $false; $Script:EnableMagicWake = $true
$script:testProcess = [pscustomobject]@{ Id = 12345; ProcessId = 12345; MainWindowHandle = $window.Handle; StartTime = (Get-Date); Responding = $false }
$script:testProcess | Add-Member ScriptMethod Dispose { }
function WdWaitForWindowHandle { param($ProcessObj, $TimeoutMs) return $ProcessObj.MainWindowHandle }
# A foreground window must still receive TOPMOST if it lacks that style.
function WdIsWindowForeground { param($Hwnd) return $true }
function Get-Process { param($Id) return $script:testProcess }
function Test-Topmost { return (([WatchdogWin32.DisplayAPI]::GetWindowLong($window.Handle, $GWL_EXSTYLE) -band $WS_EX_TOPMOST) -ne 0) }

$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('Watchdog-controls-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testDirectory)
try {
    $config = WdNewAppConfiguration $null
    Assert $config.LaunchEnabled 'Existing targets keep automatic launch enabled'
    $config.LaunchEnabled = $false; $config.FocusTop = $true
    Assert (-not (WdIsDisplayChangeRestartEnabled $config 'C:\Demo.exe')) 'Passive targets cannot queue display restarts'
    Assert (-not (WdIsUnityDisplayRecoveryEnabled 'C:\Demo.exe' $config)) 'Passive targets do not recover/restart Unity'

    # Persistence plus the exact startup loader, including defaults for older JSON.
    $UserConfigPath = Join-Path $testDirectory 'watchdog.config.json'
    $Script:EnableUdpShutdown = $false
    WdSaveUserConfiguration -AppConfigurations ([ordered]@{ 'C:\Demo.exe' = $config }) -EnableUdpShutdown $false
    $saved = [IO.File]::ReadAllText($UserConfigPath) | ConvertFrom-Json
    Assert (-not $saved.EnableUdpShutdown -and -not $saved.Targets[0].LaunchEnabled -and $saved.Targets[0].FocusTop) 'Independent switches are saved'
    $load = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if ($configurationExists)')
    }, $true)
    $configurationExists = $true
    . ([scriptblock]::Create($load.Extent.Text))
    Assert ($Script:ConfigWasLoaded -and -not $Script:EnableUdpShutdown -and -not $Apps['C:\Demo.exe'].LaunchEnabled) 'Saved switches reload'
    [IO.File]::WriteAllText($UserConfigPath, '{"Version":4,"Targets":[{"Path":"C:\\Demo.exe","FocusTop":true}]}')
    . ([scriptblock]::Create($load.Extent.Text))
    Assert ($Script:EnableUdpShutdown -and $Apps['C:\Demo.exe'].LaunchEnabled) 'Old configurations retain launch and UDP defaults'

    # Real loopback datagrams go through the production polling/command path.
    $ControlEnabled = $true; $ControlMaxMessageBytes = 256; $ControlAllowedRemoteAddresses = @('127.0.0.1')
    $Script:ControlTcpListener = $null
    $Script:ControlUdpClient = [Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 0))
    $sender = [Net.Sockets.UdpClient]::new()
    $sender.Client.ReceiveTimeout = 2000
    function Send-TestUdp { param([string]$Command)
        $bytes = [Text.Encoding]::UTF8.GetBytes($Command)
        [void]$sender.Send($bytes, $bytes.Length, $Script:ControlUdpClient.Client.LocalEndPoint)
        $deadline = (Get-Date).AddSeconds(2)
        while ($Script:ControlUdpClient.Available -eq 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 5 }
        WdPollControlListeners
        $remote = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
        return [Text.Encoding]::UTF8.GetString($sender.Receive([ref]$remote)).Trim()
    }
    $Script:PendingSystemPowerAction = $null; $Script:EnableUdpShutdown = $false
    Assert ((Send-TestUdp ' ShUtDoWn ') -eq 'ERR UDP shutdown disabled') 'Disabled UDP shutdown is rejected'
    Assert ($null -eq $Script:PendingSystemPowerAction) 'Rejected UDP command does not queue a power action'
    Assert ((Send-TestUdp 'ping') -eq 'pong') 'UDP heartbeat still works'
    $Script:EnableUdpShutdown = $true
    Assert ((Send-TestUdp 'shutdown') -eq 'OK shutdown accepted') 'Enabled UDP shutdown is accepted'
    Assert ($Script:PendingSystemPowerAction -eq 'shutdown') 'Enabled command queues shutdown without executing it'
    $Script:PendingSystemPowerAction = $null; $Script:EnableUdpShutdown = $false
    Assert ((WdGetControlResponse shutdown TCP ([Net.IPAddress]::Loopback)) -eq 'OK shutdown accepted') 'TCP shutdown remains independent'
    $Script:PendingSystemPowerAction = $null
    Assert ((Send-TestUdp 'reboot') -eq 'OK reboot accepted') 'UDP reboot remains independent'
    $Script:PendingSystemPowerAction = $null
    $ControlAllowedRemoteAddresses = @('192.0.2.1')
    $Script:EnableUdpShutdown = $true
    Assert ((Send-TestUdp 'shutdown') -eq 'ERR source not allowed') 'Source restrictions still apply'
    Assert ($null -eq $Script:PendingSystemPowerAction) 'Unauthorized datagram cannot queue shutdown'

    # Execute the entire production per-target loop, including its cleanup.
    $targetLoop = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Extent.Text.StartsWith('foreach ($Path in $Apps.Keys)')
    }, $true)
    $cycle = [scriptblock]::Create($targetLoop.Extent.Text)
    function WdGetDisableReason { return $null }
    function WdUpdateDisableState { param($DisableReason) return $false }
    function WdGetTargetProcess { param($Path) return $script:externalProcesses }
    function WdLaunchAndTrack { throw 'Unexpected target launch' }
    function WdStopProcessTreeSafe { throw 'Unexpected target termination' }
    function WdRepairWindowDisplayMode { throw 'Unexpected display repair' }
    $CurrentHour = (Get-Date).Hour
    $RestartStats = @{}; $FocusLastTime = @{}; $ScheduledLaunch = @{}
    $DisplayChangeRestartInProgress = @{}; $LastStartedProcessId = @{}
    $Apps = [ordered]@{ 'C:\Demo.exe' = $config }
    $config.Once = $true; $config.HideWindow = $true; $config.RestartOnDisplayChange = $true
    $script:externalProcesses = @()
    . $cycle
    Assert (-not (Test-Topmost) -and $ScheduledLaunch.Count -eq 0) 'Missing passive target is never launched'
    $script:externalProcesses = @($script:testProcess)
    . $cycle
    Assert (Test-Topmost) 'External process becomes persistently topmost even when already foreground'
    Assert ($Script:TopmostWindows.Count -eq 1) 'Watchdog remembers the window it changed'
    WdReleaseTopmostWindows
    Assert (-not (Test-Topmost) -and $Script:TopmostWindows.Count -eq 0) 'Topmost is restored on release'
    $FocusLastTime.Clear(); $config.FocusTop = $false
    . $cycle
    Assert (-not (Test-Topmost)) 'Topmost can be disabled independently of launch'
    $config.FocusTop = $true
    $script:externalProcesses = @($script:testProcess, $script:testProcess)
    . $cycle
    Assert (Test-Topmost) 'Passive multiple instances and unresponsive targets are not terminated'
    WdReleaseTopmostWindows
    WdRestartTopmostApps
    Assert ($ScheduledLaunch.Count -eq 0) 'Remote restart skips externally managed targets'

    # Enabled targets still follow the existing launch scheduler without enabling topmost.
    $config.LaunchEnabled = $true; $config.FocusTop = $false; $config.Once = $false
    $config.RestartOnDisplayChange = $false
    $script:externalProcesses = @(); $FirstRun = $true; $displayStable = $true
    $HangFailCount = @{}; $FullscreenHealth = @{}; $DisplayRecoveryPending = @{}
    $LaunchTime = @{}; $FastExitHandledLaunch = @{}; $LastStartAttempt = @{}; $MissingLogged = @{}
    . $cycle
    Assert ($ScheduledLaunch.ContainsKey('C:\Demo.exe') -and -not (Test-Topmost)) 'Automatic launch schedules independently of topmost'

    # Saving the real settings applies both switches immediately, with host changes mocked.
    function WdSetStartupEnabled { param($Enabled) }
    function WdSetLockScreenDisabled { param($Disabled) }
    function WdApplyMagicWakeSettings { param($Enabled) }
    $config.LaunchEnabled = $false; $config.FocusTop = $true
    $script:externalProcesses = @($script:testProcess); $FocusLastTime.Clear()
    . $cycle
    Assert (Test-Topmost) 'Prepare a window owned by watchdog before applying new settings'
    $config.FocusTop = $false
    $entries = @([pscustomobject]@{ Path = $scriptPath; Config = $config })
    WdApplyAppConfigurations -Entries $entries -StartWithWindows $false -DisableLockScreen $false -EnableMagicWake $false -EnableUdpShutdown $false
    Assert (-not (Test-Topmost) -and $Script:TopmostWindows.Count -eq 0) 'Saving topmost off restores the existing window'
    Assert (-not $Script:EnableUdpShutdown -and -not $Apps[$scriptPath].LaunchEnabled) 'Saved settings immediately replace runtime settings'
    $ControlAllowedRemoteAddresses = @('127.0.0.1')
    Assert ((Send-TestUdp 'shutdown') -eq 'ERR UDP shutdown disabled') 'UDP shutdown is disabled immediately after saving'
    Write-Output "PASS: $script:assertions assertions; no target or system power action executed."
}
finally {
    WdReleaseTopmostWindows
    if ($sender) { $sender.Dispose() }
    if ($Script:ControlUdpClient) { $Script:ControlUdpClient.Dispose() }
    Remove-Item -LiteralPath $testDirectory -Recurse -Force
}
