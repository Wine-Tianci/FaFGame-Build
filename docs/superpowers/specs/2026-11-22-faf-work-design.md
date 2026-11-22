# 同级 faf-work 构建目录

用户确认：实际构建目录放在工具根目录的 faf-work，与 jenkins-home、Start.cmd、Stop.cmd 同级。安装位置不变，所有源码快照、导入缓存、测试、导出暂存和原始日志在 faf-work 中完成。

布局为 FAF_BUILD_HOME/faf-work/<构建号>/<16位随机ID>/source、logs、artifacts。CLI 不指定 BuildRoot 时默认用工具根/faf-work；显式 BuildRoot 保持兼容。运行编号不再嵌入长时间戳，时间继续记录在清单中。每次仍创建新目录并拒绝覆盖。

Jenkins workspace 仍保持现有的隔离校验。Build-Windows 接受一个内部 RunRecordPath 参数，先在当前工作区 builds/<构建号>/run.json 写入预检记录，运行创建后记录具体工作目录与状态。记录须同时绑定源码、构建号、归档目录和精确的 faf-work 根。读取时验证规范化路径、重解析点、运行 ID、源码隔离和所属构建，不选择其他运行的最近目录。

成功时 Copy-BuildArtifacts 将精确两份 ZIP/清单复制回当前 Jenkins 工作区 builds/<构建号>/artifacts；失败时 New-BuildFailureReport 读取已验证的 run.json，从精确 faf-work 运行读取报告/原始日志，仍只归档当前工作区的 failure-report.log。分支选择之前失败没有 run.json，保留原有汇总行为。失败报告不移动游戏源码，也不清理历史运行。

添加 Windows PowerShell 5.1 行为测试覆盖短路径、运行唯一性、记录篡改/跨构建拒绝、成功产物复制、失败报告定位、无记录的早期失败、junction 拒绝。真实 Jenkins 验收增加当前日志的 Dialogic 深路径资源，验证从旧布局超过 260 字符变为 faf-work 下可用，并检查原始源码不变、Debug/Release 成功及两种失败仍可下载单报告。

通过后更新 E:/fb、源码 GitHub main 和新的 v2026.11.22 发布（完整包/更新包/校验文件）。保留旧 Release 以及本机账号、配置和历史。
