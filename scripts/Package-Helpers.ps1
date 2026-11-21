function Get-GodotVersionKey([string]$VersionText) {
    if ($VersionText -notmatch '^(\d+\.\d+(?:\.\d+)?)\.([A-Za-z0-9_-]+)(?:\.|$)') { throw "Unrecognized Godot version: $VersionText" }
    return $Matches[1] + '.' + $Matches[2]
}
function Assert-WindowsX64Template([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { throw 'Template must be an x86_64 PE executable (missing MZ header).' }
        $stream.Position = 0x3C
        $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt $stream.Length - 6) { throw 'Template must be an x86_64 PE executable (invalid PE offset).' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne 0x8664) { throw 'Template must be an x86_64 PE executable (PE Machine must equal 0x8664).' }
    } finally { $reader.Dispose(); $stream.Dispose() }
}
function Expand-GitSnapshot([string]$ArchivePath, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.IO.Compression
    $root = Get-SafeFullPath $Destination
    Assert-NoReparseTree $root
    if (@(Get-ChildItem -LiteralPath $root -Force).Count -ne 0) { throw 'Snapshot destination must be empty.' }
    $zip = [IO.Compression.ZipFile]::Open($ArchivePath, [IO.Compression.ZipArchiveMode]::Read, [Text.Encoding]::UTF8)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            # Validate every entry before extraction. Git ZIP uses UTF-8 names and
            # slash separators; reject Windows aliases, ADS and traversal paths.
            if (-not $name -or $name.Contains('\') -or $name.Contains(':') -or $name.StartsWith('/') -or [IO.Path]::IsPathRooted($name)) { throw "Unsafe snapshot ZIP path: $name" }
            $relative = $name.TrimEnd('/')
            foreach ($segment in $relative.Split('/')) {
                if (-not $segment -or $segment -in @('.','..') -or $segment.EndsWith('.') -or $segment.EndsWith(' ') -or $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw "Unsafe snapshot ZIP path segment: $name" }
            }
            $target = [IO.Path]::GetFullPath((Join-Path $root $relative))
            if (-not (Test-WithinPath $target $root) -or $target.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { throw "Snapshot ZIP path escapes destination: $name" }
            if (-not $seen.Add($target)) { throw "Duplicate or case-aliased snapshot ZIP entry: $name" }
            if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000 -or ($entry.ExternalAttributes -band 0x400) -ne 0) { throw "Snapshot ZIP link is not allowed: $name" }
        }
    } finally { $zip.Dispose() }
    # Explicit UTF-8 also covers archives whose UTF-8 flag is absent for ASCII-only
    # entries. Avoid Windows tar.exe's active-code-page filename conversion.
    [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $root, [Text.Encoding]::UTF8)
    Assert-NoReparseTree $root
}
function Get-ConfigInventory([string]$Directory) {
    $paths = [string[]]@(Get-ChildItem -LiteralPath $Directory -Recurse -File | ForEach-Object { $_.FullName.Substring($Directory.Length + 1).Replace('\','/') })
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $hash = [Security.Cryptography.SHA256]::Create()
    $sink = New-Object IO.MemoryStream
    $crypto = New-Object Security.Cryptography.CryptoStream($sink, $hash, [Security.Cryptography.CryptoStreamMode]::Write)
    $writer = New-Object IO.BinaryWriter($crypto, (New-Object Text.UTF8Encoding($false)))
    $files = @()
    try {
        foreach ($path in $paths) {
            $full = Join-Path $Directory $path
            $nameBytes = [Text.Encoding]::UTF8.GetBytes($path)
            $length = (Get-Item -LiteralPath $full).Length
            # Stable framing: LE UInt32 UTF-8 path length, path bytes, LE Int64 file
            # length, then exact file bytes. No delimiters or ambiguous concatenation.
            $writer.Write([uint32]$nameBytes.Length)
            $writer.Write($nameBytes)
            $writer.Write([int64]$length)
            $writer.Flush()
            $input = [IO.File]::OpenRead($full)
            try { $input.CopyTo($crypto) } finally { $input.Dispose() }
            $files += [ordered]@{ path=$path; length=$length; sha256=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant() }
        }
        $writer.Flush()
        $crypto.FlushFinalBlock()
        return [ordered]@{ count=$files.Count; sha256=([BitConverter]::ToString($hash.Hash).Replace('-','').ToLowerInvariant()); hashFormat='sha256-path-u32le-utf8-length-i64le-bytes-v1'; files=$files }
    } finally { $writer.Dispose(); $crypto.Dispose(); $sink.Dispose(); $hash.Dispose() }
}
function Assert-ExportedLibraries([string]$ProjectDirectory, [string]$ExportDirectory, [string]$BuildMode) {
    $mode = $BuildMode.ToLowerInvariant()
    $features = @('windows','x86_64','64','pc','template',$mode,'s3tc','bptc')
    foreach ($extension in Get-ChildItem -LiteralPath $ProjectDirectory -Filter '*.gdextension' -File -Recurse) {
        $section = ''; $matchesForPlatform = @(); $windowsEntries = 0
        foreach ($line in [IO.File]::ReadAllLines($extension.FullName)) {
            if ($line -match '^\s*\[([^\]]+)\]') { $section = $Matches[1]; continue }
            if ($section -ne 'libraries' -or $line -notmatch '^\s*([A-Za-z0-9_.]+)\s*=\s*"([^"]+)"') { continue }
            $key = $Matches[1]; $library = $Matches[2]; $tags = $key.Split('.')
            if ($tags -notcontains 'windows') { continue }
            $windowsEntries++
            if (@($tags | Where-Object { $features -notcontains $_ }).Count -eq 0) {
                $matchesForPlatform += [pscustomobject]@{ tags=$tags.Count; path=$library }
            }
        }
        if ($windowsEntries -eq 0) { continue }
        if ($matchesForPlatform.Count -eq 0) { throw "No supported Windows $mode x86_64 library in $($extension.FullName)" }
        $selected = @($matchesForPlatform | Sort-Object tags -Descending)[0]
        $libraryPath = $selected.path
        if ($libraryPath.StartsWith('res://')) { $sourceLibrary = Join-Path $ProjectDirectory $libraryPath.Substring(6) }
        else { $sourceLibrary = Join-Path $extension.DirectoryName $libraryPath }
        $sourceLibrary = [IO.Path]::GetFullPath($sourceLibrary)
        if (-not (Test-WithinPath $sourceLibrary $ProjectDirectory)) { throw "GDExtension path escapes project: $libraryPath" }
        $relative = $sourceLibrary.Substring($ProjectDirectory.Length + 1)
        # Godot copies native libraries to the export root; plugins may preserve
        # their relative path. Check those two exact placements, never a basename
        # search through arbitrary unrelated directories.
        $candidates = @((Join-Path $ExportDirectory ([IO.Path]::GetFileName($sourceLibrary))), (Join-Path $ExportDirectory $relative))
        $found = @($candidates | Where-Object { (Test-Path -LiteralPath $_ -PathType Leaf) -and (Get-Item -LiteralPath $_).Length -gt 0 })
        if ($found.Count -eq 0) { throw "Export missing selected native library: $libraryPath ($mode x86_64)" }
    }
}
function Remove-OwnedStaging([string]$Staging, [string]$RunDirectory) {
    $run = Get-SafeFullPath $RunDirectory
    $target = Get-SafeFullPath $Staging
    if (-not (Test-WithinPath $target $run) -or $target.Equals($run, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($target) -ne 'staging') { throw 'Refusing cleanup outside this run staging directory.' }
    if (Test-Path -LiteralPath $target) { Assert-NoReparseTree $target; Remove-Item -LiteralPath $target -Recurse -Force }
}
