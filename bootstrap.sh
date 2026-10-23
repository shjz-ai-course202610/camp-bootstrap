#!/usr/bin/env bash
# shjz camp bootstrap — 只假设已安装 Git、已接受课程组织邀请。
# 负责：安装 gh（如缺失）→ 检查登录/组织 → 拉取 camp.sh → init 建仓并开启自动上传。
set -u

ORG="shjz-ai-course202610"
export GH_HOST=github.com
GH_VERSION="2.103.0"
BIN_DIR="${CAMP_BIN_DIR:-$HOME/.local/bin}"
CAMP_HOME="${CAMP_HOME:-$HOME/.shjz}"
PROJECT_DIR="${CAMP_PROJECT_DIR:-$PWD}"
export CAMP_HOME
INSTALL_ONLY=0
REPO_NAME=""

case "${1:-}" in
  --install-only) INSTALL_ONLY=1 ;;
  *) REPO_NAME="${1:-}" ;;
esac

say() { printf '%s\n' "$*"; }
die() {
  printf '错误：%s\n' "$*" >&2
  printf '救援：读取同仓库 RESCUE.md，按 doctor 流程排查。\n' >&2
  exit 1
}

persist_path() {
  profile=""
  case "${SHELL:-}" in
    */zsh) profile="$HOME/.zshrc" ;;
    */bash) profile="$HOME/.bashrc" ;;
  esac
  [ -n "$profile" ] || return 0
  grep -F "$BIN_DIR" "$profile" >/dev/null 2>&1 && return 0
  printf '\n# shjz camp: GitHub CLI\n' >> "$profile"
  printf 'export PATH="%s:$PATH"\n' "$BIN_DIR" >> "$profile"
}

install_gh() {
  if command -v gh >/dev/null 2>&1; then
    say "GitHub CLI 已安装：$(gh --version 2>/dev/null | head -1)"
    return 0
  fi

  os=$(uname -s)
  arch=$(uname -m)
  case "$os" in
    Darwin)
      case "$arch" in
        arm64) asset="gh_${GH_VERSION}_macOS_arm64.zip" ;;
        x86_64) asset="gh_${GH_VERSION}_macOS_amd64.zip" ;;
        *) die "不支持的 macOS 架构：$arch" ;;
      esac
      ;;
    Linux)
      case "$arch" in
        x86_64|amd64) asset="gh_${GH_VERSION}_linux_amd64.tar.gz" ;;
        aarch64|arm64) asset="gh_${GH_VERSION}_linux_arm64.tar.gz" ;;
        *) die "不支持的 Linux 架构：$arch" ;;
      esac
      ;;
    MINGW*|MSYS*|CYGWIN*)
      case "$arch" in
        x86_64|amd64) asset="gh_${GH_VERSION}_windows_amd64.zip" ;;
        *) die "不支持的 Windows 架构：$arch" ;;
      esac
      ;;
    *) die "暂不支持的系统：$os" ;;
  esac

  # GitHub release asset ID 与 GH_VERSION 绑定；升版本时两者一起改。
  api_asset_id=""
  case "$os/$arch" in
    Darwin/arm64) api_asset_id=662956481 ;;
    Darwin/x86_64) api_asset_id=662956458 ;;
    Linux/x86_64|Linux/amd64) api_asset_id=662956379 ;;
    Linux/aarch64|Linux/arm64) api_asset_id=662956401 ;;
    MINGW*/x86_64|MSYS*/x86_64|CYGWIN*/x86_64) api_asset_id=662956535 ;;
  esac
  api_checksums_id=662956296

  mkdir -p "$BIN_DIR" || die "无法创建 $BIN_DIR"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/shjz-gh.XXXXXX") || die "无法创建临时目录"
  url="https://github.com/cli/cli/releases/download/v${GH_VERSION}/${asset}"
  say "未检测到 GitHub CLI，正在下载 ${GH_VERSION} ..."
  if [ -n "$api_asset_id" ] && \
     curl -fsSL -H "Accept: application/octet-stream" \
       "https://api.github.com/repos/cli/cli/releases/assets/${api_asset_id}" \
       -o "$tmp/$asset"; then
    say "已通过 api.github.com 下载"
  else
    say "api.github.com 下载失败，改用 github.com ..."
    curl -fsSL "$url" -o "$tmp/$asset" || die "下载 gh 失败，请检查网络后重试"
  fi
  if ! curl -fsSL -H "Accept: application/octet-stream" \
       "https://api.github.com/repos/cli/cli/releases/assets/${api_checksums_id}" \
       -o "$tmp/checksums.txt"; then
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt" \
      -o "$tmp/checksums.txt" || die "下载 gh 校验文件失败"
  fi

  ( cd "$tmp" && grep " $asset\$" checksums.txt > one.sum && \
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 -c one.sum; else sha256sum -c one.sum; fi ) \
    || die "gh 校验失败，已停止"

  mkdir -p "$tmp/extract"
  case "$asset" in
    *.zip)
      if command -v unzip >/dev/null 2>&1; then
        unzip -q "$tmp/$asset" -d "$tmp/extract" || die "解压 gh 失败"
      else
        powershell.exe -NoProfile -Command "Expand-Archive -LiteralPath '$tmp/$asset' -DestinationPath '$tmp/extract' -Force" \
          >/dev/null 2>&1 || die "解压 gh 失败"
      fi
      ;;
    *.tar.gz)
      tar -xzf "$tmp/$asset" -C "$tmp/extract" || die "解压 gh 失败"
      ;;
  esac

  src=$(find "$tmp/extract" -type f \( -name gh -o -name gh.exe \) 2>/dev/null | head -1)
  [ -n "$src" ] || die "解压后找不到 gh 可执行文件"
  cp "$src" "$BIN_DIR/$(basename "$src")" || die "复制 gh 失败"
  chmod +x "$BIN_DIR/$(basename "$src")" 2>/dev/null || true
  find "$tmp" -depth -delete 2>/dev/null || true
  export PATH="$BIN_DIR:$PATH"
  say "GitHub CLI 已安装到 $BIN_DIR"
  persist_path
}

ensure_auth() {
  GH_BIN=$(command -v gh 2>/dev/null || true)
  [ -n "$GH_BIN" ] || die "找不到 gh，请重新运行本脚本。"
  if "$GH_BIN" auth status --hostname github.com >/dev/null 2>&1; then
    say "GitHub 已登录：$("$GH_BIN" api user --jq .login 2>/dev/null || echo 未知)"
    return 0
  fi
  say "尚未登录 GitHub。请 AI 读取同仓库 RESCUE.md 的登录授权步骤，由 AI 完成登录；不要让学生输入命令。"
  say ""
  say "救援：读取同仓库 RESCUE.md，按 doctor 流程排查。"
  say "不要因为 10-20 秒没反应就判定失败；浏览器授权可能需要更久（最长等 5 分钟）。"
  exit 2
}

ensure_org() {
  state=$(gh api "user/memberships/orgs/$ORG" --jq .state 2>/dev/null) \
    || die "读不到 $ORG 的组织身份。请先接受邀请：https://github.com/orgs/$ORG/invitation"
  [ "$state" = "active" ] \
    || die "组织身份状态是 ${state}。请先接受邀请：https://github.com/orgs/$ORG/invitation"
}

fetch_camp() {
  mkdir -p "$CAMP_HOME" || die "无法创建 $CAMP_HOME"
  gh api "repos/$ORG/camp-cli/contents/camp.sh?ref=stable" \
    -H "Accept: application/vnd.github.raw" > "$CAMP_HOME/camp.sh" \
    || die "下载 camp.sh 失败"
  [ -s "$CAMP_HOME/camp.sh" ] || die "下载的 camp.sh 为空"
  head -1 "$CAMP_HOME/camp.sh" | grep -q '^#!/usr/bin/env bash' \
    || die "下载的 camp.sh 不是预期脚本"
}

run_init() {
  cd "$PROJECT_DIR" || die "无法进入项目目录：$PROJECT_DIR"
  if [ -f "$PROJECT_DIR/bootstrap.sh" ] && [ -f "$PROJECT_DIR/README.md" ] && \
     git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null | grep -q 'camp-bootstrap'; then
    die "请在课程项目文件夹里运行本脚本，不要进入 camp-bootstrap 仓库目录。"
  fi
  # 如果引导仓被克隆到项目目录下，避免把它一起上传
  if [ -d "$PROJECT_DIR/camp-bootstrap" ]; then
    printf '\n# shjz bootstrap clone\ncamp-bootstrap/\n' >> "$PROJECT_DIR/.gitignore"
  fi
  if [ -z "$REPO_NAME" ]; then
    die "缺少仓名。AI 应使用 <仓名> 调用 bootstrap.sh。"
  fi
  # CAMP_INIT_ARGS 仅供自动化测试使用（例如 --no-watch）
  bash "$CAMP_HOME/camp.sh" init --name "$REPO_NAME" --yes ${CAMP_INIT_ARGS:-}
}

main() {
  command -v git >/dev/null 2>&1 || die "缺少 Git。请先安装 Git 再运行本脚本；安装与救援步骤见 RESCUE.md。"
  install_gh
  if [ "$INSTALL_ONLY" = "1" ]; then
    gh --version
    exit 0
  fi
  ensure_auth
  ensure_org
  fetch_camp
  run_init
}

main "$@"
