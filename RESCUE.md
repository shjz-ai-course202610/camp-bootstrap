# RESCUE — AI 自动救援手册

> 读者是 AI（Claude Code），不是学员。学员全程不输入命令。
> 命令是 AI 的内部动作；对学员只输出“点一下”的卡片。

## 1. 何时使用

满足任一条就进入救援：

- `bootstrap.sh` 非零退出，或其中任一步命令失败
- 出现 404、`gh auth status` 失败、登录命令长时间无输出等可疑现象
- AI 判断环境（Git / gh / 登录 / 组织 / 网络 / 仓库）可能有问题

正常路径优先：先运行 `bootstrap.sh`，失败后再走本手册。不要在未失败时主动改写环境。

## 2. 平台选择与取文件

统一从 `api.github.com` 取（公开仓，不需要登录），不要依赖 `github.com` 主站。
分支固定用 `main`。诊断日志保存在 `~/.shjz/doctor-last.log`；doctor 本体只放临时目录，跑完删除。

### macOS / Linux

```bash
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/shjz-doctor.XXXXXX")
curl -fsSL -H "Accept: application/vnd.github.raw" \
  "https://api.github.com/repos/shjz-ai-course202610/camp-bootstrap/contents/doctor.sh?ref=main" \
  -o "$tmpdir/doctor.sh"
bash "$tmpdir/doctor.sh" --check --project "$PWD"
rm -rf "$tmpdir"
```

这不是安装，跑完删除，不加 PATH，不留常驻文件。`--fix` 时把参数换成 `--fix`，仍从 `$tmpdir/doctor.sh` 运行，结束后同样删除 `$tmpdir`。

### Windows

先判断有没有 **Git Bash**。只认下面两个路径，不要用 `Get-Command bash.exe`：

```powershell
$gitBash = @(
  "C:\Program Files\Git\bin\bash.exe",
  "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($gitBash) { $gitBash } else { "NO_GIT_BASH" }
```

- **找到 Git Bash**：用该路径的 `bash.exe` 运行 `doctor.sh`。
- **没找到 Git Bash**：用 Claude Code 的 PowerShell 工具取并运行 `doctor.ps1`（PowerShell 参数用 `-Check` / `-Fix`）：

```powershell
$tmpDir = Join-Path $env:TEMP ("shjz-doctor-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $tmpDir | Out-Null
Invoke-RestMethod -Uri "https://api.github.com/repos/shjz-ai-course202610/camp-bootstrap/contents/doctor.ps1?ref=main" `
  -Headers @{ Accept = 'application/vnd.github.raw' } `
  -OutFile (Join-Path $tmpDir "doctor.ps1")
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmpDir "doctor.ps1") -Check
Remove-Item -Recurse -Force $tmpDir
```

这不是安装，跑完删除，不加 PATH，不留常驻文件。`-Fix` 时同样从 `$tmpDir` 运行，结束后删除该目录。

### 项目目录（运行 doctor / bootstrap 前必查）

- 项目目录不能是用户主目录、桌面、`/` 或整个用户目录。
- 如果当前目录是主目录或桌面：**由 AI 自己**在其下创建课程项目子目录（例如 `~/shjz-course-<仓名>`），进入该子目录后再运行 doctor / `bootstrap.sh`；不要要求学员建目录。
- 绝不把整个主目录或桌面上传；doctor 的 `--project` 指向这个子目录。

**WSL 明确不算 Git Bash**：`C:\Windows\System32\bash.exe` 只是 WSL 入口。如果系统里只有它，按“没有 Git Bash”处理，走 `doctor.ps1`，不要用它跑 `doctor.sh`。

若 `doctor.ps1` 返回 404：先按第 5 节确认 `api.github.com` 连通，仍 404 则报 `BLOCKED`，不要改用裸 `git` 命令硬修。

## 3. 执行顺序

参数映射：`doctor.sh` 用 GNU 风格 `--check` / `--fix`；`doctor.ps1` 用 PowerShell 风格 `-Check` / `-Fix`。下文写 GNU 风格参数时，Windows PowerShell 自动换成对应写法。

1. **先跑只读检查**（`doctor.sh --check` / `doctor.ps1 -Check`）。每次输出都保存到 `~/.shjz/doctor-last.log`（见第 7 节）。
2. 读取输出末尾的 `STATUS=` / `CODE=` / `SUMMARY=` / `ACTION=`，按下面分支：
   - `STATUS=OK` → 重跑 `bootstrap.sh`。
   - `STATUS=FIXED` → 只可能出现在 `--fix` 之后，重跑 `bootstrap.sh`。
   - `STATUS=ACTION_REQUIRED`：
     a. 若 `CODE` 属于 doctor 可安全修复的范围，先跑一次 `--fix`（PowerShell：`-Fix`）：
        `GH-MISSING` / `PATH-MISSING` / `SCRIPT-CRLF` / `GIT-IDENTITY` / `GIT-CREDENTIAL` / `REPO-PUBLIC` / `WATCHER-MISSING`
     b. `--fix` 后 `STATUS=FIXED` → 重跑 `bootstrap.sh`。
     c. 仍是 `ACTION_REQUIRED`，或 `CODE` 不在上面的列表 → 按第 4 节给学员卡片，等学员完成后再重跑 `bootstrap.sh`。
   - `STATUS=BLOCKED` → **停止并报告，不要猜、不要试破坏性命令**。
3. **重试上限 3 轮**：`bootstrap.sh 失败 → doctor → 重跑 bootstrap.sh` 记 1 轮。第 3 轮仍失败就停止，附 `~/.shjz/doctor-last.log` 的最后 20 行和 `STATUS/CODE/SUMMARY/ACTION`，交给助教。禁止无限循环。
4. 不要绕过 `bootstrap.sh` 直接手搓 `gh repo create` / `git push`；修复后必须回到 `bootstrap.sh` 完成建仓与自动同步。
5. 如果 `bootstrap.sh` 或 `camp.sh` / `doctor` 的输出里出现 shell 命令，**不要转给学员**；按本手册第 4 节的授权步骤由 AI 处理。

doctor 退出码（辅助判读）：`0=OK`、`10=FIXED`、`20=ACTION_REQUIRED`、`30=BLOCKED`。
若用管道保存输出，退出码可能变成管道最后一段的；以输出里的 `STATUS=` 为准。

## 4. 授权动作（学员只点，不输入）

对学员只说“需要你点一下”，附链接/按钮，不说命令、不要求开终端。

### 4.1 GitHub 登录（AUTH-NONE / AUTH-INVALID / AUTH-SCOPE）

1. **优先复用已有登录**：先跑 `gh auth status` 和 `gh api user --jq .login`，确认不是网络导致的误判（见第 5 节）。
2. **设备码流程**（有伪终端时）：
   - 运行 `gh auth login --hostname github.com --git-protocol https --scopes repo,read:org --web`
   - `--web` 不可用时退回默认设备码流程。
   - 把一次性代码和 `https://github.com/login/device` 告诉学员，让学员在浏览器输入并授权。
   - **不要 12 秒没输出就杀进程**；最长等 5 分钟。超时再换下一条路径。
3. **PAT 剪贴板兜底**（设备码不可用 / 无伪终端）：
   - AI 打开 <https://github.com/settings/tokens>（classic token 页面）。
   - 学员创建 classic token，勾选 `repo`、`read:org`、`gist`（`gist` 仅用于满足 gh 的登录 / 权限检查），点生成后复制。
   - AI 从剪贴板读取：
     - macOS：`pbpaste`
     - Linux：`xclip -o -selection clipboard` 或 `wl-paste`
     - Windows：`Get-Clipboard`
   - 直接通过 stdin 交给 gh，**不要放进命令行参数**（会进进程列表）：
     `gh auth login --hostname github.com --with-token`
   - 成功后立刻清空剪贴板；**不打印 token、不转发、不贴进对话、不写进汇报**。token 由 `gh` 保存在系统钥匙串；没有钥匙串时可能保存在本机 gh 配置（仅本机，不写入仓库或对话）。
   - 用 `gh api user --jq .login` 验证。
4. PAT 只解决认证，**不解决 push 被网络阻断**；网络问题见 4.4。

### 4.2 组织邀请（ORG-PENDING / ORG-NONE）

- 打开 <https://github.com/orgs/shjz-ai-course202610/invitation>，让学员点 **Accept invitation**。
- 等待后重查 `gh api user/memberships/orgs/shjz-ai-course202610 --jq .state`，应为 `active`。
- `ORG-INACTIVE`：不要反复重试，报告助教确认成员状态。

### 4.3 安装 Git / Git Bash

- **macOS（GIT-MISSING / GIT-XCODE-STUB）**：AI 运行 `xcode-select --install`（不加 sudo），系统弹出安装窗口后让学员点“安装”并同意许可；完成后重跑 doctor。
- **Windows（GIT-MISSING / BASH-MISSING）**：用 `doctor.ps1 -Fix` 走 winget 或打开官方下载页；学员只在 UAC / 安装器上点“是/安装”，装完由 AI 重新运行 doctor。
- **Linux（GIT-MISSING / BLOCKED，无管理员权限）**：不要 `sudo`。doctor 会报 `GIT-MISSING` 或 `BLOCKED`；请学员通过系统软件中心 / 包管理器安装 Git（由学员授权），装好后由 AI 重跑 doctor。若系统只有命令行包管理器且学员没有管理员权限，停止并报告助教——这是已知限制，不是 Windows / macOS 路径。
- 不要用 Homebrew、不要 sudo、不要装完整 Xcode。

### 4.4 网络（NET-API / NET-WEB）

- 先分别探测：`curl -I https://api.github.com` 和 `curl -I https://github.com`。
- `api.github.com` 通、`github.com` 不通 → 让学员切手机热点或开代理；**不要用 PAT 硬顶**，PAT 不解决 push。
- 两者都不通 → 同样切网络，再重跑 doctor。
- 网络恢复前不要反复重跑 bootstrap，避免制造更多失败记录。

### 4.5 仓库相关（REPO-* / 权限 / 敏感文件）

- 按 doctor 的 `ACTION` 执行：`REPO-PUBLIC` 优先 `--fix`（有 admin 时自动转私有），无 admin 时让学员在仓库 Settings 里改 Private。
- `REPO-MISSING` / `REPO-PERM`：让助教确认仓名与 `students` team 权限；不要新建第二个仓、不要猜仓名。
- `SENSITIVE-FILES` / `LARGE-FILES`：提示学员把 `.env`、密钥、>5MB 文件移出项目或加 `.gitignore`；不要代删。

## 5. 常见误判（逐条核对）

1. **404 ≠ 仓库私有**。先看 `api.github.com` 是否返回 200、网络是否可达、登录是否有效；不要因为一个 404 就判定“私有仓或无权限”。
2. **`gh auth status` 失败 ≠ 登录过期**。可能是 `github.com` / `api.github.com` 不可达或 TLS 问题；先探测网络再判断。
3. **登录命令 12 秒无输出 ≠ 失败**。设备码/浏览器授权需要学员操作，最长等 5 分钟，不要提前杀进程。
4. **`gh: command not found` ≠ 没装**。先看 `~/.local/bin/gh` 是否存在，必要时用绝对路径调用或按 `PATH-MISSING` 处理。
5. **Windows 报 `$'\r': command not found` = CRLF，不是语法错误**。让 doctor 走 `SCRIPT-CRLF` 修复（`doctor.sh --fix` / `doctor.ps1 -Fix`），或用 Git Bash 重跑。

## 6. 安全边界

- 不 `sudo`；不装完整 Xcode；不用 Homebrew。
- 不 `git push --force`；不删除仓库。除删除本手册用 `mktemp -d` 创建并已确认路径的临时目录外，不使用 `rm -rf`。
- 不改全局 Git 身份（只用 repo-local `user.name` / `user.email`）；不传 `--allow-global-safe-directory`。
- 不打印、不转发 token；token 仅由 `gh` 保存在本机（系统钥匙串，或没有钥匙串时的 gh 配置），不写入仓库或对话；不从命令行参数传 token。
- 不改 `doctor.sh`、`doctor.ps1`、`tests/`；不改 `bootstrap.sh` 的参数与退出码语义。
- 只操作 `shjz-ai-course202610` 组织内的课程仓库。

## 7. 证据与汇报

- 每次 doctor 输出覆盖保存到 `~/.shjz/doctor-last.log`：

  ```bash
  mkdir -p "$HOME/.shjz"
  bash "$HOME/.shjz/doctor.sh" --check --project "$PWD" 2>&1 | tee "$HOME/.shjz/doctor-last.log"
  ```

  Windows PowerShell 用 `Tee-Object -FilePath "$env:USERPROFILE\.shjz\doctor-last.log"`。

- 向学员只给“现在需要你点哪一下”的卡片；`CODE` / `SUMMARY` / `ACTION` 等技术字段只写入日志或交给助教，不展示给学员。
- `BLOCKED` 或 3 轮用尽：把 `STATUS` / `CODE` / `SUMMARY` / `ACTION` 和已尝试步骤写入日志并交给助教，停止操作；不要把这些字段或命令转发给学员。
- 不要在默认汇报里倾倒完整日志；需要时再读 `~/.shjz/doctor-last.log`。
