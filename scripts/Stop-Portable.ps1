[CmdletBinding()]
param([string]$BuildHome, [ValidateRange(10,86400)][int]$TimeoutSeconds = 3600)
$ErrorActionPreference = 'Stop'
if (-not $BuildHome) { $BuildHome = Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'Portable-Helpers.ps1')
$root = Get-SafeFullPath $BuildHome
$state = Get-PortableLiveInstance $root
if (-not $state) { Write-Host 'Portable Jenkins is stopped.'; return }
$credentialsPath = Get-SafeFullPath (Join-Path $root 'jenkins-home/secrets/faf-portable-admin.json')
$credential = [IO.File]::ReadAllText($credentialsPath) | ConvertFrom-Json
if (-not $credential.user -or -not $credential.token) { throw 'Local shutdown token unavailable. Use authenticated Jenkins safeExit.' }
$pair = $credential.user + ':' + $credential.token
$headers = @{ Authorization='Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair)) }
try {
    Invoke-WebRequest -Uri ("http://127.0.0.1:$($state.port)/safeExit") -Method Post -Headers $headers -UseBasicParsing -TimeoutSec 15 | Out-Null
} catch {
    if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -in @(401,403)) { throw 'Shutdown authentication failed. Check the local admin token.' }
    # safeExit can close its HTTP connection before sending the response.
    if (Get-PortableLiveInstance $root) { throw }
} finally { Remove-Variable pair,headers,credential -ErrorAction SilentlyContinue }
Write-Host 'Safe shutdown requested. Waiting for running builds to finish...'
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
while ([DateTime]::UtcNow -lt $deadline) {
    if (-not (Get-PortableLiveInstance $root)) { Write-Host 'Portable Jenkins stopped.'; return }
    Start-Sleep -Seconds 1
}
throw 'Shutdown still pending; no process was forcibly killed. Wait for running builds and retry.'
