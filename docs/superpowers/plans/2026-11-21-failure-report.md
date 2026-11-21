# Single Failure Report Implementation Plan

**Goal:** One readable failure-report.log per failed build/startup; successful Jenkins builds show only delivery ZIP and manifest.

**Architecture:** A shared PowerShell 5.1 reporter streams summary/context/stack and direct-child log/process records into UTF-8 text. Build and launcher catch blocks invoke it while preserving original failures. A trusted Jenkins post step selects only the current build's validated run and publishes one consolidated report.

**Tech Stack:** Windows PowerShell 5.1, Jenkins declarative Pipeline, existing portable bundling/manifest.

- [x] Write and run failing tests/Failure-Report.Tests.ps1 for full aggregation, encoding, safe boundaries, missing/empty logs, redaction, original exception preservation, pre-run fallback and startup logging.
- [x] Implement scripts/Failure-Report.ps1 and scripts/New-BuildFailureReport.ps1; connect Build-Windows.ps1 and Start-Portable.ps1 (which wraps Start-Jenkins failures); retain branch-query exceptions via Get-Branches.ps1; change Jenkinsfile unsuccessful archive behavior. Run targeted tests and Jenkins/portable regression checks.
- [x] Test real Jenkins success and intentionally failing Godot test, asserting success has two artifacts and failure one report with exact error, process record and stack. Test missing-dependency portable startup and pre-run branch query failure. Keep isolated test instances and source fixtures.
- [x] Independent code review; fix actionable issues. Update user docs, build fresh dist/faf-build-portable-20261121.zip and update ZIP, validate ZIP hashes/clean contents, apply approved update to stopped E:/fb deployment, preserve user configuration/history. Workspace has no Git repository; no commit/worktree actions.

Final verification: 23 reporter checks, 7 updater checks (also run from the extracted update ZIP), 22 portable checks, 48 existing Jenkins launcher checks, and 31 real Jenkins acceptance checks passed. Full ZIP extracted with all 793 payload hashes verified; no machine state included. Installed E:/fb scripts match the verified release and its updated manifest. Both ZIP checksum sidecars match. Review approved after fixing early-report preservation and branch-query launch exception capture.
