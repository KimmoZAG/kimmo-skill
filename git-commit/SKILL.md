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
4. 未看清 `git diff HEAD`（覆盖已暂存与未暂存）之前不得写 message。
5. 无变更（工作区与 index 均干净）时直接终止，不构造空提交。

## 工作流

目标：常规提交在 **3–4 次命令调用**内完成。所有信息性查询合并成一条命令，一次拿全。

### Step 1 一次采集

```bash
git rev-parse --is-inside-work-tree >/dev/null || echo NOT_A_REPO
git branch --show-current
git status --short
git --no-pager diff HEAD --stat
git --no-pager log --oneline -5
```

- 非 git 仓库 → 终止并说明。
- `git status --short` 无输出 → 终止并说明（无变更，不构造空提交）。
- `git diff HEAD` 同时覆盖已暂存与未暂存，**不要**再分别执行 `git diff` / `git diff --staged`。
- 当前分支是 `main` / `master` → **不阻塞、不弹窗**，继续提交，只在汇报中标注一句。
- 在同一个 shell 里串联执行（`cd <repo> && ...`），不要为每条查询单开一次调用。

### Step 2 敏感排查 + 变更分析（一条命令）

```bash
git status --porcelain | awk '{print $2}' | sort -u \
  | grep -Ei '\.env|\.pem|\.key$|id_rsa|credential|secret|token|\.p12$|\.keystore$' || echo NO_SECRET_HITS
```

同时目视排查构建产物与依赖目录（`node_modules/`、`dist/`、`target/`、`__pycache__/`）及超大二进制。

分析按**意图/功能**归类，回答三问再落笔：为什么改 / 行为上改了什么 / 有什么影响（破坏性、迁移成本、依赖变化）。无关改动（格式化噪音、临时调试代码、别的需求）不得混入同一次提交。

**不读文件正文来推断改动**：禁止用 `cat`、`sed -n`、`head` 扫源码或 README 去"了解改动"，`git diff HEAD` 已是完整依据。确需理解语义时用 `grep -n` 精确取用，或只读 diff 涉及的片段。

### Step 3 精确暂存

```bash
git add -- <file1> <file2> && git --no-pager diff --cached --stat
```

- 在回复中列出将暂存的文件清单，然后**直接继续**，不要再等确认。
- 仅两种情况停下询问：清单含 Step 2 命中的敏感文件，或含与本次意图无关的文件。
- 禁止 `git add -A`、`git add .`、`git commit -a`。
- 暂存后不要重复 `git status`：`git diff --cached --stat` 已能复核暂存内容。

### Step 4 撰写 message

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

### Step 5 提交

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

### Step 6 hook 失败处理

1. 完整读取 hook 报错，定位真实原因（lint、类型、测试、commitlint 长度或格式限制）。
2. 修复代码或调整 message 后，**重新 `git add`** 被 hook 自动格式化改动的文件。
3. 重试同一命令。连续 3 次仍失败则停止，向用户报告原始报错，不要绕过 hook。

### Step 7 校验（一条命令）

```bash
git --no-pager log -1 --format='%h %s' --stat; git status --short
```

确认：message 正确落盘、提交内文件与暂存清单一致、剩余改动符合预期。

## 效率约定

1. 用 `;` / `&&` 把多条查询串进同一个 shell 调用，一次拿全信息，而不是一个信息一次调用。
2. 已获得的信息直接复用，不重复执行 `git status`、`git log`、`git diff`。
3. 不为"确认"多开一轮对话：只有敏感文件、无关文件、hook 连续失败 3 次才提问。
4. 不读源码/文档正文来推断改动，diff 已足够。
5. 汇报 ≤ 3 行，不逐条罗列已完成的检查项。

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

提交成功后 ≤ 3 行，不写逐项检查清单：

```
<短 hash> <摘要行>  (N files, +X/-Y)[, 已在 main 直接提交]
工作区：干净 / 剩余 <文件>（未提交，原因一句话）
Hook：未触发 / 触发并已修复
```

不要复述"已扫描敏感文件""已复核暂存"等过程项。
