# Run with Windows PowerShell 5.1 in an interactive Windows desktop session.
# Builds a temporary GUI EXE and launches it through the real watchdog launcher.
# Only the temporary test windows are closed; user configuration is not loaded.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Watchdog.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$constantNames = @('SWP_NOSIZE', 'SWP_NOMOVE', 'SWP_TOPMOST_FLAGS', 'SWP_NOACTIVATE', 'HWND_TOPMOST',
    'HWND_NOTOPMOST', 'GWL_EXSTYLE', 'WS_EX_TOPMOST', 'SW_RESTORE', 'VK_MENU', 'KEYEVENTF_KEYUP',
    'MOUSEEVENTF_MOVE', 'WD_WINDOW_HANDLE_POLL_MS', 'WD_FOCUS_SETTLE_MS', 'WD_INITIAL_FOCUS_DELAY_MS',
    'WD_FOCUS_WINDOW_HANDLE_TIMEOUT_MS', 'FocusCooldownSeconds')
foreach ($assignment in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    if ($assignment.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $constantNames -contains $assignment.Left.VariablePath.UserPath) {
        . ([scriptblock]::Create($assignment.Extent.Text))
    }
}
$api = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$displayApiCode'
}, $true)
. ([scriptblock]::Create($api.Extent.Text))
Add-Type -TypeDefinition $displayApiCode -Language CSharp
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TopmostTestAPI {
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr window, uint command);
}
'@
$Script:TopmostWindows = @{}; $Script:PathErrorLogged = @{}; $Script:ExitRequested = $false
$Script:UserInteractionActive = $false; $Unattended = $true
$script:assertions = 0
function Assert { param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:assertions++
    Write-Output "PASS: $Message"
}
function WdWriteLog { param($Message, $Color) Write-Host $Message }
function Get-TestWindowStyle { param($Process)
    $Process.Refresh()
    return [WatchdogWin32.DisplayAPI]::GetWindowLong($Process.MainWindowHandle, $GWL_EXSTYLE)
}
function Test-WindowAbove { param([IntPtr]$Upper, [IntPtr]$Lower)
    $current = $Lower
    for ($index = 0; $index -lt 1000; $index++) {
        $current = [TopmostTestAPI]::GetWindow($current, 3) # GW_HWNDPREV
        if ($current -eq $Upper) { return $true }
        if ($current -eq [IntPtr]::Zero) { return $false }
    }
    return $false
}
function Close-TestProcess { param($Process)
    if (-not $Process) { return }
    try {
        if (-not $Process.HasExited) {
            [void]$Process.CloseMainWindow()
            if (-not $Process.WaitForExit(3000)) { $Process.Kill(); [void]$Process.WaitForExit(3000) }
        }
    }
    finally { $Process.Dispose() }
}
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('Watchdog-exe-topmost-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testDirectory)
$exe = Join-Path $testDirectory 'WatchdogTopmostProbe.exe'
$target = $null; $cover = $null
try {
    Add-Type -OutputAssembly $exe -OutputType WindowsApplication -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Windows.Forms;
public static class WatchdogTopmostProbe {
    [STAThread] public static void Main(string[] args) {
        Application.EnableVisualStyles();
        Form form = new Form();
        bool cover = args.Length > 0;
        form.Text = cover ? "Watchdog test - ordinary covering window" : "Watchdog test - target EXE window";
        form.StartPosition = FormStartPosition.Manual;
        form.Bounds = new Rectangle(160, 160, 520, 220);
        form.TopMost = false;
        form.BackColor = cover ? Color.LightSalmon : Color.LightSkyBlue;
        Label text = new Label();
        text.Text = cover ? "Ordinary window (not topmost)" : "Target EXE launched by Watchdog";
        text.Dock = DockStyle.Fill; text.TextAlign = ContentAlignment.MiddleCenter;
        form.Controls.Add(text);
        Timer expiry = new Timer(); expiry.Interval = 60000;
        expiry.Tick += delegate { form.Close(); }; expiry.Start();
        Application.Run(form);
        expiry.Dispose(); form.Dispose();
    }
}
'@
    $config = WdNewAppConfiguration @{ FocusTop = $false; UnityDisplayRecovery = $false }
    $launchTime = @{}; $lastPid = @{}; $restartStats = @{}
    $launchArgs = @{
        Path = $exe; Config = $config; FileName = [IO.Path]::GetFileName($exe)
        StatKey = 'probe::H0'; OnceKey = 'probe::Once'; BrowserName = 'auto'; IsOnce = $false
        RestartStats = $restartStats; LaunchTime = $launchTime; DisplayRepairDone = @{}
        HangFailCount = @{}; LastStartedProcessId = $lastPid; FastExitHandledLaunch = @{}
    }
    WdLaunchAndTrack @launchArgs
    Assert ($lastPid.ContainsKey($exe)) 'Real watchdog launcher started the EXE with topmost disabled'
    $target = Get-Process -Id $lastPid[$exe]
    Assert ((WdWaitForWindowHandle $target 5000) -ne [IntPtr]::Zero) 'Target EXE created a real desktop window'
    Assert (((Get-TestWindowStyle $target) -band $WS_EX_TOPMOST) -eq 0) 'Topmost disabled leaves the EXE window ordinary'
    Close-TestProcess $target; $target = $null; $lastPid.Clear()

    $config.FocusTop = $true
    WdLaunchAndTrack @launchArgs
    Assert ($lastPid.ContainsKey($exe)) 'Real watchdog launcher started the EXE with topmost enabled'
    $target = Get-Process -Id $lastPid[$exe]
    Assert ((WdWaitForWindowHandle $target 5000) -ne [IntPtr]::Zero) 'Launched EXE window handle is available'
    $style = Get-TestWindowStyle $target
    Write-Output ('Target PID={0}; HWND={1}; EXSTYLE=0x{2:X}' -f $target.Id, $target.MainWindowHandle, $style)
    Assert (($style -band $WS_EX_TOPMOST) -ne 0) 'Watchdog launch sets the real EXE window WS_EX_TOPMOST flag'
    Assert ($Script:TopmostWindows[$target.MainWindowHandle.ToInt64()] -eq $target.Id) 'Tracked topmost handle belongs to the EXE process'

    $cover = Start-Process -FilePath $exe -ArgumentList 'cover' -PassThru
    Assert ((WdWaitForWindowHandle $cover 5000) -ne [IntPtr]::Zero) 'Ordinary covering EXE window is available'
    [void][WatchdogWin32.DisplayAPI]::SetForegroundWindow($cover.MainWindowHandle)
    Start-Sleep -Milliseconds 500
    Assert (WdIsWindowForeground $cover.MainWindowHandle) 'Ordinary covering window really became foreground'
    Assert (((Get-TestWindowStyle $cover) -band $WS_EX_TOPMOST) -eq 0) 'Covering window is not topmost'
    Assert (Test-WindowAbove $target.MainWindowHandle $cover.MainWindowHandle) 'Target EXE stays above the newly activated ordinary window'
    Assert (((Get-TestWindowStyle $target) -band $WS_EX_TOPMOST) -ne 0) 'EXE topmost persists after another window is activated'

    [void][WatchdogWin32.DisplayAPI]::SetWindowPos($target.MainWindowHandle, $HWND_NOTOPMOST, 0, 0, 0, 0, ($SWP_TOPMOST_FLAGS -bor $SWP_NOACTIVATE))
    Assert (((Get-TestWindowStyle $target) -band $WS_EX_TOPMOST) -eq 0) 'Prepare loss of topmost on the real target window'
    WdMaintainWindowFocus -Path $exe -Config $config -ProcessObj $target -FocusLastTime @{}
    Assert (((Get-TestWindowStyle $target) -band $WS_EX_TOPMOST) -ne 0) 'Watchdog monitoring restores lost EXE topmost'
    WdReleaseTopmostWindows
    Assert (((Get-TestWindowStyle $target) -band $WS_EX_TOPMOST) -eq 0) 'Disabling topmost releases the real EXE window'
    Write-Output "PASS: $script:assertions assertions using real EXE launches, native window styles and Z order."
}
finally {
    WdReleaseTopmostWindows
    Close-TestProcess $cover
    Close-TestProcess $target
    # This unique absolute directory was created above exclusively for this test.
    Remove-Item -LiteralPath $testDirectory -Recurse -Force
}
