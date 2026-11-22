. (Join-Path $PSScriptRoot 'Build-Common.ps1')
function Install-BasicGameFlowProbe([string]$ProjectDirectory,[string]$RunDirectory) {
    $project=Get-SafeFullPath $ProjectDirectory
    $snapshot=Get-SafeFullPath (Join-Path $RunDirectory 'source')
    if(-not (Test-WithinPath $project $snapshot)){throw 'Basic flow probe may only modify the disposable snapshot.'}
    $projectFile=Get-SafeFullPath (Join-Path $project 'project.godot')
    $name='_faf_build_basic_'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $script=Get-SafeFullPath (Join-Path $project ($name+'.gd'))
    if(Test-Path -LiteralPath $script){throw 'Basic flow script already exists.'}
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'basic_game_flow.gd') -Destination $script
    $text=[IO.File]::ReadAllText($projectFile)
    $setting='FafBuildBasicFlow="*res://'+$name+'.gd"'
    if($text -match '(?m)^FafBuildBasicFlow\s*='){throw 'Snapshot already defines FafBuildBasicFlow.'}
    $section=[regex]::Match($text,'(?ms)^\[autoload\][^\r\n]*\r?\n(?<body>.*?)(?=^\[|\z)')
    if($section.Success){$position=$section.Index+$section.Length;$text=$text.Substring(0,$position)+$setting+"`n`n"+$text.Substring($position)}
    else {$text+="`n[autoload]`n"+$setting+"`n"}
    Write-Utf8 $projectFile $text
    return $script
}
function Invoke-GameExport([string]$GodotPath,[string]$ProjectDirectory,[string]$RunDirectory,[string]$BuildMode,[string]$OutputPath,[int]$TimeoutSeconds) {
    $projectFile=Get-SafeFullPath (Join-Path $ProjectDirectory 'project.godot')
    if(-not (Test-WithinPath (Get-SafeFullPath $ProjectDirectory) (Get-SafeFullPath (Join-Path $RunDirectory 'source')))){throw 'Export preparation may only modify the disposable snapshot.'}
    $bytes=[IO.File]::ReadAllBytes($projectFile)
    $text=[IO.File]::ReadAllText($projectFile)
    $section=[regex]::Match($text,'(?ms)^\[editor_plugins\][^\r\n]*\r?\n(?<body>.*?)(?=^\[|\z)')
    try {
        if($section.Success){
            $body=[regex]::Replace($section.Groups['body'].Value,'"res://addons/imgui-godot/plugin\.cfg",\s*|,\s*"res://addons/imgui-godot/plugin\.cfg"|"res://addons/imgui-godot/plugin\.cfg"','')
            $offset=$section.Groups['body'].Index
            Write-Utf8 $projectFile ($text.Substring(0,$offset)+$body+$text.Substring($offset+$section.Groups['body'].Length))
        }
        Invoke-IsolatedGodot -GodotPath $GodotPath -Arguments @('--headless','--path',$ProjectDirectory,('--export-'+$BuildMode.ToLowerInvariant()),'Windows Desktop',$OutputPath) -WorkingDirectory $ProjectDirectory -Name 'windows-export' -RunDirectory $RunDirectory -TimeoutSeconds $TimeoutSeconds
    } finally {[IO.File]::WriteAllBytes($projectFile,$bytes)}
}