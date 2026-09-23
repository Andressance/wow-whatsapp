@echo off
cd /d "%~dp0"
start "WoW Claude bridge" cmd /k node supervisor.js
