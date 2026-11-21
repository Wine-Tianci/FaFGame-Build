# FAF 打包问题与修复记录

整理日期：2026-11-07。

本文记录本次从 Jenkins 构建失败到完整 Debug 打包成功的排查过程、最终采用的修复及验证结果。早期诊断中的候选方案不等于最终实现，以本文的“最终处理”为准。

## 1. 最终结果

| 项目 | 结果 |
| --- | --- |
| 游戏仓库 | `E:\workspace\faf-game` |
| 构建工具 | `E:\workspace\faf-build` |
| 修复分支 | `test_build_xtc_1105` |
| 最终提交 | `c6b94cccbc412571e2edd1adc95971938c44c406`，已推送 |
| 构建模式 | Windows x64 Debug |
| 脚本测试 | 33 项通过 |
| 必跑额外场景 | `item_system_test_runner.tscn` 通过 |
| 构建工具回归检查 | 55 项通过 |
| Windows 导出 | 通过，生成 EXE/PCK |
| 导出包启动与退出检查 | 通过 |
| 同目录存档 | 保存、独立进程重新读取、真实游戏重启、移动文件夹后读取通过 |
| 损坏存档保护 | 报错退出，原玩家存档未被覆盖 |

最终产物：[faf-test_build_xtc_1105-debug.zip](/E:/workspace/faf-build/builds/confirmed15/20261107T132543507Z-362dddcf4f8b45f393be7a453065ffba/artifacts/faf-test_build_xtc_1105-debug.zip)，约 56 MiB。

ZIP SHA-256：

```text
7DE4A3E1A0B5AD958AF1AB5EE25B1548596C7F7055C2F7C36001B0E1492AB9DD
```

本次成功结果来自命令行执行的完整构建流水线；Jenkins 任务同样调用外置 `Build-Windows.ps1`。本次尝试自动触发 Jenkins 时，本机接口认证不可用，因此没有据此宣称 Jenkins 页面已经产生新的成功构建记录。完整命令行构建和 ZIP 已独立验证。

用户要求暂不处理 `main` 后，后续修复仅提交、推送到测试分支，最终修复未合并到 `main`。

## 2. 流水线如何判定失败

主要顺序：

```text
固定本地分支提交 SHA
  → 导出独立源码快照
  → 引擎与导出模板检查
  → 编辑器导入
  → 主场景启动检查
  → 脚本测试及必跑测试场景
  → Windows 导出
  → 自动启动导出的 EXE
  → 清理验证生成的存档
  → 写入构建清单并生成 ZIP
```

Godot 进程满足以下任一条件，就会阻断后续步骤：

- 退出码非零。
- 执行超时。
- 标准输出、标准错误或该进程的 Godot 日志出现以 `ERROR:`、`SCRIPT ERROR:` 开头的行。

因此，退出码为 0 或测试打印 `tests passed`，不能抵消日志中的错误。

应区分两类失败：

- **导出之前失败**：未进入 Windows 导出，例如测试脚本无法编译。
- **导出后运行检查失败**：EXE/PCK 已生成，但自动启动或退出时出现错误，因此最终 ZIP 不会被接受。

## 3. 历史构建为什么连续失败

| 构建 | 使用内容 | 直接失败位置 |
| --- | --- | --- |
| #2、#3 | `main` 的 `bb8592b` | 主场景退出时 26 个资源仍在使用 |
| #4 | 仍是 `bb8592b` | Dialogic 修复未提交，快照仍包含旧代码 |
| #5 | `7bba751` | 主场景已通过，采集配置测试找不到 `ConfigTableManager` |
| #6 | `c6018db` | 采集配置测试已通过，下一项采集管理器测试失败 |
| #7 | `2f4f12e` | 前三项测试通过，采集对象测试及其预加载依赖出现 Autoload 编译错误 |

流水线通过 `git archive` 读取所选**本地分支的已提交快照**，不包含工作区未提交的修改，也不自动拉取远程更新。Jenkins 在本机可以读取本地新提交；远程推送是否成功是另一个状态，需要分别报告。

## 4. 按项处理的问题与最终修复

### 4.1 Dialogic 初始化产生无人管理的节点

**现象：** 主场景检查退出时出现：

```text
WARNING: 60 ObjectDB instances were leaked at exit
ERROR: 26 resources still in use at exit
```

**原因：** `DialogicGameHandler.gd` 的 18 个子系统属性使用 `preload(...).new()` 初始化，但 getter 返回的是后来由 `add_subsystem()` 创建并加入场景树的另一组节点。初始化产生的第一组节点没有父节点，也没有手动释放，连带占用了脚本、背景和立绘等资源。

`Node` 不依靠引用计数回收；清空变量不等于释放节点。父节点释放会释放其子节点，无父节点的节点需要明确释放。

**最终处理：** 去掉多余的 `.new()`，用脚本常量保留子系统类型，通过 getter 返回实际安装的节点。同步修改自动生成模板，避免编辑器重新生成旧写法。

修改文件：

- `faf_game/addons/dialogic/Core/DialogicGameHandler.gd`
- `faf_game/addons/dialogic/Core/DialogicUtil.gd`
- 新增子系统生命周期回归测试及 UID。

**范围：** 修改游戏插件代码，保持实际子系统安装、类型及访问方式。

**验证：** 旧代码的回归用例在释放 handler 后留下 24 个孤立节点；修复后无新增孤立节点。编辑器导入后再次运行主场景，原来的资源退出错误消失。

### 4.2 测试使用 `SceneTree --script`，编译早于 Autoload 注册

**现象：** `Identifier not found: ConfigTableManager`、`GameManager`、`UtilsManager` 等；预加载业务脚本也出现级联编译错误。

**原因：** 这些测试以自定义 `SceneTree` 主循环脚本直接启动，脚本及预加载依赖需要提前编译，此时项目的 Autoload 名称尚未注册。把配置加载调用放在 `_init()` 首行也不能解决编译阶段的问题。

**最终处理：** 需要项目单例的测试改为 `extends Node`、在 `_ready()` 执行，由场景测试入口在 Autoload 初始化完成后延迟加载。同时把 `root`、`quit()`、帧信号等调用调整为对应的 `get_tree()` 调用。

先后处理了采集配置、采集管理器、采集对象、采集持久化、采集工具、调试管理器、钓鱼管理器、魔法采集命中、玩家物品提示及提示相关测试。

每个测试启动独立 Godot 进程，前一个测试加载的单例不会留给后一个测试。

**范围：** 测试入口与测试环境，不改变采集、钓鱼、伤害等游戏规则。

### 4.3 采集工具测试无法推断管理器类型

**现象：** `Cannot infer the type of "collection_manager" variable`。

**最终处理：** 给 `_get_or_create_collection_manager()` 声明返回类型 `Node`，并完成上述入口迁移。保持工具伤害断言和业务实现。

### 4.4 重名 CSV 的负面测试触发严格错误检查

**现象：** 测试断言通过、退出码为 0，但出现：

```text
ERROR: Duplicate config table SameName skipped
```

**原因：** 测试故意创建同名 CSV 来验证重复表被跳过，生产配置管理器按设计报告错误。流水线不能仅凭这条输出判断它是否属于预期负面用例。

**最终处理：** 新增 `config_table_duplicate_worker.gd`，将负面用例放入专用子进程。父测试捕获 stdout/stderr，子进程使用独立日志，父测试同时确认：

- 子进程退出码为 0。
- 恰好存在一条预期的重名错误，没有额外 `ERROR` 或 `SCRIPT ERROR`。
- 返回结果显示保留的是第一份 CSV。

任何额外错误、缺失结果、错误数据或非零退出仍使父测试失败。

**范围：** 测试及辅助脚本。未降低生产配置管理器的错误级别，未修改流水线的严格错误规则。

**验证：** 注入额外子进程错误后，父测试退出码为 1；恢复正常用例后通过。

### 4.5 DebugManager 测试替身与真实单例冲突

**原因：** 场景测试启动后，真实 `/root/CollectionManager` 已存在，测试替身不能直接占用同名路径；原替身还返回了无人释放的 `Node2D`。

**最终处理：** 在同步测试期间临时重命名真实单例，让替身接收按路径查找的调用；结束后恢复原单例名称并验证恢复结果。测试不使用返回节点，替身改为返回 `null`。

**范围：** 只改 `run_debug_manager_tests.gd`，不改生产 DebugManager 或采集管理器。

### 4.6 玩家物品提示测试遗留 TestBag

**现象：** 入口修正后断言通过，但退出出现 4 个资源仍在使用。

**原因：** 三个用例各自创建的 `TestBag` 没有加入父子树，也没有释放。

**最终处理：** 在三个用例结束时明确释放对应 `TestBag`，保留原物品添加和提示断言。

**范围：** 测试文件。验证后错误和泄漏日志均为 0。

### 4.7 任务系统测试的准备条件不足

两个失败断言：

1. 尚无可提交任务时，就要求 NPC 显示 `?`。
2. 候选列表只有 B001–B003，却在释放名额后要求接取未提供的 B004。

**最终处理：**

- 在标记用例中先完成未跟踪的 B003，再检查可提交标记优先级。原有跟踪断言保持不变。
- 保留默认三个候选的断言；为“最多持有三个任务、放弃后释放名额”子用例显式生成四个候选，并验证 B004 确实在候选中。

**范围：** 只补齐 `run_quest_system_tests.gd` 的测试数据，不改标记优先级、持有上限或悬赏刷新规则。

### 4.8 提示配置测试错误释放 RefCounted

**现象：** `Can't free a RefCounted object`。

**原因：** `TipsRequest`、`TipsStyle` 继承 `RefCounted`，不应像 `Node` 一样调用 `free()`。

**最终处理：** 删除两处错误释放，使用引用计数回收，同时调整测试入口。

### 4.9 样式和游戏措辞不作为当前测试版的构建门槛

提示层旧测试存在入口、类型推断及样式断言问题。诊断还发现长文本高度估算与真实字体不同、根窗口缩放不等于逻辑视口改变。但用户明确表示当前测试版的样式会更替，这些设计层面的断言不需要验证。

**最终处理：**

- 提示层仅保留初始化、请求接收、忙碌拒绝、容量边界、替换旧请求等最小运行检查。
- 不再以像素位置、排列外观、长文本裁剪和缩放样式阻断构建。
- 提示管理器删除固定游戏措辞断言，文字替换功能使用专用固定测试模板，测试结束恢复配置缓存。

**范围：** 测试代码。最终没有实施提示字体高度计算的业务候选修改，也没有纳入原本未提交的 `ui/tips/tips_layer.gd` 改动。

### 4.10 额外采集回归场景退出必跑列表

**现象：** 32 项脚本测试全部通过后，额外场景仍因固定动画等待时间、缺少 `GameManager.game` 上下文等测试环境问题失败。

曾在诊断副本验证过修复夹具的方案，但用户判断该场景不需要作为当前打包门槛。

**最终处理：** 从 `faf-build/scripts/Godot-Checks.ps1` 的额外必跑场景列表中移除 `collection_runtime_regression.tscn`，保留游戏仓库中的场景供手动运行。同步修改构建工具测试，验证该场景不会自动执行。

**范围：** 本机构建工具脚本及其测试，不修改游戏场景或业务。32 项脚本、物品系统场景、主场景和导出包检查继续保留。

### 4.11 Phantom Camera 的编辑器依赖进入导出运行时

**现象：** Windows 导出已生成 EXE/PCK，但自动运行 EXE 时出现 `EditorInterface` 未定义。

**原因：** 相机 host 在函数中使用 `preload()` 加载编辑器取景场景。`preload()` 在脚本解析时加载依赖，已有的运行时条件判断尚未执行，因此导出程序仍解析了依赖 `EditorInterface` 的脚本。

**最终处理：** 将 `_show_viewfinder_in_play()` 中的一处 `preload()` 改为 `load()`。导出程序先经过已有检查并返回，不加载编辑器界面；带编辑器能力的进程通过条件后仍可加载它。

**范围：** 测试目录之外的游戏插件脚本 `phantom_camera_host.gd`。没有移除运行时相机，也没有改变相机跟随、切换等游戏逻辑。

### 4.12 导出游戏无法按工程路径保存状态

**现象：** 相机错误解决后，退出时仍出现 `Cannot save file 'res://data/resources/…'`，涉及背包、手持栏、魔法菜单、玩家及游戏资源。

**原因：** 编辑器中的 `res://` 指向可写工程文件；导出后这些资源在 PCK 中，无法原地修改包内文件。安装目录中的松散文件是否可写是另一个条件，不能把写入工程资源的方式直接当作通用运行时存档方式。

最初讨论过 `user://`，用户最终确认采用 **EXE 同目录的便携存档**。

**最终处理：**

- 导出游戏将数据写入 `OS.get_executable_path().get_base_dir()/saves/`。
- `player.tres` 包含玩家、背包、手持和魔法菜单状态；`game.tres` 包含游戏日期及任务状态。
- 启动优先读取已有存档；首次运行使用随包默认资源。
- 玩家恢复发生在子 UI 进入树之前，背包、手持和魔法菜单绑定到恢复后的资源。
- 存档嵌入其拥有的状态子资源，不把旧安装目录作为外部依赖；不可变脚本和魔法资源继续使用 `res://` 引用。
- 背包和手持仍保存 ID/数量记录，不把运行时 Item 实例直接写入存档。
- 先写临时文件，保留旧文件备份，再替换正式文件；失败明确报错。
- 根存档或库存恢复失败时，不覆盖原玩家存档。
- 编辑器继续保留原有工程资源保存方式。

**真实业务修改：**

- [resource_manager.gd](/E:/workspace/faf-game/faf_game/autoload/resource_manager/resource_manager.gd)：便携保存、加载、快照及备份。
- [player.gd](/E:/workspace/faf-game/faf_game/features/character/player/player.gd)：启动恢复、UI 绑定、退出保存与失败保护。
- [game.gd](/E:/workspace/faf-game/faf_game/app/game/game.gd)：游戏状态恢复和保存。

新增资源往返测试，以及仅用于导出验证的测试场景程序。

### 4.13 打包不能带上运行验证生成的进度

**原因：** 自动启动导出 EXE 会在临时包旁产生 `saves`。直接压缩整个包会把验证进度一起交付。

**最终处理：** `Build-Windows.ps1` 在包启动检查成功后，仅清理本次新包生成的 `game/saves`，再压缩。清理前检查绝对目标属于该包，拒绝重解析点；检查失败时保留诊断数据。

构建工具替身程序模拟生成存档，新增 ZIP 不包含 `game/saves/` 的回归断言。55 项工具检查通过。

### 4.14 验证环境与网络问题

- **诊断目录过长：** 深层验证目录触发 Windows/.NET 路径长度限制。改用较短的 `builds/check13`、`v15` 等目录后完成验证，不据此修改游戏逻辑。
- **导出模板拒绝 `--scene`：** 为跨进程写入/读取测试单独导出固定测试主场景程序，未放宽正式导出模板的路径覆盖限制，正式包主场景保持现状。
- **GitHub 间歇性连接重置或超时：** 每次区分本地提交与远程推送状态。部分请求使用命令级 Schannel/HTTP1.1 设置并重试，未强制推送，未永久更改全局网络配置。最终测试分支已推送到 `c6b94cc`。
- **Jenkins 本机认证：** 自动触发接口认证不可用，未重置账号或泄露凭据。成功构建证据来自完整命令行流水线。

## 5. 当前包的目录和使用方式

```text
faf-test_build_xtc_1105-debug/
  build-manifest.json
  faf_config/
  game/
    faf.exe
    faf.pck
    必要原生库文件
    saves/                    # 运行后自动生成，交付 ZIP 中没有
      player.tres
      player.backup.tres
      game.tres
      game.backup.tres
```

完整解压后运行 `game/faf.exe`。存档在 EXE 旁，不是默认 C 盘 `user://` 目录。拷贝游戏时一起保留 `game/saves`；这个方案要求该文件夹具有写权限。

本次只覆盖已确认的玩家、库存、魔法选择和游戏/任务状态存档。没有新增多存档槽 UI，也没有据此宣称全部世界资源持久化均已完成。

## 6. 最终验证证据

| 验证 | 结果 |
| --- | --- |
| 编辑器导入、主场景 | 通过 |
| 33 项脚本测试与物品系统场景 | 通过 |
| 55 项构建工具检查 | 通过 |
| Debug EXE/PCK 导出 | 通过 |
| 首次运行及退出写入 | 通过 |
| 专用导出程序在独立进程中保存与读取 | 通过 |
| 正式游戏主场景重启后再次读取 | 通过 |
| 整个游戏文件夹移动后运行与恢复 | 通过 |
| 存档写入未修改 PCK 字节 | 通过 |
| 损坏玩家存档报错，原文件未被覆盖 | 通过 |
| ZIP 包含 EXE/PCK/配置，不含验证存档 | 通过 |

证据位置：

- [最终构建清单](/E:/workspace/faf-build/builds/confirmed15/20261107T132543507Z-362dddcf4f8b45f393be7a453065ffba/artifacts/build-manifest.json)
- [最终验证汇总](/E:/workspace/faf-build/verification/build-audit-20261107-0f5bc9cb/step-15-portable-saves/result.json)
- [最终构建日志目录](/E:/workspace/faf-build/builds/confirmed15/20261107T132543507Z-362dddcf4f8b45f393be7a453065ffba/logs)
- [存档代码复核](/E:/workspace/faf-build/verification/build-audit-20261107-0f5bc9cb/step-15-portable-saves/review.md)

正常警告不等于构建失败。验证中仍存在部分 UID 回退、未识别 CSV 枚举字段、UI 锚点等警告；本次未扩大范围去清理所有警告，也未将它们描述为已修复。

## 7. 提交对应关系

| 提交 | 内容 |
| --- | --- |
| `7bba751` | Dialogic 子系统资源泄漏与生命周期测试 |
| `c6018db` | 采集配置测试入口 |
| `2f4f12e` | 采集管理器测试入口 |
| `ef49b9c` | 采集对象测试入口 |
| `6b1c323` | 采集持久化测试入口 |
| `07d03e8` | 采集工具测试入口和类型声明 |
| `3c4d6cc` | 配置重名负面测试子进程隔离 |
| `aa57a14` | DebugManager 替身与生命周期 |
| `48e329c` | 钓鱼管理器测试入口 |
| `6c2c02b` | 魔法采集命中测试入口 |
| `5ba00a1` | 玩家物品提示入口及 TestBag 清理 |
| `0c63a28` | 任务标记与悬赏名额测试准备数据 |
| `fe57f6a` | 提示配置入口与 RefCounted 清理 |
| `1b3c512` | 提示层最小运行检查 |
| `755c621` | 提示管理器入口与独立文案模板 |
| `db38c21` | Phantom Camera 编辑器场景延迟加载 |
| `c6b94cc` | 同目录存档保存、恢复与验证 |

`faf-build` 当前是独立本机工具目录，不是本次游戏仓库的 Git 提交内容。必跑场景调整和验证存档清理已更新本机脚本，不能仅通过拉取游戏测试分支获得这些构建工具改动。

## 8. 过程中的诊断副作用

早期直接运行真实源项目的检查触发旧游戏退出保存，改写了 `faf_game/data/resources/game/game_resource.tres`。当时只记录了哈希，没有保存检查前内容，未能精确还原；没有用 Git 版本覆盖用户的既有开发数据。该资源文件未纳入本轮修复提交。

随后所有游戏运行和打包验证改在独立快照、导出副本进行。便携存档实现阶段对既有修改作了备份、文件哈希和暂存索引检查，确认这些既有修改没有再被改写。不能把这一结果误述为整个排查过程从未产生过副作用。

## 9. 再次构建

Jenkins 的 `BUILD_BRANCH` 选择 `test_build_xtc_1105`，保持 `RUN_TESTS=true`。先确认本机该分支已更新到需要构建的提交，且外置工具脚本包含本次本机构建调整。

命令行可执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File 'E:/workspace/faf-build/scripts/Build-Windows.ps1' `
  -SourceRepository 'E:/workspace/faf-game' `
  -BranchName 'test_build_xtc_1105' `
  -GodotPath 'E:/Game/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe' `
  -BuildRoot 'E:/workspace/faf-build/builds' `
  -BuildMode Debug `
  -Version 'test_build_xtc_1105' `
  -BuildNumber 'manual' `
  -RunTests `
  -TimeoutSeconds 120 `
  -ExportTemplate 'E:/workspace/faf-build/runtime/templates/4.7.2.stable/windows_debug_x86_64.exe'
```

失败时先看当前运行目录的 `failure.json`、失败阶段的 `.stderr.log` 与 `.process.json`；成功时查看 `artifacts/*.zip` 和 `build-manifest.json`。不要把诊断导出、旧提交验证或缺少完整测试的结果误标为完整构建成功。
