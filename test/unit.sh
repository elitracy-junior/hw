#!/usr/bin/env bash
# Pure-function tests. No herdr server, no network, no tty.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

hwt_setup_env
trap hwt_teardown EXIT
hwt_guard_isolated

# Source the functions without dispatching.
hwt_source_hw

group "slugs and branch names"
assert_eq "add-rate-limiting" "$(slug 'Add Rate Limiting')"         "slug lowercases and joins"
assert_eq "eli-feature-x"     "$(slug 'eli/feature x')"             "slug flattens a path separator"
assert_eq "a-b"               "$(slug '  a   b  ')"                 "slug collapses runs of space"
assert_eq ""                  "$(slug '///')"                      "slug of punctuation only is empty"
assert_contains "$(slug 'Ünïcødé naming')" "naming"                 "slug keeps ascii from mixed input"

# Offline naming only: HW_SMART_BRANCH=0, so no claude call.
name=$(branch_name_for 'I need to add rate limiting to the public API endpoints')
assert_contains "$name" "rate"                                      "offline name keeps a content word"
[[ $name != *"i-need-to"* ]] && ok "offline name drops filler" || bad "offline name drops filler"
[[ ${#name} -le 60 ]] && ok "offline name is bounded" || bad "offline name is bounded (${#name})"
assert_contains "$(branch_name_for '')" "" "empty prompt does not crash"

group "worktree_state classifies every shape"
src=$(hwt_make_repo state feature-a)
wt="$HWT_DIR/wt-ready"
git -C "$src" worktree add -q "$wt" feature-a
assert_eq "ready"   "$(worktree_state "$src" "$wt")"                 "a registered usable checkout is ready"
assert_eq "absent"  "$(worktree_state "$src" "$HWT_DIR/wt-nothing")" "nothing there is absent"

foreign="$HWT_DIR/wt-foreign"; mkdir -p "$foreign"; echo x > "$foreign/file"
assert_eq "foreign" "$(worktree_state "$src" "$foreign")"            "a non-checkout directory is foreign"

stale="$HWT_DIR/wt-stale"
git -C "$src" worktree add -q "$stale" -b stale-branch
rm -rf "$stale"
assert_eq "stale"   "$(worktree_state "$src" "$stale")"              "a registered but missing path is stale"

orphan="$HWT_DIR/wt-orphan"
git -C "$src" worktree add -q "$orphan" -b orphan-branch
rm -rf "$src/.git/worktrees/wt-orphan"
assert_eq "orphan"  "$(worktree_state "$src" "$orphan")"             "files without git metadata is orphan"

group "quarantine never deletes"
doomed="$HWT_DIR/wt-doomed"; mkdir -p "$doomed"; echo keepme > "$doomed/precious"
quarantine_path "$doomed" >/dev/null 2>&1
assert_no_dir "$doomed" "quarantine moves the directory away"
found=$(find "$HW_ROOT/.hw-trash" -name precious 2>/dev/null | head -1)
assert_contains "$found" "precious" "quarantine keeps the contents in .hw-trash"

group "review marks"
HW_REVIEWS="$HW_CACHE/reviews.tsv"
review_mark "/tmp/some/worktree" >/dev/null 2>&1
review_is "/tmp/some/worktree"   && ok "a marked path reads back as a review" \
                                 || bad "a marked path reads back as a review"
review_is "/tmp/other"           && bad "an unmarked path is not a review" \
                                 || ok "an unmarked path is not a review"
review_unmark "/tmp/some/worktree" >/dev/null 2>&1
review_is "/tmp/some/worktree"   && bad "unmark clears it" || ok "unmark clears it"
review_unmark "/tmp/never/marked" >/dev/null 2>&1 && ok "unmarking something unmarked is harmless" \
                                 || bad "unmarking something unmarked is harmless"

group "branch cache staleness"
HW_BRANCHES="$HW_CACHE/branches.tsv"
rm -f "$HW_BRANCHES"
branch_cache_stale && ok "a missing cache is stale" || bad "a missing cache is stale"
: > "$HW_BRANCHES"
branch_cache_stale && bad "a fresh cache is not stale" || ok "a fresh cache is not stale"
touch -t 200001010000 "$HW_BRANCHES"
branch_cache_stale && ok "an old cache is stale" || bad "an old cache is stale"

group "compose: the spawn prompt buffer"
printf '#!/bin/bash\nprintf "ship the thing\\n\\nwith care\\n" > "$1"\n' > "$HWT_DIR/ed-write.sh"
printf '#!/bin/bash\ntrue\n'                                           > "$HWT_DIR/ed-noop.sh"
printf '#!/bin/bash\nprintf "   \\n\\n" > "$1"\n'                      > "$HWT_DIR/ed-blank.sh"
printf '#!/bin/bash\nexit 1\n'                                         > "$HWT_DIR/ed-fail.sh"
chmod +x "$HWT_DIR"/ed-*.sh

body=$(HW_EDITOR="$HWT_DIR/ed-write.sh" compose) \
  && assert_eq "ship the thing

with care" "$body" "compose returns the prose and keeps its line breaks" \
  || bad "compose returns the prose and keeps its line breaks"

HW_EDITOR="$HWT_DIR/ed-noop.sh"  compose >/dev/null 2>&1 && bad "an untouched template cancels" || ok "an untouched template cancels"
HW_EDITOR="$HWT_DIR/ed-blank.sh" compose >/dev/null 2>&1 && bad "whitespace cancels"            || ok "whitespace cancels"
HW_EDITOR="$HWT_DIR/ed-fail.sh"  compose >/dev/null 2>&1 && bad "an editor failure cancels"     || ok "an editor failure cancels"

leaked=$(find "$TMPDIR" -maxdepth 1 -name 'hw-prompt-*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "0" "$leaked" "compose leaves no scratch directories behind"

group "logs do not grow without bound"
log="$HW_CACHE/grow.log"
seq 1 50000 > "$log"
before=$(wc -c < "$log" | tr -d ' ')
trim_log "$log" 100
after=$(wc -c < "$log" | tr -d ' ')
[[ $after -lt $before ]] && ok "an oversized log is trimmed" || bad "an oversized log is trimmed"
assert_eq "100" "$(wc -l < "$log" | tr -d ' ')" "it keeps the requested number of lines"
assert_eq "50000" "$(tail -1 "$log")" "it keeps the newest lines"
printf 'small\n' > "$log"
trim_log "$log" 100
assert_eq "small" "$(cat "$log")" "a small log is left alone"
trim_log "$HW_CACHE/no-such-log" && ok "a missing log is harmless" || bad "a missing log is harmless"
leftover=$(find "$HW_CACHE" -name '*.trim' | wc -l | tr -d ' ')
assert_eq "0" "$leftover" "trimming leaves no scratch file"

group "project naming"
assert_eq "myproj" "$(project_of "$HW_ROOT/myproj/some-branch")" "project_of reads the project from the path"
# A checkout registered in place is found by its registered name, not by the
# name of the directory it happens to sit in -- repo_ref looks it up by name,
# and guessing the basename silently skipped its setup hook.
elsewhere="$HWT_DIR/some-dir-name"
mkdir -p "$elsewhere"
hwt_register webapp "$elsewhere"
assert_eq "webapp" "$(project_of "$elsewhere")" "a registered checkout uses its registered name"
assert_eq "unregistered" "$(project_of "$HWT_DIR/unregistered")" "an unknown path falls back to its basename"

summary
