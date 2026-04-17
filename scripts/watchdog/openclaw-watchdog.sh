#!/bin/bash
#
# openclaw-watchdog.sh
# 系统级 watchdog - 独立于 wrapper 进程生命周期
#
# 设计原则：
# - 外部性：不依赖被监控进程存活
# - 独立性：有自己的生命周期（系统 cron）
# - 职责单一：只做探活；恢复动作委派给 supervisord
#
# 探活：对 INTERNAL_GATEWAY_HOST:INTERNAL_GATEWAY_PORT 做 TCP connect，
#   和 wrapper 内部的 probeGateway() 语义一致（gateway 主要走 WebSocket，
#   HTTP GET / 在 token 认证下会返 401，不能用 curl -f）。
# 恢复：`supervisorctl restart openclaw-wrapper`，让 supervisord 单点管理
#   wrapper 生命周期，避免和 wrapper 自己 spawn 的 gateway 抢端口。
#
# 部署：/usr/local/bin/openclaw-watchdog.sh
# Cron: /etc/cron.d/openclaw-watchdog
#

set -euo pipefail

# Cron 环境 PATH 修复
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

# 配置（可通过环境变量覆盖）
LOG_FILE="${WATCHDOG_LOG:-/var/log/openclaw-watchdog.log}"
MAX_LOG_LINES=1000
GATEWAY_HOST="${INTERNAL_GATEWAY_HOST:-127.0.0.1}"
GATEWAY_PORT="${INTERNAL_GATEWAY_PORT:-18789}"
PROBE_TIMEOUT="${GATEWAY_PROBE_TIMEOUT:-3}"
COOLDOWN_FILE="${WATCHDOG_COOLDOWN_FILE:-/tmp/openclaw-watchdog-cooldown}"
COOLDOWN_SECONDS="${WATCHDOG_COOLDOWN_SECONDS:-300}"
PID_FILE="${WATCHDOG_PID_FILE:-/tmp/openclaw-watchdog.pid}"
WRAPPER_PROGRAM="${WATCHDOG_WRAPPER_PROGRAM:-openclaw-wrapper}"
SUPERVISOR_SOCK="${WATCHDOG_SUPERVISOR_SOCK:-unix:///var/run/supervisor.sock}"

# 防止重复运行
if [[ -f "$PID_FILE" ]]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "$(date -Iseconds): Another watchdog instance is running (PID: $OLD_PID), exiting" >&2
        exit 1
    fi
fi
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

log() {
    echo "$(date -Iseconds): $1" | tee -a "$LOG_FILE"
}

truncate_log() {
    if [[ -f "$LOG_FILE" ]]; then
        local lines
        lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ "$lines" -gt "$MAX_LOG_LINES" ]]; then
            tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp"
            mv "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    fi
}

# TCP 探活：connect 成功即认为存活。
# 对应 wrapper src/server.js 里的 probeGateway()。
check_gateway() {
    if timeout "$PROBE_TIMEOUT" bash -c ">/dev/tcp/${GATEWAY_HOST}/${GATEWAY_PORT}" 2>/dev/null; then
        return 0
    fi
    return 1
}

# 让 supervisord 去重启 wrapper，它会负责 spawn gateway 子进程。
restart_wrapper() {
    if [[ -f "$COOLDOWN_FILE" ]]; then
        local last_restart now elapsed
        last_restart=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
        now=$(date +%s)
        elapsed=$((now - last_restart))
        if [[ "$elapsed" -lt "$COOLDOWN_SECONDS" ]]; then
            log "Cooldown active, skipping restart (last: ${elapsed}s ago, need ${COOLDOWN_SECONDS}s)"
            return 1
        fi
    fi

    log "Gateway unhealthy (tcp ${GATEWAY_HOST}:${GATEWAY_PORT} unreachable), restarting ${WRAPPER_PROGRAM} via supervisorctl"

    if supervisorctl -s "$SUPERVISOR_SOCK" restart "$WRAPPER_PROGRAM" >> "$LOG_FILE" 2>&1; then
        date +%s > "$COOLDOWN_FILE"
        # supervisord startsecs=5 + gateway ready ~数秒，给 15s 宽限。
        sleep 15
        if check_gateway; then
            log "Gateway recovered after supervisorctl restart"
            return 0
        else
            log "supervisorctl restart ran but gateway still unreachable"
            return 1
        fi
    else
        log "ERROR: supervisorctl restart ${WRAPPER_PROGRAM} failed"
        return 1
    fi
}

main() {
    truncate_log

    if check_gateway; then
        exit 0
    fi

    if restart_wrapper; then
        exit 0
    else
        exit 1
    fi
}

main "$@"
