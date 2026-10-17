# Google Antigravity Visual Studio 2026 Extension Patch

Automated, fail-closed patcher for the Google Antigravity extension in Visual Studio 2026 (`Antigravity.VisualStudio.dll`).

## Problem Overview

In Visual Studio 2026 (tested on extension version `1.0.261012.0` / internal `1.0.0.0`), the Antigravity ToolWindow hangs indefinitely displaying:
```
Working...
```
Inspecting the extension via Edge DevTools (`edge://inspect`) reveals that network RPC requests show status **Stalled** indefinitely.

### Root Cause
1. In `Google.Antigravity.VisualStudio.AntigravityToolWindowControl.BuildTargetUrlWithWorkspace` and `ConnectAndNavigateAsync`, the target URL was constructed without `&useWebSocket=true`.
2. When `useWebSocket=true` is omitted, the web application falls back to HTTP/1.1 streaming RPCs.
3. Chromium / WebView2 enforces a hard limit of **6 concurrent HTTP/1.1 connections per origin** (`MaxSocketsPerGroup = 6`).
4. Because the Antigravity agent UI maintains 6 long-lived streaming connections for agent event streams, any subsequent HTTP request is queued indefinitely in Chromium's socket pool, stalling all further communication.

## What This Patch Does

The patcher uses `Mono.Cecil` to safely update string literals in `Antigravity.VisualStudio.dll`:
1. `BuildTargetUrlWithWorkspace` (primary and debugUrl branches) - appends `&serverUrl=http://{0}:{1}&useWebSocket=true`.
2. `ConnectAndNavigateAsync` (primary and debugUrl branches) - appends `&serverUrl=http://{0}:{1}&useWebSocket=true`.
3. `AntigravityScriptUtils.BuildScript` - injects a preload safety guard ensuring `window.location` activates WebSocket mode.

No IL instructions or control flow logic are changed. Only operand string constants are updated.
Metadata integrity is verified using Microsoft `PEVerify.exe`.

## Usage

### 1. Dry Run (Check Status)
```powershell
pwsh -NoProfile -File .\Patch-AntigravityVS.ps1 -DryRun
```

### 2. Apply Patch
Ensure Visual Studio 2026 is closed before applying:
```powershell
pwsh -NoProfile -File .\Patch-AntigravityVS.ps1
```

### 3. Restore Original
```powershell
pwsh -NoProfile -File .\Patch-AntigravityVS.ps1 -Restore
```

## Safety Invariants
- **Idempotent:** Re-running against an already-patched DLL makes no changes and exits 0.
- **Fail-Closed:** If an upstream update alters the expected method signatures or strings, nothing is modified and an error code is returned.
- **Automated Backups:** Original DLLs are saved under `$env:LOCALAPPDATA\AntigravityVSPatch\backups` with SHA-256 manifests.
- **No Process Disruption:** Never forces or kills running processes. If the DLL is locked by Visual Studio, it prompts you to close VS first.
