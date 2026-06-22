# scow-inspection

通过 `scowctl` 进行 SCOW 运维巡检。

## 文件

- `scripts/scowctl-inspection.sh`：自动化巡检脚本。
- `docs/scowctl-巡检命令行流程.md`：手工巡检流程与脚本行为说明。

## 使用

```bash
SCOW_BASE_URL='<scow_base_url>' \
SCOW_AUTH_USER='<auth_user>' \
SCOW_AUTH_SECRET='<auth_secret>' \
./scripts/scowctl-inspection.sh -v
```

参数：

- `-v`：打印步骤级日志。
- `-vv`：打印步骤级日志，并同步输出每条命令的 stdout/stderr。
- `-h`：显示帮助。

脚本会在 `/tmp/scowctl-inspection-<timestamp>` 下生成报告、原始命令输出和 HTTP 证据。
