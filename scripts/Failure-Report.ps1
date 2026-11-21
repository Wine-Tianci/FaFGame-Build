# Shared single-file diagnostics. Caller loads Build-Common.ps1 first.
function Protect-FailureReportText([string]$Text, [string[]]$SensitiveValues = @()) {
    foreach ($value in $SensitiveValues) {
        if (-not [string]::IsNullOrWhiteSpace($value)) { $Text=$Text.Replace($value,'[REDACTED]') }
    }
    [regex]::Replace($Text,'(?im)(["'']?Authorization["'']?\s*[:=]\s*)[^\r\n]+','$1[REDACTED]')
}
function Write-FailureReport {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ReportPath,
          [Management.Automation.ErrorRecord]$FailureRecord,
          [string]$Message,
          [hashtable]$Context=@{},
          [string]$LogsDirectory,
          [string[]]$LogFiles=@(),
          [string[]]$SensitiveValues=@())
    $path=Get-SafeFullPath $ReportPath
    $parent=Get-SafeFullPath (Split-Path $path -Parent)
    if ($Context.ContainsKey('sourceRepository') -and $Context.sourceRepository) {
        Assert-SeparatePaths (Get-SafeFullPath $Context.sourceRepository) $parent
    }
    $logs=@()
    if ($LogsDirectory -and (Test-Path -LiteralPath $LogsDirectory -PathType Container)) {
        $logRoot=Get-SafeFullPath $LogsDirectory
        $logs=@(Get-ChildItem -LiteralPath $logRoot -File | Where-Object { $_.Name.EndsWith('.log') -or $_.Name.EndsWith('.process.json') } | Sort-Object LastWriteTimeUtc,Name | Select-Object -ExpandProperty FullName)
    }
    $logs+=@($LogFiles)
    # Canonicalize every selected input before any write. No directory recursion.
    $selected=New-Object 'System.Collections.Generic.List[string]'
    $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $logs) {
        $full=Get-SafeFullPath $file
        if ($full -ieq $path -or -not $seen.Add($full)) { continue }
        if ($full.EndsWith('.log') -or $full.EndsWith('.process.json')) { $selected.Add($full) }
    }
    if ($FailureRecord) { $Message=$FailureRecord.Exception.Message }
    if (-not $Message) { $Message='Build or startup failed. See the complete process logs below.' }
    [IO.Directory]::CreateDirectory($parent)|Out-Null
    $writer=New-Object IO.StreamWriter($path,$false,(New-Object Text.UTF8Encoding($true)))
    try {
        $writer.WriteLine('FAF FAILURE REPORT')
        $writer.WriteLine('Generated UTC: '+[DateTime]::UtcNow.ToString('o'))
        $writer.WriteLine('Error: '+(Protect-FailureReportText $Message $SensitiveValues))
        foreach ($item in $Context.GetEnumerator() | Sort-Object Key) {
            $writer.WriteLine($item.Key+': '+(Protect-FailureReportText ([string]$item.Value) $SensitiveValues))
        }
        if ($FailureRecord) {
            $writer.WriteLine('Exception type: '+$FailureRecord.Exception.GetType().FullName)
            $writer.WriteLine('Error ID: '+$FailureRecord.FullyQualifiedErrorId)
            $writer.WriteLine('Invocation:')
            $writer.WriteLine((Protect-FailureReportText $FailureRecord.InvocationInfo.PositionMessage $SensitiveValues))
            $writer.WriteLine('Stack:')
            $writer.WriteLine((Protect-FailureReportText $FailureRecord.ScriptStackTrace $SensitiveValues))
            if ($FailureRecord.Exception.InnerException) {
                $writer.WriteLine('Inner exception: '+(Protect-FailureReportText $FailureRecord.Exception.InnerException.ToString() $SensitiveValues))
            }
        }
        $writer.WriteLine()
        $writer.WriteLine('COMPLETE PROCESS LOGS')
        if ($selected.Count -eq 0) { $writer.WriteLine('No process logs were created before this failure.') }
        foreach ($file in $selected) {
            $writer.WriteLine()
            $writer.WriteLine('===== '+[IO.Path]::GetFileName($file)+' =====')
            $reader=$null
            try {
                # Shared reading also works while Jenkins is still starting.
                $stream=[IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
                $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
                $line=$reader.ReadLine()
                if ($null -eq $line) { $writer.WriteLine('[empty]') }
                while ($null -ne $line) {
                    $writer.WriteLine((Protect-FailureReportText $line $SensitiveValues))
                    $line=$reader.ReadLine()
                }
            } catch { $writer.WriteLine('[Could not read log: '+(Protect-FailureReportText $_.Exception.Message $SensitiveValues)+']') }
            finally { if ($reader) { $reader.Dispose() } }
        }
    } finally { $writer.Dispose() }
    return $path
}
function Write-StartupFailureReport {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$BuildHome,
          [Parameter(Mandatory=$true)][Management.Automation.ErrorRecord]$FailureRecord,
          [Parameter(Mandatory=$true)][datetime]$StartedUtc,
          [hashtable]$Context=@{})
    $root=Get-SafeFullPath $BuildHome
    $runtime=Get-SafeFullPath (Join-Path $root 'runtime')
    $logRoot=Get-SafeFullPath (Join-Path $runtime 'logs')
    $files=@()
    if (Test-Path -LiteralPath $logRoot -PathType Container) {
        # Select by creation time so a previous attempt's late output is excluded.
        $files=@(Get-ChildItem -LiteralPath $logRoot -File | Where-Object { $_.Name -match '\.(stdout|stderr)\.log$' -and $_.CreationTimeUtc -ge $StartedUtc } | Sort-Object Name | Select-Object -ExpandProperty FullName)
    }
    $sensitive=@()
    foreach ($relative in @('jenkins-home/secrets/faf-portable-admin.json','jenkins-home/secrets/initialAdminPassword')) {
        $secretPath=Get-SafeFullPath (Join-Path $root $relative)
        if (-not (Test-Path -LiteralPath $secretPath -PathType Leaf)) { continue }
        try {
            $text=[IO.File]::ReadAllText($secretPath)
            if ($relative.EndsWith('.json')) {
                $credential=$text|ConvertFrom-Json
                foreach ($name in @('password','token')) {
                    if ($credential.PSObject.Properties[$name] -and $credential.$name) { $sensitive+=[string]$credential.$name }
                }
            } else { $sensitive+=$text.Trim() }
        } catch { }
    }
    $Context.operation='Jenkins startup'
    Write-FailureReport -ReportPath (Join-Path $runtime 'failure-report.log') -FailureRecord $FailureRecord -Context $Context -LogFiles $files -SensitiveValues $sensitive
}
