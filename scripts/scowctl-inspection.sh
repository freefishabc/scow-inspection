#!/usr/bin/env bash
# SCOW scowctl 巡检脚本：所有业务操作通过 scowctl，只有真实入口验证使用 curl。
set -uo pipefail
IFS=$'\n\t'

# 每轮巡检独立落盘，避免覆盖历史证据。
DOC_PATH="${DOC_PATH:-/home/private-scow/scowctl-巡检命令行流程.md}"
RUN_ID="${SCOW_INSPECT_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
WORKDIR="${SCOW_INSPECT_WORKDIR:-/tmp/scowctl-inspection-${RUN_ID}}"
REPORT="${WORKDIR}/report.md"
RAW_DIR="${WORKDIR}/raw"
HTTP_DIR="${WORKDIR}/http"

FINDINGS=0
FAILURES=0
BLOCKED=0
CLEANUP_FAILURES=0
FINDING_ITEMS=()

SCOW_USER_ID="${SCOW_USER_ID:-}"
SCOW_API_AUTH_TOKEN="${SCOW_API_AUTH_TOKEN:-}"
SCOW_BASE_URL="${SCOW_BASE_URL:-}"
VERBOSE=0

# 认证变量不能留空，也不能直接使用文档里的 <...> 占位符。
is_placeholder_value() {
  local value="$1"
  [[ -z "$value" ]] && return 0
  [[ "$value" == \<*\> ]]
}

# 输出脚本用法。
usage() {
  cat <<USAGE
用法:
  SCOW_BASE_URL='<scow_base_url>' SCOW_AUTH_USER='<auth_user>' SCOW_AUTH_SECRET='<auth_secret>' $0 [-v|-vv]

参数:
  -v    打印步骤级日志：关键命令名称、用途和脱敏后的命令行
  -vv   打印详细日志：包含 -v 内容，并同步输出每条命令的 stdout/stderr
  -h    显示此帮助

示例:
  SCOW_BASE_URL='http://10.100.156.82' SCOW_AUTH_USER='demo_admin' SCOW_AUTH_SECRET='<auth_secret>' $0 -v
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v)
      VERBOSE=1
      ;;
    -vv)
      VERBOSE=2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf '未知参数: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if is_placeholder_value "${SCOW_AUTH_USER:-}" || is_placeholder_value "${SCOW_AUTH_SECRET:-}"; then
  printf '缺少认证信息或仍在使用占位符。请按以下方式运行脚本：\n\n' >&2
  usage >&2
  exit 2
fi

# 清理队列用于异常退出时兜底删除本轮创建的资源。
HPC_PROBES=()
AI_PROBES=()
HPC_JOBS=()
AI_JOBS=()
AI_IMAGES=()

mkdir -p "$RAW_DIR" "$HTTP_DIR"
chmod 700 "$WORKDIR"
: > "$REPORT"

cat > "${WORKDIR}/json_helper.py" <<'PY'
import json
import re
import sys
from urllib.parse import urlparse

PREFERRED_APPS = ["vscode", "code-server", "jupyterlab", "jupyter", "rstudio"]


# 读取 stdin 中的原始文本。
def read_text():
    return sys.stdin.read()


# 从混合输出中提取第一段 JSON。
def loads_any(text):
    text = text.strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except Exception:
        pass
    decoder = json.JSONDecoder()
    for i, ch in enumerate(text):
        if ch not in "[{":
            continue
        try:
            value, _ = decoder.raw_decode(text[i:])
            return value
        except Exception:
            continue
    return None


# 深度遍历 JSON 结构中的所有节点。
def walk(value):
    yield value
    if isinstance(value, dict):
        for v in value.values():
            yield from walk(v)
    elif isinstance(value, list):
        for v in value:
            yield from walk(v)


# 遍历 JSON 并返回匹配 key 的值。
def values_for_keys(value, keys):
    keys = {k.lower() for k in keys}
    for item in walk(value):
        if isinstance(item, dict):
            for k, v in item.items():
                if str(k).lower() in keys:
                    yield v


# 将常见 JSON 值转换为字符串列表。
def as_strings(value):
    result = []
    if value is None:
        return result
    if isinstance(value, str):
        result.append(value)
    elif isinstance(value, (int, float)):
        result.append(str(value))
    elif isinstance(value, dict):
        if value and all(isinstance(k, str) for k in value.keys()):
            result.extend(str(k) for k in value.keys())
        for key in ("id", "clusterId", "name", "cluster", "accountName", "partitionName", "value"):
            if key in value and isinstance(value[key], (str, int, float)):
                result.append(str(value[key]))
    elif isinstance(value, list):
        for item in value:
            result.extend(as_strings(item))
    return result


# 按原顺序去重并过滤空值。
def uniq(seq):
    seen = set()
    out = []
    for x in seq:
        if x is None:
            continue
        x = str(x).strip()
        if not x or x in seen:
            continue
        seen.add(x)
        out.append(x)
    return out


# 按 key 优先级提取第一个标量值。
def first_scalar(value, keys):
    for v in values_for_keys(value, keys):
        if isinstance(v, (str, int, float, bool)):
            return str(v)
        for s in as_strings(v):
            return s
    return ""


# 将去重后的项目逐行输出。
def print_lines(items):
    for item in uniq(items):
        print(item)


# 从门户接口返回中提取可见集群。
def cluster_portal(data):
    for keys in (["clusterIds", "availableClusters", "clusters"], ["clusterId", "id"]):
        out = []
        for v in values_for_keys(data, keys):
            out.extend(as_strings(v))
        if out:
            return uniq(out)
    return []


# 从 AI 配置返回中提取 AI 集群。
def cluster_ai(data):
    if isinstance(data, dict):
        keys = [k for k in data.keys() if isinstance(k, str) and k not in ("code", "message", "data", "success")]
        if keys and all(not isinstance(data[k], (str, int, float, bool)) for k in keys):
            return uniq(keys)
    out = []
    for v in values_for_keys(data, ["clusterId", "cluster"]):
        out.extend(as_strings(v))
    return uniq(out)


# 从运行时信息中提取已激活集群。
def cluster_active(data):
    out = []
    for item in walk(data):
        if isinstance(item, dict):
            active = item.get("activated", item.get("isActivated", item.get("available", item.get("enabled", True))))
            if active is False:
                continue
            cid = item.get("clusterId", item.get("id", item.get("cluster")))
            if cid:
                out.append(str(cid))
    if out:
        return uniq(out)
    return cluster_ai(data) or cluster_portal(data)


# 从返回值中选择可用账户。
def pick_account(data):
    return first_scalar(data, ["accountName", "account", "accounts", "name", "id"])


# 从返回值中选择可用分区。
def pick_partition(data):
    for item in walk(data):
        if isinstance(item, dict):
            for key in ("partitionName", "partition", "name", "id"):
                value = item.get(key)
                if isinstance(value, (str, int, float)):
                    return str(value)
    return first_scalar(data, ["partitionName", "partition", "partitions", "availablePartitions", "name", "id"])


# 从返回值中提取 home 目录。
def home_path(data):
    return first_scalar(data, ["path", "home", "homeDir", "homeDirectory"])


# 将文件存在性响应规范化为 true/false/unknown。
def truthy_exists(data):
    for key in ["exists", "exist", "isExist", "isExists"]:
        for v in values_for_keys(data, [key]):
            if isinstance(v, bool):
                return "true" if v else "false"
            if isinstance(v, str):
                if v.lower() in ("true", "yes", "1"):
                    return "true"
                if v.lower() in ("false", "no", "0"):
                    return "false"
    return "unknown"


# 从作业模板列表中提取模板 ID。
def find_template_id(data):
    for item in walk(data):
        if isinstance(item, dict):
            value = item.get("id", item.get("templateId"))
            if value is not None:
                return str(value)
    return ""


# 从应用对象中提取应用 ID。
def app_id_from_obj(obj):
    if not isinstance(obj, dict):
        return ""
    for key in ("appId", "id", "name", "appName"):
        value = obj.get(key)
        if isinstance(value, str) and value:
            return value
    return ""


# 按优先级从应用列表中选择巡检应用。
def select_app(data):
    candidates = []
    for item in walk(data):
        app_id = app_id_from_obj(item)
        if app_id:
            candidates.append(app_id)
    candidates = uniq(candidates)
    lowered = {x.lower(): x for x in candidates}
    for preferred in PREFERRED_APPS:
        if preferred in lowered:
            return lowered[preferred]
    for preferred in PREFERRED_APPS:
        for candidate in candidates:
            if preferred in candidate.lower():
                return candidate
    return candidates[0] if candidates else ""


# 从创建响应中提取作业或资源 ID。
def find_job_id(data):
    if isinstance(data, (str, int, float)):
        return str(data)
    return first_scalar(data, ["jobId", "devHostId", "id"])


# 从会话列表中定位本轮 sessionId。
def find_session_id(data, job_id="", stamp=""):
    chosen = ""
    for item in walk(data):
        if not isinstance(item, dict):
            continue
        sid = item.get("sessionId", item.get("id"))
        if not sid:
            continue
        jid = str(item.get("jobId", item.get("devHostId", "")))
        item_text = json.dumps(item, ensure_ascii=False)
        if job_id and jid == str(job_id):
            return str(sid)
        if stamp and stamp in item_text:
            chosen = str(sid)
    return chosen


# 从会话或作业列表中提取状态。
def find_state(data, job_id="", session_id=""):
    for item in walk(data):
        if not isinstance(item, dict):
            continue
        jid = str(item.get("jobId", item.get("devHostId", item.get("id", ""))))
        sid = str(item.get("sessionId", ""))
        if (job_id and jid == str(job_id)) or (session_id and sid == str(session_id)):
            for key in ("state", "status", "jobState"):
                if key in item:
                    return str(item[key])
    return first_scalar(data, ["state", "status", "jobState"])


# 从桌面列表中定位本轮桌面。
def find_desktop(data, desktop_name):
    for host_group in walk(data):
        if not isinstance(host_group, dict) or "desktops" not in host_group:
            continue
        login_node = host_group.get("host") or host_group.get("loginNode")
        desktops = host_group.get("desktops")
        if not isinstance(desktops, list):
            continue
        for desktop in desktops:
            if not isinstance(desktop, dict):
                continue
            payload = desktop.get("data") if isinstance(desktop.get("data"), dict) else desktop
            text = json.dumps(payload, ensure_ascii=False)
            if desktop_name and desktop_name not in text:
                continue
            desktop_id = payload.get("id", payload.get("desktopId"))
            display_id = payload.get("displayId", payload.get("display"))
            if desktop_id is not None and display_id is not None:
                print(json.dumps({"id": desktop_id, "displayId": display_id, "loginNode": login_node}, ensure_ascii=False))
                return
    for item in walk(data):
        if not isinstance(item, dict):
            continue
        text = json.dumps(item, ensure_ascii=False)
        if desktop_name and desktop_name not in text:
            continue
        desktop_id = item.get("id", item.get("desktopId"))
        display_id = item.get("displayId", item.get("display"))
        login_node = item.get("loginNode", item.get("host", item.get("node")))
        if desktop_id is not None and display_id is not None:
            print(json.dumps({"id": desktop_id, "displayId": display_id, "loginNode": login_node}, ensure_ascii=False))
            return


# 从返回值中提取首个主机名。
def first_host(data):
    return first_scalar(data, ["loginNode", "host", "node", "hostname"])


# 去掉不能复用于创建请求的运行时字段。
def strip_runtime_fields(obj):
    if not isinstance(obj, dict):
        return {}
    ignored = {
        "id", "jobId", "sessionId", "devHostId", "status", "state", "createdAt", "updatedAt", "startedAt", "endedAt",
        "createTime", "updateTime", "startedTime", "endedTime", "userId", "owner", "displayId", "port", "password",
    }
    return {k: v for k, v in obj.items() if k not in ignored}


# 按优先字段从 JSON 中选择参数对象。
def select_object(data, preferred_keys):
    if isinstance(data, dict):
        for key in preferred_keys:
            if isinstance(data.get(key), dict):
                return data[key]
        return data
    for item in walk(data):
        if isinstance(item, dict):
            return item
    return {}


# 基于模板和实时参数生成 HPC 最小作业 body。
def hpc_job_body(data, cluster, account, partition, stamp, home):
    src = strip_runtime_fields(select_object(data, ["jobTemplate", "template", "data"]))
    if not isinstance(src, dict) or ("message" in src and "code" in src):
        src = {}
    name = f"scowctl-inspect-job-{stamp}"
    body = {
        "account": account,
        "cluster": cluster,
        "command": "hostname",
        "coreCount": int(src.get("coreCount") or 1),
        "errorOutput": f"{home}/scowctl-inspect-job-{stamp}.err" if home else f"scowctl-inspect-job-{stamp}.err",
        "jobName": name,
        "maxTime": int(src.get("maxTime") or 5),
        "nodeCount": int(src.get("nodeCount") or 1),
        "output": f"{home}/scowctl-inspect-job-{stamp}.out" if home else f"scowctl-inspect-job-{stamp}.out",
        "partition": partition,
        "save": False,
        "workingDirectory": home,
    }
    for key in ("gpuCount", "memory", "qos", "maxTimeUnit", "scriptOutput"):
        value = src.get(key)
        if value not in (None, ""):
            body[key] = value
    print(json.dumps(body, ensure_ascii=False))


# 基于历史提交生成 HPC 应用创建 body。
def patch_hpc_app(data, cluster, app_id, stamp):
    src = strip_runtime_fields(select_object(data, ["lastSubmission", "submission", "data", "parameters"]))
    if isinstance(data, dict) and isinstance(data.get("lastSubmissionInfo"), dict):
        src.update(strip_runtime_fields(data["lastSubmissionInfo"]))
    body = dict(src)
    body.setdefault("cluster", cluster)
    body["cluster"] = cluster
    if app_id:
        body.setdefault("appId", app_id)
    body.setdefault("save", False)
    body.setdefault("appName", app_id or "vscode")
    name = f"scowctl-inspect-app-{stamp}"
    body.setdefault("appJobName", name)
    for key in ("name", "jobName", "sessionName", "appJobName"):
        if key in body:
            body[key] = name
    if "workingDirectory" not in body and "workingDirectory" in src:
        body["workingDirectory"] = src["workingDirectory"]
    print(json.dumps(body, ensure_ascii=False))


# 确保 AI 应用 body 中包含 WORK_DIR。
def ensure_work_dir(body, work_dir):
    envs = body.get("envVariables")
    if not isinstance(envs, list):
        envs = []
    found = False
    for item in envs:
        if isinstance(item, dict) and item.get("key") == "WORK_DIR":
            found = True
            if not item.get("value") and work_dir:
                item["value"] = work_dir
    if not found and work_dir:
        envs.append({"key": "WORK_DIR", "value": work_dir})
    body["envVariables"] = envs
    body.setdefault("workingDirectory", work_dir)


# 基于历史参数生成 AI 应用创建 body。
def patch_ai_app(data, cluster, stamp, work_dir):
    if data is None:
        return
    src = strip_runtime_fields(select_object(data, ["parameters", "submissionParameters", "data"]))
    if not src and isinstance(data, dict):
        for key in ("parameters", "submissionParameters", "data"):
            if isinstance(data.get(key), dict):
                src = strip_runtime_fields(data[key])
                break
    if not src or ("message" in src and "code" in src):
        return
    body = dict(src)
    body["clusterId"] = cluster
    ensure_work_dir(body, work_dir)
    if "workingDirectory" not in body and work_dir:
        body["workingDirectory"] = work_dir
    name = f"scowctl-inspect-ai-app-{stamp}"
    for key in ("name", "jobName", "sessionName", "appJobName"):
        if key in body:
            body[key] = name
    print(json.dumps(body, ensure_ascii=False))


# 从 AI 历史会话中输出可复用候选。
def ai_history_candidates(data):
    for item in walk(data):
        if not isinstance(item, dict):
            continue
        job_id = item.get("jobId")
        session_id = item.get("sessionId")
        job_type = str(item.get("jobType", "")).lower()
        app_id = item.get("appId") or item.get("name")
        if job_id is None or not session_id:
            continue
        if job_type and job_type != "app":
            continue
        print("\t".join([str(job_id), str(session_id), str(app_id or "")]))


# 基于历史镜像记录生成 AI 镜像创建 body。
def patch_ai_image(data, stamp, cluster):
    src = None
    for item in walk(data):
        if not isinstance(item, dict):
            continue
        if item.get("isPlatformOwned") is True:
            continue
        if item.get("source") or item.get("sourcePath") or item.get("clusterId"):
            src = item
            break
    if src is None:
        src = select_object(data, ["data"])
    body = strip_runtime_fields(src)
    if not body:
        return
    body["clusterId"] = cluster
    body.setdefault("source", "EXTERNAL")
    if "sourcePath" not in body:
        return
    body.setdefault("types", ["APP", "DEV_HOST"])
    body["name"] = f"scowctl-inspect-image-{stamp}"
    body["tag"] = f"inspect-{stamp}"
    print(json.dumps(body, ensure_ascii=False))


# 从 AI 镜像列表中定位本轮镜像并输出 id/status。
def find_ai_image(data, name, tag):
    for item in walk(data):
        if not isinstance(item, dict):
            continue
        item_name = str(item.get("name", ""))
        item_tag = str(item.get("tag", ""))
        if name and item_name != name:
            continue
        if tag and item_tag != tag:
            continue
        image_id = item.get("id", item.get("imageId"))
        status = item.get("status", item.get("state", item.get("createStatus", item.get("imageStatus"))))
        print(json.dumps({"id": "" if image_id is None else str(image_id), "status": "" if status is None else str(status)}, ensure_ascii=False))
        return


# 从集群配置中提取登录节点地址。
def cluster_login_nodes(data, cluster):
    if not isinstance(data, dict):
        return
    configs = data.get("clusterConfigs") if isinstance(data.get("clusterConfigs"), dict) else data
    config = configs.get(cluster) if isinstance(configs, dict) else None
    if not isinstance(config, dict):
        return
    for item in config.get("loginNodes", []):
        if not isinstance(item, dict):
            continue
        value = item.get("address") or item.get("host") or item.get("name")
        if value:
            print(str(value))


# 归一化 connect 返回的真实入口信息。
def connect_info(data):
    host = first_scalar(data, ["host"])
    port = first_scalar(data, ["port"])
    password = first_scalar(data, ["password"])
    proxy_type = first_scalar(data, ["proxyType"])
    path = first_scalar(data, ["path"])
    query = first_scalar(data, ["query"])
    print("\t".join([host, port, password, proxy_type, path, query]))


# 从真实 HTML 登录页提取隐藏字段。
def html_field(text, field):
    pattern = rf'<input[^>]+name=["\']{re.escape(field)}["\'][^>]*>'
    m = re.search(pattern, text, re.I)
    if not m:
        return ""
    tag = m.group(0)
    vm = re.search(r'value=["\']([^"\']*)["\']', tag, re.I)
    return vm.group(1) if vm else ""


# 从 profile 输出中提取 baseUrl。
def base_url(text):
    data = loads_any(text)
    if data is not None:
        value = first_scalar(data, ["baseUrl", "url", "endpoint"])
        if value:
            print(value.rstrip("/"))
            return
    m = re.search(r'(https?://[^\s,;]+)', text)
    if m:
        print(m.group(1).rstrip("/"))


# 从 URL 中提取 host。
def host_of(url):
    try:
        print(urlparse(url).hostname or "")
    except Exception:
        print("")


# 根据命令分发 JSON helper 功能。
def main():
    cmd = sys.argv[1]
    text = read_text()
    data = loads_any(text)
    args = sys.argv[2:]
    if cmd == "base-url":
        base_url(text)
    elif cmd == "host-of":
        host_of(args[0] if args else text.strip())
    elif cmd == "portal-clusters":
        print_lines(cluster_portal(data))
    elif cmd == "ai-clusters":
        print_lines(cluster_ai(data))
    elif cmd == "active-clusters":
        print_lines(cluster_active(data))
    elif cmd == "user-id":
        print(first_scalar(data, ["identityId", "userId", "id", "authUser"]), end="")
    elif cmd == "token":
        print(first_scalar(data, ["token", "accessToken", "apiToken"]), end="")
    elif cmd == "account":
        print(pick_account(data), end="")
    elif cmd == "partition":
        print(pick_partition(data), end="")
    elif cmd == "home":
        print(home_path(data), end="")
    elif cmd == "exists":
        print(truthy_exists(data), end="")
    elif cmd == "template-id":
        print(find_template_id(data), end="")
    elif cmd == "app-id":
        print(select_app(data), end="")
    elif cmd == "job-id":
        print(find_job_id(data), end="")
    elif cmd == "session-id":
        print(find_session_id(data, args[0] if args else "", args[1] if len(args) > 1 else ""), end="")
    elif cmd == "state":
        print(find_state(data, args[0] if args else "", args[1] if len(args) > 1 else ""), end="")
    elif cmd == "desktop":
        find_desktop(data, args[0] if args else "")
    elif cmd == "host":
        print(first_host(data), end="")
    elif cmd == "hpc-job-body":
        hpc_job_body(data, args[0], args[1], args[2], args[3], args[4])
    elif cmd == "hpc-app-body":
        patch_hpc_app(data, args[0], args[1], args[2])
    elif cmd == "ai-app-body":
        patch_ai_app(data, args[0], args[1], args[2])
    elif cmd == "ai-image-body":
        patch_ai_image(data, args[0], args[1])
    elif cmd == "ai-image":
        find_ai_image(data, args[0] if args else "", args[1] if len(args) > 1 else "")
    elif cmd == "ai-history-candidates":
        ai_history_candidates(data)
    elif cmd == "login-nodes":
        cluster_login_nodes(data, args[0] if args else "")
    elif cmd == "connect-info":
        connect_info(data)
    elif cmd == "html-field":
        print(html_field(text, args[0]), end="")
    else:
        raise SystemExit(f"unknown command: {cmd}")


if __name__ == "__main__":
    main()
PY

# 用内嵌 Python 从 raw 文件中提取字段。
json_from_file() {
  local cmd="$1"
  local file="$2"
  shift 2
  python3 "${WORKDIR}/json_helper.py" "$cmd" "$@" < "$file"
}

# 用内嵌 Python 从 stdin 文本中提取字段。
json_from_text() {
  local cmd="$1"
  shift
  python3 "${WORKDIR}/json_helper.py" "$cmd" "$@"
}

# 生成脱敏后的命令字符串。
redacted_command() {
  local skip_next=0
  local arg
  local out=()
  for arg in "$@"; do
    if [[ "$skip_next" == 1 ]]; then
      out+=("<redacted>")
      skip_next=0
      continue
    fi
  if [[ -n "$SCOW_API_AUTH_TOKEN" && "$arg" == *"$SCOW_API_AUTH_TOKEN"* ]]; then
    out+=("<redacted-token>")
    continue
  fi
  if [[ -n "${SCOW_AUTH_SECRET:-}" && "$arg" == *"$SCOW_AUTH_SECRET"* ]]; then
    out+=("<redacted-secret>")
    continue
  fi
  case "$arg" in
      --auth-secret|--body)
        out+=("$arg")
        skip_next=1
        ;;
      *)
        out+=("$arg")
        ;;
    esac
  done
  printf '%q ' "${out[@]}"
}

# 向巡检报告追加一行内容。
append_report() {
  printf '%s\n' "$*" >> "$REPORT"
}

# 开始一个报告章节并在终端显示标题。
section() {
  append_report ""
  append_report "## $*"
  printf '\n== %s ==\n' "$*"
}

# 记录非阻塞发现。
record_finding() {
  FINDINGS=$((FINDINGS + 1))
  FINDING_ITEMS+=("$*")
  append_report "- FINDING: $*"
  printf 'FINDING: %s\n' "$*"
}

# 记录会导致 fail 的错误。
record_failure() {
  FAILURES=$((FAILURES + 1))
  append_report "- FAIL: $*"
  printf 'FAIL: %s\n' "$*"
}

# 记录导致 blocked 的阻塞项。
record_blocked() {
  BLOCKED=$((BLOCKED + 1))
  append_report "- BLOCKED: $*"
  printf 'BLOCKED: %s\n' "$*"
}

# 记录资源清理失败。
record_cleanup_failure() {
  CLEANUP_FAILURES=$((CLEANUP_FAILURES + 1))
  append_report "- CLEANUP_FAIL: $*"
  printf 'CLEANUP_FAIL: %s\n' "$*"
}

# 执行命令并统一处理落盘、回显和退出码。
run_capture() {
  local name="$1"
  local source_note="$2"
  shift 2
  local out="${RAW_DIR}/${name}.out"
  local err="${RAW_DIR}/${name}.err"
  local rcfile="${RAW_DIR}/${name}.rc"
  local safe_command
  local tty_output="/dev/tty"
  if [[ ! -w /dev/tty ]]; then
    tty_output="/dev/stderr"
  fi
  safe_command="$(redacted_command "$@")"
  append_report ""
  append_report "### ${name}"
  append_report "- 来源: ${source_note}"
  append_report "- 命令: \`${safe_command}\`"
  if [[ "$VERBOSE" -ge 1 ]]; then
    printf '[%s] %s\n' "$name" "$source_note" >&2
    printf '  %s\n' "$safe_command" >&2
  fi
  local rc
  if [[ "$VERBOSE" -ge 2 ]]; then
    # -vv 要回显命令输出，但函数 stdout 必须只返回 raw 文件路径。
    "$@" > >(tee "$out" > "$tty_output") 2> >(tee "$err" >&2)
    rc=$?
  else
    "$@" > "$out" 2> "$err"
    rc=$?
  fi
  printf '%s' "$rc" > "$rcfile"
  append_report "- 退出码: ${rc}"
  if [[ "$VERBOSE" -ge 1 ]]; then
    printf '  exit=%s out=%s err=%s\n' "$rc" "$out" "$err" >&2
  fi
  if [[ "$rc" -ne 0 ]]; then
    append_report "- stderr: ${err}"
  fi
  printf '%s\n' "$out"
  return "$rc"
}

# 执行不带 JSON body 的 scowctl api 命令。
scow_api() {
  local name="$1"
  local source_note="$2"
  local method="$3"
  local path="$4"
  shift 4
  run_capture "$name" "$source_note" scowctl api "$method" "$path" "$@"
}

# 执行带 JSON body 的 scowctl api 命令。
scow_api_body() {
  local name="$1"
  local source_note="$2"
  local method="$3"
  local path="$4"
  local body="$5"
  shift 5
  run_capture "$name" "$source_note" scowctl api "$method" "$path" --body "$body" "$@"
}

# 读取指定命令的退出码。
command_rc() {
  local name="$1"
  local rcfile="${RAW_DIR}/${name}.rc"
  [[ -f "$rcfile" ]] && cat "$rcfile" || printf '999'
}

# 从失败命令的 stdout/stderr 中提取简短原因。
command_failure_detail() {
  local name="$1"
  local out="${RAW_DIR}/${name}.out"
  local err="${RAW_DIR}/${name}.err"
  python3 - "$out" "$err" "${SCOW_AUTH_SECRET:-}" "${SCOW_API_AUTH_TOKEN:-}" <<'PY_FAILURE_DETAIL'
import json
import re
import sys
from pathlib import Path

out_path, err_path, secret, token = sys.argv[1:5]
texts = []
for file_path in (out_path, err_path):
    path = Path(file_path)
    if path.exists():
        content = path.read_text(errors="replace").strip()
        if content:
            texts.append(content)
text = "\n".join(texts).strip()
if not text:
    raise SystemExit(0)
for value in (secret, token):
    if value:
        text = text.replace(value, "<redacted>")

json_value = None
for match in re.finditer(r"[\[{]", text):
    try:
        json_value, _ = json.JSONDecoder().raw_decode(text[match.start():])
        break
    except Exception:
        pass

def walk(value):
    yield value
    if isinstance(value, dict):
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)

def collect(value):
    parts = []
    for item in walk(value):
        if not isinstance(item, dict):
            continue
        for key in ("message", "code", "reason", "error", "detailedError", "details", "detail"):
            val = item.get(key)
            if isinstance(val, (str, int, float)) and str(val):
                parts.append(f"{key}={val}")
        issues = item.get("issues")
        if isinstance(issues, list):
            for issue in issues[:3]:
                if isinstance(issue, dict):
                    msg = issue.get("message")
                    loc = issue.get("path")
                    if msg:
                        parts.append(f"issue={loc}: {msg}" if loc else f"issue={msg}")
    seen = []
    for part in parts:
        if part not in seen:
            seen.append(part)
    return "; ".join(seen[:8])

if json_value is not None:
    detail = collect(json_value)
    if detail:
        print(detail[:800], end="")
        raise SystemExit(0)

lines = [line.strip() for line in text.splitlines() if line.strip()]
print("; ".join(lines[:6])[:800], end="")
PY_FAILURE_DETAIL
}

# 用逗号拼接数组内容。
join_by_comma() {
  local IFS=,
  printf '%s' "$*"
}

# 判断数组中是否包含指定值。
contains_item() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# 清理 HPC 文件探针。
cleanup_hpc_probe() {
  local cluster="$1"
  local path="$2"
  scow_api "cleanup_hpc_probe_${cluster}_${RUN_ID}" "trap cleanup: 本轮 HPC 文件探针" DELETE /api/file/deleteFile cluster="$cluster" path="$path" >/dev/null || true
}

# 清理 AI 文件探针。
cleanup_ai_probe() {
  local cluster="$1"
  local path="$2"
  local body
  body=$(printf '{"clusterId":"%s","path":"%s","target":"FILE"}' "$cluster" "$path")
  scow_api_body "cleanup_ai_probe_${cluster}_${RUN_ID}" "trap cleanup: 本轮 AI 文件探针" POST /ai/api/file/delete "$body" >/dev/null || true
}

# 清理 HPC 作业或应用作业。
cleanup_hpc_job() {
  local cluster="$1"
  local job_id="$2"
  scow_api "cleanup_hpc_job_${cluster}_${job_id}_${RUN_ID}" "trap cleanup: 本轮 HPC 作业或应用作业" DELETE /api/job/cancelJob cluster="$cluster" jobId="$job_id" >/dev/null || true
}

# 清理 AI 作业或应用会话。
cleanup_ai_job() {
  local cluster="$1"
  local job_id="$2"
  scow_api "cleanup_ai_job_${cluster}_${job_id}_${RUN_ID}" "trap cleanup: 本轮 AI 作业" DELETE /ai/api/jobs/{jobId} jobId="$job_id" cluster="$cluster" >/dev/null || true
}

# 清理 AI 镜像探针。
cleanup_ai_image() {
  local image_id="$1"
  scow_api "cleanup_ai_image_${image_id}_${RUN_ID}" "trap cleanup: 本轮 AI 镜像" DELETE /ai/api/images/{id} id="$image_id" force=true isPlatformOwned=false >/dev/null || true
}

# 执行退出前的兜底清理。
final_trap_cleanup() {
  local item cluster path job image_id
  for item in "${HPC_PROBES[@]}"; do IFS='|' read -r cluster path <<< "$item"; cleanup_hpc_probe "$cluster" "$path"; done
  for item in "${AI_PROBES[@]}"; do IFS='|' read -r cluster path <<< "$item"; cleanup_ai_probe "$cluster" "$path"; done
  for item in "${HPC_JOBS[@]}"; do IFS='|' read -r cluster job <<< "$item"; cleanup_hpc_job "$cluster" "$job"; done
  for item in "${AI_JOBS[@]}"; do IFS='|' read -r cluster job <<< "$item"; cleanup_ai_job "$cluster" "$job"; done
  for image_id in "${AI_IMAGES[@]}"; do cleanup_ai_image "$image_id"; done
}
trap final_trap_cleanup EXIT

# 从兜底清理队列移除已清理的 HPC 探针。
remove_hpc_probe_from_trap() {
  local target="$1|$2" new=() item
  for item in "${HPC_PROBES[@]}"; do [[ "$item" != "$target" ]] && new+=("$item"); done
  HPC_PROBES=("${new[@]}")
}

# 从兜底清理队列移除已清理的 AI 探针。
remove_ai_probe_from_trap() {
  local target="$1|$2" new=() item
  for item in "${AI_PROBES[@]}"; do [[ "$item" != "$target" ]] && new+=("$item"); done
  AI_PROBES=("${new[@]}")
}

# 从兜底清理队列移除已清理的 HPC 作业。
remove_hpc_job_from_trap() {
  local target="$1|$2" new=() item
  for item in "${HPC_JOBS[@]}"; do [[ "$item" != "$target" ]] && new+=("$item"); done
  HPC_JOBS=("${new[@]}")
}

# 从兜底清理队列移除已清理的 AI 作业。
remove_ai_job_from_trap() {
  local target="$1|$2" new=() item
  for item in "${AI_JOBS[@]}"; do [[ "$item" != "$target" ]] && new+=("$item"); done
  AI_JOBS=("${new[@]}")
}

# 从兜底清理队列移除已清理的 AI 镜像。
remove_ai_image_from_trap() {
  local target="$1" new=() item
  for item in "${AI_IMAGES[@]}"; do [[ "$item" != "$target" ]] && new+=("$item"); done
  AI_IMAGES=("${new[@]}")
}

# 通过 SCOW 代理真实访问应用入口。
curl_verify_entry() {
  local scope="$1"
  local cluster="$2"
  local connect_file="$3"
  local prefix="${scope}_${cluster}_${RUN_ID}"
  local info host port password proxy_type path query entry_url cookie root_headers root_body login_headers login_body loginpage_headers loginpage_body after_headers after_body login_base login_href status

  info=$(json_from_file connect-info "$connect_file")
  IFS=$'\t' read -r host port password proxy_type path query <<< "$info"
  if [[ -z "$host" || -z "$port" ]]; then
    record_finding "${scope}/${cluster}: connect 返回值缺少 host/port，无法确定真实入口"
    return 1
  fi
  if [[ "$proxy_type" != "relative" && -n "$proxy_type" ]]; then
    record_finding "${scope}/${cluster}: proxyType=${proxy_type}，脚本仅自动验证 relative 入口"
    return 1
  fi
  if [[ -z "$SCOW_BASE_URL" ]]; then
    record_finding "${scope}/${cluster}: 缺少 SCOW_BASE_URL，无法生成真实入口"
    return 1
  fi
  if [[ "$scope" == hpc ]]; then
    entry_url="${SCOW_BASE_URL}/api/proxy/${cluster}/relative/${host}/${port}/"
  else
    entry_url="${SCOW_BASE_URL}/ai/api/proxy/${cluster}/relative/${host}/${port}/"
  fi

  local curl_headers=()
  [[ -n "$SCOW_API_AUTH_TOKEN" ]] && curl_headers+=(-H "x-scow-api-auth-token: ${SCOW_API_AUTH_TOKEN}")
  [[ -n "$SCOW_USER_ID" ]] && curl_headers+=(-H "x-scow-user-id: ${SCOW_USER_ID}")

  cookie="${HTTP_DIR}/${prefix}.cookies"
  root_headers="${HTTP_DIR}/${prefix}_root_headers.txt"
  root_body="${HTTP_DIR}/${prefix}_root_body.txt"
  loginpage_headers="${HTTP_DIR}/${prefix}_loginpage_headers.txt"
  loginpage_body="${HTTP_DIR}/${prefix}_loginpage_body.txt"
  login_headers="${HTTP_DIR}/${prefix}_login_headers.txt"
  login_body="${HTTP_DIR}/${prefix}_login_body.txt"
  after_headers="${HTTP_DIR}/${prefix}_after_headers.txt"
  after_body="${HTTP_DIR}/${prefix}_after_body.txt"

  append_report ""
  append_report "### ${scope}/${cluster} 真实入口访问"
  append_report "- 来源: connect 返回 host/port/proxyType，入口按文档由 SCOW_BASE_URL 组合；token 与 password 不写入报告"
  append_report "- ENTRY_URL: ${entry_url}"

  # 代理入口刚创建时偶尔会短暂 502，先重试几次再下结论。
  # 代理入口刚创建时偶尔会短暂 502，先重试几次再下结论。
  for attempt in 1 2 3 4 5 6; do
    curl -sS --max-time 30 \
      "${curl_headers[@]}" \
      -c "$cookie" -b "$cookie" -D "$root_headers" -o "$root_body" "$entry_url"
    status=$(awk 'toupper($0) ~ /^HTTP\// {code=$2} END {print code}' "$root_headers" 2>/dev/null || true)
    if [[ "$status" != "502" ]] && ! grep -Eq 'ECONNREFUSED|Bad Gateway' "$root_body" 2>/dev/null; then
      break
    fi
    [[ "$attempt" == 6 ]] && break
    sleep 5
  done
  append_report "- 首次访问 HTTP: ${status:-unknown}"

  if grep -Eq 'vscode-workbench-web-configuration|workbench\.js|Jupyter|jupyter|code-server' "$root_body" 2>/dev/null; then
    append_report "- 结果: link_access_ok（首次访问已返回应用页面）"
    return 0
  fi

  if grep -Eqi 'location:.*login|action=.*login|password' "$root_headers" "$root_body" 2>/dev/null; then
    curl -sS --max-time 30 \
      "${curl_headers[@]}" \
      -c "$cookie" -b "$cookie" -D "$loginpage_headers" -o "$loginpage_body" "${entry_url}login"
    login_base=$(json_from_text html-field base < "$loginpage_body")
    login_href=$(json_from_text html-field href < "$loginpage_body")
    append_report "- 登录页 hidden base 来源: 真实 login HTML，value='${login_base}'"
    append_report "- 登录页 hidden href 来源: 真实 login HTML，value 长度=${#login_href}"
    curl -sS --max-time 30 \
      "${curl_headers[@]}" \
      -c "$cookie" -b "$cookie" -D "$login_headers" -o "$login_body" \
      -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "password=${password}" \
      --data-urlencode "base=${login_base}" \
      --data-urlencode "href=${login_href}" \
      "${entry_url}login"
    status=$(awk 'toupper($0) ~ /^HTTP\// {code=$2} END {print code}' "$login_headers" 2>/dev/null || true)
    append_report "- 登录 POST HTTP: ${status:-unknown}；Set-Cookie=$(grep -Eci '^set-cookie:' "$login_headers" 2>/dev/null || true)"
    curl -sS --max-time 30 \
      "${curl_headers[@]}" \
      -c "$cookie" -b "$cookie" -D "$after_headers" -o "$after_body" "$entry_url"
    status=$(awk 'toupper($0) ~ /^HTTP\// {code=$2} END {print code}' "$after_headers" 2>/dev/null || true)
    append_report "- 登录后回访 HTTP: ${status:-unknown}"
    if grep -Eq 'vscode-workbench-web-configuration|workbench\.js|Jupyter|jupyter|code-server' "$after_body" 2>/dev/null; then
      append_report "- 结果: link_access_ok（登录后回访返回应用页面）"
      return 0
    fi
  fi

  record_finding "${scope}/${cluster}: 真实入口访问未取得明确应用页面，HTTP 证据在 ${HTTP_DIR}"
  return 1
}

# 执行单个 HPC 集群的完整巡检。
inspect_hpc_cluster() {
  local cluster="$1"
  local cluster_safe="${cluster//[^A-Za-z0-9_]/_}"
  local out account partition home probe exist desktop_name login_node login_nodes shell_login_node login_node_safe desktop_json desktop_id display_id job_body submit_out job_id start_iso end_iso state outputs app_id app_body app_submit app_job_id sessions session_id connect_out

  section "HPC ${cluster}"
  scow_api "hpc_${cluster_safe}_cluster_info" "HPC 只读检查：集群概览" GET /api/dashboard/getClusterInfo clusterId="$cluster" >/dev/null || record_finding "${cluster}: getClusterInfo 返回非零"
  if grep -q 'NOT_EXIST_IN_ACTIVATED_CLUSTERS' "${RAW_DIR}/hpc_${cluster_safe}_cluster_info.out" 2>/dev/null; then
    record_finding "${cluster}: 不在默认运行时激活集群中，跳过创建类步骤"
    return
  fi
  scow_api "hpc_${cluster_safe}_nodes" "HPC 只读检查：节点状态" GET /api/dashboard/getClusterNodesInfo cluster="$cluster" >/dev/null || record_finding "${cluster}: 节点信息读取失败"
  scow_api "hpc_${cluster_safe}_notifications" "HPC 只读检查：通知" GET /api/notification/getUnreadMessages >/dev/null || record_finding "${cluster}: 通知接口读取失败"
  out=$(scow_api "hpc_${cluster_safe}_accounts" "HPC 参数来源：账户来自 /api/job/getAccounts" GET /api/job/getAccounts cluster="$cluster") || true
  account=$(json_from_file account "$out")
  if [[ -z "$account" ]]; then
    record_blocked "${cluster}: 无法从 /api/job/getAccounts 取得账户"
    return
  fi
  out=$(scow_api "hpc_${cluster_safe}_partitions" "HPC 参数来源：分区来自 /api/job/getAvailablePartitionsForCluster" GET /api/job/getAvailablePartitionsForCluster cluster="$cluster" accountName="$account") || true
  partition=$(json_from_file partition "$out")

  out=$(scow_api "hpc_${cluster_safe}_home" "HPC 文件探针：home 来自 /api/file/getHome" GET /api/file/getHome cluster="$cluster") || true
  home=$(json_from_file home "$out")
  if [[ -z "$home" ]]; then
    record_blocked "${cluster}: 无法取得 HPC home 路径"
    return
  fi
  probe="${home}/.scowctl_probe_${RUN_ID}.txt"
  HPC_PROBES+=("${cluster}|${probe}")
  scow_api_body "hpc_${cluster_safe}_probe_create" "HPC 文件探针：创建本轮唯一文件" POST /api/file/createFile "$(printf '{"cluster":"%s","path":"%s"}' "$cluster" "$probe")" >/dev/null || record_failure "${cluster}: HPC 文件探针创建失败"
  out=$(scow_api "hpc_${cluster_safe}_probe_exists" "HPC 文件探针：复核存在" GET /api/file/fileExist cluster="$cluster" path="$probe") || true
  exist=$(json_from_file exists "$out")
  [[ "$exist" == "false" ]] && record_failure "${cluster}: HPC 文件探针创建后不存在"
  scow_api "hpc_${cluster_safe}_probe_meta" "HPC 文件探针：读取元数据" GET /api/file/getFileMetadata cluster="$cluster" path="$probe" >/dev/null || record_finding "${cluster}: HPC 文件元数据读取失败"
  scow_api "hpc_${cluster_safe}_probe_delete" "HPC 文件探针：删除本轮文件" DELETE /api/file/deleteFile cluster="$cluster" path="$probe" >/dev/null || record_cleanup_failure "${cluster}: HPC 文件探针删除失败"
  out=$(scow_api "hpc_${cluster_safe}_probe_deleted" "HPC 文件探针：复核删除" GET /api/file/fileExist cluster="$cluster" path="$probe") || true
  exist=$(json_from_file exists "$out")
  if [[ "$exist" == "true" ]]; then
    record_cleanup_failure "${cluster}: HPC 文件探针删除后仍存在"
  else
    remove_hpc_probe_from_trap "$cluster" "$probe"
  fi

  out=$(scow_api "hpc_${cluster_safe}_cluster_configs" "HPC 桌面：从集群配置取得全部 loginNodes" GET /api/getClusterConfigFiles) || true
  mapfile -t login_nodes < <(json_from_file login-nodes "$out" "$cluster")
  scow_api_body "hpc_${cluster_safe}_desktops_before" "HPC 桌面：创建前查询现有桌面列表" POST /api/desktop/listDesktops "$(printf '{"clusters":[{"cluster":"%s","loginNodes":[]}]}' "$cluster")" >/dev/null || true
  if [[ "${#login_nodes[@]}" -gt 0 ]]; then
    scow_api "hpc_${cluster_safe}_desktop_create_help" "HPC 桌面：OpenAPI help" help POST /api/desktop/createDesktop >/dev/null || true
    scow_api "hpc_${cluster_safe}_desktop_kill_help" "HPC 桌面：OpenAPI help" help POST /api/desktop/killDesktop >/dev/null || true
    for login_node in "${login_nodes[@]}"; do
      [[ -z "$login_node" ]] && continue
      login_node_safe="${login_node//[^A-Za-z0-9_]/_}"
      run_capture "hpc_${cluster_safe}_shell_${login_node_safe}" "HPC 登录节点 shell：scowctl shell 执行 hostname" scowctl shell "$cluster" "$login_node" -- hostname >/dev/null || record_finding "${cluster}/${login_node}: scowctl shell hostname 失败"
      desktop_name="scowctl-inspect-desktop-${RUN_ID}-${login_node_safe}"
      scow_api_body "hpc_${cluster_safe}_desktop_create_${login_node_safe}" "HPC 桌面：loginNode 来自 /api/getClusterConfigFiles" POST /api/desktop/createDesktop "$(printf '{"cluster":"%s","desktopName":"%s","loginNode":"%s","remoteControlTool":"vnc","wm":"xfce"}' "$cluster" "$desktop_name" "$login_node")" >/dev/null || record_finding "${cluster}/${login_node}: 桌面创建失败"
      out=$(scow_api_body "hpc_${cluster_safe}_desktops_after_create_${login_node_safe}" "HPC 桌面：创建后列表复核并取 id/displayId" POST /api/desktop/listDesktops "$(printf '{"clusters":[{"cluster":"%s","loginNodes":[]}]}' "$cluster")") || true
      desktop_json=$(json_from_file desktop "$out" "$desktop_name")
      if [[ -n "$desktop_json" ]]; then
        desktop_id=$(printf '%s' "$desktop_json" | json_from_text job-id)
        display_id=$(printf '%s' "$desktop_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("displayId", ""), end="")')
        login_node=$(printf '%s' "$desktop_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("loginNode", ""), end="")')
        scow_api_body "hpc_${cluster_safe}_desktop_kill_${login_node_safe}" "HPC 桌面：使用 listDesktops 返回的 id/displayId/loginNode 清理" POST /api/desktop/killDesktop "$(printf '{"cluster":"%s","loginNode":"%s","id":%s,"displayId":%s}' "$cluster" "$login_node" "$desktop_id" "$display_id")" >/dev/null || record_cleanup_failure "${cluster}/${login_node}: 桌面关闭失败"
        scow_api_body "hpc_${cluster_safe}_desktops_after_kill_${login_node_safe}" "HPC 桌面：清理后复核列表" POST /api/desktop/listDesktops "$(printf '{"clusters":[{"cluster":"%s","loginNodes":[]}]}' "$cluster")" >/dev/null || record_cleanup_failure "${cluster}/${login_node}: 桌面清理复核失败"
      else
        record_finding "${cluster}/${login_node}: 桌面创建后未在列表中定位本轮桌面"
      fi
    done
  else
    record_finding "${cluster}: /api/getClusterConfigFiles 未提供 loginNodes，跳过 shell 与桌面创建"
  fi

  scow_api "hpc_${cluster_safe}_submit_help" "HPC 最小作业：OpenAPI help" help POST /api/job/submitJob >/dev/null || true
  scow_api "hpc_${cluster_safe}_cancel_help" "HPC 最小作业：OpenAPI help" help DELETE /api/job/cancelJob >/dev/null || true
  out=$(scow_api "hpc_${cluster_safe}_templates" "HPC 最小作业：查询作业模板列表；当前 OpenAPI 无模板详情接口时只用于证明接口可用" GET /api/job/listJobTemplates) || true
  job_body=$(json_from_file hpc-job-body "$out" "$cluster" "$account" "$partition" "$RUN_ID" "$home")
  submit_out=$(scow_api_body "hpc_${cluster_safe}_job_submit" "HPC 最小作业：body 来自模板/账户/分区真实返回，命令改为 hostname" POST /api/job/submitJob "$job_body") || record_finding "${cluster}: 最小作业提交返回非零"
  job_id=$(json_from_file job-id "$submit_out")
  if [[ -n "$job_id" ]]; then
    HPC_JOBS+=("${cluster}|${job_id}")
    start_iso=$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
    end_iso=$(date -u -d '30 minutes' +%Y-%m-%dT%H:%M:%SZ)
    for _ in 1 2 3 4 5 6; do
      out=$(scow_api "hpc_${cluster_safe}_job_state_${_}" "HPC 最小作业：getAllJobs 必填 cluster/startTime/endTime" GET /api/job/getAllJobs cluster="$cluster" startTime="$start_iso" endTime="$end_iso") || true
      state=$(json_from_file state "$out" "$job_id" "")
      [[ -n "$state" ]] && append_report "- job ${job_id} state=${state}"
      [[ "$state" =~ COMPLETED|FAILED|CANCELED|RUNNING ]] && break
      sleep 5
    done
    scow_api "hpc_${cluster_safe}_job_cancel" "HPC 最小作业：结束前取消仍未完成的本轮作业" DELETE /api/job/cancelJob cluster="$cluster" jobId="$job_id" >/dev/null || true
    remove_hpc_job_from_trap "$cluster" "$job_id"
    while IFS= read -r outputs; do
      [[ -z "$outputs" ]] && continue
      scow_api "hpc_${cluster_safe}_job_output_delete_$(basename "$outputs")" "HPC 最小作业：清理 submitJob 输出文件" DELETE /api/file/deleteFile cluster="$cluster" path="$outputs" >/dev/null || true
      scow_api "hpc_${cluster_safe}_job_output_check_$(basename "$outputs")" "HPC 最小作业：复核输出文件不存在" GET /api/file/fileExist cluster="$cluster" path="$outputs" >/dev/null || true
    done < <(printf '%s' "$job_body" | python3 -c 'import json,sys; d=json.load(sys.stdin); [print(d[k]) for k in ("output","outputPath","errorOutput","errorOutputPath") if d.get(k)]')
  else
    record_finding "${cluster}: 无法从 submitJob 返回值取得 jobId"
  fi

  out=$(scow_api "hpc_${cluster_safe}_apps" "HPC 应用：应用列表来源" GET /api/app/listAvailableApps cluster="$cluster") || true
  app_id=$(json_from_file app-id "$out")
  if [[ -n "$app_id" ]]; then
    scow_api "hpc_${cluster_safe}_app_meta_${app_id}" "HPC 应用：元数据来源" GET /api/app/getAppMetadata cluster="$cluster" appId="$app_id" >/dev/null || true
    out=$(scow_api "hpc_${cluster_safe}_app_last_${app_id}" "HPC 应用：历史提交参数来源" GET /api/app/getAppLastSubmission cluster="$cluster" appId="$app_id") || true
    app_body=$(json_from_file hpc-app-body "$out" "$cluster" "$app_id" "$RUN_ID")
    if [[ -n "$app_body" && "$app_body" != "{}" ]]; then
      app_submit=$(scow_api_body "hpc_${cluster_safe}_app_create_${app_id}" "HPC 应用：复用 getAppLastSubmission 并只调整本轮唯一字段" POST /api/app/createAppSession "$app_body") || record_finding "${cluster}: createAppSession 返回非零，按文档查询作业与会话"
      app_job_id=$(json_from_file job-id "$app_submit")
      scow_api "hpc_${cluster_safe}_app_sessions" "HPC 应用：getAppSessions 参数名使用 clusters" GET /api/app/getAppSessions clusters="$cluster" >/dev/null || true
      sessions="${RAW_DIR}/hpc_${cluster_safe}_app_sessions.out"
      [[ -z "$app_job_id" ]] && app_job_id=$(json_from_file job-id "$sessions")
      session_id=$(json_from_file session-id "$sessions" "$app_job_id" "$RUN_ID")
      if [[ -n "$app_job_id" ]]; then HPC_JOBS+=("${cluster}|${app_job_id}"); fi
      if [[ -n "$app_job_id" && -n "$session_id" ]]; then
        connect_ok=0
        for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
          state=$(json_from_file state "$sessions" "$app_job_id" "$session_id")
          if [[ "$state" == "RUNNING" ]]; then
            connect_out=$(scow_api_body "hpc_${cluster_safe}_app_connect_${app_id}" "HPC 应用：真实入口来自 connectToApp" POST /api/app/connectToApp "$(printf '{"cluster":"%s","jobId":%s,"sessionId":"%s"}' "$cluster" "$app_job_id" "$session_id")") || true
            if [[ "$(command_rc "hpc_${cluster_safe}_app_connect_${app_id}")" == 0 ]]; then
              curl_verify_entry hpc "$cluster" "$connect_out" || true
              connect_ok=1
              break
            fi
            if ! grep -q 'SESSION_NOT_AVAILABLE' "${RAW_DIR}/hpc_${cluster_safe}_app_connect_${app_id}.out" "${RAW_DIR}/hpc_${cluster_safe}_app_connect_${app_id}.err" 2>/dev/null; then
              record_finding "${cluster}: connectToApp 返回非零"
              break
            fi
          elif [[ "$state" =~ COMPLETED|FAILED|CANCELED|ENDED ]]; then
            record_finding "${cluster}: 应用会话状态为 ${state}，无法执行真实入口验证"
            break
          fi
          sleep 5
          scow_api "hpc_${cluster_safe}_app_sessions_retry_${attempt}" "HPC 应用：等待连接可用时复查会话列表" GET /api/app/getAppSessions clusters="$cluster" >/dev/null || true
          sessions="${RAW_DIR}/hpc_${cluster_safe}_app_sessions_retry_${attempt}.out"
          session_id=$(json_from_file session-id "$sessions" "$app_job_id" "$RUN_ID")
          [[ -n "$session_id" ]] || session_id=$(json_from_file session-id "${RAW_DIR}/hpc_${cluster_safe}_app_sessions.out" "$app_job_id" "$RUN_ID")
        done
        if [[ "$connect_ok" != 1 && ! -f "${RAW_DIR}/hpc_${cluster_safe}_app_connect_${app_id}.rc" ]]; then
          record_finding "${cluster}: 应用会话未进入可连接状态，跳过真实入口验证"
        elif [[ "$connect_ok" != 1 && "$(command_rc "hpc_${cluster_safe}_app_connect_${app_id}")" != 0 ]]; then
          record_finding "${cluster}: connectToApp 返回非零"
        fi
      else
        record_finding "${cluster}: 未能从真实返回定位本轮 HPC 应用 jobId/sessionId"
      fi
      if [[ -n "$app_job_id" ]]; then
        scow_api "hpc_${cluster_safe}_app_cancel_${app_job_id}" "HPC 应用：结束前清理本轮应用作业" DELETE /api/job/cancelJob cluster="$cluster" jobId="$app_job_id" >/dev/null || true
        remove_hpc_job_from_trap "$cluster" "$app_job_id"
      fi
    else
      record_finding "${cluster}: getAppLastSubmission 未提供可复用创建参数"
    fi
  else
    record_finding "${cluster}: 无可用 HPC 应用"
  fi
}

# 执行单个 AI 集群的完整巡检。
inspect_ai_cluster() {
  local cluster="$1"
  local cluster_safe="${cluster//[^A-Za-z0-9_]/_}"
  local out home probe exist app_id account partition image_body image_out image_id image_create_name image_failure_detail image_lookup image_status image_name image_tag image_status_ok attempt sessions hist_job hist_session params app_body app_out job_id session_id state connect_out dev_body dev_out dev_job dev_session

  section "AI ${cluster}"
  scow_api "ai_${cluster_safe}_dashboard" "AI 只读检查：集群概览" GET /ai/api/dashboard/cluster clusterId="$cluster" >/dev/null || record_finding "${cluster}: AI dashboard 读取失败"
  scow_api "ai_${cluster_safe}_nodes" "AI 只读检查：节点" GET /ai/api/dashboard/nodes clusterId="$cluster" >/dev/null || record_finding "${cluster}: AI nodes 读取失败"
  scow_api "ai_${cluster_safe}_notifications" "AI 只读检查：通知" GET /ai/api/notification/unread-messages >/dev/null || record_finding "${cluster}: AI 通知读取失败"
  out=$(scow_api "ai_${cluster_safe}_apps_all" "AI 应用列表来源" GET /ai/api/allAvailableAppsFromAllClusters) || true
  app_id=$(json_from_file app-id "$out")
  out=$(scow_api "ai_${cluster_safe}_home" "AI 文件与 WORK_DIR 来源" GET /ai/api/file/homeDir clusterId="$cluster") || true
  home=$(json_from_file home "$out")

  scow_api "ai_${cluster_safe}_image_help_create" "AI 镜像：OpenAPI help" help POST /ai/api/images >/dev/null || true
  scow_api "ai_${cluster_safe}_image_help_delete" "AI 镜像：OpenAPI help" help DELETE /ai/api/images/{id} >/dev/null || true
  out=$(scow_api "ai_${cluster_safe}_images_before" "AI 镜像：远程镜像历史来源" GET /ai/api/images clusterId="$cluster") || true
  image_body=$(json_from_file ai-image-body "$out" "$RUN_ID" "$cluster")
  if [[ -n "$image_body" ]]; then
    image_create_name="ai_${cluster_safe}_image_create"
    image_name=$(printf '%s' "$image_body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name", ""), end="")')
    image_tag=$(printf '%s' "$image_body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag", ""), end="")')
    if image_out=$(scow_api_body "$image_create_name" "AI 镜像：复用最近远程镜像记录并调整唯一字段" POST /ai/api/images "$image_body"); then
      image_status_ok=0
      for attempt in 1 2 3 4 5 6; do
        out=$(scow_api "ai_${cluster_safe}_images_status_${attempt}" "AI 镜像：创建后通过列表轮询本轮镜像 status" GET /ai/api/images clusterId="$cluster") || true
        image_lookup=$(json_from_file ai-image "$out" "$image_name" "$image_tag")
        if [[ -n "$image_lookup" ]]; then
          image_id=$(printf '%s' "$image_lookup" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id", ""), end="")')
          image_status=$(printf '%s' "$image_lookup" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", ""), end="")')
          append_report "- AI image ${image_name}:${image_tag} status=${image_status:-unknown}"
          if [[ "$image_status" == "FAILURE" ]]; then
            break
          fi
          if [[ "$image_status" == "CREATING" || "$image_status" == "CREATED" ]]; then
            image_status_ok=1
          fi
          [[ "$image_status" == "CREATED" ]] && break
        fi
        [[ "$attempt" == 6 ]] || sleep 5
      done
      if [[ -z "$image_lookup" ]]; then
        record_finding "${cluster}: AI 镜像提交接口返回 0，但 30 秒内未在镜像列表定位本轮镜像 ${image_name}:${image_tag}"
      elif [[ "$image_status" == "FAILURE" ]]; then
        record_finding "${cluster}: AI 镜像 ${image_name}:${image_tag} 状态为 FAILURE，不执行回滚；请自行查看上传失败原因"
      elif [[ "$image_status_ok" == 1 ]]; then
        if [[ -n "$image_id" ]]; then
          AI_IMAGES+=("$image_id")
          scow_api "ai_${cluster_safe}_image_delete_${image_id}" "AI 镜像：状态正常后删除本轮新建镜像" DELETE /ai/api/images/{id} id="$image_id" force=true isPlatformOwned=false >/dev/null || record_cleanup_failure "${cluster}: AI 镜像删除失败"
          scow_api "ai_${cluster_safe}_images_after" "AI 镜像：删除后复核列表" GET /ai/api/images clusterId="$cluster" >/dev/null || record_cleanup_failure "${cluster}: AI 镜像删除复核失败"
          remove_ai_image_from_trap "$image_id"
        else
          record_finding "${cluster}: AI 镜像 ${image_name}:${image_tag} 状态正常但列表中未识别 image id，无法执行回滚"
        fi
      else
        record_finding "${cluster}: AI 镜像 ${image_name}:${image_tag} 30 秒内状态为 ${image_status}，不判定为正常创建状态"
      fi
    else
      image_failure_detail=$(command_failure_detail "$image_create_name")
      record_finding "${cluster}: AI 镜像创建调用失败${image_failure_detail:+：${image_failure_detail}}"
    fi
  else
    record_finding "${cluster}: 未从 /ai/api/images 取得可复用远程镜像参数，跳过镜像创建"
  fi

  sessions=$(scow_api_body "ai_${cluster_safe}_sessions_history" "AI 应用：历史会话列表来源" POST /ai/api/appSessions/list "$(printf '{"clusterId":"%s","page":1,"pageSize":20}' "$cluster")") || true
  app_body=""
  hist_job=""
  hist_session=""
  while IFS=$'\t' read -r candidate_job candidate_session candidate_app; do
    [[ -z "$candidate_job" || -z "$candidate_session" ]] && continue
    params=$(scow_api "ai_${cluster_safe}_submission_params_${candidate_job}" "AI 应用：历史创建参数来源；404 时尝试下一条真实历史会话" GET /ai/api/appSessions/{jobId}/submissionParameters jobId="$candidate_job" clusterId="$cluster" sessionId="$candidate_session") || true
    app_body=$(json_from_file ai-app-body "$params" "$cluster" "$RUN_ID" "$home")
    if [[ -n "$app_body" && "$app_body" != "{}" ]]; then
      hist_job="$candidate_job"
      hist_session="$candidate_session"
      [[ -n "$candidate_app" ]] && app_id="$candidate_app"
      append_report "- AI 历史参数选中 jobId=${hist_job}, sessionId=${hist_session}"
      break
    fi
    record_finding "${cluster}: 历史会话 jobId=${candidate_job} submissionParameters 不可用，尝试下一条"
  done < <(json_from_file ai-history-candidates "$sessions")
  if [[ -n "$hist_job" && -n "$hist_session" && -n "$app_body" && "$app_body" != "{}" ]]; then
      scow_api "ai_${cluster_safe}_app_create_help" "AI 应用：OpenAPI help" help POST /ai/api/appSessions >/dev/null || true
      app_out=$(scow_api_body "ai_${cluster_safe}_app_create" "AI 应用：复用 submissionParameters，保持字面量字段并补 WORK_DIR" POST /ai/api/appSessions "$app_body") || record_finding "${cluster}: AI 应用创建返回非零"
      job_id=$(json_from_file job-id "$app_out")
      if [[ -n "$job_id" ]]; then AI_JOBS+=("${cluster}|${job_id}"); fi
      for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
        out=$(scow_api_body "ai_${cluster_safe}_app_sessions_${_}" "AI 应用：创建后从列表取得真实 sessionId" POST /ai/api/appSessions/list "$(printf '{"clusterId":"%s","page":1,"pageSize":5}' "$cluster")") || true
        session_id=$(json_from_file session-id "$out" "$job_id" "$RUN_ID")
        state=$(json_from_file state "$out" "$job_id" "$session_id")
        [[ -n "$state" ]] && append_report "- AI app job ${job_id} state=${state}"
        [[ -n "$session_id" && "$state" =~ RUNNING|COMPLETED|FAILED|CANCELED ]] && break
        sleep 5
      done
      if [[ -n "$job_id" && -n "$session_id" ]]; then
        scow_api "ai_${cluster_safe}_app_check_${job_id}" "AI 应用：checkConnectivity" GET /ai/api/appSessions/{jobId}/checkConnectivity jobId="$job_id" clusterId="$cluster" sessionId="$session_id" >/dev/null || record_finding "${cluster}: AI 应用 checkConnectivity 返回非零"
        connect_out=$(scow_api_body "ai_${cluster_safe}_app_connect_${session_id}" "AI 应用：真实入口来自 /connect" POST /ai/api/appSessions/{sessionId}/connect "$(printf '{"cluster":"%s"}' "$cluster")" sessionId="$session_id") || record_finding "${cluster}: AI 应用 connect 返回非零"
        curl_verify_entry ai "$cluster" "$connect_out" || true
      else
        record_finding "${cluster}: AI 应用创建后未从列表取得真实 sessionId"
      fi
      if [[ -n "$job_id" ]]; then
        scow_api "ai_${cluster_safe}_app_delete_${job_id}" "AI 应用：删除本轮 job" DELETE /ai/api/jobs/{jobId} jobId="$job_id" cluster="$cluster" >/dev/null || record_cleanup_failure "${cluster}: AI 应用 job 删除失败"
        remove_ai_job_from_trap "$cluster" "$job_id"
      fi
  else
    record_blocked "${cluster}: 无可用历史 AI 应用 submissionParameters，无法安全复用真实参数创建应用"
  fi

  if [[ -n "${app_body:-}" && "${app_body:-}" != "{}" ]]; then
    scow_api "ai_${cluster_safe}_devhost_help" "AI 开发机：OpenAPI help" help POST /ai/api/devHost >/dev/null || true
    scow_api "ai_${cluster_safe}_devhost_connect_help" "AI 开发机：OpenAPI help" help POST /ai/api/appSessions/{sessionId}/connectDevHostApp >/dev/null || true
    dev_body=$(printf '%s' "$app_body" | python3 -c 'import json, sys; body=json.load(sys.stdin); body.setdefault("devHostName", "scowctl-inspect-devhost"); body.setdefault("maxTimeMinutes", 60); print(json.dumps(body, ensure_ascii=False))')
    dev_out=$(scow_api_body "ai_${cluster_safe}_devhost_create" "AI 开发机：复用 AI 应用真实历史参数并保留 WORK_DIR，补 devHostName/maxTimeMinutes 必填字段" POST /ai/api/devHost "$dev_body") || record_finding "${cluster}: devHost 创建返回非零"
    dev_job=$(json_from_file job-id "$dev_out")
    if [[ -n "$dev_job" ]]; then AI_JOBS+=("${cluster}|${dev_job}"); fi
    out=$(scow_api_body "ai_${cluster_safe}_devhost_sessions" "AI 开发机：从 appSessions/list 获取真实 sessionId" POST /ai/api/appSessions/list "$(printf '{"clusterId":"%s","page":1,"pageSize":5}' "$cluster")") || true
    dev_session=$(json_from_file session-id "$out" "$dev_job" "$RUN_ID")
    state=$(json_from_file state "$out" "$dev_job" "$dev_session")
    if [[ -n "$dev_job" && -n "$dev_session" ]]; then
      dev_ready=0
      # 开发机可能先排队，最多等约 30 秒，RUNNING 后才做连接验证。
      for attempt in 1 2 3 4 5 6; do
        if [[ "$state" == "RUNNING" ]]; then
          dev_ready=1
          break
        fi
        if [[ "$state" =~ COMPLETED|FAILED|CANCELED ]]; then
          break
        fi
        sleep 5
        out=$(scow_api_body "ai_${cluster_safe}_devhost_sessions_wait_${attempt}" "AI 开发机：等待 devHost 进入 RUNNING 时复查会话列表" POST /ai/api/appSessions/list "$(printf '{"clusterId":"%s","page":1,"pageSize":5}' "$cluster")") || true
        dev_session=$(json_from_file session-id "$out" "$dev_job" "$RUN_ID")
        state=$(json_from_file state "$out" "$dev_job" "$dev_session")
      done
      if [[ "$dev_ready" == "1" ]]; then
        scow_api "ai_${cluster_safe}_devhost_check_${dev_job}" "AI 开发机：checkDevHostConnectivity" GET /ai/api/appSessions/{jobId}/checkDevHostConnectivity jobId="$dev_job" clusterId="$cluster" sessionId="$dev_session" appName="$app_id" >/dev/null || record_finding "${cluster}: devHost connectivity 返回非零"
        connect_out=$(scow_api_body "ai_${cluster_safe}_devhost_connect_${dev_session}" "AI 开发机：真实入口来自 connectDevHostApp" POST /ai/api/appSessions/{sessionId}/connectDevHostApp "$(printf '{"cluster":"%s","appName":"%s"}' "$cluster" "$app_id")" sessionId="$dev_session") || record_finding "${cluster}: connectDevHostApp 返回非零"
        curl_verify_entry ai "$cluster" "$connect_out" || true
      elif [[ -n "$state" ]]; then
        append_report "- devHost job ${dev_job} state=${state}，30 秒内未进入 RUNNING，跳过本轮连接验证"
      else
        append_report "- devHost job ${dev_job} 未取得可判定状态，跳过本轮连接验证"
      fi
    else
      record_finding "${cluster}: devHost 未取得真实 jobId/sessionId/appName，跳过真实访问"
    fi
    if [[ -n "$dev_job" ]]; then
      scow_api "ai_${cluster_safe}_devhost_delete_${dev_job}" "AI 开发机：删除本轮 job" DELETE /ai/api/jobs/{jobId} jobId="$dev_job" cluster="$cluster" >/dev/null || record_cleanup_failure "${cluster}: devHost job 删除失败"
      remove_ai_job_from_trap "$cluster" "$dev_job"
    fi
  fi

  if [[ -n "$home" ]]; then
    probe="${home}/.scowctl_probe_${RUN_ID}.txt"
    AI_PROBES+=("${cluster}|${probe}")
    scow_api "ai_${cluster_safe}_file_list" "AI 文件探针：列目录" GET /ai/api/file/listDirectory clusterId="$cluster" path="$home" >/dev/null || record_finding "${cluster}: AI listDirectory 返回非零"
    scow_api_body "ai_${cluster_safe}_probe_create" "AI 文件探针：创建本轮唯一文件" POST /ai/api/file/createFile "$(printf '{"clusterId":"%s","path":"%s"}' "$cluster" "$probe")" >/dev/null || record_failure "${cluster}: AI 文件探针创建失败"
    out=$(scow_api "ai_${cluster_safe}_probe_exists" "AI 文件探针：复核存在" GET /ai/api/file/checkExist clusterId="$cluster" path="$probe") || true
    exist=$(json_from_file exists "$out")
    [[ "$exist" == "false" ]] && record_failure "${cluster}: AI 文件探针创建后不存在"
    scow_api_body "ai_${cluster_safe}_probe_delete" "AI 文件探针：删除本轮文件" POST /ai/api/file/delete "$(printf '{"clusterId":"%s","path":"%s","target":"FILE"}' "$cluster" "$probe")" >/dev/null || record_cleanup_failure "${cluster}: AI 文件探针删除失败"
    out=$(scow_api "ai_${cluster_safe}_probe_deleted" "AI 文件探针：复核删除" GET /ai/api/file/checkExist clusterId="$cluster" path="$probe") || true
    exist=$(json_from_file exists "$out")
    if [[ "$exist" == "true" ]]; then
      record_cleanup_failure "${cluster}: AI 文件探针删除后仍存在"
    else
      remove_ai_probe_from_trap "$cluster" "$probe"
    fi
  else
    record_blocked "${cluster}: 无法取得 AI homeDir，跳过 AI 文件探针"
  fi
}

append_report "# scowctl inspection report ${RUN_ID}"
append_report "- 手册: ${DOC_PATH}"
append_report "- 工作目录: ${WORKDIR}"
append_report "- 约束: 查询/创建/状态/清理使用 scowctl；只有真实入口访问使用 curl；不输出认证密钥明文。"

section "前置检查与登录"
for cmd in python3 scowctl curl awk; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    record_blocked "缺少命令: ${cmd}"
  fi
done
[[ "$BLOCKED" -gt 0 ]] && { append_report "最终结论：blocked"; printf '报告: %s\n' "$REPORT"; exit 2; }

run_capture "pre_scowctl_help" "前置检查：scowctl 顶层帮助" scowctl --help >/dev/null || record_blocked "scowctl --help 失败"
run_capture "pre_scowctl_api_help" "前置检查：scowctl api 帮助" scowctl api --help >/dev/null || record_blocked "scowctl api --help 失败"
profile_out=$(run_capture "pre_profile_show" "前置检查：读取 profile，提取 baseUrl" scowctl profile show) || true
SCOW_BASE_URL="${SCOW_BASE_URL:-$(json_from_file base-url "$profile_out")}"
SCOW_BASE_URL="${SCOW_BASE_URL%% }"
if [[ -z "$SCOW_BASE_URL" ]]; then
  record_finding "profile show 未提取到 baseUrl；真实入口访问可能无法执行"
else
  if [[ ! "$SCOW_BASE_URL" =~ ^https?:// ]]; then
    SCOW_BASE_URL="http://${SCOW_BASE_URL}"
  fi
  SCOW_BASE_URL="${SCOW_BASE_URL%/}"
  append_report "- SCOW_BASE_URL 来源: scowctl profile show 或环境变量，值=${SCOW_BASE_URL}"
fi

if [[ -n "${SCOW_AUTH_USER:-}" && -n "${SCOW_AUTH_SECRET:-}" ]]; then
  if [[ -n "$SCOW_BASE_URL" ]]; then
    run_capture "pre_login_env" "登录：使用环境变量 SCOW_AUTH_USER/SCOW_AUTH_SECRET，secret 不写入报告" scowctl login "$SCOW_BASE_URL" --auth-user "$SCOW_AUTH_USER" --auth-secret "$SCOW_AUTH_SECRET" >/dev/null || record_finding "环境变量登录失败；继续尝试已登录 profile"
  else
    record_finding "设置了 SCOW_AUTH_USER/SCOW_AUTH_SECRET，但缺少 SCOW_BASE_URL，跳过显式登录"
  fi
fi

run_capture "pre_api_refresh" "前置检查：刷新 OpenAPI 缓存" scowctl api refresh --verbose >/dev/null || record_blocked "OpenAPI refresh 失败"
portal_user_out=$(scow_api "pre_user_portal" "当前用户来源：/api/getUserInfo" GET /api/getUserInfo) || true
ai_user_out=$(scow_api "pre_user_ai" "当前用户与 token 来源：/ai/api/auth/userInfo" GET /ai/api/auth/userInfo) || true
scow_api "pre_mis_status" "权限检查：/mis/api/dashboard/status" GET /mis/api/dashboard/status >/dev/null || record_finding "MIS dashboard status 返回非零，可能权限不足或接口异常"
SCOW_USER_ID="${SCOW_USER_ID:-$(json_from_file user-id "$portal_user_out")}"
SCOW_USER_ID="${SCOW_USER_ID%% }"
if [[ -z "$SCOW_USER_ID" ]]; then
  SCOW_USER_ID="$(json_from_file user-id "$ai_user_out")"
fi
SCOW_API_AUTH_TOKEN="${SCOW_API_AUTH_TOKEN:-$(json_from_file token "$ai_user_out")}"
SCOW_API_AUTH_TOKEN="${SCOW_API_AUTH_TOKEN%% }"
if [[ -z "$SCOW_USER_ID" ]]; then
  record_blocked "无法从用户信息接口取得 SCOW_USER_ID"
else
  append_report "- SCOW_USER_ID 来源: /api/getUserInfo 或 /ai/api/auth/userInfo，值=${SCOW_USER_ID}"
fi
if [[ -z "$SCOW_API_AUTH_TOKEN" ]]; then
  record_finding "未从 /ai/api/auth/userInfo 取得 token；curl 真实入口验证将只带 user id header"
else
  append_report "- SCOW_API_AUTH_TOKEN 来源: /ai/api/auth/userInfo；报告中不展示明文"
fi
[[ "$BLOCKED" -gt 0 ]] && { append_report "最终结论：blocked"; printf '报告: %s\n' "$REPORT"; exit 2; }

section "集群分类"
portal_clusters_out=$(scow_api "clusters_portal_visible" "PORTAL_VISIBLE_CLUSTERS 来源：/api/getUserAssociatedClusterIds" GET /api/getUserAssociatedClusterIds userId="$SCOW_USER_ID") || true
ai_clusters_out=$(scow_api "clusters_ai_defined" "AI_DEFINED_CLUSTERS 来源：/ai/api/config/scowCluster" GET /ai/api/config/scowCluster) || true
active_clusters_out=$(scow_api "clusters_activated" "ACTIVATED_CLUSTERS 来源：/api/getClustersRuntimeInfo" GET /api/getClustersRuntimeInfo) || true
mapfile -t PORTAL_VISIBLE_CLUSTERS < <(json_from_file portal-clusters "$portal_clusters_out")
mapfile -t AI_DEFINED_CLUSTERS < <(json_from_file ai-clusters "$ai_clusters_out")
mapfile -t ACTIVATED_CLUSTERS < <(json_from_file active-clusters "$active_clusters_out")
HPC_CLUSTERS=()
for cluster in "${PORTAL_VISIBLE_CLUSTERS[@]}"; do
  if ! contains_item "$cluster" "${AI_DEFINED_CLUSTERS[@]}"; then
    HPC_CLUSTERS+=("$cluster")
  fi
done
AI_CLUSTERS=("${AI_DEFINED_CLUSTERS[@]}")
append_report "- PORTAL_VISIBLE_CLUSTERS=$(join_by_comma "${PORTAL_VISIBLE_CLUSTERS[@]}")"
append_report "- AI_DEFINED_CLUSTERS=$(join_by_comma "${AI_DEFINED_CLUSTERS[@]}")"
append_report "- ACTIVATED_CLUSTERS=$(join_by_comma "${ACTIVATED_CLUSTERS[@]}")"
append_report "- HPC_CLUSTERS=$(join_by_comma "${HPC_CLUSTERS[@]}")"
append_report "- AI_CLUSTERS=$(join_by_comma "${AI_CLUSTERS[@]}")"

if [[ "${#HPC_CLUSTERS[@]}" -eq 0 && "${#AI_CLUSTERS[@]}" -eq 0 ]]; then
  record_blocked "未能分类出 HPC 或 AI 集群"
fi
[[ "$BLOCKED" -gt 0 ]] && { append_report "最终结论：blocked"; printf '报告: %s\n' "$REPORT"; exit 2; }

for cluster in "${HPC_CLUSTERS[@]}"; do
  inspect_hpc_cluster "$cluster"
done

for cluster in "${AI_CLUSTERS[@]}"; do
  inspect_ai_cluster "$cluster"
done

trap - EXIT

section "清理复核"
if [[ "${#HPC_PROBES[@]}" -gt 0 || "${#AI_PROBES[@]}" -gt 0 || "${#HPC_JOBS[@]}" -gt 0 || "${#AI_JOBS[@]}" -gt 0 || "${#AI_IMAGES[@]}" -gt 0 ]]; then
  append_report "- 仍有 trap 清理队列项目，执行最终兜底清理。"
  final_trap_cleanup
else
  append_report "- 本轮已知可回滚资源均已执行清理路径。"
fi

section "最终结论"
append_report "- findings=${FINDINGS}"
append_report "- failures=${FAILURES}"
append_report "- blocked=${BLOCKED}"
append_report "- cleanup_failures=${CLEANUP_FAILURES}"
if [[ "$FINDINGS" -gt 0 ]]; then
  append_report "- finding_items:"
  for finding in "${FINDING_ITEMS[@]}"; do
    append_report "  - ${finding}"
  done
fi
if [[ "$BLOCKED" -gt 0 ]]; then
  append_report "最终结论：blocked"
  conclusion="blocked"
elif [[ "$FAILURES" -gt 0 || "$CLEANUP_FAILURES" -gt 0 ]]; then
  append_report "最终结论：fail"
  conclusion="fail"
elif [[ "$FINDINGS" -gt 0 ]]; then
  append_report "最终结论：pass_with_findings"
  conclusion="pass_with_findings"
else
  append_report "最终结论：pass"
  conclusion="pass"
fi

printf '\n巡检完成：%s\n报告：%s\n原始输出目录：%s\n' "$conclusion" "$REPORT" "$RAW_DIR"
case "$conclusion" in
  pass) exit 0 ;;
  pass_with_findings) exit 1 ;;
  blocked) exit 2 ;;
  fail) exit 3 ;;
esac
