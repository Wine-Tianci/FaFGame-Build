[CmdletBinding()]
param([string]$TargetDirectory)
$ErrorActionPreference='Stop'
$patchRoot=$PSScriptRoot
. (Join-Path $patchRoot 'scripts/Portable-Helpers.ps1')
if(-not $TargetDirectory) { $TargetDirectory=(Read-Host 'Existing portable tool directory (for example E:\fb)').Trim().Trim('"') }
$target=Get-SafeFullPath $TargetDirectory
Assert-SeparatePaths $target (Get-SafeFullPath $patchRoot)
$hash=[Security.Cryptography.SHA256]::Create()
try {$key=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($target.ToUpperInvariant()))).Replace('-','')} finally {$hash.Dispose()}
$mutex=New-Object Threading.Mutex($false,('Local\FafPortableSetup-'+$key))
$locked=$false
try {
    try {$locked=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$locked=$true}
    if(-not $locked) {throw 'A launcher is active. Retry when it has finished.'}
    if(Get-PortableLiveInstance $target) {throw 'Use Stop.cmd to stop this instance before updating.'}
    $configPath=Get-SafeFullPath (Join-Path $target 'portable-config.json')
    if(Test-Path -LiteralPath $configPath) {
        $config=[IO.File]::ReadAllText($configPath)|ConvertFrom-Json
        if($config.sourceRepository) {Assert-SeparatePaths (Get-SafeFullPath $config.sourceRepository) $target}
    }
    Test-PortablePayload $target|Out-Null
    $patch=[IO.File]::ReadAllText((Join-Path $patchRoot 'update-manifest.json'))|ConvertFrom-Json
    if($patch.schemaVersion -ne 1) {throw 'Unsupported update manifest.'}
    $paths=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($file in $patch.files) {
        if($file.path -notmatch '^(scripts/[^/\\]+\.(ps1|gd)|portable/bootstrap\.groovy|Jenkinsfile|README\.md)$' -or -not $paths.Add($file.path)) {throw 'Update contains an unsupported or duplicate file.'}
        $inputPath=Resolve-PortablePath $patchRoot $file.path
        $null=Resolve-PortablePath $target $file.path
        if((Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash -ine $file.sha256) {throw ('Update hash mismatch: '+$file.path)}
    }
    if($paths.Count -eq 0) {throw 'Update has no files.'}
    $manifestPath=Get-SafeFullPath (Join-Path $target 'portable-manifest.json')
    $originalManifest=[IO.File]::ReadAllText($manifestPath)
    $backup=Get-SafeFullPath (Join-Path $target ('runtime/update-backups/'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)))
    [IO.Directory]::CreateDirectory($backup)|Out-Null
    Write-Utf8 (Join-Path $backup 'portable-manifest.json') $originalManifest
    $existed=@{}
    foreach($file in $patch.files) {
        $destination=Resolve-PortablePath $target $file.path
        $existed[$file.path]=Test-Path -LiteralPath $destination -PathType Leaf
        if($existed[$file.path]) {
            $save=Resolve-PortablePath $backup $file.path
            [IO.Directory]::CreateDirectory((Split-Path $save -Parent))|Out-Null
            Copy-Item -LiteralPath $destination -Destination $save
        }
    }
    try {
        foreach($file in $patch.files) {
            $destination=Resolve-PortablePath $target $file.path
            [IO.Directory]::CreateDirectory((Split-Path $destination -Parent))|Out-Null
            Copy-Item -LiteralPath (Resolve-PortablePath $patchRoot $file.path) -Destination $destination -Force
        }
        $manifest=$originalManifest|ConvertFrom-Json
        $manifest.files=@($manifest.files|Where-Object {-not $paths.Contains($_.path)})+@($patch.files)
        $manifest|Add-Member -NotePropertyName updatedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        Write-Utf8 $manifestPath ($manifest|ConvertTo-Json -Depth 8)
        Test-PortablePayload $target|Out-Null
    } catch {
        foreach($file in $patch.files) {
            $destination=Resolve-PortablePath $target $file.path
            if($existed[$file.path]) {Copy-Item -LiteralPath (Resolve-PortablePath $backup $file.path) -Destination $destination -Force}
            elseif(Test-Path -LiteralPath $destination) {Remove-Item -LiteralPath $destination -Force}
        }
        Write-Utf8 $manifestPath $originalManifest
        throw
    }
    Write-Host "Updated: $target"
    Write-Host "Backup: $backup"
    Write-Host 'Start.cmd will load the new Pipeline on the next startup.'
} finally {
    if($locked) {$mutex.ReleaseMutex()}
    $mutex.Dispose()
}
