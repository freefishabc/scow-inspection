# scowctl 巡检命令行流程

本文档把巡检流程写成可按顺序执行的命令行模板。所有 `<...>` 都是运行时变量，必须来自前序 `scowctl` 返回值或用户显式输入，不得猜测。

## 0. 运行约定

- 平台查询、创建、状态检查全部使用 `scowctl`。
- 只有应用/开发机真实访问验证阶段允许使用 `curl` 访问由 `scowctl` 返回的真实入口。
- Windows 环境不要使用 PowerShell；使用不会改写 JSON、引号、`$PATH` 字面量的命令环境。
- 输出记录中要保存每条关键命令、参数来源、结果；不得输出明文 `<AUTH_SECRET>`。
- AI 开发机（devHost）进入排队状态时，必须继续轮询到 `RUNNING` 后再做连通性与真实入口验证；若排队超过 30 秒仍未进入 `RUNNING`，则记录为本轮跳过连接验证。
- 脚本支持 `-v` 与 `-vv`：`-v` 打印步骤级日志，`-vv` 在步骤级日志基础上同步输出每条命令的 stdout/stderr，同时仍保留落盘报告与原始输出。

## 1. 运行时变量表

| 变量 | 来源 | 用途 |
|---|---|---|
| `<SCOW_BASE_URL>` | `scowctl profile show` 的 `baseUrl` | 生成 HTTP 访问入口 |
| `<SCOW_HOST>` | 从 `<SCOW_BASE_URL>` 提取 host，例如 `10.100.156.82` | `NO_PROXY` 与 curl 入口 |
| `<AUTH_USER>` | 未登录时由用户输入 `--auth-user` | `scowctl login`、HTTP 认证头来源 |
| `<AUTH_SECRET>` | 未登录时由用户输入 `--auth-secret` | `scowctl login`、HTTP 认证 token 来源；禁止明文输出 |
| `<SCOW_USER_ID>` | `/api/getUserInfo` 或 `/ai/api/auth/userInfo`；也可来自已登录 profile 的 `authUser/identityId` | `userId` 参数与 HTTP 访问认证头 |
| `<SCOW_API_AUTH_TOKEN>` | `/ai/api/auth/userInfo` 返回的 `token`，或用户提供的 `<AUTH_SECRET>` 派生来源 | curl 访问 SCOW proxy 时的 `x-scow-api-auth-token` |
| `<PORTAL_VISIBLE_CLUSTERS>` | `/api/getUserAssociatedClusterIds userId=<SCOW_USER_ID>` | 默认门户可见集群 |
| `<AI_DEFINED_CLUSTERS>` | `/ai/api/config/scowCluster` | AI 集群定义 |
| `<ACTIVATED_CLUSTERS>` | `/api/getClustersRuntimeInfo` | 默认运行时激活集群 |
| `<AI_CLUSTERS>` | `<AI_DEFINED_CLUSTERS>` | AI 分支目标 |
| `<HPC_CLUSTERS>` | `<PORTAL_VISIBLE_CLUSTERS> - <AI_DEFINED_CLUSTERS>` | HPC 分支目标 |
| `<CLUSTER>` | 当前循环中的集群 | 各分支命令参数 |
| `<ACCOUNT_NAME>` | HPC: `/api/job/getAccounts`；AI: 历史会话参数或真实可用接口 | 提交作业/应用、查分区 |
| `<PARTITION>` | HPC: `/api/job/getAvailablePartitionsForCluster`；AI: `/ai/api/config/cluster/availablePartitions` | 提交作业/应用 |
| `<QOS>` | 历史模板/历史会话/分区返回值 | 提交作业/应用，可为空 |
| `<HOME_PATH>` | HPC: `/api/file/getHome`；AI: `/ai/api/file/homeDir` 的 `path` | 文件探针、`WORK_DIR` |
| `<PROBE_FILE>` | 基于 `<HOME_PATH>` 生成的唯一路径，如 `<HOME_PATH>/.scowctl_probe_<TIMESTAMP>.txt` | 文件探针 |
| `<TIMESTAMP>` | 当前时间或唯一后缀 | 生成本轮资源名 |
| `<APP_ID>` | HPC: `/api/app/listAvailableApps`；AI: `/ai/api/allAvailableAppsFromAllClusters` | 应用会话创建 |
| `<APP_NAME>` | 应用列表或历史会话返回值 | 应用会话创建 |
| `<TEMPLATE_ID>` | `/api/job/listJobTemplates` 返回值 | HPC 作业参数复用 |
| `<JOB_ID>` | 作业/应用创建返回值，或历史会话列表真实记录 | 查询状态、连通性、清理 |
| `<SESSION_ID>` | 应用会话创建后列表返回值，或历史会话列表真实记录 | 获取参数、connect、清理复核 |
| `<REAL_BODY>` | 由 help + 历史参数 + 实时接口返回值组成的 JSON | POST 创建请求 |
| `<WORK_DIR>` | AI: `submissionParameters.envVariables.WORK_DIR`；否则 `/ai/api/file/homeDir` 的 `path` | AI 应用 `envVariables` 必填 |
| `<HOST>` | `connectToApp` 或 AI `connect` 返回值 | HTTP 入口 |
| `<PORT>` | `connectToApp` 或 AI `connect` 返回值 | HTTP 入口 |
| `<PASSWORD>` | `connectToApp` 或 AI `connect` 返回值 | 应用登录表单 |
| `<PROXY_TYPE>` | `connectToApp` 或 AI `connect` 返回值 | 判断入口拼法 |
| `<ENTRY_URL>` | 由真实连接返回值与 `<SCOW_BASE_URL>` 组成 | curl 访问入口 |
| `<LOGIN_BASE>` | 真实登录页 HTML 中 hidden input `base` 的 value | 登录 POST 表单；可能为 `.` |
| `<LOGIN_HREF>` | 真实登录页 HTML 中 hidden input `href` 的 value | 登录 POST 表单；可能为空字符串，不能自行改成入口 URL |
| `<IMAGE_ID>` | `/ai/api/images` 创建返回值或镜像列表返回值 | AI 镜像清理 |

## 2. 前置检查与登录

```bash
scowctl --help
scowctl api --help
scowctl profile show
```

如果未登录，提示用户输入 `<AUTH_USER>` 和 `<AUTH_SECRET>`，然后执行：

```bash
scowctl login --auth-user <AUTH_USER> --auth-secret <AUTH_SECRET>
```

刷新 OpenAPI 并取当前用户：

```bash
scowctl api refresh --verbose
scowctl api GET /api/getUserInfo
scowctl api GET /ai/api/auth/userInfo
scowctl api GET /mis/api/dashboard/status
```

赋值：

```text
<SCOW_BASE_URL> = profile.show.baseUrl
<SCOW_HOST> = host(<SCOW_BASE_URL>)
<SCOW_USER_ID> = userInfo.identityId 或 userInfo.user.identityId
<SCOW_API_AUTH_TOKEN> = /ai/api/auth/userInfo 返回的 token，或本轮登录认证来源
```

若权限不足、无法登录、OpenAPI 仍不可用：输出 `blocked` 并停止。

## 3. 集群分类

```bash
scowctl api GET /api/getUserAssociatedClusterIds userId=<SCOW_USER_ID>
scowctl api GET /ai/api/config/scowCluster
scowctl api GET /api/getClustersRuntimeInfo
```

赋值：

```text
<PORTAL_VISIBLE_CLUSTERS> = /api/getUserAssociatedClusterIds 返回值
<AI_DEFINED_CLUSTERS> = /ai/api/config/scowCluster 的 key 集合
<ACTIVATED_CLUSTERS> = /api/getClustersRuntimeInfo 中已激活集群
<AI_CLUSTERS> = <AI_DEFINED_CLUSTERS>
<HPC_CLUSTERS> = <PORTAL_VISIBLE_CLUSTERS> - <AI_DEFINED_CLUSTERS>
```

## 4. HPC 分支命令

对每个 `<CLUSTER>` in `<HPC_CLUSTERS>` 执行。

### 4.1 HPC 只读检查

```bash
scowctl api GET /api/dashboard/getClusterInfo clusterId=<CLUSTER>
scowctl api GET /api/dashboard/getClusterNodesInfo cluster=<CLUSTER>
scowctl api GET /api/notification/getUnreadMessages
scowctl api GET /api/job/getAccounts cluster=<CLUSTER>
```

赋值：

```text
<ACCOUNT_NAME> = /api/job/getAccounts 返回的可用账户
```

继续查询分区：

```bash
scowctl api GET /api/job/getAvailablePartitionsForCluster cluster=<CLUSTER> accountName=<ACCOUNT_NAME>
```

赋值：

```text
<PARTITION> = 分区返回值中的可用分区
<QOS> = 分区或历史参数中的可用 QoS，可为空
```

若 `getClusterInfo` 返回 `NOT_EXIST_IN_ACTIVATED_CLUSTERS`，记录后跳过当前集群 HPC 创建类步骤。

### 4.2 HPC 文件探针

```bash
scowctl api GET /api/file/getHome cluster=<CLUSTER>
```

赋值：

```text
<HOME_PATH> = getHome 返回路径
<PROBE_FILE> = <HOME_PATH>/.scowctl_probe_<TIMESTAMP>.txt
```

执行并清理：

```bash
scowctl api POST /api/file/createFile --body '{"cluster":"<CLUSTER>","path":"<PROBE_FILE>"}'
scowctl api GET /api/file/fileExist cluster=<CLUSTER> path=<PROBE_FILE>
scowctl api GET /api/file/getFileMetadata cluster=<CLUSTER> path=<PROBE_FILE>
scowctl api DELETE /api/file/deleteFile cluster=<CLUSTER> path=<PROBE_FILE>
scowctl api GET /api/file/fileExist cluster=<CLUSTER> path=<PROBE_FILE>
```

删除失败或复核仍存在：最终不得为 `pass`。

### 4.3 HPC 桌面

先查询现有桌面：

```bash
scowctl api GET /api/desktop/listDesktops cluster=<CLUSTER>
```

若继续做桌面创建，先查 help，再使用 `listDesktops` 返回的真实 `host` 作为 `loginNode`，使用当前实例支持的 `remoteControlTool` 与 `wm` 创建、复核、关闭：

```bash
scowctl api help POST /api/desktop/createDesktop
scowctl api help POST /api/desktop/launchDesktop
scowctl api help POST /api/desktop/killDesktop
scowctl api POST /api/desktop/createDesktop --body '{"cluster":"<CLUSTER>","desktopName":"scowctl-inspect-desktop-<TIMESTAMP>","loginNode":"<LOGIN_NODE>","remoteControlTool":"vnc","wm":"xfce"}'
scowctl api GET /api/desktop/listDesktops cluster=<CLUSTER>
scowctl api POST /api/desktop/killDesktop --body '{"cluster":"<CLUSTER>","loginNode":"<LOGIN_NODE>","id":<DESKTOP_ID>,"displayId":<DISPLAY_ID>}'
scowctl api GET /api/desktop/listDesktops cluster=<CLUSTER>
```

赋值：

```text
<LOGIN_NODE> = listDesktops 返回的 host，例如 10.100.156.83
<DESKTOP_ID>, <DISPLAY_ID> = createDesktop 后再次 listDesktops 返回的新桌面记录
```

`createDesktop` 可能直接返回 VNC `host/port/password`，但关闭仍需要 `listDesktops` 中的 `id/displayId/loginNode`。清理后新建桌面应消失或 `isActive=false`。

### 4.4 HPC 最小作业

先查接口和历史模板：

```bash
scowctl api help POST /api/job/submitJob
scowctl api help DELETE /api/job/cancelJob
scowctl api GET /api/job/listJobTemplates clusters=<CLUSTER>
```

若存在模板：

```bash
scowctl api GET /api/job/getJobTemplate cluster=<CLUSTER> id=<TEMPLATE_ID>
```

赋值：

```text
<TEMPLATE_ID> = listJobTemplates 返回的模板 ID
<REAL_BODY> = getJobTemplate 返回参数最小化后组成，命令使用 hostname
```

若模板不可用：

```bash
scowctl api GET /api/job/getAccounts
scowctl api GET /api/job/getAvailableAccountsAndClusters
scowctl api GET /api/job/getAvailablePartitionsForCluster cluster=<CLUSTER>
```

提交：

```bash
scowctl api POST /api/job/submitJob --body '<REAL_BODY>'
```

赋值：

```text
<JOB_ID> = submitJob 返回值
```

后续用当前 OpenAPI 中真实的作业查询接口持续查状态，直到 `RUNNING` 或结束。若 `RUNNING`，最多观察 30 秒；必要时取消并清理输出文件。

常用状态查询与输出清理：

```bash
scowctl api help GET /api/job/getAllJobs
scowctl api GET /api/job/getAllJobs cluster=<CLUSTER> startTime=<START_ISO> endTime=<END_ISO>
scowctl api DELETE /api/file/deleteFile cluster=<CLUSTER> path=<OUTPUT_PATH>
scowctl api DELETE /api/file/deleteFile cluster=<CLUSTER> path=<ERROR_OUTPUT_PATH>
scowctl api GET /api/file/fileExist cluster=<CLUSTER> path=<OUTPUT_PATH>
scowctl api GET /api/file/fileExist cluster=<CLUSTER> path=<ERROR_OUTPUT_PATH>
```

`getAllJobs` 必填 `cluster/startTime/endTime`；本轮新提交的最小作业若直接进入 `COMPLETED`，也属于成功完成。`submitJob` 会按 `output/errorOutput` 生成文件，巡检结束前要删除并复核不存在，否则最终不得为 `pass`。

### 4.5 HPC 交互式应用

取应用和历史参数：

```bash
scowctl api GET /api/app/listAvailableApps cluster=<CLUSTER>
scowctl api GET /api/app/getAppMetadata cluster=<CLUSTER> appId=<APP_ID>
scowctl api GET /api/app/getAppLastSubmission cluster=<CLUSTER> appId=<APP_ID>
scowctl api help POST /api/app/createAppSession
```

赋值：

```text
<APP_ID> = listAvailableApps 中适合连通性测试的应用，如 vscode/jupyter/jupyterlab
<REAL_BODY> = getAppLastSubmission 返回参数 + 本轮唯一字段
```

创建：

```bash
scowctl api POST /api/app/createAppSession --body '<REAL_BODY>'
```

赋值：

```text
<JOB_ID>, <SESSION_ID> = 创建返回值或后续会话列表真实返回值
```

若 `createAppSession` 返回 5xx，不要立即重复创建：先查询作业和会话，确认是否已经创建了后端作业。

```bash
scowctl api help GET /api/app/getAppSessions
scowctl api GET /api/app/getAppSessions clusters=<CLUSTER>
scowctl api GET /api/job/getAllJobs cluster=<CLUSTER> startTime=<START_ISO> endTime=<END_ISO>
```

实测：`/api/app/getAppSessions` 的参数名是 `clusters`（数组），不是 `cluster`。若 `createAppSession` 返回 500 但 `getAllJobs` 中出现了本轮应用作业，必须记录为“接口返回异常但作业已创建”；只有在 `getAppSessions` 返回真实 `<SESSION_ID>` 后才允许继续 `connectToApp`。不要按工作目录或时间戳手工拼 `sessionId`。若无法取得真实会话 ID，应取消本轮应用作业并复核为 `CANCELED`。

会话 `RUNNING` 后获取连接信息：

```bash
scowctl api GET /api/app/checkConnectivity cluster=<CLUSTER> host=<HOST> port=<PORT> appType=<APP_TYPE>
scowctl api POST /api/app/connectToApp --body '{"cluster":"<CLUSTER>","jobId":<JOB_ID>,"sessionId":"<SESSION_ID>"}'
```

赋值：

```text
<HOST>, <PORT>, <PASSWORD>, <PROXY_TYPE> = connectToApp 返回值
<ENTRY_URL> = 若 <PROXY_TYPE>=relative，则 <SCOW_BASE_URL>/api/proxy/<CLUSTER>/relative/<HOST>/<PORT>/
```

真实访问验证：

```bash
curl -sS --max-time 30 \
  -H 'x-scow-api-auth-token: <SCOW_API_AUTH_TOKEN>' \
  -H 'x-scow-user-id: <SCOW_USER_ID>' \
  -c /tmp/scow_hpc_app.cookies -b /tmp/scow_hpc_app.cookies \
  -D /tmp/scow_hpc_app_root_headers.txt \
  -o /tmp/scow_hpc_app_root_body.txt \
  "<ENTRY_URL>"
```

若跳转登录页，读取登录页并提交：

```bash
curl -sS --max-time 30 \
  -H 'x-scow-api-auth-token: <SCOW_API_AUTH_TOKEN>' \
  -H 'x-scow-user-id: <SCOW_USER_ID>' \
  -c /tmp/scow_hpc_app.cookies -b /tmp/scow_hpc_app.cookies \
  -D /tmp/scow_hpc_app_loginpage_headers.txt \
  -o /tmp/scow_hpc_app_loginpage_body.txt \
  "<ENTRY_URL>login"

curl -sS --max-time 30 \
  -H 'x-scow-api-auth-token: <SCOW_API_AUTH_TOKEN>' \
  -H 'x-scow-user-id: <SCOW_USER_ID>' \
  -c /tmp/scow_hpc_app.cookies -b /tmp/scow_hpc_app.cookies \
  -D /tmp/scow_hpc_app_login_headers.txt \
  -o /tmp/scow_hpc_app_login_body.txt \
  -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'password=<PASSWORD>' \
  --data-urlencode 'base=<LOGIN_BASE>' \
  --data-urlencode 'href=<LOGIN_HREF>' \
  "<ENTRY_URL>login"

curl -sS --max-time 30 \
  -H 'x-scow-api-auth-token: <SCOW_API_AUTH_TOKEN>' \
  -H 'x-scow-user-id: <SCOW_USER_ID>' \
  -c /tmp/scow_hpc_app.cookies -b /tmp/scow_hpc_app.cookies \
  -D /tmp/scow_hpc_app_after_headers.txt \
  -o /tmp/scow_hpc_app_after_body.txt \
  "<ENTRY_URL>"
```

`base`、`href` 必须来自真实登录页 HTML 或真实入口；不能凭经验补造。若真实 HTML 中 `href` 的 value 为空字符串，就按空字符串提交，不要替换为 `<ENTRY_URL>`。登录请求和登录后回访必须使用同一个 cookie jar。完成后按可用接口清理会话并复核。

## 5. AI 分支命令

对每个 `<CLUSTER>` in `<AI_CLUSTERS>` 执行。

### 5.1 AI 只读检查

```bash
scowctl api GET /ai/api/dashboard/cluster clusterId=<CLUSTER>
scowctl api GET /ai/api/dashboard/nodes clusterId=<CLUSTER>
scowctl api GET /ai/api/notification/unread-messages
scowctl api GET /ai/api/allAvailableAppsFromAllClusters
scowctl api GET /ai/api/file/homeDir clusterId=<CLUSTER>
```

赋值：

```text
<APP_ID> = allAvailableAppsFromAllClusters 中适合连通性测试的应用，如 vscode
<HOME_PATH> = /ai/api/file/homeDir 返回的 path
<WORK_DIR> = <HOME_PATH>
```

注意：`/ai/api/apps/accountsAndClusters` help 只显示可选 `appId`，但实测无参数或 `appId=vscode` 返回 400 缺 `clusterId`，而传 `clusterId` 又会被 `scowctl` 判为 unknown parameter。记录该事实，不要在此阻塞；账户/分区优先从历史会话参数获取。

如已得到 `<ACCOUNT_NAME>`，可查分区：

```bash
scowctl api GET /ai/api/config/cluster/availablePartitions clusterId=<CLUSTER> accountName=<ACCOUNT_NAME>
```

### 5.2 AI 远程镜像

```bash
scowctl api help POST /ai/api/images
scowctl api help DELETE /ai/api/images/{id}
scowctl api GET /ai/api/images clusterId=<CLUSTER>
```

赋值：

```text
<REAL_BODY> = 最近一次成功远程镜像记录 + 本轮唯一名称/tag
```

创建并清理：

```bash
scowctl api POST /ai/api/images --body '<REAL_BODY>'
scowctl api DELETE /ai/api/images/{id} id=<IMAGE_ID> force=true isPlatformOwned=false
scowctl api GET /ai/api/images clusterId=<CLUSTER>
```

赋值：

```text
<IMAGE_ID> = POST /ai/api/images 返回值；不要用既有历史镜像 id 清理本轮新建镜像
```

`/ai/api/images` 创建成功时可能只返回数字 id。删除后再次 `GET /ai/api/images clusterId=<CLUSTER>`，确认本轮唯一名称/tag 不在列表中。

### 5.3 AI 应用会话创建

取历史会话：

```bash
scowctl api POST /ai/api/appSessions/list --body '{"clusterId":"<CLUSTER>","page":1,"pageSize":20}'
```

赋值：

```text
<JOB_ID>, <SESSION_ID>, <APP_ID>, <APP_NAME> = appSessions/list 中最近一次真实历史会话
```

取历史创建参数：

```bash
scowctl api help GET /ai/api/appSessions/{jobId}/submissionParameters
scowctl api GET /ai/api/appSessions/{jobId}/submissionParameters jobId=<JOB_ID> clusterId=<CLUSTER> sessionId=<SESSION_ID>
```

若返回 404 且包含 `session.json not exists`：换下一个 `/ai/api/appSessions/list` 返回的真实会话，不能手工拼 `sessionId`。

赋值：

```text
<REAL_BODY> = submissionParameters 返回值
<ACCOUNT_NAME> = <REAL_BODY>.account
<PARTITION> = <REAL_BODY>.partition
<WORK_DIR> = <REAL_BODY>.envVariables 中 key=WORK_DIR 的 value；若不存在则用 /ai/api/file/homeDir 的 path
```

创建前必须保证 `<REAL_BODY>` 中包含：

```json
"envVariables":[{"key":"WORK_DIR","value":"<WORK_DIR>"}]
```

若创建返回 `WORK_DIR is required`，按顺序补齐，不要退出：

```bash
scowctl api GET /ai/api/appSessions/{jobId}/submissionParameters jobId=<JOB_ID> clusterId=<CLUSTER> sessionId=<SESSION_ID>
scowctl api GET /ai/api/jobs/{jobId}/submissionParameters jobId=<JOB_ID> clusterId=<CLUSTER> sessionId=<SESSION_ID>
scowctl api GET /ai/api/file/homeDir clusterId=<CLUSTER>
```

实测：`/ai/api/file/homeDir clusterId=ai1` 返回 `{"path":"/data/home/demo_admin"}`；缺 `WORK_DIR` 会 400，补上后可创建成功。

创建：

```bash
scowctl api help POST /ai/api/appSessions
scowctl api POST /ai/api/appSessions --body '<REAL_BODY>'
```

赋值：

```text
<JOB_ID> = 创建返回的 jobId
<SESSION_ID> = 再查 appSessions/list 后匹配 <JOB_ID> 得到
```

```bash
scowctl api POST /ai/api/appSessions/list --body '{"clusterId":"<CLUSTER>","page":1,"pageSize":5}'
```

### 5.4 AI 应用连接与真实访问验证

会话 `RUNNING` 后：

```bash
scowctl api GET /ai/api/appSessions/{jobId}/checkConnectivity jobId=<JOB_ID> clusterId=<CLUSTER> sessionId=<SESSION_ID>
scowctl api help POST /ai/api/appSessions/{sessionId}/connect
scowctl api POST /ai/api/appSessions/{sessionId}/connect sessionId=<SESSION_ID> --body '{"cluster":"<CLUSTER>"}'
```

赋值：

```text
<HOST>, <PORT>, <PASSWORD>, <PROXY_TYPE> = connect 返回值
<ENTRY_URL> = 若 <PROXY_TYPE>=relative，则 <SCOW_BASE_URL>/ai/api/proxy/<CLUSTER>/relative/<HOST>/<PORT>/
```

注意：AI 分支没有 `/ai/api/app/connectToApp`；`connectToApp` 只用于 HPC。AI 真实入口必须来自 `/ai/api/appSessions/{sessionId}/connect`。

真实访问验证：

```bash
curl -sS --max-time 30 \
  -H 'x-scow-api-auth-token: <SCOW_API_AUTH_TOKEN>' \
  -H 'x-scow-user-id: <SCOW_USER_ID>' \
  -c /tmp/scow_ai_app.cookies -b /tmp/scow_ai_app.cookies \
  -D /tmp/scow_ai_app_root_headers.txt \
  -o /tmp/scow_ai_app_root_body.txt \
  "<ENTRY_URL>"
```

若跳转登录页：

```bash
curl -sS --max-time 30 \
  -H 'x-scow-api-auth-token: <SCOW_API_AUTH_TOKEN>' \
  -H 'x-scow-user-id: <SCOW_USER_ID>' \
  -c /tmp/scow_ai_app.cookies -b /tmp/scow_ai_app.cookies \
  -D /tmp/scow_ai_app_loginpage_headers.txt \
  -o /tmp/scow_ai_app_loginpage_body.txt \
  "<ENTRY_URL>login"

curl -sS --max-time 30 \
  -H 'x-scow-api-auth-token: <SCOW_API_AUTH_TOKEN>' \
  -H 'x-scow-user-id: <SCOW_USER_ID>' \
  -c /tmp/scow_ai_app.cookies -b /tmp/scow_ai_app.cookies \
  -D /tmp/scow_ai_app_login_headers.txt \
  -o /tmp/scow_ai_app_login_body.txt \
  -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'password=<PASSWORD>' \
  --data-urlencode 'base=<LOGIN_BASE>' \
  --data-urlencode 'href=<LOGIN_HREF>' \
  "<ENTRY_URL>login"

curl -sS --max-time 30 \
  -H 'x-scow-api-auth-token: <SCOW_API_AUTH_TOKEN>' \
  -H 'x-scow-user-id: <SCOW_USER_ID>' \
  -c /tmp/scow_ai_app.cookies -b /tmp/scow_ai_app.cookies \
  -D /tmp/scow_ai_app_after_headers.txt \
  -o /tmp/scow_ai_app_after_body.txt \
  "<ENTRY_URL>"
```

成功证据至少记录：首次 `302 -> ./login`、登录 POST 的 `302 + Set-Cookie`、回访 `200 OK`、响应体包含 `vscode-workbench-web-configuration` 或 `workbench.js`。

清理：

```bash
scowctl api DELETE /ai/api/jobs/{jobId} jobId=<JOB_ID> cluster=<CLUSTER>
scowctl api POST /ai/api/appSessions/list --body '{"clusterId":"<CLUSTER>","page":1,"pageSize":1}'
```

复核新会话为 `CANCELED` 或已消失。

### 5.5 AI 开发机

按当前 OpenAPI help 查询实际接口：

```bash
scowctl api list | grep -E 'connectDevHost|checkDevHost|appSessions'
scowctl api help POST /ai/api/appSessions
scowctl api help POST /ai/api/appSessions/{sessionId}/connectDevHostApp
```

变量来源规则与 AI 应用一致：历史参数优先，`WORK_DIR` 必须显式存在，远程镜像参数来自 `/ai/api/images`，连接入口来自真实 `connectDevHostApp` 或当前 help 指示的接口。

创建开发机并获取真实会话：

```bash
scowctl api help POST /ai/api/devHost
scowctl api POST /ai/api/devHost --body '<REAL_BODY>'
scowctl api POST /ai/api/appSessions/list --body '{"clusterId":"<CLUSTER>","page":1,"pageSize":5}'
```

赋值：

```text
<JOB_ID> = /ai/api/devHost 返回的 devHostId
<SESSION_ID> = appSessions/list 中匹配 <JOB_ID> 的真实 sessionId
```

`/ai/api/devHost` 创建返回字段名为 `devHostId`，但后续删除和连通性接口仍使用同一个值作为 `jobId`。不要根据 `devHostId` 或时间戳手工拼 `sessionId`；必须从 `/ai/api/appSessions/list` 取真实 `sessionId`。实测手工猜错 `sessionId` 会导致 `connectDevHostApp` 返回 404。

开发机连通性与真实访问验证：

```bash
scowctl api help GET /ai/api/appSessions/{jobId}/checkDevHostConnectivity
scowctl api help POST /ai/api/appSessions/{sessionId}/connectDevHostApp
scowctl api GET /ai/api/appSessions/{jobId}/checkDevHostConnectivity jobId=<JOB_ID> clusterId=<CLUSTER> sessionId=<SESSION_ID> appName=<APP_ID>
scowctl api POST /ai/api/appSessions/{sessionId}/connectDevHostApp sessionId=<SESSION_ID> --body '{"cluster":"<CLUSTER>","appName":"<APP_ID>"}'
```

若返回 `<HOST>/<PORT>/<PASSWORD>/<PROXY_TYPE>`，按 5.4 同样的真实 proxy 入口与登录页流程访问：首次入口、真实 `/login` HTML、按 hidden `base/href` 与返回密码提交、带同一 cookie 回访入口。结束后删除对应 job 并复核为 `CANCELED`：

```bash
scowctl api DELETE /ai/api/jobs/{jobId} jobId=<JOB_ID> cluster=<CLUSTER>
scowctl api POST /ai/api/appSessions/list --body '{"clusterId":"<CLUSTER>","page":1,"pageSize":5}'
```

### 5.6 AI 文件探针

```bash
scowctl api GET /ai/api/file/homeDir clusterId=<CLUSTER>
```

赋值：

```text
<HOME_PATH> = homeDir.path
<PROBE_FILE> = <HOME_PATH>/.scowctl_probe_<TIMESTAMP>.txt
```

执行并清理：

```bash
scowctl api GET /ai/api/file/listDirectory clusterId=<CLUSTER> path=<HOME_PATH>
scowctl api POST /ai/api/file/createFile --body '{"clusterId":"<CLUSTER>","path":"<PROBE_FILE>"}'
scowctl api GET /ai/api/file/checkExist clusterId=<CLUSTER> path=<PROBE_FILE>
scowctl api POST /ai/api/file/delete --body '{"clusterId":"<CLUSTER>","path":"<PROBE_FILE>","target":"FILE"}'
scowctl api GET /ai/api/file/checkExist clusterId=<CLUSTER> path=<PROBE_FILE>
```

## 6. 最终输出

按以下结构输出：

```text
权限与登录：...
集群分类：
  PORTAL_VISIBLE_CLUSTERS=...
  AI_DEFINED_CLUSTERS=...
  ACTIVATED_CLUSTERS=...
  HPC_CLUSTERS=...
  AI_CLUSTERS=...
HPC 分支结果：...
AI 分支结果：...
关键命令与参数来源：...
接口事实与试错记录：...
清理结果：...
最终结论：pass | pass_with_findings | blocked | fail
```

结论规则：

- 权限不足、关键变量无法从真实接口取得、流程无法继续：`blocked`。
- 关键检查失败、真实访问失败或清理失败：至少 `pass_with_findings`，严重时 `fail`。
- 所有关键检查成功且可回滚资源已清理：`pass`。
- `checkConnectivity` 成功不等于拿到入口；入口必须来自 HPC `connectToApp` 或 AI `connect`。
- 猜测 URL 的 404 只记录为噪音，不作为平台缺陷。
