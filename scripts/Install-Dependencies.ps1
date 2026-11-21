[CmdletBinding()]
param(
    [string]$BuildHome,
    [string]$JavaRoot = 'E:/Code/Java',
    [string]$SourceRepository = 'E:/workspace/faf-game',
    [string]$GodotPath = $(if ($env:GODOT_BIN) { $env:GODOT_BIN } else { 'E:/Game/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe' })
)
$ErrorActionPreference = 'Stop'
if (-not $BuildHome) { $BuildHome = Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'Build-Common.ps1')
. (Join-Path $PSScriptRoot 'Dependency-Helpers.ps1')
. (Join-Path $PSScriptRoot 'Package-Helpers.ps1')
$recordPath = $null
try {
    $source = Get-SafeFullPath $SourceRepository
    $build = Get-SafeFullPath $BuildHome
    $java = Get-SafeFullPath $JavaRoot
    Assert-SeparatePaths $source $build
    Assert-SeparatePaths $source $java
    # Validate all existing ancestors and final destinations before the first write.
    $downloads = Get-SafeFullPath (Join-Path $build 'runtime/downloads')
    $logs = Get-SafeFullPath (Join-Path $build ('logs/dependencies-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')))
    $javaHome = Get-SafeFullPath (Join-Path $java 'zulu21.54.109-ca-jre21.0.13.0.3-win_x64')
    $javaExe = Get-SafeFullPath (Join-Path $javaHome 'bin/java.exe')
    $templateDirectory = Get-SafeFullPath (Join-Path $build 'runtime/templates/4.7.2.stable')
    foreach ($name in Get-WindowsTemplateFiles) {
        $null = Get-SafeFullPath (Join-Path $templateDirectory $name)
    }
    foreach ($name in @('zulu-jre21.zip','jenkins-2.580.2.war','godot-4.7.2-templates.tpz')) {
        $null = Get-SafeFullPath (Join-Path $downloads $name)
    }
    $recordPath = Get-SafeFullPath (Join-Path $build 'runtime/dependencies.json')
    # Only these trees receive extracted/copied contents. Unrelated test fixtures
    # may contain deliberate junctions and are never traversed by this installer.
    foreach ($tree in @($javaHome,$templateDirectory,$logs)) {
        if (Test-Path -LiteralPath $tree) { Assert-NoReparseTree $tree }
    }
    $localTemplates = Find-LocalWindowsTemplates -GodotPath $GodotPath
    foreach ($path in @($downloads,$logs,$java)) { [IO.Directory]::CreateDirectory($path) | Out-Null }
    $curl = (Get-Command curl.exe -ErrorAction Stop).Source
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $packages = @(
        @{ name='zulu-jre21.zip'; url='https://cdn.azul.com/zulu/bin/zulu21.54.109-ca-jre21.0.13.0.3-win_x64.zip'; sha256='3a01d4e2eaab87bee5fdccae051fc3dc2c4dd655c04b942aa8ff7a74aab314c4' },
        @{ name='jenkins-2.580.2.war'; url='https://mirror.twds.com.tw/jenkins/war-stable/2.580.2/jenkins.war'; fallbackUrl='https://updates.jenkins.io/download/war/2.580.2/jenkins.war'; sha256=([BitConverter]::ToString([Convert]::FromBase64String('2YAy0kAcVAo1YTqC7TWJIfzzFm1ebqqvYKeUGEW+MlE=')).Replace('-','').ToLowerInvariant()) }
    )
    if (-not $localTemplates) {
        $packages += @{ name='godot-4.7.2-templates.tpz'; url='https://github.com/godotengine/godot-builds/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz'; sha256='f298490b8d44d934be425a5a65a51bf15f422428b229a06a6e11d9ffea248011' }
    }
    $failures = New-Object 'System.Collections.Generic.List[string]'
    $verified = @{}
    foreach ($package in $packages) {
        $destination = Join-Path $downloads $package.name
        $partial = $destination + '.' + [guid]::NewGuid().ToString('N') + '.partial'
        try {
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ine $package.sha256) {
                Write-Host "[download] $($package.name)"
                # Bound both stalled connections and stalled body transfers. A verified
                # existing archive is reused; a partial file is never treated as installed.
                $downloaded = $false
                $urls = @($package.url)
                if ($package.ContainsKey('fallbackUrl')) { $urls += $package.fallbackUrl }
                foreach ($url in $urls) {
                    try {
                        $null = Invoke-BuildProcess -FilePath $curl -Arguments @('--fail','--location','--silent','--show-error','--connect-timeout','20','--max-time','1800','--speed-limit','1024','--speed-time','30','--output',$partial,$url) -WorkingDirectory $downloads -TimeoutSeconds 1810 -LogPrefix (Join-Path $logs ($package.name + '-' + $urls.IndexOf($url)))
                        if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine $package.sha256) { throw "SHA256 mismatch for $($package.name)." }
                        $downloaded = $true
                        break
                    } catch {
                        if ($url -eq $urls[-1]) { throw }
                    }
                }
                if (-not $downloaded) { throw "Download failed: $($package.name)" }
                Move-Item -LiteralPath $partial -Destination $destination -Force
            }
            $verified[$package.name] = $destination
            Write-Host "[verified] $($package.name)"
        } catch {
            $failures.Add($package.name + ': ' + $_.Exception.Message)
            Write-Host "[failed] $($failures[$failures.Count - 1])"
        }
    }
    if ($verified.ContainsKey('zulu-jre21.zip')) {
        if (-not (Test-Path -LiteralPath $javaHome)) {
            [IO.Compression.ZipFile]::ExtractToDirectory($verified['zulu-jre21.zip'],$java)
        }
        if (-not (Test-Path -LiteralPath $javaExe -PathType Leaf)) { throw "Java installation incomplete: $javaExe. Existing directories were not replaced." }
        $null = Invoke-BuildProcess -FilePath $javaExe -Arguments @('-version') -WorkingDirectory $build -LogPrefix (Join-Path $logs 'java-version') -TimeoutSeconds 20 -Environment (New-GodotEnvironment $logs) -RemoveEnvironment @('JAVA_TOOL_OPTIONS','JDK_JAVA_OPTIONS','_JAVA_OPTIONS')
        Assert-PinnedJavaVersion ([IO.File]::ReadAllText((Join-Path $logs 'java-version.stdout.log')) + [IO.File]::ReadAllText((Join-Path $logs 'java-version.stderr.log')))
    }
    $templateRecord = $null
    if ($localTemplates) {
        $templateRecord = Install-LocalWindowsTemplates -SourceDirectory $localTemplates -Destination $templateDirectory -RunDirectory (Join-Path $logs 'template-validation')
    } elseif ($verified.ContainsKey('godot-4.7.2-templates.tpz')) {
        $archiveTemplates = Get-SafeFullPath (Join-Path $logs 'archive-templates')
        [IO.Directory]::CreateDirectory($archiveTemplates) | Out-Null
        $archive = [IO.Compression.ZipFile]::OpenRead($verified['godot-4.7.2-templates.tpz'])
        try {
            foreach ($name in Get-WindowsTemplateFiles) {
                $entry = $archive.GetEntry('templates/' + $name)
                if ($null -eq $entry) { throw "Missing official template: $name" }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,(Join-Path $archiveTemplates $name),$false)
            }
        } finally { $archive.Dispose() }
        $templateRecord = Install-LocalWindowsTemplates -SourceDirectory $archiveTemplates -Destination $templateDirectory -RunDirectory (Join-Path $logs 'template-validation') -SourceKind archive
    }
    $record = [ordered]@{
        status=$(if ($failures.Count) { 'incomplete' } else { 'installed' })
        javaHome=$javaHome; jenkinsWar=(Join-Path $downloads 'jenkins-2.580.2.war')
        godotVersion='4.7.2.stable'; templateDirectory=$templateDirectory
        templates=$templateRecord
        java=[ordered]@{ home=$javaHome; version='21.0.13.0.3+1-LTS'; vendor='Zulu21.54+109-CA'; sha256=$(if (Test-Path -LiteralPath $javaExe -PathType Leaf) { (Get-FileHash -LiteralPath $javaExe -Algorithm SHA256).Hash.ToLowerInvariant() }) }
        jenkins=[ordered]@{ version='2.580.2'; war=(Join-Path $downloads 'jenkins-2.580.2.war'); sha256=$(if ($verified.ContainsKey('jenkins-2.580.2.war')) { (Get-FileHash -LiteralPath $verified['jenkins-2.580.2.war'] -Algorithm SHA256).Hash.ToLowerInvariant() }) }
        verifiedPackages=@($verified.Keys); packages=$packages; failures=@($failures); logs=$logs
        checkedUtc=[DateTime]::UtcNow.ToString('o')
    }
    Write-Utf8 $recordPath ($record | ConvertTo-Json -Depth 6)
    if ($failures.Count) { Write-Host "INCOMPLETE: dependency downloads failed. See $logs"; exit 1 }
    Write-Host "INSTALLED: Java in $javaHome; Jenkins and templates in $build/runtime"
    exit 0
} catch {
    $message = $_.Exception.Message
    if ($recordPath -and [IO.Directory]::Exists([IO.Path]::GetDirectoryName($recordPath))) {
        Write-Utf8 $recordPath (([ordered]@{ status='incomplete'; failures=@($message); checkedUtc=[DateTime]::UtcNow.ToString('o') }) | ConvertTo-Json -Depth 3)
    }
    Write-Host "FAILED: $message"
    exit 1
}
