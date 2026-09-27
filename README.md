# powershiori

A [SHIORI/3.0](https://ssp.shillest.net/ukadoc/manual/spec_shiori3.html) shiori written in pure PowerShell. The whole interpreter lives in `powershiori.ps1`; [ps12exe](https://github.com/steve02081504/ps12exe) compiles it into a native Win32 DLL whose exported entry points (`loadu`/`load`/`unload`/`request`) the baseware resolves with `LoadLibrary`/`GetProcAddress`, exactly like YAYA or any other shiori DLL.

It reimplements the essentials of the SHIORI/3.0 request/response cycle that [YAYA](https://github.com/YAYA-shiori/yaya-shiori) and the [yaya-dic](https://github.com/YAYA-shiori/yaya-dic) base dictionary rely on, but the dictionary format is native PowerShell rather than YAYA's Lua-like language.

## Requirements

- Windows, 64-bit baseware (SSP, or [shioricaller](https://github.com/ukatech/shioricaller))
- A PowerShell interpreter on `PATH` (`pwsh` preferred, `powershell` accepted)
- .NET Framework 4.0 (ps12exe's native DLL exports only support Framework4.0 + x86/x64)

## Build

```bat
build.bat
```

`build.bat` finds a PowerShell host (errors out if there is none), installs the `ps12exe` module from the gallery if it is missing, then compiles `powershiori.ps1` into `powershiori.dll`. The target (`Framework4.0`, `x64`) is pinned by `#_pragma` directives inside `powershiori.ps1`, so no build options are needed.

## Test

```powershell
./tests/Run-Tests.ps1 -Build
```

The tests load the compiled DLL through the same native interface SSP uses and assert the SHIORI responses. Because the DLL hosts .NET Framework PowerShell, the tests run under 64-bit Windows PowerShell 5.1; `Run-Tests.ps1` re-launches itself there automatically when started from pwsh.

## Install into a ghost

Put the built DLL where SSP looks for it (typically `ghost/master/shiori.dll`, or whatever `shiori`/`shiori.dllname` in the ghost's `descript.txt` points at) and drop `.dic.ps1` dictionaries next to it in `ghost/master/`.

## Request flow

1. SSP calls `loadu(dir)` with the module directory as a UTF-8 `HGLOBAL`. `load` (OEM codepage) is the legacy fallback; if `loadu` already ran, `load` just frees its buffer.
2. Each `*.dic.ps1` in that directory is loaded. `_loading_order.txt` (one filename per line, `//` comments allowed) controls order; otherwise files load alphabetically.
3. Every request arrives through `request(HGLOBAL, long*)`. Request strings are decoded using their `Charset` header (UTF-8, Shift_JIS/CP932, EUC-JP, UTF-16 supported), the id is normalized, and a registered handler is invoked. Responses use the request's charset.
4. `unload` clears the handlers.

## Dictionary format

A `.dic.ps1` file either returns a hashtable of event name to handler, or calls the globally available `Register-ShioriEvent`:

```powershell
# hashtable style
@{
    OnBoot = {
        param($context)
        '\0\s[0]\1\s[10]\e'
    }
    OnMouseDoubleClick = 'static-string-is-also-fine'
}
```

```powershell
# imperative style
Register-ShioriEvent OnBoot {
    param($context)
    '\0\s[0]\1\s[10]\e'
}
```

A handler is invoked as `& $handler $context`. Return a SakuraScript string for a `Value`/`ValueNotify` response, or an empty string to fall through to an earlier handler and finally to the built-in default. When the same event is defined by several files, the last one loaded is tried first.

### `$context`

| field | meaning |
| --- | --- |
| `Event` | normalized event id (`OnBoot`, `On_foo`, …) |
| `Command` | `GET` or `NOTIFY` |
| `Protocol` | e.g. `SHIORI/3.0` |
| `Charset` | request/response charset |
| `Sender`, `SenderType`, `SecurityLevel`, `Status`, `BaseId` | request headers |
| `Headers` | all headers (case-insensitive) |
| `Reference` / `PassThru` | `ReferenceN` values (array) and `X-SSTP-PassThru-*` values |
| `ResponseHeaders` | extra response headers (ordered dictionary) |
| `ResponseReference` | array emitted as `Reference0`, `Reference1`, … |
| `Marker`, `SecurityLevelResponse` | emitted as `Marker` / `SecurityLevel` headers |

### Built-in defaults

Following YAYA's `yaya_base/shiori3.dic`:

| event | response |
| --- | --- |
| `OnFirstBoot` | `204` if an `OnBoot` handler exists, else the boot script |
| `OnBoot`, `OnWindowStateRestore` | `\0\s[0]\1\s[10]\e` |
| `OnClose` | `\0\-\e` |
| anything else with no handler | `204 No Content` |

`OnSurfaceChange`, `On_uniqueid` and `OnNotifySelfInfo` update built-in state (`$global:PSShiori.LastSurface`, `IsVisible`, `UniqueId`, …). `NOTIFY` requests always answer `204`, returning any script through the SSP `ValueNotify` extension.

## Differences from YAYA

- Dictionaries are PowerShell, not the YAYA dic language. There is no `#define`, `case`, `foreach` or SakuraScript-level variable system — use PowerShell.
- No SAORI loading, `OnTranslate`, chain/eval (`:chain=`, `:eval=`), random-talk scheduling or variable persistence yet; handlers can implement any of those themselves.
- The exported surface is limited to `loadu`, `load`, `unload`, `request` and `CI_check_failed`.
