# Windows x64 便携构建工具

用户确认方案 1：保留 Jenkins，交付包含运行依赖的离线 ZIP。Windows PowerShell 5.1 是操作系统前提；用户只需选择已准备好的游戏 Git 仓库。现有本机 Jenkins 保持独立。

发布使用明确白名单：scripts、presets、Jenkinsfile、便携入口、使用说明、JRE、完整 Git 运行目录、Jenkins WAR、可独立运行的 Godot 编辑器、匹配的 Windows 导出模板、经过 lock 校验的插件。不能复制本机 jenkins-home、依赖绝对路径记录、日志、历史、游戏源码、凭据。发布目录必须全新。

Start.cmd 调用 Start-Portable.ps1，首次交互选择仓库并保存 portable-config.json；可命令行传入仓库、端口，便于验收。按包根解析运行依赖，使用进程级 Git PATH；不修改系统环境。首次生成 Jenkins home、预置插件、可信初始化脚本；每实例生成独立 admin 密码，只保存在本地 secrets 文件，不写日志。初始化开启认证与 CSRF、禁用匿名权限、设置单执行器 windows-godot、创建带参数的 faf-windows Pipeline；后续不重置账号。

启动等待 Jenkins 初始化标记和 HTTP 就绪，自动打开浏览器。重复双击复用已验证的同一实例；端口占用明确提示或自动选择空闲端口。Stop.cmd 用启动记录核对实例，通过只存本机的 API Token 发起 safeExit，等待构建结束，不强杀不明进程。移动目录需先停机；下次重新按根目录定位。

验收：真实 Windows PowerShell 5.1 测试；新包无本机数据；解压至中文和空格路径；无系统 Git/Java 依赖启动 Jenkins、认证访问参数任务、读取本地分支、停止、移动后重启；独立最小 Godot 项目通过预置 Jenkins 流水线运行真实 Debug/Release 构建并归档。现有游戏本身的问题不放宽检查。Godot 编辑器来源于已有发行文件，带 .steam 版本标识，但不带 Steam API DLL、客户端或用户配置；验收期间没有 Steam 进程，独立导入和导出是交付前提。
