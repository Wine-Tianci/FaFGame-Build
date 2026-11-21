[CmdletBinding()]
param([string]$TestRoot)
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path $PSScriptRoot -Parent
$script:passed = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++; Write-Host "PASS: $Message"
}
function Reject([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $_.Exception.Message -match $Pattern }
    Assert $rejected $Message
}
Assert (Test-Path -LiteralPath (Join-Path $toolRoot 'scripts/Portable-Helpers.ps1')) 'Portable runtime helpers exist'
. (Join-Path $toolRoot 'scripts/Portable-Helpers.ps1')
if (-not $TestRoot) { $TestRoot = Join-Path $toolRoot ('test-results/portable-' + [guid]::NewGuid().ToString('N')) }
$package = Join-Path $TestRoot 'original package'
[IO.Directory]::CreateDirectory($package) | Out-Null
$runtime = [ordered]@{ java='runtime/java/bin/java.exe'; git='runtime/git/cmd/git.exe'; godot='runtime/godot/godot.exe'; war='runtime/jenkins/jenkins.war'; templates='runtime/templates/4.7.2.stable' }
foreach ($path in @($runtime.java,$runtime.git,$runtime.godot,$runtime.war,($runtime.templates + '/version.txt'))) {
    $full = Join-Path $package $path
    [IO.Directory]::CreateDirectory((Split-Path $full -Parent)) | Out-Null
    Write-Utf8 $full 'fixture'
}
$manifest = [ordered]@{ schemaVersion=1; runtime=$runtime; files=@(Get-PortableFileRecords $package) }
Write-Utf8 (Join-Path $package 'portable-manifest.json') ($manifest | ConvertTo-Json -Depth 8)
$resolved = Get-PortableRuntime $package
Assert ($resolved.java -eq (Get-SafeFullPath (Join-Path $package $runtime.java))) 'Resolve Java from package root'
Test-PortablePayload $package | Out-Null
Assert $true 'Verify clean payload hashes'
$moved = Join-Path $TestRoot '便携 工具 moved'
Copy-Item -LiteralPath $package -Destination $moved -Recurse
$afterMove = Get-PortableRuntime $moved
Assert ($afterMove.git -eq (Get-SafeFullPath (Join-Path $moved $runtime.git))) 'Relocation resolves Git at new Unicode/spaces root'
Test-PortablePayload $moved | Out-Null
Assert $true 'Relocation preserves manifest verification'
Write-Utf8 (Join-Path $moved $runtime.java) 'tampered'
Reject { Test-PortablePayload $moved } 'hash|Hash' 'Reject altered runtime dependency'
Remove-Item -LiteralPath (Join-Path $moved $runtime.git)
Reject { Get-PortableRuntime $moved } 'missing|Missing|not found' 'Reject missing bundled Git'
$manifest.runtime.java = '../outside.exe'
Write-Utf8 (Join-Path $package 'portable-manifest.json') ($manifest | ConvertTo-Json -Depth 8)
Reject { Get-PortableRuntime $package } 'relative|escape|path' 'Reject manifest directory traversal'
$manifest.runtime.java = $runtime.git
$manifest.runtime.git = 'C:/Windows/not-bundled.exe'
Write-Utf8 (Join-Path $package 'portable-manifest.json') ($manifest | ConvertTo-Json -Depth 8)
Reject { Get-PortableRuntime $package } 'relative|escape|path' 'Reject absolute manifest dependency'
$credential = Join-Path $TestRoot 'local secret'
Write-PortableSecret $credential '{"token":"test-only"}'
$acl = Get-Acl -LiteralPath $credential
Assert $acl.AreAccessRulesProtected 'Local credential file does not inherit broad permissions'
$record = @{ name='fixture'; sha256=[Convert]::ToBase64String([byte[]](1..32)) }
$plugin = Join-Path $TestRoot 'fixture.jpi'
Write-Utf8 $plugin 'wrong'
Reject { Assert-PortablePluginHash $plugin $record } 'hash|Hash' 'Reject plugin that differs from trusted lock'
$existing = Join-Path $TestRoot 'existing release'
[IO.Directory]::CreateDirectory($existing) | Out-Null
Reject { & (Join-Path $toolRoot 'scripts/New-PortablePackage.ps1') -DestinationPath $existing } 'exist|fresh' 'Never overwrite or reuse release destination'
Assert (-not (Test-Path -LiteralPath (Join-Path $existing 'runtime'))) 'Rejected release destination is unchanged'
Assert (Test-Path -LiteralPath (Join-Path $toolRoot 'scripts/Start-Portable.ps1')) 'Double-click portable launcher exists'
Assert (Test-Path -LiteralPath (Join-Path $toolRoot 'scripts/Stop-Portable.ps1')) 'Graceful portable stop exists'
Assert ($null -eq (Get-PortableLiveInstance $moved)) 'Fresh package has no live instance'
$lockHome = Join-Path $TestRoot 'lock home'
[IO.Directory]::CreateDirectory((Join-Path $lockHome 'runtime')) | Out-Null
Write-Utf8 (Join-Path $lockHome 'runtime/jenkins-plugin-lock.json') '[{"name":"first"},{"name":"second"}]'
Write-Utf8 (Join-Path $lockHome 'runtime/jenkins-language-plugin-lock.json') '[{"name":"third"}]'
Assert ((Get-Command Get-PortablePluginLocks -ErrorAction SilentlyContinue) -ne $null) 'Plugin lock loader exists'
$records = @(Get-PortablePluginLocks $lockHome)
Assert ($records.Count -eq 3 -and $records[1].name -eq 'second') 'PowerShell 5.1 flattens both plugin lock arrays'
Assert ((Get-Command Assert-PortableDestination -ErrorAction SilentlyContinue) -ne $null) 'Release overlap guard exists'
Reject { Assert-PortableDestination $toolRoot (Join-Path $toolRoot 'scripts/recursive release') } 'overlap' 'Reject release nested within copied scripts'
Reject { Assert-PortableDestination $toolRoot (Join-Path $toolRoot 'presets/recursive release') } 'overlap' 'Reject release nested within copied presets'
Assert-PortableDestination $toolRoot (Join-Path $toolRoot 'dist/fresh release')
Assert $true 'Allow release under independent dist directory'
Write-Host "Portable tests passed: $script:passed"
