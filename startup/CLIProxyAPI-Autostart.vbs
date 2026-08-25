Option Explicit

' This launcher only starts the two loopback services. The selected Codex mode
' remains controlled by config.toml and is never changed at Windows login.
Dim shell, userProfile, startScript
Set shell = CreateObject("WScript.Shell")
userProfile = shell.ExpandEnvironmentStrings("%USERPROFILE%")
startScript = userProfile & "\.codex\tools\cliproxyapi\Start-CLIProxyAPI.ps1"
shell.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & startScript & """ -WaitReady", 0, False
