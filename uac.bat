@echo off
setlocal EnableDelayedExpansion
title Win10 无人值守自动登录配置工具
chcp 65001 >nul

:: ---------- 自动请求管理员权限 ----------
>nul 2>&1 net session
if !errorlevel! neq 0 (
    echo 正在请求管理员权限...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: ---------- 从本文件末尾提取内嵌的 PowerShell 脚本正文 ----------
:: 说明:下面的 PowerShell 代码就写在本 bat 文件里(标记行之后),
:: 可以直接用记事本/VSCode 打开编辑,不需要 base64 解码。
set "PS1_PATH=%TEMP%\Win10_Unattended_AutoDesktop.ps1"

powershell -NoProfile -Command "$mark = '::' + 'PS1_SCRIPT_START::'; $c = Get-Content -Raw -LiteralPath '%~f0'; $i = $c.LastIndexOf($mark); if ($i -lt 0) { throw 'marker not found' }; $body = $c.Substring($i + $mark.Length); Set-Content -LiteralPath '%PS1_PATH%' -Value $body -Encoding UTF8"

if not exist "%PS1_PATH%" (
    echo 释放脚本失败,请检查权限或磁盘空间。
    pause
    exit /b 1
)

:MENU
cls
echo ================================================
echo   Win10 无人值守自动登录配置工具
echo ================================================
echo   [1] 启用自动登录 ^(当前用户,本地账户^)
echo   [2] 启用自动登录 ^(手动输入用户名/域^)
echo   [3] 禁用自动登录 ^(清除密码,同时恢复锁屏^)
echo   [4] 仅恢复锁屏功能 ^(保留自动登录不变^)
echo   [0] 退出
echo ================================================
set /p CHOICE=请输入选项编号并回车:

if "%CHOICE%"=="1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1_PATH%" -UserName "%USERNAME%" -LocalAccount
    goto END
)

if "%CHOICE%"=="2" (
    set /p CUSTOM_USER=请输入用户名:
    set /p CUSTOM_DOMAIN=请输入域名或计算机名 ^(本地账户直接回车^):
    if "!CUSTOM_DOMAIN!"=="" (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1_PATH%" -UserName "!CUSTOM_USER!" -LocalAccount
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1_PATH%" -UserName "!CUSTOM_USER!" -Domain "!CUSTOM_DOMAIN!"
    )
    goto END
)

if "%CHOICE%"=="3" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1_PATH%" -Disable
    goto END
)

if "%CHOICE%"=="4" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1_PATH%" -RestoreLockScreen
    goto END
)

if "%CHOICE%"=="0" (
    exit /b 0
)

echo 无效选项,请重新输入。
pause
goto MENU

:END
echo.
pause
exit /b 0

REM ============================================================
REM 下面是内嵌的 PowerShell 脚本正文,可直接在此编辑。
REM cmd.exe 执行到上面的 exit /b 就结束了,不会尝试运行这部分。
REM ============================================================
::PS1_SCRIPT_START::
# Windows 10 unattended mode: boot directly into desktop without lock screen clicks.
# Run from an elevated PowerShell window.
#
# Security note:
# Windows built-in AutoAdminLogon stores the account password in the registry.
# Use this only on controlled unattended machines, kiosks, labs, or isolated hosts.

[CmdletBinding(DefaultParameterSetName = "Enable")]
param(
    [Parameter(ParameterSetName = "Enable")]
    [string]$UserName = $env:USERNAME,

    [Parameter(ParameterSetName = "Enable")]
    [string]$Domain = $env:COMPUTERNAME,

    [Parameter(ParameterSetName = "Enable")]
    [switch]$LocalAccount,

    [Parameter(ParameterSetName = "Enable")]
    [System.Security.SecureString]$Password,

    [Parameter(ParameterSetName = "Disable", Mandatory = $true)]
    [switch]$Disable,

    [Parameter(ParameterSetName = "RestoreLockScreen", Mandatory = $true)]
    [switch]$RestoreLockScreen
)

$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-RegistryDword {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

function Set-RegistryString {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}

function Remove-RegistryValueIfExists {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ((Test-Path -LiteralPath $Path) -and (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue)) {
        Remove-ItemProperty -Path $Path -Name $Name -Force
    }
}

function Convert-SecureStringToPlainText {
    param([Parameter(Mandatory = $true)][System.Security.SecureString]$SecureString)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Restore-LockScreenAbility {
    param(
        [Parameter(Mandatory = $true)][string]$PersonalizationPath,
        [Parameter(Mandatory = $true)][string]$SystemPolicyPath,
        [Parameter(Mandatory = $true)][string]$CurrentUserPolicyPath
    )

    Remove-RegistryValueIfExists -Path $PersonalizationPath -Name "NoLockScreen"
    Set-RegistryDword -Path $SystemPolicyPath -Name "InactivityTimeoutSecs" -Value 0

    # Restore the ability to lock the screen (Win+L / Ctrl+Alt+Del / Start menu).
    Remove-RegistryValueIfExists -Path $CurrentUserPolicyPath -Name "DisableLockWorkstation"

    # Restore reasonable display/sleep timeouts (Windows defaults) so the screen can lock again.
    try {
        powercfg /change monitor-timeout-ac 10 | Out-Null
        powercfg /change monitor-timeout-dc 5 | Out-Null
        powercfg /change standby-timeout-ac 30 | Out-Null
        powercfg /change standby-timeout-dc 15 | Out-Null
    }
    catch {
        Write-Host "Warning: failed to restore power settings via powercfg. $_" -ForegroundColor Yellow
    }
}

if (-not (Test-IsAdministrator)) {
    throw "Please run PowerShell as Administrator, then execute this script again."
}

$winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$personalizationPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
$systemPolicyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
$currentUserDesktopPath = "HKCU:\Control Panel\Desktop"
$currentUserPolicyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System"

if ($RestoreLockScreen) {
    Restore-LockScreenAbility -PersonalizationPath $personalizationPath -SystemPolicyPath $systemPolicyPath -CurrentUserPolicyPath $currentUserPolicyPath

    Write-Host ""
    Write-Host "Done." -ForegroundColor Green
    Write-Host "Lock-screen ability is restored (Win+L, Ctrl+Alt+Del lock, inactivity lock, sleep)."
    Write-Host "AutoAdminLogon settings were NOT changed."
    Write-Host "Note: this only affects the account running this script; sign into other accounts and re-run if needed." -ForegroundColor DarkGray
    exit 0
}

if ($Disable) {
    Set-RegistryString -Path $winlogonPath -Name "AutoAdminLogon" -Value "0"
    Remove-RegistryValueIfExists -Path $winlogonPath -Name "DefaultPassword"
    Remove-RegistryValueIfExists -Path $winlogonPath -Name "DefaultUserName"
    Remove-RegistryValueIfExists -Path $winlogonPath -Name "DefaultDomainName"
    Remove-RegistryValueIfExists -Path $winlogonPath -Name "ForceAutoLogon"

    Restore-LockScreenAbility -PersonalizationPath $personalizationPath -SystemPolicyPath $systemPolicyPath -CurrentUserPolicyPath $currentUserPolicyPath

    Write-Host ""
    Write-Host "Done." -ForegroundColor Green
    Write-Host "Auto login is disabled and the stored AutoAdminLogon password was removed."
    Write-Host "Lock-screen and screen-lock shortcuts (Win+L etc.) are restored."
    Write-Host "Reboot to verify normal sign-in behavior."
    exit 0
}

if ($LocalAccount) {
    $Domain = "."
}

if (-not $Password) {
    $Password = Read-Host -Prompt "Password for $Domain\$UserName" -AsSecureString
}

$plainPassword = Convert-SecureStringToPlainText -SecureString $Password
if ([string]::IsNullOrWhiteSpace($plainPassword)) {
    Write-Host "Password is empty; configuring AutoAdminLogon for a blank-password account." -ForegroundColor Yellow
    $plainPassword = ""
}

# AutoAdminLogon boots directly into the configured user's desktop.
Set-RegistryString -Path $winlogonPath -Name "AutoAdminLogon" -Value "1"
Set-RegistryString -Path $winlogonPath -Name "ForceAutoLogon" -Value "1"
Set-RegistryString -Path $winlogonPath -Name "DefaultUserName" -Value $UserName
Set-RegistryString -Path $winlogonPath -Name "DefaultDomainName" -Value $Domain
Set-RegistryString -Path $winlogonPath -Name "DefaultPassword" -Value $plainPassword

# Hide the pre-sign-in lock screen where the Windows edition honors this policy.
Set-RegistryDword -Path $personalizationPath -Name "NoLockScreen" -Value 1

# Avoid automatic inactivity lock from local security policy.
Set-RegistryDword -Path $systemPolicyPath -Name "InactivityTimeoutSecs" -Value 0

# Disable password-protected screensaver for the current user running the script.
Set-RegistryString -Path $currentUserDesktopPath -Name "ScreenSaveActive" -Value "0"
Set-RegistryString -Path $currentUserDesktopPath -Name "ScreenSaverIsSecure" -Value "0"

# Remove the "Lock" option from Win+L, Ctrl+Alt+Del, and the Start menu for the current user.
Set-RegistryDword -Path $currentUserPolicyPath -Name "DisableLockWorkstation" -Value 1

# Prevent the display/system from sleeping, which would otherwise trigger the lock screen on wake.
try {
    powercfg /change monitor-timeout-ac 0 | Out-Null
    powercfg /change monitor-timeout-dc 0 | Out-Null
    powercfg /change standby-timeout-ac 0 | Out-Null
    powercfg /change standby-timeout-dc 0 | Out-Null
}
catch {
    Write-Host "Warning: failed to adjust power settings via powercfg. $_" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Unattended desktop login is enabled for $Domain\$UserName."
Write-Host "Lock screen is disabled: Win+L / Ctrl+Alt+Del lock, inactivity lock, screensaver lock, and display/system sleep are all turned off."
Write-Host "Reboot to test: Windows should enter that user's desktop without a lock-screen click."
Write-Host "Important: the AutoAdminLogon password is stored in the registry by Windows design."
Write-Host "To disable later, run this script with -Disable."
Write-Host ""
Write-Host "Note: the lock-workstation and screensaver settings above apply to the user account" -ForegroundColor DarkGray
Write-Host "running this script. If your autologon account ($Domain\$UserName) is a different" -ForegroundColor DarkGray
Write-Host "account, sign into it once and re-run this script under that account for full effect." -ForegroundColor DarkGray
