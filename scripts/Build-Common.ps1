# Shared process and path safety primitives. Compatible with Windows PowerShell 5.1.
Set-StrictMode -Version Latest
if (-not ('FafBuild.NativePath' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace FafBuild {
    public static class NativePath {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint size, uint flags);
        public static string ResolveExisting(string path) {
            using (SafeFileHandle handle = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                StringBuilder buffer = new StringBuilder(32768);
                uint length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
                if (length == 0 || length >= buffer.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error());
                string result = buffer.ToString();
                if (result.StartsWith(@"\\?\UNC\")) throw new InvalidOperationException("Network paths are not supported.");
                return result.StartsWith(@"\\?\") ? result.Substring(4) : result;
            }
        }
    }
}
'@
}
function ConvertTo-NativeArgument([string]$Value) {
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Get-SafeFullPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A path must not be empty.' }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\')) { throw "Network and device paths are not supported: $Path" }
    if ($full.Length -gt [IO.Path]::GetPathRoot($full).Length) { $full = $full.TrimEnd('\','/') }
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point not allowed: $cursor" }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    # Resolve the longest existing ancestor by handle. GetFullPath alone does not
    # normalize 8.3 short names or SUBST drives and can miss a real overlap.
    $ancestor = $full
    $tail = New-Object 'System.Collections.Generic.List[string]'
    while (-not (Test-Path -LiteralPath $ancestor)) {
        $tail.Insert(0, [IO.Path]::GetFileName($ancestor))
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
        if (-not $ancestor) { throw "Path has no existing filesystem ancestor: $Path" }
    }
    $canonical = [FafBuild.NativePath]::ResolveExisting($ancestor)
    foreach ($part in $tail) { $canonical = [IO.Path]::Combine($canonical, $part) }
    return $canonical
}
function Test-WithinPath([string]$Child, [string]$Parent) {
    $Child.Equals($Parent, [StringComparison]::OrdinalIgnoreCase) -or $Child.StartsWith($Parent.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}
function Assert-SeparatePaths([string]$Source, [string]$Output) {
    if ((Test-WithinPath $Source $Output) -or (Test-WithinPath $Output $Source)) { throw 'Source repository and BuildRoot must not overlap.' }
}
function Assert-NoReparseTree([string]$Root) {
    $null = Get-SafeFullPath $Root
    # Enumerate one level at a time: never recurse into a reparse point first.
    foreach ($item in Get-ChildItem -LiteralPath $Root -Force) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point not allowed: $($item.FullName)" }
        if ($item.PSIsContainer) { Assert-NoReparseTree $item.FullName }
    }
}
function Write-Utf8([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}
function Invoke-BuildProcess {
    param([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory,
          [int]$TimeoutSeconds = 120, [string]$LogPrefix, [hashtable]$Environment = @{},
          [switch]$CheckGodotErrors, [string]$GodotLog, [string[]]$RemoveEnvironment = @())
    $p = New-Object Diagnostics.Process
    $p.StartInfo.FileName = $FilePath
    $p.StartInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $p.StartInfo.WorkingDirectory = $WorkingDirectory
    $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.CreateNoWindow = $true
    $p.StartInfo.WindowStyle = 'Hidden'
    $p.StartInfo.RedirectStandardOutput = $true
    $p.StartInfo.RedirectStandardError = $true
    $p.StartInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $p.StartInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($key in $RemoveEnvironment) { $p.StartInfo.EnvironmentVariables.Remove($key) }
    foreach ($key in $Environment.Keys) { $p.StartInfo.EnvironmentVariables[$key] = [string]$Environment[$key] }
    $stdout = ''; $stderr = ''; $timedOut = $false; $exitCode = -1
    try {
        $null = $p.Start()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            # Kill the launched tree only, including children inheriting the redirected pipes.
            $killer = New-Object Diagnostics.Process
            try {
                $killer.StartInfo.FileName = Join-Path $env:SystemRoot 'System32/taskkill.exe'
                $killer.StartInfo.Arguments = '/PID ' + $p.Id + ' /T /F'
                $killer.StartInfo.UseShellExecute = $false
                $killer.StartInfo.CreateNoWindow = $true
                $killer.StartInfo.WindowStyle = 'Hidden'
                $null = $killer.Start()
                if (-not $killer.WaitForExit(5000)) { $killer.Kill() }
            } finally { $killer.Dispose() }
            if (-not $p.HasExited) { $p.Kill() }
            $null = $p.WaitForExit(5000)
        }
        # Bound stream draining as well: a descendant can otherwise keep a pipe open forever.
        if (-not $outTask.Wait(5000) -or -not $errTask.Wait(5000)) { throw 'Child output streams did not close within 5 seconds.' }
        $stdout = $outTask.Result; $stderr = $errTask.Result
        $exitCode = $p.ExitCode
    } finally {
        if ($LogPrefix) {
            Write-Utf8 ($LogPrefix + '.stdout.log') $stdout
            Write-Utf8 ($LogPrefix + '.stderr.log') $stderr
            Write-Utf8 ($LogPrefix + '.process.json') (([ordered]@{ executable=$FilePath; arguments=$Arguments; cwd=$WorkingDirectory; exitCode=$exitCode; timedOut=$timedOut }) | ConvertTo-Json -Depth 5)
        }
        $p.Dispose()
    }
    if ($timedOut) { throw "Process timeout after $TimeoutSeconds seconds: $FilePath" }
    if ($exitCode -ne 0) { throw "Process exited with code ${exitCode}: $FilePath`n$stderr" }
    if ($CheckGodotErrors) {
        $content = $stdout + "`n" + $stderr
        if ($GodotLog -and (Test-Path -LiteralPath $GodotLog)) { $content += "`n" + [IO.File]::ReadAllText($GodotLog) }
        if ($content -match '(?m)^(?:ERROR|SCRIPT ERROR):') { throw "Godot emitted an error (exit code $exitCode). See $LogPrefix" }
    }
    return $stdout.Trim()
}
function Invoke-ReadGit([string]$Repository, [string[]]$Arguments, [string]$LogPrefix, [int]$TimeoutSeconds = 120) {
    $git = (Get-Command git.exe -ErrorAction Stop).Source
    # -C does not override GIT_DIR/GIT_WORK_TREE, object stores or injected
    # configuration. Clear inherited Git controls (including trace destinations)
    # in this child only; keep PATH and the rest of the host environment intact.
    $gitEnvironment = [string[]]@([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_.StartsWith('GIT_', [StringComparison]::OrdinalIgnoreCase) })
    Invoke-BuildProcess -FilePath $git -Arguments (@('--no-optional-locks','-c','core.fsmonitor=false','-C',$Repository) + $Arguments) -WorkingDirectory $Repository -LogPrefix $LogPrefix -TimeoutSeconds $TimeoutSeconds -RemoveEnvironment $gitEnvironment
}
function New-GodotEnvironment([string]$RunDirectory) {
    $envMap = @{}
    foreach ($name in @('APPDATA','LOCALAPPDATA','TEMP','TMP')) {
        $path = Join-Path $RunDirectory ('user-data/' + $name)
        [IO.Directory]::CreateDirectory($path) | Out-Null
        $envMap[$name] = $path
    }
    return $envMap
}
function Get-IsolatedEnginePath([string]$OriginalPath, [string]$RunDirectory) {
    $engineDirectory = Split-Path $OriginalPath -Parent
    $selfContained = (Test-Path -LiteralPath (Join-Path $engineDirectory '._sc_')) -or (Test-Path -LiteralPath (Join-Path $engineDirectory '_sc_'))
    if (-not $selfContained) { return $OriginalPath }
    # Portable/Steam editors ignore APPDATA when a self-contained marker exists.
    # Copy only the executable and its Steam dependency, never markers or settings.
    $isolatedDirectory = Join-Path $RunDirectory 'engine'
    [IO.Directory]::CreateDirectory($isolatedDirectory) | Out-Null
    $copy = Join-Path $isolatedDirectory ([IO.Path]::GetFileName($OriginalPath))
    Copy-Item -LiteralPath $OriginalPath -Destination $copy
    $steamDll = Join-Path $engineDirectory 'steam_api64.dll'
    if (Test-Path -LiteralPath $steamDll -PathType Leaf) {
        $steamDll = Get-SafeFullPath $steamDll
        Copy-Item -LiteralPath $steamDll -Destination (Join-Path $isolatedDirectory 'steam_api64.dll')
    }
    return $copy
}
function Invoke-IsolatedGodot {
    param([string]$GodotPath, [string[]]$Arguments, [string]$WorkingDirectory,
          [string]$Name, [string]$RunDirectory, [int]$TimeoutSeconds)
    $prefix = Join-Path $RunDirectory ('logs/' + ($Name -replace '[^A-Za-z0-9_.-]','_'))
    $godotLog = $prefix + '.godot.log'
    Write-Host "[stage] $Name"
    Invoke-BuildProcess -FilePath $GodotPath -Arguments (@('--log-file',$godotLog) + $Arguments) -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds -LogPrefix $prefix -Environment (New-GodotEnvironment $RunDirectory) -CheckGodotErrors -GodotLog $godotLog
}
