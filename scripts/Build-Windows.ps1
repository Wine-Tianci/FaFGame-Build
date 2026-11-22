[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SourceRepository,
    [Parameter(Mandatory=$true)][string]$BranchName,
    [Parameter(Mandatory=$true)][string]$GodotPath,
    [string]$BuildRoot,
    [string]$BuildMode = 'Release',
    [string]$Version,
    [string]$BuildNumber = (Get-Date -Format 'yyyyMMddHHmmss'),
    [switch]$RunTests,
    [switch]$KeepStaging,
    [int]$TimeoutSeconds = 120,
    [string]$ExportTemplate,
    [string]$RunRecordPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Build-Common.ps1')
. (Join-Path $PSScriptRoot 'Package-Helpers.ps1')
. (Join-Path $PSScriptRoot 'Failure-Report.ps1')
. (Join-Path $PSScriptRoot 'Build-Workspace.ps1')
. (Join-Path $PSScriptRoot 'Basic-Game-Flow.ps1')
$toolRoot = Split-Path $PSScriptRoot -Parent
$originalAppData = $env:APPDATA
$run = $null; $staging = $null; $zipPath = $null; $artifactManifest = $null
$output = $null; $repo = $null; $sha = $null
$recordPath = $null; $runRecord = $null
try {
    $repo = Get-SafeFullPath $SourceRepository
    if (-not $BuildRoot) { $BuildRoot = Join-Path $toolRoot 'faf-work' }
    $output = Get-SafeFullPath $BuildRoot
    Assert-SeparatePaths $repo $output
    if ($RunRecordPath) {
        $recordPath = Get-SafeFullPath $RunRecordPath
        $recordDirectory = Get-SafeFullPath (Split-Path $recordPath -Parent)
        Assert-SeparatePaths $repo $recordDirectory
        Assert-SeparatePaths $output $recordDirectory
        if ((Split-Path $recordPath -Leaf) -ine 'run.json') { throw 'RunRecordPath must name run.json.' }
        if (Test-Path -LiteralPath $recordPath) { throw 'Run record already exists; refusing to overwrite an earlier build.' }
        [IO.Directory]::CreateDirectory($recordDirectory) | Out-Null
        $runRecord = [ordered]@{ schemaVersion=1; buildRoot=$output; runDirectory=$null; runId=$null; sourceRepository=$repo; buildNumber=$BuildNumber; archiveDirectory=$recordDirectory; status='preflight' }
        Write-Utf8 $recordPath ($runRecord | ConvertTo-Json -Depth 5)
    }
    if (-not (Test-Path -LiteralPath $repo -PathType Container)) { throw "Source repository not found: $repo" }
    $actualRoot = Get-SafeFullPath (Invoke-ReadGit $repo @('rev-parse','--show-toplevel'))
    if (-not $repo.Equals($actualRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'SourceRepository must be the Git repository root.' }
    $run = New-CompactBuildRunDirectory $output
    $runId = Split-Path $run -Leaf
    if ($runRecord) {
        $runRecord.runDirectory=$run; $runRecord.runId=$runId; $runRecord.status='running'
        Write-Utf8 $recordPath ($runRecord | ConvertTo-Json -Depth 5)
    }
    foreach ($directory in @('logs','source','artifacts')) { [IO.Directory]::CreateDirectory((Join-Path $run $directory)) | Out-Null }
    if ($BuildMode -cnotin @('Debug','Release')) { throw 'BuildMode must be Debug or Release.' }
    if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 86400) { throw 'TimeoutSeconds must be between 1 and 86400.' }
    if ([string]::IsNullOrWhiteSpace($BuildNumber)) { throw 'BuildNumber must not be empty.' }
    if ([string]::IsNullOrWhiteSpace($BranchName) -or $BranchName.StartsWith('-') -or $BranchName.StartsWith('refs/')) { throw 'BranchName must be a local branch name, not an option or ref expression.' }
    $null = Invoke-ReadGit $repo @('check-ref-format', ('refs/heads/' + $BranchName)) (Join-Path $run 'logs/git-branch-format') $TimeoutSeconds
    $localRefs = Invoke-ReadGit $repo @('for-each-ref','--format=%(refname)','refs/heads/') (Join-Path $run 'logs/git-local-refs') $TimeoutSeconds
    $exactRef = $false
    foreach ($localRef in ($localRefs -split "`r?`n")) {
        if ([StringComparer]::Ordinal.Equals($localRef, ('refs/heads/' + $BranchName))) { $exactRef = $true; break }
    }
    if (-not $exactRef) { throw "Exact local branch not found: $BranchName" }
    $sha = Invoke-ReadGit $repo @('rev-parse','--verify','--end-of-options', ('refs/heads/' + $BranchName + '^{commit}')) (Join-Path $run 'logs/git-resolve') $TimeoutSeconds
    if ($sha -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') { throw 'Git returned an invalid full commit SHA.' }
    $shortSha = $sha.Substring(0,12)
    if (-not $Version) { $Version = "$BranchName-$shortSha-$BuildNumber" }
    $safeVersion = ($Version -replace '[^A-Za-z0-9._-]', '_').Trim('.','_','-')
    if (-not $safeVersion) { $safeVersion = 'build' }
    if ($safeVersion.Length -gt 100) { $safeVersion = $safeVersion.Substring(0,100) }
    $packageName = "faf-$safeVersion-$($BuildMode.ToLowerInvariant())"
    $GodotPath = Get-SafeFullPath $GodotPath
    if (-not (Test-Path -LiteralPath $GodotPath -PathType Leaf)) { throw "Godot executable not found: $GodotPath" }
    $originalGodotPath = $GodotPath
    $GodotPath = Get-IsolatedEnginePath $originalGodotPath $run
    $engineVersion = Invoke-IsolatedGodot -GodotPath $GodotPath -Arguments @('--version') -WorkingDirectory $run -Name 'engine-version' -RunDirectory $run -TimeoutSeconds $TimeoutSeconds
    $engineVersionKey = Get-GodotVersionKey $engineVersion
    if (-not $ExportTemplate) {
        $ExportTemplate = Join-Path $originalAppData ("Godot/export_templates/$engineVersionKey/windows_$($BuildMode.ToLowerInvariant())_x86_64.exe")
    }
    $ExportTemplate = Get-SafeFullPath $ExportTemplate
    if (-not (Test-Path -LiteralPath $ExportTemplate -PathType Leaf) -or (Get-Item -LiteralPath $ExportTemplate).Length -eq 0) { throw "Windows $BuildMode x86_64 export template not found or empty: $ExportTemplate" }
    Assert-WindowsX64Template $ExportTemplate
    $templateRuntime = Get-IsolatedEnginePath $ExportTemplate (Join-Path $run 'template-validation')
    $templateVersionText = Invoke-IsolatedGodot -GodotPath $templateRuntime -Arguments @('--version') -WorkingDirectory $run -Name 'template-version' -RunDirectory $run -TimeoutSeconds $TimeoutSeconds
    if ((Get-GodotVersionKey $templateVersionText) -cne $engineVersionKey) { throw "Template version mismatch: engine=$engineVersion; template=$templateVersionText" }
    $templateHash = (Get-FileHash -LiteralPath $ExportTemplate -Algorithm SHA256).Hash.ToLowerInvariant()
    # Reject symlink and submodule entries before extraction: their targets cannot
    # be guaranteed to stay within this immutable, self-contained snapshot.
    $tree = Invoke-ReadGit $repo @('ls-tree','-r',$sha) (Join-Path $run 'logs/git-tree') $TimeoutSeconds
    if ($tree -match '(?m)^(120000|160000) ') { throw 'Snapshot contains a symbolic link or submodule; self-contained regular files are required.' }
    $archivePath = Join-Path $run 'source.zip'
    $null = Invoke-ReadGit $repo @('archive','--format=zip',('--output=' + $archivePath),$sha) (Join-Path $run 'logs/git-archive') $TimeoutSeconds
    $snapshot = Join-Path $run 'source'
    Expand-GitSnapshot $archivePath $snapshot
    Write-Utf8 (Join-Path $run 'logs/archive-extract.stdout.log') 'Extracted validated Git ZIP snapshot with explicit UTF-8 filename decoding.'
    Assert-NoReparseTree $snapshot
    $project = Join-Path $snapshot 'faf_game'
    if (-not (Test-Path -LiteralPath (Join-Path $project 'project.godot') -PathType Leaf)) { throw 'Snapshot is missing faf_game/project.godot.' }
    $config = Join-Path $snapshot 'faf_config'
    if (-not (Test-Path -LiteralPath $config -PathType Container)) { throw 'Snapshot is missing faf_config.' }
    $csvs = @(Get-ChildItem -LiteralPath $config -Recurse -Filter '*.csv' -File)
    if ($csvs.Count -eq 0 -or @($csvs | Where-Object Length -eq 0).Count -gt 0) { throw 'faf_config must contain nonempty CSV files; empty CSV files are rejected.' }
    $presetPath = Join-Path $project 'export_presets.cfg'
    $presetText = [IO.File]::ReadAllText((Join-Path $toolRoot 'presets/export_presets.cfg'))
    $templateValue = $ExportTemplate.Replace('\','/').Replace('"','\"')
    $presetText = $presetText.Replace(('custom_template/' + $BuildMode.ToLowerInvariant() + '=""'), ('custom_template/' + $BuildMode.ToLowerInvariant() + '="' + $templateValue + '"'))
    Write-Utf8 $presetPath $presetText
    # Check in this scope so no nested PowerShell process is needed.
        $null = & (Join-Path $PSScriptRoot 'Godot-Checks.ps1') -GodotPath $GodotPath -ProjectDirectory $project -RunDirectory $run -TimeoutSeconds $TimeoutSeconds
    $null = Install-BasicGameFlowProbe $project $run
    $staging = Join-Path $run 'staging'
    $package = Join-Path $staging $packageName
    $game = Join-Path $package 'game'
    [IO.Directory]::CreateDirectory($game) | Out-Null
    Copy-Item -LiteralPath $config -Destination (Join-Path $package 'faf_config') -Recurse
    $exe = Join-Path $game 'faf.exe'
    $null = Invoke-GameExport $GodotPath $project $run $BuildMode $exe $TimeoutSeconds
    Assert-NoReparseTree $package
    foreach ($required in @($exe,(Join-Path $game 'faf.pck'))) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf) -or (Get-Item -LiteralPath $required).Length -eq 0) { throw "Export missing or empty: $required" }
    }
    Assert-ExportedLibraries $project $game $BuildMode
    $smokeCwd = Join-Path $run 'smoke-cwd'
    [IO.Directory]::CreateDirectory($smokeCwd) | Out-Null
    $smokeSaveDirectory = Join-Path $game 'saves'
    if (Test-Path -LiteralPath $smokeSaveDirectory) { throw 'Export unexpectedly contains save data before runtime verification.' }
    $null = Invoke-IsolatedGodot -GodotPath $exe -Arguments @('--headless','--','--faf-build-basic-flow',('--faf-flow-timeout=' + [Math]::Max(1,$TimeoutSeconds-5))) -WorkingDirectory $smokeCwd -Name 'basic-game-flow' -RunDirectory $run -TimeoutSeconds $TimeoutSeconds
    # Only remove newly generated verification data after a successful smoke check.
    if (Test-Path -LiteralPath $smokeSaveDirectory) {
        $ownedSavePath = Get-SafeFullPath $smokeSaveDirectory
        $ownedGamePath = Get-SafeFullPath $game
        if (-not (Test-WithinPath $ownedSavePath $ownedGamePath) -or [IO.Path]::GetFileName($ownedSavePath) -ne 'saves') { throw 'Verification save directory escaped the package.' }
        Assert-NoReparseTree $ownedSavePath
        Remove-Item -LiteralPath $ownedSavePath -Recurse -Force
    }
        try { $advisory = & (Join-Path $PSScriptRoot 'Godot-Checks.ps1') -GodotPath $GodotPath -ProjectDirectory $project -RunDirectory $run -TimeoutSeconds $TimeoutSeconds -RunTests:$RunTests -SkipImport }
    catch {
        $advisory=[ordered]@{requested=[bool]$RunTests;total=0;passed=0;failed=1;blocking=$false;setupError=$_.Exception.Message}
        Write-Warning 'Optional suite setup/reporting failed; the basic-flow-verified package will still be produced.'
        try {$null=Write-FailureReport -ReportPath (Join-Path $run 'artifacts/test-report.log') -FailureRecord $_ -Context @{operation='Optional functional test setup';blocking=$false} -LogsDirectory (Join-Path $run 'logs')} catch {Write-Warning 'Optional diagnostics could not be written; see local console output.'}
    }
    $manifest = [ordered]@{
        checks=@{basicFlow='passed';advisory=$advisory}
        schemaVersion=1; sourceRepository=$repo; selectedBranch=$BranchName; fullSha=$sha; shortSha=$shortSha
        buildMode=$BuildMode; buildId=$runId; buildNumber=$BuildNumber; version=$Version; packageName=$packageName
        godotVersion=$engineVersion; godotOriginalPath=$originalGodotPath; godotRuntimePath=$GodotPath
        exportTemplate=$ExportTemplate; exportTemplateVersion=$templateVersionText; exportTemplateSha256=$templateHash
        createdUtc=[DateTime]::UtcNow.ToString('o')
        config=(Get-ConfigInventory (Join-Path $package 'faf_config'))
        presetSha256=(Get-FileHash -LiteralPath $presetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        adapters=@()
    }
    $manifestText = $manifest | ConvertTo-Json -Depth 8
    Write-Utf8 (Join-Path $package 'build-manifest.json') $manifestText
    $artifactManifest = Join-Path $run 'artifacts/build-manifest.json'
    Write-Utf8 $artifactManifest $manifestText
    $zipPath = Join-Path $run ("artifacts/$packageName.zip")
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($package, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $true)
    if (-not $KeepStaging) { Remove-OwnedStaging $staging $run }
    if ($runRecord) { $runRecord.status='success'; Write-Utf8 $recordPath ($runRecord | ConvertTo-Json -Depth 5) }
    Write-Host "SUCCESS: $zipPath"
    exit 0
} catch {
    $failure = $_
    if ($runRecord) {
        try { $runRecord.status='failed'; Write-Utf8 $recordPath ($runRecord | ConvertTo-Json -Depth 5) }
        catch { Write-Warning 'Could not update build run record; original failure is preserved.' }
    }
    if ($run -and (Test-Path -LiteralPath $run)) {
        # A partially written ZIP or a failure during cleanup must never look successful.
        foreach ($partial in @($zipPath,$artifactManifest)) { if ($partial -and (Test-Path -LiteralPath $partial)) { Remove-Item -LiteralPath $partial -Force } }
        try {
            Write-Utf8 (Join-Path $run 'failure.json') (([ordered]@{ status='failed'; message=$failure.Exception.Message; utc=[DateTime]::UtcNow.ToString('o'); sourceRepository=$SourceRepository; branch=$BranchName; logs=(Join-Path $run 'logs') }) | ConvertTo-Json -Depth 5)
            $report = Write-FailureReport -ReportPath (Join-Path $run 'failure-report.log') -FailureRecord $failure -Context @{operation='Windows build';sourceRepository=$SourceRepository;branch=$BranchName;mode=$BuildMode;version=$Version;buildNumber=$BuildNumber;commit=$sha;godot=$GodotPath;template=$ExportTemplate} -LogsDirectory (Join-Path $run 'logs')
            Write-Host "Failure report: $report"
        } catch { Write-Warning "Could not write failure report: $($_.Exception.Message)" }
        Write-Host "FAILED: $($failure.Exception.Message)`nDiagnostics: $run"
    } else {
        Write-Host "FAILED: $($failure.Exception.Message)"
        if ($output -and $repo) {
            try { $report = Write-FailureReport -ReportPath (Join-Path $output 'failure-report.log') -FailureRecord $failure -Context @{operation='Windows build';sourceRepository=$repo;branch=$BranchName;mode=$BuildMode;version=$Version;buildNumber=$BuildNumber}; Write-Host "Failure report: $report" }
            catch { Write-Warning "Could not write failure report: $($_.Exception.Message)" }
        }
    }
    exit 1
}
