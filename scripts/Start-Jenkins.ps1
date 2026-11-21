[CmdletBinding()]
param(
    [string]$BuildHome,
    [string]$JavaPath,
    [string]$WarPath,
    [string]$SourceRepository = 'E:/workspace/faf-game',
    [string]$GodotPath = 'E:/Game/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe',
    [string]$TemplateDirectory,
    [ValidateRange(1,65535)][int]$Port = 8080,
    [switch]$SkipSetupWizard
)
$ErrorActionPreference = 'Stop'
if (-not $BuildHome) { $BuildHome = Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'Build-Common.ps1')
$homePath = Get-SafeFullPath $BuildHome
$source = Get-SafeFullPath $SourceRepository
Assert-SeparatePaths $source $homePath
if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Source repository not found: $source" }
if (-not $JavaPath) {
    $dependencyRecord = Get-SafeFullPath (Join-Path $homePath 'runtime/dependencies.json')
    if (Test-Path -LiteralPath $dependencyRecord -PathType Leaf) {
        $dependencies = [IO.File]::ReadAllText($dependencyRecord) | ConvertFrom-Json
        if ($dependencies -and $dependencies.PSObject.Properties['javaHome'] -and $dependencies.javaHome) {
            if ($dependencies.javaHome -isnot [string] -or -not [IO.Path]::IsPathRooted($dependencies.javaHome)) { throw 'Dependency javaHome must be an absolute path.' }
            $JavaPath = Join-Path (Get-SafeFullPath $dependencies.javaHome) 'bin/java.exe'
        }
    }
    if (-not $JavaPath) { $JavaPath = 'E:/Code/Java/zulu21.54.109-ca-jre21.0.13.0.3-win_x64/bin/java.exe' }
}
if (-not $WarPath) { $WarPath = Join-Path $homePath 'runtime/downloads/jenkins-2.580.2.war' }
if (-not $TemplateDirectory) { $TemplateDirectory = Join-Path $homePath 'runtime/templates/4.7.2.stable' }
$java = Get-SafeFullPath $JavaPath
$war = Get-SafeFullPath $WarPath
$godot = Get-SafeFullPath $GodotPath
$templates = Get-SafeFullPath $TemplateDirectory
foreach ($dependency in @(@('Java',$java),@('Jenkins WAR',$war),@('Godot',$godot))) {
    if (-not (Test-Path -LiteralPath $dependency[1] -PathType Leaf)) { throw ($dependency[0] + ' dependency not found: ' + $dependency[1]) }
}
$paths = @{}
foreach ($relative in @('jenkins-home','runtime','runtime/jenkins-cache','runtime/logs','runtime/temp','runtime/user-home','runtime/user-home/AppData/Roaming','runtime/user-home/AppData/Local')) {
    $path = Get-SafeFullPath (Join-Path $homePath $relative)
    if (-not (Test-WithinPath $path $homePath)) { throw "Runtime path escaped BuildHome: $path" }
    Assert-SeparatePaths $source $path
    $paths[$relative] = $path
}
$statePath = Get-SafeFullPath (Join-Path $homePath 'runtime/jenkins.pid.json')
$hash = [Security.Cryptography.SHA256]::Create()
try { $mutexKey = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($homePath.ToUpperInvariant()))).Replace('-','') } finally { $hash.Dispose() }
$mutex = New-Object Threading.Mutex($false, ('Local\FafJenkins-' + $mutexKey))
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another launcher is active for this BuildHome.' }
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $old = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        $existing = Get-Process -Id $old.pid -ErrorAction SilentlyContinue
        if ($existing) {
            try {
                if ($existing.StartTime.ToUniversalTime().ToString('o') -eq $old.startTimeUtc) { throw "Jenkins instance is already running (PID $($old.pid))." }
            } finally { $existing.Dispose() }
        }
    }
    $probe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
    try { $probe.Server.ExclusiveAddressUse = $true; $probe.Start() } catch { throw "Local port $Port is unavailable: $($_.Exception.Message)" } finally { $probe.Stop() }
    # Check every existing path/reparse ancestor before creating any directory.
    foreach ($path in $paths.Values) { [IO.Directory]::CreateDirectory($path) | Out-Null }
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N')
    $stdoutLog = Join-Path $paths['runtime/logs'] ("jenkins-$stamp.stdout.log")
    $stderrLog = Join-Path $paths['runtime/logs'] ("jenkins-$stamp.stderr.log")
    $arguments = @(
        ('-Djava.io.tmpdir=' + $paths['runtime/temp']),
        ('-Duser.home=' + $paths['runtime/user-home']),
        '-jar', $war,
        '--httpListenAddress=127.0.0.1', ('--httpPort=' + $Port),
        ('--webroot=' + $paths['runtime/jenkins-cache'])
    )
    if ($SkipSetupWizard) { $arguments = @('-Djenkins.install.runSetupWizard=false') + $arguments }
    $environmentMap = [Environment]::GetEnvironmentVariables()
    foreach ($name in @('JAVA_TOOL_OPTIONS','JDK_JAVA_OPTIONS','_JAVA_OPTIONS','JENKINS_JAVA_OPTIONS','JENKINS_OPTS')) { $environmentMap.Remove($name) }
    $childEnvironment = @{
        JENKINS_HOME=$paths['jenkins-home']; FAF_BUILD_HOME=$homePath; FAF_SOURCE_REPOSITORY=$source;
        GODOT_BIN=$godot; FAF_TEMPLATE_DIRECTORY=$templates; TEMP=$paths['runtime/temp']; TMP=$paths['runtime/temp'];
        APPDATA=$paths['runtime/user-home/AppData/Roaming']; LOCALAPPDATA=$paths['runtime/user-home/AppData/Local']
    }
    foreach ($name in $childEnvironment.Keys) { $environmentMap[$name] = $childEnvironment[$name] }
    # Windows Known Folder APIs require the actual user identity. Keep inherited
    # USERPROFILE/HOMEDRIVE/HOMEPATH; Java storage uses -Duser.home above.
    # CreateProcess with inherited FILE handles keeps logging independent of this
    # PowerShell process. RedirectStandardOutput pipes would need a live reader.
    if (-not ('FafJenkins.DetachedProcess' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace FafJenkins {
  public static class DetachedProcess {
    [StructLayout(LayoutKind.Sequential)] struct Security { public int length; public IntPtr descriptor; public int inherit; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Startup {
      public int cb; public string reserved, desktop, title;
      public int x,y,xSize,ySize,xCount,yCount,fill,flags; public short show, reserved2;
      public IntPtr reservedPointer, stdin, stdout, stderr;
    }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process, thread; public int pid, tid; }
    [StructLayout(LayoutKind.Sequential)] struct StartupEx { public Startup startup; public IntPtr attributes; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr CreateFile(string name, uint access, uint share, ref Security security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateProcess(string app, StringBuilder command, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr environment, string cwd, ref StartupEx startup, out ProcessInfo process);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr result);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    static IntPtr Open(string name, uint access, uint disposition) {
      var security = new Security { length=Marshal.SizeOf(typeof(Security)), inherit=1 };
      IntPtr handle=CreateFile(name,access,3,ref security,disposition,128,IntPtr.Zero);
      if (handle==new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
      return handle;
    }
    public static int Start(string executable, string command, string cwd, string stdout, string stderr, IDictionary environment) {
      IntPtr output=IntPtr.Zero, error=IntPtr.Zero, input=IntPtr.Zero, block=IntPtr.Zero, attributes=IntPtr.Zero, handles=IntPtr.Zero;
      bool initialized=false;
      try {
        output=Open(stdout,0x40000000,1); error=Open(stderr,0x40000000,1); input=Open("NUL",0x80000000,3);
        var values=new SortedDictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        foreach (DictionaryEntry pair in environment) values[(string)pair.Key]=(string)pair.Value;
        var text=new StringBuilder(); foreach(var pair in values) text.Append(pair.Key).Append('=').Append(pair.Value).Append('\0');
        text.Append('\0'); block=Marshal.StringToHGlobalUni(text.ToString());
        IntPtr size=IntPtr.Zero; InitializeProcThreadAttributeList(IntPtr.Zero,1,0,ref size);
        attributes=Marshal.AllocHGlobal(size);
        if(!InitializeProcThreadAttributeList(attributes,1,0,ref size)) throw new Win32Exception(Marshal.GetLastWin32Error());
        initialized=true; handles=Marshal.AllocHGlobal(IntPtr.Size*3);
        Marshal.WriteIntPtr(handles,0,input); Marshal.WriteIntPtr(handles,IntPtr.Size,output); Marshal.WriteIntPtr(handles,IntPtr.Size*2,error);
        if(!UpdateProcThreadAttribute(attributes,0,new IntPtr(0x20002),handles,new IntPtr(IntPtr.Size*3),IntPtr.Zero,IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
        var startup=new StartupEx { startup=new Startup { cb=Marshal.SizeOf(typeof(StartupEx)),flags=0x101,show=0,stdin=input,stdout=output,stderr=error }, attributes=attributes };
        ProcessInfo process;
        if (!CreateProcess(executable,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,true,0x08080400,block,cwd,ref startup,out process)) throw new Win32Exception(Marshal.GetLastWin32Error());
        CloseHandle(process.thread); CloseHandle(process.process); return process.pid;
      } finally {
        if(output!=IntPtr.Zero) CloseHandle(output); if(error!=IntPtr.Zero) CloseHandle(error); if(input!=IntPtr.Zero) CloseHandle(input);
        if(block!=IntPtr.Zero) Marshal.FreeHGlobal(block);
        if(initialized) DeleteProcThreadAttributeList(attributes); if(attributes!=IntPtr.Zero) Marshal.FreeHGlobal(attributes); if(handles!=IntPtr.Zero) Marshal.FreeHGlobal(handles);
      }
    }
  }
}
'@
    }
    $commandLine = ((@($java) + $arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $childId = [FafJenkins.DetachedProcess]::Start($java, $commandLine, $homePath, $stdoutLog, $stderrLog, $environmentMap)
    $process = Get-Process -Id $childId -ErrorAction SilentlyContinue
    if (-not $process) { throw "Jenkins process exited immediately. Logs: $stdoutLog ; $stderrLog" }
    try {
        $state = [ordered]@{ pid=$childId; startTimeUtc=$process.StartTime.ToUniversalTime().ToString('o'); executable=$java; arguments=$arguments; buildHome=$homePath; jenkinsHome=$paths['jenkins-home']; port=$Port; stdoutLog=$stdoutLog; stderrLog=$stderrLog }
        Write-Utf8 $statePath ($state | ConvertTo-Json -Depth 4)
        Start-Sleep -Milliseconds 800
        if ($process.HasExited) { throw "Jenkins process exited during startup. Logs: $stdoutLog ; $stderrLog" }
        Write-Output "Jenkins process started (PID $childId). Startup is asynchronous; readiness is not yet confirmed."
        Write-Output "URL: http://127.0.0.1:$Port/"
        Write-Output "Logs: $stdoutLog ; $stderrLog"
    } finally { $process.Dispose() }
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
