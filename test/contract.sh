#!/usr/bin/env bash
# What hw assumes about the outside world: its own syntax, and the shape of the
# herdr CLI and JSON it reads. These drift without any change to hw, and the
# symptom is a command that quietly does nothing.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

group "the script itself"
if bash -n "$HWT_HW" 2>/dev/null; then ok "hw parses"; else bad "hw parses"; fi
if command -v shellcheck >/dev/null 2>&1; then
  if out=$(shellcheck -S style "$HWT_HW" 2>&1); then ok "shellcheck is clean"
  else bad "shellcheck is clean"; note "$out"; fi
else
  note "shellcheck not installed; skipped"
fi

group "bash 3.2, which is the only bash macOS ships"
# /usr/bin/env bash finds /bin/bash here, so anything from bash 4 is a runtime
# failure on the machine this runs on, not a portability nicety.
bash4=$(grep -nE 'declare -A|[^a-z]mapfile|[^a-z]readarray|\$\{[A-Za-z_]+\^\^|\$\{[A-Za-z_]+,,|&>>|;;&' "$HWT_HW" || true)
if [[ -z $bash4 ]]; then ok "no bash 4 constructs"; else bad "no bash 4 constructs"; note "$bash4"; fi
# `local a=1 b=$a` reads the outer a in 3.2, which under set -u aborts.
selfref=$(grep -nE '^\s*local [A-Za-z_]+=[^ ]* [A-Za-z_]+=\$[A-Za-z_]' "$HWT_HW" || true)
if [[ -z $selfref ]]; then ok "no local declaration reads a name from the same line"
else bad "no local declaration reads a name from the same line"; note "$selfref"; fi

group "dependencies hw shells out to"
for dep in herdr git fzf jq awk sed perl mktemp; do
  if command -v "$dep" >/dev/null 2>&1; then ok "$dep is on PATH"; else bad "$dep is on PATH"; fi
done

group "herdr subcommands and flags hw calls"
# A flag that is renamed or dropped upstream turns every call into a no-op that
# hw cannot see, because it sends output to /dev/null and shrugs off failure.
check_cli() {
  local group=$1 sub=$2; shift 2
  local help
  local missing=()
  if ! help=$(herdr "$group" "$sub" --help 2>&1); then
    bad "herdr $group $sub exists"; return
  fi
  local flags="${*:-}" flag
  for flag in "$@"; do
    grep -q -- "$flag" <<<"$help" || missing+=("$flag")
  done
  if (( ${#missing[@]} > 0 )); then
    bad "herdr $group $sub takes $flags"; note "missing: ${missing[*]}"
  else
    ok "herdr $group $sub $flags"
  fi
}
check_cli agent   focus
check_cli agent   list
check_cli agent   prompt
check_cli agent   rename          --clear
check_cli agent   start           --kind --pane
check_cli pane    list
check_cli workspace close
check_cli workspace create        --cwd --label --focus
check_cli workspace focus
check_cli workspace get
check_cli workspace list
check_cli workspace rename
check_cli workspace report-metadata --source --token
check_cli worktree open           --cwd --path --label --focus

group "JSON shapes hw reads"
hwt_setup_env
trap hwt_teardown EXIT
hwt_guard_isolated
if ! hwt_start_server; then
  bad "an isolated server to check JSON against"
  summary; exit
fi
src=$(hwt_make_repo contract probe)
hwt_register contract "$src"
( hwt_source_hw; create_worktree "$src" "probe" "" "" "" ) >/dev/null 2>&1

has_path() { # <json> <jq path> <what>
  local value
  value=$(jq -r "$2" <<<"$1" 2>/dev/null)
  if [[ -n $value && $value != "null" ]]; then ok "$3"; else bad "$3"; note "path: $2"; fi
}
ws_json=$(herdr workspace list 2>/dev/null)
has_path "$ws_json" '.result.workspaces[0].workspace_id'              'workspace_id'
has_path "$ws_json" '.result.workspaces[0].label'                     'label'
has_path "$ws_json" '.result.workspaces[0].worktree.checkout_path'    'worktree.checkout_path'
has_path "$ws_json" '.result.workspaces[0].worktree.repo_root'        'worktree.repo_root'
has_path "$ws_json" '.result.workspaces[0].worktree.repo_name'        'worktree.repo_name'
has_path "$ws_json" '.result.workspaces[0].worktree.is_linked_worktree|tostring' 'worktree.is_linked_worktree'
has_path "$ws_json" '.result.workspaces[]|select(.tokens.branch)|.tokens.branch' 'tokens.<name>'

pane_json=$(herdr pane list 2>/dev/null)
has_path "$pane_json" '.result.panes[0].pane_id'       'pane_id'
has_path "$pane_json" '.result.panes[0].workspace_id'  'pane workspace_id'
has_path "$pane_json" '.result.panes[0].cwd'           'pane cwd'

ws_id=$(jq -r '.result.workspaces[0].workspace_id' <<<"$ws_json")
get_json=$(herdr workspace get "$ws_id" 2>/dev/null)
has_path "$get_json" '.result.workspace.workspace_id' 'workspace get workspace_id'
has_path "$get_json" '.result.workspace.label'        'workspace get label'

agent_json=$(herdr agent list 2>/dev/null)
if jq -e '.result.agents' >/dev/null 2>&1 <<<"$agent_json"; then
  ok "agent list carries .result.agents"
else
  bad "agent list carries .result.agents"
fi

# worktree open is the call create_worktree reads two fields out of.
open_json=$(herdr worktree open --cwd "$src" --path "$HW_ROOT/contract/probe2" \
              --label "contract probe2" 2>/dev/null) || open_json=""
if [[ -n $open_json ]]; then
  has_path "$open_json" '.result.workspace.workspace_id' 'worktree open workspace_id'
  has_path "$open_json" '.result.root_pane.pane_id'      'worktree open root_pane.pane_id'
else
  note "worktree open returned nothing for a second checkout; skipped"
fi

summary
