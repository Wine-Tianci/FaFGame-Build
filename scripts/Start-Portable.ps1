[CmdletBinding()]
param(
    [string]$BuildHome,
    [string]$SourceRepository,
    [ValidateRange(0,65535)][int]$Port = 0,
    [ValidateRange(10,900)][int]$StartupTimeoutSeconds = 180,
    [switch]$NoBrowser,
    [switch]$NonInteractive
)
$ErrorActionPreference = 'Stop'
if (-not $BuildHome) { $BuildHome = Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'Portable-Helpers.ps1')
. (Join-Path $PSScriptRoot 'Failure-Report.ps1')
$attemptStartedUtc = [DateTime]::UtcNow
$safeRoot = Get-SafeFullPath $BuildHome
$hash = [Security.Cryptography.SHA256]::Create()
try { $mutexKey = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($safeRoot.ToUpperInvariant()))).Replace('-','') } finally { $hash.Dispose() }
$mutex = New-Object Threading.Mutex($false,('Local\FafPortableSetup-' + $mutexKey))
$locked = $false
try {
    try { $locked = $mutex.WaitOne($StartupTimeoutSeconds * 1000) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another portable launcher is still initializing this directory. Retry after it finishes.' }
Write-Host 'Checking bundled files...'
$runtime = Test-PortablePayload $BuildHome
$root = $runtime.root
$marker = Get-SafeFullPath (Join-Path $root 'runtime/portable-ready.json')
$credentialsPath = Get-SafeFullPath (Join-Path $root 'jenkins-home/secrets/faf-portable-admin.json')
$existing = Get-PortableLiveInstance $root
if ($existing) {
    if ($SourceRepository -or ($Port -and $Port -ne $existing.port)) { throw 'Instance already running. Stop it before changing repository or port.' }
    $Port = $existing.port
    Write-Host 'Reusing tracked instance; checking readiness...'
} else {
$configPath = Get-SafeFullPath (Join-Path $root 'portable-config.json')
$config = $null
if (Test-Path -LiteralPath $configPath -PathType Leaf) { $config = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json }
if (-not $SourceRepository -and $config) { $SourceRepository = $config.sourceRepository }
if (-not $SourceRepository) {
    if ($NonInteractive) { throw 'First launch requires SourceRepository.' }
    $SourceRepository = (Read-Host 'Game Git repository full path (contains faf_game and faf_config)').Trim().Trim('"')
}
$source = Get-SafeFullPath $SourceRepository
Assert-SeparatePaths $source $root
if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Source repository not found: $source" }
$oldPath = $env:PATH
try {
    $env:PATH = Get-PortableGitPath $runtime.git
    $repositoryRoot = Invoke-ReadGit $source @('rev-parse','--show-toplevel')
    if ((Get-SafeFullPath $repositoryRoot) -ine $source) { throw 'Select the Git repository root.' }
    foreach ($relative in @('faf_game/project.godot','faf_config')) {
        if (-not (Test-Path -LiteralPath (Join-Path $source $relative))) { throw "Source repository is missing $relative" }
    }
    $explicitPort = $Port -ne 0
    if (-not $Port) { $Port = if ($config) { [int]$config.port } else { 8080 } }
    if ($Port -lt 1 -or $Port -gt 65535) { throw 'Configured port is invalid.' }
    $chosenPort = 0
    for ($candidate = $Port; $candidate -le [Math]::Min(65535,$Port + 20); $candidate++) {
        $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$candidate)
        try { $listener.Server.ExclusiveAddressUse=$true; $listener.Start(); $chosenPort=$candidate; break }
        catch { if ($explicitPort) { throw "Local port $Port is already occupied." } }
        finally { $listener.Stop() }
    }
    if (-not $chosenPort) { throw 'No free local port. Pass a different Port.' }
    $Port = $chosenPort
    Write-Utf8 $configPath (([ordered]@{ schemaVersion=1; sourceRepository=$source; port=$Port }) | ConvertTo-Json)
    $jenkinsHome = Get-SafeFullPath (Join-Path $root 'jenkins-home')
    $jenkinsConfig = Get-SafeFullPath (Join-Path $jenkinsHome 'config.xml')
    $ownerMarker = Get-SafeFullPath (Join-Path $jenkinsHome '.faf-portable-home')
    $seedMarker = Get-SafeFullPath (Join-Path $jenkinsHome '.faf-portable-plugins-seeded')
    if ((Test-Path -LiteralPath $jenkinsConfig) -and -not (Test-Path -LiteralPath $ownerMarker)) { throw 'Jenkins home was not created by this portable launcher.' }
    if (-not (Test-Path -LiteralPath $jenkinsConfig -PathType Leaf)) {
        foreach ($relative in @('users','jobs','secrets/master.key')) {
            if (Test-Path -LiteralPath (Join-Path $jenkinsHome $relative)) { throw 'Refusing to provision an existing non-portable Jenkins home.' }
        }
        [IO.Directory]::CreateDirectory($jenkinsHome) | Out-Null
        Write-Utf8 $ownerMarker '1'
        # Start with authentication enabled even if bootstrap/plugin loading fails.
        Write-Utf8 $jenkinsConfig @'
<?xml version='1.0' encoding='UTF-8'?>
<hudson>
  <numExecutors>1</numExecutors><mode>NORMAL</mode><useSecurity>true</useSecurity>
  <authorizationStrategy class="hudson.security.FullControlOnceLoggedInAuthorizationStrategy"><denyAnonymousReadAccess>true</denyAnonymousReadAccess></authorizationStrategy>
  <securityRealm class="hudson.security.HudsonPrivateSecurityRealm"><disableSignup>true</disableSignup><enableCaptcha>false</enableCaptcha></securityRealm>
  <crumbIssuer class="hudson.security.csrf.DefaultCrumbIssuer"><excludeClientIPFromCrumb>true</excludeClientIPFromCrumb></crumbIssuer>
  <disableRememberMe>false</disableRememberMe>
</hudson>
'@
    }
    # config.xml alone does not prove plugin seeding finished. Retry incomplete
    # first-launch copies; completed homes retain their later plugin changes.
    if (-not (Test-Path -LiteralPath $seedMarker -PathType Leaf)) {
        $pluginTarget = Get-SafeFullPath (Join-Path $jenkinsHome 'plugins')
        [IO.Directory]::CreateDirectory($pluginTarget) | Out-Null
        foreach ($plugin in Get-ChildItem -LiteralPath (Join-Path $root 'runtime/jenkins/plugins') -Filter '*.jpi' -File) {
            Copy-Item -LiteralPath $plugin.FullName -Destination (Join-Path $pluginTarget $plugin.Name) -Force
        }
        Write-Utf8 $seedMarker '1'
    }
    $initDirectory = Get-SafeFullPath (Join-Path $jenkinsHome 'init.groovy.d')
    [IO.Directory]::CreateDirectory($initDirectory) | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'portable/bootstrap.groovy') -Destination (Join-Path $initDirectory 'faf-portable.groovy') -Force
    $secretsDirectory = Get-SafeFullPath (Join-Path $jenkinsHome 'secrets')
    [IO.Directory]::CreateDirectory($secretsDirectory) | Out-Null
    $credentialsPath = Get-SafeFullPath (Join-Path $secretsDirectory 'faf-portable-admin.json')
    if (-not (Test-Path -LiteralPath $credentialsPath)) { Write-PortableSecret $credentialsPath '{}' }
    # A marker belongs to this startup, not to a previous successful run.
    if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker }
    & (Join-Path $PSScriptRoot 'Start-Jenkins.ps1') -BuildHome $root -JavaPath $runtime.java -WarPath $runtime.war -SourceRepository $source -GodotPath $runtime.godot -TemplateDirectory $runtime.templates -Port $Port -SkipSetupWizard
} finally { $env:PATH = $oldPath }
}
$baseUrl = "http://127.0.0.1:$Port"
Write-Host 'Waiting for Jenkins first-start setup...'
$deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
$ready = $false
while ([DateTime]::UtcNow -lt $deadline) {
    $state = Get-PortableLiveInstance $root
    if (-not $state) { throw 'Jenkins exited before becoming ready. See runtime/logs.' }
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        try {
            $response = Invoke-WebRequest -Uri ($baseUrl + '/login') -UseBasicParsing -TimeoutSec 3
            if ($response.StatusCode -eq 200) { $ready=$true; break }
        } catch { }
    }
    Start-Sleep -Milliseconds 1000
}
if (-not $ready) { throw 'Jenkins startup timed out. Process is still tracked; see runtime/logs or use Stop.cmd.' }
Write-Host "Ready: $baseUrl/job/faf-windows/"
Write-Host 'Login user: admin'
Write-Host "Initial password is in: $credentialsPath (password field). Change it in Jenkins after login."
if (-not $NoBrowser) { Start-Process ($baseUrl + '/job/faf-windows/') }
} catch {
    $startupFailure = $_
    try {
        $report = Write-StartupFailureReport -BuildHome $safeRoot -FailureRecord $startupFailure -StartedUtc $attemptStartedUtc -Context @{sourceRepository=$SourceRepository;port=$Port}
        Write-Host "Failure report: $report"
    } catch { Write-Warning "Could not write startup failure report: $($_.Exception.Message)" }
    throw $startupFailure
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
