[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PatchDirectory,[string]$TestRoot)
$ErrorActionPreference='Stop'
$toolRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $toolRoot 'scripts/Portable-Helpers.ps1')
if(-not $TestRoot) {$TestRoot=Join-Path $toolRoot ('test-results/update-'+[guid]::NewGuid().ToString('N'))}
$script:passed=0
function Assert($Condition,[string]$Message) {if(-not $Condition){throw "FAIL: $Message"};$script:passed++;Write-Host "PASS: $Message"}
$target=Join-Path $TestRoot 'existing tool'
$source=Join-Path $TestRoot 'source'
[IO.Directory]::CreateDirectory($source)|Out-Null
$runtime=@{java='runtime/java/bin/java.exe';git='runtime/git/cmd/git.exe';godot='runtime/godot/godot.exe';war='runtime/jenkins/jenkins.war';templates='runtime/templates/4.7.2.stable'}
foreach($relative in @($runtime.java,$runtime.git,$runtime.godot,$runtime.war,($runtime.templates+'/version.txt'),'Jenkinsfile')) {
    $path=Join-Path $target $relative
    [IO.Directory]::CreateDirectory((Split-Path $path -Parent))|Out-Null
    Write-Utf8 $path 'old fixture payload'
}
Write-Utf8 (Join-Path $target 'portable-manifest.json') (@{schemaVersion=1;runtime=$runtime;files=@(Get-PortableFileRecords $target)}|ConvertTo-Json -Depth 8)
Write-Utf8 (Join-Path $target 'portable-config.json') (@{sourceRepository=$source;port=8089}|ConvertTo-Json)
[IO.Directory]::CreateDirectory((Join-Path $target 'jenkins-home/users'))|Out-Null
Write-Utf8 (Join-Path $target 'jenkins-home/users/account.txt') 'keep local account'
Write-Utf8 (Join-Path $target 'jenkins-home/history.txt') 'keep build history'
$configBefore=[IO.File]::ReadAllText((Join-Path $target 'portable-config.json'))
$patch=Get-SafeFullPath $PatchDirectory
Invoke-BuildProcess -FilePath (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $patch 'Update-Portable.ps1'),'-TargetDirectory',$target) -WorkingDirectory $toolRoot -TimeoutSeconds 60|Out-Null
Assert ([IO.File]::ReadAllText((Join-Path $target 'jenkins-home/users/account.txt')) -eq 'keep local account') 'Update preserves local account data'
Assert ([IO.File]::ReadAllText((Join-Path $target 'jenkins-home/history.txt')) -eq 'keep build history') 'Update preserves build history'
Assert ([IO.File]::ReadAllText((Join-Path $target 'portable-config.json')) -eq $configBefore) 'Update preserves repository/port settings'
Test-PortablePayload $target|Out-Null
Assert $true 'Updated manifest verifies all runtime and script hashes'
Assert (Test-Path -LiteralPath (Join-Path $target 'scripts/Failure-Report.ps1')) 'Update installs new single-file reporter'
$saved=@(Get-ChildItem -LiteralPath (Join-Path $target 'runtime/update-backups') -Recurse -Filter Jenkinsfile)
Assert ($saved.Count -eq 1 -and [IO.File]::ReadAllText($saved[0].FullName) -eq 'old fixture payload') 'Previous scripts are backed up'
$corrupt=Join-Path $TestRoot 'invalid patch'
Copy-Item -LiteralPath $patch -Destination $corrupt -Recurse
Write-Utf8 (Join-Path $corrupt 'Jenkinsfile') 'tampered update'
$before=(Get-FileHash -LiteralPath (Join-Path $target 'Jenkinsfile')).Hash
$rejected=$false
try {
    Invoke-BuildProcess -FilePath (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $corrupt 'Update-Portable.ps1'),'-TargetDirectory',$target) -WorkingDirectory $toolRoot -TimeoutSeconds 60|Out-Null
} catch {$rejected=$_.Exception.Message -match 'Update hash mismatch'}
Assert ($rejected -and (Get-FileHash -LiteralPath (Join-Path $target 'Jenkinsfile')).Hash -eq $before) 'Tampered update is rejected before altering the installation'
Write-Host "Portable update tests passed: $script:passed"
