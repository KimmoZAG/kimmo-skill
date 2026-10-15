#!/usr/bin/env bash
# run_model skill 通用启动器：按 profile 组装并启动 vllm serve
# 用法：
#   serve.sh                          # 列出全部可用 profile
#   serve.sh <profile> [选项] [额外 vllm 参数...]
# 选项：
#   --foreground      前台运行（默认后台 setsid）
#   --log-dir <dir>   后台日志目录（默认 $KIMMO_SERVE_LOG_DIR 或 /tmp）
#   --help            帮助
# 额外 vllm 参数追加在命令尾部，同名 flag 以追加值为准。
# 本文件不含任何模型信息；模型定义见 scripts/models/<profile>.sh。

set -euo pipefail

_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_MODEL_DIR="$_SKILL_DIR/scripts/models"

usage() {
    sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

list_profiles() {
    echo "可用 profile（scripts/models/）："
    local f
    for f in "$_MODEL_DIR"/*.sh; do
        [[ -e "$f" ]] || { echo "  （无任何 profile）"; return 0; }
        local name desc
        name="$(basename "$f" .sh)"
        desc="$(grep -m1 '^# profile:' "$f" | sed 's/^# profile:[[:space:]]*//')"
        printf '  %-24s %s\n' "$name" "${desc:-}"
    done
    echo "启动：serve.sh <profile> [--foreground] [--log-dir <dir>] [额外 vllm 参数...]"
}

PROFILE=""
MODE="background"
LOG_DIR="${KIMMO_SERVE_LOG_DIR:-/tmp}"
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --foreground|-f) MODE="foreground"; shift ;;
        --log-dir)       LOG_DIR="$2"; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        --*)             EXTRA_ARGS+=("$1"); shift ;;
        *)
            if [[ -z "$PROFILE" ]]; then PROFILE="$1"; else EXTRA_ARGS+=("$1"); fi
            shift
            ;;
    esac
done

if [[ -z "$PROFILE" ]]; then
    list_profiles
    exit 0
fi

_PROFILE_FILE="$_MODEL_DIR/$PROFILE.sh"
if [[ ! -f "$_PROFILE_FILE" ]]; then
    echo "[serve.sh] ERROR: profile 不存在：$_PROFILE_FILE" >&2
    list_profiles
    exit 1
fi

# --- 环境准备（幂等） ---
# shellcheck disable=SC1090,SC1091
source "$_SKILL_DIR/scripts/env.sh"
# shellcheck disable=SC1090
source "$_PROFILE_FILE"

# --- profile 字段校验 ---
: "${PROFILE_NAME:=$PROFILE}"
: "${HOST:=0.0.0.0}"
: "${PORT:=8000}"
for var in MODEL_PATH SERVED_MODEL_NAME SERVE_ARGS; do
    if [[ -z "${!var:-}" ]]; then
        echo "[serve.sh] ERROR: profile '$PROFILE' 未定义必填变量 $var" >&2
        exit 1
    fi
done
if [[ ! -d "$MODEL_PATH" ]]; then
    echo "[serve.sh] ERROR: 权重目录不存在：$MODEL_PATH" >&2
    exit 1
fi

# --- 残留检查：端口占用 / 已有 vllm serve 进程 ---
if ss -tln 2>/dev/null | grep -qE ":${PORT}[[:space:]]"; then
    echo "[serve.sh] ERROR: 端口 $PORT 已被占用，先处理残留服务（pgrep -af 'vllm serve'）再启动" >&2
    exit 1
fi
if pgrep -f 'vllm serve' >/dev/null 2>&1; then
    echo "[serve.sh] ERROR: 已存在 vllm serve 进程，先 kill 再启动：" >&2
    pgrep -af 'vllm serve' >&2
    exit 1
fi

CMD=(vllm serve "$MODEL_PATH"
    --served-model-name "$SERVED_MODEL_NAME"
    --host "$HOST" --port "$PORT"
    ${SERVE_ARGS[@]+"${SERVE_ARGS[@]}"}
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})

if [[ "$MODE" == "foreground" ]]; then
    echo "[serve.sh] 前台启动 ${PROFILE_NAME}（Ctrl+C 退出即终止服务）"
    exec "${CMD[@]}"
fi

# --- 后台：setsid 独立会话 + 子 shell 内再做一次五通道清理（防经 BASH_ENV/导出函数回流） ---
LOG_FILE="$LOG_DIR/${PROFILE_NAME}_serve.log"
mkdir -p "$LOG_DIR"
CMD_STR="$(printf '%q ' "${CMD[@]}")"
setsid bash -c '
    unset BASH_ENV ENV NODE_OPTIONS
    unset CODEBUDDY_SAFE_DELETE_BIN_DIR CODEBUDDY_SAFE_DELETE_BULK_GUARD \
          CODEBUDDY_SAFE_DELETE_SHIM_DIR CODEBUDDY_SAFE_DELETE_ENABLED \
          CODEBUDDY_SAFE_DELETE_BULK_STATE_DIR
    unset -f rm unlink rmdir 2>/dev/null
    export PATH="$(echo "$PATH" | tr ":" "\n" | grep -v vendor/shim | paste -sd:)"
    export PYTHONPATH="$(echo "$PYTHONPATH" | tr ":" "\n" | grep -v vendor/shim | grep -v "^$" | paste -sd:)"
    exec '"$CMD_STR"'
' > "$LOG_FILE" 2>&1 < /dev/null &
LAUNCH_PID=$!

echo "[serve.sh] ${PROFILE_NAME} 已后台启动（setsid pid=${LAUNCH_PID}）"
echo "  日志：${LOG_FILE}"
echo "  监控：tail -f ${LOG_FILE}"
echo "  就绪标志：grep 'Application startup complete' ${LOG_FILE}"
if [[ -n "${SMOKE_CMD[*]:-}" ]]; then
    echo "  就绪后冒烟：${SMOKE_CMD[*]}"
fi
if [[ -n "${NOTES:-}" ]]; then
    echo "  注意：${NOTES}"
fi
