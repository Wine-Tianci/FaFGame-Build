[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DestinationPath,
    [string]$JavaHome,
    [string]$GitHome,
    [string]$GodotPath,
    [string]$TemplateDirectory,
    [string]$PluginDirectory,
    [string]$WarPath,
    [switch]$Zip
)
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Portable-Helpers.ps1')
. (Join-Path $PSScriptRoot 'Package-Helpers.ps1')
. (Join-Path $PSScriptRoot 'Dependency-Helpers.ps1')
$destination = Get-SafeFullPath $DestinationPath
Assert-PortableDestination $toolRoot $destination
if (Test-WithinPath $toolRoot $destination) { throw 'Release destination cannot contain the tool source.' }
if (-not $JavaHome -or -not $GitHome -or -not $GodotPath) { throw 'Specify JavaHome, GitHome and standalone GodotPath.' }
if (-not $TemplateDirectory) { $TemplateDirectory = Join-Path $toolRoot 'runtime/templates/4.7.2.stable' }
if (-not $PluginDirectory) { $PluginDirectory = Join-Path $toolRoot 'jenkins-home/plugins' }
if (-not $WarPath) { $WarPath = Join-Path $toolRoot 'runtime/downloads/jenkins-2.580.2.war' }
$javaHomePath = Get-SafeFullPath $JavaHome
$gitHomePath = Get-SafeFullPath $GitHome
$godot = Get-SafeFullPath $GodotPath
$templates = Get-SafeFullPath $TemplateDirectory
$plugins = Get-SafeFullPath $PluginDirectory
$war = Get-SafeFullPath $WarPath
$zipPath = $destination + '.zip'
if ($Zip -and (Test-Path -LiteralPath $zipPath)) { throw 'Release ZIP already exists.' }
foreach ($source in @($javaHomePath,$gitHomePath,(Split-Path $godot -Parent),$templates,$plugins)) {
    Assert-SeparatePaths $source $destination
}
foreach ($dependency in @((Join-Path $javaHomePath 'bin/java.exe'),(Join-Path $gitHomePath 'cmd/git.exe'),$godot,$war)) {
    if (-not (Test-Path -LiteralPath $dependency -PathType Leaf)) { throw "Dependency missing: $dependency" }
}
if ((Get-FileHash -LiteralPath $war -Algorithm SHA256).Hash -ine 'd98032d2401c540a35613a82ed358921fcf3166d5e6eaaaf60a7941845be3251') { throw 'Jenkins WAR hash mismatch.' }
$locks = @(Get-PortablePluginLocks $toolRoot)
foreach ($record in $locks) {
    $plugin = Get-SafeFullPath (Join-Path $plugins ($record.name + '.jpi'))
    Assert-PortablePluginHash $plugin $record
}
foreach ($tree in @($javaHomePath,$gitHomePath)) { Assert-NoReparseTree $tree }
foreach ($name in Get-WindowsTemplateFiles) {
    $path = Get-SafeFullPath (Join-Path $templates $name)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Template missing: $name" }
    if ($name.EndsWith('.exe')) { Assert-WindowsX64Template $path }
}
if ([IO.File]::ReadAllText((Join-Path $templates 'version.txt')).Trim() -ne '4.7.2.stable') { throw 'Template version mismatch.' }
$probeRoot = Join-Path $toolRoot ('test-results/portable-dependencies-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($probeRoot) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $probeRoot 'logs')) | Out-Null
$null = Invoke-BuildProcess -FilePath (Join-Path $javaHomePath 'bin/java.exe') -Arguments @('-version') -WorkingDirectory $probeRoot -LogPrefix (Join-Path $probeRoot 'java') -TimeoutSeconds 30 -RemoveEnvironment @('JAVA_TOOL_OPTIONS','JDK_JAVA_OPTIONS','_JAVA_OPTIONS')
Assert-PinnedJavaVersion ([IO.File]::ReadAllText((Join-Path $probeRoot 'java.stdout.log')) + [IO.File]::ReadAllText((Join-Path $probeRoot 'java.stderr.log')))
$editorVersion = Invoke-IsolatedGodot $godot @('--headless','--version') $probeRoot 'godot' $probeRoot 30
if ((Get-GodotVersionKey $editorVersion) -ne '4.7.2.stable') { throw 'Godot version must match 4.7.2.stable templates.' }
# Some official editor builds carry a .steam version tag but also execute
# independently. The acceptance test runs the copied editor without Steam DLLs.
Write-Host 'Copying clean portable payload...'
[IO.Directory]::CreateDirectory($destination) | Out-Null
foreach ($name in @('scripts','presets')) {
    $source = Join-Path $toolRoot $name
    Assert-NoReparseTree $source
    Copy-Item -LiteralPath $source -Destination (Join-Path $destination $name) -Recurse
}
Copy-Item -LiteralPath (Join-Path $toolRoot 'Jenkinsfile') -Destination (Join-Path $destination 'Jenkinsfile')
foreach ($name in @('Start.cmd','Stop.cmd','README.md')) {
    Copy-Item -LiteralPath (Join-Path $toolRoot ('portable/' + $name)) -Destination (Join-Path $destination $name)
}
[IO.Directory]::CreateDirectory((Join-Path $destination 'portable')) | Out-Null
Copy-Item -LiteralPath (Join-Path $toolRoot 'portable/bootstrap.groovy') -Destination (Join-Path $destination 'portable/bootstrap.groovy')
$runtime = Join-Path $destination 'runtime'
[IO.Directory]::CreateDirectory($runtime) | Out-Null
Copy-Item -LiteralPath $javaHomePath -Destination (Join-Path $runtime 'java') -Recurse
$gitTarget = Join-Path $runtime 'git'
[IO.Directory]::CreateDirectory($gitTarget) | Out-Null
foreach ($name in @('cmd','mingw64','usr','etc','LICENSE.txt')) {
    $path = Join-Path $gitHomePath $name
    if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination (Join-Path $gitTarget $name) -Recurse }
}
$godotTarget = Join-Path $runtime 'godot'
[IO.Directory]::CreateDirectory($godotTarget) | Out-Null
Copy-Item -LiteralPath $godot -Destination (Join-Path $godotTarget 'godot.exe')
foreach ($name in @('LICENSE.txt','COPYRIGHT.txt','AUTHORS.md')) {
    $path = Join-Path (Split-Path $godot -Parent) $name
    if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination (Join-Path $godotTarget $name) }
}
# Godot editor/export templates may require the ICU data alongside the EXE.
Copy-Item -LiteralPath (Join-Path $templates 'icudt_godot.dat') -Destination (Join-Path $godotTarget 'icudt_godot.dat')
$templateTarget = Join-Path $runtime 'templates/4.7.2.stable'
[IO.Directory]::CreateDirectory($templateTarget) | Out-Null
foreach ($name in Get-WindowsTemplateFiles) { Copy-Item -LiteralPath (Join-Path $templates $name) -Destination (Join-Path $templateTarget $name) }
$jenkinsTarget = Join-Path $runtime 'jenkins'
[IO.Directory]::CreateDirectory((Join-Path $jenkinsTarget 'plugins')) | Out-Null
Copy-Item -LiteralPath $war -Destination (Join-Path $jenkinsTarget 'jenkins.war')
foreach ($record in $locks) { Copy-Item -LiteralPath (Join-Path $plugins ($record.name + '.jpi')) -Destination (Join-Path $jenkinsTarget ('plugins/' + $record.name + '.jpi')) }
foreach ($name in @('jenkins-plugin-lock.json','jenkins-language-plugin-lock.json')) {
    Copy-Item -LiteralPath (Join-Path $toolRoot ('runtime/' + $name)) -Destination (Join-Path $jenkinsTarget $name)
}
$manifest = [ordered]@{
    schemaVersion=1; createdUtc=[DateTime]::UtcNow.ToString('o'); platform='windows-x64'; godotVersion=$editorVersion
    runtime=[ordered]@{ java='runtime/java/bin/java.exe'; git='runtime/git/cmd/git.exe'; godot='runtime/godot/godot.exe'; war='runtime/jenkins/jenkins.war'; templates='runtime/templates/4.7.2.stable' }
    files=@(Get-PortableFileRecords $destination)
}
Write-Utf8 (Join-Path $destination 'portable-manifest.json') ($manifest | ConvertTo-Json -Depth 8)
Test-PortablePayload $destination | Out-Null
if ($Zip) {
    Write-Host 'Compressing portable release...'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($destination,$zipPath,[IO.Compression.CompressionLevel]::Optimal,$true)
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Utf8 ($zipPath + '.sha256') ($hash + '  ' + [IO.Path]::GetFileName($zipPath) + "`n")
    Write-Host "ZIP: $zipPath"
}
Write-Host "Portable release: $destination"
