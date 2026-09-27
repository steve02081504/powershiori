@echo off
setlocal enableextensions

rem Build powershiori.ps1 into powershiori.dll (x64, .NET Framework 4.0).
rem x64/Framework4.0 are pinned by #_pragma in powershiori.ps1, so no build options are passed here.

rem 1) Need a PowerShell interpreter: prefer PowerShell 7+ (pwsh), fall back to Windows PowerShell.
set "PSEXE="
where pwsh >nul 2>nul && set "PSEXE=pwsh"
if not defined PSEXE (
	where powershell >nul 2>nul && set "PSEXE=powershell"
)
if not defined PSEXE (
	echo [build] ERROR: no PowerShell interpreter found on PATH ^(need pwsh or powershell^).
	exit /b 1
)
echo [build] using %PSEXE%

rem 2) Make sure ps12exe is available, installing it from the gallery if needed, then 3) compile.
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; if (-not (Get-Module -ListAvailable ps12exe)) { Write-Host '[build] ps12exe not installed; installing from PSGallery...'; Install-Module ps12exe -Scope CurrentUser -Repository PSGallery -Force }; Import-Module ps12exe; ps12exe -inputFile '%~dp0powershiori.ps1' -outputFile '%~dp0powershiori.dll' -NoUpdateCheck"
if errorlevel 1 (
	echo [build] ERROR: compilation failed.
	exit /b 1
)
echo [build] done: %~dp0powershiori.dll
exit /b 0
