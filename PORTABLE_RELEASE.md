# Windows x64 便携发布

## 2026-11-22：同级 faf-work

新版完整包为 dist/faf-build-portable-20261122.zip，已有工具用 dist/faf-build-update-20261122.zip。实际构建从 Jenkins 的多层工作区迁至工具根目录/faf-work/<构建号>/<16位运行ID>/，与 jenkins-home、Start.cmd、Stop.cmd 同级。CLI 默认也使用 faf-work；显式 BuildRoot 继续有效。

Jenkins 工作区仅保存精确的 run.json 以及交付归档；成功归档 ZIP/清单，失败仍只归档 failure-report.log。运行记录验证所属构建、源码、短运行 ID、数据根和归档根，拒绝跨构建或 reparse/junction 指向。旧的账号、配置、历史和原工作区不会删除。

对于收到的 263 字符 Dialogic 导入文件路径，新布局连同 16 位运行编号将其降至约 194 个字符，安装位置不变。运行时间继续记录在清单中。极深的安装路径/资源目录仍不能保证任意长度支持；本更新不更改系统长路径策略，也不修改游戏源码或测试预期。

用户最新日志的路径问题已经绕过，失败转为游戏 run_attribute_menu_tests.gd 的两项断言（魔法轮盘 Q 键和 Bag 输入代码）；这与工具目录改造分别处理。

验证：Build-Workspace.Tests.ps1 通过 19 项，Failure-Report.Tests.ps1 通过 23 项，入口 6 项、便携基础 22 项、Jenkins 启动器 48 项、更新器 7 项通过。真实 Jenkins 验收通过 42 项，证据在 verification/pa-555c1a9d；夹具包含用户日志中的 Dialogic SVG.import 路径，在旧布局超过 MAX_PATH，新 faf-work 布局下可解压、导入并成功完成 Debug/Release。失败测试和分支读取错误仍各只归档一个报告。测试实例已停机。

## 2026-11-21：单文件失败报告

新版便携包为 `dist/faf-build-portable-20261121.zip`；已有工具使用 `dist/faf-build-update-20261121.zip`。更新包应解压到现有工具目录之外，先运行原工具 Stop.cmd，再双击更新包的 Update.cmd 并输入原工具目录。更新会校验文件、备份原脚本和 manifest，保留本机账号、仓库/端口配置及历史；下次 Start.cmd 自动加载新的可信 Pipeline。

成功构建归档游戏 ZIP 与 build-manifest.json，失败构建只归档 failure-report.log。报告包含原始错误、分支/模式/版本、调用栈、完整 stdout/stderr/Godot 日志及 process.json。读取分支失败时记录选择阶段的 Git 诊断；在创建运行目录前失败时也保留原始错误。便携启动失败的报告为 runtime/failure-report.log，遮盖已知本机密码、API Token 和 Authorization 头。原始日志仍留在本地，旧构建归档不改动。

验证：Failure-Report.Tests.ps1 通过 23 项；更新保留用户数据、校验 manifest 和拒绝篡改包的测试通过 7 项；既有 Jenkins 启动测试通过 48 项；便携基础测试通过 22 项。真实 Jenkins 验收通过 31 项，证据在 verification/pa-a8ed2884：Debug/Release 各两份交付产物，故意失败的 Godot 测试和 Git 分支查询各只归档一份完整报告。测试实例已安全停止。

本机 E:/fb 已更新，脚本备份在 runtime/update-backups/20261121T095730-774cea61。本次不修改游戏仓库或游戏逻辑。

交付 ZIP 已实际解压并验证：完整包 338.5 MiB，793 个 payload 文件的 hash 匹配 manifest；更新包 24.9 KiB，从实际解压的更新包再次执行保留用户数据/拒绝篡改测试通过 7 项。E:/fb 已安装脚本与发布文件一致，两个 ZIP 的 .sha256 校验文件匹配。完整发布包不包含本机账号、配置、PID 或失败报告。

## 2026-11-15：原始便携发布

发布文件为 `dist/faf-build-portable-20261115.zip`（338.5 MiB），校验文件为同名 `.zip.sha256`。解压后读包内 README.md，双击 Start.cmd，首次选择游戏 Git 仓库，按启动提示读取本机生成的初始密码并登录。建议解压到较短、可写的路径，例如 `D:\faf-build`。

Java、完整 Git 运行文件、Godot 编辑器、Windows x64 模板、Jenkins WAR、Pipeline 与中文插件均已内置。Jenkins 仍是网页入口，既有 PowerShell 构建检查保持有效。系统前提为 Windows x64 / Windows PowerShell 5.1。源仓库需要由使用者准备；工具读取已提交的本地分支，不替使用者拉取远程更新。

发布只从白名单目录组装，包含相对路径 manifest 和 SHA-256。没有复制当前本机的 jenkins-home、账号、凭据、日志、构建历史、游戏源码、绝对路径 dependencies.json 或 PID。每次组装必须用全新目标目录。

## 重新生成

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\New-PortablePackage.ps1 `
  -DestinationPath .\dist\faf-build-portable-new `
  -JavaHome 'E:\Code\Java\zulu21.54.109-ca-jre21.0.13.0.3-win_x64' `
  -GitHome 'C:\Users\Wine\AppData\Local\Programs\Git' `
  -GodotPath 'E:\Game\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe' `
  -Zip
```

组装会验证固定版本 JRE、Jenkins WAR SHA-256、两个插件 lock 中每份 JPI 的 hash、Godot 版本、模板 PE x64 架构和 version.txt。当前编辑器带 `.steam` 版本标识，但单独复制 EXE/ICU 文件后可工作；发布不带 Steam API DLL、Steam 客户端、编辑器设置或 Steam 数据。两个模式均已通过真实导入、测试、导出和运行检查。

## 验收证据

2026-11-15 完成 `tests/Portable.Tests.ps1` 的 22 项检查，以及 `tests/Portable.Acceptance.ps1` 的 24 项真实验收。实际验收路径为 `verification/pa-fdfa8486`，结果在该目录的 acceptance-results.json。

真实验收从启动进程 PATH 中移除了系统 Git 和 Java，把包复制到中文/空格目录：全新 Jenkins 初始化、匿名访问拒绝、本地 API Token 认证、首次参数任务、重复启动、缺少初始化标记时拒绝误报就绪、Debug/Release Jenkins 流水线及 ZIP/清单归档、认证安全停机、目录移动后用新路径的 Java 重启、插件复制中断后恢复、保留账号与历史、源码提交不变。结束时安全停止了所有成功验收实例，未启动或停止原有本机 Jenkins。

最终 ZIP 已在 `verification/portable-zip-check` 实际解压，791 个发布文件的 hash 全部与 manifest 一致，ZIP SHA-256 为 `f742a901389797eac45be37445139f0ec08a694df5687f42ee9f915d441066ad`，与随包校验文件一致。解压后再次确认没有 Jenkins home、账号配置和 PID，发布脚本与已验收的源脚本一致。

既有 Jenkins 启动测试通过 48 项；依赖安装测试通过 16 项。既有 Build-Windows.Tests.ps1 的首个模拟构建用例另有执行异常：子 PowerShell 返回 -1 且没有标准输出或标准错误，在普通和提升执行中均复现；诊断文件在 `verification/build-test-diagnostic`。未修改该测试或原有构建业务脚本。该脚本失败与便携包通过的真实 Debug/Release 构建是两份不同证据，不将其计入通过项，根因尚未确定。

只分发原始发布 ZIP。运行过的目录已经包含本地凭据、源码快照和历史，不能重新压缩给其他人。Stop.cmd 使用生成的本机 API Token 安全停机；若该 Token 被手动撤销，需用有权限的 Jenkins 账号执行安全停机。
