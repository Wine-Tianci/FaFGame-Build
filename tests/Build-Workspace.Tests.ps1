[CmdletBinding()]
param([string]$TestRoot)
$ErrorActionPreference='Stop'
$toolRoot=Split-Path $PSScriptRoot -Parent
$script:passed=0
function Assert($Condition,[string]$Message) {if(-not $Condition){throw "FAIL: $Message"};$script:passed++;Write-Host "PASS: $Message"}
function Reject([scriptblock]$Action,[string]$Pattern,[string]$Message) {
    $blocked=$false
    try {& $Action|Out-Null} catch {$blocked=$_.Exception.Message -match $Pattern}
    Assert $blocked $Message
}
Assert (Test-Path -LiteralPath (Join-Path $toolRoot 'scripts/Build-Workspace.ps1')) 'Build workspace helpers exist'
. (Join-Path $toolRoot 'scripts/Build-Common.ps1')
. (Join-Path $toolRoot 'scripts/Build-Workspace.ps1')
. (Join-Path $toolRoot 'scripts/Package-Helpers.ps1')
if(-not $TestRoot) {$TestRoot=Join-Path $toolRoot ('verification/fw-'+[guid]::NewGuid().ToString('N').Substring(0,8))}
$install=Join-Path $TestRoot 'installed portable tool'
$source=Join-Path $TestRoot 'source repository'
$workspace=Join-Path $install 'jenkins-home/workspace/faf-windows'
[IO.Directory]::CreateDirectory($install)|Out-Null
[IO.Directory]::CreateDirectory($source)|Out-Null
$layout=Get-BuildWorkspaceLayout -BuildHome $install -Workspace $workspace -BuildNumber 3 -SourceRepository $source
Assert ($layout.dataRoot -eq (Get-SafeFullPath (Join-Path $install 'faf-work/3'))) 'Actual build root is faf-work beside jenkins-home'
Assert ($layout.archiveRoot -eq (Get-SafeFullPath (Join-Path $workspace 'builds/3'))) 'Archives remain in the current Jenkins workspace'
Assert (-not (Test-Path -LiteralPath $layout.dataRoot)) 'Layout validation creates no directories'
Reject {Get-BuildWorkspaceLayout $install $workspace '../other' $source} 'number' 'Reject traversal in build number'
Reject {Get-BuildWorkspaceLayout $install $workspace 3 $install} 'overlap' 'Reject tool/source overlap'
$run=New-CompactBuildRunDirectory $layout.dataRoot
$second=New-CompactBuildRunDirectory $layout.dataRoot
Assert ((Split-Path $run -Leaf) -match '^[0-9a-f]{16}$') 'Run IDs use 16 hex characters'
Assert ($run -ne $second -and (Test-Path -LiteralPath $run)) 'Repeated builds get distinct fresh directories'
$relative='faf_game/addons/dialogic/Modules/DefaultLayoutParts/Layer_SpeakerPortraitTextbox/speaker-textbox-icon.svg.import'
$snapshot=Join-Path $run 'source'
[IO.Directory]::CreateDirectory($snapshot)|Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$zipPath=Join-Path $TestRoot 'deep-source.zip'
$zip=[IO.Compression.ZipFile]::Open($zipPath,[IO.Compression.ZipArchiveMode]::Create)
try {$stream=$zip.CreateEntry($relative).Open();$writer=New-Object IO.StreamWriter($stream);try{$writer.Write('deep path fixture')}finally{$writer.Dispose()}}finally{$zip.Dispose()}
Expand-GitSnapshot $zipPath $snapshot
Assert (Test-Path -LiteralPath (Join-Path $snapshot $relative)) 'Logged deep Dialogic path extracts through compact faf-work layout'
[IO.Directory]::CreateDirectory($layout.archiveRoot)|Out-Null
[IO.Directory]::CreateDirectory((Join-Path $run 'artifacts'))|Out-Null
[IO.Directory]::CreateDirectory((Join-Path $run 'logs'))|Out-Null
Write-Utf8 (Join-Path $run 'artifacts/game.zip') 'fixture delivery'
Write-Utf8 (Join-Path $run 'artifacts/build-manifest.json') '{"mode":"Debug"}'
Write-Utf8 (Join-Path $run 'logs/test.stderr.log') 'ERROR: exact selected run'
$record=@{schemaVersion=1;buildRoot=$layout.dataRoot;runDirectory=$run;runId=(Split-Path $run -Leaf);sourceRepository=(Get-SafeFullPath $source);buildNumber='3';archiveDirectory=$layout.archiveRoot;status='success'}
Write-Utf8 $layout.runRecord ($record|ConvertTo-Json)
$selected=Read-BuildRunRecord -RecordPath $layout.runRecord -ExpectedBuildRoot $layout.dataRoot -ArchiveDirectory $layout.archiveRoot -SourceRepository $source -BuildNumber 3
Assert ($selected.runDirectory -eq $run) 'Run record selects the exact current run'
& (Join-Path $toolRoot 'scripts/Copy-BuildArtifacts.ps1') -BuildHome $install -Workspace $workspace -BuildNumber 3 -SourceRepository $source|Out-Null
$deliveries=@(Get-ChildItem -LiteralPath (Join-Path $layout.archiveRoot 'artifacts') -File)
Assert ($deliveries.Count -eq 2) 'Only game ZIP and manifest are copied for Jenkins'
Assert ([IO.File]::ReadAllText((Join-Path $layout.archiveRoot 'artifacts/game.zip')) -eq 'fixture delivery') 'Copied delivery bytes match the source'
Write-Utf8 (Join-Path $run 'failure-report.log') 'Exact run failure report'
$record.status='failed';Write-Utf8 $layout.runRecord ($record|ConvertTo-Json)
& (Join-Path $toolRoot 'scripts/New-BuildFailureReport.ps1') -BuildRoot $layout.archiveRoot -SourceRepository $source -BuildNumber 3 -RunRecordPath $layout.runRecord -ExpectedBuildRoot $layout.dataRoot|Out-Null
Assert ([IO.File]::ReadAllText((Join-Path $layout.archiveRoot 'failure-report.log')) -eq 'Exact run failure report') 'Failure archive reads the exact faf-work run'
$record.runDirectory=Join-Path $source 'outside';Write-Utf8 $layout.runRecord ($record|ConvertTo-Json)
Reject {Read-BuildRunRecord $layout.runRecord $layout.dataRoot $layout.archiveRoot $source 3} 'outside|within|escaped' 'Reject a record that points outside faf-work'
$record.runDirectory=$run;$record.buildNumber='4';Write-Utf8 $layout.runRecord ($record|ConvertTo-Json)
Reject {Read-BuildRunRecord $layout.runRecord $layout.dataRoot $layout.archiveRoot $source 3} 'number|different|ownership' 'Reject another build number in the run record'
$record.buildNumber='3';$record.archiveDirectory=Join-Path $workspace 'builds/4';Write-Utf8 $layout.runRecord ($record|ConvertTo-Json)
Reject {Read-BuildRunRecord $layout.runRecord $layout.dataRoot $layout.archiveRoot $source 3} 'archive|ownership|different' 'Reject another archive directory in the run record'
$record.archiveDirectory=$layout.archiveRoot;$record.runDirectory=$null;$record.runId=$null;$record.status='failed'
Write-Utf8 $layout.runRecord ($record|ConvertTo-Json)
Write-Utf8 (Join-Path $layout.dataRoot 'failure-report.log') 'Original preflight error and stack'
& (Join-Path $toolRoot 'scripts/New-BuildFailureReport.ps1') -BuildRoot $layout.archiveRoot -SourceRepository $source -BuildNumber 3 -RunRecordPath $layout.runRecord -ExpectedBuildRoot $layout.dataRoot|Out-Null
Assert ([IO.File]::ReadAllText((Join-Path $layout.archiveRoot 'failure-report.log')) -eq 'Original preflight error and stack') 'Preflight record preserves errors before a run directory exists'
$junctionTarget=Join-Path $TestRoot 'junction target'
$junctionHome=Join-Path $TestRoot 'junction tool'
[IO.Directory]::CreateDirectory($junctionTarget)|Out-Null
[IO.Directory]::CreateDirectory($junctionHome)|Out-Null
New-Item -ItemType Junction -Path (Join-Path $junctionHome 'faf-work') -Target $junctionTarget|Out-Null
Reject {Get-BuildWorkspaceLayout $junctionHome (Join-Path $junctionHome 'jenkins-home/workspace/test') 3 $source} 'Reparse' 'Reject a faf-work junction before any build writes'
$record.runDirectory=$run;$record.runId=(Split-Path $run -Leaf);$record.status='success'
Write-Utf8 $layout.runRecord ($record|ConvertTo-Json)
$record.sourceRepository=$install;Write-Utf8 $layout.runRecord ($record|ConvertTo-Json)
Reject {Read-BuildRunRecord $layout.runRecord $layout.dataRoot $layout.archiveRoot $source 3} 'ownership|different' 'Reject a record bound to a different source repository'
Write-Host "Build workspace tests passed: $script:passed"
