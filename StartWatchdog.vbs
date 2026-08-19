Option Explicit

Dim shell, fileSystem, scriptDirectory, watchdogScript, powershellPath, command

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
watchdogScript = fileSystem.BuildPath(scriptDirectory, "Watchdog.ps1")
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & _
    "\System32\WindowsPowerShell\v1.0\powershell.exe"

command = """" & powershellPath & """" & _
    " -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden" & _
    " -File """ & watchdogScript & """ -RestartExisting"

' Window style 0 runs PowerShell without creating a visible console window.
shell.Run command, 0, False
