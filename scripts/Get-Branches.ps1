[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SourceRepository,[string]$LogDirectory)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Build-Common.ps1')
$selectionLogs=$null
try {
    $repo = Get-SafeFullPath $SourceRepository
    $rootLog=$null; $branchesLog=$null
    if ($LogDirectory) {
        $logs=Get-SafeFullPath $LogDirectory
        Assert-SeparatePaths $repo $logs
        [IO.Directory]::CreateDirectory($logs)|Out-Null
        $selectionLogs=$logs
        $rootLog=Join-Path $logs 'git-root'
        $branchesLog=Join-Path $logs 'git-branches'
    }
    $root = Invoke-ReadGit $repo @('rev-parse','--show-toplevel') $rootLog
    if (-not $repo.Equals((Get-SafeFullPath $root), [StringComparison]::OrdinalIgnoreCase)) { throw 'SourceRepository must be the repository root.' }
    Invoke-ReadGit $repo @('for-each-ref','--format=%(refname:strip=2)','refs/heads/') $branchesLog
    exit 0
} catch {
    $branchFailure=$_
    if ($selectionLogs) {
        try { Write-Utf8 (Join-Path $selectionLogs 'branch-selection-error.log') ("Error: $($branchFailure.Exception.Message)`nInvocation:`n$($branchFailure.InvocationInfo.PositionMessage)`nStack:`n$($branchFailure.ScriptStackTrace)") }
        catch { Write-Warning 'Could not retain branch-selection exception details.' }
    }
    Write-Error $branchFailure -ErrorAction Continue
    exit 1
}
