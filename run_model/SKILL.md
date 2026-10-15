---
name: run_model
description: 在 aarch64 + 昇腾 Ascend 910B 容器上准备 vLLM 运行环境，并按模型 profile 启动、重启、验证大模型推理服务（如 Qwen3.5-35B-A3B）。本 skill 应在以下场景使用：在 NPU/Ascend 上部署或重启 vLLM 服务、启动前清理 IDE shim 等环境污染、排查 worker 秒死/`No module named 'acl'` 等启动故障、对已注册模型做 REST 冒烟或 vllm bench 压测、新增模型接入。包含与模型无关的通用环境准备层和可插拔的模型 profile 层。
---

# run_model：Ascend NPU 上 vLLM 环境准备与模型启动

> kimmo-skill 系列之一；后续新 skill 与本 skill 平级放置于同一父目录 `kimmo-skill/` 下，各 skill 内部只做相对引用，互不依赖。

本 skill 可安装在任意路径（如 `~/.codebuddy/skills/kimmo-skill/run_model/`）。以下 `<SKILL>` 统一指本 SKILL.md 所在目录（skill 加载时会给出的 base directory）；skill 内部脚本经 `BASH_SOURCE` 自定位，与安装位置和当前工作目录无关，可整体迁移。仅环境层路径（conda、CANN、模型库）为本机固定路径。

两层严格解耦的设计：

- **通用环境准备层**（`<SKILL>/scripts/env.sh`）：与模型无关的前置流程，任何模型启动都必须执行，禁止为某个模型修改它。
- **模型启动层**（`<SKILL>/scripts/models/<name>.sh`）：每模型一个独立 profile，互不依赖，只定义变量，启动逻辑全部复用 `<SKILL>/scripts/serve.sh`。

## 目录结构与职责

| 文件 | 职责 |
|---|---|
| `scripts/env.sh` | 幂等 source：conda env `lmcache` 确认、CANN `set_env.sh`、shim 五通道清理、`MAX_JOBS=4` |
| `scripts/serve.sh` | 通用启动器：按 profile 组装 `vllm serve` 命令，支持后台（setsid）与前台 |
| `scripts/models/*.sh` | 模型 profile（仅变量定义） |
| `references/environment.md` | 环境陷阱速查（现象 → 根因 → 处理）与分层排错顺序 |
| `references/models.md` | 模型注册表：各 profile 的参数依据、模式要求、冒烟与压测方法 |

## 标准工作流

### 1. 环境准备（每次启动前，必选）

```bash
source <SKILL>/scripts/env.sh
```

幂等，可重复 source。完成：确认 conda env `lmcache`、加载 CANN、剔除 `vendor/shim` 五通道污染（`BASH_ENV`/`NODE_OPTIONS`/safe-delete 变量/`rm` shell 函数/PATH 与 PYTHONPATH）、`MAX_JOBS=4`。

### 2. 选择 profile

```bash
bash <SKILL>/scripts/serve.sh        # 无参数：列出全部可用 profile
```

各 profile 的参数依据与注意事项查 `references/models.md`。

### 3. 启动服务

```bash
# 后台（默认，setsid 防连带杀死），日志默认落 /tmp/<profile>_serve.log
bash <SKILL>/scripts/serve.sh qwen3.5-35b-a3b

# 指定日志目录 / 追加 vllm 参数（追加参数在命令尾部，同名 flag 后者生效）
bash <SKILL>/scripts/serve.sh qwen3.5-35b-a3b --log-dir /tmp/logs --gpu-memory-utilization 0.9

# 前台运行
bash <SKILL>/scripts/serve.sh qwen3.5-35b-a3b --foreground
```

端口被占用或已有 vLLM 进程时启动器会拒绝执行，先处理残留进程。

### 4. 监控启动

`tail -f <日志>`，等待 `Application startup complete`。各模型启动时间线与资源预算见 `references/models.md`。startup complete 后多数模型还有短暂 warmup，期间请求变慢属正常。

### 5. 冒烟验证

执行 profile 中 `SMOKE_CMD` 定义冒烟脚本（各模型的调用约定见 `references/models.md`）。失败时按 `references/environment.md` 的分层排错顺序处理，勿盲改。

### 6. 可选：压测

`vllm bench serve` 模板及其三个必踩坑见 `references/models.md` 压测小节。

## 扩展性契约（新增模型时必须遵守）

1. **只允许**：新增 `<SKILL>/scripts/models/<model-name>.sh` 一个 profile 文件，并在 `references/models.md` 追加一节。
2. **禁止**：修改 `scripts/env.sh`、`scripts/serve.sh`、`SKILL.md`、`references/environment.md` 及任何已有 profile。若通用层确有缺陷，先向维护者报告，不得为单个模型绕过契约。
3. profile 只定义变量，不含启动逻辑；模式要求（graph/eager）写进 `SERVE_ARGS` 并在注释中说明原因。

新 profile 最小字段模板：

```bash
#!/usr/bin/env bash
# profile: <model-name> —— 一句话说明
PROFILE_NAME="<model-name>"
MODEL_PATH="<权重绝对路径>"            # 必填：本地路径，勿用 HF 名（外网不通会静默挂起）
SERVED_MODEL_NAME="<注册名>"           # 必填：API 调用时 model 字段的值
HOST="0.0.0.0"
PORT=8000
SERVE_ARGS=(                           # 必填：全部关键 vllm 参数
  --tensor-parallel-size 2
  --max-model-len 8192
  --gpu-memory-utilization 0.8
  --trust-remote-code
  # --enforce-eager    # 仅当该模型 eager 才可用时才加，注释写明原因
)
SMOKE_CMD=(python /root/develop/test_qwen35_rest.py)   # 必填：冒烟验证命令
NOTES="启动时间线/资源预算/已知坑一句话，详见 references/models.md 对应节"
```

同时在 `references/models.md` 按"模型注册表"现有条目格式追加一节（权重路径、参数依据、模式要求、冒烟方式、已知注意事项）。
