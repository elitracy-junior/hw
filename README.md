# hw — the Orca workflow on herdr

One bash script driving [herdr](https://github.com/herdrdev/herdr), nvim,
lazygit and `gh`: worktree spawning, project switching, PR review, and the
sidebar that shows it all.

## Install

```sh
git clone git@github.com:elitracy-junior/hw.git ~/Documents/hw
ln -s ~/Documents/hw/hw ~/.local/bin/hw
mkdir -p ~/.config/hw && cp ~/Documents/hw/config.example.sh ~/.config/hw/config.sh
```

Needs `herdr`, `git`, `fzf`, `jq` and `gh`. `hw linear` also needs a Linear API
key in the keychain, and branch naming uses `claude` when it is available.

The sidebar wants the patched herdr at
[elitracy-junior/herdr](https://github.com/elitracy-junior/herdr) — see
[Projects sidebar](#projects-sidebar). Everything else works against stock
herdr; the extra config keys are simply ignored.

## Layout

```
~/Documents/worktrees/<project>/.bare    bare repo — all git data, never a session
~/Documents/worktrees/<project>/.git     file: "gitdir: ./.bare"
~/Documents/worktrees/<project>/main     the default branch, an ordinary worktree
~/Documents/worktrees/<project>/<slug>   other worktrees
```

The repo is **bare** so that no checkout owns it. With a normal clone the
default-branch checkout is git's *main working tree*: it holds `.git/` and the
admin data for every linked worktree, so `git worktree remove` refuses it
(`fatal: ... is a main working tree`) and herdr groups all its sessions
together. Bare makes every checkout — `main` included — an ordinary worktree
you can close and remove independently.

herdr rejects a linked worktree as the source for new-worktree actions
(`linked_worktree_source`), so `hw` passes `--cwd <project>/.bare`.

## Sessions are grouped by repo

One session per worktree, named after its **branch**, sitting under its repo:

```
junior
  eli/questing
  feat/oncall-tasks
cs-ops
  eli/oncall-calendar-view
```

`hw` creates the worktree with plain `git worktree add`, then opens it with
`herdr worktree open` rather than `workspace create`. That is what records the
`repo_key` herdr groups on, so the grouping is herdr's own rather than
something hw draws. With the bare layout the group header herdr opens is the
`.bare` directory, which `normalize_main_label` renames to the project.

Sessions used to be flat, created with `workspace create`, which left herdr
with no worktree record for them: the built-in `branch` and `git_status`
sidebar tokens were blank and `prefix alt+g` could not see them. They are no
longer flat, and both work.

## Pickers

`hw spaces` (`prefix s`) and `hw agents` (`prefix a`) are fzf popups over the
live session list. Neither of herdr's built-ins does quite this: its
`workspace_picker` is a sidebar highlight rather than an overlay, and its
`goto` picker spans panes as well as spaces.

```
w1T    ·  cs-ops   feat/oncall-tasks
w1V    ●  cs-ops   eli/questing

w5:pA  *◑  sandbox  -             claude    Herdr and Claude workflow…
w1V:p1  ●  cs-ops   eli/questing  questing  On-call dashboard gamification
```

`*` marks where you are; `◑` working, `!` blocked, `✓` done, `●` idle, `·`
unknown. Both match on repo, branch, and (for agents) the terminal title.

## Projects

A project is a name plus a git source: a bare repo under `$HW_ROOT`, or **any
checkout registered in place**.

```
hw add [folder] [name]   register a local repo; nothing is moved or re-cloned
hw projects              list what is known
```

`prefix g` asks for the **project first**, then what to do in it:

```
＋ add a folder…     adopt a repo from disk
◆ junior             /Users/eli/Documents/Junior/repos/junior
● cs-ops             local
○ knock-knock        remote

        ↓  pick one

branch   branch or PR     check out existing work
prompt   new prompt       describe it, Claude picks up from there
linear   Linear ticket    pick one of your assigned issues
open     default branch   just open the repo
```

The picker resolves which names are already local **once**, then does a single
`awk` pass over the org list. Calling `project_src` per cache line meant ~120
subshells and took ~4s; it is now ~0.4s.

Rows are emitted registered → local → remote, and that order wins ties.

Registered and local rows carry **no trailing column** — the `◆ ● ○` marker
already says which kind each is. That is deliberate: every name is padded to
the same width, so line length comes down to what follows it, and fzf's
default `length` tiebreak was ranking a registered row carrying a 40-char path
*below* short remote names. Typing `junior` surfaced `junior-docs`,
`junior-mobile` and `junior-desktop` before the repo itself. With nothing after
the name, local rows are the shortest and length favours them, with index
(emission order) settling the rest.

This costs nothing — it is fzf's default sort. `--nth=2 --tiebreak=index`
fixes the same problem but measured ~2.7 ms/run slower, and re-runs on every
keystroke. Run `hw projects` to see where a registered project lives.

`＋ add a folder…` lists every git repo found under `$HW_SCAN_DIRS` (esc to
type a path instead), registers it, and drops you straight into the second
step — no second project prompt.

The branch picker shows **branch names only**, one per column. Earlier rows
carried the name twice plus the commit subject and PR title, so fuzzy matching
scored against all of it. Remote and local refs are merged and deduped, newest
first. `gh pr list` is no longer called: a PR's head branch is already a remote
branch, so it was a redundant network round-trip. Caveat: a PR from a **fork**
has no `origin/<branch>` and will not appear.

Registered folders stay exactly where they are; their worktrees still land
under `$HW_ROOT/<name>/<branch-slug>`. The registry is
`~/.config/hw/projects.tsv` (`<name>\t<path>`), safe to hand-edit.

Spawning is deliberately **not** cwd-aware — `hw spawn` always asks which
project first, so any branch of any repo can be started from anywhere.
Tune discovery with `HW_SCAN_DIRS` / `HW_SCAN_DEPTH` in `config.sh`.

## Writing the prompt

`prompt` opens a blank buffer in your editor rather than asking for one line at
a shell prompt. Write as much as you like, save, and the worktree is named from
it and the agent seeded with it.

```sh
HW_EDITOR=nvim   # falls back to $VISUAL, then $EDITOR, then nvim
```

The buffer is a `.md` file so nvim treats it as prose. Lines starting with `#`
are stripped, so the two-line hint at the bottom cannot reach the agent, and
saving nothing cancels. Line breaks are kept: herdr wraps an agent prompt in a
bracketed paste, where a newline is a newline rather than a submit.

`read -p` was wrong here twice over — a popup's stdin is not reliably a
terminal, which is what used to hang `hw close`, and one unscrollable line is a
poor place to write a paragraph.

## Branch naming

A prompted worktree gets a short name, not a slug of the whole sentence:

```
"can you create new sessions for my nvim git plugin so it syncs
 with the herdr sidebar"           ->  eli/nvim-herdr-sessions
"I need to add rate limiting to the public API endpoints"
                                   ->  eli/add-api-rate-limiting
```

`claude -p --model haiku` picks the name (~7s). If it is slow, unavailable, or
returns something chatty, `hw` falls back to stripping filler words and keeping
the first few meaningful ones — `eli/fix-flaky-retry-logic`. There is no
`timeout` binary on macOS, so the wait is polled and capped.

```sh
HW_SMART_BRANCH=0     # offline naming only
HW_NAME_MODEL=haiku
HW_NAME_TIMEOUT=15
```

## herdr keys (prefix = ctrl+s)

| Key | Does |
|---|---|
| `prefix s` | **`hw spaces`** — popup picker over open sessions |
| `prefix a` | **`hw agents`** — popup picker over live agents, across all spaces |
| `prefix g` | **`hw spawn`** — one picker: Linear ticket / branch / prompt / project |
| `prefix l` | lazygit popup |
| `prefix shift+g` | herdr's native new-worktree prompt |
| `prefix alt+g` | herdr's native open-worktree picker |
| `prefix d` / `prefix shift+d` | **`hw close`** — close this session, choose whether the worktree goes too |
| `prefix f` | herdr's own `goto` picker (spans panes as well as spaces) |
| `prefix w` | herdr's `workspace_picker` — a sidebar **highlight**, not a popup |
| `prefix j` / `prefix k` | next / previous space, no UI (displaces herdr's default `focus_pane_down`/`up`, unused here since panes move with `ctrl+hjkl`) |
| `prefix shift+1..9` | jump to a space by number |
| `prefix shift+x` | *disabled* — it acts on the whole repo, pulling in every session sharing it; `hw close` acts on one |

## nvim keys (leader = space)

| Key | Does |
|---|---|
| `<leader>wt` | **toggle the review panel** (right bar) |
| `<leader>wr` | refresh the panel now |
| `<leader>ww` | switch herdr workspace |
| `<leader>ws` | spawn a worktree (same picker as `prefix g`) |
| `<leader>op` | Octo: PR list |
| `<leader>oo` | Octo: current PR |
| `<leader>or` / `<leader>oR` | Octo: start / submit review |
| `<leader>oc` | Octo: PR checks |
| `<leader>od` | Octo: PR diff |
| `<leader>ot` | Octo: resolve thread |
| `<leader>gg` | lazygit (pre-existing) |

## Picker keys (fzf)

fzf has no modal vi mode, so `hw` binds single-keystroke analogues instead.
`ctrl-h/j/k/l` are deliberately unused — herdr grabs them globally for
herdr-splits pane navigation, so they never reach fzf in a popup.

| Key | Does |
|---|---|
| `alt-j` / `alt-k` | down / up |
| `ctrl-n` / `ctrl-p` | down / up (fzf defaults, kept) |
| `ctrl-d` / `ctrl-u` | half page down / up |
| `ctrl-f` / `ctrl-b` | page down / up |
| `alt-g` / `alt-G` | first / last |
| `alt-w` | delete word back |
| `alt-0` / `alt-4` | start / end of line (`^` and `$`) |
| `esc` | abort |

Use the **left** alt key; WezTerm's right alt composes characters. Override the
whole set with `HW_FZF_BIND` in `config.sh`.

## The review panel

`<leader>wt` toggles a right-hand `Snacks.win` showing, for the current branch:

- the PR header (number, title, state, +/−, review decision)
- CI checks, failures sorted to the top
- unresolved review threads with `file:line` and the comment text
- top-level discussion

It refreshes every 60s while open, plus on `FocusGained` and `BufWritePost`, and
`Snacks.notify`s when checks or comments actually change. `<leader>wr` or `r`
inside the panel forces a refresh.

`<leader>wt` puts the cursor **in** the panel, so you can scroll straight to a
comment without a second keystroke.

### Inside the panel

| Key | Does |
|---|---|
| `<CR>` / `<Tab>` / `za` | on a comment: expand the whole thread in place. On a failed check: open its log in a `Snacks.terminal`. On the header: open the PR in Octo. |
| `gf` | jump to the comment's `file:line` in your other window (resolved against the repo root; warns if the file is not in this checkout) |
| `o` | open the item in a browser |
| `r` | refresh |
| `q` | close |

An expanded thread (`▾`) shows the diff hunk the comment hangs on, then every
reply in full, wrapped. Diff lines are left intact rather than truncated — the
window is `nowrap`, so long code scrolls sideways. Bot `<details>` blocks (cubic's
"Prompt for AI agents") are stripped. Collapsed threads (`▸`) show a one-line
summary and a reply count.

Tunable from lua:

```lua
require("elias.work.panel").config.width = 60
require("elias.work.panel").config.refresh_interval = 30000
require("elias.work.panel").config.notify_on_change = false
```

## CLI

```
hw spawn | proj | new "<prompt>" | branch | linear | ci | pr | close | rm
hw spaces | agents | reviews | projects | add | sync | watch | doctor
```

`hw ci` / `hw pr` still work from a shell, but the panel is the better path.

## Projects sidebar

Stock herdr splits the sidebar into a Spaces panel and an Agents panel. Every
agent already knows its workspace, so that puts related things in two places
and spends half the sidebar doing it. The patched build folds them into one
tree instead:

```
junior
   eli/project-access-groups-rfc
       󰚩 claude
       ▪ nvim
       ▪ lazygit

   eli/oncall-calendar-view
       ⠼ claude
       • bun  :3500
```

- **Agents** carry an agent glyph, a braille spinner while working, and a green
  check when done. Grey otherwise — a column of coloured marks reads as alarm
  when nothing is wrong.
- **Panes** carry what they are running, named by the command rather than the
  whole line (`bun run dev` is `bun`) and looking past wrappers like
  `safe-chain`. A pane listening on a port shows it and breathes: the mark grows
  and shrinks. Deliberately not a spinner — a server that has been up for an
  hour should not look like it is stuck mid-request.
- **The mark left of a branch** is hw's: a pencil for a worktree checked out to
  review someone's PR, a pull-request glyph for a branch that has one of its
  own, coloured green when it is ready to merge, red when checks fail, yellow
  when it needs approval, grey when it is a draft.

Turn it on with:

```toml
[ui.sidebar]
projects = true
projects_status_token = "$hw_status"
```

Herdr drops metadata tokens when the server restarts, so run `hw sync` after
one to put the review and PR marks back. `hw watch` keeps them current.

## Slow work runs in the background

herdr allows one popup at a time, so a `git worktree remove` or a repo setup
hook held inside the popup that asked for it blocks every other hw command
until it finishes. Setting a worktree up and tearing one down are detached
jobs instead, and the space reports what it is doing while they run:

```
cs-ops
  eli/oncall-calendar-view
       ⠼ tearing down
```

A plain `&` is not enough: closing a pane makes herdr signal that pane's whole
session, so a backgrounded job dies with the popup that started it. `detach`
re-execs through `setsid` so the job lands in a session of its own. Job output
goes to `$HW_JOBLOG` (`~/.cache/hw/jobs.log`), which is the only record of a
setup hook that failed.

The row clears however the job ends, including a crash, so it cannot spin
forever with nothing behind it.

## Resuming

A worktree outlives the herdr workspace that opened it, so spawning the same
ticket or branch again never fails — it resumes. Four states, handled:

| On disk | In herdr | What happens |
|---|---|---|
| checkout | workspace open | focuses that workspace |
| checkout | no workspace | `worktree open` adopts it, new session, setup hooks **skipped** |
| gone (git still lists it) | — | `git worktree prune`, then a clean create |
| nothing | — | normal create |

If things get closed in an odd order, `create_worktree` classifies the path
before acting rather than assuming:

| State | Meaning | What happens |
|---|---|---|
| `ready` | registered with git and usable | reopened |
| `orphan` | files there, git metadata gone | `git worktree repair` first; if that fails, quarantined and recreated |
| `foreign` | path exists, not a checkout | empty dir is removed; otherwise refuses with a clear message |
| `stale` | git lists it, directory gone | pruned, then recreated |
| `absent` | nothing there | normal create |

A workspace pointing at anything but `ready` is closed as stale rather than
focused. If the branch is already checked out in a *different* worktree, that
one is opened instead of failing.

**Nothing is ever deleted outright.** Anything hw discards is moved to
`$HW_ROOT/.hw-trash/<timestamp>-<name>`, so a wrong guess is recoverable.

## Closing one session

A project's canonical checkout and each of its worktrees are separate herdr
workspaces that all share one `repo_root`, so herdr's `remove_worktree` treats
them as a group. `hw close` (`prefix d`) acts on the current workspace alone
and asks what to do with its worktree:

- **keep** — close the session, leave the worktree so you can reopen it later
- **remove** — close the session and remove the worktree
- **cancel**

herdr's own `close_workspace` and `remove_worktree` are set to `""`, so every
close goes through this prompt rather than silently leaving orphaned worktrees
behind. Both `prefix d` and `prefix shift+d` run it.

It reports uncommitted and unpushed counts in the prompt and asks a second time
before removing anything that has either. The project's main checkout is never
offered for removal: every linked worktree depends on its `.git`.

## hw doctor

```
hw doctor        # report
hw doctor --fix  # repair
```

Scans every project for orphan checkouts, stale git registrations, workspaces
pointing at missing checkouts, and branches with no upstream (which silently
break `gh` and the review panel).

Setup hooks are a create-time concern, so a resumed checkout does not re-run
`.herdr/setup.sh` or re-copy env files — your uncommitted work and local state
are left alone. An agent is only started if one is not already live in that
workspace, so re-spawning never stacks two Claudes in one worktree.

## Per-repo setup hooks (Orca's `--setup run`)

Two things run when `hw` creates a worktree:

1. Gitignored `.env*` files are copied from the canonical checkout.
2. `.herdr/setup.sh` at the repo root runs inside the new worktree, if executable.
   `$HW_WORKTREE` and `$HW_MAIN` are set.

```sh
#!/bin/sh
# <repo>/.herdr/setup.sh
bun install
```

## Sidebar CI/PR state

`hw watch` polls open worktree workspaces and reports `$ci` / `$pr` tokens that
`[ui.sidebar.spaces]` renders. Run it once per herdr session:

```sh
hw watch &
```

## Linear token

```sh
security add-generic-password -s hw-linear -a "$USER" -w
```

Paste a personal API key from <https://linear.app/settings/api>.
`hw linear` lists your assigned, not-done issues and uses Linear's own
`branchName` for the worktree branch.
