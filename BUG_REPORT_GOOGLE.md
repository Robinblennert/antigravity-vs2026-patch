# Bug Report: Visual Studio 2026 Antigravity Extension Stalls Indefinitely on "Working..."

## Component
- **Product:** Google Antigravity Extension for Visual Studio 2026
- **Assembly:** `Antigravity.VisualStudio.dll`
- **Observed Version:** `1.0.261012.0` (File version `1.0.0.0`)
- **Platform:** Windows x64, Visual Studio 2026 Enterprise (`18.10.x`), Microsoft.Web.WebView2

---

## Summary
The Antigravity tool window in Visual Studio 2026 permanently hangs on `"Working..."`. In Edge DevTools (`edge://inspect`), pending RPC requests to the local language server / agent backend show state **Stalled** indefinitely.

---

## Root Cause Analysis
1. In `Google.Antigravity.VisualStudio.AntigravityToolWindowControl`:
   - `BuildTargetUrlWithWorkspace`:
     ```csharp
     // Current upstream implementation:
     string text2 = string.Format(
         CultureInfo.InvariantCulture,
         "http://{0}:{1}{2}{3}extensionView=true&extensionVariant=visual-studio&hostVersion={4}&hostTheme={5}&workspaceUri={6}&extensionVersion={7}",
         ...);
     ```
   - Notice that `&useWebSocket=true` is omitted from the URL query string.
2. In the Chromium network stack (underlying WebView2):
   - Without `useWebSocket=true`, the web UI falls back to HTTP/1.1 chunked/streaming RPCs.
   - Chromium imposes a strict hard ceiling of **6 concurrent connections per host/port** (`kDefaultMaxSocketsPerGroup = 6`).
3. As the UI initializes, it establishes 6 persistent long-lived streams (events, logging, status, trajectory, terminal, and agent bridge).
4. All 6 sockets remain occupied. Any subsequent request (such as user prompt submission or tool confirmation) is placed in Chromium's socket queue awaiting a free slot, resulting in an indefinite **Stalled** status.

---

## Suggested Fix
1. In `BuildTargetUrlWithWorkspace` and `ConnectAndNavigateAsync`, include `serverUrl` and `useWebSocket=true`:
   ```csharp
   "http://{0}:{1}{2}{3}extensionView=true&extensionVariant=visual-studio&hostVersion={4}&hostTheme={5}&serverUrl=http://{0}:{1}&useWebSocket=true&workspaceUri={6}&extensionVersion={7}"
   ```
2. When `useWebSocket=true` is supplied, communication multiplexes through a single persistent WebSocket connection (`ws://127.0.0.1:<port>/...`), consuming only 1 socket out of the 6-connection pool.
3. This completely prevents socket pool exhaustion and resolves the stalled connection hang.
