@echo off
cd /d "%~dp0"
start "WoW WhatsApp bridge" cmd /k node supervisor.js
