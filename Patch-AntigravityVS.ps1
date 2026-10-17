<#
.SYNOPSIS
    Re-applies the WebSocket transport fix to the Google Antigravity extension for Visual Studio 2026.

.DESCRIPTION
    Antigravity.VisualStudio.dll (observed: v1.0.261012.0) builds the WebView2 URL for the agent UI
    without `useWebSocket=true`. The web client then falls back to HTTP/1.1 streaming RPCs. Chromium
    allows max 6 concurrent HTTP/1.1 connections per origin, and the agent UI opens >= 6 long-lived
    streams, so later requests sit in "Stalled" forever and the chat stays on "Working...".

    This script rewrites the string literals (ldstr operands) that build that URL so the client uses a
    single multiplexed WebSocket. No IL control flow is changed.

    Properties:
      * Idempotent      - already patched DLLs are detected and left untouched.
      * Fail-closed     - if a required upstream string is missing (new extension version changed the
                          code), nothing is written and the script exits non-zero.
      * Backed up       - the original DLL is stored under %LOCALAPPDATA%\AntigravityVSPatch\backups
                          with a manifest (SHA-256 before/after) and can be restored with -Restore.
      * Never kills processes - if Visual Studio holds the DLL, the script stops and asks you to close VS.

.PARAMETER DllPath
    Explicit DLL path(s). Default: every Antigravity.VisualStudio.dll under
    %LOCALAPPDATA%\Microsoft\VisualStudio\18.0_*\Extensions\.

.PARAMETER DryRun
    Report state only. Nothing is written.

.PARAMETER Restore
    Put back the original DLL from the backup whose recorded patched SHA-256 matches the current file.

.EXAMPLE
    pwsh -NoProfile -File .\Patch-AntigravityVS.ps1 -DryRun
.EXAMPLE
    pwsh -NoProfile -File .\Patch-AntigravityVS.ps1
.EXAMPLE
    pwsh -NoProfile -File .\Patch-AntigravityVS.ps1 -Restore

.NOTES
    Exit codes: 0 = OK (patched or already patched), 2 = upstream changed / required string missing,
                3 = DLL locked (close Visual Studio), 4 = verification failed (rolled back), 1 = other error.
#>
[CmdletBinding()]
param(
    [string[]] $DllPath,
    [switch] $DryRun,
    [switch] $Restore,
    [string] $BackupRoot = (Join-Path $env:LOCALAPPDATA 'AntigravityVSPatch\backups')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$PatchId = 'agy-vs-websocket-transport-v1'
$CtrlType = 'Google.Antigravity.VisualStudio.AntigravityToolWindowControl'
$ScriptType = 'Google.Antigravity.VisualStudio.Utils.AntigravityScriptUtils'

$JsOldPrefix = "`r`n(function() {`r`n    let rpcId = 1;"
$JsNewPrefix = "`r`n(function() {`r`n    try {`r`n        if (window.location && window.location.protocol.startsWith('http') && !window.location.search.includes('useWebSocket=')) {`r`n            const sep = window.location.search ? '&' : '?';`r`n            window.history.replaceState(null, '', window.location.pathname + window.location.search + sep + 'useWebSocket=true' + window.location.hash);`r`n        }`r`n    } catch (e) {}`r`n    let rpcId = 1;"

# Each rule targets ldstr operands inside one method. Kind: Equals = whole literal, Prefix = literal start.
$Rules = @(
    [pscustomobject]@{ Name = 'BuildTargetUrlWithWorkspace/primary'; Type = $CtrlType; Nested = $null; Method = 'BuildTargetUrlWithWorkspace'; Params = -1; Kind = 'Equals'; Required = $true
        Old = 'http://{0}:{1}{2}{3}extensionView=true&extensionVariant=visual-studio&hostVersion={4}&hostTheme={5}&workspaceUri={6}&extensionVersion={7}'
        New = 'http://{0}:{1}{2}{3}extensionView=true&extensionVariant=visual-studio&hostVersion={4}&hostTheme={5}&serverUrl=http://{0}:{1}&useWebSocket=true&workspaceUri={6}&extensionVersion={7}' }
    [pscustomobject]@{ Name = 'BuildTargetUrlWithWorkspace/debugUrl'; Type = $CtrlType; Nested = $null; Method = 'BuildTargetUrlWithWorkspace'; Params = -1; Kind = 'Equals'; Required = $false
        Old = 'extensionView=true&extensionVariant=visual-studio&hostVersion='
        New = 'extensionView=true&useWebSocket=true&extensionVariant=visual-studio&hostVersion=' }
    [pscustomobject]@{ Name = 'ConnectAndNavigateAsync/primary'; Type = $CtrlType; Nested = 'ConnectAndNavigateAsync'; Method = 'MoveNext'; Params = -1; Kind = 'Equals'; Required = $true
        Old = 'http://{0}:{1}{2}{3}extensionView=true&extensionVariant=visual-studio&hostVersion={4}&hostTheme={5}'
        New = 'http://{0}:{1}{2}{3}extensionView=true&extensionVariant=visual-studio&hostVersion={4}&hostTheme={5}&serverUrl=http://{0}:{1}&useWebSocket=true' }
    [pscustomobject]@{ Name = 'ConnectAndNavigateAsync/debugUrl'; Type = $CtrlType; Nested = 'ConnectAndNavigateAsync'; Method = 'MoveNext'; Params = -1; Kind = 'Equals'; Required = $false
        Old = 'extensionView=true&extensionVariant=visual-studio&hostVersion='
        New = 'extensionView=true&useWebSocket=true&extensionVariant=visual-studio&hostVersion=' }
    [pscustomobject]@{ Name = 'AntigravityScriptUtils.BuildScript/preload-guard'; Type = $ScriptType; Nested = $null; Method = 'BuildScript'; Params = 1; Kind = 'Prefix'; Required = $true
        Old = $JsOldPrefix
        New = $JsNewPrefix }
)

function Get-Sha256([string] $Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }

function Read-AllBytesShared([string] $Path) {
    $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try {
        $ms = [System.IO.MemoryStream]::new()
        $fs.CopyTo($ms)
        return $ms.ToArray()
    } finally { $fs.Dispose() }
}

function Test-FileWritable([string] $Path) {
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $fs.Dispose()
        return $true
    } catch [System.IO.IOException] { return $false }
}

function Find-MonoCecil {
    $candidates = [System.Collections.Generic.List[string]]::new()
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vsRoots = @()
    if (Test-Path -LiteralPath $vswhere) {
        $vsRoots = @(& $vswhere -prerelease -all -property installationPath 2>$null | Where-Object { $_ })
    }
    $vsRoots += @(Get-ChildItem -LiteralPath (Join-Path $env:ProgramFiles 'Microsoft Visual Studio') -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue } | ForEach-Object { $_.FullName })
    foreach ($root in ($vsRoots | Select-Object -Unique)) {
        $candidates.Add((Join-Path $root 'Common7\IDE\Extensions\Microsoft\CodeCoverage.Console\Mono.Cecil.dll'))
    }
    $nuget = Join-Path $env:USERPROFILE '.nuget\packages\mono.cecil'
    if (Test-Path -LiteralPath $nuget) {
        Get-ChildItem -LiteralPath $nuget -Recurse -Filter 'Mono.Cecil.dll' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\lib\\netstandard2\.0\\' } |
            Sort-Object FullName -Descending | ForEach-Object { $candidates.Add($_.FullName) }
    }
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    throw 'Mono.Cecil.dll not found. Install Visual Studio 2026 (CodeCoverage.Console ships it) or run: dotnet add package Mono.Cecil in any project to populate the NuGet cache.'
}

function Find-TargetDlls {
    $root = Join-Path $env:LOCALAPPDATA 'Microsoft\VisualStudio'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    @(Get-ChildItem -LiteralPath $root -Directory -Filter '18.0_*' -ErrorAction SilentlyContinue | ForEach-Object {
        $ext = Join-Path $_.FullName 'Extensions'
        if (Test-Path -LiteralPath $ext) {
            Get-ChildItem -LiteralPath $ext -Recurse -Filter 'Antigravity.VisualStudio.dll' -File -ErrorAction SilentlyContinue
        }
    } | ForEach-Object { $_.FullName })
}

function Get-RuleMethod($Module, $Rule) {
    $type = $Module.GetType($Rule.Type)
    if ($null -eq $type) { return $null }
    if ($Rule.Nested) {
        $type = @($type.NestedTypes | Where-Object { $_.Name -match [regex]::Escape($Rule.Nested) }) | Select-Object -First 1
        if ($null -eq $type) { return $null }
    }
    $m = @($type.Methods | Where-Object { $_.Name -eq $Rule.Method -and $_.HasBody -and ($Rule.Params -lt 0 -or $_.Parameters.Count -eq $Rule.Params) })
    if ($m.Count -ne 1) { return $null }
    return $m[0]
}

function Test-Old($Rule, [string] $s) { if ($Rule.Kind -eq 'Equals') { $s -ceq $Rule.Old } else { $s.StartsWith($Rule.Old, [System.StringComparison]::Ordinal) } }
function Test-New($Rule, [string] $s) { if ($Rule.Kind -eq 'Equals') { $s -ceq $Rule.New } else { $s.StartsWith($Rule.New, [System.StringComparison]::Ordinal) } }

# Returns per-rule state and (optionally) applies replacements in-memory.
function Invoke-Rules($Module, [bool] $Apply) {
    $report = foreach ($rule in $Rules) {
        $method = Get-RuleMethod $Module $rule
        $old = 0; $new = 0
        if ($null -ne $method) {
            foreach ($ins in $method.Body.Instructions) {
                if ($ins.OpCode.Code -ne [Mono.Cecil.Cil.Code]::Ldstr) { continue }
                $s = [string]$ins.Operand
                if (Test-New $rule $s) { $new++; continue }
                if (Test-Old $rule $s) {
                    $old++
                    if ($Apply) {
                        if ($rule.Kind -eq 'Equals') { $ins.Operand = $rule.New }
                        else { $ins.Operand = $rule.New + $s.Substring($rule.Old.Length) }
                    }
                }
            }
        }
        $state = if ($null -eq $method) { 'MethodMissing' } elseif ($old -gt 0) { 'NeedsPatch' } elseif ($new -gt 0) { 'Patched' } else { 'StringMissing' }
        [pscustomobject]@{ Rule = $rule.Name; Required = $rule.Required; State = $state; OldHits = $old; NewHits = $new }
    }
    return @($report)
}

function Invoke-PEVerify([string] $Path) {
    $pv = @(
        "${env:ProgramFiles(x86)}\Microsoft SDKs\Windows\v10.0A\bin\NETFX 4.8.1 Tools\x64\PEVerify.exe",
        "${env:ProgramFiles(x86)}\Microsoft SDKs\Windows\v10.0A\bin\NETFX 4.8 Tools\x64\PEVerify.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $pv) { Write-Warning 'PEVerify.exe not found; skipping metadata verification.'; return $true }
    $out = & $pv /md /nologo $Path 2>&1
    $code = $LASTEXITCODE
    $out | ForEach-Object { Write-Host "    PEVerify: $_" }
    return ($code -eq 0)
}

# ---------------------------------------------------------------------------------------------
$exit = 0
try {
    $targets = @(if ($DllPath) { $DllPath | ForEach-Object { (Resolve-Path -LiteralPath $_).Path } } else { Find-TargetDlls })
    if ($targets.Count -eq 0) { Write-Host 'No Antigravity.VisualStudio.dll found under %LOCALAPPDATA%\Microsoft\VisualStudio\18.0_*\Extensions.'; exit 0 }

    if ($Restore) {
        foreach ($dll in $targets) {
            $cur = Get-Sha256 $dll
            $manifest = Get-ChildItem -LiteralPath $BackupRoot -Recurse -Filter 'manifest.json' -ErrorAction SilentlyContinue |
                ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json | Add-Member -PassThru NoteProperty Dir $_.DirectoryName } |
                Where-Object { $_.PatchedSha256 -eq $cur } | Select-Object -First 1
            if (-not $manifest) { Write-Host "[$dll] no backup whose patched SHA-256 matches $cur - nothing restored."; continue }
            if (-not (Test-FileWritable $dll)) { Write-Host "[$dll] is locked. Close Visual Studio and re-run."; $exit = 3; continue }
            [System.IO.File]::Copy((Join-Path $manifest.Dir 'Antigravity.VisualStudio.dll'), $dll, $true)
            Write-Host "[$dll] restored original (SHA-256 $(Get-Sha256 $dll))."
        }
        exit $exit
    }

    $cecil = Find-MonoCecil
    [void][System.Reflection.Assembly]::LoadFrom($cecil)
    Write-Host "Mono.Cecil: $cecil"

    foreach ($dll in $targets) {
        Write-Host ''
        Write-Host "== $dll"
        $version = (Get-Item -LiteralPath $dll).VersionInfo.FileVersion
        $shaBefore = Get-Sha256 $dll
        Write-Host "   FileVersion: $version   SHA-256: $shaBefore"

        $bytes = Read-AllBytesShared $dll
        $ms = [System.IO.MemoryStream]::new($bytes)
        $asm = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($ms)
        try {
            $report = Invoke-Rules $asm.MainModule $false
            $report | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

            $blocking = @($report | Where-Object { $_.Required -and $_.State -in 'MethodMissing', 'StringMissing' })
            if ($blocking.Count -gt 0) {
                Write-Host '   UPSTREAM CHANGED: a required target was not found. Nothing written. Review the new extension version before patching.'
                $exit = [Math]::Max($exit, 2); continue
            }
            $pending = @($report | Where-Object { $_.State -eq 'NeedsPatch' })
            if ($pending.Count -eq 0) { Write-Host '   Already patched. Nothing to do.'; continue }
            if ($DryRun) { Write-Host "   DryRun: $($pending.Count) rule(s) would be applied."; continue }

            if (-not (Test-FileWritable $dll)) {
                Write-Host '   DLL is locked (Visual Studio is running). Close Visual Studio and re-run. No process was touched.'
                $exit = [Math]::Max($exit, 3); continue
            }

            # Backup (once per original hash)
            $bdir = Join-Path $BackupRoot $shaBefore
            [void][System.IO.Directory]::CreateDirectory($bdir)
            $bfile = Join-Path $bdir 'Antigravity.VisualStudio.dll'
            if (-not (Test-Path -LiteralPath $bfile)) { [System.IO.File]::WriteAllBytes($bfile, $bytes) }
            if ((Get-Sha256 $bfile) -ne $shaBefore) { throw "Backup hash mismatch for $bfile" }

            [void](Invoke-Rules $asm.MainModule $true)
            $tmp = "$dll.$PatchId.tmp"
            $asm.Write($tmp)
        } finally { $asm.Dispose(); $ms.Dispose() }

        # Verify the written temp file before swapping it in.
        $vms = [System.IO.MemoryStream]::new([System.IO.File]::ReadAllBytes($tmp))
        $vasm = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($vms)
        try { $after = Invoke-Rules $vasm.MainModule $false } finally { $vasm.Dispose(); $vms.Dispose() }
        $bad = @($after | Where-Object { $_.State -eq 'NeedsPatch' -or ($_.Required -and $_.State -ne 'Patched') })
        if ($bad.Count -gt 0 -or -not (Invoke-PEVerify $tmp)) {
            [System.IO.File]::Delete($tmp)
            Write-Host '   VERIFICATION FAILED. Original left untouched.'
            $exit = [Math]::Max($exit, 4); continue
        }

        [System.IO.File]::Copy($tmp, $dll, $true)
        [System.IO.File]::Delete($tmp)
        $shaAfter = Get-Sha256 $dll
        [pscustomobject]@{
            PatchId = $PatchId; TargetPath = $dll; FileVersion = $version
            OriginalSha256 = $shaBefore; PatchedSha256 = $shaAfter
            PatchedAtUtc = [DateTime]::UtcNow.ToString('o'); Cecil = $cecil
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $bdir 'manifest.json') -Encoding utf8
        Write-Host "   PATCHED. SHA-256 $shaBefore -> $shaAfter. Backup: $bdir"
        Write-Host '   Restart Visual Studio to load the patched extension.'
    }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    $exit = 1
}
exit $exit
