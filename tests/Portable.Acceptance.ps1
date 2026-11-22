[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PackageDirectory,[string]$TestRoot)
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $toolRoot 'scripts/Portable-Helpers.ps1')
if (-not $TestRoot) { $TestRoot = Join-Path $toolRoot ('verification/pa-' + [guid]::NewGuid().ToString('N').Substring(0,8)) }
$testRootPath = Get-SafeFullPath $TestRoot
[IO.Directory]::CreateDirectory($testRootPath) | Out-Null
$unicodeLabel = '"\u4fbf\u643a \u5de5\u5177"' | ConvertFrom-Json
$homePath = Join-Path $testRootPath ($unicodeLabel + ' original')
$movedPath = Join-Path $testRootPath ($unicodeLabel + ' moved')
$source = Join-Path $testRootPath 'fixture repository'
$results = New-Object 'System.Collections.Generic.List[string]'
function Assert($Condition,[string]$Message) {
    if (-not $Condition) { throw "Acceptance failed: $Message" }
    $results.Add($Message); Write-Host "PASS: $Message"
}
$package = Test-PortablePayload $PackageDirectory
foreach ($name in @('jenkins-home','portable-config.json','builds','faf-work','logs','runtime/dependencies.json','runtime/jenkins.pid.json')) {
    Assert (-not (Test-Path -LiteralPath (Join-Path $package.root $name))) ("Clean release excludes $name")
}
Copy-Item -LiteralPath $package.root -Destination $homePath -Recurse
[IO.Directory]::CreateDirectory((Join-Path $source 'faf_game/tests')) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $source 'faf_config')) | Out-Null
Write-Utf8 (Join-Path $source 'faf_game/project.godot') @'
config_version=5
[application]
config/name="PortableAcceptance"
run/main_scene="res://main.tscn"
[rendering]
renderer/rendering_method="gl_compatibility"
'@
Write-Utf8 (Join-Path $source 'faf_game/main.gd') "extends Node`nfunc _ready():`n`tget_tree().quit()`n"
Write-Utf8 (Join-Path $source 'faf_game/main.tscn') @'
[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://main.gd" id="1"]
[node name="Main" type="Node"]
script = ExtResource("1")
'@
Write-Utf8 (Join-Path $source 'faf_game/tests/run_portable_tests.gd') "extends SceneTree`nfunc _initialize():`n`tprint(`"portable acceptance suite passed`")`n`tquit()`n"
Write-Utf8 (Join-Path $source 'faf_config/items.csv') "id,name`n1,portable`n"
$deepRelative='faf_game/addons/dialogic/Modules/DefaultLayoutParts/Layer_SpeakerPortraitTextbox/speaker-textbox-icon.svg'
$deepFile=Join-Path $source $deepRelative
[IO.Directory]::CreateDirectory((Split-Path $deepFile -Parent))|Out-Null
Write-Utf8 $deepFile '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8" fill="#fff"/></svg>'
Write-Utf8 (Join-Path $source '.gitignore') "faf_game/.godot/`n"
$prepare=Join-Path $testRootPath 'prepare'
[IO.Directory]::CreateDirectory((Join-Path $prepare 'logs'))|Out-Null
Invoke-BuildProcess -FilePath (Get-PortableRuntime $homePath).godot -Arguments @('--headless','--path',(Join-Path $source 'faf_game'),'--editor','--quit') -WorkingDirectory $source -Environment (New-GodotEnvironment $prepare) -TimeoutSeconds 90 -LogPrefix (Join-Path $prepare 'logs/import') -CheckGodotErrors|Out-Null
Assert (Test-Path -LiteralPath ($deepFile+'.import')) 'Fixture includes the same deep Dialogic import filename as the user log'
$oldRunName='20261121T160738418Z-3e9645c88e854d379303548da65de287'
$oldDeepPath=Join-Path $homePath ('jenkins-home/workspace/faf-windows/builds/1/'+$oldRunName+'/source/'+$deepRelative+'.import')
Assert ($oldDeepPath.Length -gt 259) 'The deep fixture would exceed MAX_PATH in the old workspace layout'
$git = (Get-PortableRuntime $homePath).git
foreach ($arguments in @(@('init','-b','main'),@('config','user.name','Portable Fixture'),@('config','user.email','portable@example.invalid'),@('add','.'),@('commit','-m','portable fixture'))) {
    Invoke-BuildProcess -FilePath $git -Arguments (@('-C',$source) + $arguments) -WorkingDirectory $source | Out-Null
}
# A committed test failure exercises the actual failing Pipeline/report path.
Invoke-BuildProcess -FilePath $git -Arguments @('-C',$source,'checkout','-b','broken-fixture') -WorkingDirectory $source | Out-Null
Write-Utf8 (Join-Path $source 'faf_game/tests/run_portable_tests.gd') "extends SceneTree`nfunc _initialize():`n`tpush_error(`"FAF_EXPECTED_REPORT_FAILURE`")`n`tquit(1)`n"
foreach($arguments in @(@('add','.'),@('commit','-m','intentional report failure'),@('checkout','main'))) {
    Invoke-BuildProcess -FilePath $git -Arguments (@('-C',$source)+$arguments) -WorkingDirectory $source | Out-Null
}
$sourceSha = Invoke-BuildProcess -FilePath $git -Arguments @('-C',$source,'rev-parse','HEAD') -WorkingDirectory $source
$oldPath = $env:PATH
$env:PATH = (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot + ';' + (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0')
Assert ($null -eq (Get-Command git.exe -ErrorAction SilentlyContinue)) 'System Git unavailable to launch process'
Assert ($null -eq (Get-Command java.exe -ErrorAction SilentlyContinue)) 'System Java unavailable to launch process'
$activeHome = $homePath
$headers = $null
try {
    Invoke-BuildProcess -FilePath (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $homePath 'scripts/Start-Portable.ps1'),'-SourceRepository',$source,'-NoBrowser','-NonInteractive') -WorkingDirectory $testRootPath -TimeoutSeconds 260 -LogPrefix (Join-Path $testRootPath 'launch') | Out-Null
    $state = Get-PortableLiveInstance $homePath
    Assert ($null -ne $state) 'Fresh Jenkins starts from Unicode/spaces path'
    $baseUrl = "http://127.0.0.1:$($state.port)"
    $secret = [IO.File]::ReadAllText((Join-Path $homePath 'jenkins-home/secrets/faf-portable-admin.json')) | ConvertFrom-Json
    $initialPassword = $secret.password
    $headers = @{ Authorization='Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($secret.user + ':' + $secret.token)) }
    $anonymousDenied = $false
    try { Invoke-WebRequest -Uri ($baseUrl + '/job/faf-windows/api/json') -MaximumRedirection 0 -UseBasicParsing | Out-Null }
    catch { $anonymousDenied = [int]$_.Exception.Response.StatusCode -in @(302,401,403) }
    Assert $anonymousDenied 'Anonymous users cannot read build task'
    $job = Invoke-RestMethod -Uri ($baseUrl + '/job/faf-windows/api/json') -Headers $headers
    Assert ($job.name -eq 'faf-windows') 'Authenticated task API works with generated token'
    $parameterNames = @($job.property | ForEach-Object { if ($_.PSObject.Properties['parameterDefinitions']) { $_.parameterDefinitions.name } })
    Assert ($parameterNames -contains 'BUILD_BRANCH' -and $parameterNames -contains 'BUILD_MODE') 'First launch already provides build parameters'
    $beforePid = $state.pid
    Invoke-BuildProcess -FilePath (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $homePath 'scripts/Start-Portable.ps1'),'-NoBrowser','-NonInteractive') -WorkingDirectory $testRootPath -TimeoutSeconds 60 | Out-Null
    Assert ((Get-PortableLiveInstance $homePath).pid -eq $beforePid) 'Repeated launch reuses the same instance'
    $readyMarker = Join-Path $homePath 'runtime/portable-ready.json'
    $savedMarker = [IO.File]::ReadAllText($readyMarker)
    Remove-Item -LiteralPath $readyMarker
    try {
        $rejectedUnready = $false
        try {
            Invoke-BuildProcess -FilePath (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $homePath 'scripts/Start-Portable.ps1'),'-NoBrowser','-NonInteractive','-StartupTimeoutSeconds','10') -WorkingDirectory $testRootPath -TimeoutSeconds 35 | Out-Null
        } catch { $rejectedUnready = $_.Exception.Message -match 'startup timed out' }
        Assert $rejectedUnready 'Repeated launch cannot claim readiness without bootstrap marker'
    } finally { Write-Utf8 $readyMarker $savedMarker }
    foreach ($mode in @('Debug','Release')) {
        $response = Invoke-WebRequest -Uri ($baseUrl + '/job/faf-windows/buildWithParameters') -Method Post -Headers $headers -Body @{BUILD_BRANCH='main';BUILD_MODE=$mode;BUILD_VERSION=('portable-' + $mode);RUN_TESTS='true'} -UseBasicParsing
        $queueUrl = $response.Headers['Location']
        $deadline = [DateTime]::UtcNow.AddMinutes(5)
        $buildUrl = $null
        while ([DateTime]::UtcNow -lt $deadline) {
            $queue = Invoke-RestMethod -Uri ($queueUrl + 'api/json') -Headers $headers
            if ($queue.PSObject.Properties['executable'] -and $queue.executable) { $buildUrl=$queue.executable.url; break }
            Start-Sleep -Seconds 1
        }
        if (-not $buildUrl) { throw "Jenkins $mode build stayed in queue." }
        do {
            $build = Invoke-RestMethod -Uri ($buildUrl + 'api/json') -Headers $headers
            if (-not $build.building) { break }
            Start-Sleep -Seconds 1
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($build.result -ne 'SUCCESS') {
            $console = (Invoke-WebRequest -Uri ($buildUrl + 'consoleText') -Headers $headers -UseBasicParsing).Content
            Write-Utf8 (Join-Path $testRootPath ($mode + '-console.log')) $console
            throw "Jenkins $mode result: $($build.result). See $testRootPath/$mode-console.log"
        }
        Assert ($build.result -eq 'SUCCESS') ("Real Jenkins $mode pipeline succeeds using bundled tools")
        $artifactNames = @($build.artifacts.fileName)
        Assert (@($artifactNames | Where-Object { $_.EndsWith('.zip') }).Count -gt 0 -and $artifactNames -contains 'build-manifest.json') ("$mode ZIP and build manifest archived")
        Assert ($artifactNames.Count -eq 2) ("$mode successful archive excludes diagnostics")
        $archiveRoot=Join-Path $homePath ('jenkins-home/workspace/faf-windows/builds/'+$build.number)
        $runRecord=[IO.File]::ReadAllText((Join-Path $archiveRoot 'run.json'))|ConvertFrom-Json
        $expectedData=Get-SafeFullPath (Join-Path $homePath ('faf-work/'+$build.number))
        Assert ((Split-Path $runRecord.runDirectory -Parent) -eq $expectedData -and $runRecord.status -eq 'success') ("$mode real work occurs in same-level faf-work")
        Assert ((Split-Path $runRecord.runDirectory -Leaf) -match '^[0-9a-f]{16}$') ("$mode run uses a compact unique ID")
        $imported=Join-Path $runRecord.runDirectory ('source/'+$deepRelative+'.import')
        Assert ($imported.Length -lt 260 -and (Test-Path -LiteralPath $imported)) ("$mode deep Dialogic resource extracts and imports below MAX_PATH")
        Assert (-not (Test-Path -LiteralPath (Join-Path $archiveRoot 'source'))) ("$mode Jenkins workspace does not hold the source snapshot")
    }
    $response=Invoke-WebRequest -Uri ($baseUrl+'/job/faf-windows/buildWithParameters') -Method Post -Headers $headers -Body @{BUILD_BRANCH='broken-fixture';BUILD_MODE='Debug';BUILD_VERSION='expected-failure';RUN_TESTS='true'} -UseBasicParsing
    $queueUrl=$response.Headers['Location']
    $deadline=[DateTime]::UtcNow.AddMinutes(5)
    $buildUrl=$null
    while([DateTime]::UtcNow -lt $deadline) {
        $queue=Invoke-RestMethod -Uri ($queueUrl+'api/json') -Headers $headers
        if($queue.PSObject.Properties['executable'] -and $queue.executable) {$buildUrl=$queue.executable.url;break}
        Start-Sleep -Seconds 1
    }
    if(-not $buildUrl) {throw 'Intentional failure stayed in queue.'}
    do {
        $failedBuild=Invoke-RestMethod -Uri ($buildUrl+'api/json') -Headers $headers
        if(-not $failedBuild.building) {break}
        Start-Sleep -Seconds 1
    } while([DateTime]::UtcNow -lt $deadline)
    Assert ($failedBuild.result -eq 'FAILURE') 'Intentional test error still fails the real Pipeline'
    Assert (@($failedBuild.artifacts).Count -eq 1 -and $failedBuild.artifacts[0].fileName -eq 'failure-report.log') 'Failed Pipeline archives exactly one consolidated report'
    $reportContent=(Invoke-WebRequest -Uri ($buildUrl+'artifact/'+$failedBuild.artifacts[0].relativePath) -Headers $headers -UseBasicParsing).Content
    Write-Utf8 (Join-Path $testRootPath 'expected-failure-report.log') $reportContent
    Assert ($reportContent.Contains('FAF_EXPECTED_REPORT_FAILURE') -and $reportContent.Contains('run_portable_tests') -and $reportContent.Contains('exitCode') -and $reportContent.Contains('Stack:')) 'Downloaded report contains test error, original stack and process records'
    # Temporarily hide this test fixture's own Git metadata to exercise failure
    # while obtaining the branch list, before Build-Windows creates a run.
    $gitMetadata=Get-SafeFullPath (Join-Path $source '.git')
    $hiddenMetadata=Get-SafeFullPath (Join-Path $source '.git-report-test')
    if(-not (Test-WithinPath $gitMetadata $testRootPath) -or -not (Test-WithinPath $hiddenMetadata $testRootPath)) {throw 'Fixture metadata move escaped test root.'}
    Move-Item -LiteralPath $gitMetadata -Destination $hiddenMetadata
    try {
        $response=Invoke-WebRequest -Uri ($baseUrl+'/job/faf-windows/buildWithParameters') -Method Post -Headers $headers -Body @{BUILD_BRANCH='';BUILD_MODE='Release';BUILD_VERSION='selection-failure';RUN_TESTS='true'} -UseBasicParsing
        $queueUrl=$response.Headers['Location']
        $deadline=[DateTime]::UtcNow.AddMinutes(3)
        $buildUrl=$null
        while([DateTime]::UtcNow -lt $deadline) {
            $queue=Invoke-RestMethod -Uri ($queueUrl+'api/json') -Headers $headers
            if($queue.PSObject.Properties['executable'] -and $queue.executable) {$buildUrl=$queue.executable.url;break}
            Start-Sleep -Seconds 1
        }
        if(-not $buildUrl) {throw 'Branch failure stayed in queue.'}
        do {
            $selectionBuild=Invoke-RestMethod -Uri ($buildUrl+'api/json') -Headers $headers
            if(-not $selectionBuild.building) {break}
            Start-Sleep -Seconds 1
        } while([DateTime]::UtcNow -lt $deadline)
        Assert ($selectionBuild.result -eq 'FAILURE' -and @($selectionBuild.artifacts).Count -eq 1 -and $selectionBuild.artifacts[0].fileName -eq 'failure-report.log') 'Branch-selection failure also archives exactly one report'
        $selectionText=(Invoke-WebRequest -Uri ($buildUrl+'artifact/'+$selectionBuild.artifacts[0].relativePath) -Headers $headers -UseBasicParsing).Content
        $gitDiagnosis=$selectionText.Contains('not a git repository') -or $selectionText.Contains('SourceRepository must be the repository root')
        Assert ($gitDiagnosis -and $selectionText.Contains('git-root.stderr.log') -and $selectionText.Contains('Release')) 'Archived pre-run report includes underlying Git diagnosis and selected mode'
        Write-Utf8 (Join-Path $testRootPath 'selection-failure-report.log') $selectionText
    } finally {Move-Item -LiteralPath $hiddenMetadata -Destination $gitMetadata}
    Invoke-BuildProcess -FilePath (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $homePath 'scripts/Stop-Portable.ps1'),'-TimeoutSeconds','60') -WorkingDirectory $testRootPath -TimeoutSeconds 80 | Out-Null
    Assert ($null -eq (Get-PortableLiveInstance $homePath)) 'Authenticated safe shutdown stops only this instance'
    # Simulate an interrupted seed: config.xml exists, one plugin is absent and
    # the completion marker was never recorded. Restart must repair it.
    $missingPlugin = Join-Path $homePath 'jenkins-home/plugins/workflow-job.jpi'
    Remove-Item -LiteralPath $missingPlugin
    Remove-Item -LiteralPath (Join-Path $homePath 'jenkins-home/.faf-portable-plugins-seeded')
    # Both resolved paths were validated within the acceptance workspace.
    $moveSource = Get-SafeFullPath $homePath
    $moveTarget = Get-SafeFullPath $movedPath
    if (-not (Test-WithinPath $moveSource $testRootPath) -or -not (Test-WithinPath $moveTarget $testRootPath)) { throw 'Acceptance move escaped test root.' }
    Move-Item -LiteralPath $moveSource -Destination $moveTarget
    $activeHome = $movedPath
    Invoke-BuildProcess -FilePath (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $movedPath 'scripts/Start-Portable.ps1'),'-NoBrowser','-NonInteractive') -WorkingDirectory $testRootPath -TimeoutSeconds 260 -LogPrefix (Join-Path $testRootPath 'relocated-launch') | Out-Null
    $state = Get-PortableLiveInstance $movedPath
    Assert ($state.executable -eq (Get-PortableRuntime $movedPath).java) 'Relocated instance runs Java from its new directory'
    Assert (Test-Path -LiteralPath (Join-Path $movedPath 'jenkins-home/plugins/workflow-job.jpi')) 'Interrupted plugin seed is repaired on restart'
    $secretAfterMove = [IO.File]::ReadAllText((Join-Path $movedPath 'jenkins-home/secrets/faf-portable-admin.json')) | ConvertFrom-Json
    Assert ($secretAfterMove.password -eq $initialPassword) 'Restart preserves the original account password'
    $jobAfterMove = Invoke-RestMethod -Uri ("http://127.0.0.1:$($state.port)/job/faf-windows/api/json") -Headers $headers
    Assert (@($jobAfterMove.builds).Count -eq 4) 'Relocation preserves successful and failing build histories'
    $finalSha = Invoke-BuildProcess -FilePath (Get-PortableRuntime $movedPath).git -Arguments @('-C',$source,'rev-parse','HEAD') -WorkingDirectory $source
    Assert ($finalSha -eq $sourceSha) 'Source repository commit remains unchanged'
} finally {
    $env:PATH = $oldPath
    if (Get-PortableLiveInstance $activeHome) {
        & (Join-Path $activeHome 'scripts/Stop-Portable.ps1') -TimeoutSeconds 60
    }
    Remove-Variable secret,secretAfterMove,headers,initialPassword -ErrorAction SilentlyContinue
    Write-Utf8 (Join-Path $testRootPath 'acceptance-results.json') ($results | ConvertTo-Json)
}
Write-Host "Portable acceptance passed: $($results.Count). Evidence: $testRootPath"
