# 环境准备层：陷阱速查与排错顺序

与模型无关。素材源：`env-and-e2e-test-note.md` 第 1/2/3/6/7 节。执行 `scripts/env.sh` 已覆盖大部分前置项；本文件用于**故障定位**与**偏离标准路径的操作**（pip、git、编译）。

## 基线环境

- aarch64（openEuler）+ Ascend 910B2 容器，2 卡 × 64GB HBM。卡经容器设备节点直通（`/dev/davinci5`、`/dev/davinci6` → 逻辑 0/1），**NPU 卡号不经环境变量控制**（不使用 `ASCEND_RT_VISIBLE_DEVICES`）。
- 唯一运行环境：conda env `lmcache`（`/root/miniconda3/envs/lmcache`，Python 3.12.15）。env 名是历史命名，内部是完整 NPU vLLM 栈。系统 python（`/usr/local/python3.12.13`）不作运行环境。
- 版本组合：vllm 0.23.0+empty（editable `/root/develop/vllm`）、vllm_ascend 0.23.0（editable `/root/develop/vllm-ascend`，c_ops 已编译）、torch 2.10.0+cpu / torch_npu 2.10.0.post4、triton-ascend 3.2.2（装在 `triton` 包名下）、transformers 5.5.4、CANN 9.1.0。
- 查看运行进程全量变量：`tr '\0' '\n' < /proc/<pid>/environ | sort`。`VSCODE_*`/`CODEBUDDY_*` 等约 70 个变量为 IDE/编排噪声，与服务无关。

## 陷阱速查（现象 → 根因 → 处理）

| 现象 | 根因 | 处理 |
|---|---|---|
| worker fork 后约 2 秒即死，日志仅 `WorkerProc was terminated`，真实堆栈被吞 | IDE 经 `PYTHONPATH` 注入 `.../vendor/shim` | 剔除该条目后重启（`env.sh` 已处理）。剔除后 acl 不受影响：conda python 走 `cann.pth`，vLLM 引擎子进程本就剥掉 PYTHONPATH |
| `No module named 'acl'` | PYTHONPATH 被整体覆盖，丢了 CANN 条目 | 改为**追加**：`export PYTHONPATH=<dev>:$PYTHONPATH`，或重新 source `env.sh` |
| pip 安装中途失败、文件删除被拦 | safe-delete shim 拦截 pip 的删除操作 | 先 `env.sh` 清理，或 `PYTHONPATH= python -m pip <cmd>` |
| `module 'triton' has no attribute 'language'` | **误执行了 `pip uninstall triton`**。triton-ascend 3.2.2 装在 `triton` 包名下，卸载会连带删除共享文件 | **永远不要 `pip uninstall triton`**。误删后恢复：<br>`python -m pip install --force-reinstall --no-deps triton-ascend==3.2.2 --extra-index-url https://mirrors.huaweicloud.com/ascend/repos/pypi` |
| 判断 vllm/vllm_ascend 加载来源时被 `pip show` 误导 | editable finder 与 PYTHONPATH 覆盖下 dist-info 不变 | **不要信 `pip show`**。用 `python -c "import vllm; print(vllm.__file__)"` 或 `inspect.getsourcefile` 确认 |
| 改了 `.py` 行为不变 | `vllm serve` 长驻进程，import 早已完成 | kill 后重启 |
| `import vllm_ascend` 正常，跑模型崩（新 clone/复制副本） | C 扩展 `.so` 不进 git（`.gitignore`），延迟加载所以 import 不报错 | 免编译副本必须**整目录 `cp -r`**（带走 8 个 `.so`）；自检 `find <副本>/vllm_ascend -name '*.so' \| wc -l` 应为 8 |
| 单独升级 vllm 或 vllm-ascend 后接口报错、导入失败 | 两者版本号严格绑定，不能只换一个 | 版本必须成对切换（详见下文"版本成对"） |
| nohup 后台任务莫名被杀 | 轮询命令超时被取消时同进程组任务被连带杀死 | 后台长任务必须 `setsid`（`serve.sh` 已内置） |
| vllm-ascend 编译时打爆容器 | `setup.py` 用 `os.cpu_count()`（宿主 192 核）而非 cgroup 配额（实际 8 核） | `export MAX_JOBS=4`（`env.sh` 已设置） |
| `import vllm` 的脚本报 `unknown location` | 脚本放 `/root/develop`，`sys.path[0]` 劫持 editable namespace 包 | 需要 `import vllm` 的脚本放 `/root`；纯 REST 客户端脚本不受限 |
| 异常堆栈不完整难定位 | 多进程模式堆栈被包装异常吞掉 | `VLLM_ENABLE_V1_MULTIPROCESSING=0` 进程内运行，堆栈完整 |

### pip

- 昇腾专属包加 `--extra-index-url https://mirrors.huaweicloud.com/ascend/repos/pypi`；默认源 `https://pypi.org/simple`。
- numpy：triton-ascend 元数据 pin `numpy==1.26.4`。`pip check` 报的仅是元数据警告（两条运行路径实测无影响），**不要盲目回退 numpy**——opencv-python-headless 要求 numpy>=2，降级引入新冲突。
- 依赖复刻：`pip freeze` 中有 `file:///root/selfgz*` 的 CANN 内部包，复刻只取 `name==version` 行，按快照装加 `--no-deps`。

### Git（GitHub）

- 直连 `github.com:443` 超时，**全部用 SSH**：`git clone git@github.com:<org>/<repo>.git`（`~/.ssh/config` 已配 `Host github.com → ssh.github.com:443`）。
- 容器重启后先 `unset GIT_SSH_COMMAND`（可能指向失效的 `/tmp/coder.*` 助手）。
- `~/.ssh/{config,id_ed25519}` 权限会被重置回 664，git 前重新 `chmod 600`。

### 版本成对切换

vllm-ascend 与 vllm 版本号严格绑定，当前矩阵：v0.23.0 ↔ vllm 0.23.0 + transformers 5.5.4（CANN 9.1.0 / torch_npu 2.10.0.post4 / triton-ascend 3.2.2）。升级前查目标版本 `docs/source/community/versioning_policy.md` 的 Release compatibility matrix 与 `requirements.txt`。切换副本的三种方式（PYTHONPATH 追加覆盖 / `pip install -e` 重装 / 独立 venv）与免编译整目录复制法见 `switching-vllm-and-vllm-ascend.md`。

### LMCache（当前不启用）

lmcache / lmcache_ascend 装在 env 中但未接入部署，勿在启动参数中引入。`/root/develop/LMCache` editable 克隆有两个本地补丁，更新仓库会被冲掉需重打；源码编译开关 `BUILD_WITH_ASCEND=1`（`NO_CUDA_EXT=1` 会报 `ModuleNotFoundError: lmcache.lmcache_native`）。

## 分层排错顺序（按序执行，勿跳层）

```bash
# 1) torch_npu 基础层
python -c "import torch, torch_npu; print(torch.npu.is_available()); print(torch.npu.matmul(torch.randn(2,2).npu(), torch.randn(2,2).npu()).shape)"
# 2) 栈导入层（triton.backends 应含 'ascend'）
python -c "import vllm, vllm_ascend; print(vllm.__file__); print(vllm_ascend.__file__)"
python -c "import triton; print(triton.backends)"
# 3) 平台插件层（应输出 NPUPlatform）
python -c "from vllm.platforms import current_platform; print(type(current_platform).__name__)"
# 4) REST 冒烟（服务就绪后）
python /root/develop/test_qwen35_rest.py
```

第 1 层失败查 CANN/驱动与 `env.sh` 是否生效；第 2 层失败查 PYTHONPATH 与 editable finder；第 4 层失败回到启动日志定位（可临时 `VLLM_ENABLE_V1_MULTIPROCESSING=0` 拿完整堆栈）。
