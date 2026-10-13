#!/usr/bin/env bash
# Shared harness: assertions, and an isolated world to run hw against.

HWT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HWT_HW="$HWT_ROOT/hw"

HWT_PASS=0
HWT_FAIL=0
HWT_CURRENT=""

ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; HWT_PASS=$((HWT_PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; HWT_FAIL=$((HWT_FAIL+1)); }
note() { printf '       %s\n' "$*"; }
group(){ HWT_CURRENT=$1; printf '\n\033[1m%s\033[0m\n' "$1"; }

# assert_eq <expected> <actual> <what>
assert_eq() {
  local want=$1 got=$2 what=$3
  if [[ $want == "$got" ]]; then ok "$what"; else
    bad "$what"; note "want: [$want]"; note "got:  [$got]"
  fi
}

# assert_contains <haystack> <needle> <what>
assert_contains() {
  local hay=$1 needle=$2 what=$3
  if [[ $hay == *"$needle"* ]]; then ok "$what"; else
    bad "$what"; note "looked for: [$needle]"; note "in: [${hay:0:400}]"
  fi
}

# assert_rc <expected rc> <what> -- cmd...
assert_rc() {
  local want=$1 what=$2; shift 3
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  assert_eq "$want" "$got" "$what"
}

assert_file()    { [[ -f $1 ]] && ok "$2" || { bad "$2"; note "missing file: $1"; }; }
assert_dir()     { [[ -d $1 ]] && ok "$2" || { bad "$2"; note "missing dir: $1"; }; }
assert_no_dir()  { [[ ! -d $1 ]] && ok "$2" || { bad "$2"; note "still there: $1"; }; }

summary() {
  printf '\n\033[1m%d passed, %d failed\033[0m\n' "$HWT_PASS" "$HWT_FAIL"
  (( HWT_FAIL == 0 ))
}

# --- the isolated world -----------------------------------------------------
#
# Everything hw and herdr touch is redirected into one temp directory. The
# guard is not politeness: the first attempt at this silently drove the real
# session, because a readiness check that accepts any successful CLI call is
# answered by whatever server is already running.

hwt_setup_env() {
  HWT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/hw-test-XXXXXX") || exit 1
  export HWT_DIR
  export XDG_CONFIG_HOME="$HWT_DIR/xdg-config"
  export XDG_STATE_HOME="$HWT_DIR/xdg-state"
  export HERDR_SOCKET_PATH="$HWT_DIR/xdg-config/herdr/herdr.sock"
  export HW_ROOT="$HWT_DIR/worktrees"
  export HW_CACHE="$HWT_DIR/cache"
  export HW_CONFIG="$HWT_DIR/hw-config.sh"
  export HW_JOBLOG="$HWT_DIR/cache/jobs.log"
  export HW_REGISTRY="$HWT_DIR/projects.tsv"
  export HW_NO_PAUSE=1
  export HW_SMART_BRANCH=0          # no network, no claude
  export GIT_CONFIG_GLOBAL="$HWT_DIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME=hw-test GIT_AUTHOR_EMAIL=hw@test
  export GIT_COMMITTER_NAME=hw-test GIT_COMMITTER_EMAIL=hw@test
  # Scratch files land here too, so a test can assert that nothing leaked
  # without counting litter an earlier run of something else left in /tmp.
  export TMPDIR="$HWT_DIR/tmp"
  mkdir -p "$XDG_CONFIG_HOME/herdr" "$XDG_STATE_HOME" "$HW_ROOT" "$HW_CACHE" "$TMPDIR"
  : > "$HW_CONFIG"
  git config --global init.defaultBranch main
  git config --global user.name hw-test
  git config --global user.email hw@test
}

hwt_guard_isolated() {
  [[ -n ${HWT_DIR:-} ]]                   || { echo "no HWT_DIR"; exit 1; }
  [[ ${HERDR_SOCKET_PATH:-} == "$HWT_DIR"/* ]] \
    || { echo "refusing to run: HERDR_SOCKET_PATH is not inside $HWT_DIR"; exit 1; }
  [[ ${HW_ROOT:-} == "$HWT_DIR"/* ]] \
    || { echo "refusing to run: HW_ROOT is not inside $HWT_DIR"; exit 1; }
  [[ ${HW_CACHE:-} == "$HWT_DIR"/* ]] \
    || { echo "refusing to run: HW_CACHE is not inside $HWT_DIR"; exit 1; }
}

hwt_start_server() {
  hwt_guard_isolated
  herdr server >"$HWT_DIR/server-stdout.log" 2>&1 &
  HWT_SERVER=$!
  # Wait on the socket file this test owns, never on a CLI call succeeding.
  local i
  for i in $(seq 1 120); do
    [[ -S $HERDR_SOCKET_PATH ]] && break
    sleep 0.25
  done
  [[ -S $HERDR_SOCKET_PATH ]] || { echo "isolated server never bound $HERDR_SOCKET_PATH"; return 1; }
  for i in $(seq 1 40); do
    herdr workspace list >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  echo "isolated server bound but does not answer"
  return 1
}

hwt_stop_server() {
  [[ -n ${HWT_SERVER:-} ]] || return 0
  kill "$HWT_SERVER" 2>/dev/null || true
  wait "$HWT_SERVER" 2>/dev/null || true
  HWT_SERVER=""
}

hwt_teardown() {
  hwt_stop_server
  [[ -n ${HWT_DIR:-} && -d $HWT_DIR && $HWT_DIR == *hw-test-* ]] && rm -rf "$HWT_DIR"
  return 0
}

# A bare-layout project the way `hw` lays one out, with some history.
# hwt_make_repo <name> [extra-branch...]
hwt_make_repo() {
  local name=${1:?}; shift
  local work="$HWT_DIR/src-$name"
  mkdir -p "$work"
  git -C "$work" init -q
  printf 'hello from %s\n' "$name" > "$work/README.md"
  mkdir -p "$work/.herdr"
  git -C "$work" add -A
  git -C "$work" commit -q -m "initial commit"
  local b
  for b in "$@"; do
    git -C "$work" branch "$b"
  done
  printf '%s' "$work"
}

# Register a plain checkout as a project, the way `hw add` does.
hwt_register() {
  local name=${1:?} path=${2:?}
  printf '%s\t%s\n' "$name" "$path" >> "$HW_REGISTRY"
}

# Run with a deadline. A command that reaches fzf opens /dev/tty and waits for a
# keystroke no test can send, so a hang has to fail rather than stall the suite.
hwt_timeout() {
  local secs=${1:?}; shift
  "$@" </dev/null &
  local job=$!
  ( sleep "$secs"; kill -9 "$job" 2>/dev/null ) >/dev/null 2>&1 &
  local watchdog=$!
  local rc=0
  wait "$job" 2>/dev/null || rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  return "$rc"
}

hw() { hwt_timeout "${HWT_CMD_TIMEOUT:-60}" "$HWT_HW" "$@"; }

# Pull hw's functions into this shell for direct testing.
#
# hw sets `set -euo pipefail` at the top, and sourcing a script runs that in the
# caller: a suite that sources it then dies at its first failing assertion
# instead of reporting it. Put the suite's own options back afterwards. Note
# that functions called this way therefore run without errexit -- the integration
# suite runs hw as a real process, which is where that behaviour is covered.
hwt_source_hw() {
  # shellcheck source=/dev/null
  HW_LIB=1 . "$HWT_HW"
  set +e +o pipefail
  set -u
}
