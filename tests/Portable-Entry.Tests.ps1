[CmdletBinding()]
param([string]$TestRoot)
$ErrorActionPreference='Stop'
$toolRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $toolRoot 'scripts/Build-Common.ps1')
if(-not $TestRoot) {$TestRoot=Join-Path $toolRoot ('test-results/entry-'+[guid]::NewGuid().ToString('N'))}
$script:passed=0
function Assert($Condition,[string]$Message) {if(-not $Condition){throw "FAIL: $Message"};$script:passed++;Write-Host "PASS: $Message"}
function Run-Cmd([string]$Path) {
    $p=New-Object Diagnostics.Process
    $p.StartInfo.FileName=Join-Path $env:SystemRoot 'System32/cmd.exe'
    $p.StartInfo.Arguments='/d /s /c ""'+$Path+'" -NoBrowser"'
    $p.StartInfo.UseShellExecute=$false
    $p.StartInfo.CreateNoWindow=$true
    $p.StartInfo.RedirectStandardInput=$true
    $p.StartInfo.RedirectStandardOutput=$true
    $p.StartInfo.RedirectStandardError=$true
    try {
        $null=$p.Start();$p.StandardInput.Close()
        $o=$p.StandardOutput.ReadToEndAsync();$e=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit(20000)) {$p.Kill();throw 'Entry probe timed out'}
        return @{code=$p.ExitCode;text=$o.Result+$e.Result}
    } finally {$p.Dispose()}
}
foreach($entry in @('Start','Stop')) {
    $source=Join-Path $TestRoot ('GitHub source/'+$entry+'/portable')
    [IO.Directory]::CreateDirectory($source)|Out-Null
    Copy-Item -LiteralPath (Join-Path $toolRoot ('portable/'+$entry+'.cmd')) -Destination (Join-Path $source ($entry+'.cmd'))
    $result=Run-Cmd (Join-Path $source ($entry+'.cmd'))
    Assert ($result.code -eq 1 -and $result.text.Contains('GitHub source code') -and $result.text.Contains('github.com/Wine-Tianci/FaFGame-Build/releases')) ($entry+' explains source download and provides Releases link')
    Assert (-not $result.text.Contains('Windows PowerShell 5.1')) ($entry+' does not launch PowerShell with a missing script')
    $bundle=Join-Path $TestRoot ('complete package/'+$entry)
    [IO.Directory]::CreateDirectory((Join-Path $bundle 'scripts'))|Out-Null
    Copy-Item -LiteralPath (Join-Path $toolRoot ('portable/'+$entry+'.cmd')) -Destination (Join-Path $bundle ($entry+'.cmd'))
    Write-Utf8 (Join-Path $bundle 'portable-manifest.json') '{}'
    Write-Utf8 (Join-Path $bundle ('scripts/'+$entry+'-Portable.ps1')) 'param([switch]$NoBrowser) Write-Output ("FAF_ENTRY_OK: " + $NoBrowser); exit 7'
    $result=Run-Cmd (Join-Path $bundle ($entry+'.cmd'))
    Assert ($result.text.Contains('FAF_ENTRY_OK: True') -and $result.code -eq 7) ($entry+' resolves bundled script with spaces, forwards arguments and preserves error code')
}
Write-Host "Portable entry tests passed: $script:passed"
