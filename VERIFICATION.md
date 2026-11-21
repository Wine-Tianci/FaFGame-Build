# faf-build 验证记录（2026-11-01）

## 当前部署

- 构建工具：`E:/workspace/faf-build`。
- Java：Azul Zulu21.54+109-CA，`21.0.13.0.3+1-LTS`，安装于 `E:/Code/Java/zulu21.54.109-ca-jre21.0.13.0.3-win_x64`。
- Jenkins：`2.580.2`，仅监听 [127.0.0.1:8080](http://127.0.0.1:8080/)，认证保持开启。
- Pipeline 与必要依赖共 51 个插件，版本和官方 SHA-256 记录在 `runtime/jenkins-plugin-lock.json`。
- Godot：`4.7.2`；复用 Steam 便携数据目录内的匹配 Windows 模板，复制后检查 PE 架构、真实版本及文件哈希。Java 与 Jenkins 安装包通过官方 SHA-256 校验。
- 本机以后台进程运行，未注册 Windows 服务。电脑重启后执行 `scripts/Start-Jenkins.ps1`。

## 已完成的验证

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| 构建脚本自动化检查 | 55 项通过 | 冷缓存、精确分支、Git 环境污染、中文快照、错误处理、超时、ZIP 等 |
| 依赖安装自动化检查 | 16 项通过 | 本机模板复用、版本校验、默认入口及路径保护 |
| Jenkins 启动器与集成代码检查 | 48 项通过 | 默认入口、后台生命周期、目录边界、系统身份和 AppData 隔离 |
| 真实命令行 Release 导出 | 通过 | `builds/self-test/20261101T094943336Z-a333b6685503434892cd75e655626a52/` |
| 真实 Jenkins Release 自测 | SUCCESS | [faf-build-self-test #3](http://127.0.0.1:8080/job/faf-build-self-test/3/) |
| Jenkins 归档与下载 | 通过 | ZIP、清单、日志已归档；通过认证接口下载到 `verification/downloaded-artifacts/` |
| 同一提交的重复构建 | 来源与配置摘要一致 | 命令行和 Jenkins 均为 `6733b8b97f016d101758ba3cd536e31238567453`，配置 SHA-256 一致 |

自测使用 `verification/fixture-repository` 内的独立测试项目，不代表正式游戏已通过全部检查。Jenkins 自测工具副本位于并列的 `verification/self-test-tool-home`，避免测试源与工具根目录重叠。

两个 Release 包都实际启动并读取随包 CSV；归档中包含 `game/faf.exe`、`game/faf.pck`、`faf_config/verification.csv` 和 `build-manifest.json`。额外 Debug 构建及网页分支交互验收未执行，不计为已通过。

## 正式游戏构建结果

[faf-windows #1](http://127.0.0.1:8080/job/faf-windows/1/) 使用已提交的 `main`，在开始构建时固定到：

```text
47b883a3609412f8e2ada4f4258475b352bdc3ae
```

冷缓存预热和正常编辑器导入均通过；随后主场景启动检查失败：

```text
ERROR: 26 resources still in use at exit (run with --verbose for details).
```

即使 Godot 退出码为 0，该 ERROR 仍使任务失败。Jenkins 正确归档了诊断日志和 failure.json，未发布成功游戏包。阶段日志位于：

```text
jenkins-home/workspace/faf-windows/builds/1/20261101T111954385Z-2fe0b7dd6a5b460996d3af79c7f2d290/logs/
```

该检查结果只对应上述固定提交。源分支的后续提交不会改变这次构建的快照或结果。构建工具不修改游戏源仓库；游戏错误需要在源项目修复并提交后再构建。

## 已解决的工具问题

- Git ZIP 快照使用显式 UTF-8 解压，避免 Windows tar 损坏中文文件名。
- Git 子进程清除继承的 GIT_* 覆盖变量，避免读取错误仓库；分支按 Ordinal 精确匹配。
- Steam 自包含编辑器在本次构建目录内运行副本，设置与缓存不会写回引擎安装目录。
- 首次导入仅在构建副本中暂时禁用编辑器插件进行预热，finally 按字节恢复原 project.godot，然后执行完整严格导入；不关闭原生扩展、不忽略 ERROR。
- 保留真实 Windows USERPROFILE、HOMEDRIVE、HOMEPATH，避免 Known Folder API 失败；Java user.home、Jenkins、AppData 和临时目录仍独立。

原始基线与诊断保留在 `verification/baseline/`、`verification/known-folder-proof/`。初次自测失败的 Jenkins 历史也保留，成功验收以 #3 为准。

## 解压换目录验证

Jenkins #3 的归档 ZIP 已通过本机认证接口下载；下载文件与服务端归档 SHA-256 相同。解压到独立目录后，从包目录之外启动 game/faf.exe，退出码为 0，无 ERROR，输出配置读取成功标记。解压后的配置摘要与构建清单一致。

证据目录：E:\workspace\faf-build\verification\relocation-2bfb478d
