#!/usr/bin/env bash
# shjz camp doctor — 诊断并安全修复课程环境（Git / gh / PATH / 登录 / 组织 / 网络 / 仓库 / 自动同步）。
# 兼容 macOS 自带 Bash 3.2 / Linux / Windows Git Bash；不依赖 jq、Homebrew、Python、sudo。
#
# 用法：
#   bash doctor.sh [--check|--fix] [--project DIR] [--org ORG] [--camp-home DIR]
#                  [--bootstrap PATH] [--allow-global-safe-directory]
#
# 默认 --check（只读）。--fix 才应用安全修复，修完重跑一次检查。
# 输出契约固定在最后：
#   CAMP_DOCTOR 1
#   STATUS=OK|FIXED|ACTION_REQUIRED|BLOCKED
#   CODE=<主错误码或 OK>
#   SUMMARY=<一句话>
#   ACTION=<下一步，AI 可读；没有就 NONE>
#   PROJECT=<绝对路径>
#   ALSO=<其他错误码，逗号分隔；没有就 NONE>
# 退出码：0=OK 10=FIXED 20=ACTION_REQUIRED 30=BLOCKED
#
# 测试用环境变量 CAMP_TEST=1：只查 PATH 与 $HOME 下的候选路径，
# 不查 /usr/bin、/usr/local/bin、/opt/homebrew 等系统固定路径，
# 便于在已安装 git/gh 的机器上模拟缺失。生产环境不要设置。

set -u
umask 077

# 课程只使用 github.com；固定主机，避免 gh 被环境指向企业版。
export GH_HOST="github.com"

ORG="shjz-ai-course202610"
CAMP_HOME="${CAMP_HOME:-$HOME/.shjz}"
BIN_DIR="${CAMP_BIN_DIR:-$HOME/.local/bin}"
MODE="check"
PROJECT_ARG=""
BOOTSTRAP_ARG=""
ALLOW_SAFE_DIR=0
CAMP_TEST="${CAMP_TEST:-0}"
# 所有测试专用捷径都只由 CAMP_TEST=1 开启。
TEST_MODE=0
[ "$CAMP_TEST" = "1" ] && TEST_MODE=1

ORIG_PWD="$PWD"

# ---------- 输出 ----------
redact_url() {
  # 抹掉 URL userinfo 与常见 GitHub token，防止凭据出现在输出/日志中。
  printf '%s' "$1" | sed -E \
    -e 's#(https?://)[^/@[:space:]]+@#\1***@#g' \
    -e 's#(ssh://)[^/@[:space:]]+@#\1***@#g' \
    -e 's#gh[pousr]_[A-Za-z0-9]+#***#g' \
    -e 's#github_pat_[A-Za-z0-9_]+#***#g'
}

QUIET=0
show() { [ "$QUIET" = "1" ] || printf '%s\n' "$(redact_url "$*")"; }
section() { [ "$QUIET" = "1" ] || printf '\n[%s] %s\n' "$1" "$2"; }
log_line() { printf '%s\n' "$(redact_url "$*")" >&2; }

usage() {
  cat <<'USAGE'
用法：bash doctor.sh [--check|--fix] [--project DIR] [--org ORG]
                     [--camp-home DIR] [--bootstrap PATH]
                     [--allow-global-safe-directory]

  --check                         只读检查（默认）
  --fix                           应用安全修复，然后重新检查
  --project DIR                   项目目录（默认当前目录；不是 Git 仓时回退到 $CAMP_HOME/repo）
  --org ORG                       课程组织（默认 shjz-ai-course202610）
  --camp-home DIR                 状态目录（默认 $HOME/.shjz）
  --bootstrap PATH                本地 bootstrap.sh（默认 $PWD/bootstrap.sh 或 $CAMP_HOME/bootstrap.sh）
  --allow-global-safe-directory   允许写全局 git safe.directory（默认只报告）
USAGE
}

emit_contract() {
  # status code summary action project also exitcode
  printf '\nCAMP_DOCTOR 1\nSTATUS=%s\nCODE=%s\nSUMMARY=%s\nACTION=%s\nPROJECT=%s\nALSO=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6"
  exit "$7"
}

# ---------- 结果收集 ----------
ISSUES_CODES=""
ISSUES_DETAIL=""
FIX_APPLIED=0
PERSIST_FAILED=0
REPO_NESTED=0

GIT_BIN=""
GIT_ON_PATH=0
GH_BIN=""
GH_ON_PATH=0
MISSING_PATH_DIRS=""
CRLF_FILES=""
AUTH_OK=0

REPO_IS_REPO=0
PROJECT_REAL=""
REPO_TOP=""
OWNER=""
REPO_NAME=""
REPO_PRIVATE=""
REPO_PUSH=""
REPO_ADMIN=""
REPO_CANONICAL_NAME=""
GIT_SAFE_PATH=""

NET_PROBED=0
NET_API_OK=0
NET_WEB_OK=0
NET_CODELOAD_OK=0
NET_WEB_FALLBACK=0

BOOTSTRAP_FILE=""
BOOTSTRAP_READY=0

reset_results() {
  ISSUES_CODES=""
  ISSUES_DETAIL=""
  GIT_BIN=""
  GIT_ON_PATH=0
  GH_BIN=""
  GH_ON_PATH=0
  MISSING_PATH_DIRS=""
  CRLF_FILES=""
  AUTH_OK=0
  REPO_IS_REPO=0
  REPO_NESTED=0
  PROJECT_REAL=""
  REPO_TOP=""
  OWNER=""
  REPO_NAME=""
  REPO_PRIVATE=""
  REPO_PUSH=""
  REPO_ADMIN=""
  REPO_CANONICAL_NAME=""
  GIT_SAFE_PATH=""
}

add_issue() {
  _code=$1
  _msg=$(redact_url "$2")
  case " $ISSUES_CODES " in
    *" $_code "*) ;;
    *) ISSUES_CODES="$ISSUES_CODES $_code" ;;
  esac
  ISSUES_DETAIL="${ISSUES_DETAIL}${_code}|${_msg}
"
}

code_present() {
  case " $ISSUES_CODES " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

add_missing_dir() {
  _dir=$1
  [ -n "$_dir" ] || return 0
  case ":$MISSING_PATH_DIRS:" in
    *":$_dir:"*) ;;
    *) MISSING_PATH_DIRS="${MISSING_PATH_DIRS:+$MISSING_PATH_DIRS:}$_dir" ;;
  esac
}

# ---------- 临时目录 ----------
WORK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/shjz-doctor.XXXXXX" 2>/dev/null) || WORK_TMP=""
if [ -z "$WORK_TMP" ]; then
  WORK_TMP="${TMPDIR:-/tmp}/shjz-doctor.$$"
  mkdir -p "$WORK_TMP" 2>/dev/null || WORK_TMP=""
fi
cleanup() {
  if [ -n "${WORK_TMP:-}" ] && [ -d "$WORK_TMP" ]; then
    find "$WORK_TMP" -depth -delete 2>/dev/null || true
  fi
}
trap cleanup EXIT HUP INT TERM

# ---------- 参数 ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check" ;;
    --fix) MODE="fix" ;;
    --project)
      shift
      [ $# -gt 0 ] || { usage >&2; emit_contract "ACTION_REQUIRED" "ARGS" "参数缺少值" "修正参数后重跑 doctor.sh" "$PWD" "NONE" 20; }
      PROJECT_ARG=$1
      ;;
    --project=*) PROJECT_ARG=${1#*=} ;;
    --org)
      shift
      [ $# -gt 0 ] || { usage >&2; emit_contract "ACTION_REQUIRED" "ARGS" "参数缺少值" "修正参数后重跑 doctor.sh" "$PWD" "NONE" 20; }
      ORG=$1
      ;;
    --org=*) ORG=${1#*=} ;;
    --camp-home)
      shift
      [ $# -gt 0 ] || { usage >&2; emit_contract "ACTION_REQUIRED" "ARGS" "参数缺少值" "修正参数后重跑 doctor.sh" "$PWD" "NONE" 20; }
      CAMP_HOME=$1
      ;;
    --camp-home=*) CAMP_HOME=${1#*=} ;;
    --bootstrap)
      shift
      [ $# -gt 0 ] || { usage >&2; emit_contract "ACTION_REQUIRED" "ARGS" "参数缺少值" "修正参数后重跑 doctor.sh" "$PWD" "NONE" 20; }
      BOOTSTRAP_ARG=$1
      ;;
    --bootstrap=*) BOOTSTRAP_ARG=${1#*=} ;;
    --allow-global-safe-directory) ALLOW_SAFE_DIR=1 ;;
    -h|--help) usage; emit_contract "OK" "OK" "已显示帮助" "NONE" "$PWD" "NONE" 0 ;;
    *)
      log_line "未知参数：$1"
      usage >&2
      emit_contract "ACTION_REQUIRED" "ARGS" "参数错误" "修正参数后重跑 doctor.sh" "$PWD" "NONE" 20
      ;;
  esac
  shift
done

# ---------- 路径解析 ----------
# PROJECT：--project 优先；否则当前目录不是 Git 仓时用 $CAMP_HOME/repo。
if [ -n "$PROJECT_ARG" ]; then
  PROJECT=$PROJECT_ARG
else
  _cwd_is_repo=0
  if command -v git >/dev/null 2>&1 && git -C "$ORIG_PWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    _cwd_is_repo=1
  fi
  if [ "$_cwd_is_repo" = "1" ] || [ ! -f "$CAMP_HOME/repo" ]; then
    PROJECT=$ORIG_PWD
  else
    PROJECT=$(cat "$CAMP_HOME/repo" 2>/dev/null || printf '%s' "$ORIG_PWD")
    [ -n "$PROJECT" ] || PROJECT=$ORIG_PWD
  fi
fi
case "$PROJECT" in
  /*) ;;
  *) PROJECT="$ORIG_PWD/$PROJECT" ;;
esac
if [ -d "$PROJECT" ]; then
  PROJECT_REAL=$(cd "$PROJECT" 2>/dev/null && pwd -P) || PROJECT_REAL=$PROJECT
  PROJECT=$PROJECT_REAL
else
  PROJECT_REAL=$PROJECT
fi

# 当前脚本的绝对路径（用于 CRLF 检查）
SELF=$0
case "$SELF" in
  /*) ;;
  *) SELF="$ORIG_PWD/$SELF" ;;
esac

# ---------- 查找可执行文件 ----------
try_git_candidate() {
  [ -n "$1" ] || return 1
  [ -x "$1" ] || return 1
  GIT_BIN=$1
  GIT_ON_PATH=0
  add_missing_dir "$(dirname "$1")"
  return 0
}

find_git() {
  if command -v git >/dev/null 2>&1; then
    GIT_BIN=$(command -v git)
    GIT_ON_PATH=1
    return 0
  fi

  case "$OS_KIND" in
    mac)
      if [ "$TEST_MODE" != "1" ]; then
        try_git_candidate "/usr/bin/git" && return 0
        try_git_candidate "/opt/homebrew/bin/git" && return 0
        try_git_candidate "/usr/local/bin/git" && return 0
      fi
      ;;
    linux)
      if [ "$TEST_MODE" != "1" ]; then
        try_git_candidate "/usr/bin/git" && return 0
        try_git_candidate "/usr/local/bin/git" && return 0
      fi
      ;;
    windows)
      if [ "$TEST_MODE" != "1" ]; then
        try_git_candidate "/c/Program Files/Git/cmd/git.exe" && return 0
        if [ -n "${LOCALAPPDATA:-}" ]; then
          _la=$LOCALAPPDATA
          if command -v cygpath >/dev/null 2>&1; then
            _la=$(cygpath -u "$LOCALAPPDATA" 2>/dev/null || printf '%s' "$LOCALAPPDATA")
          fi
          try_git_candidate "$_la/Programs/Git/cmd/git.exe" && return 0
        fi
      fi
      ;;
  esac
  return 1
}

try_gh_candidate() {
  [ -n "$1" ] || return 1
  [ -x "$1" ] || return 1
  GH_BIN=$1
  _cand_dir=$(dirname "$1")
  case "$1" in
    *.exe)
      # Windows：目录在 PATH 中即可按命令名调用（Git Bash 自动补 .exe）。
      case ":$PATH:" in
        *":$_cand_dir:"*) GH_ON_PATH=1 ;;
        *) GH_ON_PATH=0; add_missing_dir "$_cand_dir" ;;
      esac
      ;;
    *)
      GH_ON_PATH=0
      add_missing_dir "$_cand_dir"
      ;;
  esac
  return 0
}

find_gh() {
  if command -v gh >/dev/null 2>&1; then
    GH_BIN=$(command -v gh)
    GH_ON_PATH=1
    return 0
  fi

  try_gh_candidate "$HOME/.local/bin/gh" && return 0
  try_gh_candidate "$HOME/.local/bin/gh.exe" && return 0
  if [ "$TEST_MODE" != "1" ]; then
    try_gh_candidate "/opt/homebrew/bin/gh" && return 0
    try_gh_candidate "/usr/local/bin/gh" && return 0
  fi
  return 1
}

# ---------- 网络（并行探测） ----------
curl_probe() {
  # -f：403/404 等非 2xx 视为不可达；-L 跟随重定向。
  curl -fsSL -o /dev/null --connect-timeout 5 --max-time 8 "$1" >/dev/null 2>&1
}

probe_one() {
  # $1=url $2=结果文件（写 1/0）；失败后等 2 秒重试一次
  if curl_probe "$1"; then
    printf '1' > "$2"
    return 0
  fi
  sleep 2 2>/dev/null || true
  if curl_probe "$1"; then
    printf '1' > "$2"
    return 0
  fi
  printf '0' > "$2"
  return 1
}

probe_git_web() {
  # curl 不通时用 git ls-remote 复核 github.com（不走 gh，避免登录状态影响）；硬超时 10 秒。
  _g=$(command -v git 2>/dev/null) || return 1
  GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1 GIT_HTTP_LOW_SPEED_TIME=5 \
    "$_g" ls-remote "https://github.com/${ORG}/camp-bootstrap.git" HEAD >/dev/null 2>&1 &
  _gp=$!
  ( sleep 10; kill "$_gp" 2>/dev/null ) &
  _wd=$!
  wait "$_gp" 2>/dev/null
  _rc=$?
  kill "$_wd" 2>/dev/null || true
  wait "$_wd" 2>/dev/null || true
  return "$_rc"
}

probe_network() {
  [ "$NET_PROBED" = "1" ] && return 0
  NET_PROBED=1
  NET_API_OK=0
  NET_WEB_OK=0
  NET_CODELOAD_OK=0
  NET_WEB_FALLBACK=0
  command -v curl >/dev/null 2>&1 || return 0

  if [ -n "$WORK_TMP" ] && [ -d "$WORK_TMP" ]; then
    probe_one "https://api.github.com/" "$WORK_TMP/net-api" &
    _p1=$!
    probe_one "https://github.com/" "$WORK_TMP/net-web" &
    _p2=$!
    probe_one "https://codeload.github.com/octocat/Hello-World/tar.gz/refs/heads/master" "$WORK_TMP/net-codeload" &
    _p3=$!
    wait "$_p1" 2>/dev/null || true
    wait "$_p2" 2>/dev/null || true
    wait "$_p3" 2>/dev/null || true
    [ "$(cat "$WORK_TMP/net-api" 2>/dev/null)" = "1" ] && NET_API_OK=1
    [ "$(cat "$WORK_TMP/net-web" 2>/dev/null)" = "1" ] && NET_WEB_OK=1
    [ "$(cat "$WORK_TMP/net-codeload" 2>/dev/null)" = "1" ] && NET_CODELOAD_OK=1
  else
    probe_one "https://api.github.com/" "/dev/null" && NET_API_OK=1
    probe_one "https://github.com/" "/dev/null" && NET_WEB_OK=1
    probe_one "https://codeload.github.com/octocat/Hello-World/tar.gz/refs/heads/master" "/dev/null" && NET_CODELOAD_OK=1
  fi

  # curl 对 github.com 偶发失败；api 可达时用 git ls-remote 复核。
  if [ "$NET_WEB_OK" != "1" ] && [ "$NET_API_OK" = "1" ]; then
    if probe_git_web; then
      NET_WEB_OK=1
      NET_WEB_FALLBACK=1
    fi
  fi
}

# 课程基础设施仓：公开是预期状态，不参与 REPO-PUBLIC 检查/自动转私有。
is_infra_repo() {
  # GitHub 仓名大小写不敏感，先转小写再比较。
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    camp-bootstrap|camp-cli|_org-infra|briceyun) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------- origin 解析 ----------
# 输出 "owner repo"，无法识别 github.com 形式时返回 1。
parse_origin() {
  # host 大小写不敏感（GitHub.com / GITHUB.COM 都接受）。
  _o=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  # 去掉 URL userinfo（https://user:token@host / https://token@host / ssh://git@host）。
  case "$_o" in
    https://*@github.com/*) _o="https://${_o#https://*@}" ;;
    http://*@github.com/*) _o="http://${_o#http://*@}" ;;
    ssh://*@github.com/*) _o="ssh://${_o#ssh://*@}" ;;
  esac
  # 依次去掉尾部 /、.git、再一个 /（兼容 repo.git/）。
  _o=${_o%/}
  _o=${_o%.git}
  _o=${_o%/}
  case "$_o" in
    https://github.com/*) _rest=${_o#https://github.com/} ;;
    http://github.com/*) _rest=${_o#http://github.com/} ;;
    git@github.com:*) _rest=${_o#git@github.com:} ;;
    ssh://github.com/*) _rest=${_o#ssh://github.com/} ;;
    ssh://git@github.com/*) _rest=${_o#ssh://git@github.com/} ;;
    git://github.com/*) _rest=${_o#git://github.com/} ;;
    *) return 1 ;;
  esac
  _owner=${_rest%%/*}
  _repo=${_rest#*/}
  _repo=${_repo%%/*}
  [ -n "$_owner" ] && [ -n "$_repo" ] || return 1
  printf '%s %s\n' "$_owner" "$_repo"
}

# ---------- 检查主体 ----------
run_checks() {
  reset_results

  # 1. OS / SHELL
  section "1/12" "系统"
  _uname=$(uname -s 2>/dev/null || printf 'unknown')
  case "$_uname" in
    Darwin) OS_KIND="mac"; OS_LABEL="macOS" ;;
    Linux) OS_KIND="linux"; OS_LABEL="Linux" ;;
    MINGW*|MSYS*|CYGWIN*) OS_KIND="windows"; OS_LABEL="Windows (Git Bash)" ;;
    *) OS_KIND="unknown"; OS_LABEL="未知（${_uname}）" ;;
  esac
  show "  系统: $OS_LABEL    Shell: ${SHELL:-未知}"
  if [ "$OS_KIND" = "unknown" ]; then
    add_issue "OS-UNSUPPORTED" "不支持的系统：$_uname"
    show "  ✗ 不支持的系统"
    return 0
  fi

  # 2. git
  section "2/12" "Git"
  if find_git; then
    if _gitver=$("$GIT_BIN" --version 2>/dev/null); then
      show "  ✓ $GIT_BIN ($_gitver)"
      if [ "$GIT_ON_PATH" != "1" ]; then
        show "  ! 不在 PATH 中"
      fi
    else
      _xcp=$(xcode-select -p 2>/dev/null || true)
      case "$_xcp" in
        *CommandLineTools*)
          add_issue "GIT-XCODE-STUB" "git 不可用，Command Line Tools 未安装完整"
          show "  ✗ git 不可用（Xcode 命令行工具占位）"
          ;;
        *)
          add_issue "GIT-BROKEN" "$GIT_BIN --version 失败"
          show "  ✗ git 无法运行：$GIT_BIN"
          ;;
      esac
      GIT_BIN=""
    fi
  else
    add_issue "GIT-MISSING" "找不到 git"
    show "  ✗ 找不到 git"
  fi

  # 3. bash（仅 Windows）
  section "3/12" "Bash"
  if [ "$OS_KIND" = "windows" ]; then
    if command -v bash >/dev/null 2>&1; then
      show "  ✓ $(command -v bash)"
    elif [ -x "/c/Program Files/Git/bin/bash.exe" ]; then
      show "  ✓ /c/Program Files/Git/bin/bash.exe"
    else
      _bash_candidate=""
      if [ -n "${LOCALAPPDATA:-}" ]; then
        _la_bash=$LOCALAPPDATA
        if command -v cygpath >/dev/null 2>&1; then
          _la_bash=$(cygpath -u "$LOCALAPPDATA" 2>/dev/null || printf '%s' "$LOCALAPPDATA")
        fi
        if [ -x "$_la_bash/Programs/Git/bin/bash.exe" ]; then
          _bash_candidate="$_la_bash/Programs/Git/bin/bash.exe"
        fi
      fi
      if [ -n "$_bash_candidate" ]; then
        show "  ✓ $_bash_candidate"
      else
        add_issue "BASH-MISSING" "找不到 Git Bash"
        show "  ✗ 找不到 bash"
      fi
    fi
  else
    show "  - 非 Windows，跳过"
  fi

  # 4. gh
  section "4/12" "GitHub CLI"
  if find_gh; then
    show "  ✓ $GH_BIN"
    if [ "$GH_ON_PATH" != "1" ]; then
      show "  ! 不在 PATH 中"
    fi
  else
    add_issue "GH-MISSING" "找不到 gh"
    show "  ✗ 找不到 gh"
  fi

  # 5. 脚本完整性（CR）
  section "5/12" "脚本完整性"
  _crlf_found=0
  for _f in "$SELF" "$CAMP_HOME/bootstrap.sh" "$CAMP_HOME/camp.sh"; do
    [ -f "$_f" ] || continue
    if LC_ALL=C grep -q "$(printf '\r')" "$_f" 2>/dev/null; then
      CRLF_FILES="${CRLF_FILES}${_f}
"
      add_issue "SCRIPT-CRLF" "$_f 含 Windows 换行（CR）"
      show "  ✗ 含 CR: $_f"
      _crlf_found=1
    fi
  done
  [ "$_crlf_found" = "0" ] && show "  ✓ 无 CR"

  # 6. PATH
  section "6/12" "PATH"
  if [ -n "$MISSING_PATH_DIRS" ]; then
    add_issue "PATH-MISSING" "PATH 缺少：$MISSING_PATH_DIRS"
    show "  ✗ PATH 缺少：$MISSING_PATH_DIRS"
  else
    show "  ✓ 关键命令可在 PATH 中找到"
  fi

  # 7. 网络
  section "7/12" "网络"
  probe_network
  if [ "$NET_API_OK" != "1" ]; then
    add_issue "NET-API" "api.github.com 不可达"
    show "  ✗ api.github.com 不可达"
  else
    show "  ✓ api.github.com"
  fi
  if [ "$NET_API_OK" = "1" ]; then
    if [ "$NET_WEB_OK" != "1" ]; then
      add_issue "NET-WEB" "github.com 不可达"
      show "  ✗ github.com 不可达"
    else
      if [ "$NET_WEB_FALLBACK" = "1" ]; then
        show "  ✓ github.com（curl 失败，git ls-remote 兜底成功）"
      else
        show "  ✓ github.com"
      fi
      if [ "$NET_CODELOAD_OK" != "1" ]; then
        show "  ! codeload.github.com 不可达（仅报告，不影响主流程）"
      else
        show "  ✓ codeload.github.com"
      fi
    fi
  fi

  # 8. 登录
  section "8/12" "GitHub 登录"
  if [ -z "$GH_BIN" ]; then
    show "  - 缺少 gh，跳过"
  elif [ "$NET_API_OK" != "1" ]; then
    show "  - api.github.com 不可达，跳过"
  else
    if [ -n "$WORK_TMP" ]; then
      _authfile="$WORK_TMP/auth-status"
    else
      _authfile="${TMPDIR:-/tmp}/shjz-auth.$$"
    fi
    if ! "$GH_BIN" auth status --hostname github.com > "$_authfile" 2>&1; then
      add_issue "AUTH-NONE" "未登录 GitHub"
      show "  ✗ 未登录"
    else
      _authout=$(cat "$_authfile" 2>/dev/null || true)
      _login=$("$GH_BIN" api user --jq .login 2>/dev/null) || _login=""
      if [ -z "$_login" ]; then
        add_issue "AUTH-INVALID" "登录状态无效"
        show "  ✗ 登录状态无效"
      else
        AUTH_OK=1
        _missing_scope=0
        # 只解析 "Token scopes:" 行，要求精确的带引号 scope（避免 public_repo / repo:status / 用户名误匹配）。
        _scopes_line=$(printf '%s\n' "$_authout" | grep -i "Token scopes:" | head -1)
        if [ -n "$_scopes_line" ]; then
          case "$_scopes_line" in
            *"'repo'"*) ;;
            *) _missing_scope=1 ;;
          esac
          case "$_scopes_line" in
            *"'read:org'"*|*"'admin:org'"*|*"'write:org'"*) ;;
            *) _missing_scope=1 ;;
          esac
        fi
        if [ "$_missing_scope" = "1" ]; then
          add_issue "AUTH-SCOPE" "缺少 repo 或 read:org 权限"
          show "  ! 已登录，但缺少 repo/read:org scope"
        else
          show "  ✓ 已登录：$_login"
        fi
      fi
    fi
  fi

  # 9. 组织
  section "9/12" "组织"
  if [ "$AUTH_OK" != "1" ]; then
    show "  - 登录不可用，跳过"
  else
    _state=$("$GH_BIN" api "user/memberships/orgs/$ORG" --jq .state 2>/dev/null) || _state=""
    if [ -z "$_state" ]; then
      add_issue "ORG-NONE" "读不到 $ORG 的组织身份"
      show "  ✗ 读不到 $ORG 的成员身份"
    elif [ "$_state" = "pending" ]; then
      add_issue "ORG-PENDING" "组织邀请待接受"
      show "  ✗ 组织邀请待接受"
    elif [ "$_state" != "active" ]; then
      add_issue "ORG-INACTIVE" "组织身份状态：$_state"
      show "  ✗ 组织身份状态：$_state"
    else
      show "  ✓ $ORG 成员状态 active"
    fi
  fi

  # 10. 项目仓库
  section "10/12" "项目仓库"
  check_repo

  # 11. 自动同步
  section "11/12" "自动同步"
  check_watcher

  # 12. 敏感 / 大文件
  section "12/12" "敏感/大文件"
  check_files
}

check_repo() {
  if [ -z "$GIT_BIN" ] || [ ! -d "$PROJECT" ]; then
    show "  - 缺少 git 或项目目录，跳过"
    return 0
  fi

  if [ -n "$WORK_TMP" ]; then
    _err="$WORK_TMP/git-top.err"
  else
    _err="${TMPDIR:-/tmp}/shjz-git-top.$$"
  fi
  _top=$("$GIT_BIN" -C "$PROJECT" rev-parse --show-toplevel 2>"$_err") || _top=""
  if [ -z "$_top" ]; then
    if grep -qi "dubious ownership" "$_err" 2>/dev/null; then
      GIT_SAFE_PATH=$PROJECT
      add_issue "GIT-SAFE-DIR" "Git 报告 dubious ownership：$PROJECT"
      show "  ✗ Git 所有权可疑（dubious ownership）"
    else
      show "  - 不是 Git 仓库（init 会创建，不算错）"
    fi
    return 0
  fi

  REPO_IS_REPO=1
  _pr=$(cd "$PROJECT" 2>/dev/null && pwd -P) || _pr=$PROJECT
  _tr=$(cd "$_top" 2>/dev/null && pwd -P) || _tr=$_top
  PROJECT_REAL=$_pr
  REPO_TOP=$_tr

  if [ "$_tr" != "$_pr" ]; then
    REPO_NESTED=1
    add_issue "REPO-NESTED" "项目位于上层仓库 $_tr 内"
    show "  ! 项目嵌套在上层仓库中：$_tr"
    # 嵌套时绝不检查/修改上层仓库的远端、身份、凭据。
    return 0
  fi
  show "  ✓ 仓库根目录：$_tr"

  _origin=$("$GIT_BIN" -C "$PROJECT" remote get-url origin 2>/dev/null) || _origin=""
  if [ -z "$_origin" ]; then
    add_issue "REPO-NO-REMOTE" "缺少 origin"
    show "  ! 缺少 origin"
  else
    _parsed=$(parse_origin "$_origin") || _parsed=""
    if [ -z "$_parsed" ]; then
      add_issue "REPO-FOREIGN" "origin 不是 github.com/${ORG}：$_origin"
      show "  ! origin 指向非课程组织：$_origin"
    else
      OWNER=${_parsed%% *}
      REPO_NAME=${_parsed#* }
      if [ "$OWNER" != "$ORG" ]; then
        add_issue "REPO-FOREIGN" "origin owner 是 ${OWNER}，不是 ${ORG}"
        show "  ! origin owner 是 ${OWNER}，不是 ${ORG}"
      else
        show "  ✓ origin：$OWNER/$REPO_NAME"
        check_repo_meta
      fi
    fi
  fi

  _un=$("$GIT_BIN" -C "$PROJECT" config --local --get user.name 2>/dev/null) || _un=""
  _ue=$("$GIT_BIN" -C "$PROJECT" config --local --get user.email 2>/dev/null) || _ue=""
  if [ -z "$_un" ] || [ -z "$_ue" ]; then
    add_issue "GIT-IDENTITY" "缺少 repo-local user.name / user.email"
    show "  ! 缺少 repo-local Git 身份"
  else
    show "  ✓ repo-local 身份：$_un <$_ue>"
  fi

  if [ "$AUTH_OK" = "1" ]; then
    # 同时收集通用 helper 与 github.com host-scoped helper（gh auth setup-git 写后者）。
    _helpers=$(
      {
        "$GIT_BIN" -C "$PROJECT" config --get-all credential.helper 2>/dev/null
        "$GIT_BIN" -C "$PROJECT" config --get-all credential.https://github.com.helper 2>/dev/null
      }
    )
    case "$_helpers" in
      *"gh auth git-credential"*)
        show "  ✓ credential helper：gh helper"
        ;;
      *)
        add_issue "GIT-CREDENTIAL" "缺少 gh 可用的 credential helper"
        show "  ! credential helper：非 gh helper"
        ;;
    esac
  fi
}

check_repo_meta() {
  [ -n "$GH_BIN" ] || return 0
  [ "$NET_API_OK" = "1" ] || return 0
  [ "$AUTH_OK" = "1" ] || return 0

  if [ -n "$WORK_TMP" ]; then
    _err2="$WORK_TMP/repo-meta.err"
  else
    _err2="${TMPDIR:-/tmp}/shjz-repo-meta.$$"
  fi
  _meta=$("$GH_BIN" api "repos/$OWNER/$REPO_NAME" \
    --jq '"\(.private) \(.permissions.push // false) \(.permissions.admin // false) \(.name // "")"' \
    2>"$_err2") || _meta=""

  if [ -z "$_meta" ]; then
    add_issue "REPO-MISSING" "读不到仓库 ${OWNER}/${REPO_NAME}（404 或无权限）"
    show "  ! 读不到远端仓库 $OWNER/$REPO_NAME"
    return 0
  fi

  REPO_PRIVATE=$(printf '%s' "$_meta" | awk '{print $1}')
  REPO_PUSH=$(printf '%s' "$_meta" | awk '{print $2}')
  REPO_ADMIN=$(printf '%s' "$_meta" | awk '{print $3}')
  # 以 API 返回的规范名（.name）判定基础设施仓；取不到时回退 origin 名。
  REPO_CANONICAL_NAME=$(printf '%s' "$_meta" | awk '{print $4}' | tr '[:upper:]' '[:lower:]')
  [ -n "$REPO_CANONICAL_NAME" ] || REPO_CANONICAL_NAME=$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]')

  if [ "$REPO_PRIVATE" = "false" ]; then
    _infra_name=${REPO_CANONICAL_NAME:-$REPO_NAME}
    if is_infra_repo "$_infra_name"; then
      show "  - 课程基础设施仓（${_infra_name}），公开是预期状态，跳过"
    else
      add_issue "REPO-PUBLIC" "仓库是公开的"
      show "  ! 仓库是公开的"
    fi
  else
    show "  ✓ 仓库私有性：${REPO_PRIVATE:-未知}"
  fi

  if [ "$REPO_PUSH" = "false" ]; then
    add_issue "REPO-PERM" "当前账号没有 push 权限"
    show "  ! 当前账号没有 push 权限"
  fi
}

check_watcher() {
  if [ ! -f "$CAMP_HOME/repo" ]; then
    show "  - 未接管仓库（$CAMP_HOME/repo 不存在），跳过"
    return 0
  fi

  _installed=1
  case "$OS_KIND" in
    mac)
      if launchctl list 2>/dev/null | grep -q "cn.shushuoai.shjz-camp"; then
        _installed=0
      elif [ -f "$HOME/Library/LaunchAgents/cn.shushuoai.shjz-camp.plist" ]; then
        _installed=0
      fi
      ;;
    linux)
      if systemctl --user list-timers --all 2>/dev/null | grep -q "shjz"; then
        _installed=0
      fi
      ;;
    windows)
      if schtasks //Query //TN shjz-camp >/dev/null 2>&1; then
        _installed=0
      fi
      ;;
  esac

  if [ "$_installed" = "0" ]; then
    show "  ✓ 已安装自动同步"
  else
    add_issue "WATCHER-MISSING" "未安装 60 秒自动同步"
    show "  ! 未安装自动同步"
  fi
}

check_files() {
  # 只扫描项目目录 3 层内（maxdepth 3）；更深层的 .env/证书/大文件不检查。
  [ -d "$PROJECT" ] || { show "  - 项目目录不存在，跳过"; return 0; }

  _sens=$(find "$PROJECT" -maxdepth 3 -type d \( -name .git -o -name node_modules \) -prune -o \
    -type f \( -name '.env' -o -name '*.pem' -o -name 'id_rsa' -o -name 'credentials*' \) \
    -print 2>/dev/null | head -3)
  if [ -n "$_sens" ]; then
    _sens_one=$(printf '%s' "$_sens" | tr '\n' ',')
    add_issue "SENSITIVE-FILES" "发现敏感文件：$_sens_one"
    show "  ! 敏感文件：$_sens_one"
  else
    show "  ✓ 3 层内无 .env/*.pem/id_rsa/credentials*"
  fi

  _large=$(find "$PROJECT" -maxdepth 3 -type d \( -name .git -o -name node_modules \) -prune -o \
    -type f -size +5120k -print 2>/dev/null | head -3)
  if [ -n "$_large" ]; then
    _large_one=$(printf '%s' "$_large" | tr '\n' ',')
    add_issue "LARGE-FILES" "发现 >5MB 文件：$_large_one"
    show "  ! 大文件：$_large_one"
  else
    show "  ✓ 3 层内无 >5MB 文件"
  fi
}

# ---------- 安全修复 ----------
LOG_FILE="$CAMP_HOME/doctor.log"
FIX_TS=$(date '+%Y%m%d-%H%M%S' 2>/dev/null || printf 'now')
BACKUP_DIR="$CAMP_HOME/backup/$FIX_TS"

log_fix() {
  mkdir -p "$CAMP_HOME" 2>/dev/null || true
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf 'now')" "$(redact_url "$*")" \
    >> "$LOG_FILE" 2>/dev/null || true
}

backup_file() {
  _bf=$1
  [ -f "$_bf" ] || return 0
  # 含内嵌凭据的文件一律不复制，避免 token 进入备份（.git/config 尤其重要）。
  if grep -Eq '://[^/@]+@|gh[pousr]_|github_pat_' "$_bf" 2>/dev/null; then
    log_fix "凭据文件不备份：$_bf"
    return 0
  fi
  mkdir -p "$BACKUP_DIR" 2>/dev/null || return 1
  chmod 700 "$BACKUP_DIR" 2>/dev/null || true
  _target="$BACKUP_DIR/$(basename "$_bf")"
  _n=1
  while [ -e "$_target" ]; do
    _target="$BACKUP_DIR/$(basename "$_bf").$_n"
    _n=$((_n + 1))
  done
  cp -p "$_bf" "$_target" 2>/dev/null || return 1
  log_fix "备份 $_bf -> $_target"
  return 0
}

persist_path_dir() {
  _pd=$1
  _profile=""
  case "${SHELL:-}" in
    */zsh) _profile="$HOME/.zshrc" ;;
    */bash) _profile="$HOME/.bashrc" ;;
    *) return 1 ;;   # 未知/未设置 SHELL：无法安全持久化，交给 ACTION_REQUIRED
  esac

  _line="export PATH=\"$_pd:\$PATH\""
  if grep -F "$_line" "$_profile" >/dev/null 2>&1; then
    return 0
  fi
  if [ -f "$_profile" ]; then
    backup_file "$_profile" || true
  fi
  {
    if [ -f "$_profile" ] && [ -s "$_profile" ]; then
      printf '\n'
    fi
    if ! grep -qF '# shjz camp doctor' "$_profile" 2>/dev/null; then
      printf '# shjz camp doctor\n'
    fi
    printf '%s\n' "$_line"
  } 2>/dev/null >> "$_profile" || {
    log_fix "写 shell profile 失败：$_profile"
    return 1
  }
  log_fix "写入 PATH：$_profile -> $_pd"
  return 0
}

persist_path_windows() {
  _wd=$1
  command -v powershell.exe >/dev/null 2>&1 || return 1
  _ps1="$WORK_TMP/set-user-path.ps1"
  if [ -z "$WORK_TMP" ]; then
    _ps1="${TMPDIR:-/tmp}/shjz-setpath.$$"
  fi
  _wd_windows=$(printf '%s' "$_wd" | sed -e 's|^/\([A-Za-z]\)/|\1:/|' -e 's|/|\\|g')
  cat > "$_ps1" <<'PS1'
$bin = $env:SHJZ_BIN_DIR
$cur = [Environment]::GetEnvironmentVariable('Path', 'User')
if ([string]::IsNullOrEmpty($cur)) { $cur = '' }
$parts = $cur -split ';'
if ($parts -notcontains $bin) {
  if ($cur -eq '') { $new = $bin } else { $new = $bin + ';' + $cur }
  [Environment]::SetEnvironmentVariable('Path', $new, 'User')
}
PS1
  SHJZ_BIN_DIR="$_wd_windows" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$_ps1" \
    >/dev/null 2>&1 || return 1
  return 0
}

fix_crlf() {
  [ -n "$CRLF_FILES" ] || return 0
  while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    [ -f "$_f" ] || continue
    backup_file "$_f" || {
      log_fix "CRLF 备份失败：$_f"
      continue
    }
    _t="$_f.doctor.$$"
    if tr -d '\r' < "$_f" > "$_t" 2>/dev/null && cat "$_t" > "$_f" 2>/dev/null; then
      FIX_APPLIED=1
      log_fix "CRLF -> LF：$_f"
      show "  [修复] 去 CR：$_f"
    else
      log_fix "CRLF 转换失败：$_f"
    fi
    rm -f "$_t" 2>/dev/null || true
  done <<EOF
$CRLF_FILES
EOF
}

fix_path() {
  [ -n "$MISSING_PATH_DIRS" ] || return 0
  _dirs=$(printf '%s' "$MISSING_PATH_DIRS" | tr ':' '\n')
  while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    export PATH="$_d:$PATH"
    _persist_ok=0
    case "$OS_KIND" in
      mac|linux) persist_path_dir "$_d" && _persist_ok=1 ;;
      windows) persist_path_windows "$_d" && _persist_ok=1 ;;
      *) _persist_ok=1 ;;
    esac
    if [ "$_persist_ok" = "1" ]; then
      FIX_APPLIED=1
      log_fix "PATH += $_d"
      show "  [修复] PATH 加入 $_d"
    else
      PERSIST_FAILED=1
      log_fix "PATH 持久化失败：$_d"
      show "  ! PATH 持久化失败：${_d}（当前进程已临时加入）"
    fi
  done <<EOF
$_dirs
EOF
}

resolve_bootstrap() {
  [ "$BOOTSTRAP_READY" = "1" ] && return 0
  BOOTSTRAP_READY=1
  if [ -n "$BOOTSTRAP_ARG" ] && [ -f "$BOOTSTRAP_ARG" ]; then
    BOOTSTRAP_FILE=$BOOTSTRAP_ARG
    return 0
  fi
  if [ -f "$ORIG_PWD/bootstrap.sh" ]; then
    BOOTSTRAP_FILE="$ORIG_PWD/bootstrap.sh"
    return 0
  fi
  if [ -f "$CAMP_HOME/bootstrap.sh" ]; then
    BOOTSTRAP_FILE="$CAMP_HOME/bootstrap.sh"
    return 0
  fi
  BOOTSTRAP_FILE=""
}

fetch_bootstrap() {
  [ -n "$BOOTSTRAP_FILE" ] && return 0
  [ -n "$WORK_TMP" ] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  _tmp="$WORK_TMP/bootstrap.sh"
  if curl -fsSL --connect-timeout 5 --max-time 8 \
      -H "Accept: application/vnd.github.raw" \
      "https://api.github.com/repos/$ORG/camp-bootstrap/contents/bootstrap.sh?ref=main" \
      -o "$_tmp" 2>/dev/null && [ -s "$_tmp" ]; then
    BOOTSTRAP_FILE=$_tmp
    log_fix "临时下载 bootstrap.sh"
    return 0
  fi
  return 1
}

fix_gh() {
  resolve_bootstrap
  fetch_bootstrap || true
  if [ -z "$BOOTSTRAP_FILE" ]; then
    log_fix "GH-MISSING：找不到 bootstrap.sh，无法自动安装"
    return 1
  fi
  if CAMP_HOME="$CAMP_HOME" CAMP_BIN_DIR="$BIN_DIR" HOME="$HOME" \
      bash "$BOOTSTRAP_FILE" --install-only >/dev/null 2>&1; then
    export PATH="$BIN_DIR:$PATH"
    if [ -x "$BIN_DIR/gh" ]; then
      GH_BIN="$BIN_DIR/gh"
    elif [ -x "$BIN_DIR/gh.exe" ]; then
      GH_BIN="$BIN_DIR/gh.exe"
    fi
    FIX_APPLIED=1
    log_fix "gh 安装完成：$BIN_DIR"
    show "  [修复] 已运行 bootstrap.sh --install-only"
  else
    log_fix "gh 安装失败"
  fi
}

fix_identity() {
  [ "$REPO_IS_REPO" = "1" ] || return 0
  [ -n "$GH_BIN" ] || {
    log_fix "GIT-IDENTITY：gh 不可用，跳过"
    return 0
  }
  _login=$("$GH_BIN" api user --jq '.login' 2>/dev/null) || _login=""
  if [ -z "$_login" ]; then
    log_fix "GIT-IDENTITY：读不到 gh 用户，跳过"
    return 1
  fi
  _name=$("$GH_BIN" api user --jq '.name // .login' 2>/dev/null) || _name=""
  [ -n "$_name" ] || _name=$_login
  _id=$("$GH_BIN" api user --jq '.id' 2>/dev/null) || _id=""
  if [ -n "$_id" ]; then
    _email="${_id}+${_login}@users.noreply.github.com"
  else
    _email="${_login}@users.noreply.github.com"
  fi

  backup_file "$PROJECT/.git/config" || true
  if "$GIT_BIN" -C "$PROJECT" config --local user.name "$_name" &&
     "$GIT_BIN" -C "$PROJECT" config --local user.email "$_email"; then
    FIX_APPLIED=1
    log_fix "repo-local 身份：$_name <$_email>"
    show "  [修复] 写入 repo-local 身份：$_name"
  else
    log_fix "写入 repo-local 身份失败"
  fi
}

fix_credential() {
  [ "$REPO_IS_REPO" = "1" ] || return 0
  [ -n "$GIT_BIN" ] || return 0
  backup_file "$PROJECT/.git/config" || true
  if ! "$GIT_BIN" -C "$PROJECT" config --local --replace-all credential.helper '!gh auth git-credential'; then
    log_fix "写入 credential helper 失败"
    return 1
  fi
  _v=$("$GIT_BIN" -C "$PROJECT" config --local --get-all credential.helper 2>/dev/null | head -1) || _v=""
  if [ "$_v" = '!gh auth git-credential' ]; then
    FIX_APPLIED=1
    log_fix "repo-local credential.helper = !gh auth git-credential"
    show "  [修复] 写入 repo-local credential helper"
  else
    log_fix "credential helper 回读不一致：$_v"
  fi
}

fix_public() {
  [ -n "$GH_BIN" ] || return 0
  _infra_name=${REPO_CANONICAL_NAME:-$REPO_NAME}
  if is_infra_repo "$_infra_name"; then
    log_fix "REPO-PUBLIC：$_infra_name 是课程基础设施仓，跳过自动转私有"
    show "  [跳过] 课程基础设施仓不自动转私有：$_infra_name"
    return 0
  fi
  if [ "$OWNER" != "$ORG" ]; then
    log_fix "REPO-PUBLIC：owner 非课程组织（${OWNER}），跳过自动转私有"
    show "  [跳过] owner 不是 ${ORG}，不自动转私有"
    return 0
  fi
  if [ "$REPO_ADMIN" = "true" ] && [ -n "$OWNER" ] && [ -n "$REPO_NAME" ] && [ "$OWNER" = "$ORG" ]; then
    if "$GH_BIN" repo edit "$OWNER/$REPO_NAME" \
        --visibility private --accept-visibility-change-consequences >/dev/null 2>&1; then
      FIX_APPLIED=1
      log_fix "仓库转私有：$OWNER/$REPO_NAME"
      show "  [修复] 仓库已转私有：$OWNER/$REPO_NAME"
    else
      log_fix "仓库转私有失败：$OWNER/$REPO_NAME"
    fi
  else
    log_fix "REPO-PUBLIC：当前账号无 admin，仅报告"
    show "  [跳过] 无 admin，公开仓仅报告"
  fi
}

fix_watcher() {
  if [ ! -f "$CAMP_HOME/camp.sh" ]; then
    log_fix "WATCHER-MISSING：camp.sh 不存在，仅报告"
    return 0
  fi
  if CAMP_HOME="$CAMP_HOME" bash "$CAMP_HOME/camp.sh" watch >/dev/null 2>&1; then
    FIX_APPLIED=1
    log_fix "自动同步已安装"
    show "  [修复] 已安装 60 秒自动同步"
  else
    log_fix "自动同步安装失败"
  fi
}

fix_safe_dir() {
  [ -n "$GIT_SAFE_PATH" ] || return 0
  if [ "$ALLOW_SAFE_DIR" = "1" ]; then
    backup_file "$HOME/.gitconfig" || true
    if "$GIT_BIN" config --global --add safe.directory "$GIT_SAFE_PATH" 2>/dev/null; then
      FIX_APPLIED=1
      log_fix "safe.directory += $GIT_SAFE_PATH"
      show "  [修复] 全局 safe.directory 加入 $GIT_SAFE_PATH"
    else
      log_fix "写 safe.directory 失败"
    fi
  else
    log_fix "GIT-SAFE-DIR：仅报告（未传 --allow-global-safe-directory）"
    show "  [跳过] safe.directory 仅报告（需 --allow-global-safe-directory）"
  fi
}

apply_fixes() {
  show ""
  show "[修复] 开始应用安全修复"
  [ -n "$ISSUES_CODES" ] || { show "  无需修复"; return 0; }

  if code_present "SCRIPT-CRLF"; then fix_crlf; fi
  if code_present "PATH-MISSING"; then fix_path; fi
  if code_present "GH-MISSING"; then fix_gh; fi
  if [ "$REPO_NESTED" = "1" ]; then
    log_fix "REPO-NESTED：跳过 fix_public / fix_identity / fix_credential"
  else
    if code_present "GIT-IDENTITY"; then fix_identity; fi
    if code_present "GIT-CREDENTIAL"; then fix_credential; fi
    if code_present "REPO-PUBLIC"; then fix_public; fi
  fi
  if code_present "WATCHER-MISSING"; then fix_watcher; fi
  if code_present "GIT-SAFE-DIR"; then fix_safe_dir; fi
  log_fix "修复流程结束（FIX_APPLIED=${FIX_APPLIED}）"
}

# ---------- 汇总输出 ----------
summary_for() {
  case "$1" in
    OK) printf '%s' "环境检查通过" ;;
    FIXED) printf '%s' "已自动修复环境问题，复查通过" ;;
    BLOCKED) printf '%s' "当前系统不受支持，无法继续" ;;
    *)
      case "$2" in
        OS-UNSUPPORTED) printf '%s' "不支持的操作系统" ;;
        GIT-MISSING) printf '%s' "缺少 Git" ;;
        GIT-BROKEN) printf '%s' "Git 无法运行" ;;
        GIT-XCODE-STUB) printf '%s' "Xcode 命令行工具未安装完整" ;;
        BASH-MISSING) printf '%s' "缺少 Git Bash" ;;
        GH-MISSING) printf '%s' "缺少 GitHub CLI" ;;
        SCRIPT-CRLF) printf '%s' "脚本含 Windows 换行" ;;
        PATH-MISSING) printf '%s' "PATH 缺少关键目录" ;;
        NET-API) printf '%s' "api.github.com 不可达" ;;
        NET-WEB) printf '%s' "github.com 不可达" ;;
        NET-CODELOAD) printf '%s' "codeload.github.com 不可达（仅报告）" ;;
        AUTH-NONE) printf '%s' "尚未登录 GitHub" ;;
        AUTH-INVALID) printf '%s' "GitHub 登录无效" ;;
        AUTH-SCOPE) printf '%s' "GitHub 授权缺少 scope" ;;
        ORG-NONE) printf '%s' "读不到组织成员身份" ;;
        ORG-PENDING) printf '%s' "组织邀请待接受" ;;
        ORG-INACTIVE) printf '%s' "组织成员状态非 active" ;;
        REPO-NESTED) printf '%s' "项目嵌套在上层 Git 仓库中（仅报告）" ;;
        REPO-NO-REMOTE) printf '%s' "项目缺少 origin（仅报告）" ;;
        REPO-FOREIGN) printf '%s' "origin 不属于课程组织（仅报告）" ;;
        REPO-MISSING) printf '%s' "远端仓库不存在或无权限（仅报告）" ;;
        REPO-PUBLIC) printf '%s' "仓库是公开的" ;;
        REPO-PERM) printf '%s' "账号缺少 push 权限（仅报告）" ;;
        GIT-IDENTITY) printf '%s' "缺少 repo-local Git 身份" ;;
        GIT-CREDENTIAL) printf '%s' "缺少 gh 可用的 credential helper" ;;
        WATCHER-MISSING) printf '%s' "未安装自动同步" ;;
        GIT-SAFE-DIR) printf '%s' "Git 所有权可疑（默认仅报告）" ;;
        SENSITIVE-FILES) printf '%s' "项目内有敏感文件（仅报告）" ;;
        LARGE-FILES) printf '%s' "项目内有 >5MB 文件（仅报告）" ;;
        *) printf '%s' "发现需要处理的问题" ;;
      esac
      ;;
  esac
}

action_for() {
  case "$1" in
    OK|FIXED) printf '%s' "重新运行 bootstrap.sh 完成建仓与同步" ;;
    OS-UNSUPPORTED) printf '%s' "改用 macOS、Linux 或 Windows Git Bash 后重试" ;;
    GIT-MISSING) printf '%s' "先安装 Git（macOS 可运行 xcode-select --install），再重跑 doctor.sh" ;;
    GIT-BROKEN) printf '%s' "重新安装 Git 后重跑 doctor.sh" ;;
    GIT-XCODE-STUB) printf '%s' "运行 xcode-select --install 完成安装，然后重跑 doctor.sh" ;;
    BASH-MISSING) printf '%s' "安装 Git for Windows（含 Git Bash），重开终端后重跑 doctor.sh" ;;
    GH-MISSING) printf '%s' "运行 doctor.sh --fix，让 bootstrap.sh --install-only 安装 gh" ;;
    SCRIPT-CRLF) printf '%s' "运行 doctor.sh --fix 把脚本转成 LF" ;;
    PATH-MISSING) printf '%s' "运行 doctor.sh --fix 写入 PATH 并重开终端" ;;
    NET-API) printf '%s' "切换网络或热点，确认 api.github.com 可达后重试" ;;
    NET-WEB) printf '%s' "切换网络或热点，确认 github.com 可达后重试" ;;
    NET-CODELOAD) printf '%s' "可继续；若 clone 失败再切换网络" ;;
    AUTH-NONE) printf '%s' "AI 运行 gh auth login --hostname github.com --web 发起设备码登录；学员只打开链接并输入代码，不需要自己运行命令" ;;
    AUTH-INVALID) printf '%s' "重新运行 gh auth login 完成登录，不要使用别人的 token" ;;
    AUTH-SCOPE) printf '%s' "重新授权，scope 必须包含 repo 和 read:org" ;;
    ORG-NONE) printf '%s' "让学员打开 https://github.com/orgs/$ORG/invitation 接受邀请，或联系助教确认已邀请" ;;
    ORG-PENDING) printf '%s' "让学员打开 https://github.com/orgs/$ORG/invitation 接受邀请" ;;
    ORG-INACTIVE) printf '%s' "联系助教确认组织成员状态" ;;
    REPO-NESTED) printf '%s' "把项目移出上层 Git 仓库（不要删除 .git），或改用独立目录后重跑" ;;
    REPO-NO-REMOTE) printf '%s' "运行 camp.sh init，或为项目添加指向课程组织的 origin" ;;
    REPO-FOREIGN) printf '%s' "确认 origin 后改回 https://github.com/$ORG/<repo>.git（不要 force push）" ;;
    REPO-MISSING) printf '%s' "让助教确认仓名与组织权限；不要当作私有仓处理" ;;
    REPO-PUBLIC) printf '%s' "运行 doctor.sh --fix（有 admin 时自动转私有）；无 admin 请学员在 GitHub 仓库 Settings 手动改为 Private" ;;
    REPO-PERM) printf '%s' "联系助教把学员加入 students team 并授予写权限" ;;
    GIT-IDENTITY) printf '%s' "运行 doctor.sh --fix 写入 repo-local user.name/user.email" ;;
    GIT-CREDENTIAL) printf '%s' "运行 doctor.sh --fix 写入 repo-local gh credential helper" ;;
    WATCHER-MISSING) printf '%s' "运行 doctor.sh --fix 安装自动同步（或 bash $CAMP_HOME/camp.sh watch）" ;;
    GIT-SAFE-DIR) printf '%s' "确认目录可信；默认只报告，必要时加 --allow-global-safe-directory 由管理员处理" ;;
    SENSITIVE-FILES) printf '%s' "把 .env/*.pem/id_rsa/credentials* 移出项目或加入 .gitignore" ;;
    LARGE-FILES) printf '%s' "移除或压缩 >5MB 文件后再同步" ;;
    *) printf '%s' "查看上方诊断并处理后重跑 doctor.sh" ;;
  esac
}

# ---------- 主流程 ----------
if [ "$MODE" = "fix" ]; then
  QUIET=1
  run_checks
  QUIET=0
  apply_fixes
  run_checks
else
  QUIET=0
  run_checks
fi

# PATH 持久化失败：当前进程已临时生效，但重开终端仍会缺失，必须保持 ACTION_REQUIRED。
if [ "$PERSIST_FAILED" = "1" ] && ! code_present "PATH-MISSING"; then
  ISSUES_CODES=" PATH-MISSING${ISSUES_CODES}"
  ISSUES_DETAIL="PATH-MISSING|PATH 已临时生效但持久化失败，重开终端后会缺失
${ISSUES_DETAIL}"
fi

# 列出问题
if [ -n "$ISSUES_CODES" ] && [ "$QUIET" = "0" ]; then
  show ""
  show "发现的问题："
  while IFS='|' read -r _c _m; do
    [ -n "$_c" ] || continue
    show "  - $_c: $_m"
  done <<EOF
$ISSUES_DETAIL
EOF
fi

# 状态判定：BLOCKED > ACTION_REQUIRED > FIXED > OK
STATUS="OK"
EXIT_CODE=0
if code_present "OS-UNSUPPORTED"; then
  STATUS="BLOCKED"
  EXIT_CODE=30
elif [ -n "$ISSUES_CODES" ]; then
  STATUS="ACTION_REQUIRED"
  EXIT_CODE=20
elif [ "$FIX_APPLIED" = "1" ]; then
  STATUS="FIXED"
  EXIT_CODE=10
fi

MAIN_CODE="OK"
if [ -n "$ISSUES_CODES" ]; then
  MAIN_CODE=$(printf '%s\n' "$ISSUES_CODES" | awk '{print $1}')
fi

ALSO="NONE"
if [ -n "$ISSUES_CODES" ]; then
  for _c in $ISSUES_CODES; do
    [ "$_c" = "$MAIN_CODE" ] && continue
    if [ "$ALSO" = "NONE" ]; then
      ALSO=$_c
    else
      ALSO="$ALSO,$_c"
    fi
  done
fi

SUMMARY=$(redact_url "$(summary_for "$STATUS" "$MAIN_CODE")")
ACTION="NONE"
if [ "$STATUS" = "OK" ]; then
  ACTION="NONE"
elif [ "$STATUS" = "FIXED" ]; then
  ACTION="重新运行 bootstrap.sh 完成建仓与同步"
else
  ACTION=$(redact_url "$(action_for "$MAIN_CODE")")
fi

printf '\nCAMP_DOCTOR 1\n'
printf 'STATUS=%s\n' "$STATUS"
printf 'CODE=%s\n' "$MAIN_CODE"
printf 'SUMMARY=%s\n' "$SUMMARY"
printf 'ACTION=%s\n' "$ACTION"
printf 'PROJECT=%s\n' "$PROJECT"
printf 'ALSO=%s\n' "$ALSO"

exit "$EXIT_CODE"
