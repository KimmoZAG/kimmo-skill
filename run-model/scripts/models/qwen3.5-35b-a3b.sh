#!/usr/bin/env bash
# profile: Qwen3.5-35B-A3B —— Qwen3.5 MoE（混合注意力 + GDN），graph 模式 TP=2
# 完整参数依据 / 启动时间线 / 冒烟与压测方法：references/models.md 第 1 节

PROFILE_NAME="qwen3.5-35b-a3b"
MODEL_PATH="/data/shared_upload/models/vspec/Qwen3.5-35B-A3B"
SERVED_MODEL_NAME="Qwen3.5-35B-A3B"
HOST="0.0.0.0"
PORT=8000

# 必须用 graph 模式：eager 下约 3-5 tok/s 不可用，graph 模式约 70 tok/s
# 注意：勿加 --enforce-eager
# --max-model-len 262144 为本次实际执行值（readme 4.3 原为 8192，差异见 models.md）；
#   262K 下 KV cache 13.71 GiB/卡，满长并发约 2-3 条；需更高满长并发可追加 --gpu-memory-utilization 0.9
SERVE_ARGS=(
    --tensor-parallel-size 2
    --max-model-len 262144
    --gpu-memory-utilization 0.8
    --trust-remote-code
)

# 默认关闭思考模式；--thinking 开启（请求体 chat_template_kwargs: enable_thinking）
SMOKE_CMD=(python /root/develop/test_qwen35_rest.py)

NOTES="graph 模式必须（勿加 --enforce-eager）；启动约 3.5-6 分钟（权重 70-80s + compile 约 45s + 图捕获约 50s + warmup 约 30s）；冒烟期望输出 REST API TEST PASSED"
