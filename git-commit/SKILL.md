---
name: git-commit
description: 按 Conventional Commits 规范生成英文 commit message 并完成提交流程。本 skill 应在用户要求提交代码、暂存变更、生成 commit message 或执行 git commit 时导入；覆盖上下文收集、敏感文件排查、按文件精确暂存、message 撰写、hook 失败处理与提交后校验。
---

# git-commit：Conventional Commits 提交规范

将一次提交拆成"先看清全部变更 → 只暂存相关文件 → 英文 conventional message → 提交并校验"。message 用英文，流程说明用中文。

## 硬性规则

1. **禁止** `git add -A`、`git add .`、`git commit -a`。一律按路径精确暂存。
2. **禁止** `git commit --amend`、`git push`、`git config` 改动，除非用户明确要求。
3. **禁止** `--no-verify` 绕过 hook，除非用户明确要求。
4. 未看清 `git diff` 与 `git diff --staged` 之前不得写 message。
5. 无变更（工作区与 index 均干净）时直接终止，不构造空提交。

## 工作流

### Step 1 前置校验

```bash
git rev-parse --is-inside-work-tree
git branch --show-current
git status --short
```

- 非 git 仓库 → 终止并说明。
- 无任何输出（干净）→ 终止并说明。
- 当前分支为 `main` / `master` → 提示用户"正在主分支直接提交"，等待确认后再继续。

### Step 2 收集上下文

```bash
git diff --stat          # 未暂存概览
git diff                 # 未暂存明细
git diff --staged        # 已暂存明细
git log --oneline -10    # 仓库既有风格
```

三份 diff 缺一不可：只看其中之一会漏掉已暂存或未暂存的一半改动。若已有暂存内容，明确区分"本次要提交的部分"与"留下的部分"。

### Step 3 敏感文件排查

对变更文件列表做扫描，命中即不暂存、先告警：

```bash
git diff --name-only; git diff --staged --name-only | sort -u \
  | grep -Ei '\.env|\.pem|\.key$|id_rsa|credential|secret|token|\.p12$|\.keystore$'
```

同时注意误提交的构建产物、依赖目录（`node_modules/`、`dist/`、`target/`、`__pycache__/`）与超大二进制文件。

### Step 4 变更分析

按**意图/功能**归类，而非按文件罗列。先回答三问，再落笔：

- 为什么改（动机 / 修的问题）
- 改了什么（行为层面的差异，不是行数）
- 有什么影响（破坏性、迁移成本、依赖变化）

无关改动（格式化噪音、临时调试代码、别的需求）不得混入同一次提交。

### Step 5 精确暂存 + 清单

```bash
git add -- <file1> <file2>
git diff --cached --stat
```

- 先列出将要暂存的文件清单。
- 清单中若含与本次意图无关的文件或 Step 3 命中的敏感文件 → 停下来询问，不要继续。
- 其余情况列清单后直接继续，无需多轮确认。
- 用 `git diff --cached` 复核：确认暂存内容就是清单里那些改动。

### Step 6 撰写 message

格式：

```
<type>(<scope>): <subject>

<body>

<footer>
```

摘要行规则：

| 项 | 要求 |
|----|------|
| 长度 | ≤ 50 字符（硬上限 72） |
| 语气 | 祈使句现在时：add / fix / remove / rename / drop，不用 added / fixes |
| 大小写 | subject 首字母小写，结尾不加句号 |
| scope | 小写，模块名，可省略 |
| 类型 | 见下方类型表，禁止自造类型 |

类型表：

| type | 用途 |
|------|------|
| `feat` | 新功能 |
| `fix` | 缺陷修复 |
| `docs` | 文档 / 注释 |
| `style` | 格式、空白、分号，不改逻辑 |
| `refactor` | 重构，不改行为 |
| `perf` | 性能优化 |
| `test` | 测试新增或修正 |
| `build` | 构建系统、依赖、打包配置 |
| `ci` | CI 配置与脚本 |
| `chore` | 杂项维护（版本号、脚手架） |
| `revert` | 回滚提交，正文注明被回滚的 hash |

**正文规模自适应**（按净变更判定，取满足的最高档）：

| 档位 | 判定 | 输出 |
|------|------|------|
| 小 | ≤ 2 文件 且 ≤ 30 行净变更，单一意图 | 仅摘要行 |
| 中 | 3–9 文件，或 30–150 行，或多处相关改动 | 摘要 + 2–4 条 `- ` 要点 |
| 大 | ≥ 10 文件，或 ≥ 150 行，跨模块，或含破坏性变更 | 摘要 + 一段"为什么" + 要点列表 + footer |

正文每行 ≤ 72 字符；要点写"改了什么 + 为什么"，不写"修改了 xx 文件"。

破坏性变更必须用 footer 声明：

```
BREAKING CHANGE: <不兼容点与迁移方式>
```

### Step 7 提交

用 heredoc 保留换行与反引号，不拼接多个 `-m`：

```bash
git commit -m "$(cat <<'EOF'
feat(api): add pagination to user list endpoint

- accept page and page_size query params
- clamp page_size to 1..100
- return total count in meta
EOF
)"
```

不添加任何 AI 署名 / `Co-authored-by` / 生成工具标记，除非用户明确要求。

### Step 8 hook 失败处理

1. 完整读取 hook 报错，定位真实原因（lint、类型、测试、commitlint 长度或格式限制）。
2. 修复代码或调整 message 后，**重新 `git add`** 被 hook 自动格式化改动的文件。
3. 重试同一命令。连续 3 次仍失败则停止，向用户报告原始报错，不要绕过 hook。

### Step 9 校验

```bash
git log -1 --stat
git status --short
```

确认：message 已正确落盘、提交内文件与清单一致、工作区剩余改动符合预期（应只剩刻意留下的部分）。

## message 示例

小改（仅摘要行）：

```
fix(auth): guard against expired refresh token
```

中改：

```
feat(api): add pagination to user list endpoint

- accept page and page_size query params
- clamp page_size to 1..100
- return total count in meta
```

大改：

```
refactor(store): replace redux-thunk with async actions

Thunk middleware duplicated loading/error state across slices and
made cross-slice flows hard to follow.

- move async logic into per-slice action creators
- drop redux-thunk dependency
- keep existing selectors unchanged

BREAKING CHANGE: `dispatch(fetchUsers())` now resolves with the payload
instead of returning the action object.
```

反例（禁止）：

```
update code                          # 无语义，未说明改了什么
Fixed the bug.                       # 过去式 + 句号
feat: Added New Login Page For User Authentication Flow   # 超长 + 大写 + 过去式
feat: misc changes + format + bump deps   # 多意图混杂
```

## 汇报格式

提交成功后输出：

- 短 hash 与摘要行
- 本次提交的文件数
- 工作区剩余未提交内容（若有，说明为何留下）
- hook 是否触发过、是否被修复
