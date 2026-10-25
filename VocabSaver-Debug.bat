@echo off
cd /d "%~dp0"
echo Dang chay Vocab Saver o che do debug. Neu co loi se hien ben duoi.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0VocabSaver.ps1"
echo.
echo ===== Script da dung. Chup man hinh cua so nay gui cho Copilot =====
pause
