$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path $toolRoot ('test-results/dependencies-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $fixture 'source'
New-Item -ItemType Directory -Path $source | Out-Null
$installer = Join-Path $toolRoot 'scripts/Install-Dependencies.ps1'
if (-not (Test-Path -LiteralPath $installer)) { throw 'Dependency installer must exist.' }
foreach ($target in @('build','java')) {
    $build = Join-Path $fixture 'build'
    $java = Join-Path $fixture 'java'
    if ($target -eq 'build') { $build = Join-Path $source 'nested-build' }
    else { $java = Join-Path $source 'nested-java' }
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -BuildHome $build -JavaRoot $java -SourceRepository $source 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $output -notmatch 'must not overlap') { throw "Expected source overlap rejection for ${target}: $output" }
    if (@(Get-ChildItem -LiteralPath $source -Force).Count -ne 0) { throw 'Installer wrote into source.' }
    if (Test-Path -LiteralPath $build) { throw 'Installer wrote output before path validation.' }
    Write-Host "PASS reject $target installation overlapping source before writes/downloads"
}
$wrapper = Join-Path $fixture 'offline-child.ps1'
[IO.File]::WriteAllText($wrapper, @'
param($Installer,$Build,$Java,$Source)
$env:PATH = ''
& $Installer -BuildHome $Build -JavaRoot $Java -SourceRepository $Source
exit $LASTEXITCODE
'@)
$ps = (Get-Command powershell.exe).Source
foreach ($relative in @('runtime/downloads','runtime/templates','logs')) {
    $case = Join-Path $fixture ([guid]::NewGuid().ToString('N'))
    $build = Join-Path $case 'build'
    $sourceCase = Join-Path $case 'source'
    $link = Join-Path $build $relative
    New-Item -ItemType Directory -Force -Path $sourceCase,(Split-Path $link -Parent) | Out-Null
    New-Item -ItemType Junction -Path $link -Target $sourceCase | Out-Null
    $output = & $ps -NoProfile -ExecutionPolicy Bypass -File $wrapper -Installer $installer -Build $build -Java (Join-Path $case 'java') -Source $sourceCase 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $output -notmatch 'Reparse point not allowed') { throw "Expected nested junction rejection: $relative : $output" }
    if (@(Get-ChildItem -LiteralPath $sourceCase -Force).Count) { throw 'Installer wrote through nested junction.' }
    Write-Host "PASS reject nested $relative junction before writes"
}
$retryBuild = Join-Path $fixture 'retry-build'
New-Item -ItemType Directory -Force -Path (Join-Path $retryBuild 'runtime') | Out-Null
$state = Join-Path $retryBuild 'runtime/dependencies.json'
[IO.File]::WriteAllText($state, '{"status":"installed"}')
$output = & $ps -NoProfile -ExecutionPolicy Bypass -File $wrapper -Installer $installer -Build $retryBuild -Java (Join-Path $fixture 'retry-java') -Source $source 2>&1 | Out-String
if ($LASTEXITCODE -eq 0) { throw 'Expected missing curl failure.' }
if ((Get-Content -Raw -LiteralPath $state | ConvertFrom-Json).status -ne 'incomplete') { throw 'A failed retry retained stale installed state.' }
Write-Host 'PASS failed retry replaces stale installed state'
$helper = Join-Path $toolRoot 'scripts/Dependency-Helpers.ps1'
if (-not (Test-Path -LiteralPath $helper)) { throw 'Pinned Java version validator must exist.' }
. $helper
Assert-PinnedJavaVersion 'openjdk version "21.0.13.0.3"; OpenJDK Runtime Environment Zulu21.54+109-CA (build 21.0.13.0.3+1-LTS)'
foreach ($wrong in @('openjdk 17.0.1','openjdk 21.0.13+9','openjdk 21.0.13.0.3+10','openjdk 21.0.13.0.3+2','fixture exits zero')) {
    $rejected = $false
    try { Assert-PinnedJavaVersion $wrong } catch { $rejected = $true }
    if (-not $rejected) { throw "Accepted incorrect Java version: $wrong" }
}
Write-Host 'PASS reject incorrect Java version even with exit code zero'
. (Join-Path $toolRoot 'scripts/Build-Common.ps1')
. (Join-Path $toolRoot 'scripts/Package-Helpers.ps1')
$engine = Join-Path $fixture 'portable-engine'
$localTemplates = Join-Path $engine 'editor_data/export_templates/4.7.2.stable'
$appData = Join-Path $fixture 'appdata'
$destination = Join-Path $fixture 'copied-templates'
$run = Join-Path $fixture 'template-validation'
New-Item -ItemType Directory -Force -Path $localTemplates | Out-Null
$fakeTemplate = Join-Path $fixture 'template.exe'
$compiler = New-Object CodeDom.Compiler.CompilerParameters
$compiler.GenerateExecutable = $true
$compiler.OutputAssembly = $fakeTemplate
$compiler.CompilerOptions = '/platform:x64'
Add-Type -TypeDefinition @'
using System;
using System.IO;
public class TemplateFixture {
  public static void Main(string[] args) {
    string appData = Environment.GetEnvironmentVariable("APPDATA");
    File.WriteAllText(Path.Combine(appData, "template-probe.txt"), "isolated");
    string wrong = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "wrong-version");
    Console.WriteLine(File.Exists(wrong) ? "4.6.stable.official.fixture" : "4.7.2.stable.official.fixture");
  }
}
'@ -CompilerParameters $compiler
foreach ($name in @('windows_debug_x86_64.exe','windows_release_x86_64.exe','windows_debug_x86_64_console.exe','windows_release_x86_64_console.exe')) {
    Copy-Item -LiteralPath $fakeTemplate -Destination (Join-Path $localTemplates $name)
}
Write-Utf8 (Join-Path $localTemplates 'icudt_godot.dat') 'fixture ICU data'
Write-Utf8 (Join-Path $localTemplates 'version.txt') '4.7.2.stable'
$found = Find-LocalWindowsTemplates -GodotPath (Join-Path $engine 'godot.exe') -AppDataDirectory $appData
if ($found -ne (Get-SafeFullPath $localTemplates)) { throw 'Portable templates were not selected.' }
$record = Install-LocalWindowsTemplates -SourceDirectory $found -Destination $destination -RunDirectory $run
if ($record.source -ne 'local' -or $record.version -ne '4.7.2.stable' -or $record.files.Count -ne 6) { throw 'Local template provenance/hash record incomplete.' }
if (-not (Test-Path (Join-Path $run 'user-data/APPDATA/template-probe.txt'))) { throw 'Template subprocess APPDATA was not isolated.' }
if (Test-Path (Join-Path $localTemplates 'template-probe.txt')) { throw 'Template source was mutated.' }
Write-Host 'PASS copy complete portable templates and validate real x64 fixture/version in isolated environment'
Remove-Item -LiteralPath (Join-Path $localTemplates 'windows_debug_x86_64_console.exe')
if (Find-LocalWindowsTemplates -GodotPath (Join-Path $engine 'godot.exe') -AppDataDirectory $appData) { throw 'Missing console helper did not require fallback.' }
Write-Host 'PASS incomplete local templates require archive fallback'
Copy-Item -LiteralPath $fakeTemplate -Destination (Join-Path $localTemplates 'windows_debug_x86_64_console.exe')
Write-Utf8 (Join-Path $localTemplates 'version.txt') '4.6.stable'
if (Find-LocalWindowsTemplates -GodotPath (Join-Path $engine 'godot.exe') -AppDataDirectory $appData) { throw 'Wrong version.txt did not require fallback.' }
Write-Host 'PASS incorrect local version.txt requires archive fallback'
Write-Utf8 (Join-Path $localTemplates 'version.txt') '4.7.2.stable'
Write-Utf8 (Join-Path $destination 'wrong-version') 'fixture trigger'
$rejected = $false
try { Install-LocalWindowsTemplates -SourceDirectory $localTemplates -Destination $destination -RunDirectory $run | Out-Null } catch { $rejected = $_.Exception.Message -match 'version' }
if (-not $rejected) { throw 'Template executable version mismatch was accepted.' }
Write-Host 'PASS reject executable version mismatch despite matching directory/version.txt'
$fallback = Join-Path $appData 'Godot/export_templates/4.7.2.stable'
New-Item -ItemType Directory -Force -Path (Split-Path $fallback -Parent) | Out-Null
Copy-Item -LiteralPath $localTemplates -Destination $fallback -Recurse
$found = Find-LocalWindowsTemplates -GodotPath (Join-Path $fixture 'absent/godot.exe') -AppDataDirectory $appData
if ($found -ne (Get-SafeFullPath $fallback)) { throw 'APPDATA template discovery failed.' }
Write-Host 'PASS discover matching APPDATA template installation'
$linked = Join-Path $fixture 'linked-output'
New-Item -ItemType Junction -Path $linked -Target $source | Out-Null
$rejected = $false
try { Install-LocalWindowsTemplates -SourceDirectory $localTemplates -Destination $linked -RunDirectory $run | Out-Null } catch { $rejected = $_.Exception.Message -match 'Reparse point' }
if (-not $rejected -or @(Get-ChildItem $source -Force).Count) { throw 'Template copy bypassed reparse protection.' }
Write-Host 'PASS reject template destination junction before copying'
$curlDirectory = Join-Path $fixture 'offline-curl'
New-Item -ItemType Directory -Path $curlDirectory | Out-Null
Add-Type -TypeDefinition @'
using System;
using System.IO;
public class OfflineCurl {
  public static int Main(string[] args) {
    File.AppendAllText(Path.Combine(Environment.CurrentDirectory, "curl-requests.txt"), args[args.Length - 1] + "\n");
    Console.Error.WriteLine("Offline fixture: network unavailable");
    return 7;
  }
}
'@ -OutputAssembly (Join-Path $curlDirectory 'curl.exe') -OutputType ConsoleApplication
$localWrapper = Join-Path $fixture 'local-installer-child.ps1'
Write-Utf8 $localWrapper @'
param($Installer,$Build,$Java,$Source,$Godot,$CurlDirectory,$AppData)
$env:PATH = $CurlDirectory
$env:APPDATA = $AppData
& $Installer -BuildHome $Build -JavaRoot $Java -SourceRepository $Source -GodotPath $Godot
exit $LASTEXITCODE
'@
foreach ($validLocal in @($true,$false)) {
    Write-Utf8 (Join-Path $localTemplates 'version.txt') $(if ($validLocal) { '4.7.2.stable' } else { '4.6.stable' })
    $integrationBuild = Join-Path $fixture ('integration-' + $validLocal)
    New-Item -ItemType Directory -Force -Path (Join-Path $integrationBuild 'test-results') | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $integrationBuild 'test-results/unrelated-fixture') -Target $source | Out-Null
    $output = & $ps -NoProfile -ExecutionPolicy Bypass -File $localWrapper -Installer $installer -Build $integrationBuild -Java (Join-Path $fixture 'integration-java') -Source $source -Godot (Join-Path $engine 'godot.exe') -CurlDirectory $curlDirectory -AppData (Join-Path $fixture 'empty-appdata') 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { throw 'Offline failed downloads must not produce installed status.' }
    $integrationRecord = Get-Content -Raw (Join-Path $integrationBuild 'runtime/dependencies.json') | ConvertFrom-Json
    $requests = [IO.File]::ReadAllText((Join-Path $integrationBuild 'runtime/downloads/curl-requests.txt'))
    if ($validLocal) {
        if ($requests -match 'templates.tpz' -or $integrationRecord.templates.source -ne 'local' -or $integrationRecord.templates.files.Count -ne 6) { throw "Installer did not reuse local templates without archive download: $output" }
        if ($integrationRecord.packages[0].sha256 -ne '3a01d4e2eaab87bee5fdccae051fc3dc2c4dd655c04b942aa8ff7a74aab314c4') { throw 'Azul archive hash changed.' }
        if ($requests -notmatch 'mirror.twds.com.tw' -or $requests -notmatch 'updates.jenkins.io') { throw 'Jenkins mirror failure did not try official fallback.' }
        Write-Host 'PASS installer local branch skips TPZ download and records template hashes while retaining download failures'
    } else {
        if ($requests -notmatch 'templates.tpz' -or $integrationRecord.templates) { throw "Installer did not fall back for incorrect local template version: $output" }
        Write-Host 'PASS installer incorrect local version uses checked archive fallback and stays incomplete offline'
    }
}
$defaultHome = Join-Path $fixture 'default build home'
$defaultScripts = Join-Path $defaultHome 'scripts'
New-Item -ItemType Directory -Force -Path $defaultScripts | Out-Null
foreach ($name in @('Install-Dependencies.ps1','Dependency-Helpers.ps1','Build-Common.ps1','Package-Helpers.ps1')) {
    Copy-Item -LiteralPath (Join-Path $toolRoot ('scripts/' + $name)) -Destination (Join-Path $defaultScripts $name)
}
Write-Utf8 (Join-Path $localTemplates 'version.txt') '4.7.2.stable'
$defaultFailure = ''
try {
    $null = Invoke-BuildProcess -FilePath $ps -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $defaultScripts 'Install-Dependencies.ps1'),'-JavaRoot',(Join-Path $fixture 'default-java'),'-SourceRepository',$source,'-GodotPath',(Join-Path $engine 'godot.exe')) -WorkingDirectory $fixture -Environment @{ PATH=$curlDirectory; APPDATA=(Join-Path $fixture 'empty-appdata') } -TimeoutSeconds 30
} catch { $defaultFailure = $_.Exception.Message }
$defaultRecord = Join-Path $defaultHome 'runtime/dependencies.json'
if (-not (Test-Path -LiteralPath $defaultRecord)) { throw "Omitted BuildHome did not use copied installer's tool root: $defaultFailure" }
$defaultState = Get-Content -Raw -LiteralPath $defaultRecord | ConvertFrom-Json
if ($defaultState.status -ne 'incomplete' -or $defaultState.templates.directory -ne (Join-Path (Get-SafeFullPath $defaultHome) 'runtime/templates/4.7.2.stable')) { throw 'Default installer home or offline failure status incorrect.' }
Write-Host 'PASS real PowerShell -File without BuildHome uses installer tool root with offline dependencies'
Write-Host 'PASSED: 16 dependency installer checks'
