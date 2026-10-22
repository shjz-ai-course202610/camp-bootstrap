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

## 安全边界

- 不写 token、不接收 token
- 不 sudo、不装完整 Xcode、不使用 Homebrew
- 只操作课程组织内的仓；不碰其他组织
- 登录必须由学员本人在浏览器完成
