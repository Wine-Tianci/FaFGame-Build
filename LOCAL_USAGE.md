# faf-build 本机使用手册

本文适用于已经部署在本机的 faf-build，说明日常启动、停机、登录、改密和构建操作。命令在 **Windows PowerShell** 中执行。历史验收结果见 [VERIFICATION.md](VERIFICATION.md)。

## 1. 入口与目录

| 项目 | 本机位置或说明 |
| --- | --- |
| Jenkins 首页 | [http://127.0.0.1:8080/](http://127.0.0.1:8080/) |
| 正式游戏构建任务 | [faf-windows](http://127.0.0.1:8080/job/faf-windows/) |
| 工具目录 | E:/workspace/faf-build |
| 只读游戏源仓库 | E:/workspace/faf-game |
| Java | E:/Code/Java/zulu21.54.109-ca-jre21.0.13.0.3-win_x64/bin/java.exe |
| Godot 编辑器 | E:/Game/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe |
| Jenkins 数据与账号 | E:/workspace/faf-build/jenkins-home |
| Windows 导出模板 | E:/workspace/faf-build/runtime/templates/4.7.2.stable |
| 初始账号 | admin；自行新增或更换账号后，使用你设置的账号 |

这里的“服务”是后台运行的 Jenkins Java 进程，**尚未注册为 Windows 服务，也没有配置开机自启**。关闭启动它的 PowerShell 窗口不会停止 Jenkins；电脑重启后需要重新启动。

127.0.0.1 指本机。当前启动器只监听回环地址，适合本机浏览器访问。

### 1.1 界面语言

本机 Jenkins 已统一设为简体中文（zh_CN），覆盖浏览器的语言偏好。登录页、已提供中文翻译的系统菜单，以及本机两个任务的名称、说明、参数提示和阶段名称使用中文。配置后刷新网页即可看到变化。

- 正式任务显示为“FAF Windows 游戏构建”，地址仍为 `/job/faf-windows/`。
- 自测任务显示为“FAF 构建工具自测”，地址仍为 `/job/faf-build-self-test/`。
- BUILD_BRANCH、BUILD_MODE、BUILD_VERSION、RUN_TESTS 是脚本参数名；Debug、Release 是模式值，保留原名以保持兼容，含义见页面中文说明和第 5 节。
- 新的阶段名称在后续构建中显示；已有构建的历史阶段名称和日志保持原样。插件未提供翻译的个别页面及底层工具日志仍可能显示英文。

语言由 locale、localization-support 和 localization-zh-cn 插件提供，固定版本见 `runtime/jenkins-language-plugin-lock.json`，设置保存在 `jenkins-home/locale.xml`。本机当前禁止用户单独覆盖语言设置；调整时由管理员进入“系统管理 → 系统配置”的 Locale 区域修改。

本机版本组合在启动时可能保留语言插件加载前的英文菜单缓存，`jenkins-home/init.groovy.d/25-faf-localization-cache.groovy` 会刷新核心消息类持有的旧缓存，让它们重新读取官方中文资源。该兼容脚本不改写翻译内容；升级 Jenkins 或语言插件后，应检查登录页及“系统管理”菜单，并留意启动日志中的脚本错误。

当前官方语言包缺少登录页“Sign in to Jenkins”标题的翻译，因此 `jenkins-home/init.groovy.d/30-faf-login-translation.groovy` 为这一项补充“登录 Jenkins”。补译脚本已即时应用并保存为启动钩子，未修改官方插件文件；若后续官方包补齐该项，将优先采用官方翻译。仅需撤销这一项补译时，停机后把该文件扩展名改为 `.disabled`，再启动 Jenkins。其他中文设置不受影响。

### 1.2 如何阅读和执行命令

代码块中只包含需要输入的内容。`PS C:\Users\Wine>` 是终端提示符，不要复制；`>>` 是 PowerShell 的续行提示符，表示上一行的命令尚未结束，也不要复制。完成后回到 `PS ...>` 表示这条命令执行结束；后台 Jenkins 可以继续运行。

- 多条命令按顺序分行显示。同一组中后面的命令可能使用前面创建的变量，应在同一个 PowerShell 窗口执行。
- `$` 开头的是变量，例如 `$buildHome` 保存构建目录；`=` 把右侧的值存入左侧变量。设置普通变量不会修改系统环境变量。
- `|` 是管道：把前一条命令的结果传给后一条。本文将管道后的命令另起一行；输入行末的 `|` 后出现 `>>` 是正常现象。
- 长命令末尾的反引号 `` ` `` 表示下一行继续同一条命令，**反引号后不能有空格**。执行时复制整个代码块。
- `#` 开头的是注释，不会执行。引号用于界定字符串；含空格的路径必须加引号。双引号内的 `$变量` 会替换成变量值，单引号中的文字保持原样。
- 包含 `try`、`finally`、`if` 或 `& { ... }` 的代码块应完整执行，不要只挑出其中的停机命令。`{ ... }` 表示一组需要一起处理的语句。

## 2. 手动启动

### 2.1 日常启动命令

打开 Windows PowerShell，执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File E:/workspace/faf-build/scripts/Start-Jenkins.ps1
```

这是一条启动命令，各部分含义如下：

| 部分 | 含义 |
| --- | --- |
| powershell.exe | 启动一个 Windows PowerShell 进程来执行后面的脚本 |
| -NoProfile | 不加载个人 PowerShell 配置文件，使启动过程少受个人配置影响 |
| -ExecutionPolicy Bypass | 为这次新开的 PowerShell 进程设置脚本执行策略；不会永久修改系统的执行策略，也不会自动取得管理员权限 |
| -File | 指定要执行的脚本文件；后面跟脚本路径 |
| Start-Jenkins.ps1 | 检查依赖与端口，启动后台 Java/Jenkins，并记录进程信息和日志位置 |

启动输出中，`PID` 是进程编号；`URL` 是网页入口；`Logs` 后面是标准输出日志和标准错误日志的路径。`Startup is asynchronous; readiness is not yet confirmed` 表示“进程已启动，Jenkins 仍在后台初始化，尚未确认就绪”。

随后打开 [Jenkins 首页](http://127.0.0.1:8080/)。首次启动或插件加载可能需要等待；终端显示“进程已启动”不代表网页已经就绪。

如果提示实例已经运行，直接打开网页即可，不需要再次启动。启动器会检查 PID 和启动时间，避免重复启动同一实例。

### 2.2 核对服务状态

```powershell
$buildHome = 'E:/workspace/faf-build'
$state = Get-Content -Raw -LiteralPath "$buildHome/runtime/jenkins.pid.json" |
    ConvertFrom-Json
Get-Process -Id $state.pid -ErrorAction SilentlyContinue |
    Select-Object Id, ProcessName, StartTime, Path
Test-NetConnection -ComputerName 127.0.0.1 -Port 8080
```

按执行顺序解释：

1. `$buildHome = ...`：把构建目录保存到变量，供后面拼接路径。
2. `Get-Content`：读取启动器保存的进程记录。`-LiteralPath` 按原样解释文件路径，不把路径中的字符当成通配符；`-Raw` 把整个文件读成一个字符串。
3. `ConvertFrom-Json`：接收管道传来的 JSON 字符串，将其转换成 PowerShell 对象并存入 `$state`，随后可以用 `$state.pid` 读取记录中的进程编号。
4. `Get-Process`：通过 `-Id $state.pid` 查询该进程。`-ErrorAction SilentlyContinue` 表示进程不存在时不显示错误；没有结果不代表服务正常，而是需要检查是否已退出。
5. `Select-Object`：只显示指定字段。`Id` 是进程编号，`ProcessName` 是进程名，`StartTime` 是启动时间，`Path` 是可执行文件路径。它只整理输出，不修改进程。
6. `Test-NetConnection`：检测 `-ComputerName` 指定的地址能否连接到 `-Port` 指定的 TCP 端口。这里检查本机 8080，`TcpTestSucceeded : True` 表示 TCP 连接成功。

判断方法：

- 找得到对应 Java 进程、启动时间与记录相符，且浏览器能打开登录页，说明服务可用。
- 端口连通只能说明有程序监听，仍应核对是否是本次 Jenkins。
- jenkins.pid.json 保存的是上次启动记录；文件存在不等于进程仍在运行。
- 进程存在但网页打不开时，检查下面的启动日志。

```powershell
$buildHome = 'E:/workspace/faf-build'
$state = Get-Content -Raw -LiteralPath "$buildHome/runtime/jenkins.pid.json" |
    ConvertFrom-Json
Get-Content -LiteralPath $state.stderrLog -Tail 60
Get-Content -LiteralPath $state.stdoutLog -Tail 60
```

这组命令先重新设置目录、读取并解析进程记录，作用与上组相同；然后执行两条日志读取命令：

- `Get-Content -LiteralPath $state.stderrLog -Tail 60`：显示标准错误日志末尾 60 行。Java/Jenkins 的普通启动信息也会写入此日志，文件名中有 stderr 不代表所有内容都是错误。
- `Get-Content -LiteralPath $state.stdoutLog -Tail 60`：显示标准输出日志末尾 60 行。
- `-Tail 60` 只取最后 60 行，这两条命令不会修改日志，也不会持续跟踪新日志。

看到 `Jenkins is fully up and running` 表示该次启动完成。首次启动日志可能包含初始化凭据，分享故障日志前应去掉凭据内容。

如果只想查找启动完成的记录，可以在上面的 `$state` 已赋值后执行：

```powershell
Select-String -LiteralPath $state.stderrLog -SimpleMatch 'Jenkins is fully up and running'
```

`Select-String` 在指定日志中查找文本，`-SimpleMatch` 表示按普通文字匹配。找到时会显示文件名、行号和匹配行；没有输出表示该日志里尚未找到这段文字，应继续检查日志。这里使用 `$state.stderrLog`，确保查询的是启动记录对应的日志，而不是任意旧日志。

例如，进程显示为 java、`TcpTestSucceeded` 为 True，且**本次启动日志**出现上述完成记录，就可以确认启动完成；浏览器能打开登录页，则进一步确认网页可用。日志时间中的 `+0000` 表示 UTC，北京时间需加 8 小时。

### 2.3 本机路径调整后的完整启动命令

日常不需要传全套参数。只有本机的安装位置、源仓库位置或端口改变时，才使用下面的形式：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File E:/workspace/faf-build/scripts/Start-Jenkins.ps1 `
    -BuildHome E:/workspace/faf-build `
    -JavaPath 'E:/Code/Java/zulu21.54.109-ca-jre21.0.13.0.3-win_x64/bin/java.exe' `
    -WarPath E:/workspace/faf-build/runtime/downloads/jenkins-2.580.2.war `
    -SourceRepository E:/workspace/faf-game `
    -GodotPath 'E:/Game/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe' `
    -TemplateDirectory E:/workspace/faf-build/runtime/templates/4.7.2.stable `
    -Port 8080
```

以上多行仍是**一条命令**，行末反引号用于续行。`powershell.exe` 的通用选项见第 2.1 节，`-File` 路径后面的参数传给启动脚本：

| 参数 | 含义 |
| --- | --- |
| -BuildHome | 构建工具根目录，Jenkins 数据、日志等写入该目录 |
| -JavaPath | 用于运行 Jenkins 的 java.exe 完整路径 |
| -WarPath | Jenkins 的 WAR 程序包路径 |
| -SourceRepository | 构建时只读访问的游戏源仓库路径 |
| -GodotPath | 构建时使用的 Godot 编辑器路径 |
| -TemplateDirectory | 与 Godot 版本匹配的导出模板目录 |
| -Port | Jenkins 本机网页监听的端口 |

这些命令行参数不会自动保存为下次启动的默认值。省略 JavaPath 时，启动器会读取 runtime/dependencies.json 的 javaHome；SourceRepository 和 GodotPath 则有脚本中的本机默认路径。调整它们后，后续启动也要继续传入相应参数。

若端口改为 8081，浏览器地址也改为 http://127.0.0.1:8081/，并在“系统管理 → 系统配置”的 Jenkins URL 中同步修改链接地址。`-Port` 只改端口，不会开放局域网监听。

## 3. 登录、设置账号和修改密码

### 3.1 本机首次登录

本机初始化时保留了 Jenkins 生成的 admin 账号。**尚未改过密码时**，可以在本机查看初始化密码文件：

```powershell
Get-Content -LiteralPath E:/workspace/faf-build/jenkins-home/secrets/initialAdminPassword
```

`Get-Content` 会把这个文件的内容显示在终端中；`-LiteralPath` 指定文件的准确路径。这条命令只读取初始化密码，不会修改账号或重置密码。

在登录页输入账号 admin 和文件中的密码。不要把密码复制进构建脚本、Git 仓库或普通问题截图。

如果已经改过密码，应使用新密码。initialAdminPassword 是初始化时的记录，**不会随日后的改密自动更新**。本手册不收录任何实际密码。

### 3.2 修改自己的登录密码

1. 登录 Jenkins，点击右上角用户名，进入个人页面。
2. 打开“安全 / Security”。本机 admin 的入口是 [账号安全设置](http://127.0.0.1:8080/user/admin/security/)。
3. 在“Password”和“Confirm Password”中输入相同的新密码，保存。
4. 退出登录，再使用新密码确认可以登录。

本机使用 Jenkins 自己的用户数据库。不要把“显示名称”当成登录用户名；修改显示名称不等于修改账号 ID。

### 3.3 新建另一个本地账号

使用管理员账号进入“系统管理 / Manage Jenkins → 用户 / Users”，选择创建用户，填写用户名、密码、确认密码等字段并保存，再用新账号验证登录。

创建账号与分配权限是两件事。当前权限策略是“已登录用户拥有完整控制权”，因此**不能把新建账号当成只读访客账号**。只有在确实需要分级权限时，才另外配置授权策略；不要为解决登录问题而开启匿名访问或取消认证。

需要更换管理员账号时，先确保新账号能登录且具有管理员权限，再处理旧账号，避免失去管理入口。

### 3.4 登录失败时

| 现象 | 处理方法 |
| --- | --- |
| 初始化密码不再有效 | 确认是否已经改密，或浏览器是否访问了另一端口上的实例；不要反复把旧初始化密码当成当前密码 |
| 忘记个人密码，但仍有其他管理员 | 请另一管理员在用户管理中进入该账号的安全设置，设置新密码 |
| 所有管理员都无法登录 | 先保留并备份完整 jenkins-home，再由本机管理员执行账号恢复；不要删除整个 Jenkins 数据目录重新开始 |
| 登录成功但没有管理权限 | 由管理员检查授权策略；重新安装 Java 或删除浏览器缓存不能替代权限配置 |

## 4. 停止与重启

### 4.1 推荐：通过认证接口安全停机

安全停机会等待正在执行的构建结束。需要有管理员权限的 Jenkins API Token。

先在“个人页面 → 安全 / Security → API Token”中创建一个用于本机维护的令牌并保存好。令牌通常只在生成时完整显示一次。它与登录密码是两种凭据。

执行下列命令时，凭据窗口的“密码”栏填写 **API Token，不是网页登录密码**：

```powershell
$jenkinsUrl = 'http://127.0.0.1:8080'
$credential = Get-Credential -UserName 'admin' -Message '密码栏填写 Jenkins API Token'
$pair = '{0}:{1}' -f $credential.UserName, $credential.GetNetworkCredential().Password
$headers = @{
    Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
}
try {
    Invoke-WebRequest -Uri "$jenkinsUrl/safeExit" -Method Post -Headers $headers -UseBasicParsing |
        Select-Object StatusCode
}
finally {
    Remove-Variable pair, headers, credential -ErrorAction SilentlyContinue
}
```

请完整执行这段代码。各条赋值、命令和控制语句的含义如下：

1. `$jenkinsUrl = ...`：保存当前 Jenkins 的访问地址。
2. `Get-Credential`：弹出凭据输入窗口，`-UserName` 预填账号，`-Message` 显示填写提示；输入结果保存在 `$credential`。
3. `$pair = ...`：`-f` 按格式拼接“用户名:API Token”；`GetNetworkCredential().Password` 读取刚才在密码栏填写的令牌，供这次请求使用。
4. `$headers = @{ ... }`：创建 HTTP 请求头。`@{ ... }` 是键值表；`UTF8.GetBytes` 把文字转换成字节，`ToBase64String` 将其编码为 Basic 认证格式。Base64 是编码，不是加密，不要输出或分享 `$pair`、`$headers` 的值。
5. `try { ... }`：执行停机请求；无论请求成功还是出现错误，后面的 `finally` 都会执行清理。
6. `Invoke-WebRequest`：向本机 `/safeExit` 接口发送请求。`-Uri` 指定地址，`-Method Post` 指定提交请求，`-Headers` 携带认证信息，`-UseBasicParsing` 在 Windows PowerShell 5.1 中使用基础响应解析。
7. `Select-Object StatusCode`：从返回结果中只显示 HTTP 状态码。请求被接受不等于进程已立即退出，仍需等待安全停机完成。
8. `Remove-Variable`：移除本次使用的三个临时变量。`-ErrorAction SilentlyContinue` 避免变量不存在时的清理错误；这不会删除 Jenkins 账号或撤销 API Token。

使用 API Token 认证的请求无需另外提供 CSRF crumb。若返回 403，先检查令牌、账号权限和访问的实例是否正确；不要改为关闭 CSRF 保护。

请求被接受后，等待当前构建结束，再用第 2.2 节核对进程已退出、端口已关闭。如果停机时 HTTP 连接提前断开，也应先检查进程状态，不要据此直接启动第二个实例。

**“准备关闭 / Prepare for Shutdown”通常只表示停止接收新的构建，不代表 Java 进程已经退出。关闭网页或退出登录也不会停止服务。**

### 4.2 无法正常响应时：核对身份后结束进程

仅在安全停机无法使用，并且已确认没有需要保留的运行中构建时，使用下面的最后处理方式。它会直接结束进程，不属于优雅停机。

```powershell
& {
    $buildHome = 'E:/workspace/faf-build'
    $record = Get-Content -Raw -LiteralPath "$buildHome/runtime/jenkins.pid.json" |
        ConvertFrom-Json
    $jenkinsProcess = Get-Process -Id $record.pid -ErrorAction Stop
    if ($jenkinsProcess.StartTime.ToUniversalTime().ToString('o') -ne $record.startTimeUtc -or
        $jenkinsProcess.Path -ine $record.executable) {
        throw 'PID 或启动时间、可执行文件不匹配，停止操作。'
    }
    $jenkinsProcess |
        Select-Object Id, StartTime, Path
    Stop-Process -Id $jenkinsProcess.Id -ErrorAction Stop
}
```

请连同外层 `& { ... }` 一起执行，不要单独复制最后的 `Stop-Process`：

1. `& { ... }`：把整组语句作为一个脚本块执行，前面的检查失败时终止这个脚本块，防止继续执行后面的结束进程操作。
2. `$buildHome`、`Get-Content`、`ConvertFrom-Json`：设置目录并读取启动记录；此处将解析结果保存为 `$record`。
3. `Get-Process`：查找记录中的进程，保存到 `$jenkinsProcess`。`-ErrorAction Stop` 表示查询失败时立即中止脚本块。
4. `if (...)`：比较进程实际启动时间和可执行文件路径。`ToUniversalTime()` 转为 UTC，`ToString('o')` 使用与记录一致的时间格式；`-ne` 表示不相等，`-ine` 表示忽略大小写后仍不相等，`-or` 表示任意一项不匹配就进入错误分支。
5. `throw`：报告不匹配并终止脚本块，因此不会执行下方的停机命令。
6. `Select-Object`：显示已经核对过的进程编号、启动时间和程序路径，供核查。
7. `Stop-Process`：直接结束该编号的进程。`-ErrorAction Stop` 使停机失败时明确报告错误。这一步会中断该进程，并不等待 Jenkins 构建收尾。

只处理记录对应的进程，不要使用“结束所有 java.exe”之类的命令。记录指向旧进程或 PID 已复用时，不要强行继续。

### 4.3 重启顺序

先按上面的方法停止，确认旧进程已退出，再执行第 2.1 节的启动命令。Jenkins 账号、任务、历史和插件保存在 jenkins-home 中，正常重启不会清空这些内容。

## 5. 手动构建游戏

1. 打开 [faf-windows](http://127.0.0.1:8080/job/faf-windows/)，点击“带参数构建 / Build with Parameters”。
2. 设置下表参数并启动。
3. 如果分支留空，在该次构建的等待输入步骤选择分支并继续；15 分钟未选择会超时结束。
4. 查看“控制台输出 / Console Output”中的阶段结果。
5. 成功后，在该次构建页面的“归档产物 / Artifacts”下载 ZIP 和 build-manifest.json。

| 参数 | 用途 |
| --- | --- |
| BUILD_BRANCH | 本地分支名，例如 main；留空时进入分支下拉选择 |
| BUILD_MODE | Debug 或 Release；两种模式都会保留本项目已配置的 ImGui，定位为内部测试包 |
| BUILD_VERSION | 可选的包版本标识；留空按分支、提交短 SHA 和构建号生成 |
| RUN_TESTS | 是否运行额外测试套件；默认开启 |

取消 RUN_TESTS 不会跳过编辑器导入、主场景启动、导出或导出包启动检查。任何阶段的 ERROR、SCRIPT ERROR、非零退出或超时，都会使构建失败。

分支列表来自源仓库的本地分支，工具不会自动拉取远程更新。可以用下列只读命令核对：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File E:/workspace/faf-build/scripts/Get-Branches.ps1 `
    -SourceRepository E:/workspace/faf-game
```

这是一条分行书写的命令：通用 PowerShell 选项与第 2.1 节相同；`-File` 执行列出分支的脚本，`-SourceRepository` 指定要读取的 Git 仓库。输出为本地分支名称；该命令不执行构建，不拉取远程更新，也不切换源仓库分支。

需要新增本地分支或获取远程提交时，由仓库维护者在构建之外准备。未提交改动不会进入包内。

**选定分支后，构建脚本解析并固定完整提交 SHA，再导出独立快照。固定 SHA 之后源分支新增提交、源工作区切换分支或修改文件，都不会改变这次构建内容。下一次构建才重新解析分支。**

### 不通过网页，直接打一个 Release 包

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File E:/workspace/faf-build/scripts/Build-Windows.ps1 `
    -SourceRepository E:/workspace/faf-game `
    -BranchName main `
    -GodotPath 'E:/Game/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe' `
    -BuildRoot E:/workspace/faf-build/builds `
    -BuildMode Release `
    -RunTests `
    -ExportTemplate E:/workspace/faf-build/runtime/templates/4.7.2.stable/windows_release_x86_64.exe
```

这是一条真正执行构建的命令，**仅在需要打包时运行**。它直接调用构建脚本，不依赖 Jenkins 网页，结果写入指定构建目录，不会新增一条 Jenkins 网页构建记录。通用 PowerShell 选项见第 2.1 节，构建参数含义如下：

| 参数 | 含义 |
| --- | --- |
| -File | 执行 Build-Windows.ps1 构建脚本 |
| -SourceRepository | 只读获取已提交内容的源仓库 |
| -BranchName main | 构建名为 main 的本地分支；需要其他分支时替换这个值 |
| -GodotPath | 使用哪个 Godot 编辑器执行导入、检查和导出 |
| -BuildRoot | 每次运行的独立目录、产物与日志的存放根目录 |
| -BuildMode Release | 选择 Release 模式；如改为 Debug，也应使用匹配的 Debug 导出模板 |
| -RunTests | 开启额外测试套件；这是开关参数，无需在后面填写值 |
| -ExportTemplate | 本次导出使用的模板文件，应匹配 Godot 版本、Windows x64 平台及构建模式 |

## 6. 本机需要保留的环境配置

本机依赖已经安装。日常使用不必重新安装，也不必修改系统 JAVA_HOME 或全局 PATH；应确保启动 Jenkins 的用户能够找到 git.exe。

| 配置 | 当前要求或来源 |
| --- | --- |
| Windows / PowerShell | Windows x64；现有脚本使用 Windows PowerShell 5.1 |
| Git | git.exe 可从启动进程的 PATH 找到 |
| Java | Azul Zulu21.54+109-CA，21.0.13.0.3+1-LTS；路径优先来自 runtime/dependencies.json 的 javaHome |
| Jenkins | 2.580.2，WAR 位于 runtime/downloads |
| Godot / 模板 | Godot 4.7.2 编辑器和同版本 Windows x64 模板，不能只靠重命名目录匹配版本 |
| Pipeline 插件 | 本机已安装；版本记录在 runtime/jenkins-plugin-lock.json |
| 节点标签 | windows-godot；本机已配置一个执行器 |
| JENKINS_HOME | 由启动器设置为工具目录下的 jenkins-home |
| FAF_BUILD_HOME | 由启动器根据 BuildHome 设置 |
| FAF_SOURCE_REPOSITORY | 由启动器根据 SourceRepository 设置 |
| GODOT_BIN | 由启动器根据 GodotPath 设置 |
| FAF_TEMPLATE_DIRECTORY | 由启动器根据 TemplateDirectory 设置 |

这些环境变量主要设置给 Jenkins 子进程，不会自动改写系统环境。Java 的 user.home、AppData、日志和临时目录放在构建目录内；Windows 的 USERPROFILE、HOMEDRIVE、HOMEPATH 保持真实身份路径，不要手动改成一个空构建目录。

需要调整 Java、Godot、模板或源仓库路径时，停止 Jenkins 后使用完整参数重新启动。仅修改当前 PowerShell 的环境变量，不会更新已经运行的 Java 进程。

## 7. 产物与日志在哪里

| 内容 | 位置 |
| --- | --- |
| 网页构建的 ZIP、清单、诊断 | 优先从该次 Jenkins 构建页面的 Artifacts 查看 |
| 命令行构建目录 | E:/workspace/faf-build/builds/运行编号/ |
| 正式任务工作区 | E:/workspace/faf-build/jenkins-home/workspace/faf-windows/ |
| 正式任务某次运行 | 工作区/builds/构建号/运行编号/ |
| 构建成功产物 | 运行目录/artifacts/ |
| 构建失败汇总 | Jenkins 归档的 failure-report.log；命令行运行目录/failure-report.log |
| 构建失败原始记录 | 运行目录/failure.json |
| 便携启动失败汇总 | 工具目录/runtime/failure-report.log |
| 构建阶段日志 | 运行目录/logs/ |
| Jenkins 服务日志 | runtime/jenkins.pid.json 中的 stdoutLog、stderrLog |

ZIP 中游戏程序位于包根下的 game/faf.exe，faf_config 与 game 并列。应解压完整目录，再运行 game/faf.exe；不要只复制单个 EXE。

build-manifest.json 可用于追溯分支、完整提交 SHA、构建模式、构建号、Godot 版本、模板和配置摘要。source.zip 是构建输入快照，不是成功游戏包。

## 8. 常见问题

| 现象 | 检查方向 |
| --- | --- |
| 网页打不开 | 先检查 PID、端口和最新服务日志；电脑重启后需要手动启动 |
| 提示端口已占用 | 确认是否已有 Jenkins；不要结束不明进程。确需换端口时，启动参数、浏览器地址和 Jenkins URL 都要同步 |
| 提示实例已运行 | 核对 jenkins.pid.json 对应进程后直接使用现有实例 |
| 提示找不到 Java / Godot / WAR | 检查完整路径是否存在；旧 dependencies.json 可能仍引用旧 Java 路径 |
| 任务一直排队 | 检查 windows-godot 节点是否在线、唯一执行器是否被其他构建或等待分支输入的任务占用 |
| 分支不在列表中 | 确认它是本地分支；只有远程跟踪引用或尚未准备的分支不会显示 |
| 源代码改了，包没有变化 | 检查是否已提交，以及清单记录的分支和 SHA；未提交内容本来就不打包 |
| 模板版本不匹配 | 检查编辑器真实版本与模板真实版本；Steam 更新编辑器后也可能出现不匹配 |
| 取消 RUN_TESTS 后仍失败 | 导入、主场景和导出包检查仍执行，查看最早失败阶段 |
| 日志出现 26 resources still in use at exit | 这是已有验收中出现过的游戏退出错误示例；按规则失败，需要在源项目修复并提交，不能把任务当成功包 |
| 没看到 ZIP | 先看构建结果和 failure.json；失败时通常只归档诊断 |
| 历史记录只剩 20 次，磁盘仍占用很多 | Jenkins 历史保留与工作区快照清理是两件事；清理前先停止相关构建并保留需要的产物 |

本机另有 faf-build-self-test，使用独立测试项目验证构建工具。它成功不代表正式游戏的任意提交也通过。具体已执行和未执行的验证以 [VERIFICATION.md](VERIFICATION.md) 为准。

## 9. 日常操作速查

- 开机后使用：运行 Start-Jenkins.ps1 → 打开本机网页 → 登录。
- 打包：进入 faf-windows → 带参数构建 → 选择本地分支和模式 → 查看结果及产物。
- 改密：个人页面 → 安全 → 新密码与确认密码 → 保存并重新登录。
- 停机：管理员 API Token 调用 safeExit → 等待构建结束和进程退出。
- 重启：确认旧进程退出 → 再运行启动脚本。
