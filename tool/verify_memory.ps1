param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [int]$Seconds = 30
)

$ErrorActionPreference = 'Stop'
$exePath = (Resolve-Path -LiteralPath $Exe).Path
$testHome = Join-Path ([IO.Path]::GetTempPath()) ('BotConsole-memory-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $testHome | Out-Null
# The test never starts or touches real services and never loads user settings.
@{ ui = @{ autoStart = $false }; usageDatabasePath = (Join-Path $testHome 'missing.db') } |
    ConvertTo-Json | Set-Content (Join-Path $testHome 'settings.json') -Encoding utf8

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class BotConsoleMemory {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetProcessWorkingSetSizeEx(
        IntPtr process, out UIntPtr min, out UIntPtr max, out uint flags);
    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr window, uint msg, IntPtr w, IntPtr l);
}
'@

$start = [Diagnostics.ProcessStartInfo]::new($exePath)
$start.WorkingDirectory = Split-Path -Parent $exePath
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.Environment['BOTCONSOLE_HOME'] = $testHome
$app = [Diagnostics.Process]::Start($start)
$samples = @()
try {
    [UIntPtr]$minimum = [UIntPtr]::Zero
    [UIntPtr]$maximum = [UIntPtr]::Zero
    [uint32]$flags = 0
    # Check the OS policy as well as sampled RAM: a short sample alone is insufficient.
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        if ($app.HasExited) { throw 'App exited during startup.' }
        $ok = [BotConsoleMemory]::GetProcessWorkingSetSizeEx($app.Handle, [ref]$minimum, [ref]$maximum, [ref]$flags)
        if ($ok -and ($flags -band 4) -ne 0) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if (!$ok -or ($flags -band 4) -eq 0 -or $maximum.ToUInt64() -gt 96MB) {
        throw '96 MiB hard resident memory policy was not applied.'
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($app.HasExited) { throw 'App exited during sampling.' }
        $app.Refresh()
        if ($app.WorkingSet64 -gt 100MB) { throw "Resident RAM exceeded 100 MiB: $($app.WorkingSet64)" }
        $samples += [pscustomobject]@{ Resident = $app.WorkingSet64; Commit = $app.PrivateMemorySize64 }
        Start-Sleep -Milliseconds 200
    }
    [pscustomobject]@{
        LimitMiB = $maximum.ToUInt64() / 1MB
        PeakResidentMiB = [math]::Round(($samples.Resident | Measure-Object -Maximum).Maximum / 1MB, 2)
        PeakPrivateCommitMiB = [math]::Round(($samples.Commit | Measure-Object -Maximum).Maximum / 1MB, 2)
        Samples = $samples.Count
    } | ConvertTo-Json
} finally {
    # This isolated instance owns no bot processes. Request its native normal exit.
    $app.Refresh()
    if (!$app.HasExited -and $app.MainWindowHandle -ne [IntPtr]::Zero) {
        [BotConsoleMemory]::PostMessage($app.MainWindowHandle, 0x8002, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    }
    if (!$app.HasExited -and !$app.WaitForExit(5000)) { $app.Kill(); $app.WaitForExit() }
    $app.Dispose()
    # Delete only files created by this script, leaving unexpected files for inspection.
    $settingsFile = Join-Path $testHome 'settings.json'
    if (Test-Path -LiteralPath $settingsFile) { Remove-Item -LiteralPath $settingsFile }
}
