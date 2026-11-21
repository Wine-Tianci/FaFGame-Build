[CmdletBinding()]
param([string]$TestRoot)
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path $PSScriptRoot -Parent
$launcher = Join-Path $toolRoot 'scripts/Start-Jenkins.ps1'
$checker = Join-Path $toolRoot 'scripts/Check-JenkinsWorkspace.ps1'
$script:passed = 0
function Assert($Value, [string]$Message) { if (-not $Value) { throw "ASSERT: $Message" }; $script:passed++; Write-Host "PASS: $Message" }
Assert (Test-Path -LiteralPath $launcher) 'Jenkins launcher exists'
Assert (Test-Path -LiteralPath $checker) 'Workspace checker exists'
. (Join-Path $toolRoot 'scripts/Build-Common.ps1')
if (-not $TestRoot) { $TestRoot = Join-Path $toolRoot ('test-results/jenkins-' + [guid]::NewGuid().ToString('N')) }
[IO.Directory]::CreateDirectory($TestRoot) | Out-Null
$repo = Join-Path $TestRoot 'read only source'
[IO.Directory]::CreateDirectory($repo) | Out-Null
$fakeJava = Join-Path $TestRoot 'fake java.exe'
$fakeGodot = Join-Path $TestRoot 'godot.exe'
$war = Join-Path $TestRoot 'jenkins with spaces.war'
Write-Utf8 $fakeGodot 'fake'
Write-Utf8 $war 'fake'
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
class FakeJava {
  public static int Main(string[] args) {
    string root = Environment.GetEnvironmentVariable("FAF_BUILD_HOME");
    File.WriteAllLines(Path.Combine(root, "argv.txt"), args);
    string[] names = {"JENKINS_HOME", "FAF_BUILD_HOME", "FAF_SOURCE_REPOSITORY", "GODOT_BIN", "FAF_TEMPLATE_DIRECTORY", "TEMP", "TMP", "USERPROFILE", "HOMEDRIVE", "HOMEPATH", "APPDATA", "LOCALAPPDATA", "JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS"};
    using (var w = File.CreateText(Path.Combine(root, "environment.txt"))) foreach (string name in names) w.WriteLine(name + "=" + Environment.GetEnvironmentVariable(name));
    Console.WriteLine("fake-stdout-initial"); Console.Error.WriteLine("fake-stderr-initial");
    if (File.Exists(Path.Combine(root, "exit-immediately"))) return 17;
    Thread.Sleep(2500);
    Console.WriteLine("fake-stdout-after-launcher-exit"); Console.Error.WriteLine("fake-stderr-after-launcher-exit");
    Thread.Sleep(30000); return 0;
  }
}
'@ -OutputAssembly $fakeJava -OutputType ConsoleApplication
$portProbe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$portProbe.Start()
$script:testPort = $portProbe.LocalEndpoint.Port
$portProbe.Stop()
function Launch([string]$HomePath, [int]$Port = $script:testPort, [string]$Java = $fakeJava, [string]$WarFile = $war) {
    $launchArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$launcher,'-BuildHome',$HomePath,'-WarPath',$WarFile,'-SourceRepository',$repo,'-GodotPath',$fakeGodot,'-Port',"$Port")
    if ($Java) { $launchArgs += @('-JavaPath',$Java) }
    Invoke-BuildProcess -FilePath (Join-Path $PSHOME 'powershell.exe') -Arguments $launchArgs -WorkingDirectory $TestRoot -TimeoutSeconds 20
}
function Reject([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $caught = $false
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message -match $Pattern }
    Assert $caught $Message
}
function ReadLiveLog([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = New-Object IO.StreamReader($stream)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose(); $stream.Dispose() }
}
$homePath = Join-Path $TestRoot 'build home with spaces'
$defaultHome = Join-Path $TestRoot 'default launcher home'
$defaultScripts = Join-Path $defaultHome 'scripts'
New-Item -ItemType Directory -Force -Path $defaultScripts | Out-Null
foreach ($name in @('Start-Jenkins.ps1','Build-Common.ps1')) {
    Copy-Item -LiteralPath (Join-Path $toolRoot ('scripts/' + $name)) -Destination (Join-Path $defaultScripts $name)
}
$defaultChild = $null
try {
    $null = Invoke-BuildProcess -FilePath (Join-Path $PSHOME 'powershell.exe') -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $defaultScripts 'Start-Jenkins.ps1'),'-JavaPath',$fakeJava,'-WarPath',$war,'-SourceRepository',$repo,'-GodotPath',$fakeGodot,'-Port',"$script:testPort") -WorkingDirectory $TestRoot -TimeoutSeconds 20
    $defaultState = Get-Content -Raw (Join-Path $defaultHome 'runtime/jenkins.pid.json') | ConvertFrom-Json
    $defaultChild = Get-Process -Id $defaultState.pid -ErrorAction Stop
    Assert ($defaultState.buildHome -eq (Get-SafeFullPath $defaultHome) -and -not $defaultChild.HasExited) 'Real PowerShell -File without BuildHome uses launcher tool root'
} finally {
    if ($defaultChild -and -not $defaultChild.HasExited) { $defaultChild.Kill(); $defaultChild.WaitForExit() }
    if ($defaultChild) { $defaultChild.Dispose() }
}
Reject { Launch $homePath 0 } 'Port' 'Reject invalid port'
Assert (-not (Test-Path $homePath)) 'Invalid port creates no home'
Reject { Launch $homePath $script:testPort (Join-Path $TestRoot 'missing.exe') } 'Java' 'Reject missing Java'
Reject { Launch $homePath $script:testPort $fakeJava (Join-Path $TestRoot 'missing.war') } 'WAR' 'Reject missing WAR'
Assert (-not (Test-Path $homePath)) 'Missing dependencies create no home'
Reject { Launch (Join-Path $repo 'nested') } 'overlap' 'Reject home inside source'
Reject { Launch $TestRoot } 'overlap' 'Reject home containing source'
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$listener.Start()
$busyPort = $listener.LocalEndpoint.Port
try { Reject { Launch $homePath $busyPort } 'port|Port|socket|Socket|usage|address' 'Reject occupied port before launch' } finally { $listener.Stop() }
Assert (-not (Test-Path $homePath)) 'Occupied port creates no home'
$validWorkspace = Join-Path $homePath 'jenkins-home/workspace/game'
& $checker -BuildHome $homePath -Workspace $validWorkspace -SourceRepository $repo | Out-Null
Assert (-not (Test-Path $homePath)) 'Workspace validation never creates files'
Reject { & $checker -BuildHome $homePath -Workspace (Join-Path $TestRoot 'foreign') -SourceRepository $repo } 'workspace|Workspace' 'Reject foreign workspace'
Reject { & $checker -BuildHome $homePath -Workspace $validWorkspace -SourceRepository (Join-Path $validWorkspace 'source') } 'overlap' 'Reject source nested in workspace'
Reject { & $checker -BuildHome $homePath -Workspace $validWorkspace -SourceRepository $homePath } 'overlap' 'Reject workspace nested in source'
$oldJavaOptions = $env:JAVA_TOOL_OPTIONS
$oldHome = $env:JENKINS_HOME
$oldAppData = $env:APPDATA
$oldLocalAppData = $env:LOCALAPPDATA
$child = $null
try {
    $env:JAVA_TOOL_OPTIONS = '-Dunwanted=inherited'
    $env:JENKINS_HOME = 'unwanted-parent-home'
    $launchOutput = Launch $homePath
    $state = Get-Content -Raw (Join-Path $homePath 'runtime/jenkins.pid.json') | ConvertFrom-Json
    $child = Get-Process -Id $state.pid -ErrorAction Stop
    Assert (-not $child.HasExited) 'Child survives launcher PowerShell exit'
    Assert ($env:JENKINS_HOME -eq 'unwanted-parent-home') 'Parent Jenkins environment unchanged'
    Assert ($env:JAVA_TOOL_OPTIONS -eq '-Dunwanted=inherited') 'Parent Java environment unchanged'
    $argsSeen = [IO.File]::ReadAllLines((Join-Path $homePath 'argv.txt'))
    Assert ($argsSeen -contains (Get-SafeFullPath $war)) 'Native argv preserves WAR path with spaces'
    Assert ($argsSeen -contains '--httpListenAddress=127.0.0.1') 'Bind localhost only'
    Assert ($argsSeen -contains ('--httpPort=' + $script:testPort)) 'Port passed to Java child'
    Assert ($argsSeen -contains ('-Djava.io.tmpdir=' + (Join-Path (Get-SafeFullPath $homePath) 'runtime/temp'))) 'Java temporary directory isolated'
    Assert ($argsSeen -contains ('-Duser.home=' + (Join-Path (Get-SafeFullPath $homePath) 'runtime/user-home'))) 'Java user.home remains isolated without changing Windows identity'
    $environmentSeen = [IO.File]::ReadAllText((Join-Path $homePath 'environment.txt'))
    Assert ($environmentSeen.Contains('JENKINS_HOME=' + (Join-Path (Get-SafeFullPath $homePath) 'jenkins-home'))) 'Child Jenkins home isolated'
    Assert ($environmentSeen.Contains('FAF_SOURCE_REPOSITORY=' + (Get-SafeFullPath $repo))) 'Source path reaches child as data'
    foreach ($name in @('USERPROFILE','HOMEDRIVE','HOMEPATH')) {
        $parentValue = [Environment]::GetEnvironmentVariable($name)
        Assert ($environmentSeen -match ('(?m)^' + $name + '=' + [regex]::Escape([string]$parentValue) + '\r?$')) ('Child preserves Windows identity variable ' + $name)
    }
    foreach ($name in @('TEMP','TMP')) {
        Assert ($environmentSeen.Contains($name + '=' + (Join-Path (Get-SafeFullPath $homePath) 'runtime/temp'))) ('Child ' + $name + ' remains isolated inside build home')
    }
    Assert ($environmentSeen.Contains('APPDATA=' + (Join-Path (Get-SafeFullPath $homePath) 'runtime/user-home/AppData/Roaming'))) 'Child APPDATA isolated inside build home'
    Assert ($environmentSeen.Contains('LOCALAPPDATA=' + (Join-Path (Get-SafeFullPath $homePath) 'runtime/user-home/AppData/Local'))) 'Child LOCALAPPDATA isolated inside build home'
    Assert ($env:APPDATA -eq $oldAppData -and $env:LOCALAPPDATA -eq $oldLocalAppData) 'Parent AppData environment unchanged'
    Assert ($environmentSeen -match '(?m)^JAVA_TOOL_OPTIONS=\r?$') 'Inherited Java option injection removed from child'
    Assert ($launchOutput -notmatch 'secret|password') 'Launcher output contains no credentials'
    Start-Sleep -Seconds 3
    Assert ((ReadLiveLog $state.stdoutLog).Contains('fake-stdout-after-launcher-exit')) 'Stdout still reaches file after launcher exits'
    Assert ((ReadLiveLog $state.stderrLog).Contains('fake-stderr-after-launcher-exit')) 'Stderr still reaches file after launcher exits'
    Reject { Launch $homePath } 'running|active' 'Refuse duplicate instance'
    Assert (-not $child.HasExited) 'Duplicate attempt leaves existing process alive'
} finally {
    $env:JAVA_TOOL_OPTIONS = $oldJavaOptions
    $env:JENKINS_HOME = $oldHome
    if ($child -and -not $child.HasExited) { $child.Kill(); $child.WaitForExit() }
    if ($child) { $child.Dispose() }
}
$recordedHome = Join-Path $TestRoot 'recorded java home'
$recordedJava = Join-Path $TestRoot 'recorded-jre/bin/java.exe'
New-Item -ItemType Directory -Force -Path (Join-Path $recordedHome 'runtime'),(Split-Path $recordedJava -Parent) | Out-Null
Copy-Item -LiteralPath $fakeJava -Destination $recordedJava
Write-Utf8 (Join-Path $recordedHome 'runtime/dependencies.json') (@{ javaHome=(Split-Path (Split-Path $recordedJava -Parent) -Parent) } | ConvertTo-Json)
$recordedChild = $null
try {
    $null = Launch $recordedHome $script:testPort ''
    $recordedState = Get-Content -Raw (Join-Path $recordedHome 'runtime/jenkins.pid.json') | ConvertFrom-Json
    $recordedChild = Get-Process -Id $recordedState.pid
    Assert (-not $recordedChild.HasExited) 'Default Java comes from dependencies.json javaHome'
} finally {
    if ($recordedChild -and -not $recordedChild.HasExited) { $recordedChild.Kill(); $recordedChild.WaitForExit() }
    if ($recordedChild) { $recordedChild.Dispose() }
}
$linkedHome = Join-Path $TestRoot 'linked record home'
New-Item -ItemType Directory -Force -Path (Join-Path $linkedHome 'runtime') | Out-Null
$linkedJre = Join-Path $TestRoot 'linked-jre'
New-Item -ItemType Junction -Path $linkedJre -Target (Split-Path (Split-Path $recordedJava -Parent) -Parent) | Out-Null
Write-Utf8 (Join-Path $linkedHome 'runtime/dependencies.json') (@{ javaHome=$linkedJre } | ConvertTo-Json)
Reject { Launch $linkedHome $script:testPort '' } 'Reparse point' 'Reject Java record pointing through a junction'
$partialHome = Join-Path $TestRoot 'partial dependency record'
New-Item -ItemType Directory -Force -Path (Join-Path $partialHome 'runtime') | Out-Null
Write-Utf8 (Join-Path $partialHome 'runtime/dependencies.json') '{"status":"incomplete"}'
Reject { Launch $partialHome $script:testPort '' (Join-Path $TestRoot 'missing.war') } 'Java dependency not found: .*zulu21|Jenkins WAR dependency not found' 'Incomplete dependency record without Java home uses Azul fallback'
$earlyHome = Join-Path $TestRoot 'early exit home'
[IO.Directory]::CreateDirectory($earlyHome) | Out-Null
Write-Utf8 (Join-Path $earlyHome 'exit-immediately') 'yes'
Reject { Launch $earlyHome } 'exited' 'Report immediate child exit'
$pipeline = [IO.File]::ReadAllText((Join-Path $toolRoot 'Jenkinsfile'))
Assert ($pipeline.Contains('skipDefaultCheckout()') -and $pipeline.Contains('disableConcurrentBuilds()')) 'Static pipeline checkout and concurrency guards'
Assert (-not $pipeline.Contains('deleteDir') -and -not $pipeline.Contains('checkout scm')) 'Static pipeline has no unguarded cleanup or source checkout'
Assert (-not $pipeline.Contains('${params.') -and -not $pipeline.Contains('${env.FAF_SELECTED_BRANCH}')) 'Static pipeline does not interpolate user data into code'
Assert ($pipeline.Contains('artifacts/*.zip') -and -not $pipeline.Contains('**/*.zip')) 'Static success archive targets artifacts only'
Write-Host "Jenkins tests passed: $script:passed (fake native process; no real Jenkins execution)."
Write-Host "Test evidence: $TestRoot"
