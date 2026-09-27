# powershiori - a SHIORI/3.0 shiori written in pure PowerShell.
#
# Compile to a native shiori DLL with ps12exe (see build.ps1):
#   ps12exe -inputFile powershiori.ps1 -outputFile powershiori.dll -Build @{ Platform='x64' }
#
# The #_DllExport directives below make ps12exe emit the native entry points that the baseware
# (SSP / shioricaller) resolves with GetProcAddress. Each one forwards to the like-named
# PowerShell function in this file, which does the actual work.
#
# SHIORI/3.0 DLL interface (see https://ssp.shillest.net/ukadoc/manual/spec_dll.html):
#   BOOL   loadu(HGLOBAL path_utf8, long len)   - module init, UTF-8 path
#   BOOL   load (HGLOBAL path_oem,  long len)   - legacy fallback, OEM codepage path
#   BOOL   unload()                             - module teardown
#   HGLOBAL request(HGLOBAL req, long* len)     - the single request/response entry point
#
# All string arguments/returns travel through Win32 Global Memory: the baseware allocates with
# GlobalAlloc(GMEM_FIXED) and hands us the HGLOBAL; we GlobalFree() it, allocate a fresh buffer for
# the answer, write the byte length back through `len`, and return the new HGLOBAL.

# Native exports only exist for .NET Framework 4.0 on an explicit architecture (ps12exe rejects
# AnyCPU/Core). Keep the target fixed here so build.bat does not have to pass any build options.
#_pragma Build.Target Framework4.0
#_pragma Build.Platform x64

#_DllExport bool loadu(IntPtr h, int len)
#_DllExport bool load(IntPtr h, int len)
#_DllExport bool unload()
#_DllExport bool CI_check_failed()
#_DllExport IntPtr request(IntPtr h, IntPtr len)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Win32 global memory helpers
# ---------------------------------------------------------------------------

if (-not ('PSShiori.Native' -as [type])) {
	Add-Type -Namespace PSShiori -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr GlobalFree(IntPtr hMem);
'@
}

function Write-PSShioriLog {
	param([string]$Message)
	if (-not $env:POWERSHIORI_DEBUG) { return }
	try {
		$path = if ($env:POWERSHIORI_LOG) { $env:POWERSHIORI_LOG } else { Join-Path $env:TEMP 'powershiori.log' }
		Add-Content -LiteralPath $path -Value ("{0} {1}" -f ([DateTime]::Now.ToString('s')), $Message) -Encoding UTF8
	}
	catch { }
}

# Copy `Length` bytes out of an HGLOBAL into a managed byte array.
function Read-HGlobalBytes {
	param([IntPtr]$Handle, [int]$Length)
	if ($Length -le 0) { return , [byte[]]@() }
	$buffer = New-Object byte[] $Length
	[System.Runtime.InteropServices.Marshal]::Copy($Handle, $buffer, 0, $Length)
	return , $buffer
}

# Allocate a GMEM_FIXED buffer (zero-initialised, plus a spare NUL) and copy `Bytes` into it.
function New-HGlobalBytes {
	param([byte[]]$Bytes)
	$size = $Bytes.Length + 1
	$handle = [PSShiori.Native]::GlobalAlloc(0x0040, [UIntPtr]::new([uint64]$size))
	if ($handle -eq [IntPtr]::Zero) { throw 'GlobalAlloc failed' }
	if ($Bytes.Length -gt 0) { [System.Runtime.InteropServices.Marshal]::Copy($Bytes, 0, $handle, $Bytes.Length) }
	return $handle
}

# ---------------------------------------------------------------------------
# Charset handling
# ---------------------------------------------------------------------------

function Get-ShioriEncoding {
	param([string]$Charset)
	if ([string]::IsNullOrWhiteSpace($Charset)) { return [System.Text.Encoding]::UTF8 }
	try {
		switch -Regex ($Charset.Trim()) {
			'^(UTF-?8|utf8|65001)$' { return [System.Text.Encoding]::UTF8 }
			'^(Shift[-_]?JIS|SJIS|CP932|Windows-31J|MS932|932)$' { return [System.Text.Encoding]::GetEncoding(932) }
			'^(EUC-?JP|EUCJP|51932)$' { return [System.Text.Encoding]::GetEncoding(51932) }
			'^(UTF-16LE|Unicode|1200)$' { return [System.Text.Encoding]::Unicode }
			'^(UTF-16BE|UnicodeBE|1201)$' { return [System.Text.Encoding]::BigEndianUnicode }
			default { return [System.Text.Encoding]::GetEncoding($Charset.Trim()) }
		}
	}
	catch {
		return [System.Text.Encoding]::UTF8
	}
}

# Peek at a request's raw bytes to find its Charset header (headers are ASCII, so Latin-1 is safe).
function Get-ShioriRequestCharset {
	param([byte[]]$Bytes)
	$ascii = [System.Text.Encoding]::GetEncoding(28591).GetString($Bytes)
	if ($ascii -match '(?im)^Charset:\s*([^\r\n]+)') { return $Matches[1].Trim() }
	return 'UTF-8'
}

# ---------------------------------------------------------------------------
# Request parsing / response formatting
# ---------------------------------------------------------------------------

function Parse-ShioriRequest {
	param([string]$Text)
	$lines = [System.Text.RegularExpressions.Regex]::Split($Text, "`r`n|`r|`n")
	$result = @{
		Command     = ''
		Protocol    = ''
		HeaderPairs = New-Object System.Collections.Generic.List[object]
		Headers     = @{}
		References  = @()
		PassThru    = @{}
	}
	if ($lines.Count -eq 0 -or [string]::IsNullOrWhiteSpace($lines[0])) { return $result }

	if ($lines[0] -match '^(\S+)\s+(\S+)\s*$') {
		$result.Command = $Matches[1]
		$result.Protocol = $Matches[2]
	}
	else {
		return $result
	}

	$referenceMap = @{}
	for ($i = 1; $i -lt $lines.Count; $i++) {
		$line = $lines[$i]
		if ([string]::IsNullOrEmpty($line)) { break }
		if ($line -notmatch '^([^:]+):\s?(.*)$') { continue }
		$key = $Matches[1].Trim()
		$value = $Matches[2]
		$result.Headers[$key] = $value
		$result.HeaderPairs.Add(@{ Key = $key; Value = $value })
		if ($key -match '^Reference(\d+)$') {
			$referenceMap[[int]$Matches[1]] = $value
		}
		elseif ($key -match '^X-SSTP-PassThru-(.+)$') {
			$result.PassThru[$Matches[1]] = $value
		}
	}

	if ($referenceMap.Count -gt 0) {
		$maxIndex = ($referenceMap.Keys | Measure-Object -Maximum).Maximum
		$references = New-Object object[] ($maxIndex + 1)
		for ($i = 0; $i -le $maxIndex; $i++) {
			$references[$i] = if ($referenceMap.ContainsKey($i)) { $referenceMap[$i] } else { '' }
		}
		$result.References = $references
	}
	return $result
}

# SHIORI/3.0 event IDs are conventionally `OnXxx`; legacy short IDs get the `On_` prefix (YAYA rule).
function Normalize-ShioriEventId {
	param([string]$EventId)
	if ([string]::IsNullOrEmpty($EventId)) { return '' }
	if ($EventId -notmatch '^On') { return 'On_' + $EventId }
	return $EventId
}

function Format-ShioriResponse {
	param([hashtable]$Context, [string]$Value, [bool]$IsNotify)
	$charset = $Context.Charset
	$hasValue = -not [string]::IsNullOrEmpty($Value)
	$lines = New-Object System.Collections.Generic.List[string]

	if ($IsNotify) {
		$lines.Add('SHIORI/3.0 204 No Content')
		$lines.Add("Charset: $charset")
		if ($hasValue) { $lines.Add("ValueNotify: $Value") }
	}
	elseif ($hasValue) {
		$lines.Add('SHIORI/3.0 200 OK')
		$lines.Add("Charset: $charset")
		$lines.Add("Sender: $($global:PSShiori.Name)")
		$lines.Add("Value: $Value")
	}
	else {
		$lines.Add('SHIORI/3.0 204 No Content')
		$lines.Add("Charset: $charset")
	}

	$referenceIndex = 0
	foreach ($reference in $Context.ResponseReference) {
		if (-not [string]::IsNullOrEmpty($reference)) { $lines.Add("Reference$referenceIndex`: $reference") }
		$referenceIndex++
	}
	if (-not [string]::IsNullOrEmpty($Context.Marker)) { $lines.Add("Marker: $($Context.Marker)") }
	if (-not [string]::IsNullOrEmpty($Context.SecurityLevelResponse)) { $lines.Add("SecurityLevel: $($Context.SecurityLevelResponse)") }
	foreach ($header in $Context.ResponseHeaders.GetEnumerator()) {
		$lines.Add("$($header.Key): $($header.Value)")
	}

	$lines.Add('')
	$lines.Add('')
	return ($lines -join "`r`n")
}

function Format-ShioriError {
	param([string]$Charset, [int]$StatusCode, [string]$Reason)
	return ("SHIORI/3.0 $StatusCode $Reason`r`nCharset: $Charset`r`n`r`n")
}

# ---------------------------------------------------------------------------
# Dictionary loading
# ---------------------------------------------------------------------------

function Read-ShioriTextFile {
	param([string]$Path)
	$bytes = [System.IO.File]::ReadAllBytes($Path)
	$utf8 = New-Object System.Text.UTF8Encoding($false, $true)
	try { $text = $utf8.GetString($bytes) }
	catch { $text = [System.Text.Encoding]::Default.GetString($bytes) }
	return $text.TrimStart([char]0xFEFF)
}

function Add-ShioriHandler {
	param([string]$Event, [object]$Handler, [string]$Source)
	$handlers = $global:PSShiori.Handlers
	$sources = $global:PSShiori.HandlerSources
	if ($Handler -is [string]) {
		$staticValue = $Handler
		$scriptBlock = { param($context) return $staticValue }.GetNewClosure()
	}
	elseif ($Handler -is [scriptblock]) {
		$scriptBlock = $Handler
	}
	else {
		$staticValue = "$Handler"
		$scriptBlock = { param($context) return $staticValue }.GetNewClosure()
	}

	if (-not $handlers.ContainsKey($Event)) {
		$handlers[$Event] = New-Object System.Collections.Generic.List[object]
		$sources[$Event] = New-Object System.Collections.Generic.List[string]
		$global:PSShiori.EventList.Add($Event) | Out-Null
	}
	$handlers[$Event].Add($scriptBlock)
	$sources[$Event].Add($Source)
	Write-PSShioriLog "registered handler for $Event ($Source)"
}

# Exposed to dictionaries. A dictionary may either call this, or simply `return @{ Event = { ... } }`.
function Register-ShioriEvent {
	param(
		[Parameter(Mandatory = $true, Position = 0)][string]$Event,
		[Parameter(Mandatory = $true, Position = 1)][object]$Handler,
		[string]$Source = ''
	)
	Add-ShioriHandler -Event $Event -Handler $Handler -Source $Source
}

function Import-ShioriDictionary {
	param([string]$Path, [string]$Source)
	$text = Read-ShioriTextFile -Path $Path
	$scriptBlock = [scriptblock]::Create($text)
	$result = & $scriptBlock
	if ($result -is [System.Collections.IDictionary]) {
		foreach ($entry in $result.GetEnumerator()) {
			Add-ShioriHandler -Event ([string]$entry.Key) -Handler $entry.Value -Source $Source
		}
	}
}

function Find-ShioriDictionaries {
	param([string]$Directory)
	if (-not (Test-Path -LiteralPath $Directory)) { return @() }

	$orderFile = Join-Path $Directory '_loading_order.txt'
	$files = @(Get-ChildItem -LiteralPath $Directory -Filter '*.dic.ps1' -File -ErrorAction SilentlyContinue)
	$byName = @{}
	foreach ($file in $files) { $byName[$file.Name] = $file.FullName }

	$ordered = New-Object System.Collections.Generic.List[string]
	if (Test-Path -LiteralPath $orderFile) {
		foreach ($line in (Read-ShioriTextFile -Path $orderFile) -split "`r`n|`r|`n") {
			$name = $line.Trim()
			if ([string]::IsNullOrEmpty($name) -or $name.StartsWith('//')) { continue }
			if (-not $name.EndsWith('.dic.ps1')) { $name += '.dic.ps1' }
			if ($byName.ContainsKey($name)) {
				$ordered.Add($byName[$name])
				$byName.Remove($name)
			}
		}
		foreach ($name in ($byName.Keys | Sort-Object)) { $ordered.Add($byName[$name]) }
	}
	else {
		foreach ($name in ($byName.Keys | Sort-Object)) { $ordered.Add($byName[$name]) }
	}
	return $ordered
}

function Reset-ShioriDictionaries {
	$global:PSShiori.Handlers = @{}
	$global:PSShiori.HandlerSources = @{}
	$global:PSShiori.EventList = New-Object System.Collections.Generic.List[string]
}

function Initialize-ShioriRuntime {
	param([string]$ModulePath)
	$directory = $ModulePath
	if (-not [string]::IsNullOrEmpty($directory)) {
		$directory = $directory.TrimEnd('\', '/')
	}
	$global:PSShiori.Path = $directory
	$global:PSShiori.Loaded = $true
	$global:PSShiori.LastSurface = @(0, 10)
	$global:PSShiori.IsVisible = @(1, 1)
	$global:PSShiori.UniqueId = ''

	Reset-ShioriDictionaries
	foreach ($file in (Find-ShioriDictionaries -Directory $directory)) {
		try {
			Import-ShioriDictionary -Path $file -Source ([System.IO.Path]::GetFileName($file))
		}
		catch {
			Write-PSShioriLog "failed to load dictionary $file : $($_.Exception.Message)"
		}
	}
	Write-PSShioriLog "loaded $($global:PSShiori.EventList.Count) event handlers from $directory"
}

# ---------------------------------------------------------------------------
# Event dispatch
# ---------------------------------------------------------------------------

function Update-ShioriBuiltinState {
	param([hashtable]$Context)
	switch ($Context.Event) {
		'OnSurfaceChange' {
			if ($Context.Reference.Count -ge 3 -and $Context.Reference[2] -ne '') {
				$parts = $Context.Reference[2] -split ','
				if ($parts.Count -ge 2) {
					$character = [int]$parts[0]
					$surface = [int]$parts[1]
					if ($surface -ge 0) {
						$global:PSShiori.LastSurface[$character] = $surface
						$global:PSShiori.IsVisible[$character] = 1
					}
					else { $global:PSShiori.IsVisible[$character] = 0 }
				}
			}
			elseif ($Context.Reference.Count -ge 2) {
				$sakura = [int]$Context.Reference[0]
				$kero = [int]$Context.Reference[1]
				if ($sakura -ge 0) { $global:PSShiori.LastSurface[0] = $sakura; $global:PSShiori.IsVisible[0] = 1 }
				else { $global:PSShiori.IsVisible[0] = 0 }
				if ($kero -ge 0) { $global:PSShiori.LastSurface[1] = $kero; $global:PSShiori.IsVisible[1] = 1 }
				else { $global:PSShiori.IsVisible[1] = 0 }
			}
		}
		'On_uniqueid' {
			if ($Context.Reference.Count -ge 1) { $global:PSShiori.UniqueId = $Context.Reference[0] }
		}
		'OnNotifySelfInfo' {
			if ($Context.Reference.Count -ge 1) { $global:PSShiori.GhostName = $Context.Reference[0] }
			if ($Context.Reference.Count -ge 4) { $global:PSShiori.ShellName = $Context.Reference[3] }
			if ($Context.Reference.Count -ge 7) { $global:PSShiori.BalloonName = $Context.Reference[5] }
		}
	}
}

function Get-ShioriDefaultScript {
	param([hashtable]$Context)
	switch ($Context.Event) {
		'OnFirstBoot' {
			if ($global:PSShiori.Handlers.ContainsKey('OnBoot') -and $global:PSShiori.Handlers['OnBoot'].Count -gt 0) { return '' }
			return '\0\s[0]\1\s[10]\e'
		}
		'OnBoot' { return '\0\s[0]\1\s[10]\e' }
		'OnWindowStateRestore' { return '\0\s[0]\1\s[10]\e' }
		'OnClose' { return '\0\-\e' }
		default { return '' }
	}
}

function Invoke-ShioriEvent {
	param([hashtable]$Context)
	Update-ShioriBuiltinState -Context $Context

	$handlers = $global:PSShiori.Handlers
	if ($handlers.ContainsKey($Context.Event)) {
		$list = $handlers[$Context.Event]
		for ($i = $list.Count - 1; $i -ge 0; $i--) {
			$result = & $list[$i] $Context
			if ($null -ne $result -and "$result" -ne '') { return "$result" }
		}
	}
	return (Get-ShioriDefaultScript -Context $Context)
}

function New-ShioriContext {
	param([hashtable]$Request, [string]$Charset, [string]$Event)
	return @{
		Event                = $Event
		Command              = $Request.Command
		Protocol             = $Request.Protocol
		Charset              = $Charset
		Sender               = [string]$Request.Headers['Sender']
		SenderType           = [string]$Request.Headers['SenderType']
		SecurityLevel        = [string]$Request.Headers['SecurityLevel']
		Status               = [string]$Request.Headers['Status']
		BaseId               = [string]$Request.Headers['BaseID']
		Headers              = $Request.Headers
		Reference            = $Request.References
		PassThru             = $Request.PassThru
		ResponseHeaders      = (New-Object System.Collections.Specialized.OrderedDictionary)
		ResponseReference    = @()
		Marker               = ''
		SecurityLevelResponse = ''
	}
}

# ---------------------------------------------------------------------------
# Main request pipeline
# ---------------------------------------------------------------------------

function Invoke-PSShioriRequest {
	param([string]$RequestText, [string]$Charset)
	$request = Parse-ShioriRequest -Text $RequestText
	if ([string]::IsNullOrEmpty($request.Command) -or [string]::IsNullOrEmpty($request.Protocol)) {
		return (Format-ShioriError -Charset $Charset -StatusCode 400 -Reason 'Bad Request')
	}
	$command = $request.Command.ToUpperInvariant()
	if ($command -ne 'GET' -and $command -ne 'NOTIFY') {
		return (Format-ShioriError -Charset $Charset -StatusCode 400 -Reason 'Bad Request')
	}

	$event = Normalize-ShioriEventId -EventId ([string]$request.Headers['ID'])
	$context = New-ShioriContext -Request $request -Charset $Charset -Event $event
	$value = Invoke-ShioriEvent -Context $context
	return (Format-ShioriResponse -Context $context -Value $value -IsNotify ($command -eq 'NOTIFY'))
}

# ---------------------------------------------------------------------------
# Exported entry points
# ---------------------------------------------------------------------------

function loadu {
	param([IntPtr]$h, [int]$len)
	try {
		$bytes = Read-HGlobalBytes -Handle $h -Length $len
		[void][PSShiori.Native]::GlobalFree($h)
		$path = [System.Text.Encoding]::UTF8.GetString($bytes)
		Initialize-ShioriRuntime -ModulePath $path
		return $true
	}
	catch {
		Write-PSShioriLog "loadu failed: $($_.Exception.Message)"
		return $false
	}
}

function load {
	param([IntPtr]$h, [int]$len)
	if ($global:PSShiori.Loaded) {
		[void][PSShiori.Native]::GlobalFree($h)
		return $true
	}
	try {
		$bytes = Read-HGlobalBytes -Handle $h -Length $len
		[void][PSShiori.Native]::GlobalFree($h)
		$path = [System.Text.Encoding]::Default.GetString($bytes)
		Initialize-ShioriRuntime -ModulePath $path
		return $true
	}
	catch {
		Write-PSShioriLog "load failed: $($_.Exception.Message)"
		return $false
	}
}

function unload {
	$global:PSShiori.Loaded = $false
	Reset-ShioriDictionaries
	return $true
}

function CI_check_failed { return $false }

function request {
	param([IntPtr]$h, [IntPtr]$len)
	$length = 0
	try {
		$length = [System.Runtime.InteropServices.Marshal]::ReadInt32($len)
		$bytes = Read-HGlobalBytes -Handle $h -Length $length
		[void][PSShiori.Native]::GlobalFree($h)

		$charset = Get-ShioriRequestCharset -Bytes $bytes
		$encoding = Get-ShioriEncoding -Charset $charset
		$requestText = $encoding.GetString($bytes)
		$responseText = Invoke-PSShioriRequest -RequestText $requestText -Charset $charset

		$responseBytes = (Get-ShioriEncoding -Charset $charset).GetBytes($responseText)
		$out = New-HGlobalBytes -Bytes $responseBytes
		[System.Runtime.InteropServices.Marshal]::WriteInt32($len, $responseBytes.Length)
		return $out
	}
	catch {
		Write-PSShioriLog "request failed: $($_.Exception.Message)"
		$out = New-HGlobalBytes -Bytes ([System.Text.Encoding]::UTF8.GetBytes("SHIORI/3.0 500 Internal Server Error`r`nCharset: UTF-8`r`n`r`n"))
		[System.Runtime.InteropServices.Marshal]::WriteInt32($len, [System.Text.Encoding]::UTF8.GetByteCount("SHIORI/3.0 500 Internal Server Error`r`nCharset: UTF-8`r`n`r`n"))
		return $out
	}
}

# ---------------------------------------------------------------------------
# Module state (runs once, when ps12exe's DLL loader dot-sources this script)
# ---------------------------------------------------------------------------

$global:PSShiori = @{
	Name            = 'PowerShell'
	Loaded          = $false
	Path            = ''
	Handlers        = @{}
	HandlerSources  = @{}
	EventList       = New-Object System.Collections.Generic.List[string]
	LastSurface     = @(0, 10)
	IsVisible       = @(1, 1)
	UniqueId        = ''
	GhostName       = ''
	ShellName       = ''
	BalloonName     = ''
}
