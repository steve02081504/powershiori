# AGENTS.md

Pure-PowerShell SHIORI/3.0 shiori. `powershiori.ps1` holds the whole implementation, including the `#_DllExport` directives that ps12exe turns into native DLL exports.

## Layout

- `powershiori.ps1` — shiori source (protocol, GlobalAlloc marshalling, dictionary loader, dispatch). `#_pragma Build.Target/Build.Platform` pin Framework4.0 + x64 so the build needs no options.
- `build.bat` — finds a PowerShell host, installs `ps12exe` if missing, compiles to `powershiori.dll`
- `tests/Run-Tests.ps1` — native P/Invoke tests (`-Build` to rebuild first)
- `tests/example/ghost/master/*.dic.ps1` — example dictionaries used by the tests

## Build & test

```powershell
./build.bat                       # anywhere; uses pwsh if present, else powershell
./tests/Run-Tests.ps1 -Build      # any shell; re-launches under powershell.exe 5.1
```

## Hard constraints (do not fight these)

- ps12exe native exports require `Build.Target='Framework4.0'` and an explicit `x64`/`x86` platform; AnyCPU and Core are rejected.
- The built DLL hosts .NET Framework PowerShell, so it can only be loaded by a .NET Framework process: test with 64-bit Windows PowerShell 5.1, never from pwsh 7 / any .NET Core host.
- `#_DllExport <cstype> name(cstype arg, ...)` generates a C# `cdecl` wrapper that calls the like-named PowerShell function with the arguments and casts the (single) returned object to the return type. The PowerShell function must emit exactly one object — guard helper calls with `[void]`, never leave stray pipeline output.
- ps12exe's static analyzer warns about functions used before their definition; define helpers before callers to keep builds warning-free.

## SHIORI/3.0 DLL contract (ukadoc spec_dll)

- Strings cross the boundary via Win32 global memory: caller `GlobalAlloc(GMEM_FIXED)`s, module `GlobalFree`s the input and returns a freshly allocated `HGLOBAL`. `request` gets `long* len` (32-bit on Windows) — read/write it with `Marshal.ReadInt32`/`WriteInt32`.
- Exports implemented: `loadu` (UTF-8 path), `load` (OEM path, fallback), `unload`, `request`, `CI_check_failed`. shioricaller only resolves `load`, not `loadu`, so both must work.
- Response uses CRLF and ends with a blank line (CRLF CRLF).

## References

- Protocol: https://ssp.shillest.net/ukadoc/manual/spec_shiori3.html and `spec_dll.html`
- Behaviour modelled on YAYA's `yaya_base/shiori3.dic` (built-in event defaults, NOTIFY/ValueNotify)
- Loader reference: https://github.com/ukatech/shioricaller (`shiori_loader.cpp`)
