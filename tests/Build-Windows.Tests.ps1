[CmdletBinding()]
param([string]$TestRoot)
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path $PSScriptRoot -Parent
if (-not $TestRoot) { $TestRoot = Join-Path $toolRoot ('test-results/' + [guid]::NewGuid().ToString('N')) }
$script:passed = 0
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "ASSERT: $Message" } }
function WriteText([string]$Path, [string]$Text) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}
function Native([string]$File, [string[]]$Arguments, [string]$Cwd = $TestRoot) {
    $p = New-Object Diagnostics.Process
    $p.StartInfo.FileName = $File
    $p.StartInfo.Arguments = (($Arguments | ForEach-Object { '"' + [regex]::Replace([regex]::Replace($_, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"' }) -join ' ')
    $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.CreateNoWindow = $true
    $p.StartInfo.WindowStyle = 'Hidden'
    $p.StartInfo.RedirectStandardOutput = $true
    $p.StartInfo.RedirectStandardError = $true
    $p.StartInfo.WorkingDirectory = $Cwd
    try {
        $null = $p.Start()
        $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(120000)) { $p.Kill(); throw 'Test child timed out' }
        [pscustomobject]@{ Code = $p.ExitCode; Out = $o.Result; Err = $e.Result }
    } finally { $p.Dispose() }
}
[IO.Directory]::CreateDirectory($TestRoot) | Out-Null
$repo = Join-Path $TestRoot 'source repository with spaces'
[IO.Directory]::CreateDirectory($repo) | Out-Null
$git = (Get-Command git.exe).Source
function Git([string[]]$Arguments) {
    $r = Native $git (@('--no-optional-locks','-C',$repo) + $Arguments)
    Assert ($r.Code -eq 0) ("fixture git failed: " + $r.Err)
    return $r.Out.Trim()
}
$null = Git @('init','-b','main')
$null = Git @('config','user.name','Build Fixture')
$null = Git @('config','user.email','fixture@example.invalid')
WriteText (Join-Path $repo 'faf_game/project.godot') "config_version=5`n[application]`nconfig/name=`"fixture`""
WriteText (Join-Path $repo 'faf_config/tables/items.csv') "id,name`n1,committed`n"
WriteText (Join-Path $repo 'faf_config/Z.csv') "id`n2`n"
WriteText (Join-Path $repo 'faf_game/marker.txt') 'main commit'
# Keep this PowerShell 5.1 source ASCII; JSON escapes create real Unicode paths.
$unicodeFiles = @(
    ('"faf_game/\u4e2d\u6587\u76ee\u5f55/\u9493\u9c7c\u7ec4\u4ef6.png"' | ConvertFrom-Json),
    ('"faf_game/\u4e2d\u6587\u76ee\u5f55/\u5c0f\u94f6\u9c7c.png"' | ConvertFrom-Json)
)
foreach ($relative in $unicodeFiles) { WriteText (Join-Path $repo $relative) ($relative + "`n" + ('"\u4e2d\u6587\u5185\u5bb9"' | ConvertFrom-Json)) }
WriteText (Join-Path $repo 'faf_game/tests/run_node_tests.gd') "extends Node`nfunc _ready():`n`tget_tree().quit()"
WriteText (Join-Path $repo 'faf_game/tests/run_tree_tests.gd') "extends SceneTree`nfunc _initialize():`n`tquit()"
WriteText (Join-Path $repo 'faf_game/tests/run_item_display_tests.gd') 'extends Node'
WriteText (Join-Path $repo 'faf_game/tests/item_display_test_runner.tscn') '[gd_scene format=3]'
WriteText (Join-Path $repo 'faf_game/tests/item_system_test_runner.tscn') '[gd_scene format=3]'
WriteText (Join-Path $repo 'faf_game/tests/collection_runtime_regression.tscn') '[gd_scene format=3]'
WriteText (Join-Path $repo 'faf_game/tests/run_collection_runtime_regression.gd') 'extends Node'
WriteText (Join-Path $repo 'faf_game/addons/example/native.gdextension') @'
[libraries]
windows.debug.x86_64 = "bin/native.debug.dll"
windows.release.x86_64 = "res://addons/example/bin/native.release.dll"
windows.release.x86_32 = "bin/ignore.dll"
linux.release.x86_64 = "bin/ignore.so"
'@
$null = Git @('add','.')
$null = Git @('commit','-m','fixture main')
$mainSha = Git @('rev-parse','HEAD')
$unicodeBranchNfc = '"caf\u00e9"' | ConvertFrom-Json
$unicodeBranchNfd = '"cafe\u0301"' | ConvertFrom-Json
$null = Git @('branch',$unicodeBranchNfc,$mainSha)
$null = Git @('checkout','-b','feature/space-test')
WriteText (Join-Path $repo 'faf_game/marker.txt') 'feature commit'
$null = Git @('add','.')
$null = Git @('commit','-m','fixture feature')
$featureSha = Git @('rev-parse','HEAD')
foreach ($variant in @('no-csv','no-project','empty-csv')) {
    $null = Git @('checkout','-b',$variant,'feature/space-test')
    if ($variant -eq 'no-csv') { $null = Git @('rm','-r','faf_config') }
    elseif ($variant -eq 'no-project') { $null = Git @('rm','faf_game/project.godot') }
    else { WriteText (Join-Path $repo 'faf_config/Z.csv') '' }
    $null = Git @('add','.')
    $null = Git @('commit','-m',("fixture " + $variant))
}
$null = Git @('checkout','-b','editor-plugins','main')
# BOM, CRLF and a multiline array make byte restoration observable.
$pluginProject = "config_version=5`r`n[application]`r`nconfig/name=`"fixture`"`r`n`r`n[editor_plugins]`r`nenabled=PackedStringArray(`r`n`"res://addons/example/plugin.cfg`"`r`n)`r`n`r`n[rendering]`r`nrenderer/rendering_method=`"gl_compatibility`"`r`n"
[IO.File]::WriteAllText((Join-Path $repo 'faf_game/project.godot'), $pluginProject, (New-Object Text.UTF8Encoding($true)))
$pluginProjectBytes = [IO.File]::ReadAllBytes((Join-Path $repo 'faf_game/project.godot'))
$null = Git @('add','.')
$null = Git @('commit','-m','fixture enabled editor plugin')
$null = Git @('checkout','-b','empty-editor-plugins','main')
WriteText (Join-Path $repo 'faf_game/project.godot') "config_version=5`n[editor_plugins]`n; enabled=PackedStringArray(`"res://commented/plugin.cfg`")`nenabled=PackedStringArray()`n"
$null = Git @('add','.')
$null = Git @('commit','-m','fixture empty editor plugins')
$null = Git @('checkout','feature/space-test')
WriteText (Join-Path $repo 'faf_game/marker.txt') 'dirty file must not ship'
WriteText (Join-Path $repo 'untracked.txt') 'must not ship'
$beforeStatus = Git @('status','--porcelain=v1','--untracked-files=all')
$beforeRefs = Git @('show-ref')
function RepositoryFingerprint {
    $lines = @(Get-ChildItem -LiteralPath $repo -Recurse -Force -File | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($repo.Length) + '|' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    })
    return $lines -join "`n"
}
$beforeFiles = RepositoryFingerprint
$otherRepo = Join-Path $TestRoot 'foreign repository'
[IO.Directory]::CreateDirectory($otherRepo) | Out-Null
foreach ($folder in @('faf_game','faf_config')) { Copy-Item -LiteralPath (Join-Path $repo $folder) -Destination (Join-Path $otherRepo $folder) -Recurse }
WriteText (Join-Path $otherRepo 'faf_game/marker.txt') 'foreign repository commit must never ship'
foreach ($gitArguments in @(
    @('init','-b','main'), @('config','user.name','Foreign Fixture'),
    @('config','user.email','foreign@example.invalid'), @('add','.'),
    @('commit','-m','foreign fixture'), @('branch','foreign-only')
)) {
    $otherResult = Native $git (@('--no-optional-locks','-C',$otherRepo) + $gitArguments)
    Assert ($otherResult.Code -eq 0) ('foreign fixture Git failed: ' + $otherResult.Err)
}
$fake = Join-Path $TestRoot 'fake engine.exe'
$template = Join-Path $TestRoot 'windows template.exe'
$compilerParameters = New-Object CodeDom.Compiler.CompilerParameters
$compilerParameters.CompilerOptions = '/platform:x64'
$compilerParameters.OutputAssembly = $fake
$compilerParameters.GenerateExecutable = $true
$null = $compilerParameters.ReferencedAssemblies.Add('System.dll')
$null = $compilerParameters.ReferencedAssemblies.Add('System.Core.dll')
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Diagnostics;
public static class FakeEngine {
  public static int Main(string[] args) {
    string mode = Environment.GetEnvironmentVariable("FAF_TEST_SCENARIO") ?? "ok";
    string own = System.Reflection.Assembly.GetExecutingAssembly().Location;
    if (args.Contains("--child")) { Thread.Sleep(20000); return 0; }
    bool game = Path.GetFileName(own) == "faf.exe";
    string engineDirectory = Path.GetDirectoryName(own);
    if (!game && (File.Exists(Path.Combine(engineDirectory,"._sc_")) || File.Exists(Path.Combine(engineDirectory,"_sc_")))) {
      Directory.CreateDirectory(Path.Combine(engineDirectory,"editor_data"));
      File.WriteAllText(Path.Combine(engineDirectory,"editor_data","settings-touched.txt"), "self-contained mode ignores APPDATA");
    }
    if (Path.GetFileName(own) == "godot.exe" && mode == "selfcontained" && !File.Exists(Path.Combine(engineDirectory,"steam_api64.dll"))) return 74;
    int li = Array.IndexOf(args, "--log-file");
    string log = li >= 0 ? args[li+1] : null;
    if (args.Contains("--version")) { Console.WriteLine(Path.GetFileName(own).Contains("bad-version") ? "4.4.0.stable.official.fixture" : "4.5.1.stable.official.fixture"); return 0; }
    foreach (string key in new [] {"APPDATA", "LOCALAPPDATA", "TEMP", "TMP"}) {
      string v = Environment.GetEnvironmentVariable(key);
      if (v == null || !v.Contains("user-data")) { Console.Error.WriteLine("ERROR: user data not isolated"); return 71; }
    }
    if (log != null) File.WriteAllText(log, "fake log\n");
    Console.WriteLine(string.Join("|", args));
    Console.WriteLine("cwd=" + Environment.CurrentDirectory);
    if (game) {
      string package = Directory.GetParent(Path.GetDirectoryName(own)).FullName;
      if (Environment.CurrentDirectory.StartsWith(package, StringComparison.OrdinalIgnoreCase)) return 72;
      if (!File.Exists(Path.Combine(package, "faf_config", "tables", "items.csv"))) return 73;
      string saves = Path.Combine(Path.GetDirectoryName(own), "saves");
      Directory.CreateDirectory(saves);
      File.WriteAllText(Path.Combine(saves, "game.tres"), "verification-only progress");
      if (mode == "smoke") { Console.Error.WriteLine("ERROR: smoke failed"); return 0; }
      if (mode == "smokenonzero") return 8;
      if (mode == "smoketimeout") Thread.Sleep(10000);
      return 0;
    }
    bool editor = args.Contains("--editor");
    bool export = args.Contains("--export-release") || args.Contains("--export-debug");
    if (editor && !export) {
      if (mode.StartsWith("cold-plugin")) {
        string configPath = Path.Combine(args[Array.IndexOf(args,"--path")+1], "project.godot");
        string config = File.ReadAllText(configPath);
        bool inPlugins = false, pluginsEnabled = false;
        foreach (string sourceLine in config.Split('\n')) {
          string line = sourceLine.Trim();
          if (line.StartsWith("[")) inPlugins = line == "[editor_plugins]";
          else if (inPlugins && !line.StartsWith(";") && line.Contains("res://")) pluginsEnabled = true;
        }
        bool bootstrapped = File.Exists(configPath + ".fixture-imported");
        Console.WriteLine("fixture_plugins_enabled=" + pluginsEnabled);
        if (pluginsEnabled && !bootstrapped) { Console.Error.WriteLine("ERROR: plugin preload UID not cached"); return 0; }
        if (!pluginsEnabled) {
          if (mode == "cold-plugin-bootstrap-error") { Console.Error.WriteLine("ERROR: bootstrap failed"); return 0; }
          File.WriteAllText(configPath + ".fixture-imported", "resource scan completed");
          // Model an editor save: the wrapper must restore the exact original bytes.
          File.AppendAllText(configPath, "\n; editor changed temporary configuration\n");
        } else if (mode == "cold-plugin-normal-error") { Console.Error.WriteLine("SCRIPT ERROR: enabled plugin is broken"); return 0; }
      }
      if (mode == "nonzero") return 9;
      if (mode == "error") { Console.WriteLine("ERROR: exit zero is not success"); return 0; }
      if (mode == "stderr") { Console.Error.WriteLine("SCRIPT ERROR: exit zero"); return 0; }
      if (mode == "logerror" && log != null) File.AppendAllText(log, "ERROR: log only\n");
      if (mode == "timeout") {
        ProcessStartInfo childInfo = new ProcessStartInfo(own, "--child");
        childInfo.UseShellExecute = false; childInfo.CreateNoWindow = true; childInfo.WindowStyle = ProcessWindowStyle.Hidden;
        Process child = Process.Start(childInfo);
        File.WriteAllText(log + ".childpid", child.Id.ToString());
        Thread.Sleep(10000);
      }
      if (mode == "flood") { for (int i=0;i<16000;i++) { Console.WriteLine("out " + i); Console.Error.WriteLine("err " + i); } }
    }
    if (export) {
      if (mode == "exporterror") { Console.WriteLine("ERROR: export failed"); return 0; }
      if (mode == "exportnonzero") return 7;
      string exe = args[args.Length-1];
      Directory.CreateDirectory(Path.GetDirectoryName(exe));
      File.Copy(own, exe);
      if (mode != "missingpck") File.WriteAllText(Path.ChangeExtension(exe,"pck"), "separate pck");
      if (mode != "missingdll") File.WriteAllText(Path.Combine(Path.GetDirectoryName(exe), args.Contains("--export-debug") && mode != "wrongdebugdll" ? "native.debug.dll" : "native.release.dll"), "native");
    }
    if (!editor && !export && mode == "mainsmoke") { Console.WriteLine("ERROR: main scene failed"); return 0; }
    return 0;
  }
}
'@ -CompilerParameters $compilerParameters
Copy-Item -LiteralPath $fake -Destination $template
$powershell = Join-Path $PSHOME 'powershell.exe'
$buildScript = Join-Path $toolRoot 'scripts/Build-Windows.ps1'
$branchScript = Join-Path $toolRoot 'scripts/Get-Branches.ps1'
function RunBuild([hashtable]$Overrides = @{}, [string]$Scenario = 'ok') {
    $params = @{ SourceRepository=$repo; BranchName='main'; GodotPath=$fake; BuildRoot=(Join-Path $TestRoot 'build output'); BuildMode='Release'; BuildNumber='007'; ExportTemplate=$template; TimeoutSeconds='5' }
    foreach ($k in $Overrides.Keys) { $params[$k] = $Overrides[$k] }
    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$buildScript)
    foreach ($k in $params.Keys) {
        if ($params[$k] -is [bool]) { if ($params[$k]) { $a += "-$k" } }
        else { $a += "-$k"; $a += [string]$params[$k] }
    }
    $env:FAF_TEST_SCENARIO = $Scenario
    try { return Native $powershell $a } finally { Remove-Item Env:FAF_TEST_SCENARIO -ErrorAction SilentlyContinue }
}
function Check([string]$Name, [scriptblock]$Body) { & $Body; $script:passed++; Write-Host "PASS $Name" }
function ExpectFailure([hashtable]$Overrides, [string]$Scenario = 'ok') {
    if (-not $Overrides.ContainsKey('BuildRoot')) { $Overrides.BuildRoot = Join-Path $TestRoot ('f-' + [guid]::NewGuid().ToString('N').Substring(0,8)) }
    $existingZips = @()
    if (Test-Path -LiteralPath $Overrides.BuildRoot) { $existingZips = @(Get-ChildItem -LiteralPath $Overrides.BuildRoot -Filter '*.zip' -Recurse -File | Where-Object { $_.Directory.Name -eq 'artifacts' } | ForEach-Object FullName) }
    $r = RunBuild $Overrides $Scenario
    Assert ($r.Code -eq 1) ("expected exit 1: " + $r.Out + $r.Err)
    if (Test-Path -LiteralPath $Overrides.BuildRoot) {
        $afterZips = @(Get-ChildItem -LiteralPath $Overrides.BuildRoot -Filter '*.zip' -Recurse -File | Where-Object { $_.Directory.Name -eq 'artifacts' } | ForEach-Object FullName)
        Assert (($afterZips -join '|') -eq ($existingZips -join '|')) 'failure must not produce ZIP or remove earlier packages'
    }
    return $r
}
try {
    Check 'entrypoints exist' { Assert (Test-Path -LiteralPath $buildScript) 'Build-Windows.ps1 must exist'; Assert (Test-Path -LiteralPath $branchScript) 'Get-Branches.ps1 must exist' }
    Check 'cold editor plugin import restores original configuration before normal import' {
        $root = Join-Path $TestRoot 'cold-plugin'
        $result = RunBuild @{BranchName='editor-plugins'; BuildRoot=$root} 'cold-plugin'
        Assert ($result.Code -eq 0) ($result.Out+$result.Err)
        $run = @(Get-ChildItem -LiteralPath $root -Directory)[0].FullName
        $actualBytes = [IO.File]::ReadAllBytes((Join-Path $run 'source/faf_game/project.godot'))
        Assert ([Convert]::ToBase64String($actualBytes) -ceq [Convert]::ToBase64String($pluginProjectBytes)) 'restore exact BOM, CRLF and original project bytes'
        $bootstrap = Get-Content -Raw -LiteralPath (Join-Path $run 'logs/editor-import-bootstrap.stdout.log')
        $normal = Get-Content -Raw -LiteralPath (Join-Path $run 'logs/editor-import.stdout.log')
        Assert ($bootstrap -match 'fixture_plugins_enabled=False') 'resource bootstrap disables editor plugins only'
        Assert ($normal -match 'fixture_plugins_enabled=True') 'normal import executes with original editor plugins enabled'
    }
    foreach ($scenario in @('cold-plugin-bootstrap-error','cold-plugin-normal-error')) {
        Check "$scenario is strict and restores original configuration" {
            $root = Join-Path $TestRoot $scenario
            $null = ExpectFailure @{BranchName='editor-plugins'; BuildRoot=$root} $scenario
            $run = @(Get-ChildItem -LiteralPath $root -Directory)[0].FullName
            $actualBytes = [IO.File]::ReadAllBytes((Join-Path $run 'source/faf_game/project.godot'))
            Assert ([Convert]::ToBase64String($actualBytes) -ceq [Convert]::ToBase64String($pluginProjectBytes)) 'restore original configuration even on bootstrap or normal import failure'
            $normalLog = Join-Path $run 'logs/editor-import.stdout.log'
            if ($scenario -eq 'cold-plugin-bootstrap-error') { Assert (-not (Test-Path -LiteralPath $normalLog)) 'bootstrap error must stop immediately without retry or normal import' }
            else { Assert ((Get-Content -Raw -LiteralPath (Join-Path $run 'logs/editor-import.stderr.log')) -match 'enabled plugin is broken') 'full import still fails on SCRIPT ERROR' }
        }
    }
    Check 'projects without enabled editor plugins skip bootstrap' {
        foreach ($branch in @('main','empty-editor-plugins')) {
            $root = Join-Path $TestRoot ('nb-' + $branch.Substring(0,2))
            $result = RunBuild @{BranchName=$branch; BuildRoot=$root}
            Assert ($result.Code -eq 0) ($result.Out+$result.Err)
            Assert (@(Get-ChildItem -LiteralPath $root -Filter 'editor-import-bootstrap*' -Recurse -File).Count -eq 0) 'no bootstrap for absent or empty plugin lists, including commented enabled setting'
        }
    }
    Check 'read-only branch list' {
        $r = Native $powershell @('-NoProfile','-File',$branchScript,'-SourceRepository',$repo)
        Assert ($r.Code -eq 0) $r.Err
        Assert ($r.Out -match '(?m)^main\s*$' -and $r.Out -match '(?m)^feature/space-test\s*$') 'list both local branches'
    }
    Check 'inherited Git repository overrides cannot substitute another repository' {
        $inherited = @{GIT_DIR=(Join-Path $otherRepo '.git'); GIT_WORK_TREE=$repo}
        $saved = @{}
        foreach ($key in $inherited.Keys) { $saved[$key] = [Environment]::GetEnvironmentVariable($key); [Environment]::SetEnvironmentVariable($key,$inherited[$key]) }
        try {
            $root = Join-Path $TestRoot 'git-env'
            $result = RunBuild @{BuildRoot=$root}
            Assert ($result.Code -eq 0) ($result.Out+$result.Err)
            $run = @(Get-ChildItem -LiteralPath $root -Directory)[0].FullName
            $m = Get-Content -Raw -LiteralPath (Join-Path $run 'artifacts/build-manifest.json') | ConvertFrom-Json
            Assert ($m.fullSha -ceq $mainSha) 'manifest must pin the selected repository commit despite inherited GIT_DIR and GIT_WORK_TREE'
            Assert ([IO.File]::ReadAllText((Join-Path $run 'source/faf_game/marker.txt')) -ceq 'main commit') 'snapshot must come from selected repository'
            $branches = Native $powershell @('-NoProfile','-File',$branchScript,'-SourceRepository',$repo)
            Assert ($branches.Code -eq 0 -and $branches.Out -notmatch 'foreign-only' -and $branches.Out -match 'feature/space-test') 'branch listing ignores repository overrides too'
        } finally { foreach ($key in $inherited.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) } }
    }
    Check 'Git config overrides cannot replace repository config or branch parsing' {
        $inherited = @{GIT_CONFIG_COUNT='1'; GIT_CONFIG_KEY_0='core.repositoryformatversion'; GIT_CONFIG_VALUE_0='999'; GIT_CONFIG_PARAMETERS="'core.repositoryformatversion=999'"; GIT_CONFIG=(Join-Path $otherRepo '.git/config'); GIT_CEILING_DIRECTORIES=$TestRoot}
        $saved = @{}
        foreach ($key in $inherited.Keys) { $saved[$key] = [Environment]::GetEnvironmentVariable($key); [Environment]::SetEnvironmentVariable($key,$inherited[$key]) }
        try {
            $result = RunBuild @{BuildRoot=(Join-Path $TestRoot 'git-config-env')}
            Assert ($result.Code -eq 0) ($result.Out+$result.Err)
        } finally { foreach ($key in $inherited.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) } }
    }
    Check 'Unicode normalization does not make a missing branch an exact match' {
        $result = ExpectFailure @{BranchName=$unicodeBranchNfd}
        Assert ($result.Out -match 'Exact local branch not found') 'NFD input must not match a distinct NFC branch during exact ref enumeration'
        $result = RunBuild @{BranchName=$unicodeBranchNfc; BuildRoot=(Join-Path $TestRoot 'unicode-branch')}
        Assert ($result.Code -eq 0) ($result.Out+$result.Err)
    }
    Check 'Release package from fixed clean commit, spaces, RunTests' {
        $r = RunBuild @{RunTests=$true; KeepStaging=$true}
        Assert ($r.Code -eq 0) ($r.Out + $r.Err)
        $script:firstRun = @(Get-ChildItem -LiteralPath (Join-Path $TestRoot 'build output') -Directory)[0].FullName
        $manifestFile = @(Get-ChildItem -LiteralPath (Join-Path $firstRun 'artifacts') -Filter '*.json')[0]
        $script:manifest = Get-Content -Raw -LiteralPath $manifestFile.FullName | ConvertFrom-Json
        Assert ($manifest.fullSha -eq $mainSha) 'main SHA'
        Assert ($manifest.buildMode -eq 'Release') 'Release mode'
        Assert ($manifest.version -eq ('main-' + $mainSha.Substring(0,12) + '-007')) 'default version'
        Assert ($manifest.config.count -eq 2 -and $manifest.config.sha256 -match '^[0-9a-f]{64}$') 'config count and hash'
        Assert ($manifest.config.files[0].path -ceq 'Z.csv') 'Ordinal sorting places uppercase Z first'
        $bytes = New-Object IO.MemoryStream
        $writer = New-Object IO.BinaryWriter($bytes)
        try {
            foreach ($relative in @('Z.csv','tables/items.csv')) {
                $name = [Text.Encoding]::UTF8.GetBytes($relative)
                $data = [IO.File]::ReadAllBytes((Join-Path $repo ('faf_config/' + $relative)))
                $writer.Write([uint32]$name.Length); $writer.Write($name); $writer.Write([int64]$data.Length); $writer.Write($data)
            }
            $writer.Flush()
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $expectedHash = [BitConverter]::ToString($sha.ComputeHash($bytes.ToArray())).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
        } finally { $writer.Dispose(); $bytes.Dispose() }
        Assert ($manifest.config.sha256 -ceq $expectedHash) 'independent config hash framing and bytes'
        Assert ($manifest.adapters.Count -eq 0) 'no speculative adapters'
        Assert ((Get-Content -Raw -LiteralPath (Join-Path $firstRun 'source/faf_game/marker.txt')) -eq 'main commit') 'snapshot ignores dirty workspace and current branch'
        Assert (-not (Test-Path -LiteralPath (Join-Path $firstRun 'source/untracked.txt'))) 'untracked excluded'
        $preset = Get-Content -Raw -LiteralPath (Join-Path $firstRun 'source/faf_game/export_presets.cfg')
        Assert ($preset -match 'binary_format/embed_pck=false' -and $preset -match 'codesign/enable=false' -and $preset -match 'architecture="x86_64"') 'preset architecture, separate PCK, unsigned'
        Assert ($preset -match '(?m)^imgui/debug=true$' -and $preset -match '(?m)^imgui/release=true$') 'ImGui native plugin explicitly enabled in both build modes'
        Assert ($preset -match [regex]::Escape($template.Replace('\','/'))) 'absolute template path'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zipFile = @(Get-ChildItem -LiteralPath (Join-Path $firstRun 'artifacts') -Filter '*.zip')[0]
        $zip = [IO.Compression.ZipFile]::OpenRead($zipFile.FullName)
        try {
            $entries = @($zip.Entries | ForEach-Object {$_.FullName.Replace('\','/')})
            $top = $manifest.packageName
            foreach ($suffix in @('game/faf.exe','game/faf.pck','game/native.release.dll','faf_config/tables/items.csv','build-manifest.json')) {
                Assert ($entries -contains "$top/$suffix") "ZIP contains $suffix under top folder"
            }
            Assert (@($entries | Where-Object { $_.StartsWith("$top/game/saves/") }).Count -eq 0) 'ZIP does not contain smoke-test saves'
        } finally { $zip.Dispose() }
        $logs = (Get-ChildItem -LiteralPath (Join-Path $firstRun 'logs') -Filter '*.stdout.log' | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName }) -join "`n"
        Assert ($logs -match '--script\|res://tests/run_tree_tests.gd') 'SceneTree test executed'
        Assert ($logs -match 'run_node_tests.gd' -and $logs -match 'item_display_test_runner.tscn' -and $logs -match 'item_system_test_runner.tscn') 'all Node and scene tests executed'
        Assert ([regex]::Matches($logs, '--scene\|res://tests/collection_runtime_regression.tscn').Count -eq 0) 'optional collection regression scene is not executed during packaging'
        Assert ($manifest.godotOriginalPath -eq $fake -and $manifest.godotRuntimePath -eq $fake) 'normal engine runs directly from its original path'
        Assert ($manifest.exportTemplateSha256 -ceq (Get-FileHash -LiteralPath $template -Algorithm SHA256).Hash.ToLowerInvariant()) 'manifest pins template bytes'
        Assert ($manifest.exportTemplateVersion -eq '4.5.1.stable.official.fixture') 'template version recorded'
    }
    Check 'UTF-8 Chinese archive paths and bytes survive the snapshot' {
        foreach ($relative in $unicodeFiles) {
            $sourceFile = Join-Path $repo $relative
            $snapshotFile = Join-Path (Join-Path $firstRun 'source') $relative
            Assert (Test-Path -LiteralPath $snapshotFile -PathType Leaf) 'Chinese snapshot filename must remain exact'
            Assert ((Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath $snapshotFile -Algorithm SHA256).Hash) 'Chinese snapshot file SHA must match the committed bytes'
            Assert ([IO.File]::ReadAllText($sourceFile) -ceq [IO.File]::ReadAllText($snapshotFile)) 'Chinese snapshot content remains exact'
        }
    }
    foreach ($marker in @('._sc_','_sc_')) {
        Check "self-contained engine $marker runs from an isolated copy" {
            $engineSource = Join-Path $TestRoot ('portable-' + $marker)
            [IO.Directory]::CreateDirectory($engineSource) | Out-Null
            $sourceExe = Join-Path $engineSource 'godot.exe'
            Copy-Item -LiteralPath $fake -Destination $sourceExe
            WriteText (Join-Path $engineSource $marker) ''
            WriteText (Join-Path $engineSource 'steam_api64.dll') 'steam fixture dependency'
            WriteText (Join-Path $engineSource 'editor_data/existing-settings.txt') 'developer settings must not change or be copied'
            $beforeEngine = @(Get-ChildItem -LiteralPath $engineSource -File -Force -Recurse | Sort-Object FullName | ForEach-Object { $_.FullName + '|' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join "`n"
            $root = Join-Path $TestRoot ('portable-output-' + $marker)
            $r = RunBuild @{GodotPath=$sourceExe; BuildRoot=$root} 'selfcontained'
            Assert ($r.Code -eq 0) ($r.Out+$r.Err)
            $afterEngine = @(Get-ChildItem -LiteralPath $engineSource -File -Force -Recurse | Sort-Object FullName | ForEach-Object { $_.FullName + '|' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join "`n"
            Assert ($beforeEngine -ceq $afterEngine) 'original self-contained engine installation must be byte-for-byte unchanged'
            $run = @(Get-ChildItem -LiteralPath $root -Directory)[0].FullName
            $m = Get-Content -Raw -LiteralPath (Join-Path $run 'artifacts/build-manifest.json') | ConvertFrom-Json
            Assert ($m.godotOriginalPath -eq $sourceExe) 'manifest records original engine path'
            Assert ($m.godotRuntimePath -eq (Join-Path $run 'engine/godot.exe')) 'manifest records isolated engine path'
            Assert ((Get-FileHash -LiteralPath $sourceExe).Hash -eq (Get-FileHash -LiteralPath $m.godotRuntimePath).Hash) 'engine copy has identical executable bytes'
            Assert (Test-Path -LiteralPath (Join-Path $run 'engine/steam_api64.dll')) 'Steam DLL copied beside engine'
            Assert (-not (Test-Path -LiteralPath (Join-Path $run 'engine/editor_data'))) 'developer editor_data was not copied'
            foreach ($forbidden in @('._sc_','_sc_')) { Assert (-not (Test-Path -LiteralPath (Join-Path $run ('engine/' + $forbidden)))) 'self-contained marker was not copied' }
        }
    }
    Check 'Debug, feature branch and independent runs, cleanup keeps diagnostics' {
        $r = RunBuild @{BranchName='feature/space-test'; BuildMode='Debug'}
        Assert ($r.Code -eq 0) ($r.Out + $r.Err)
        $runs = @(Get-ChildItem -LiteralPath (Join-Path $TestRoot 'build output') -Directory)
        Assert ($runs.Count -eq 2) 'unique run without overwriting'
        $run = @($runs | Where-Object FullName -ne $firstRun)[0].FullName
        $m = Get-Content -Raw -LiteralPath (@(Get-ChildItem -LiteralPath (Join-Path $run 'artifacts') -Filter '*.json')[0].FullName) | ConvertFrom-Json
        Assert ($m.fullSha -eq $featureSha -and $m.buildMode -eq 'Debug') 'selected feature Debug'
        Assert ($m.config.sha256 -eq $manifest.config.sha256) 'stable config hash across independent builds'
        Assert (-not (Test-Path -LiteralPath (Join-Path $run 'staging'))) 'default cleans own staging'
        Assert ((Test-Path -LiteralPath (Join-Path $run 'logs')) -and (Test-Path -LiteralPath (Join-Path $run 'source'))) 'logs and snapshot preserved'
    }
    foreach ($branch in @('missing','HEAD','main~0','--help','refs/heads/main','main..x','MAIN')) {
        Check "reject branch $branch" {
            $result = ExpectFailure @{BranchName=$branch}
            if ($branch -ceq 'MAIN') { Assert ($result.Out -match 'Exact local branch not found') 'case-mismatched branch fails before export, not from an unrelated runtime error' }
        }
    }
    Check 'reject invalid mode' { $null = ExpectFailure @{BuildMode='Fast'} }
    Check 'missing Godot' { $null = ExpectFailure @{GodotPath=(Join-Path $TestRoot 'missing.exe')} }
    Check 'missing template' { $null = ExpectFailure @{ExportTemplate=(Join-Path $TestRoot 'missing-template.exe')} }
    Check 'reject a template with the wrong engine version' {
        $wrongVersion = Join-Path $TestRoot 'bad-version-template.exe'
        Copy-Item -LiteralPath $template -Destination $wrongVersion
        $r = ExpectFailure @{ExportTemplate=$wrongVersion}
        Assert ($r.Out -match 'Template version mismatch') 'wrong template version fails explicitly'
    }
    Check 'reject a template that is not an x64 PE executable' {
        $wrongArchitecture = Join-Path $TestRoot 'x86-template.exe'
        $peBytes = [IO.File]::ReadAllBytes($template)
        $peOffset = [BitConverter]::ToInt32($peBytes,0x3c)
        $peBytes[$peOffset+4] = 0x4c; $peBytes[$peOffset+5] = 0x01
        [IO.File]::WriteAllBytes($wrongArchitecture,$peBytes)
        $r = ExpectFailure @{ExportTemplate=$wrongArchitecture}
        Assert ($r.Out -match 'x86_64 PE') 'wrong PE machine rejected before execution'
    }
    Check 'default template resolves matching Godot version and mode' {
        $oldAppData = $env:APPDATA
        $env:APPDATA = Join-Path $TestRoot 'developer app data'
        try {
            $expected = Join-Path $env:APPDATA 'Godot/export_templates/4.5.1.stable/windows_release_x86_64.exe'
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($expected)) | Out-Null
            Copy-Item -LiteralPath $template -Destination $expected
            $r = RunBuild @{BuildRoot=(Join-Path $TestRoot 'default-template'); ExportTemplate=''}
            Assert ($r.Code -eq 0) ($r.Out+$r.Err)
        } finally { $env:APPDATA = $oldAppData }
    }
    Check 'same version and build number produce independent runs' {
        $oldZip = @(Get-ChildItem -LiteralPath (Join-Path $firstRun 'artifacts') -Filter '*.zip')[0]
        $oldHash = (Get-FileHash -LiteralPath $oldZip.FullName).Hash
        $r = RunBuild @{}
        Assert ($r.Code -eq 0) ($r.Out+$r.Err)
        Assert (@(Get-ChildItem -LiteralPath (Join-Path $TestRoot 'build output') -Directory).Count -eq 3) 'third independent run'
        Assert ((Get-FileHash -LiteralPath $oldZip.FullName).Hash -eq $oldHash) 'earlier ZIP unchanged'
    }
    foreach ($variant in @('no-csv','no-project','empty-csv')) {
        Check "reject $variant commit" { $null = ExpectFailure @{BranchName=$variant} }
    }
    foreach ($overlap in @($repo,(Join-Path $repo 'child'),$TestRoot,(Join-Path $repo '../source repository with spaces/child'))) {
        Check "reject overlap $overlap" { $null = ExpectFailure @{BuildRoot=$overlap} }
    }
    Check 'reject case-insensitive overlap' { $null = ExpectFailure @{BuildRoot=$repo.ToUpperInvariant()} }
    Check 'reject junction output ancestor' {
        $target = Join-Path $TestRoot 'junction target'; [IO.Directory]::CreateDirectory($target) | Out-Null
        $alias = Join-Path $TestRoot 'junction alias'
        New-Item -ItemType Junction -Path $alias -Target $target | Out-Null
        $null = ExpectFailure @{BuildRoot=(Join-Path $alias 'builds')}
    }
    Check 'reject Windows trailing-dot path alias' {
        $null = ExpectFailure @{BuildRoot=($repo + './builds')}
    }
    Check 'reject overlap hidden by Windows short-name alias' {
        Add-Type -TypeDefinition 'using System.Runtime.InteropServices; using System.Text; public static class ShortPathForTest { [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] public static extern uint GetShortPathName(string path, StringBuilder result, uint size); }'
        $shortBuffer = New-Object Text.StringBuilder 4096
        Assert ([ShortPathForTest]::GetShortPathName($repo,$shortBuffer,4096) -gt 0) 'read fixture short path'
        $null = ExpectFailure @{BuildRoot=(Join-Path $shortBuffer.ToString() 'alias builds')}
    }
    foreach ($scenario in @('nonzero','error','stderr','logerror','timeout','mainsmoke','exporterror','exportnonzero','smoke','smokenonzero','smoketimeout','missingdll','missingpck')) {
        Check "failure $scenario retains logs and no ZIP" {
            $root = Join-Path $TestRoot $scenario
            $null = ExpectFailure @{BuildRoot=$root; TimeoutSeconds='1'} $scenario
            Assert (@(Get-ChildItem -LiteralPath $root -Filter 'failure.json' -Recurse -File).Count -eq 1) 'failure record'
            Assert (@(Get-ChildItem -LiteralPath $root -Filter '*.log' -Recurse -File).Count -gt 0) 'diagnostic logs retained'
            if ($scenario -eq 'timeout') {
                $pidFile = @(Get-ChildItem -LiteralPath $root -Filter '*.childpid' -Recurse -File)[0]
                $childPid = [int](Get-Content -Raw -LiteralPath $pidFile.FullName)
                Assert ($null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) 'timeout terminates descendants'
            }
        }
    }
    Check 'Debug cannot accept a Release-only DLL' { $null = ExpectFailure @{BuildMode='Debug'} 'wrongdebugdll' }
    Check 'stdout and stderr drained concurrently' { $r = RunBuild @{BuildRoot=(Join-Path $TestRoot 'flood')} 'flood'; Assert ($r.Code -eq 0) ($r.Out+$r.Err) }
    Check 'source Git state, refs and every file unchanged' {
        Assert ((Git @('status','--porcelain=v1','--untracked-files=all')) -eq $beforeStatus) 'source status unchanged'
        Assert ((Git @('show-ref')) -eq $beforeRefs) 'source refs unchanged'
        Assert ((RepositoryFingerprint) -eq $beforeFiles) 'source files including .git unchanged'
    }
    Write-Host "PASSED: $script:passed checks; evidence: $TestRoot"
    exit 0
} catch { Write-Host "FAILED after $script:passed checks: $_"; Write-Host $_.ScriptStackTrace; Write-Host "Evidence: $TestRoot"; exit 1 }
