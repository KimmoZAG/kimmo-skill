# 模型注册表

每个 profile 一节。**profile 文件（`scripts/models/<name>.sh`）是启动参数的唯一事实来源**，本文件记录其参数依据、验证方法与历史执行记录。新增模型：新增 profile 文件 + 在本文件追加一节，禁止改动通用层（见 SKILL.md 扩展性契约）。

新模型追加格式：照第 1 节小节结构（基本信息 / 启动参数与依据 / 模式要求 / 启动时间线与资源 / 冒烟 / 压测 / 已知注意事项 / 执行记录）。

---

## 1. qwen3.5-35b-a3b

### 1.1 基本信息

- 权重：`/data/shared_upload/models/vspec/Qwen3.5-35B-A3B`（67GB，14 个 bf16 safetensors 分片 + index.json）。⚠️ 同名目录 `/data/shared_upload/Qwen3.5-35B-A3B` 是未完成下载（仅 45MB 配置，权重全 `.incomplete`），**不要用**。
- 同目录 `Qwen3.5-35B-A3B-Eagle3-Specforge` 为投机解码草稿模型，当前未启用。
- 架构：`Qwen3_5MoeForConditionalGeneration`，多模态（文本 + ViT），bf16 无量化。MoE 256 专家 top-8、混合注意力（40 层中每 4 层 1 个 full attention + 3 个 GatedDeltaNet 线性注意力）、MTP 层 1 个、原生上下文 262144、`mamba_ssm_dtype=float32`。
- 兼容性：vllm 0.23.0 已原生注册该架构；transformers 5.5.4 支持 `qwen3_5_moe`；vllm-ascend 0.23.0 有 GDN 专门补丁（`patch_qwen3_5.py` 将 `Qwen3_5GatedDeltaNet._forward_core` 路由到 NPU triton 算子）。

### 1.2 启动参数与依据

profile 实际命令（`serve.sh qwen3.5-35b-a3b` 展开）：

```bash
vllm serve /data/shared_upload/models/vspec/Qwen3.5-35B-A3B \
  --served-model-name Qwen3.5-35B-A3B \
  --host 0.0.0.0 --port 8000 \
  --tensor-parallel-size 2 \
  --max-model-len 262144 \
  --gpu-memory-utilization 0.8 \
  --trust-remote-code
```

| 参数 | 值 | 依据 |
|---|---|---|
| TP | 2 | 2 卡 × 64GB，权重 67GB 单卡放不下 |
| max-model-len | 262144 | **本次实际执行值**（用户指定 256K）。与 readme 4.3 的 8192 不同，以实际执行为准；8192 为 readme 原建议值，长上下文需求时可回退 |
| gpu-memory-utilization | 0.8 | KV cache 13.71 GiB/卡（实测）；需更高满长并发改 0.9（无 OOM 风险） |
| trust-remote-code | — | 多模态远端代码 |

### 1.3 模式要求：必须 graph 模式

**勿加 `--enforce-eager`**：eager 下约 3-5 tok/s 不可用（冒烟 18-21s/请求），graph 模式约 70 tok/s（229 tokens/3.3s 含 prefill），冒烟请求 0.9-1.6s。

graph 模式适配现状（vllm-ascend 0.23 全平台现状，非模型问题）：

- 核心路径全部生效、无 fallback：torch.compile 单动态图覆盖 1-2048（AOT 落 `~/.cache/vllm/torch_compile_cache/`）；decode FULL cudagraph 35 档（1-256）全捕获回放（日志 `Replaying aclgraph`）；GDN/Mamba 状态算子按设计 split 出编译图走 `Using Triton/FLA GDN prefill kernel`；MoE 256 专家 auto 后端无降级；norm_quant + act_quant 融合已启用。
- 平台限制：piecewise cudagraph 被强制禁用，prefill 只有编译图、无图捕获，仅 decode 吃 aclgraph；批并发超 256 时超出部分退出 aclgraph 走编译图，高并发可加 `--max-num-seqs 256` 对齐；每次重启完整重编约 45s，编译缓存不省墙钟时间。视觉塔用 TORCH_SDPA 且不编译，纯文本请求不受影响。

### 1.4 启动时间线与资源预算

- 时间线：权重加载约 70-80s → torch.compile 约 45s → 图捕获约 50s → `Application startup complete` → 约 30s 多模态 warmup（期间请求明显变慢，属正常）。全程约 3.5-6 分钟。
- 资源（每卡）：权重 32.85GB；KV cache 13.71 GiB @262144/0.8（实测，满长单条请求约 4.7 GiB，满长并发约 2-3 条；0.9 时 24.5 GiB）；峰值激活 1.74GB；图内存 0.89GB；空闲约 12GB。
- 模型自带 `generation_config.json` 会覆盖 vLLM 默认采样参数（temperature=1.0/top_k=20/top_p=0.95），不显式传参时按此生效。

### 1.5 冒烟验证

```bash
python /root/develop/test_qwen35_rest.py        # 仅标准库；默认 enable_thinking: false
python /root/develop/test_qwen35_rest.py --thinking   # 开启思考模式
# 可选：--base-url / --model / --max-tokens
```

流程：先查 `/v1/models` 注册名，再发 3 条 prompt（介绍/代码/问答），校验 finish_reason 与非空输出，末尾输出 `REST API TEST PASSED`。典型耗时 1.3s/1.6s/0.2s（本次实测）。

调用约定：`model` 写注册名 `Qwen3.5-35B-A3B`；`/v1/chat/completions` 用 `messages`，`prompt` 只属于 `/v1/completions`，混用报 400。默认思考模型，输出带 `Thinking Process`，不需要时请求体加 `"chat_template_kwargs": {"enable_thinking": false}`。

### 1.6 压测（vllm bench serve）

三个必踩坑：`--model` 必须本地绝对路径（传 HF 名会联网下载，外网不通表现为静默挂起、服务端无请求日志）；必须加 `--served-model-name` 且与服务端注册名一致（否则 404）；必须显式 `--endpoint /v1/chat/completions`（默认端点与 `--backend openai-chat` 不匹配）。

```bash
vllm bench serve \
  --backend openai-chat \
  --model /data/shared_upload/models/vspec/Qwen3.5-35B-A3B \
  --served-model-name Qwen3.5-35B-A3B \
  --base-url http://127.0.0.1:8000 \
  --endpoint /v1/chat/completions \
  --dataset-name random \
  --random-input-len 128 --random-output-len 128 \
  --num-prompts 64 --request-rate 8 \
  --percentile-metrics ttft,tpot,itl,e2el \
  --save-result --result-dir /root/develop/bench-results
```

`vllm-hust-benchmark` wrapper（`/root/develop/vllm-hust-benchmark`）不可直接使用（依赖本机不存在的 `../vllm-hust`），用上面命令等价。

### 1.7 执行记录（2026-10-15）

- 以 262144 / TP=2 / 0.8 后台启动，全程约 5.5 分钟至 startup complete，KV cache 13.71 GiB/卡。
- 冒烟 3/3 通过（1.3s/1.6s/0.2s，finish_reason=stop，输出非空），`REST API TEST PASSED`。
