[CmdletBinding()]
param([string]$TestRoot)
$ErrorActionPreference='Stop'
$toolRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $toolRoot 'scripts/Build-Common.ps1')
if(-not $TestRoot){$TestRoot=Join-Path $toolRoot ('verification/policy-'+[guid]::NewGuid().ToString('N').Substring(0,8))}
$source=Join-Path $TestRoot 'source'
[IO.Directory]::CreateDirectory((Join-Path $source 'faf_game/tests'))|Out-Null
[IO.Directory]::CreateDirectory((Join-Path $source 'faf_config'))|Out-Null
Write-Utf8 (Join-Path $source 'faf_game/project.godot') "config_version=5`n[application]`nconfig/name=`"PolicyFixture`"`nrun/main_scene=`"res://main.tscn`"`n[rendering]`nrenderer/rendering_method=`"gl_compatibility`"`n"
Write-Utf8 (Join-Path $source 'faf_game/main.tscn') "[gd_scene load_steps=2 format=3]`n[ext_resource type=`"Script`" path=`"res://main.gd`" id=`"1`"]`n[node name=`"Game`" type=`"Node`"]`nscript=ExtResource(`"1`")`n"
Write-Utf8 (Join-Path $source 'faf_game/main.gd') @"
extends Node
enum SessionState { WaitingForStart, Starting, Running }
var session_state = SessionState.WaitingForStart
var level_prepared = false
var player: Node
var current_level_instance: Node
func start_new_game() -> void:
    player = Node.new()
    add_child(player)
    current_level_instance = Node.new()
    add_child(current_level_instance)
    session_state = SessionState.Running
    level_prepared = true
"@
Write-Utf8 (Join-Path $source 'faf_config/items.csv') "id,name`n1,fixture`n"
Write-Utf8 (Join-Path $source 'faf_game/tests/run_policy_tests.gd') "extends SceneTree`nfunc _initialize():`n`tpush_error(`"FAF_OPTIONAL_POLICY_FAILURE`")`n`tquit(1)`n"
$git='E:/fb/runtime/git/cmd/git.exe'
foreach($args in @(@('init','-b','main'),@('config','user.name','Policy Fixture'),@('config','user.email','fixture@example.invalid'),@('add','.'),@('commit','-m','policy fixture'))){Invoke-BuildProcess $git (@('-C',$source)+$args) $source|Out-Null}
$env:PATH='E:/fb/runtime/git/cmd;E:/fb/runtime/git/mingw64/bin;E:/fb/runtime/git/usr/bin;'+$env:PATH
$build=Join-Path $toolRoot 'scripts/Build-Windows.ps1'
$ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$root=Join-Path $TestRoot 'advisory-build'
Invoke-BuildProcess $ps @('-NoProfile','-ExecutionPolicy','Bypass','-File',$build,'-SourceRepository',$source,'-BranchName','main','-GodotPath','E:/fb/runtime/godot/godot.exe','-BuildRoot',$root,'-BuildMode','Debug','-BuildNumber','policy','-Version','policy','-RunTests','-ExportTemplate','E:/fb/runtime/templates/4.7.2.stable/windows_debug_x86_64.exe') $toolRoot 180 (Join-Path $TestRoot 'build')|Out-Null
$run=@(Get-ChildItem -LiteralPath $root -Directory)[0].FullName
$files=@(Get-ChildItem -LiteralPath (Join-Path $run 'artifacts') -File)
if(@($files|Where-Object Extension -eq '.zip').Count -ne 1){throw 'Advisory failure prevented game ZIP'}
$report=Join-Path $run 'artifacts/test-report.log'
if(-not (Test-Path -LiteralPath $report) -or -not [IO.File]::ReadAllText($report).Contains('FAF_OPTIONAL_POLICY_FAILURE')){throw 'Optional failure not captured in one report'}
$basic=Join-Path $run 'logs/basic-game-flow.stdout.log'
if(-not (Test-Path -LiteralPath $basic) -or -not [IO.File]::ReadAllText($basic).Contains('FAF_BASIC_FLOW_PASSED')){throw 'Actual start-new-game flow was not verified'}
$manifest=[IO.File]::ReadAllText((Join-Path $run 'artifacts/build-manifest.json'))|ConvertFrom-Json
if($manifest.checks.advisory.failed -ne 1 -or $manifest.checks.basicFlow -ne 'passed'){throw 'Manifest does not distinguish basic/advisory outcomes'}
Write-Host 'PASS: failed optional test preserves ZIP, basic flow and one diagnostic report.'
Write-Host ('Evidence: '+$TestRoot)
$defaultRoot=Join-Path $TestRoot 'default-build'
Invoke-BuildProcess $ps @('-NoProfile','-ExecutionPolicy','Bypass','-File',$build,'-SourceRepository',$source,'-BranchName','main','-GodotPath','E:/fb/runtime/godot/godot.exe','-BuildRoot',$defaultRoot,'-BuildMode','Debug','-BuildNumber','default','-Version','default','-ExportTemplate','E:/fb/runtime/templates/4.7.2.stable/windows_debug_x86_64.exe') $toolRoot 180 (Join-Path $TestRoot 'default')|Out-Null
$defaultRun=@(Get-ChildItem -LiteralPath $defaultRoot -Directory)[0].FullName
$defaultManifest=[IO.File]::ReadAllText((Join-Path $defaultRun 'artifacts/build-manifest.json'))|ConvertFrom-Json
if($defaultManifest.checks.advisory.requested -or $defaultManifest.checks.advisory.total -ne 0 -or (Test-Path -LiteralPath (Join-Path $defaultRun 'artifacts/test-report.log'))){throw 'Default policy ran functional suites'}
Write-Host 'PASS: default only checks actual exported basic flow, no functional suites.'
Invoke-BuildProcess $git @('-C',$source,'checkout','-b','broken-basic') $source|Out-Null
Write-Utf8 (Join-Path $source 'faf_game/main.gd') "extends Node`nenum SessionState { WaitingForStart, Starting, Running }`nvar session_state=SessionState.WaitingForStart`nfunc start_new_game():`n`tpush_error(`"FAF_BLOCKING_BASIC_FAILURE`")`n`tget_tree().quit(1)`n"
foreach($args in @(@('add','.'),@('commit','-m','broken basic fixture'))){Invoke-BuildProcess $git (@('-C',$source)+$args) $source|Out-Null}
$badRoot=Join-Path $TestRoot 'broken-basic-build'
$blocked=$false
try{Invoke-BuildProcess $ps @('-NoProfile','-ExecutionPolicy','Bypass','-File',$build,'-SourceRepository',$source,'-BranchName','broken-basic','-GodotPath','E:/fb/runtime/godot/godot.exe','-BuildRoot',$badRoot,'-BuildMode','Debug','-BuildNumber','bad','-Version','bad','-ExportTemplate','E:/fb/runtime/templates/4.7.2.stable/windows_debug_x86_64.exe') $toolRoot 180 (Join-Path $TestRoot 'bad')|Out-Null}catch{$blocked=$true}
$badRun=@(Get-ChildItem -LiteralPath $badRoot -Directory)[0].FullName
if(-not $blocked -or @(Get-ChildItem -LiteralPath (Join-Path $badRun 'artifacts') -Filter '*.zip').Count -ne 0 -or -not [IO.File]::ReadAllText((Join-Path $badRun 'failure-report.log')).Contains('FAF_BLOCKING_BASIC_FAILURE')){throw 'Basic flow failure did not block ZIP and retain original logs'}
Write-Host 'PASS: actual basic flow errors remain blocking and retain one failure report.'