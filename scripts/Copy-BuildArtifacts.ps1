[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$BuildHome,
      [Parameter(Mandatory=$true)][string]$Workspace,
      [Parameter(Mandatory=$true)][string]$BuildNumber,
      [Parameter(Mandatory=$true)][string]$SourceRepository)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Build-Workspace.ps1')
$layout=Get-BuildWorkspaceLayout $BuildHome $Workspace $BuildNumber $SourceRepository
$record=Read-BuildRunRecord $layout.runRecord $layout.dataRoot $layout.archiveRoot $layout.source $BuildNumber
if(-not $record -or $record.status -ne 'success' -or -not $record.runDirectory) {throw 'No successful current build run is available for artifact copy.'}
$artifacts=Get-SafeFullPath (Join-Path $record.runDirectory 'artifacts')
Assert-NoReparseTree $artifacts
$zips=@(Get-ChildItem -LiteralPath $artifacts -Filter '*.zip' -File)
$manifest=Get-SafeFullPath (Join-Path $artifacts 'build-manifest.json')
if($zips.Count -ne 1 -or $zips[0].Length -eq 0 -or -not (Test-Path -LiteralPath $manifest -PathType Leaf) -or (Get-Item -LiteralPath $manifest).Length -eq 0) {throw 'Current build must provide exactly one nonempty ZIP and its manifest.'}
$destination=Get-SafeFullPath (Join-Path $layout.archiveRoot 'artifacts')
[IO.Directory]::CreateDirectory($destination)|Out-Null
foreach($file in @($zips[0].FullName,$manifest)) {
    $target=Get-SafeFullPath (Join-Path $destination ([IO.Path]::GetFileName($file)))
    Copy-Item -LiteralPath $file -Destination $target -Force
    if((Get-FileHash -LiteralPath $file).Hash -ne (Get-FileHash -LiteralPath $target).Hash) {throw 'Copied artifact checksum differs from its source.'}
}
$testReport=Get-SafeFullPath (Join-Path $artifacts 'test-report.log')
if(Test-Path -LiteralPath $testReport -PathType Leaf){Copy-Item -LiteralPath $testReport -Destination (Get-SafeFullPath (Join-Path $destination 'test-report.log')) -Force}
Write-Host "Copied current build deliveries: $destination"
exit 0
