# FAF Windows 便携打包工具

本手册用于已组装的便携发行包。请从 [GitHub Releases](https://github.com/Wine-Tianci/FaFGame-Build/releases/latest) 下载 `faf-build-portable-*.zip`。GitHub 的“Code → Download ZIP”或“Source code”只含源码，不能直接双击这里的入口使用；小型更新 ZIP 也需要已有完整便携工具。

适用于 Windows x64，使用系统自带 Windows PowerShell 5.1。包内已带 Java、Git、Godot、Windows 导出模板、Jenkins 和流水线插件，无需安装 Java、Steam、Git 或 Godot，也无需修改 JAVA_HOME、系统 PATH。首次启动不下载依赖。

1. **完整解压** ZIP 到有写入权限的本地目录。不要在压缩包中直接运行，不要放在游戏源码目录内。实际构建使用工具根目录同级的 `faf-work` 和短运行编号，减少安装目录层级带来的路径长度问题。
2. 双击 **Start.cmd**。首次输入游戏 **Git 仓库根目录**的完整路径，该目录应包含 `faf_game/project.godot` 和 `faf_config`。这项选择只需做一次。
3. 等待初始化完成，浏览器会打开构建任务。登录用户是 `admin`，初始密码见启动窗口提示的 `jenkins-home/secrets/faf-portable-admin.json` 文件中的 `password` 字段。每份首次启动的工具会生成自己的密码。登录后可在个人安全设置中改密。
4. 点击“带参数构建”，选择分支、Debug/Release 和测试选项。构建完成后从该次构建页面的“归档产物”下载 ZIP。
5. 双击 **Stop.cmd** 停机。它会等待正在执行的构建结束。关闭浏览器或启动窗口不会停止 Jenkins。

工具读取本地分支的已提交快照。未提交改动不进入游戏包；拉取远程更新和准备仓库由仓库维护者处理。源码目录只读，构建在工具自己的目录中完成。默认只执行导入/导出和一个基本主流程检查：导出的游戏开始新游戏，等待玩家与关卡准备完成，然后正常退出。完整功能测试默认关闭；勾选后仅记录日志，其失败、超时或崩溃不阻止生成基本流程已通过的包。

实际构建目录为 `<工具目录>/faf-work/<构建号>/<16位运行ID>/`，与 jenkins-home、Start.cmd 和 Stop.cmd 同级。source 保存源码快照，logs 保存原始日志，artifacts 保存交付 ZIP 和清单。运行时间、提交等仍记录在清单中。Jenkins 工作区只保存 run.json 位置记录以及归档所需的 ZIP、清单或 failure-report.log。

更新保留旧的 Jenkins 构建记录和旧工作区，新构建自动使用 faf-work。旧 faf-work 数据不会随 Jenkins 的历史条数设置自动删除；清理前应停止相关构建并保留所需交付物。非常深的安装路径或特别长的资源文件名仍受 Windows/引擎限制，失败报告会保留实际路径。

第一次需要选择源码路径并登录；运行依赖已经内置。默认使用 8080 端口，占用时自动尝试后续 20 个端口，仅监听本机。再次双击 Start.cmd 会打开同一实例。首次初始化可能需要数分钟。

## 配置与移动

源码路径和端口保存在根目录 `portable-config.json`。先停机，再修改该文件或运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Start-Portable.ps1 -SourceRepository 'D:\projects\faf-game' -Port 8081
```

移动目录前先用 Stop.cmd 停机，再移动整个工具目录。Java、Godot、Git 和模板会从新目录定位；如果游戏仓库也移动了，需要更新 `sourceRepository`。日志、任务、账号和历史属于这台电脑的本地数据。更新工具时应另行备份这些数据。

## 给其他人分发

**只分发原始发布 ZIP，不要把已经运行过的目录重新压缩发给别人。** 运行后的目录包含本地账号、用于安全停机的 API Token、路径、源码快照和构建历史。`faf-portable-admin.json` 是本机凭据，请勿分享，也不要上传原始服务日志。修改登录密码不更新该文件中的初始 password 记录。

**构建失败只需发送一个文件：** 在该次 Jenkins 构建页面的“归档产物”下载 `failure-report.log`。其中包含错误摘要、分支/模式/版本、调用栈，以及该次 Git、Godot 导入、测试、导出和启动检查的完整日志与进程记录。默认成功只归档游戏 ZIP 和 build-manifest.json；勾选可选功能测试时增加一个 test-report.log，包含全部测试结果与原始日志，清单明确记录非阻断失败数量。

**工具启动失败：** 查看工具目录下 `runtime/failure-report.log`；其中汇总本次启动错误和本次服务日志，并遮盖本机已知初始密码、API Token 及 Authorization 头。再次启动失败会更新这个报告。原始服务日志仍位于 runtime/logs，原始构建日志仍位于运行目录/logs，需要深入检查时可在本机查看。

命令行构建失败的报告位于运行目录/failure-report.log；若失败发生在创建运行目录之前，报告位于 BuildRoot/failure-report.log。目录无法安全写入、工作区与源码重叠或命令参数解析失败时，错误仍在启动窗口/控制台中显示。

默认账号拥有管理员权限，适用于本机个人构建；服务只绑定 `127.0.0.1`。

第三方软件许可随运行目录附带。Jenkins 与插件的许可也包含在 WAR/JPI 的 META-INF 内。便携编辑器可带 `.steam` 版本标识，但发布只复制经独立启动验收的编辑器及 ICU 数据，不包含 Steam 客户端或 Steam API DLL。
