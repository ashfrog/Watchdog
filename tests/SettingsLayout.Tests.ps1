param([string]$OutputDirectory = '')
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Watchdog.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$builder = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'WdNewSettingsView' }, $true)
Add-Type -AssemblyName System.Windows.Forms
$initializer = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'WdInitializeSettingsControls' }, $true)
. ([scriptblock]::Create($initializer.Extent.Text))
WdInitializeSettingsControls
$previewReferences = @([Windows.Forms.Form].Assembly.Location, [ComponentModel.Component].Assembly.Location) | Select-Object -Unique
Add-Type -ReferencedAssemblies $previewReferences -WarningAction SilentlyContinue -TypeDefinition @'
public class WatchdogSettingsPreviewForm : System.Windows.Forms.Form {
    protected override bool ShowWithoutActivation { get { return true; } }
}
'@
# Use the production view with only a non-activating Form subclass for offscreen rendering.
. ([scriptblock]::Create($builder.Extent.Text.Replace('New-Object Windows.Forms.Form', 'New-Object WatchdogSettingsPreviewForm')))
[Windows.Forms.Application]::EnableVisualStyles()
$Script:StartWithWindows = $true
$Script:DisableLockScreen = $false
$Script:EnableMagicWake = $true
if ($OutputDirectory) { [void][IO.Directory]::CreateDirectory($OutputDirectory) }
$cases = @(@('desktop', 1040, 680), @('portrait', 760, 900), @('compact', 480, 680))
foreach ($case in $cases) {
    $view = WdNewSettingsView
    $form = $view.Form
    try {
        $form.ClientSize = New-Object Drawing.Size($case[1], $case[2])
        $form.StartPosition = 'Manual'
        $form.Location = New-Object Drawing.Point(-20000, -20000)
        $form.ShowInTaskbar = $false
        $view.EmptyList.Visible = $false
        foreach ($sample in @(@('Exhibition.exe', 'D:\Exhibition\Exhibition.exe'), @('VideoPlayer.exe', 'D:\Media\VideoPlayer.exe'))) {
            $item = New-Object Windows.Forms.ListViewItem($sample[0])
            [void]$item.SubItems.Add($sample[1]); [void]$item.SubItems.Add([string][char]0x5C31 + [char]0x7EEA); [void]$item.SubItems.Add('')
            [void]$view.List.Items.Add($item)
        }
        $view.List.Items[0].Selected = $true
        $view.PathBox.Text = 'D:\Exhibition\Exhibition.exe'
        $view.ArgsBox.Text = '-screen-fullscreen 1'
        $view.FirstBox.Value = 1; $view.RestartBox.Value = 5; $view.MinBox.Value = 15
        $view.CheckBoxes.Fullscreen.Checked = $true
        $view.CheckBoxes.RestartOnDisplayChange.Checked = $true
        $view.CheckBoxes.UnityDisplayRecovery.Checked = $true
        $view.CheckBoxes.KillTreeOnHang.Checked = $true
        $adapter = New-Object Windows.Forms.ListViewItem('Ethernet 1')
        [void]$adapter.SubItems.Add('D8-43-AE-B6-F7-2C')
        [void]$view.AdapterList.Items.Add($adapter)
        [void]$form.Handle
        $createHandles = { param($control)
            [void]$control.Handle
            foreach ($child in $control.Controls) { & $createHandles $child }
            $control.PerformLayout()
        }
        & $createHandles $form
        $form.Show()
        [Windows.Forms.Application]::DoEvents()
        $form.PerformLayout()
        $bitmap = New-Object Drawing.Bitmap($form.ClientSize.Width, $form.ClientSize.Height)
        try {
            $form.Controls[0].DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)))
            if ($OutputDirectory) { $bitmap.Save((Join-Path $OutputDirectory ($case[0] + '.png'))) }
        }
        finally { $bitmap.Dispose() }
        if ($view.CheckBoxes.Count -ne 10) { throw 'A configuration option was lost' }
        if ($case[0] -eq 'desktop' -and $view.ProgramPage.VerticalScroll.Visible) { throw 'Default compact desktop layout should show all program settings without scrolling' }
        if ($case[0] -ne 'compact' -and $view.CheckBoxes.Fullscreen.Top -ne $view.CheckBoxes.ForceDisplayMode.Top) { throw 'Wide options failed to align in two columns' }
        if ($view.Body.ColumnCount -ne $(if ($case[0] -eq 'desktop') { 2 } else { 1 })) { throw 'Responsive breakpoint failed' }
        $saveTop = $view.Save.Location
        $parent = $view.Save.Parent
        while ($parent -and $parent -ne $form) {
            $saveTop.Offset($parent.Left, $parent.Top)
            $parent = $parent.Parent
        }
        if ($saveTop.Y -lt 0 -or $saveTop.Y + $view.Save.Height -gt $form.ClientSize.Height) { throw 'Save action is clipped' }
        if ($view.Cancel.Bottom -gt $view.Cancel.Parent.ClientSize.Height -or $view.Cancel.Left -lt 0) { throw 'Cancel action is clipped' }
        foreach ($check in $view.CheckBoxes.Values) {
            if ($check.Right -gt $check.Parent.ClientSize.Width) { throw "Option clipped: $($check.Text)" }
        }
        if ($view.List.ClientSize.Height -lt 55) { throw 'Program list cannot show even one complete item' }
        Write-Output ("PASS {0}: client={1}; body={2}; save={3}; program={4}" -f $case[0], $form.ClientSize, $view.Body.Size, $saveTop, $view.ProgramPage.Size)
        # Invoke the actual page-switch event without showing the window or changing settings.
        $click = [Windows.Forms.Control].GetMethod('OnClick', [Reflection.BindingFlags]'Instance,NonPublic')
        [void]$click.Invoke($view.HostTab, @([EventArgs]::Empty))
        [Windows.Forms.Application]::DoEvents()
        $form.PerformLayout()
        $bitmap = New-Object Drawing.Bitmap($form.ClientSize.Width, $form.ClientSize.Height)
        try {
            $form.Controls[0].DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)))
            if ($OutputDirectory) { $bitmap.Save((Join-Path $OutputDirectory ($case[0] + '-host.png'))) }
        }
        finally { $bitmap.Dispose() }
        # Resize the same live form in both directions; switching layout must retain edits.
        foreach ($width in @(520, 1180, $case[1])) {
            $form.ClientSize = New-Object Drawing.Size($width, $case[2])
            [Windows.Forms.Application]::DoEvents()
            if ($view.PathBox.Text -ne 'D:\Exhibition\Exhibition.exe' -or -not $view.CheckBoxes.RestartOnDisplayChange.Checked) { throw 'Resize lost configuration edits' }
            if ($view.Body.GetCellPosition($view.HostPage.Parent.Parent).Column -ne $(if ($width -ge 928) { 1 } else { 0 })) { throw 'Live resize placed the settings panel incorrectly' }
        }
    }
    finally { $form.Dispose() }
}
# Exercise the actual editor bindings. Persistence and adapter discovery are mocked;
# only ShowDialog is replaced so the test cannot wait for input or show a dialog.
foreach ($name in @('WdGetConfigValue', 'WdNewAppConfiguration', 'WdShowSettingsWindow')) {
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    . ([scriptblock]::Create($function.Extent.Text.Replace('[void]$form.ShowDialog()', '. $script:settingsExercise')))
}
function WdGetPhysicalNetworkAdapters { return @() }
function WdApplyAppConfigurations {
    param($Entries, $StartWithWindows, $DisableLockScreen, $EnableMagicWake)
    $script:capturedSettings = @{ Entries = @($Entries); AutoStart = $StartWithWindows; LockScreen = $DisableLockScreen; Wake = $EnableMagicWake }
}
function WdOfferAuthorizationForError { param($Exception, $Operation) throw $Exception }
$Apps = [ordered]@{ 'D:\Exhibition\Exhibition.exe' = (WdNewAppConfiguration @{ HideCursor = $true; Arguments = 'original' }) }
$script:settingsExercise = {
    $form.StartPosition = 'Manual'; $form.Location = New-Object Drawing.Point(-20000, -20000)
    $form.ShowInTaskbar = $false; $form.Show()
    [Windows.Forms.Application]::DoEvents()
    $argsBox.Text = '-screen-fullscreen 1'
    # Type into the custom number field's real edit control, rather than setting Value directly.
    $numberEdit = @($restartBox.Controls[0].Controls | Where-Object { $_ -is [Windows.Forms.TextBox] })[0]
    $numberEdit.Text = '8'
    $checkBoxes.RestartOnDisplayChange.Checked = $true
    $view.HostTab.PerformClick()
    $autoStart.Checked = $false
    $disableLockScreen.Checked = $true
    $magicWake.Checked = $false
    $save.PerformClick()
}
if (-not (WdShowSettingsWindow)) { throw 'Settings editor failed to save through existing handler' }
$savedConfig = $script:capturedSettings.Entries[0].Config
if ($savedConfig.Arguments -ne '-screen-fullscreen 1' -or $savedConfig.Restart -ne 8 -or
    -not $savedConfig.RestartOnDisplayChange -or -not $savedConfig.HideCursor -or -not $savedConfig.UnityDisplayRecovery) { throw 'Editor did not preserve program options' }
if ($script:capturedSettings.AutoStart -or -not $script:capturedSettings.LockScreen -or $script:capturedSettings.Wake) { throw 'Host options were not bound to save' }
if ($Script:SettingsWindowOpen -or $null -ne $Script:SettingsForm -or $Script:UserInteractionActive) { throw 'Editor did not restore unattended state after closing' }
$Apps = [ordered]@{}
$script:settingsExercise = {
    if ($pathBox.Enabled -or $save.Enabled -eq $false -or $remove.Enabled) { throw 'Empty state enables invalid editing or disables saving' }
}
[void](WdShowSettingsWindow -FirstRun)
Write-Output 'PASS: responsive layout, page switching, editor bindings, empty state and unattended-state cleanup; persistence was mocked.'
