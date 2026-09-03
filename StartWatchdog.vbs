Option Explicit

Dim shell, fileSystem, scriptDirectory, watchdogScript, powershellPath, command, argument, unattended

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
watchdogScript = fileSystem.BuildPath(scriptDirectory, "Watchdog.ps1")
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & _
    "\System32\WindowsPowerShell\v1.0\powershell.exe"

unattended = False
For Each argument In WScript.Arguments
    If LCase(argument) = "/unattended" Or LCase(argument) = "-unattended" Then
        unattended = True
    End If
Next

command = """" & powershellPath & """" & _
    " -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden" & _
    " -File """ & watchdogScript & """ -RestartExisting"

If unattended Then
    command = command & " -Unattended"
End If

' Window style 0 runs PowerShell without creating a visible console window.
shell.Run command, 0, False
