#!/bin/bash
#
# openclaw-watchdog.sh
# 系统级 watchdog - 独立于 gateway 进程生命周期
#
# 设计原则：
# - 外部性：不依赖被监控进程存活
# - 独立性：有自己的生命周期（系统 cron）
# - 有效性：能直接触发重启，不只是记录日志
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
CHECK_URL="${GATEWAY_HEALTH_URL:-http://127.0.0.1:18792/}"
COOLDOWN_FILE="${WATCHDOG_COOLDOWN_FILE:-/tmp/openclaw-watchdog-cooldown}"
COOLDOWN_SECONDS=300
CHECK_TIMEOUT="${GATEWAY_CHECK_TIMEOUT:-10}"
PID_FILE="${WATCHDOG_PID_FILE:-/tmp/openclaw-watchdog.pid}"

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

# 日志函数
log() {
    echo "$(date -Iseconds): $1" | tee -a "$LOG_FILE"
}

# 截断日志防止膨胀
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

# 检查 gateway 健康状态
check_gateway() {
    if curl -sf --max-time "$CHECK_TIMEOUT" "$CHECK_URL" > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

# 获取 gateway PID（如果存在）
get_gateway_pid() {
    pgrep -f "openclaw-gateway" 2>/dev/null || echo ""
}

# 重启 gateway
restart_gateway() {
    # 检查冷却期
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
    
    log "Gateway unhealthy, attempting restart"
    
    # 先尝试优雅停止（如果进程还在）
    local pid
    pid=$(get_gateway_pid)
    if [[ -n "$pid" ]]; then
        log "Found gateway PID: $pid, sending SIGTERM"
        kill -TERM "$pid" 2>/dev/null || true
        sleep 2
        # 如果还在，强制结束
        if kill -0 "$pid" 2>/dev/null; then
            log "Gateway still running, sending SIGKILL"
            kill -KILL "$pid" 2>/dev/null || true
            sleep 1
        fi
    fi
    
    # 启动 gateway
    log "Starting gateway..."
    if openclaw gateway start >> "$LOG_FILE" 2>&1; then
        # 记录重启时间
        date +%s > "$COOLDOWN_FILE"
        sleep 3
        if check_gateway; then
            log "Gateway restarted successfully"
            return 0
        else
            log "Gateway start command succeeded but health check failed"
            return 1
        fi
    else
        log "Gateway start command failed"
        return 1
    fi
}

# 主逻辑
main() {
    truncate_log
    
    if check_gateway; then
        # 健康，静默退出（可选：记录 verbose 日志）
        exit 0
    fi
    
    # 不健康，尝试重启
    if restart_gateway; then
        exit 0
    else
        log "ERROR: Failed to restart gateway"
        exit 1
    fi
}

main "$@"
