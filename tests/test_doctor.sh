#!/usr/bin/env bash
# doctor.sh 测试：临时 HOME / CAMP_HOME / 项目目录 + fake gh/curl/launchctl/bootstrap。
# 兼容 macOS Bash 3.2。运行：bash tests/test_doctor.sh
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DOCTOR="$ROOT/doctor.sh"
ORG="shjz-ai-course202610"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/doctor-tests.XXXXXX") || exit 1
ORIG_PATH="$PATH"
TESTS=0
FAILS=0

trap 'find "$TMP" -depth -delete 2>/dev/null || true' EXIT

# ---------- 断言 ----------
check_eq() {
  TESTS=$((TESTS + 1))
  if [ "$2" != "$3" ]; then
    FAILS=$((FAILS + 1))
    printf 'FAIL: %s\n  期望: [%s]\n  实际: [%s]\n' "$1" "$2" "$3" >&2
  fi
}

check_contains() {
  TESTS=$((TESTS + 1))
  case "$3" in
    *"$2"*) ;;
    *) FAILS=$((FAILS + 1)); printf 'FAIL: %s\n  期望包含: [%s]\n  实际输出:\n%s\n' "$1" "$2" "$3" >&2 ;;
  esac
}

check_not_contains() {
  TESTS=$((TESTS + 1))
  case "$3" in
    *"$2"*) FAILS=$((FAILS + 1)); printf 'FAIL: %s\n  期望不包含: [%s]\n' "$1" "$2" >&2 ;;
    *) ;;
  esac
}

check_file_true() {
  TESTS=$((TESTS + 1))
  if [ ! -e "$2" ]; then
    FAILS=$((FAILS + 1))
    printf 'FAIL: %s\n  期望存在: [%s]\n' "$1" "$2" >&2
  fi
}

check_file_mode() {
  TESTS=$((TESTS + 1))
  _actual=$3
  if [ "$2" != "$_actual" ]; then
    FAILS=$((FAILS + 1))
    printf 'FAIL: %s\n  期望权限: [%s]\n  实际: [%s]\n' "$1" "$2" "$_actual" >&2
  fi
}

file_mode() {
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" 2>/dev/null ;;
    *) stat -c '%a' "$1" 2>/dev/null ;;
  esac
}

case_name() { printf '\n== %s ==\n' "$1"; }

# ---------- fake 工具 ----------
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/gh" <<'GH'
#!/usr/bin/env bash
set -u
log="${FAKE_GH_LOG:-/dev/null}"
printf '%s\n' "$*" >> "$log" 2>/dev/null || true
printf 'GH_HOST=%s\n' "${GH_HOST:-}" >> "$log" 2>/dev/null || true
state="${FAKE_GH_STATE_DIR:-}"
cmd="${1:-}"
case "$cmd" in
  auth)
    if [ "${FAKE_GH_AUTH_OK:-1}" = "1" ]; then
      printf 'github.com\n'
      printf '  Logged in to github.com account %s (keyring)\n' "${FAKE_GH_LOGIN:-tester}"
      if [ "${FAKE_GH_NO_SCOPES_LINE:-0}" = "1" ]; then
        :
      elif [ -n "${FAKE_GH_SCOPES_LINE:-}" ]; then
        printf '  - Token scopes: %s\n' "$FAKE_GH_SCOPES_LINE"
      elif [ "${FAKE_GH_SCOPES:-full}" = "none" ]; then
        printf "  - Token scopes: 'gist'\n"
      else
        printf "  - Token scopes: 'repo', 'read:org'\n"
      fi
      exit 0
    fi
    printf 'You are not logged into any GitHub hosts.\n' >&2
    exit 1
    ;;
  api)
    url="${2:-}"
    shift 2 2>/dev/null || true
    jqexpr=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --jq) shift; jqexpr="${1:-}" ;;
      esac
      shift
    done
    case "$url" in
      user/memberships/orgs/*)
        if [ "${FAKE_GH_ORG_READABLE:-1}" != "1" ]; then
          printf 'gh: Not Found (HTTP 404)\n' >&2
          exit 1
        fi
        printf '%s\n' "${FAKE_GH_ORG_STATE:-active}"
        exit 0
        ;;
      repos/*/*)
        if [ "${FAKE_GH_REPO_MISSING:-0}" = "1" ]; then
          printf 'gh: Not Found (HTTP 404)\n' >&2
          exit 1
        fi
        priv="${FAKE_GH_REPO_PRIVATE:-true}"
        if [ -n "$state" ] && [ -f "$state/private" ]; then
          priv=$(cat "$state/private")
        fi
        _repo=${url#repos/}
        _repo=${_repo##*/}
        _name="${FAKE_GH_REPO_NAME:-$_repo}"
        printf '%s %s %s %s\n' "$priv" "${FAKE_GH_REPO_PUSH:-true}" "${FAKE_GH_REPO_ADMIN:-true}" "$_name"
        exit 0
        ;;
      user)
        if [ "${FAKE_GH_USER_OK:-1}" != "1" ]; then
          exit 1
        fi
        case "$jqexpr" in
          *id*) printf '%s\n' "${FAKE_GH_USER_ID:-12345}" ;;
          *name*) printf '%s\n' "${FAKE_GH_USER_NAME:-Test User}" ;;
          *) printf '%s\n' "${FAKE_GH_LOGIN:-tester}" ;;
        esac
        exit 0
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  repo)
    if [ "${2:-}" = "edit" ]; then
      case " $* " in
        *" --visibility private "*) [ -n "$state" ] && printf 'true\n' > "$state/private" ;;
      esac
      exit 0
    fi
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
GH

cat > "$FAKEBIN/curl" <<'CURL'
#!/usr/bin/env bash
set -u
url=""
for a in "$@"; do
  case "$a" in
    http://*|https://*) url=$a ;;
  esac
done
host=${url#*://}
host=${host%%/*}
for h in ${FAKE_CURL_FAIL_HOSTS:-}; do
  if [ "$host" = "$h" ]; then
    exit 7
  fi
done
# 模拟“根路径 404”：FAKE_CURL_404_HOSTS 命中的 host，其根路径返回 404
_path=${url#*://*/}
for h in ${FAKE_CURL_404_HOSTS:-}; do
  if [ "$host" = "$h" ] && [ -z "$_path" ]; then
    exit 22
  fi
done
# 模拟 -f：HTTP >=400 时 curl 以 22 退出
_fail_on_http=0
for a in "$@"; do
  case "$a" in
    -*f*) _fail_on_http=1 ;;
  esac
done
code="${FAKE_CURL_HTTP_CODE:-200}"
if [ "$_fail_on_http" = "1" ]; then
  case "$code" in
    2*) ;;
    *) exit 22 ;;
  esac
fi
exit 0
CURL

cat > "$FAKEBIN/launchctl" <<'LAUNCH'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    if [ "${FAKE_LAUNCHCTL_HAS:-0}" = "1" ]; then
      printf 'PID\tStatus\tLabel\n'
      printf -- '-\t0\tcn.shushuoai.shjz-camp\n'
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
LAUNCH

cat > "$FAKEBIN/bootstrap" <<'BOOT'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FAKE_BOOTSTRAP_LOG:-/dev/null}" 2>/dev/null || true
if [ "${1:-}" = "--install-only" ]; then
  _dir="${CAMP_BIN_DIR:-$HOME/.local/bin}"
  mkdir -p "$_dir"
  _gh_name="${FAKE_BOOTSTRAP_GH_NAME:-gh}"
  cp "${FAKE_GH_SRC:?FAKE_GH_SRC missing}" "$_dir/$_gh_name"
  chmod +x "$_dir/$_gh_name"
  exit 0
fi
exit 0
BOOT

chmod +x "$FAKEBIN/gh" "$FAKEBIN/curl" "$FAKEBIN/launchctl" "$FAKEBIN/bootstrap"

# ---------- 沙箱助手 ----------
new_case() {
  _name=$1
  _base="$TMP/$_name"
  mkdir -p "$_base/home" "$_base/camp" "$_base/project" "$_base/state"
  printf '%s\n' "$_base"
}

init_repo() {
  _proj=$1
  _name=${2:-demo}
  mkdir -p "$_proj"
  git -C "$_proj" init -q >/dev/null 2>&1
  git -C "$_proj" remote add origin "https://github.com/$ORG/$_name.git"
  git -C "$_proj" config --local user.name "Test User"
  git -C "$_proj" config --local user.email "12345+tester@users.noreply.github.com"
  git -C "$_proj" config --local credential.helper '!gh auth git-credential'
  printf 'hello\n' > "$_proj/README.md"
}

make_isolated_bin() {
  # $1=dir $2=1 时包含 git；始终复制 fake curl/launchctl，不含 gh
  _dir=$1
  _with_git=$2
  mkdir -p "$_dir"
  for _c in bash sh env uname mktemp sed grep awk tr cp mv dirname basename head tail cat rm mkdir find date sleep chmod ls sort wc; do
    _p=$(command -v "$_c" 2>/dev/null) || continue
    case "$_p" in
      /*) ;;
      *) continue ;;
    esac
    ln -sf "$_p" "$_dir/$_c"
  done
  cp "$FAKEBIN/curl" "$_dir/curl"
  cp "$FAKEBIN/launchctl" "$_dir/launchctl"
  chmod +x "$_dir/curl" "$_dir/launchctl"
  if [ "$_with_git" = "1" ]; then
    _g=$(command -v git)
    ln -sf "$_g" "$_dir/git"
  fi
}

make_git_wrapper_bin() {
  # 除 ls-remote 外全部委托给真实 git；ls-remote 由 FAKE_GIT_LSREMOTE_OK 控制。
  _dir=$1
  mkdir -p "$_dir"
  _real=$(command -v git)
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [ "${1:-}" = "ls-remote" ]; then\n'
    printf '  [ "${FAKE_GIT_LSREMOTE_OK:-0}" = "1" ] && exit 0\n'
    printf '  exit 1\n'
    printf 'fi\n'
    printf 'exec "%s" "$@"\n' "$_real"
  } > "$_dir/git"
  chmod +x "$_dir/git"
}

run_doctor() {
  _base=$1
  _path=$2
  shift 2
  (
    export HOME="$_base/home"
    export CAMP_HOME="$_base/camp"
    export CAMP_BIN_DIR="$_base/home/.local/bin"
    export CAMP_TEST="${CAMP_TEST:-1}"
    export SHELL="${SHELL:-/bin/zsh}"
    export LOCALAPPDATA="${LOCALAPPDATA:-}"
    export PATH="$_path"
    export FAKE_GH_STATE_DIR="$_base/state"
    export FAKE_GH_LOG="${FAKE_GH_LOG:-$_base/gh.log}"
    export FAKE_BOOTSTRAP_LOG="${FAKE_BOOTSTRAP_LOG:-$_base/bootstrap.log}"
    export FAKE_GH_SRC="$FAKEBIN/gh"
    export FAKE_GH_AUTH_OK="${FAKE_GH_AUTH_OK:-1}"
    export FAKE_GH_USER_OK="${FAKE_GH_USER_OK:-1}"
    export FAKE_GH_SCOPES="${FAKE_GH_SCOPES:-full}"
    export FAKE_GH_SCOPES_LINE="${FAKE_GH_SCOPES_LINE:-}"
    export FAKE_GH_NO_SCOPES_LINE="${FAKE_GH_NO_SCOPES_LINE:-0}"
    export FAKE_GH_ORG_READABLE="${FAKE_GH_ORG_READABLE:-1}"
    export FAKE_GH_ORG_STATE="${FAKE_GH_ORG_STATE:-active}"
    export FAKE_GH_REPO_PRIVATE="${FAKE_GH_REPO_PRIVATE:-true}"
    export FAKE_GH_REPO_PUSH="${FAKE_GH_REPO_PUSH:-true}"
    export FAKE_GH_REPO_ADMIN="${FAKE_GH_REPO_ADMIN:-true}"
    export FAKE_GH_REPO_MISSING="${FAKE_GH_REPO_MISSING:-0}"
    export FAKE_GH_REPO_NAME="${FAKE_GH_REPO_NAME:-}"
    export FAKE_GH_USER_ID="${FAKE_GH_USER_ID:-12345}"
    export FAKE_GH_USER_NAME="${FAKE_GH_USER_NAME:-Test User}"
    export FAKE_GH_LOGIN="${FAKE_GH_LOGIN:-tester}"
    export FAKE_CURL_FAIL_HOSTS="${FAKE_CURL_FAIL_HOSTS:-}"
    export FAKE_CURL_404_HOSTS="${FAKE_CURL_404_HOSTS:-}"
    export FAKE_CURL_HTTP_CODE="${FAKE_CURL_HTTP_CODE:-200}"
    export FAKE_GIT_LSREMOTE_OK="${FAKE_GIT_LSREMOTE_OK:-0}"
    export FAKE_BOOTSTRAP_GH_NAME="${FAKE_BOOTSTRAP_GH_NAME:-gh}"
    /bin/bash "$DOCTOR" "$@"
  )
}

# =====================================================================
# 1. 全 OK
# =====================================================================
case_name "1. 全 OK"
base=$(new_case ok)
proj="$base/project"
init_repo "$proj"
out=$(run_doctor "$base" "$FAKEBIN:$ORIG_PATH" --project "$proj" --org "$ORG")
rc=$?
check_eq "1.1 exit 0" "0" "$rc"
check_contains "1.2 STATUS=OK" "STATUS=OK" "$out"
check_contains "1.3 CODE=OK" "CODE=OK" "$out"
proj_real=$(cd "$proj" && pwd -P)
check_contains "1.4 PROJECT 绝对路径" "PROJECT=$proj_real" "$out"

# =====================================================================
# 2. git 缺失（受限 PATH，不提供 git）
# =====================================================================
case_name "2. git 缺失"
base=$(new_case gitmissing)
bin="$base/bin"
make_isolated_bin "$bin" 0
out=$(run_doctor "$base" "$bin" --project "$base/project" --org "$ORG")
rc=$?
check_eq "2.1 exit 20" "20" "$rc"
check_contains "2.2 CODE=GIT-MISSING" "CODE=GIT-MISSING" "$out"
check_contains "2.3 STATUS=ACTION_REQUIRED" "STATUS=ACTION_REQUIRED" "$out"

# =====================================================================
# 3. gh 缺失 + fake bootstrap --fix -> --install-only
# =====================================================================
case_name "3. gh 缺失 + --fix"
base=$(new_case ghmissing)
proj="$base/project"
init_repo "$proj"
bin="$base/bin"
make_isolated_bin "$bin" 1
out=$(run_doctor "$base" "$bin" --project "$proj" --org "$ORG" \
  --bootstrap "$FAKEBIN/bootstrap" --fix)
rc=$?
check_eq "3.1 exit 10" "10" "$rc"
check_contains "3.2 STATUS=FIXED" "STATUS=FIXED" "$out"
check_contains "3.3 bootstrap 收到 --install-only" "--install-only" "$(cat "$base/bootstrap.log" 2>/dev/null || true)"
check_file_true "3.4 gh 已安装到 BIN_DIR" "$base/home/.local/bin/gh"

# =====================================================================
# 4. CRLF -> --fix 转 LF
# =====================================================================
case_name "4. CRLF"
base=$(new_case crlf)
proj="$base/project"
init_repo "$proj"
printf '#!/usr/bin/env bash\r\necho hi\r\n' > "$base/camp/camp.sh"
out=$(run_doctor "$base" "$FAKEBIN:$ORIG_PATH" --project "$proj" --org "$ORG" --fix)
rc=$?
check_eq "4.1 exit 10" "10" "$rc"
check_contains "4.2 STATUS=FIXED" "STATUS=FIXED" "$out"
if LC_ALL=C grep -q "$(printf '\r')" "$base/camp/camp.sh" 2>/dev/null; then
  check_eq "4.3 camp.sh 无 CR" "no-cr" "has-cr"
else
  check_eq "4.3 camp.sh 无 CR" "no-cr" "no-cr"
fi
backup_dir=$(find "$base/camp/backup" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
check_file_mode "4.4 backup 目录权限" "700" "$(file_mode "$backup_dir")"
check_file_mode "4.5 doctor.log 权限" "600" "$(file_mode "$base/camp/doctor.log")"

# =====================================================================
# 5. 无 repo-local 身份 -> --fix 写入
# =====================================================================
case_name "5. Git 身份"
base=$(new_case identity)
proj="$base/project"
init_repo "$proj"
git -C "$proj" config --local --unset-all user.name >/dev/null 2>&1 || true
git -C "$proj" config --local --unset-all user.email >/dev/null 2>&1 || true
# origin 带 token：parse_origin 必须剥离 userinfo；.git/config 备份必须跳过。
git -C "$proj" remote set-url origin "https://ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA@github.com/$ORG/demo.git"
out=$(run_doctor "$base" "$FAKEBIN:$ORIG_PATH" --project "$proj" --org "$ORG" --fix 2>&1)
rc=$?
check_eq "5.1 exit 10" "10" "$rc"
check_contains "5.2 STATUS=FIXED" "STATUS=FIXED" "$out"
uname_local=$(git -C "$proj" config --local --get user.name 2>/dev/null || true)
uemail_local=$(git -C "$proj" config --local --get user.email 2>/dev/null || true)
check_eq "5.3 user.name 已写入" "Test User" "$uname_local"
check_contains "5.4 user.email 已写入" "12345+tester@users.noreply.github.com" "$uemail_local"
check_eq "5.5 含 token 的 .git/config 未备份" "absent" "$([ -n "$(find "$base/camp/backup" -type f -name 'config*' 2>/dev/null | head -1)" ] && echo present || echo absent)"
check_contains "5.6 日志记录凭据不备份" "凭据文件不备份" "$(cat "$base/camp/doctor.log" 2>/dev/null || true)"
check_not_contains "5.7 token 不出现在 stdout/stderr" "ghp_AAAAAAAA" "$out"
check_not_contains "5.8 token 不出现在 doctor.log" "ghp_AAAAAAAA" "$(cat "$base/camp/doctor.log" 2>/dev/null || true)"

# =====================================================================
# 6. api.github.com 不可达
# =====================================================================
case_name "6. NET-API"
base=$(new_case netapi)
proj="$base/project"
init_repo "$proj"
out=$(FAKE_CURL_FAIL_HOSTS="api.github.com" run_doctor "$base" "$FAKEBIN:$ORIG_PATH" \
  --project "$proj" --org "$ORG")
rc=$?
check_eq "6.1 exit 20" "20" "$rc"
check_contains "6.2 CODE=NET-API" "CODE=NET-API" "$out"

# =====================================================================
# 7. api 通、github.com 不通
# =====================================================================
case_name "7. NET-WEB"
base=$(new_case netweb)
proj="$base/project"
init_repo "$proj"
wrapper="$base/gitwrap"
make_git_wrapper_bin "$wrapper"
out=$(FAKE_CURL_FAIL_HOSTS="github.com" FAKE_GIT_LSREMOTE_OK=0 \
  run_doctor "$base" "$wrapper:$FAKEBIN:$ORIG_PATH" --project "$proj" --org "$ORG")
rc=$?
check_eq "7.1 exit 20" "20" "$rc"
check_contains "7.2 CODE=NET-WEB" "CODE=NET-WEB" "$out"

# =====================================================================
# 8. 登录失败但 api 通
# =====================================================================
case_name "8. AUTH-NONE"
base=$(new_case authnone)
proj="$base/project"
init_repo "$proj"
out=$(FAKE_GH_AUTH_OK=0 run_doctor "$base" "$FAKEBIN:$ORIG_PATH" \
  --project "$proj" --org "$ORG")
rc=$?
check_eq "8.1 exit 20" "20" "$rc"
check_contains "8.2 CODE=AUTH-NONE" "CODE=AUTH-NONE" "$out"
check_contains "8.3 ACTION 由 AI 发起设备码" "AI 运行 gh auth login" "$out"
check_not_contains "8.4 不让学员执行命令" "学员本人在终端运行" "$out"

# =====================================================================
# 9. 组织 pending
# =====================================================================
case_name "9. ORG-PENDING"
base=$(new_case orgpending)
proj="$base/project"
init_repo "$proj"
out=$(FAKE_GH_ORG_STATE="pending" run_doctor "$base" "$FAKEBIN:$ORIG_PATH" \
  --project "$proj" --org "$ORG")
rc=$?
check_eq "9.1 exit 20" "20" "$rc"
check_contains "9.2 CODE=ORG-PENDING" "CODE=ORG-PENDING" "$out"

# =====================================================================
# 10. 公开仓 + admin -> --fix 调 gh repo edit 转私有
# =====================================================================
case_name "10. 公开仓 + admin"
base=$(new_case public)
proj="$base/project"
init_repo "$proj"
out=$(FAKE_GH_REPO_PRIVATE=false FAKE_GH_REPO_ADMIN=true \
  run_doctor "$base" "$FAKEBIN:$ORIG_PATH" --project "$proj" --org "$ORG" --fix)
rc=$?
check_eq "10.1 exit 10" "10" "$rc"
check_contains "10.2 STATUS=FIXED" "STATUS=FIXED" "$out"
ghlog=$(cat "$base/gh.log" 2>/dev/null || true)
check_contains "10.3 调用了 repo edit" "repo edit" "$ghlog"
check_contains "10.4 带 --visibility private" "--visibility private" "$ghlog"
check_eq "10.5 状态已改为私有" "true" "$(cat "$base/state/private" 2>/dev/null || true)"

# =====================================================================
# 11. 嵌套仓库：只报告，不做修改
# =====================================================================
case_name "11. REPO-NESTED"
base=$(new_case nested)
parent="$base/parent"
init_repo "$parent"
mkdir -p "$parent/sub"
printf 'keep\n' > "$parent/sub/keep.txt"
before_cfg=$(git -C "$parent" config --local --list 2>/dev/null)
out=$(run_doctor "$base" "$FAKEBIN:$ORIG_PATH" --project "$parent/sub" --org "$ORG")
rc=$?
after_cfg=$(git -C "$parent" config --local --list 2>/dev/null)
check_eq "11.1 exit 20" "20" "$rc"
check_contains "11.2 CODE=REPO-NESTED" "CODE=REPO-NESTED" "$out"
check_eq "11.3 Git 配置未改动" "$before_cfg" "$after_cfg"
check_eq "11.4 未在子目录建 .git" "absent" "$([ -e "$parent/sub/.git" ] && echo present || echo absent)"
check_eq "11.5 文件内容未改动" "keep" "$(cat "$parent/sub/keep.txt")"
check_not_contains "11.6 未查询远端仓库" "repos/" "$(cat "$base/gh.log" 2>/dev/null || true)"
outfix=$(run_doctor "$base" "$FAKEBIN:$ORIG_PATH" --project "$parent/sub" --org "$ORG" --fix)
rcfix=$?
after_fix_cfg=$(git -C "$parent" config --local --list 2>/dev/null)
check_eq "11.7 --fix exit 20" "20" "$rcfix"
check_eq "11.8 --fix 未改配置" "$before_cfg" "$after_fix_cfg"
check_not_contains "11.9 --fix 未调用 repo edit" "repo edit" "$(cat "$base/gh.log" 2>/dev/null || true)"

# =====================================================================
# 12. 输出契约字段齐全
# =====================================================================
case_name "12. 输出契约"
base=$(new_case contract)
proj="$base/project"
init_repo "$proj"
out=$(run_doctor "$base" "$FAKEBIN:$ORIG_PATH" --project "$proj" --org "$ORG")
rc=$?
check_eq "12.1 exit 0" "0" "$rc"
check_contains "12.2 版本行" "CAMP_DOCTOR 1" "$out"
check_contains "12.3 STATUS" "STATUS=OK" "$out"
check_contains "12.4 CODE" "CODE=OK" "$out"
check_contains "12.5 SUMMARY" "SUMMARY=" "$out"
check_contains "12.6 ACTION" "ACTION=" "$out"
check_contains "12.7 PROJECT" "PROJECT=" "$out"
check_contains "12.8 ALSO" "ALSO=NONE" "$out"
ghlog12=$(cat "$base/gh.log" 2>/dev/null || true)
check_contains "12.10 固定 GH_HOST" "GH_HOST=github.com" "$ghlog12"
check_contains "12.11 auth status 固定 hostname" "auth status --hostname github.com" "$ghlog12"

# 多错误时 ALSO 非空且逗号分隔
base2=$(new_case contract2)
bin2="$base2/bin"
make_isolated_bin "$bin2" 0
out2=$(run_doctor "$base2" "$bin2" --project "$base2/project" --org "$ORG")
check_contains "12.9 多错误 ALSO 非 NONE" "ALSO=GH-MISSING" "$out2"

# =====================================================================
# 13. 缺少 scope
# =====================================================================
case_name "13. AUTH-SCOPE"
base=$(new_case authscope)
proj="$base/project"
init_repo "$proj"
out=$(FAKE_GH_SCOPES=none run_doctor "$base" "$FAKEBIN:$ORIG_PATH" \
  --project "$proj" --org "$ORG")
rc=$?
check_eq "13.1 exit 20" "20" "$rc"
check_contains "13.2 CODE=AUTH-SCOPE" "CODE=AUTH-SCOPE" "$out"

# =====================================================================
# 14. 远端仓库 404 -> REPO-MISSING（不当作私有仓）
# =====================================================================
case_name "14. REPO-MISSING"
base=$(new_case repomissing)
proj="$base/project"
init_repo "$proj"
out=$(FAKE_GH_REPO_MISSING=1 run_doctor "$base" "$FAKEBIN:$ORIG_PATH" \
  --project "$proj" --org "$ORG")
rc=$?
check_eq "14.1 exit 20" "20" "$rc"
check_contains "14.2 CODE=REPO-MISSING" "CODE=REPO-MISSING" "$out"

# =====================================================================
# 15. origin 指向别组织 -> REPO-FOREIGN
# =====================================================================
case_name "15. REPO-FOREIGN"
base=$(new_case repoforeign)
proj="$base/project"
init_repo "$proj"
git -C "$proj" remote set-url origin "https://github.com/someone-else/demo.git"
out=$(run_doctor "$base" "$FAKEBIN:$ORIG_PATH" --project "$proj" --org "$ORG")
rc=$?
check_eq "15.1 exit 20" "20" "$rc"
check_contains "15.2 CODE=REPO-FOREIGN" "CODE=REPO-FOREIGN" "$out"

# =====================================================================
# 16. --check 只读：不写 doctor.log / backup
# =====================================================================
case_name "16. --check 只读"
base=$(new_case readonly)
proj="$base/project"
init_repo "$proj"
run_doctor "$base" "$FAKEBIN:$ORIG_PATH" --project "$proj" --org "$ORG" >/dev/null 2>&1
check_eq "16.1 未写 doctor.log" "absent" "$([ -e "$base/camp/doctor.log" ] && echo present || echo absent)"
check_eq "16.2 未建 backup 目录" "absent" "$([ -d "$base/camp/backup" ] && echo present || echo absent)"

# =====================================================================
# 17. admin:org 隐含 read:org：真实 scope 行不应误报 AUTH-SCOPE
# =====================================================================
case_name "17. admin:org 满足组织权限"
base=$(new_case adminorg)
proj="$base/project"
init_repo "$proj"
out=$(FAKE_GH_SCOPES_LINE="'admin:org', 'delete_repo', 'gist', 'repo', 'workflow'" \
  run_doctor "$base" "$FAKEBIN:$ORIG_PATH" --project "$proj" --org "$ORG")
rc=$?
check_eq "17.1 exit 0" "0" "$rc"
check_contains "17.2 STATUS=OK" "STATUS=OK" "$out"
check_not_contains "17.3 不报 AUTH-SCOPE" "AUTH-SCOPE" "$out"

# scopes 行缺失时不应误报 AUTH-SCOPE
out2=$(FAKE_GH_NO_SCOPES_LINE=1 run_doctor "$base" "$FAKEBIN:$ORIG_PATH" \
  --project "$proj" --org "$ORG")
rc2=$?
check_eq "17.4 无 scopes 行 exit 0" "0" "$rc2"
check_not_contains "17.5 无 scopes 行不误报" "AUTH-SCOPE" "$out2"

# =====================================================================
# 18. 课程基础设施仓公开且 admin：不报 REPO-PUBLIC，不调 gh repo edit
# =====================================================================
case_name "18. 基础设施仓不自动转私有"
base=$(new_case infrapublic)
proj="$base/project"
init_repo "$proj" camp-bootstrap
out=$(FAKE_GH_REPO_PRIVATE=false FAKE_GH_REPO_ADMIN=true \
  run_doctor "$base" "$FAKEBIN:$ORIG_PATH" --project "$proj" --org "$ORG" --fix)
rc=$?
check_eq "18.1 exit 0" "0" "$rc"
check_contains "18.2 STATUS=OK" "STATUS=OK" "$out"
check_not_contains "18.3 不报 REPO-PUBLIC" "REPO-PUBLIC" "$out"
check_not_contains "18.4 未调用 repo edit" "repo edit" "$(cat "$base/gh.log" 2>/dev/null || true)"
check_eq "18.5 未写入私有状态" "absent" "$([ -e "$base/state/private" ] && echo present || echo absent)"

# =====================================================================
# 19. 基础设施仓名大小写不敏感
# =====================================================================
case_name "19. 基础设施仓名大小写"
base=$(new_case infracase)
proj="$base/project"
init_repo "$proj" Camp-Bootstrap
out=$(FAKE_GH_REPO_PRIVATE=false FAKE_GH_REPO_ADMIN=true \
  run_doctor "$base" "$FAKEBIN:$ORIG_PATH" --project "$proj" --org "$ORG" --fix)
rc=$?
check_eq "19.1 exit 0" "0" "$rc"
check_not_contains "19.2 不报 REPO-PUBLIC" "REPO-PUBLIC" "$out"
check_not_contains "19.3 未调用 repo edit" "repo edit" "$(cat "$base/gh.log" 2>/dev/null || true)"

# =====================================================================
# 20. origin host 大小写不敏感
# =====================================================================
case_name "20. origin host 大小写"
base=$(new_case hostcase)
proj="$base/project"
init_repo "$proj"
git -C "$proj" remote set-url origin "https://GitHub.com/$ORG/Demo.git"
out=$(run_doctor "$base" "$FAKEBIN:$ORIG_PATH" --project "$proj" --org "$ORG")
rc=$?
check_eq "20.1 exit 0" "0" "$rc"
check_not_contains "20.2 不报 REPO-FOREIGN" "REPO-FOREIGN" "$out"

# =====================================================================
# 21. HTTP 403 视为不可达（curl -f）
# =====================================================================
case_name "21. 403 视为不可达"
base=$(new_case http403)
proj="$base/project"
init_repo "$proj"
out=$(FAKE_CURL_HTTP_CODE=403 run_doctor "$base" "$FAKEBIN:$ORIG_PATH" \
  --project "$proj" --org "$ORG")
rc=$?
check_eq "21.1 exit 20" "20" "$rc"
check_contains "21.2 CODE=NET-API" "CODE=NET-API" "$out"

# =====================================================================
# 22. curl 对 github.com 失败，但 git ls-remote 成功 -> 不报 NET-WEB
# =====================================================================
case_name "22. curl 失败但 git ls-remote 成功"
base=$(new_case netfallbackok)
proj="$base/project"
init_repo "$proj"
wrapper="$base/gitwrap"
make_git_wrapper_bin "$wrapper"
out=$(FAKE_CURL_FAIL_HOSTS="github.com" FAKE_GIT_LSREMOTE_OK=1 \
  run_doctor "$base" "$wrapper:$FAKEBIN:$ORIG_PATH" --project "$proj" --org "$ORG")
rc=$?
check_eq "22.1 exit 0" "0" "$rc"
check_not_contains "22.2 不报 NET-WEB" "NET-WEB" "$out"
check_contains "22.3 使用 git ls-remote 兜底" "git ls-remote 兜底成功" "$out"

# =====================================================================
# 23. curl 与 git ls-remote 都失败 -> NET-WEB
# =====================================================================
case_name "23. curl 与 git ls-remote 都失败"
base=$(new_case netfallbackfail)
proj="$base/project"
init_repo "$proj"
wrapper="$base/gitwrap"
make_git_wrapper_bin "$wrapper"
out=$(FAKE_CURL_FAIL_HOSTS="github.com" FAKE_GIT_LSREMOTE_OK=0 \
  run_doctor "$base" "$wrapper:$FAKEBIN:$ORIG_PATH" --project "$proj" --org "$ORG")
rc=$?
check_eq "23.1 exit 20" "20" "$rc"
check_contains "23.2 CODE=NET-WEB" "CODE=NET-WEB" "$out"

# =====================================================================
# 24. PATH 持久化失败 -> 保持 PATH-MISSING / ACTION_REQUIRED
# =====================================================================
case_name "24. PATH 持久化失败"
base=$(new_case persistfail)
proj="$base/project"
init_repo "$proj"
bin="$base/bin"
make_isolated_bin "$bin" 1
mkdir -p "$base/home/.local/bin"
cp "$FAKEBIN/gh" "$base/home/.local/bin/gh"
chmod +x "$base/home/.local/bin/gh"
mkdir -p "$base/home/.zshrc"   # profile 路径是目录 -> 写入失败
out=$(SHELL=/bin/zsh run_doctor "$base" "$bin" --project "$proj" --org "$ORG" --fix)
rc=$?
check_eq "24.1 exit 20" "20" "$rc"
check_contains "24.2 CODE=PATH-MISSING" "CODE=PATH-MISSING" "$out"
check_contains "24.3 STATUS=ACTION_REQUIRED" "STATUS=ACTION_REQUIRED" "$out"
check_not_contains "24.4 不是 FIXED" "STATUS=FIXED" "$out"

# =====================================================================
# 25. Windows 候选路径含空格
# =====================================================================
case_name "25. Windows 路径含空格"
base=$(new_case winpath)
bin="$base/bin"
make_isolated_bin "$bin" 0
# 让 command -v bash 失败，专门走 LOCALAPPDATA 的 bash.exe 候选。
# 去掉 PATH 里的 bash 后，所有 fake 脚本改用绝对 shebang。
rm -f "$bin/uname" "$bin/bash"
cat > "$bin/uname" <<'UNAME'
#!/bin/bash
printf 'MINGW64_NT-10.0\n'
UNAME
chmod +x "$bin/uname"
cp "$FAKEBIN/gh" "$bin/gh"
sed '1s|^#!.*|#!/bin/bash|' "$bin/gh" > "$bin/gh.tmp" && mv "$bin/gh.tmp" "$bin/gh"
chmod +x "$bin/gh"
sed '1s|^#!.*|#!/bin/bash|' "$bin/curl" > "$bin/curl.tmp" && mv "$bin/curl.tmp" "$bin/curl"
chmod +x "$bin/curl"
la="$base/la with space"
gitcmd="$la/Programs/Git/cmd"
gitbin="$la/Programs/Git/bin"
mkdir -p "$gitcmd" "$gitbin"
cat > "$gitcmd/git" <<'GITEXE'
#!/bin/bash
case "${1:-}" in
  --version) printf 'git version 2.42.0.windows.1\n'; exit 0 ;;
  *) exit 1 ;;
esac
GITEXE
cp "$gitcmd/git" "$gitcmd/git.exe"
cat > "$gitbin/bash.exe" <<'BASHEXE'
#!/bin/bash
exit 0
BASHEXE
chmod +x "$gitcmd/git" "$gitcmd/git.exe" "$gitbin/bash.exe"

# 完整的 Git Bash 安装：cmd 目录在 PATH 中
out=$(CAMP_TEST=0 LOCALAPPDATA="$la" \
  run_doctor "$base" "$gitcmd:$bin" --project "$base/project" --org "$ORG")
rc=$?
check_eq "25.1 exit 0" "0" "$rc"
check_contains "25.2 找到含空格路径" "$gitcmd" "$out"
check_contains "25.3 git 可用" "git version 2.42.0.windows.1" "$out"
check_not_contains "25.4 不报 GIT-MISSING" "GIT-MISSING" "$out"

# 候选路径不在 PATH 时也要识别含空格的 git.exe（会如实报 PATH-MISSING）
out=$(CAMP_TEST=0 LOCALAPPDATA="$la" \
  run_doctor "$base" "$bin" --project "$base/project" --org "$ORG")
rc=$?
check_eq "25.5 候选路径 exit 20" "20" "$rc"
check_contains "25.6 识别含空格 git.exe" "$gitcmd/git.exe" "$out"
check_not_contains "25.7 不报 GIT-MISSING" "GIT-MISSING" "$out"
check_not_contains "25.8 不报 BASH-MISSING" "BASH-MISSING" "$out"
check_contains "25.9 识别含空格 bash.exe" "$gitbin/bash.exe" "$out"

# =====================================================================
# 26. --help / 参数错误也输出契约
# =====================================================================
case_name "26. --help / 参数错误契约"
out=$(/bin/bash "$DOCTOR" --help)
rc=$?
check_eq "26.1 --help exit 0" "0" "$rc"
check_contains "26.2 help 契约" "CAMP_DOCTOR 1" "$out"
check_contains "26.3 help STATUS=OK" "STATUS=OK" "$out"
out=$(/bin/bash "$DOCTOR" --bogus 2>/dev/null)
rc=$?
check_eq "26.4 bad args exit 20" "20" "$rc"
check_contains "26.5 bad args CODE=ARGS" "CODE=ARGS" "$out"

# =====================================================================
# 27. API 规范名（.name）识别基础设施仓
# =====================================================================
case_name "27. API 规范名识别基础设施仓"
base=$(new_case canonical)
proj="$base/project"
init_repo "$proj" 'camp%2Dbootstrap'
out=$(FAKE_GH_REPO_PRIVATE=false FAKE_GH_REPO_ADMIN=true FAKE_GH_REPO_NAME=camp-bootstrap \
  run_doctor "$base" "$FAKEBIN:$ORIG_PATH" --project "$proj" --org "$ORG" --fix)
rc=$?
check_eq "27.1 exit 0" "0" "$rc"
check_not_contains "27.2 不报 REPO-PUBLIC" "REPO-PUBLIC" "$out"
check_not_contains "27.3 未调用 repo edit" "repo edit" "$(cat "$base/gh.log" 2>/dev/null || true)"

# =====================================================================
# 28. codeload 用已知 tarball URL，根路径 404 不影响
# =====================================================================
case_name "28. codeload tarball URL"
base=$(new_case codeload)
proj="$base/project"
init_repo "$proj"
out=$(FAKE_CURL_404_HOSTS="codeload.github.com" \
  run_doctor "$base" "$FAKEBIN:$ORIG_PATH" --project "$proj" --org "$ORG")
rc=$?
check_eq "28.1 exit 0" "0" "$rc"
check_contains "28.2 codeload 可达" "✓ codeload.github.com" "$out"
check_not_contains "28.3 codeload 未告警" "! codeload.github.com" "$out"

# =====================================================================
# 29. origin 以 .git/ 结尾
# =====================================================================
case_name "29. origin 以 .git/ 结尾"
base=$(new_case dotslash)
proj="$base/project"
init_repo "$proj"
git -C "$proj" remote set-url origin "https://github.com/$ORG/demo.git/"
out=$(run_doctor "$base" "$FAKEBIN:$ORIG_PATH" --project "$proj" --org "$ORG")
rc=$?
check_eq "29.1 exit 0" "0" "$rc"
check_not_contains "29.2 不报 REPO-FOREIGN" "REPO-FOREIGN" "$out"

# =====================================================================
# 30. 未知 SHELL：持久化失败 -> PATH-MISSING / ACTION_REQUIRED
# =====================================================================
case_name "30. 未知 SHELL 持久化失败"
base=$(new_case fishshell)
proj="$base/project"
init_repo "$proj"
bin="$base/bin"
make_isolated_bin "$bin" 1
mkdir -p "$base/home/.local/bin"
cp "$FAKEBIN/gh" "$base/home/.local/bin/gh"
chmod +x "$base/home/.local/bin/gh"
out=$(SHELL=/bin/fish run_doctor "$base" "$bin" --project "$proj" --org "$ORG" --fix)
rc=$?
check_eq "30.1 exit 20" "20" "$rc"
check_contains "30.2 CODE=PATH-MISSING" "CODE=PATH-MISSING" "$out"
check_contains "30.3 STATUS=ACTION_REQUIRED" "STATUS=ACTION_REQUIRED" "$out"
check_not_contains "30.4 不是 FIXED" "STATUS=FIXED" "$out"
check_eq "30.5 未写 profile" "absent" "$([ -e "$base/home/.zshrc" ] || [ -e "$base/home/.bashrc" ] && echo present || echo absent)"

# =====================================================================
# 31. Windows：bootstrap 安装 gh.exe 后复查能找到
# =====================================================================
case_name "31. Windows gh.exe 安装后复查"
base=$(new_case wingh)
proj="$base/project"
init_repo "$proj"
bin="$base/bin"
make_isolated_bin "$bin" 1
rm -f "$bin/uname"
cat > "$bin/uname" <<'UNAME'
#!/usr/bin/env bash
printf 'MINGW64_NT-10.0\n'
UNAME
chmod +x "$bin/uname"
out=$(FAKE_BOOTSTRAP_GH_NAME=gh.exe \
  run_doctor "$base" "$bin" --project "$proj" --org "$ORG" \
  --bootstrap "$FAKEBIN/bootstrap" --fix)
rc=$?
check_eq "31.1 exit 10" "10" "$rc"
check_contains "31.2 STATUS=FIXED" "STATUS=FIXED" "$out"
check_file_true "31.3 gh.exe 已安装" "$base/home/.local/bin/gh.exe"
check_not_contains "31.4 复查不再 GH-MISSING" "GH-MISSING" "$out"

# =====================================================================
# 32. 仅全局 osxkeychain：GIT-CREDENTIAL；--fix 写入本地 gh helper
# =====================================================================
case_name "32. 全局 osxkeychain 不算 gh helper"
base=$(new_case credglobal)
proj="$base/project"
init_repo "$proj"
git -C "$proj" config --local --unset-all credential.helper >/dev/null 2>&1 || true
HOME="$base/home" git config --global credential.helper osxkeychain
out=$(run_doctor "$base" "$FAKEBIN:$ORIG_PATH" --project "$proj" --org "$ORG")
rc=$?
check_eq "32.1 exit 20" "20" "$rc"
check_contains "32.2 CODE=GIT-CREDENTIAL" "CODE=GIT-CREDENTIAL" "$out"
check_contains "32.3 新 summary" "缺少 gh 可用的 credential helper" "$out"
check_not_contains "32.4 不打印原始 helper" "osxkeychain" "$out"
out2=$(run_doctor "$base" "$FAKEBIN:$ORIG_PATH" --project "$proj" --org "$ORG" --fix)
rc2=$?
check_eq "32.5 exit 10" "10" "$rc2"
check_contains "32.6 STATUS=FIXED" "STATUS=FIXED" "$out2"
check_contains "32.7 写入本地 gh helper" "!gh auth git-credential" "$(git -C "$proj" config --local --get-all credential.helper 2>/dev/null | head -1)"

# =====================================================================
# 33. host-scoped gh helper 视为健康
# =====================================================================
case_name "33. host-scoped gh helper"
base=$(new_case credhostscope)
proj="$base/project"
init_repo "$proj"
git -C "$proj" config --local --unset-all credential.helper >/dev/null 2>&1 || true
git -C "$proj" config --local 'credential.https://github.com.helper' '!gh auth git-credential'
out=$(run_doctor "$base" "$FAKEBIN:$ORIG_PATH" --project "$proj" --org "$ORG")
rc=$?
check_eq "33.1 exit 0" "0" "$rc"
check_not_contains "33.2 不报 GIT-CREDENTIAL" "GIT-CREDENTIAL" "$out"
check_contains "33.3 报告 gh helper" "credential helper：gh helper" "$out"
check_not_contains "33.4 不打印原始 helper" "gh auth git-credential" "$out"

printf '\n%s: %s 项，%s 失败\n' "$(basename "$0")" "$TESTS" "$FAILS"
[ "$FAILS" -eq 0 ]
