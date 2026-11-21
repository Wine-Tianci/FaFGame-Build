[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$SourceRepository,
    [Parameter(Mandatory=$true)][string]$BuildHome
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Build-Common.ps1')
$homePath = Get-SafeFullPath $BuildHome
$source = Get-SafeFullPath $SourceRepository
$workspacePath = Get-SafeFullPath $Workspace
Assert-SeparatePaths $source $homePath
Assert-SeparatePaths $source $workspacePath
$jenkinsHome = Get-SafeFullPath (Join-Path $homePath 'jenkins-home')
if (-not (Test-WithinPath $workspacePath $jenkinsHome)) {
    throw 'Jenkins Workspace must be within FAF_BUILD_HOME/jenkins-home (normally jenkins-home/workspace).'
}
# No writes: Jenkins itself creates durable-task files before this script executes.
# Initial node/job workspace configuration is therefore also a mandatory boundary.
Write-Output $workspacePath
