function Assert-PinnedJavaVersion([string]$Output) {
    if ($Output -notmatch 'Zulu21\.54\+109-CA' -or $Output -notmatch '(?<![0-9.])21\.0\.13\.0\.3\+1(?:-LTS)?(?:[^0-9.]|$)') {
        throw 'Installed Java must report Zulu21.54+109-CA build 21.0.13.0.3+1-LTS.'
    }
}
function Get-WindowsTemplateFiles {
    @('windows_debug_x86_64.exe','windows_release_x86_64.exe','windows_debug_x86_64_console.exe','windows_release_x86_64_console.exe','icudt_godot.dat','version.txt')
}
function Find-LocalWindowsTemplates {
    param([string]$GodotPath, [string]$AppDataDirectory = $env:APPDATA)
    $candidates = @()
    if ($GodotPath) { $candidates += Join-Path (Split-Path (Get-SafeFullPath $GodotPath) -Parent) 'editor_data/export_templates/4.7.2.stable' }
    if ($AppDataDirectory) { $candidates += Join-Path $AppDataDirectory 'Godot/export_templates/4.7.2.stable' }
    foreach ($candidate in $candidates) {
        $candidate = Get-SafeFullPath $candidate
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
        $complete = $true
        foreach ($name in Get-WindowsTemplateFiles) {
            $file = Get-SafeFullPath (Join-Path $candidate $name)
            if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -eq 0) { $complete = $false }
        }
        if (-not $complete) { continue }
        if ([IO.File]::ReadAllText((Join-Path $candidate 'version.txt')).Trim() -ne '4.7.2.stable') { continue }
        return $candidate
    }
    return $null
}
function Install-LocalWindowsTemplates {
    param([string]$SourceDirectory, [string]$Destination, [string]$RunDirectory,
          [ValidateSet('local','archive')][string]$SourceKind = 'local')
    $source = Get-SafeFullPath $SourceDirectory
    $destinationPath = Get-SafeFullPath $Destination
    $run = Get-SafeFullPath $RunDirectory
    Assert-SeparatePaths $source $destinationPath
    Assert-SeparatePaths $source $run
    $names = @(Get-WindowsTemplateFiles)
    # Validate every source/output/reparse ancestor before the first copy or mkdir.
    foreach ($name in $names) {
        $file = Get-SafeFullPath (Join-Path $source $name)
        $null = Get-SafeFullPath (Join-Path $destinationPath $name)
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -eq 0) { throw "Missing Windows template file: $name" }
        if ($name.EndsWith('.exe')) { Assert-WindowsX64Template $file }
    }
    if ([IO.File]::ReadAllText((Join-Path $source 'version.txt')).Trim() -ne '4.7.2.stable') { throw 'Windows template version.txt must equal 4.7.2.stable.' }
    if (Test-Path -LiteralPath $run) { Assert-NoReparseTree $run }
    if (Test-Path -LiteralPath $destinationPath) { Assert-NoReparseTree $destinationPath }
    [IO.Directory]::CreateDirectory($destinationPath) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $run 'logs')) | Out-Null
    foreach ($name in $names) { Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $destinationPath $name) -Force }
    foreach ($name in @('windows_debug_x86_64.exe','windows_release_x86_64.exe')) {
        $version = Invoke-IsolatedGodot -GodotPath (Join-Path $destinationPath $name) -Arguments @('--headless','--version') -WorkingDirectory $run -Name $name -RunDirectory $run -TimeoutSeconds 20
        if ((Get-GodotVersionKey $version) -ne '4.7.2.stable') { throw "Windows template executable version mismatch: $name reports $version" }
    }
    $files = @($names | ForEach-Object { [ordered]@{ name=$_; sha256=(Get-FileHash -LiteralPath (Join-Path $destinationPath $_) -Algorithm SHA256).Hash.ToLowerInvariant() } })
    return [ordered]@{ source=$SourceKind; sourceDirectory=$source; directory=$destinationPath; version='4.7.2.stable'; files=$files }
}
