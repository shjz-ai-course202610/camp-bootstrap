# camp-bootstrap

课程环境引导脚本。只假设：

- 已安装 Git
- 已接受 `shjz-ai-course202610` 组织邀请

脚本负责：

1. 检测 `gh`（GitHub CLI）；缺失时从 GitHub 官方 release 下载到 `~/.local/bin`，不依赖 Homebrew、不需要 sudo
2. 检查 GitHub 登录；未登录时提示学员本人在浏览器完成
3. 检查组织身份为 `active`
4. 从 `shjz-ai-course202610/camp-cli` 的 `stable` 分支拉取 `camp.sh` 到 `~/.shjz/camp.sh`
5. 运行 `camp.sh init`，建私有仓、首次上传、开启每 60 秒自动同步

## 用法

```bash
bash bootstrap.sh <仓名>
```

只测试 gh 安装：

```bash
bash bootstrap.sh --install-only
```

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

`gh auth login` 的设备码流程依赖 github.com 主站；主站不稳时会失败。备用路径：

1. 浏览器打开 <https://github.com/settings/tokens>，创建 classic token，勾选 `repo`、`read:org`
2. 终端运行：

   ```bash
   gh auth login --hostname github.com --with-token
   ```

   粘贴 token，回车
3. 课程结束后到同一页面撤销该 token
4. token **只留在本机**；不要贴进 Claude Code 对话、不要写进仓库、不要发给助教

## 为什么不公开 camp-cli

建仓和推送仍然需要 GitHub 认证；公开 `camp-cli` 省不掉登录，反而暴露测试与文档。只公开这个 `camp-bootstrap` 引导仓。

## 安全边界

- 不写 token、不接收 token
- 不 sudo、不装完整 Xcode、不使用 Homebrew
- 只操作课程组织内的仓；不碰其他组织
- 登录必须由学员本人在浏览器完成
