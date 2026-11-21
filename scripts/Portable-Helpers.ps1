# Portable release/runtime primitives. Windows PowerShell 5.1.
. (Join-Path $PSScriptRoot 'Build-Common.ps1')
function Resolve-PortablePath([string]$BuildHome, [string]$RelativePath) {
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath -match '(^|[/\\])\.\.([/\\]|$)|:') { throw 'Manifest path must be a safe relative path.' }
    $root = Get-SafeFullPath $BuildHome
    $path = Get-SafeFullPath (Join-Path $root $RelativePath)
    if (-not (Test-WithinPath $path $root) -or $path -eq $root) { throw 'Manifest path escaped package root.' }
    return $path
}
function Get-PortableRuntime([string]$BuildHome) {
    $root = Get-SafeFullPath $BuildHome
    $manifest = [IO.File]::ReadAllText((Join-Path $root 'portable-manifest.json')) | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1) { throw 'Unsupported portable manifest schema.' }
    $resolved = @{ root=$root; manifest=$manifest }
    foreach ($key in @('java','git','godot','war','templates')) {
        $path = Resolve-PortablePath $root $manifest.runtime.$key
        $kind = if ($key -eq 'templates') { 'Container' } else { 'Leaf' }
        if (-not (Test-Path -LiteralPath $path -PathType $kind)) { throw "Bundled dependency missing: $key ($path)" }
        $resolved[$key] = $path
    }
    return $resolved
}
function Get-PortableFileRecords([string]$BuildHome) {
    $root = Get-SafeFullPath $BuildHome
    Assert-NoReparseTree $root
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName) {
        $relative = $file.FullName.Substring($root.Length + 1).Replace('\','/')
        if ($relative -eq 'portable-manifest.json') { continue }
        [ordered]@{ path=$relative; sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
}
function Test-PortablePayload([string]$BuildHome) {
    $runtime = Get-PortableRuntime $BuildHome
    if (@($runtime.manifest.files).Count -eq 0) { throw 'Portable manifest contains no file records.' }
    foreach ($file in $runtime.manifest.files) {
        $path = Resolve-PortablePath $runtime.root $file.path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Payload file missing: $($file.path)" }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $file.sha256) { throw "Payload hash mismatch: $($file.path)" }
    }
    return $runtime
}
function Assert-PortablePluginHash([string]$Path, $Record) {
    $expected = [BitConverter]::ToString([Convert]::FromBase64String($Record.sha256)).Replace('-','')
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $expected) { throw "Plugin hash mismatch: $($Record.name)" }
}
function Get-PortablePluginLocks([string]$ToolRoot) {
    foreach ($name in @('jenkins-plugin-lock.json','jenkins-language-plugin-lock.json')) {
        $records = [IO.File]::ReadAllText((Join-Path $ToolRoot ('runtime/' + $name))) | ConvertFrom-Json
        foreach ($record in $records) { $record }
    }
}
function Assert-PortableDestination([string]$ToolRoot, [string]$Destination) {
    $root = Get-SafeFullPath $ToolRoot
    $output = Get-SafeFullPath $Destination
    if (Test-Path -LiteralPath $output) { throw 'Release destination must be fresh; it already exists.' }
    foreach ($relative in @('scripts','presets','portable')) { Assert-SeparatePaths (Join-Path $root $relative) $output }
}
function Write-PortableSecret([string]$Path, [string]$Text) {
    $path = Get-SafeFullPath $Path
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')
    $acl.AddAccessRule($rule)
    [IO.File]::WriteAllText($path, $Text, (New-Object Text.UTF8Encoding($false)))
    Set-Acl -LiteralPath $path -AclObject $acl
}
function Get-PortableLiveInstance([string]$BuildHome) {
    $root = Get-SafeFullPath $BuildHome
    $recordPath = Get-SafeFullPath (Join-Path $root 'runtime/jenkins.pid.json')
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { return $null }
    $record = [IO.File]::ReadAllText($recordPath) | ConvertFrom-Json
    $process = Get-Process -Id $record.pid -ErrorAction SilentlyContinue
    if (-not $process) { return $null }
    try {
        if ($process.HasExited) { return $null }
        $startTicks = $process.StartTime.ToUniversalTime().Ticks
        $executable = $process.Path
        if ($process.HasExited) { return $null }
        if ($startTicks -ne ([datetime]$record.startTimeUtc).ToUniversalTime().Ticks) { return $null }
        if ($executable -ine $record.executable -or $record.buildHome -ine $root) {
            throw 'Live instance identity mismatch. Stop it from its original directory before moving the tool.'
        }
        $expected = (Get-PortableRuntime $root).java
        if ($executable -ine $expected) { throw 'Live instance executable is outside the bundled runtime.' }
        return $record
    } finally { $process.Dispose() }
}
function Get-PortableGitPath([string]$GitExecutable) {
    $gitHome = Split-Path (Split-Path $GitExecutable -Parent) -Parent
    @((Join-Path $gitHome 'cmd'),(Join-Path $gitHome 'mingw64/bin'),(Join-Path $gitHome 'usr/bin'),
      (Join-Path $env:SystemRoot 'System32'),$env:SystemRoot,
      (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0')) -join ';'
}
