# Run with Windows PowerShell 5.1 or PowerShell 7. No watchdog, target processes,
# network listeners, display changes, or real process termination are started.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Watchdog.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$source = [IO.File]::ReadAllText($scriptPath)
foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}
$constantNames = @('DisplayChangeDebounceSeconds', 'UnityDisplayStartupGraceSeconds', 'UnityDisplayMismatchChecks',
    'UnityDisplayRepairGraceSeconds', 'DisplayRecoveryCooldownSeconds', 'MaxRetryInHour', 'WD_FULLSCREEN_TOLERANCE_PX')
foreach ($assignment in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    if ($assignment.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $constantNames -contains $assignment.Left.VariablePath.UserPath) {
        . ([scriptblock]::Create($assignment.Extent.Text))
    }
}
$script:logMessages = @()
function WdWriteLog { param($Message, $Color) $script:logMessages += $Message }
$script:assertions = 0
function Assert { param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:assertions++
}

# Compile the exact embedded C# and smoke-test read-only native mode enumeration.
$apiAssignment = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$displayApiCode'
}, $true)
. ([scriptblock]::Create($apiAssignment.Extent.Text))
Add-Type -TypeDefinition $displayApiCode -Language CSharp
Assert ([Runtime.InteropServices.Marshal]::SizeOf([type]'WatchdogWin32.DisplayAPI+DEVMODEW') -eq 220) 'DEVMODEW ABI size'
$fingerprint = WdGetDisplayTopologyFingerprint
if ($fingerprint) {
    Assert ($fingerprint -match 'mode=\d+x\d+\|rotation=[0-3]') 'Native resolution and rotation query'
    Write-Output "Native display query: $fingerprint"
}
else { Write-Output 'Native display query unavailable in this session; no display was changed.' }

# Create only the invisible listener. Test messages go exclusively to its own HWND,
# never HWND_BROADCAST; these do not change display resolution or monitor power.
WdInitializeDisplayEventMonitor
Assert ($null -ne $Script:DisplayEventMonitor) ("Hidden event listener compiles and starts: " + ($script:logMessages -join '; '))
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DisplayRecoveryTestMessages {
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
}
'@
$listener = $Script:DisplayEventMonitor
$powerData = [Runtime.InteropServices.Marshal]::AllocHGlobal(24)
try {
    Assert (-not [WatchdogWin32.DisplayAPI]::IsWindowVisible($listener.Handle)) 'Listener never shows a window'
    [Runtime.InteropServices.Marshal]::StructureToPtr([guid]'2B84C20E-AD23-4DDF-93DB-05FFBD7EFCA5', $powerData, $false)
    [Runtime.InteropServices.Marshal]::WriteInt32($powerData, 16, 4)
    [Runtime.InteropServices.Marshal]::WriteInt32($powerData, 20, 1)
    [void][DisplayRecoveryTestMessages]::SendMessage($listener.Handle, 0x218, [intptr]0x8013, $powerData)
    Assert (-not (WdConsumeDisplayEvent)) 'Initial monitor state does not cause a restart'
    [Runtime.InteropServices.Marshal]::WriteInt32($powerData, 20, 0)
    [void][DisplayRecoveryTestMessages]::SendMessage($listener.Handle, 0x218, [intptr]0x8013, $powerData)
    Assert (-not (WdConsumeDisplayEvent)) 'Power-off alone does not restart targets'
    [Runtime.InteropServices.Marshal]::WriteInt32($powerData, 20, 1)
    [void][DisplayRecoveryTestMessages]::SendMessage($listener.Handle, 0x218, [intptr]0x8013, $powerData)
    Assert (WdConsumeDisplayEvent) 'Power-on is detected without a resolution change'
    Assert (-not (WdConsumeDisplayEvent)) 'Power event is consumed exactly once'
    [void][DisplayRecoveryTestMessages]::SendMessage($listener.Handle, 0x7E, [intptr]32, [intptr]0)
    [void][DisplayRecoveryTestMessages]::SendMessage($listener.Handle, 0x7E, [intptr]32, [intptr]0)
    Assert (WdConsumeDisplayEvent) 'Short display-change notifications survive between polls'
    Assert (-not (WdConsumeDisplayEvent)) 'Notification burst is coalesced'
    $Script:DisplayEventQuietUntil = (Get-Date).AddSeconds(20)
    [void][DisplayRecoveryTestMessages]::SendMessage($listener.Handle, 0x7E, [intptr]32, [intptr]0)
    Assert (-not (WdConsumeDisplayEvent)) 'Unity startup mode notifications cannot create a restart loop'
    $Script:DisplayEventQuietUntil = [DateTime]::MinValue
    [void][DisplayRecoveryTestMessages]::SendMessage($listener.Handle, 0x7E, [intptr]32, [intptr]0)
    Assert (WdConsumeDisplayEvent) 'Display notifications resume after recovery grace'
}
finally {
    [Runtime.InteropServices.Marshal]::FreeHGlobal($powerData)
    $listener.Dispose()
    $Script:DisplayEventMonitor = $null
}

# Physical client coordinates, including portrait and secondary monitor offsets.
Assert (WdTestFullscreenClientBounds 0 0 1080 1920 0 0 1080 1920) 'Portrait fullscreen is healthy'
Assert (-not (WdTestFullscreenClientBounds 0 0 1920 1080 0 0 1080 1920)) 'Landscape window on portrait display'
Assert (-not (WdTestFullscreenClientBounds 0 0 720 1280 0 0 1080 1920)) 'Top-left partial screen / DPI-sized window'
Assert (WdTestFullscreenClientBounds -1080 100 1080 1920 -1080 100 1080 1920) 'Negative secondary monitor origin'
Assert (-not (WdTestFullscreenClientBounds 0 0 1080 1920 -1080 0 1080 1920)) 'Correct size at wrong position'
Assert (WdTestFullscreenClientBounds 2 2 1078 1918 0 0 1080 1920) 'Small pixel tolerance'
Assert (-not (WdTestFullscreenClientBounds 0 0 0 0 0 0 0 0)) 'Unavailable geometry is never healthy'

$time = [datetime]'2026-01-01T00:00:00'
$state = @{ Baseline = 'portrait'; Pending = $null; ChangedAt = $null }
Assert (-not (WdUpdateDisplayTopologyState $state 'portrait' $time)) 'Unchanged topology'
Assert (-not (WdUpdateDisplayTopologyState $state 'landscape' $time)) 'Start debounce'
Assert (-not (WdUpdateDisplayTopologyState $state 'portrait' $time.AddSeconds(3))) 'Returning to baseline still requires recovery'
Assert (-not (WdUpdateDisplayTopologyState $state 'portrait' $time.AddSeconds(12))) 'Restart debounce on latest change'
Assert (WdUpdateDisplayTopologyState $state 'portrait' $time.AddSeconds(13)) 'Recover once after transient change'
Assert (-not (WdUpdateDisplayTopologyState $state 'portrait' $time.AddSeconds(30))) 'No repeated event after stability'
Assert (-not (WdUpdateDisplayTopologyState $state '' $time.AddSeconds(31))) 'Unavailable sample cannot trigger recovery'
Assert (-not (WdUpdateDisplayTopologyState $state 'portrait' $time.AddSeconds(60))) 'Reconnect starts fresh debounce'
Assert (WdUpdateDisplayTopologyState $state 'portrait' $time.AddSeconds(70)) 'Reconnect to original mode triggers recovery'
$state = @{ Baseline = '1080x1920|rotation=1'; Pending = $null; ChangedAt = $null }
Assert (-not (WdUpdateDisplayTopologyState $state '1080x1920|rotation=3' $time)) 'Same dimensions with changed rotation'
Assert (WdUpdateDisplayTopologyState $state '1080x1920|rotation=3' $time.AddSeconds(10)) 'Rotation-only change confirmed'
$state = @{ Baseline = 'portrait'; Pending = $null; ChangedAt = $null }
Assert (-not (WdUpdateDisplayTopologyState $state 'portrait' $time $true)) 'Same-resolution display event starts debounce'
Assert (-not (WdUpdateDisplayTopologyState $state 'portrait' $time.AddSeconds(9))) 'No premature event restart'
Assert (WdUpdateDisplayTopologyState $state 'portrait' $time.AddSeconds(10)) 'Same-resolution power-on event triggers recovery'

$states = @{}
$bad = @{ Matches = $false; Details = 'client=1920x1080; monitor=1080x1920' }
$good = @{ Matches = $true; Details = 'client=1080x1920; monitor=1080x1920' }
Assert (-not (WdUpdateFullscreenHealth $states app 123 $bad $true $time)) 'New PID gets startup grace'
Assert (-not (WdUpdateFullscreenHealth $states app 123 $bad $true $time.AddSeconds(19))) 'Startup splash is ignored'
Assert (-not (WdUpdateFullscreenHealth $states app 123 $bad $true $time.AddSeconds(20))) 'First mismatch'
Assert (-not (WdUpdateFullscreenHealth $states app 123 $bad $true $time.AddSeconds(23))) 'Second mismatch'
Assert (WdUpdateFullscreenHealth $states app 123 $bad $true $time.AddSeconds(26)) 'Third mismatch requests recovery'
$states.app.RepairAt = $time.AddSeconds(26)
Assert (-not (WdUpdateFullscreenHealth $states app 123 $bad $true $time.AddSeconds(29))) 'Wait for Unity after fullscreen refresh'
Assert (-not (WdUpdateFullscreenHealth $states app 123 $good $true $time.AddSeconds(32))) 'Successful repair avoids restart'
Assert ($null -eq $states.app.RepairAt -and $states.app.Failures -eq 0) 'Successful repair clears escalation'
[void](WdUpdateFullscreenHealth $states app 123 $bad $true $time.AddSeconds(35))
Assert (-not (WdUpdateFullscreenHealth $states app 123 $null $true $time.AddSeconds(38))) 'Missing/minimized window resets consecutive checks'
Assert ($states.app.Failures -eq 0) 'Unknown sample is not a failure'
[void](WdUpdateFullscreenHealth $states app 123 $bad $true $time.AddSeconds(41))
Assert (-not (WdUpdateFullscreenHealth $states app 123 $bad $false $time.AddSeconds(44))) 'Unstable display resets failures'
Assert ($states.app.Failures -eq 0) 'No accumulated failures through display change'
Assert (-not (WdUpdateFullscreenHealth $states app 456 $bad $true $time.AddSeconds(47))) 'Replacement PID gets fresh grace'

Assert (WdCanScheduleDisplayRecovery app @{} @{} 0 $time) 'First restart allowed'
Assert (-not (WdCanScheduleDisplayRecovery app @{ app = $time } @{} 0 $time.AddSeconds(59))) 'Cooldown enforced'
Assert (WdCanScheduleDisplayRecovery app @{ app = $time } @{} 0 $time.AddSeconds(60)) 'Cooldown expires'
Assert (-not (WdCanScheduleDisplayRecovery app @{} @{ app = @{} } 0 $time)) 'Do not overlap pending stop'
Assert (-not (WdCanScheduleDisplayRecovery app @{} @{} $MaxRetryInHour $time)) 'Do not kill a target when relaunch is throttled'

# File detection mock: do not create a real Unity installation or executable.
function Test-Path { param($LiteralPath, $PathType) return ($LiteralPath -match '(UnityPlayer\.dll|Demo_Data)$') }
$unityPath = 'C:\DisplayRecoveryTest\Demo.exe'
$config = WdNewAppConfiguration $null
Assert (WdIsUnityDisplayRecoveryEnabled $unityPath $config) 'Existing Unity configs gain recovery by default'
Assert (WdIsDisplayChangeRestartEnabled $config $unityPath) 'Unity recovery does not require legacy restart switch'
Assert (-not (WdIsUnityDisplayRecoveryEnabled 'C:\DisplayRecoveryTest\Other.exe' $config)) 'Other executables are untouched'
foreach ($setting in @('Once', 'HideWindow', 'AllowMultiInstance')) {
    $config[$setting] = $true
    Assert (-not (WdIsUnityDisplayRecoveryEnabled $unityPath $config)) "Respect $setting"
    $config[$setting] = $false
}
$config.ForceDisplayMode = $true
Assert (-not (WdIsUnityDisplayRecoveryEnabled $unityPath $config)) 'Respect explicitly forced windowed mode'
$config.ForceDisplayMode = $false
$config.UnityDisplayRecovery = $false
Assert (-not (WdIsUnityDisplayRecoveryEnabled $unityPath $config)) 'User can disable recovery'
$config.RestartOnDisplayChange = $true
Assert (WdIsUnityDisplayRecoveryEnabled $unityPath $config) 'Legacy restart option independently enables Unity fullscreen checks'

# Execute the production recovery decision block with native side effects mocked.
$begin = $source.IndexOf('                        $fullscreenMismatch = $false')
$end = $source.IndexOf('                        if ($isExe -and -not $mainProc.Responding)', $begin)
Assert ($begin -ge 0 -and $end -gt $begin) 'Locate production recovery block'
$recoveryBlock = [scriptblock]::Create($source.Substring($begin, $end - $begin))
$script:repairCalls = 0
$script:stopCalls = 0
function WdGetFullscreenObservation { param($ProcessObj) return $script:testObservation }
function WdRepairWindowDisplayMode { param($ProcessObj, $Fullscreen, [switch]$ForceRefresh)
    Assert ($Fullscreen -and $ForceRefresh) 'Repair reapplies current fullscreen bounds'
    $script:repairCalls++
    return $true
}
function WdStopProcessTreeSafe { param($ProcessId, $KillTree)
    Assert ($ProcessId -eq 123) 'Only the configured target PID is stopped'
    $script:stopCalls++
    return $true
}
function Invoke-RecoveryCycle { foreach ($tick in @(1)) { . $recoveryBlock } }
$Path = $unityPath
$Config = WdNewAppConfiguration $null
$FileName = 'Demo.exe'
$TargetID = 123
$StatKey = 'Demo::H0'
$mainProc = $null
$unityDisplayRecovery = $true
$displayStable = $true
$FullscreenHealth = @{}
$DisplayRecoveryPending = @{}
$DisplayRecoveryLastAttempt = @{}
$DisplayChangeRestartInProgress = @{}
$RestartStats = @{ $StatKey = 0 }
$ScheduledLaunch = @{}
$LaunchTime = @{ $Path = (Get-Date) }
$DisplayRepairDone = @{}
$HangFailCount = @{}
$script:testObservation = $bad
[void](WdUpdateFullscreenHealth $FullscreenHealth $Path $TargetID $bad $true (Get-Date).AddSeconds(-60))
1..3 | ForEach-Object { Invoke-RecoveryCycle }
Assert ($script:repairCalls -eq 1 -and $script:stopCalls -eq 0) 'Persistent mismatch refreshes first without stopping Unity'
Invoke-RecoveryCycle
Assert ($script:stopCalls -eq 0) 'No immediate restart while Unity processes resize'
$script:testObservation = $good
Invoke-RecoveryCycle
Assert ($script:stopCalls -eq 0) 'Recovered fullscreen keeps original process'
$DisplayRecoveryPending[$Path] = $true
Invoke-RecoveryCycle
Assert ($script:repairCalls -eq 2 -and $script:stopCalls -eq 0) 'Stable topology change refreshes even an already full-size window'
$script:testObservation = $bad
$FullscreenHealth[$Path].RepairAt = (Get-Date).AddSeconds(-10)
1..3 | ForEach-Object { Invoke-RecoveryCycle }
Assert ($script:stopCalls -eq 1) 'Failed refresh escalates to one restart'
Assert ($ScheduledLaunch.ContainsKey($Path) -and $DisplayChangeRestartInProgress.ContainsKey($Path)) 'Restart uses existing stop-and-relaunch tracking'
Assert (-not $LaunchTime.ContainsKey($Path)) 'Planned restart is not counted as a fast crash'
$DisplayRecoveryPending[$Path] = $true
Invoke-RecoveryCycle
Assert ($script:stopCalls -eq 1) 'Pending exit and cooldown prevent repeated stop'
$DisplayChangeRestartInProgress.Clear()
$DisplayRecoveryLastAttempt.Clear()
$RestartStats[$StatKey] = $MaxRetryInHour
Invoke-RecoveryCycle
Assert ($script:stopCalls -eq 1 -and $DisplayRecoveryPending.ContainsKey($Path)) 'Rate-limited topology recovery preserves request and running process'
$RestartStats[$StatKey] = 0
$Config.RestartOnDisplayChange = $true
$script:testObservation = $good
Invoke-RecoveryCycle
Assert ($script:stopCalls -eq 2 -and $script:repairCalls -eq 2) 'Explicit legacy restart option remains honored'
Assert (-not $DisplayRecoveryPending.ContainsKey($Path)) 'Successful scheduling consumes pending request'

# Previously missed case: Windows reports unchanged display parameters, Unity is
# still landscape in the corner, and only RestartOnDisplayChange is enabled.
$Config.UnityDisplayRecovery = $false
$unityDisplayRecovery = WdIsUnityDisplayRecoveryEnabled $Path $Config
$DisplayChangeRestartInProgress.Clear()
$DisplayRecoveryLastAttempt.Clear()
$FullscreenHealth.Clear()
$script:testObservation = $bad
[void](WdUpdateFullscreenHealth $FullscreenHealth $Path $TargetID $bad $true (Get-Date).AddSeconds(-60))
1..3 | ForEach-Object { Invoke-RecoveryCycle }
Assert ($script:stopCalls -eq 3 -and $script:repairCalls -eq 2) 'Legacy option directly restarts a persistent fullscreen mismatch without any topology event'

# Unattended permission failures must only be logged, never prompt or elevate.
function WdRequestElevatedRestart { throw 'Unattended recovery attempted an elevation prompt' }
$Script:UserInteractionActive = $false
$Unattended = $true
WdOfferAuthorizationForError -Exception (New-Object ComponentModel.Win32Exception(5)) -Operation 'recovery test'
Assert ($script:logMessages[-1] -like '*authorization deferred*') 'Unattended launch failure logs without prompting'
Write-Output "PASS: $script:assertions assertions; no real programs restarted."
