// 可信的外置流水线定义：配置为 Jenkins 内联脚本，不从游戏分支加载。
pipeline {
    agent { label 'windows-godot' }
    options {
        disableConcurrentBuilds()
        skipDefaultCheckout()
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }
    parameters {
        string(name: 'BUILD_BRANCH', defaultValue: '', description: '构建分支：填写本地分支名；留空后可在构建流程中选择。只打包已提交的内容。')
        choice(name: 'BUILD_MODE', choices: ['Debug', 'Release'], description: '构建模式：Debug 为调试版，Release 为发布版。两种模式均保留 ImGui，适合内部测试。')
        string(name: 'BUILD_VERSION', defaultValue: '', description: '版本标识：选填；留空时按分支、提交短 SHA 和构建编号自动生成。')
        booleanParam(name: 'RUN_TESTS', defaultValue: true, description: '运行测试：导出前执行测试套件。关闭此项仍会执行导入、主场景和导出包启动检查。')
    }
    stages {
        stage('检查构建目录') {
            steps {
                script {
                    env.FAF_BUILD_HOME = env.FAF_BUILD_HOME ?: 'E:/workspace/faf-build'
                    env.FAF_TEMPLATE_DIRECTORY = env.FAF_TEMPLATE_DIRECTORY ?: "${env.FAF_BUILD_HOME}/runtime/templates/4.7.2.stable"
                    env.FAF_WORKSPACE_VALIDATED = 'false'
                }
                powershell encoding: 'UTF-8', script: '''
                    $ErrorActionPreference = 'Stop'
                    if ([string]::IsNullOrWhiteSpace($env:FAF_SOURCE_REPOSITORY)) { throw 'FAF_SOURCE_REPOSITORY is required in trusted node environment.' }
                    if ([string]::IsNullOrWhiteSpace($env:GODOT_BIN)) { throw 'GODOT_BIN is required in trusted node environment.' }
                    & (Join-Path $env:FAF_BUILD_HOME 'scripts/Check-JenkinsWorkspace.ps1') -BuildHome $env:FAF_BUILD_HOME -Workspace $env:WORKSPACE -SourceRepository $env:FAF_SOURCE_REPOSITORY
                '''
                script { env.FAF_WORKSPACE_VALIDATED = 'true' }
            }
        }
        stage('选择构建分支') {
            steps {
                script {
                    try {
                    env.FAF_SELECTED_BRANCH = params.BUILD_BRANCH
                    env.FAF_SELECTED_MODE = params.BUILD_MODE
                    env.FAF_SELECTED_VERSION = params.BUILD_VERSION
                    env.FAF_RUN_TESTS = params.RUN_TESTS.toString()
                    if (params.BUILD_BRANCH == '') {
                        def branchText = powershell(returnStdout: true, encoding: 'UTF-8', script: '''
                            $ErrorActionPreference = 'Stop'
                            & (Join-Path $env:FAF_BUILD_HOME 'scripts/Get-Branches.ps1') -SourceRepository $env:FAF_SOURCE_REPOSITORY -LogDirectory (Join-Path $env:WORKSPACE ('builds/' + $env:BUILD_NUMBER + '/selection-logs'))
                            exit $LASTEXITCODE
                        ''').trim()
                        if (!branchText) { error('源仓库没有可用的本地分支。') }
                        def selectedBranch
                        timeout(time: 15, unit: 'MINUTES') {
                            selectedBranch = input(message: '请选择要构建的本地分支', ok: '开始构建', parameters: [choice(name: 'BRANCH', choices: branchText, description: '仅打包该本地分支已提交的内容。')])
                        }
                        env.FAF_SELECTED_BRANCH = selectedBranch
                    } else {
                        env.FAF_SELECTED_BRANCH = params.BUILD_BRANCH
                    }
                    } catch (err) {
                        env.FAF_FAILURE_MESSAGE = err.toString()
                        throw err
                    }
                }
            }
        }
        stage('检查、测试并导出 Windows 包') {
            steps {
                powershell encoding: 'UTF-8', script: '''
                    $ErrorActionPreference = 'Stop'
                    & (Join-Path $env:FAF_BUILD_HOME 'scripts/Check-JenkinsWorkspace.ps1') -BuildHome $env:FAF_BUILD_HOME -Workspace $env:WORKSPACE -SourceRepository $env:FAF_SOURCE_REPOSITORY | Out-Null
                    if ($env:BUILD_NUMBER -notmatch '^[0-9]+$') { throw 'Invalid Jenkins BUILD_NUMBER.' }
                    if ($env:FAF_SELECTED_MODE -cnotin @('Debug','Release')) { throw 'Invalid build mode.' }
                    . (Join-Path $env:FAF_BUILD_HOME 'scripts/Build-Workspace.ps1')
                    $layout = Get-BuildWorkspaceLayout $env:FAF_BUILD_HOME $env:WORKSPACE $env:BUILD_NUMBER $env:FAF_SOURCE_REPOSITORY
                    $buildRoot = $layout.dataRoot
                    $template = Join-Path $env:FAF_TEMPLATE_DIRECTORY ('windows_' + $env:FAF_SELECTED_MODE.ToLowerInvariant() + '_x86_64.exe')
                    & (Join-Path $env:FAF_BUILD_HOME 'scripts/Build-Windows.ps1') -SourceRepository $env:FAF_SOURCE_REPOSITORY -BranchName $env:FAF_SELECTED_BRANCH -GodotPath $env:GODOT_BIN -BuildRoot $buildRoot -BuildMode $env:FAF_SELECTED_MODE -Version $env:FAF_SELECTED_VERSION -BuildNumber $env:BUILD_NUMBER -RunTests:([bool]::Parse($env:FAF_RUN_TESTS)) -ExportTemplate $template -RunRecordPath $layout.runRecord
                    exit $LASTEXITCODE
                '''
            }
        }
        stage('归档构建产物') {
            steps {
                powershell encoding: 'UTF-8', script: '''
                    $ErrorActionPreference = 'Stop'
                    & (Join-Path $env:FAF_BUILD_HOME 'scripts/Copy-BuildArtifacts.ps1') -BuildHome $env:FAF_BUILD_HOME -Workspace $env:WORKSPACE -BuildNumber $env:BUILD_NUMBER -SourceRepository $env:FAF_SOURCE_REPOSITORY
                    exit $LASTEXITCODE
                '''
                archiveArtifacts artifacts: "builds/${env.BUILD_NUMBER}/artifacts/*.zip", fingerprint: true
                archiveArtifacts artifacts: "builds/${env.BUILD_NUMBER}/artifacts/*.json", fingerprint: true
            }
        }
    }
    post {
        unsuccessful {
            script {
                if (env.FAF_WORKSPACE_VALIDATED == 'true') {
                    env.FAF_BUILD_RESULT = currentBuild.currentResult
                    powershell encoding: 'UTF-8', script: '''
                        $ErrorActionPreference = 'Stop'
                        & (Join-Path $env:FAF_BUILD_HOME 'scripts/Check-JenkinsWorkspace.ps1') -BuildHome $env:FAF_BUILD_HOME -Workspace $env:WORKSPACE -SourceRepository $env:FAF_SOURCE_REPOSITORY | Out-Null
                        . (Join-Path $env:FAF_BUILD_HOME 'scripts/Build-Workspace.ps1')
                        $layout = Get-BuildWorkspaceLayout $env:FAF_BUILD_HOME $env:WORKSPACE $env:BUILD_NUMBER $env:FAF_SOURCE_REPOSITORY
                        & (Join-Path $env:FAF_BUILD_HOME 'scripts/New-BuildFailureReport.ps1') -BuildRoot $layout.archiveRoot -SourceRepository $env:FAF_SOURCE_REPOSITORY -BranchName $env:FAF_SELECTED_BRANCH -BuildMode $env:FAF_SELECTED_MODE -Version $env:FAF_SELECTED_VERSION -BuildNumber $env:BUILD_NUMBER -Result $env:FAF_BUILD_RESULT -PipelineMessage $env:FAF_FAILURE_MESSAGE -RunRecordPath $layout.runRecord -ExpectedBuildRoot $layout.dataRoot
                        exit $LASTEXITCODE
                    '''
                    archiveArtifacts artifacts: "builds/${env.BUILD_NUMBER}/failure-report.log"
                }
            }
        }
    }
}
