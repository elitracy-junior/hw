#!/usr/bin/env bash
# End-to-end tests against a herdr server of this suite's own, with throwaway
# git repos. Never touches the session you are working in.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HWT_CMD_TIMEOUT=25
hwt_setup_env
trap hwt_teardown EXIT
hwt_guard_isolated
hwt_start_server || { echo "cannot start an isolated server; skipping"; exit 1; }

ws_count()  { herdr workspace list 2>/dev/null | jq -r '.result.workspaces | length'; }
ws_labels() { herdr workspace list 2>/dev/null | jq -r '.result.workspaces[].label' | sort | tr '\n' ' '; }
# Use hw's own lookup: a test that reimplements it cannot catch it being wrong.
ws_for()    { hwt_source_hw; workspace_for_path "$1"; }
token()     { herdr workspace list 2>/dev/null \
                | jq -r --arg w "$1" --arg t "$2" '.result.workspaces[] | select(.workspace_id == $w) | .tokens[$t] // ""'; }
# Wait for a detached job to land rather than sleeping a guessed amount.
wait_until() { local i; for i in $(seq 1 "${2:-60}"); do eval "$1" && return 0; sleep 0.25; done; return 1; }

group "a clean server starts empty"
assert_eq "0" "$(ws_count)" "no workspaces before anything is spawned"

group "spawn a worktree from an existing branch"
src=$(hwt_make_repo alpha feature-one)
hwt_register alpha "$src"
# Spawn entry points pick through fzf, which opens /dev/tty and so ignores any
# stdin a test could feed it. Drive create_worktree instead: it is the code all
# of them funnel into once the choice is made.
hwt_source_hw
HW_REVIEW_ICON=${HW_REVIEW_ICON:-}
ws=$(create_worktree "$src" "feature-one" "" "" "" 2>/dev/null | tail -1)
assert_contains "$ws" "w" "create_worktree returns a workspace id"
path="$HW_ROOT/alpha/feature-one"
assert_dir "$path" "the checkout exists on disk"
assert_eq "feature-one" "$(git -C "$path" rev-parse --abbrev-ref HEAD)" "it is on the branch asked for"
assert_eq "feature-one" "$(token "$ws" branch)" "the branch is reported as a token"
assert_contains "$(ws_labels)" "feature-one" "the space is named after the branch"

group "spawning the same branch again resumes rather than duplicating"
before=$(ws_count)
ws2=$(create_worktree "$src" "feature-one" "" "" "" 2>/dev/null | tail -1)
assert_eq "$before" "$(ws_count)" "no second space is created"
assert_eq "$ws" "$ws2" "the same space is returned"

group "a detached setup job reports and then clears its status"
# The hook lives in the registered checkout, which is where run_setup looks for
# it after resolving the project by registry name rather than directory name.
printf '#!/bin/sh\nsleep 1\ntouch "$HW_WORKTREE/setup-ran"\n' > "$src/.herdr/setup.sh"
chmod +x "$src/.herdr/setup.sh"
path2="$HW_ROOT/alpha/feature-two"
git -C "$src" branch feature-two 2>/dev/null || true
ws3=$(create_worktree "$src" "feature-two" "" "" "" 2>/dev/null | tail -1)
wait_until '[[ -n $(token '"$ws3"' hw_status) ]]' 20 \
  && ok "the space reports a job while one runs" \
  || note "status not observed (job may have finished first)"
wait_until '[[ -f '"$path2"'/setup-ran ]]' 60 \
  && ok "the setup hook runs outside the caller" \
  || bad "the setup hook runs outside the caller"
wait_until '[[ -z $(token '"$ws3"' hw_status) ]]' 60 \
  && ok "the status clears when the job ends" \
  || bad "the status clears when the job ends"

group "a detached job survives its caller being killed off"
# herdr signals every process in a closing pane's session. This sweeps the
# caller's session the same way, which is as close as a test gets -- it does not
# reproduce the narrow window between forking the job and its setsid, so it
# proves the job is in its own session, not that the window is shut.
marker="$HWT_DIR/outlives-caller"
rm -f "$marker"
cat > "$HWT_DIR/caller.sh" <<CALLER
#!/bin/bash
set -uo pipefail
HW_LIB=1 . "$HWT_HW"
set +e
detach /bin/sh -c "sleep 3; touch '$marker'"
echo \$\$ > "$HWT_DIR/caller.pid"
CALLER
chmod +x "$HWT_DIR/caller.sh"
perl -e 'use POSIX qw(setsid); setsid(); exec { $ARGV[0] } @ARGV' -- "$HWT_DIR/caller.sh" \
  >/dev/null 2>&1
caller_pid=$(cat "$HWT_DIR/caller.pid" 2>/dev/null || echo 0)
# Everything still in the caller's session goes, SIGKILL and all.
if [[ $caller_pid -gt 0 ]]; then
  sid=$(ps -o sess= -p "$caller_pid" 2>/dev/null | tr -d ' ')
  for pid in $(ps -ax -o pid=,sess= 2>/dev/null \
                | awk -v s="${sid:-none}" '$2 == s { print $1 }'); do
    [[ $pid == "$$" ]] && continue
    kill -9 "$pid" 2>/dev/null || true
  done
fi
wait_until "[[ -f '$marker' ]]" 60 \
  && ok "the job finished after its caller's session was swept" \
  || bad "the job finished after its caller's session was swept"

group "tearing a worktree down removes the checkout and closes the space"
teardown_path="$HW_ROOT/alpha/feature-one"
teardown_ws=$(ws_for "$teardown_path")
assert_contains "$teardown_ws" "w" "the space is found by checkout path"
hw __teardown "$teardown_path" "$teardown_ws" >/dev/null 2>&1
assert_no_dir "$teardown_path" "the checkout is gone"
wait_until '[[ -z $(ws_for '"$teardown_path"') ]]' 40 \
  && ok "the space is closed" || bad "the space is closed"
assert_contains "$(git -C "$src" worktree list)" "" "git still answers after the removal"
[[ $(git -C "$src" worktree list --porcelain | grep -c "^worktree ") -ge 1 ]] \
  && ok "the source checkout is untouched" || bad "the source checkout is untouched"

group "teardown is safe on every broken shape"
for shape in stale orphan foreign absent; do
  p="$HW_ROOT/alpha/shape-$shape"
  case $shape in
    stale)   git -C "$src" worktree add -q "$p" -b "b-$shape"; rm -rf "$p" ;;
    orphan)  git -C "$src" worktree add -q "$p" -b "b-$shape"
             rm -rf "$src/.git/worktrees/shape-$shape" ;;
    foreign) mkdir -p "$p"; echo x > "$p/file" ;;
    absent)  : ;;
  esac
  rc=0; hw __teardown "$p" "-" >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "teardown of a $shape checkout succeeds"
  assert_no_dir "$p" "a $shape checkout is left off disk"
done

group "nothing is ever deleted outright"
trashed=$(find "$HW_ROOT/.hw-trash" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
[[ $trashed -ge 1 ]] && ok "discarded checkouts went to .hw-trash" \
                     || bad "discarded checkouts went to .hw-trash"

group "a review mark reaches the sidebar as a token"
rv_path="$HW_ROOT/alpha/feature-two"
rv_ws=$(ws_for "$rv_path")
if [[ -n $rv_ws ]]; then
  ( hwt_source_hw; review_mark "$rv_path" )
  ( hwt_source_hw; sync_space_markers "$(herdr workspace list 2>/dev/null)" )
  assert_eq "$HW_REVIEW_ICON" "$(token "$rv_ws" review)" "a marked worktree reports the review glyph"
  ( hwt_source_hw; review_unmark "$rv_path" )
  ( hwt_source_hw; sync_space_markers "$(herdr workspace list 2>/dev/null)" )
  assert_eq "" "$(token "$rv_ws" review)" "unmarking clears the glyph"
else
  bad "a review mark reaches the sidebar as a token"; note "no workspace for $rv_path"
fi

group "hw sync re-asserts markers without failing"
rc=0; hw sync >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "hw sync exits clean"

group "hw doctor reports and repairs"
rc=0; hw doctor >/dev/null 2>&1 || rc=$?
[[ $rc -le 1 ]] && ok "hw doctor runs" || bad "hw doctor runs (rc=$rc)"
rc=0; hw doctor --fix >/dev/null 2>&1 || rc=$?
[[ $rc -le 1 ]] && ok "hw doctor --fix runs" || bad "hw doctor --fix runs (rc=$rc)"

group "every command that runs unattended exits clean"
# Exit status is not cosmetic here: hw's popup trap holds the window open on
# "[enter to close]" when a command exits non-zero, so a stray failing test at
# the end of a function looks to the user like the command broke.
run_clean() {
  local rc=0 out
  out=$(hw "$@" 2>&1) || rc=$?
  if [[ $rc -eq 0 ]]; then ok "hw $* exits clean"
  else bad "hw $* exits clean"; note "rc=$rc"; note "${out:0:200}"; fi
}
run_clean projects
run_clean sync
run_clean doctor
run_clean doctor --fix
run_clean help

group "closing a space that owns no worktree"
plain=$(herdr workspace create --cwd "$src" --label plain 2>/dev/null \
        | jq -r '.result.workspace.workspace_id')
if [[ -n $plain && $plain != null ]]; then
  run_clean close "$plain"
  wait_until '[[ -z $(herdr workspace list 2>/dev/null | jq -r --arg w "'"$plain"'" ".result.workspaces[]|select(.workspace_id==\$w)|.workspace_id") ]]' 20 \
    && ok "the space is closed" || bad "the space is closed"
else
  note "could not create a plain workspace; skipped"
fi

group "a missing server is reported, not shrugged off"
# Point at a socket nothing is listening on. Every herdr call inside hw ignores
# failure, so without the guard each of these would come up empty and silent.
saved_socket=$HERDR_SOCKET_PATH
export HERDR_SOCKET_PATH="$HWT_DIR/not-a-socket"
for sub in spaces agents sync doctor rm; do
  out=$(hw "$sub" 2>&1); rc=$?
  if [[ $rc -ne 0 && $out == *"no herdr server"* ]]; then
    ok "hw $sub says the server is missing"
  else
    bad "hw $sub says the server is missing"; note "rc=$rc out=${out:0:120}"
  fi
done
# Commands that need nothing from herdr still work.
rc=0; hw projects >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "hw projects still works without a server"
rc=0; hw help >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "hw help still works without a server"
export HERDR_SOCKET_PATH=$saved_socket

group "the job log records enough to debug a failed spawn"
assert_file "$HW_JOBLOG" "a job log was written"
log=$(cat "$HW_JOBLOG" 2>/dev/null)
assert_contains "$log" "spawn "    "it records each spawn"
assert_contains "$log" "detach "   "it records each job handed off"
assert_contains "$log" "setup "    "it records the setup job starting"
assert_contains "$log" "teardown " "it records the teardown job starting"
# A popup is gone before its output can be read, so these are the only trace of
# what a spawn did. "detach" without the matching "setup" means the job was
# handed off and never started.
assert_contains "$log" "pane="     "the setup line names the pane it will seed"

summary
