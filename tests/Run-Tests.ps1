#Requires -Version 5.0
<#
.SYNOPSIS
	Loads the built shiori DLL through the native SHIORI interface and asserts its responses.
.DESCRIPTION
	The shiori is a .NET Framework 4.0 DLL that hosts PowerShell, so it must be exercised from 64-bit
	Windows PowerShell 5.1. When run from PowerShell 7+ this script re-launches itself under
	powershell.exe automatically.
.PARAMETER Dll
	Path to the shiori DLL (default: <repo>\powershiori.dll).
.PARAMETER Build
	Rebuild the DLL before testing.
.EXAMPLE
	.\tests\Run-Tests.ps1 -Build
#>
[CmdletBinding()]
param(
	[string]$Dll,
	[switch]$Build
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $Dll) { $Dll = Join-Path $root 'powershiori.dll' }
$Dll = [System.IO.Path]::GetFullPath($Dll)

# The DLL is a Framework4.0 assembly with native exports; only Windows PowerShell 5.1 can host it.
if ($PSVersionTable.PSEdition -eq 'Core') {
	$exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
	if (-not (Test-Path -LiteralPath $exe)) { throw 'Windows PowerShell 5.1 not found' }
	$arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Dll', $Dll)
	if ($Build) { $arguments += '-Build' }
	& $exe @arguments
	exit $LASTEXITCODE
}

if ($Build -or -not (Test-Path -LiteralPath $Dll)) {
	$bat = Join-Path $root 'build.bat'
	if (-not (Test-Path -LiteralPath $bat)) { throw "build.bat missing: $bat" }
	& cmd /c "`"$bat`""
	if ($LASTEXITCODE -ne 0) { throw "Build failed (exit $LASTEXITCODE)" }
	if (-not (Test-Path -LiteralPath $Dll)) { throw "Build failed: $Dll missing" }
}

$ghostDir = Join-Path $root 'tests\example\ghost\master'
if (-not (Test-Path -LiteralPath $ghostDir)) { throw "Example ghost directory missing: $ghostDir" }

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class PSShioriTest {
	[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);
	[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GlobalFree(IntPtr hMem);
	[DllImport(@"$Dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "loadu")] public static extern bool loadu(IntPtr h, int len);
	[DllImport(@"$Dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "load")] public static extern bool load(IntPtr h, int len);
	[DllImport(@"$Dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "unload")] public static extern bool unload();
	[DllImport(@"$Dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "CI_check_failed")] public static extern bool CI_check_failed();
	[DllImport(@"$Dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "request")] public static extern IntPtr request(IntPtr h, ref int len);
}
"@

$script:Passed = 0
$script:Failed = 0

function New-HGlobal {
	param([byte[]]$Bytes)
	$handle = [PSShioriTest]::GlobalAlloc(0x0040, [UIntPtr]::new([uint64]($Bytes.Length + 1)))
	[System.Runtime.InteropServices.Marshal]::Copy($Bytes, 0, $handle, $Bytes.Length)
	return $handle
}

function Invoke-Shiori {
	param([string]$Request)
	$bytes = [System.Text.Encoding]::UTF8.GetBytes($Request)
	$handle = New-HGlobal -Bytes $bytes
	$length = $bytes.Length
	$responseHandle = [PSShioriTest]::request($handle, [ref]$length)
	$responseBytes = New-Object byte[] $length
	[System.Runtime.InteropServices.Marshal]::Copy($responseHandle, $responseBytes, 0, $length)
	[void][PSShioriTest]::GlobalFree($responseHandle)
	return [System.Text.Encoding]::UTF8.GetString($responseBytes)
}

function Get-ResponseHeader {
	param([string]$Response, [string]$Name)
	foreach ($line in ($Response -split "`r`n")) {
		if ($line -match "^$([regex]::Escape($Name)):\s?(.*)$") { return $Matches[1] }
	}
	return $null
}

function Test-Case {
	param([string]$Name, [scriptblock]$Body)
	try {
		& $Body
		$script:Passed++
		Write-Host "PASS  $Name" -ForegroundColor Green
	}
	catch {
		$script:Failed++
		Write-Host "FAIL  $Name`n      $($_.Exception.Message)" -ForegroundColor Red
	}
}

function Assert-True {
	param([bool]$Condition, [string]$Message)
	if (-not $Condition) { throw $Message }
}

function Assert-Equal {
	param($Expected, $Actual, [string]$Message)
	if ("$Expected" -ne "$Actual") { throw "$Message (expected [$Expected], got [$Actual])" }
}

function Assert-Match {
	param([string]$Pattern, [string]$Actual, [string]$Message)
	if ($Actual -notmatch $Pattern) { throw "$Message (pattern [$Pattern], got [$Actual])" }
}

function New-Request {
	param([string]$Command = 'GET', [string]$Id, [hashtable]$Headers = @{})
	$lines = New-Object System.Collections.Generic.List[string]
	$lines.Add("$Command SHIORI/3.0")
	$lines.Add('Charset: UTF-8')
	if ($Id) { $lines.Add("ID: $Id") }
	foreach ($entry in $Headers.GetEnumerator()) { $lines.Add("$($entry.Key): $($entry.Value)") }
	$lines.Add('')
	$lines.Add('')
	return ($lines -join "`r`n")
}

Write-Host "Testing $Dll"

Test-Case 'CI_check_failed returns false' {
	Assert-True (-not [PSShioriTest]::CI_check_failed()) 'CI_check_failed should be false on a clean build'
}

Test-Case 'loadu accepts a UTF-8 module path' {
	$pathBytes = [System.Text.Encoding]::UTF8.GetBytes($ghostDir)
	$handle = New-HGlobal -Bytes $pathBytes
	Assert-True ([PSShioriTest]::loadu($handle, $pathBytes.Length)) 'loadu returned false'
}

Test-Case 'load is a no-op after loadu (and frees its buffer)' {
	$pathBytes = [System.Text.Encoding]::UTF8.GetBytes($ghostDir)
	$handle = New-HGlobal -Bytes $pathBytes
	Assert-True ([PSShioriTest]::load($handle, $pathBytes.Length)) 'load returned false'
}

Test-Case 'GET OnBoot returns 200 with the dictionary script' {
	$response = Invoke-Shiori (New-Request -Id 'OnBoot')
	Assert-Equal 'SHIORI/3.0 200 OK' ($response -split "`r`n")[0] 'status line'
	Assert-Equal 'PowerShell' (Get-ResponseHeader $response 'Sender') 'Sender header'
	Assert-Equal '\0\s[0]\1\s[10]\e' (Get-ResponseHeader $response 'Value') 'Value header'
}

Test-Case 'GET OnClose uses the built-in default' {
	$response = Invoke-Shiori (New-Request -Id 'OnClose')
	Assert-Equal '\0\-\e' (Get-ResponseHeader $response 'Value') 'Value header'
}

Test-Case 'dictionary handler with Reference0' {
	$response = Invoke-Shiori (New-Request -Id 'OnTestEcho' -Headers @{ Reference0 = 'hello' })
	Assert-Equal 'OnTestEcho reference0=[hello]' (Get-ResponseHeader $response 'Value') 'Value header'
}

Test-Case 'dictionary handler that returns a static string' {
	$response = Invoke-Shiori (New-Request -Id 'OnStatic')
	Assert-Equal 'static-string-response' (Get-ResponseHeader $response 'Value') 'Value header'
}

Test-Case 'Register-ShioriEvent style dictionary' {
	$response = Invoke-Shiori (New-Request -Id 'OnRegisterStyle')
	Assert-Equal 'from-register-style' (Get-ResponseHeader $response 'Value') 'Value header'
}

Test-Case 'later handler wins, empty string falls back' {
	$response = Invoke-Shiori (New-Request -Id 'OnWithPriorityFallback' -Headers @{ Reference0 = 'r' })
	Assert-Equal 'fallback-ok: r' (Get-ResponseHeader $response 'Value') 'Value header'
}

Test-Case 'unknown GET event returns 204' {
	$response = Invoke-Shiori (New-Request -Id 'OnNobodyKnowsThis')
	Assert-Equal 'SHIORI/3.0 204 No Content' ($response -split "`r`n")[0] 'status line'
}

Test-Case 'NOTIFY returns 204 with ValueNotify' {
	$response = Invoke-Shiori (New-Request -Command 'NOTIFY' -Id 'OnTestEcho' -Headers @{ Reference0 = 'x' })
	Assert-Equal 'SHIORI/3.0 204 No Content' ($response -split "`r`n")[0] 'status line'
	Assert-Equal 'OnTestEcho reference0=[x]' (Get-ResponseHeader $response 'ValueNotify') 'ValueNotify header'
}

Test-Case 'OnFirstBoot defers to OnBoot with 204' {
	$response = Invoke-Shiori (New-Request -Id 'OnFirstBoot')
	Assert-Equal 'SHIORI/3.0 204 No Content' ($response -split "`r`n")[0] 'status line'
}

Test-Case 'bad request returns 400' {
	$response = Invoke-Shiori "garbage`r`n`r`n"
	Assert-Equal 'SHIORI/3.0 400 Bad Request' ($response -split "`r`n")[0] 'status line'
}

Test-Case 'Shift_JIS response encoding is honored' {
	$request = "GET SHIORI/3.0`r`nCharset: Shift_JIS`r`nID: OnStatic`r`n`r`n"
	$bytes = [System.Text.Encoding]::GetEncoding(932).GetBytes($request)
	$handle = New-HGlobal -Bytes $bytes
	$length = $bytes.Length
	$responseHandle = [PSShioriTest]::request($handle, [ref]$length)
	$responseBytes = New-Object byte[] $length
	[System.Runtime.InteropServices.Marshal]::Copy($responseHandle, $responseBytes, 0, $length)
	[void][PSShioriTest]::GlobalFree($responseHandle)
	$text = [System.Text.Encoding]::GetEncoding(932).GetString($responseBytes)
	Assert-Equal 'static-string-response' (Get-ResponseHeader $text 'Value') 'Value header'
}

Test-Case 'unload returns true' {
	Assert-True ([PSShioriTest]::unload()) 'unload returned false'
}

Test-Case 'load re-initializes the runtime after unload' {
	$pathBytes = [System.Text.Encoding]::Default.GetBytes($ghostDir)
	$handle = New-HGlobal -Bytes $pathBytes
	Assert-True ([PSShioriTest]::load($handle, $pathBytes.Length)) 'load returned false'
	$response = Invoke-Shiori (New-Request -Id 'OnBoot')
	Assert-Equal '\0\s[0]\1\s[10]\e' (Get-ResponseHeader $response 'Value') 'Value header'
}

Write-Host ""
Write-Host ("Passed: {0}  Failed: {1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
