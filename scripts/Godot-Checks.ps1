[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GodotPath,
      [Parameter(Mandatory=$true)][string]$ProjectDirectory,
      [Parameter(Mandatory=$true)][string]$RunDirectory,
      [int]$TimeoutSeconds = 120, [switch]$RunTests)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Build-Common.ps1')
# This file is dot-sourced by the build entrypoint; failures propagate to its failure record.
# Editor plugins can preload UID resources before a fresh snapshot's first scan
# populates the UID cache. Bootstrap with only editor_plugins/enabled cleared;
# keep native extensions and autoloads active, then perform the full strict import.
$projectFile = Join-Path $ProjectDirectory 'project.godot'
$projectText = [IO.File]::ReadAllText($projectFile)
$pluginSection = [regex]::Match($projectText, '(?ms)^\[editor_plugins\][ \t]*(?:;[^\r\n]*)?\r?\n(?<body>.*?)(?=^\[|\z)')
if ($pluginSection.Success) {
    # Godot serializes this setting as a PackedStringArray; allow multiline arrays
    # and escaped characters, without mistaking commented-out settings for enabled plugins.
    $enabled = [regex]::Match($pluginSection.Groups['body'].Value, '(?m)^[ \t]*enabled[ \t]*=[ \t]*PackedStringArray\((?<values>(?:\s|"(?:[^"\\]|\\.)*"|,)*)\)')
    if ($enabled.Success -and $enabled.Groups['values'].Value.Contains('"')) {
        $snapshotRoot = Get-SafeFullPath (Join-Path $RunDirectory 'source')
        $projectPath = Get-SafeFullPath $ProjectDirectory
        if (-not (Test-WithinPath $projectPath $snapshotRoot)) {
            throw 'Editor import bootstrap may only modify the disposable run/source snapshot.'
        }
        $originalProjectBytes = [IO.File]::ReadAllBytes($projectFile)
        $offset = $pluginSection.Groups['body'].Index + $enabled.Index
        $bootstrapProject = $projectText.Substring(0, $offset) + 'enabled=PackedStringArray()' + $projectText.Substring($offset + $enabled.Length)
        try {
            Write-Utf8 $projectFile $bootstrapProject
            $null = Invoke-IsolatedGodot -GodotPath $GodotPath -Arguments @('--headless','--path',$ProjectDirectory,'--editor','--quit') -WorkingDirectory $ProjectDirectory -Name 'editor-import-bootstrap' -RunDirectory $RunDirectory -TimeoutSeconds $TimeoutSeconds
        } finally {
            # Preserve encoding/BOM/newlines and undo any editor save even on failure.
            [IO.File]::WriteAllBytes($projectFile, $originalProjectBytes)
        }
    }
}
$null = Invoke-IsolatedGodot -GodotPath $GodotPath -Arguments @('--headless','--path',$ProjectDirectory,'--editor','--quit') -WorkingDirectory $ProjectDirectory -Name 'editor-import' -RunDirectory $RunDirectory -TimeoutSeconds $TimeoutSeconds
$null = Invoke-IsolatedGodot -GodotPath $GodotPath -Arguments @('--headless','--path',$ProjectDirectory,'--quit-after','60') -WorkingDirectory $ProjectDirectory -Name 'main-scene-smoke' -RunDirectory $RunDirectory -TimeoutSeconds $TimeoutSeconds
if ($RunTests) {
    $testDir = Join-Path $ProjectDirectory 'tests'
    # Generate an external-owned runner in the disposable snapshot. The source repository
    # need not contain any tooling files or uncommitted test_script_runner resources.
    $runnerName = '_faf_build_runner_' + [guid]::NewGuid().ToString('N')
    $runnerScript = Join-Path $ProjectDirectory ($runnerName + '.gd')
    Write-Utf8 $runnerScript @'
extends Node
func _ready() -> void:
    call_deferred("_run_suite")
func _run_suite() -> void:
    var arguments := OS.get_cmdline_user_args()
    if arguments.size() != 1 or not arguments[0].begins_with("res://tests/"):
        push_error("Expected one test script in res://tests/")
        get_tree().quit(1)
        return
    var resource = load(arguments[0])
    if not resource is Script or not resource.can_instantiate():
        push_error("Cannot instantiate test script: " + arguments[0])
        get_tree().quit(1)
        return
    if not ClassDB.is_parent_class(resource.get_instance_base_type(), "Node"):
        push_error("Expected a Node test script: " + arguments[0])
        get_tree().quit(1)
        return
    add_child(resource.new())
'@
    Write-Utf8 (Join-Path $ProjectDirectory ($runnerName + '.tscn')) ("[gd_scene load_steps=2 format=3]`n[ext_resource type=`"Script`" path=`"res://$runnerName.gd`" id=`"1`"]`n[node name=`"BuildTestRunner`" type=`"Node`"]`nscript = ExtResource(`"1`")`n")
    try {
        if (Test-Path -LiteralPath $testDir) {
            $index = 0
            foreach ($test in Get-ChildItem -LiteralPath $testDir -Filter 'run_*tests.gd' -File -Recurse | Sort-Object FullName) {
                $index++
                $relative = $test.FullName.Substring($ProjectDirectory.Length + 1).Replace('\','/')
                $resourcePath = 'res://' + $relative
                if ($test.Name -eq 'run_item_display_tests.gd') {
                    $argsForTest = @('--scene','res://tests/item_display_test_runner.tscn')
                } elseif ([IO.File]::ReadAllText($test.FullName) -match '(?m)^\s*extends\s+SceneTree\s*(?:#.*)?$') {
                    $argsForTest = @('--script',$resourcePath)
                } else {
                    $argsForTest = @('--scene',("res://$runnerName.tscn"),'--',$resourcePath)
                }
                $null = Invoke-IsolatedGodot -GodotPath $GodotPath -Arguments (@('--headless','--path',$ProjectDirectory) + $argsForTest) -WorkingDirectory $ProjectDirectory -Name ("test-$index-" + $test.BaseName) -RunDirectory $RunDirectory -TimeoutSeconds $TimeoutSeconds
            }
            # Collection runtime regression remains an optional manual scene test.
            foreach ($scene in @('item_system_test_runner.tscn')) {
                if (Test-Path -LiteralPath (Join-Path $testDir $scene)) {
                    $null = Invoke-IsolatedGodot -GodotPath $GodotPath -Arguments @('--headless','--path',$ProjectDirectory,'--scene',('res://tests/' + $scene)) -WorkingDirectory $ProjectDirectory -Name ('test-scene-' + [IO.Path]::GetFileNameWithoutExtension($scene)) -RunDirectory $RunDirectory -TimeoutSeconds $TimeoutSeconds
                }
            }
        }
    } finally {
        # Only the two exact generated files in this snapshot are removed.
        foreach ($suffix in @('.gd','.tscn','.gd.uid')) {
            $generated = Join-Path $ProjectDirectory ($runnerName + $suffix)
            if (Test-Path -LiteralPath $generated) { Remove-Item -LiteralPath $generated -Force }
        }
    }
}
