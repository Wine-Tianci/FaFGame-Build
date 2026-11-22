# 2026-11-22 Basic-flow packaging validation

User authorized project functional test failures to become advisory logs. Default RUN_TESTS is false. The sole runtime gate now executes the exported game with a snapshot-only gated autoload, calls start_new_game, waits for Running + level_prepared + player/level nodes, then exits normally. Normal launches queue the probe for deletion and do not start or exit automatically.

Real main f945d1c9d3c76e1bd5cf04f1c61cd8cae9cb5563 succeeded in Debug mode:
- basic-only: faf-work/basic-main/664e67298c0348e5, ZIP 60477771 bytes, basic exit 0 and FAF_BASIC_FLOW_PASSED.
- advisory enabled: faf-work/advisory-main/f002f91003774261, 64 suites, 55 passed/9 failed, still produced ZIP 60477942 bytes and artifacts/test-report.log 130225 bytes.

Import/export, invalid source/templates/native dependencies and basic game-flow failures remain blocking. Functional assertion failure, unexpected log, timeout and native crash are caught individually and recorded without stopping packaging. Manifest checks.advisory records the exact requested/total/passed/failed/blocking=false values.

Headless export temporarily disables only the ImGui editor plugin in the disposable snapshot to prevent its exit hook from removing ImGuiRoot and triggering autoload scene reload errors. Dialogic editor remains enabled; runtime ImGui autoload/native libraries are preserved. The snapshot project file is restored after export. No game production files were modified.

Real policy fixture validated advisory failure preserves ZIP/report, default skips suites, and basic failure blocks ZIP. Real Jenkins policy acceptance passed 42 checks (verification/pa-09e095f7), including both export modes, non-blocking optional failure with three artifacts, early failure reports, migration and source preservation. Updater checks passed 7. Release ZIP extracted and all 797 payload hashes matched; installed E:/fb source matches.