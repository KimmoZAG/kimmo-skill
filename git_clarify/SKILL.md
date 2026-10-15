---
name: git_clarify
description: 本机环境的 Git/GitHub 使用规范。本 skill 应在执行任何涉及 GitHub 的 git 操作（clone、push、pull、remote 配置、SSH 认证）前显式导入，用于规避本环境特有的网络与权限陷阱：GitHub 直连 443 超时必须走 SSH、容器重启后 SSH 密钥权限被重置、失效的 GIT_SSH_COMMAND 助手。
---

# git_clarify：本环境 Git/GitHub 使用规范

本机所有 GitHub 操作只有一种正确姿势：**SSH，且必须经 `ssh.github.com:443`**。直连 `github.com:443` 被墙/超时，任何 `https://github.com/...` 的 clone/push 都会卡死。

## 每次操作前（三条前置，缺一不可）

```bash
unset GIT_SSH_COMMAND              # 通道1：容器重启后可能指向已失效的 /tmp/coder.* 助手
chmod 600 ~/.ssh/config ~/.ssh/id_ed25519   # 通道2：权限会被重置为 664/660，SSH 直接拒绝
git ls-remote git@github.com:KimmoZAG/kimmo-skill.git >/dev/null 2>&1 && echo SSH-OK   # 通道3：连通性自检
```

`~/.ssh/config` 已配置 `Host github.com → ssh.github.com:443`（密钥 `~/.ssh/id_ed25519`），无需改动。

## 规则

1. **clone / remote 一律用 SSH 地址**，永远不用 https：
   ```bash
   git clone git@github.com:<org>/<repo>.git
   git remote set-url origin git@github.com:<org>/<repo>.git   # 修正已有 https remote
   ```
2. **push/pull 卡住不动**：先按上面三条前置逐项检查，再 `ssh -T git@github.com` 验证认证（成功输出 `Hi <user>!`）。
3. **其余 git 行为照常**：本 skill 只约束"连 GitHub"这一层，分支、提交、工作流不受影响。
4. **不要改 git 全局配置**（`git config --global`）来解决连接问题——连接问题只出在 SSH 通道，改配置无效且污染环境。
