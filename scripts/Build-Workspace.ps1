# Compact scratch directories and validated per-build Jenkins run records.
. (Join-Path $PSScriptRoot 'Build-Common.ps1')
function Get-BuildWorkspaceLayout {
    param([string]$BuildHome,[string]$Workspace,[string]$BuildNumber,[string]$SourceRepository)
    if($BuildNumber -notmatch '^[0-9]+$') {throw 'Invalid build number.'}
    $homePath=Get-SafeFullPath $BuildHome
    $source=Get-SafeFullPath $SourceRepository
    $workspacePath=Get-SafeFullPath $Workspace
    & (Join-Path $PSScriptRoot 'Check-JenkinsWorkspace.ps1') -BuildHome $homePath -Workspace $workspacePath -SourceRepository $source|Out-Null
    $dataRoot=Get-SafeFullPath (Join-Path $homePath ('faf-work/'+$BuildNumber))
    $archiveRoot=Get-SafeFullPath (Join-Path $workspacePath ('builds/'+$BuildNumber))
    Assert-SeparatePaths $source $dataRoot
    Assert-SeparatePaths $dataRoot $archiveRoot
    return @{buildHome=$homePath;source=$source;workspace=$workspacePath;dataRoot=$dataRoot;archiveRoot=$archiveRoot;runRecord=(Get-SafeFullPath (Join-Path $archiveRoot 'run.json'))}
}
function New-CompactBuildRunDirectory([string]$BuildRoot) {
    $root=Get-SafeFullPath $BuildRoot
    [IO.Directory]::CreateDirectory($root)|Out-Null
    for($attempt=0;$attempt -lt 5;$attempt++) {
        $run=Get-SafeFullPath (Join-Path $root ([guid]::NewGuid().ToString('N').Substring(0,16)))
        if(Test-Path -LiteralPath $run) {continue}
        New-Item -ItemType Directory -Path $run -ErrorAction Stop|Out-Null
        return $run
    }
    throw 'Could not allocate a fresh compact build run.'
}
function Read-BuildRunRecord {
    param([string]$RecordPath,[string]$ExpectedBuildRoot,[string]$ArchiveDirectory,[string]$SourceRepository,[string]$BuildNumber)
    $path=Get-SafeFullPath $RecordPath
    $archive=Get-SafeFullPath $ArchiveDirectory
    $expected=Get-SafeFullPath $ExpectedBuildRoot
    $source=Get-SafeFullPath $SourceRepository
    Assert-SeparatePaths $source $expected
    Assert-SeparatePaths $source $archive
    Assert-SeparatePaths $expected $archive
    if((Split-Path $path -Parent) -ine $archive -or (Split-Path $path -Leaf) -ine 'run.json') {throw 'Run record archive ownership mismatch.'}
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)) {return $null}
    $record=[IO.File]::ReadAllText($path)|ConvertFrom-Json
    foreach($name in @('schemaVersion','buildRoot','runDirectory','runId','sourceRepository','buildNumber','archiveDirectory','status')) {
        if(-not $record.PSObject.Properties[$name]) {throw ('Run record missing field: '+$name)}
    }
    if($record.schemaVersion -ne 1 -or $record.status -notin @('preflight','running','success','failed')) {throw 'Unsupported run record schema or status.'}
    foreach($name in @('buildRoot','sourceRepository','archiveDirectory')) {
        if($record.$name -isnot [string] -or -not [IO.Path]::IsPathRooted($record.$name)) {throw 'Run record paths must be absolute strings.'}
    }
    if((Get-SafeFullPath $record.buildRoot) -ine $expected -or [string]$record.buildNumber -cne $BuildNumber -or
       (Get-SafeFullPath $record.sourceRepository) -ine $source -or (Get-SafeFullPath $record.archiveDirectory) -ine $archive) {
        throw 'Run record ownership differs from the current build number, source or archive directory.'
    }
    if($record.runDirectory) {
        if($record.runDirectory -isnot [string] -or -not [IO.Path]::IsPathRooted($record.runDirectory)) {throw 'Run directory must be an absolute string.'}
        $run=Get-SafeFullPath $record.runDirectory
        if((Split-Path $run -Parent) -ine $expected) {throw 'Run record points outside the expected faf-work build root.'}
        if($record.runId -notmatch '^[0-9a-f]{16}$' -or (Split-Path $run -Leaf) -cne $record.runId) {throw 'Run record ID does not match its compact directory.'}
        if(-not (Test-Path -LiteralPath $run -PathType Container)) {throw 'Recorded build run directory is missing.'}
        $record.runDirectory=$run
    } elseif($record.runId -or $record.status -eq 'success') {throw 'Run record has an ID or success status without a run directory.'}
    return $record
}
