[CmdletBinding()]
param([string]$TestRoot)
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path $PSScriptRoot -Parent
$script:passed = 0
function Assert($Condition,[string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++; Write-Host "PASS: $Message"
}
Assert (Test-Path -LiteralPath (Join-Path $toolRoot 'scripts/Failure-Report.ps1')) 'Combined failure reporter exists'
. (Join-Path $toolRoot 'scripts/Build-Common.ps1')
. (Join-Path $toolRoot 'scripts/Failure-Report.ps1')
if (-not $TestRoot) { $TestRoot=Join-Path $toolRoot ('test-results/failure-report-'+[guid]::NewGuid().ToString('N')) }
$run=Join-Path $TestRoot 'run'
$logs=Join-Path $run 'logs'
$source=Join-Path $TestRoot 'source'
[IO.Directory]::CreateDirectory($logs)|Out-Null
[IO.Directory]::CreateDirectory($source)|Out-Null
$unicode='"\u8d44\u6e90\u52a0\u8f7d\u5931\u8d25"'|ConvertFrom-Json
Write-Utf8 (Join-Path $logs 'editor-import.stdout.log') "import progress`n$unicode`n"
Write-Utf8 (Join-Path $logs 'editor-import.stderr.log') 'ERROR: missing asset'
Write-Utf8 (Join-Path $logs 'editor-import.godot.log') "before error`nSCRIPT ERROR: invalid call`n  at example.gd:42`nafter error"
Write-Utf8 (Join-Path $logs 'editor-import.process.json') '{"executable":"godot.exe","exitCode":1,"timedOut":false}'
Write-Utf8 (Join-Path $logs 'git-archive.stderr.log') ''
Write-Utf8 (Join-Path $logs 'not-a-log.json') '{"password":"must-not-copy"}'
[IO.Directory]::CreateDirectory((Join-Path $logs 'nested'))|Out-Null
Write-Utf8 (Join-Path $logs 'nested/secret.log') 'nested-must-not-copy'
$report=Join-Path $run 'failure-report.log'
$failure=$null
try { throw 'Build fixture failed' } catch { $failure=$_ }
Write-FailureReport -ReportPath $report -FailureRecord $failure -Context @{branch='feature/example';mode='Debug';sourceRepository=$source} -LogsDirectory $logs | Out-Null
$text=[IO.File]::ReadAllText($report)
Assert ($text.Contains('Build fixture failed') -and $text.Contains('feature/example')) 'Summary contains original error and branch'
Assert ($text.Contains('Failure-Report.Tests.ps1') -and $text.Contains('Stack')) 'Original invocation and script stack are preserved'
Assert ($text.Contains($unicode)) 'UTF-8 Unicode log content is preserved'
Assert ($text.Contains('before error') -and $text.Contains('after error') -and $text.Contains('example.gd:42')) 'Full Godot context and call stack are retained'
Assert ($text.Contains('exitCode') -and $text.Contains('timedOut')) 'Process execution metadata is included'
Assert ($text.Contains('git-archive.stderr.log') -and $text.Contains('[empty]')) 'Empty logs have explicit file sections'
Assert (-not $text.Contains('must-not-copy')) 'Only direct log and process files are collected'
$emptyReport=Join-Path $TestRoot 'early/failure-report.log'
Write-FailureReport -ReportPath $emptyReport -Message 'Failed before launching tools' -Context @{sourceRepository=$source} | Out-Null
Assert ([IO.File]::ReadAllText($emptyReport).Contains('No process logs')) 'Pre-process failure produces a readable report'
$blocked=$false
try { Write-FailureReport -ReportPath (Join-Path $source 'failure-report.log') -Message 'blocked' -Context @{sourceRepository=$source} | Out-Null } catch { $blocked=$_.Exception.Message -match 'overlap' }
Assert ($blocked -and -not (Test-Path -LiteralPath (Join-Path $source 'failure-report.log'))) 'Reporter never writes into source repository'
$startup=Join-Path $TestRoot 'startup'
[IO.Directory]::CreateDirectory((Join-Path $startup 'runtime/logs'))|Out-Null
[IO.Directory]::CreateDirectory((Join-Path $startup 'jenkins-home/secrets'))|Out-Null
Write-Utf8 (Join-Path $startup 'jenkins-home/secrets/faf-portable-admin.json') '{"user":"admin","password":"fixture-password-123","token":"fixture-api-token-456"}'
Write-Utf8 (Join-Path $startup 'jenkins-home/secrets/initialAdminPassword') 'fixture-initial-789'
Write-Utf8 (Join-Path $startup 'runtime/logs/old.stderr.log') 'old-attempt-must-not-copy'
$started=[DateTime]::UtcNow.AddSeconds(-1)
(Get-Item -LiteralPath (Join-Path $startup 'runtime/logs/old.stderr.log')).LastWriteTimeUtc=$started.AddHours(-1)
(Get-Item -LiteralPath (Join-Path $startup 'runtime/logs/old.stderr.log')).CreationTimeUtc=$started.AddHours(-1)
Write-Utf8 (Join-Path $startup 'runtime/logs/jenkins-current.stderr.log') "startup failed fixture-password-123 fixture-api-token-456 fixture-initial-789`nAuthorization: Basic confidential"
Write-StartupFailureReport -BuildHome $startup -FailureRecord $failure -StartedUtc $started -Context @{sourceRepository=$source} | Out-Null
$startupText=[IO.File]::ReadAllText((Join-Path $startup 'runtime/failure-report.log'))
Assert ($startupText.Contains('startup failed') -and $startupText.Contains('[REDACTED]')) 'Startup logs are consolidated with credential redaction'
Assert (-not ($startupText -match 'fixture-password-123|fixture-api-token-456|fixture-initial-789|confidential|old-attempt-must-not-copy')) 'Known credentials and previous attempts are excluded'
$pipelineRoot=Join-Path $TestRoot 'pipeline-build-7'
[IO.Directory]::CreateDirectory($pipelineRoot)|Out-Null
& (Join-Path $toolRoot 'scripts/New-BuildFailureReport.ps1') -BuildRoot $pipelineRoot -SourceRepository $source -BranchName main -BuildMode Debug -BuildNumber 7 | Out-Null
Assert ([IO.File]::ReadAllText((Join-Path $pipelineRoot 'failure-report.log')).Contains('before a build run was created')) 'Pipeline pre-run failure still produces one report'
$pipelineRun=Join-Path $pipelineRoot 'one-run'
Copy-Item -LiteralPath $run -Destination $pipelineRun -Recurse
& (Join-Path $toolRoot 'scripts/New-BuildFailureReport.ps1') -BuildRoot $pipelineRoot -SourceRepository $source -BranchName main -BuildMode Debug -BuildNumber 7 | Out-Null
Assert ([IO.File]::ReadAllText((Join-Path $pipelineRoot 'failure-report.log')) -eq [IO.File]::ReadAllText($report)) 'Pipeline archive preserves the original complete report and stack'
$missingSource=Join-Path $TestRoot 'missing source'
$earlyBuild=Join-Path $TestRoot 'early build'
$child=New-Object Diagnostics.Process
$child.StartInfo.FileName=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$child.StartInfo.UseShellExecute=$false
$child.StartInfo.CreateNoWindow=$true
$child.StartInfo.RedirectStandardOutput=$true
$child.StartInfo.RedirectStandardError=$true
$argsList=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $toolRoot 'scripts/Build-Windows.ps1'),'-SourceRepository',$missingSource,'-BranchName','main','-GodotPath',(Join-Path $TestRoot 'absent-godot.exe'),'-BuildRoot',$earlyBuild)
$child.StartInfo.Arguments=($argsList|ForEach-Object {ConvertTo-NativeArgument $_}) -join ' '
try {
    $null=$child.Start();$out=$child.StandardOutput.ReadToEndAsync();$err=$child.StandardError.ReadToEndAsync()
    if(-not $child.WaitForExit(20000)) {$child.Kill();throw 'Early build probe timed out'}
    Assert ($child.ExitCode -eq 1 -and (Test-Path -LiteralPath (Join-Path $earlyBuild 'failure-report.log'))) 'Real build entrypoint reports pre-run source failure with original exit code'
    Assert ([IO.File]::ReadAllText((Join-Path $earlyBuild 'failure-report.log')).Contains('Source repository not found')) 'Pre-run report identifies missing source'
    $originalEarly=[IO.File]::ReadAllText((Join-Path $earlyBuild 'failure-report.log'))
    & (Join-Path $toolRoot 'scripts/New-BuildFailureReport.ps1') -BuildRoot $earlyBuild -SourceRepository $missingSource -BranchName main -BuildMode Debug | Out-Null
    Assert ([IO.File]::ReadAllText((Join-Path $earlyBuild 'failure-report.log')) -eq $originalEarly) 'Pipeline preserves a detailed root report from a pre-run failure'
} finally {$child.Dispose()}
$selectionRoot=Join-Path $TestRoot 'branch-selection'
$selectionLogs=Join-Path $selectionRoot 'selection-logs'
$child=New-Object Diagnostics.Process
$child.StartInfo.FileName=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$child.StartInfo.UseShellExecute=$false
$child.StartInfo.CreateNoWindow=$true
$child.StartInfo.RedirectStandardOutput=$true
$child.StartInfo.RedirectStandardError=$true
$argsList=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $toolRoot 'scripts/Get-Branches.ps1'),'-SourceRepository',$source,'-LogDirectory',$selectionLogs)
$child.StartInfo.Arguments=($argsList|ForEach-Object {ConvertTo-NativeArgument $_}) -join ' '
try {
    $null=$child.Start();$out=$child.StandardOutput.ReadToEndAsync();$err=$child.StandardError.ReadToEndAsync()
    if(-not $child.WaitForExit(20000)) {$child.Kill();throw 'Branch selection probe timed out'}
    Assert ($child.ExitCode -eq 1 -and (Test-Path -LiteralPath (Join-Path $selectionLogs 'git-root.stderr.log'))) 'Branch query retains Git stderr before a build run exists'
    & (Join-Path $toolRoot 'scripts/New-BuildFailureReport.ps1') -BuildRoot $selectionRoot -SourceRepository $source -BuildMode Release -Version 'selection-case' | Out-Null
    $selectionReport=[IO.File]::ReadAllText((Join-Path $selectionRoot 'failure-report.log'))
    Assert ($selectionReport.Contains('not a git repository') -and $selectionReport.Contains('git-root.process.json') -and $selectionReport.Contains('Release')) 'Branch-selection report contains underlying Git diagnosis and build mode'
} finally {$child.Dispose()}
$missingGitRoot=Join-Path $TestRoot 'branch missing Git'
$missingGitLogs=Join-Path $missingGitRoot 'selection-logs'
$child=New-Object Diagnostics.Process
$child.StartInfo.FileName=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$child.StartInfo.UseShellExecute=$false
$child.StartInfo.CreateNoWindow=$true
$child.StartInfo.RedirectStandardOutput=$true
$child.StartInfo.RedirectStandardError=$true
$child.StartInfo.EnvironmentVariables['PATH']=(Join-Path $env:SystemRoot 'System32')+';'+$env:SystemRoot
$argsList=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $toolRoot 'scripts/Get-Branches.ps1'),'-SourceRepository',$source,'-LogDirectory',$missingGitLogs)
$child.StartInfo.Arguments=($argsList|ForEach-Object {ConvertTo-NativeArgument $_}) -join ' '
try {
    $null=$child.Start();$out=$child.StandardOutput.ReadToEndAsync();$err=$child.StandardError.ReadToEndAsync()
    if(-not $child.WaitForExit(20000)) {$child.Kill();throw 'Missing Git probe timed out'}
    Assert ($child.ExitCode -eq 1 -and (Test-Path -LiteralPath (Join-Path $missingGitLogs 'branch-selection-error.log'))) 'Branch query records a launch exception even without Git stderr'
    & (Join-Path $toolRoot 'scripts/New-BuildFailureReport.ps1') -BuildRoot $missingGitRoot -SourceRepository $source | Out-Null
    $missingGitReport=[IO.File]::ReadAllText((Join-Path $missingGitRoot 'failure-report.log'))
    Assert ($missingGitReport.Contains('git.exe') -and $missingGitReport.Contains('Get-Command') -and $missingGitReport.Contains('Stack:')) 'Single branch report contains missing-executable diagnosis and caught stack'
} finally {$child.Dispose()}
$startupPackage=Join-Path $TestRoot 'startup package'
[IO.Directory]::CreateDirectory((Join-Path $startupPackage 'scripts'))|Out-Null
foreach($name in @('Start-Portable.ps1','Portable-Helpers.ps1','Failure-Report.ps1','Build-Common.ps1')) {
    Copy-Item -LiteralPath (Join-Path $toolRoot ('scripts/'+$name)) -Destination (Join-Path $startupPackage ('scripts/'+$name))
}
Write-Utf8 (Join-Path $startupPackage 'portable-manifest.json') '{"schemaVersion":1,"runtime":{"java":"runtime/java/bin/java.exe","git":"runtime/git/cmd/git.exe","godot":"runtime/godot/godot.exe","war":"runtime/jenkins/jenkins.war","templates":"runtime/templates/4.7.2.stable"},"files":[]}'
$child=New-Object Diagnostics.Process
$child.StartInfo.FileName=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$child.StartInfo.UseShellExecute=$false
$child.StartInfo.CreateNoWindow=$true
$child.StartInfo.RedirectStandardOutput=$true
$child.StartInfo.RedirectStandardError=$true
$argsList=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $startupPackage 'scripts/Start-Portable.ps1'),'-SourceRepository',$source,'-NoBrowser','-NonInteractive')
$child.StartInfo.Arguments=($argsList|ForEach-Object {ConvertTo-NativeArgument $_}) -join ' '
try {
    $null=$child.Start();$out=$child.StandardOutput.ReadToEndAsync();$err=$child.StandardError.ReadToEndAsync()
    if(-not $child.WaitForExit(20000)) {$child.Kill();throw 'Startup failure probe timed out'}
    Assert ($child.ExitCode -eq 1 -and (Test-Path -LiteralPath (Join-Path $startupPackage 'runtime/failure-report.log'))) 'Real portable startup creates one report while preserving failure exit code'
    Assert ([IO.File]::ReadAllText((Join-Path $startupPackage 'runtime/failure-report.log')).Contains('Bundled dependency missing: java')) 'Startup report names the missing runtime dependency'
} finally {$child.Dispose()}
Write-Host "Failure report tests passed: $script:passed"
