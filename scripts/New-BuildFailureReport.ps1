[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$BuildRoot,
      [Parameter(Mandatory=$true)][string]$SourceRepository,
      [string]$BranchName,[string]$BuildMode,[string]$Version,[string]$BuildNumber,
      [string]$Result='FAILURE',[string]$PipelineMessage,
      [string]$RunRecordPath,[string]$ExpectedBuildRoot)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Build-Common.ps1')
. (Join-Path $PSScriptRoot 'Failure-Report.ps1')
. (Join-Path $PSScriptRoot 'Build-Workspace.ps1')
$root=Get-SafeFullPath $BuildRoot
$source=Get-SafeFullPath $SourceRepository
Assert-SeparatePaths $source $root
$context=@{operation='Windows build';sourceRepository=$source;branch=$BranchName;mode=$BuildMode;version=$Version;buildNumber=$BuildNumber;result=$Result}
$report=Get-SafeFullPath (Join-Path $root 'failure-report.log')
$runs=@()
if (Test-Path -LiteralPath $root -PathType Container) {
    $runs=@(Get-ChildItem -LiteralPath $root -Directory | Sort-Object LastWriteTimeUtc -Descending)
}
$run=$null
if ($RunRecordPath) {
    if (-not $ExpectedBuildRoot) { throw 'ExpectedBuildRoot is required for a Jenkins run record.' }
    $selected=Read-BuildRunRecord $RunRecordPath $ExpectedBuildRoot $root $source $BuildNumber
    if ($selected) {
        if ($selected.runDirectory) { $run=$selected.runDirectory }
        else {
            $earlyReport=Get-SafeFullPath (Join-Path (Get-SafeFullPath $ExpectedBuildRoot) 'failure-report.log')
            if (Test-Path -LiteralPath $earlyReport -PathType Leaf) { [IO.File]::Copy($earlyReport,$report,$true); Write-Output $report; exit 0 }
        }
    }
} else { foreach ($candidate in $runs) {
    $safeRun=Get-SafeFullPath $candidate.FullName
    if (Test-Path -LiteralPath (Join-Path $safeRun 'logs') -PathType Container) { $run=$safeRun; break }
} }
if ($run) {
    $existing=Get-SafeFullPath (Join-Path $run 'failure-report.log')
    if (Test-Path -LiteralPath $existing -PathType Leaf) {
        # Retain the original caught ErrorRecord/stack from the build process.
        [IO.File]::Copy($existing,$report,$true)
        Write-Output $report
        exit 0
    }
    $message="Jenkins pipeline ended with $Result. See process logs below."
    $record=Get-SafeFullPath (Join-Path $run 'failure.json')
    if (Test-Path -LiteralPath $record -PathType Leaf) {
        try { $failure=[IO.File]::ReadAllText($record)|ConvertFrom-Json; $message=$failure.message }
        catch { $message+=' Original failure.json could not be read.' }
    }
    $context.runDirectory=$run
    Write-FailureReport -ReportPath $report -Message $message -Context $context -LogsDirectory (Join-Path $run 'logs')
} else {
    if (Test-Path -LiteralPath $report -PathType Leaf) {
        Write-Output $report
        exit 0
    }
    $message="Jenkins pipeline ended with $Result before a build run was created. See this build's console output for the failing preflight or branch-selection step."
    if ($PipelineMessage) { $message+="`nPipeline error: $PipelineMessage" }
    Write-FailureReport -ReportPath $report -Message $message -Context $context -LogsDirectory (Join-Path $root 'selection-logs')
}
exit 0
