# FaFGame-Build

FAF 游戏的独立 Windows 打包工具。提供本机 Jenkins 网页入口，可选择 Git 分支、Debug/Release 和测试选项，完成源码快照、Godot 导入、测试、导出、运行检查和 ZIP 打包。

便携发行包内置 Java、Git、Godot、Windows 导出模板、Jenkins 和插件，使用者无需安装这些运行依赖或配置 JAVA_HOME。

## 下载与使用

从 [Releases](https://github.com/Wine-Tianci/FaFGame-Build/releases) 下载：

- **首次使用：** `faf-build-portable-20261122-basic.zip`，约 338.5 MiB。
- **已有便携工具：** `faf-build-update-20261122-basic.zip`，约 25 KiB。
- 对应的 `.sha256` 文件用于校验下载内容。

首次使用步骤：

1. 完整解压到可写、路径较短的本地目录，例如 `E:\fb`。工具目录应与游戏源码目录分开。
2. 双击 `Start.cmd`，首次输入游戏 Git 仓库根目录。该目录应包含 `faf_game/project.godot` 和 `faf_config`。
3. 等待浏览器打开 Jenkins。账号为 `admin`，每份工具首次启动会生成独立初始密码，位置由启动窗口提示。
4. 在 `faf-windows` 中选择“带参数构建”，填写本地分支、模式和测试选项。
5. 成功后下载游戏 ZIP 和 `build-manifest.json`；需要停机时运行 `Stop.cmd`。

更新时先用原工具的 `Stop.cmd` 停机，将更新包解压到另一个目录，双击 `Update.cmd` 并输入原工具目录。更新保留本机账号、配置和构建历史，并备份原脚本。下次 `Start.cmd` 加载新规则。

系统要求为 Windows x64 / Windows PowerShell 5.1。源码仓库及远程更新由使用者准备，工具读取本地分支的已提交快照，未提交改动不进入游戏包。

## 失败日志

- 构建失败：在对应 Jenkins 构建页面下载一个 `failure-report.log`，其中包含错误摘要、参数、调用栈、阶段日志和进程记录。
- 便携工具启动失败：查看工具目录中的 `runtime/failure-report.log`。
- 默认只验证导出游戏开始新游戏并正常退出。完整功能测试默认关闭；可选运行时只记录日志，不阻止 ZIP。成功归档游戏 ZIP、清单，若请求完整测试则另有一个 test-report.log。

实际构建在工具根目录同级的 `faf-work/<构建号>/<16位运行ID>/` 中完成，安装位置不变；Jenkins 工作区只接收 ZIP、清单或失败报告。对于近期 263 字符的 Dialogic 文件路径，新布局降到约 194 字符。特别深的安装路径/资源名仍受 Windows 和引擎限制。

## 源码结构

| 路径 | 用途 |
| --- | --- |
| `scripts/` | 构建、依赖准备、启动/停机、失败报告及发行包组装脚本 |
| `portable/` | 发行包的双击入口、初始化及更新器 |
| `presets/` | 写入独立快照的 Windows 导出预设 |
| `tests/` | 单元、回归和真实 Jenkins/Godot 验收 |
| `runtime/*-lock.json` | 固定版本插件及校验信息 |
| `Jenkinsfile` | 可信的外置 Pipeline |
| `docs/` | 设计与实施文档 |

仓库保存源码和插件锁定信息。便携二进制包通过 Releases 分发；运行依赖、源码快照、构建历史、账号、凭据和本机配置不提交到 Git。

## 从源码组装

准备版本匹配的 JRE、完整 Git 运行目录、Godot 编辑器、Windows 导出模板、Jenkins WAR 和插件 JPI 后执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\New-PortablePackage.ps1 `
  -DestinationPath .\dist\faf-build-portable `
  -JavaHome 'D:\dependencies\java' `
  -GitHome 'D:\dependencies\git' `
  -GodotPath 'D:\dependencies\godot\godot.exe' `
  -TemplateDirectory 'D:\dependencies\templates\4.7.2.stable' `
  -PluginDirectory 'D:\dependencies\jenkins\plugins' `
  -WarPath 'D:\dependencies\jenkins\jenkins.war' `
  -Zip
```

当前固定版本：Zulu JRE 21.0.13.0.3+1-LTS / Zulu21.54+109-CA、Jenkins 2.580.2、Godot 4.7.2。组装脚本校验依赖和插件并生成相对路径 manifest，不复制已运行 Jenkins 的数据。发行入口从 `portable/` 复制到包根；GitHub 的源码 ZIP 本身不是已组装的便携包。

## 验证与文档

失败报告测试通过 23 项、更新器测试 7 项、便携基础测试 22 项、Jenkins 启动器测试 48 项。真实 Jenkins 验收通过 42 项，覆盖 Debug/Release、失败报告归档、认证、安全停机和目录迁移。以上使用独立测试工程，实际游戏提交仍需通过自身构建检查。

常用验证：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Failure-Report.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Portable.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Jenkins.Tests.ps1
```

[便携包手册](portable/README.md) · [发布与验收记录](PORTABLE_RELEASE.md) · [本机部署手册](LOCAL_USAGE.md)

原始部署及验证文档保留历史日期与本机路径，重新部署时应使用自己的目录。第三方软件的许可随发行包或其 WAR/JPI 附带。

当前策略已对 main 提交 f945d1c 实际验证：默认基本流程成功生成 Debug ZIP；开启完整功能测试时 64 个套件中 55 通过、9 失败，仍生成 ZIP 和汇总日志。功能失败不等于已经修复，清单保留准确统计。
