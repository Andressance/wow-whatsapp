# Runs the bridge in the current terminal (auto-restarts on crash). Ctrl+C stops it cleanly.
# If PowerShell refuses to run scripts:  powershell -ExecutionPolicy Bypass -File .\start.ps1
# start-window.cmd is the double-click version that opens its own window.
& node (Join-Path $PSScriptRoot 'supervisor.js')
