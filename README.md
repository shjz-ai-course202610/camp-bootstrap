# camp-bootstrap

课程环境引导脚本。正常路径假设：

- Git 可用；如果 Git 缺失，AI 救援路径（`RESCUE.md` → `doctor`）会检测并协助安装
- 已接受 `shjz-ai-course202610` 组织邀请

脚本负责：

1. 检测 `gh`（GitHub CLI）；缺失时从 GitHub 官方 release 下载到 `~/.local/bin`，不依赖 Homebrew、不需要 sudo
2. 检查 GitHub 登录；未登录时提示学员本人在浏览器完成
3. 检查组织身份为 `active`
4. 从 `shjz-ai-course202610/camp-cli` 的 `stable` 分支拉取 `camp.sh` 到 `~/.shjz/camp.sh`
5. 运行 `camp.sh init`，建私有仓、首次上传、开启每 60 秒自动同步

## 用法

以下命令供开发者 / 手动排查使用；学员不需要执行，由 AI 代跑。

```bash
bash bootstrap.sh <仓名>
```

只测试 gh 安装：

```bash
bash bootstrap.sh --install-only
```

## AI 自动救援

正常路径只需要让 AI 运行 `bootstrap.sh`。任何一步失败时，AI 会：

1. 读取同仓库的 `RESCUE.md`
2. 按平台取 `doctor.sh` 或 `doctor.ps1`（统一走 `api.github.com`），先跑只读检查（`doctor.sh --check` / `doctor.ps1 -Check`）
3. 只做安全修复，然后重跑 `bootstrap.sh`（最多 3 轮，不无限循环）
4. 需要人工时，给学员一张“只需点一下”的卡片

平台选择：macOS / Linux 用 `doctor.sh`；Windows 有 Git Bash（`C:\Program Files\Git\bin\bash.exe` 或 `%LOCALAPPDATA%\Programs\Git\bin\bash.exe`）用 `doctor.sh`；只有 WSL 的 `C:\Windows\System32\bash.exe` 不算 Git Bash，改用 `doctor.ps1`。

学员不需要输入命令，只做三类动作：

- 在浏览器里授权（登录 GitHub、接受组织邀请）
- 安装软件时点“安装 / 是”（Git、命令行工具等）
- 网络不通时切换手机热点或代理

AI 只向学员转达需要他点一下 / 授权的动作；`STATUS` / `CODE` / `SUMMARY` / `ACTION` 等技术字段只交给助教 / 老师并保存在 `~/.shjz/doctor-last.log`；命令由 AI 执行，不原样转发给学员。

## 网络不稳时的兜底

- **引导脚本本体**：优先用 `api.github.com` 取，不依赖 github.com 主站：

  ```bash
  curl -fsSL -H "Accept: application/vnd.github.raw" \
    "https://api.github.com/repos/shjz-ai-course202610/camp-bootstrap/contents/bootstrap.sh?ref=main" \
    -o bootstrap.sh
  ```

- **gh 下载**：脚本优先走 `api.github.com/repos/cli/cli/releases/assets/<id>`，失败才回退 github.com。
- **clone / push**：仍走 github.com；主站不可达时需要代理，或配置 `ssh.github.com:443`。
  - `api.github.com` 只能解决“取文件/取 release”，不能替代 push。

## 设备码登录失败时（PAT 兜底）

优先让 AI 用 `doctor` 自动判断，不要因为 404 就认定仓库私有。只有确认是登录问题、且设备码流程不可用时，才走下面的 PAT 兜底。

`gh auth login` 的设备码流程依赖 github.com 主站；主站不稳时会失败。备用路径：

1. AI 在浏览器打开 <https://github.com/settings/tokens>，由学员创建 classic token，勾选 `repo`、`read:org`、`gist`（`gist` 仅用于满足 gh 的登录 / 权限检查），生成后复制。学员只操作浏览器，不输入命令。
2. AI 仅在登录时从剪贴板读取 token，通过 stdin 交给 `gh auth login --hostname github.com --with-token`；不打印、不转发、不贴进对话，不放进命令行参数或 shell 历史。
3. AI 登录成功后立即清空剪贴板。token 由 `gh` 保存在系统钥匙串；没有系统钥匙串时可能保存在本机 gh 配置文件，均只在本机，不写入仓库或对话。
4. 课程结束后到同一页面撤销该 token
5. 学员不要把 token 发给任何人；不要贴进 Claude Code 对话、不要写进仓库

## 为什么不公开 camp-cli

建仓和推送仍然需要 GitHub 认证；公开 `camp-cli` 省不掉登录，反而暴露测试与文档。只公开这个 `camp-bootstrap` 引导仓。

## 安全边界

- AI 仅在登录时从剪贴板读取 token，不打印、不转发、不写进仓库或对话；token 由 `gh` 保存在本机（系统钥匙串，或没有钥匙串时的 gh 配置），学员不要把 token 发给任何人
- 不 sudo、不装完整 Xcode、不使用 Homebrew
- 只操作课程组织内的仓；不碰其他组织
- 登录必须由学员本人在浏览器完成
