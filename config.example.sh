# hw configuration — sourced by ~/.local/bin/hw.
# `:-` form so an exported env var still wins over the file.

# Where worktrees and canonical checkouts live: $HW_ROOT/<project>/<name>
HW_ROOT="${HW_ROOT:-$HOME/Documents/worktrees}"

# GitHub org used by `hw proj` and `hw branch`
HW_ORG="${HW_ORG:-myjunior}"

# Agent launched in new worktrees (any `herdr agent start --kind` value)
HW_AGENT="${HW_AGENT:-claude}"

# Prefix for branches created by `hw new`
HW_BRANCH_PREFIX="${HW_BRANCH_PREFIX:-eli/}"

# Seconds between `hw watch` polls
HW_WATCH_INTERVAL="${HW_WATCH_INTERVAL:-90}"

# Vim-ish keys for every hw picker. fzf has no modal vi mode, so these are
# single-keystroke analogues. ctrl-h/j/k/l are intentionally NOT used: herdr
# binds them globally to herdr-splits pane nav, so they never reach fzf.
# Use the LEFT alt key — WezTerm's right alt composes characters instead.
HW_FZF_BIND="${HW_FZF_BIND:-\
alt-j:down,alt-k:up,\
ctrl-n:down,ctrl-p:up,\
ctrl-d:half-page-down,ctrl-u:half-page-up,\
ctrl-f:page-down,ctrl-b:page-up,\
alt-g:first,alt-G:last,\
alt-w:backward-kill-word,\
alt-0:beginning-of-line,alt-4:end-of-line,\
esc:abort}"

# Where "＋ add a folder…" looks for git repos to adopt.
HW_SCAN_DIRS="${HW_SCAN_DIRS:-$HOME/Documents $HOME/code $HOME/src $HOME/Developer $HOME/projects $HOME/repos}"
HW_SCAN_DEPTH="${HW_SCAN_DEPTH:-5}"

# Branch naming for `hw new` / the "new prompt" spawn.
# 1 = ask Claude for a short name; 0 = offline stopword-stripping only.
HW_SMART_BRANCH="${HW_SMART_BRANCH:-1}"
HW_NAME_MODEL="${HW_NAME_MODEL:-haiku}"
HW_NAME_TIMEOUT="${HW_NAME_TIMEOUT:-15}"   # seconds before falling back
