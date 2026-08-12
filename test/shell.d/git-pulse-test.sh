#!/bin/bash

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

require_command git
require_command node
require_command tmux
require_command script

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME="GitPulse tests"
export GIT_AUTHOR_EMAIL="gitpulse@tests.invalid"
export GIT_COMMITTER_NAME="GitPulse tests"
export GIT_COMMITTER_EMAIL="gitpulse@tests.invalid"

TMP=$(mktemp -d)
cleanup() {
  rm -rf "$TMP"
  # safety net for tmux sockets created outside TMP
  rm -rf /tmp/tmux-$(id -u)/gitpulse-* /tmp/tmux-$(id -u)/gpalt-*
}
trap cleanup EXIT

assert_eq() { # description expected actual
  local detail="expected: $2
actual:   $3"
  [[ $3 == "$2" ]] || fail "$1" "$detail"
  pass "$1"
}

###############################################################################
# omarchy-git-status
###############################################################################

CLEAN="$TMP/clean"
git init -q -b main "$CLEAN"
git init -q --bare "$TMP/remote.git"
printf 'base\n' >"$CLEAN/file.txt"
git -C "$CLEAN" add file.txt
git -C "$CLEAN" commit -qm init
git -C "$CLEAN" remote add origin "$TMP/remote.git"
git -C "$CLEAN" push -qu origin main >/dev/null
printf 'more\n' >>"$CLEAN/file.txt"
git -C "$CLEAN" commit -qam second

out=$(bin/omarchy-git-status "$CLEAN")
assert_eq "omarchy-git-status clean repo, ahead of upstream" \
  "$(printf '%s\n' "$CLEAN" 'main' 'ahead 1 behind 0' 'staged 0 modified 0 untracked 0 conflict 0')" \
  "$out"

DIRTY="$TMP/dirty"
git init -q -b main "$DIRTY"
printf 'one\n' >"$DIRTY/a.txt"
git -C "$DIRTY" add .
git -C "$DIRTY" commit -qm init
printf 'two\n' >>"$DIRTY/a.txt"
printf 'new\n' >"$DIRTY/b.txt"
printf 'x\n' >"$DIRTY/staged.txt"
git -C "$DIRTY" add staged.txt

out=$(bin/omarchy-git-status "$DIRTY")
assert_eq "omarchy-git-status staged, modified and untracked files" \
  "$(printf '%s\n' "$DIRTY" 'main' 'ahead 0 behind 0' 'staged 1 modified 1 untracked 1 conflict 0')" \
  "$out"

CONFLICT="$TMP/conflict"
git init -q -b main "$CONFLICT"
printf 'base\n' >"$CONFLICT/f.txt"
git -C "$CONFLICT" add .
git -C "$CONFLICT" commit -qm base
git -C "$CONFLICT" checkout -qb side
printf 'side\n' >"$CONFLICT/f.txt"
git -C "$CONFLICT" commit -qam side
git -C "$CONFLICT" checkout -q main
printf 'main\n' >"$CONFLICT/f.txt"
git -C "$CONFLICT" commit -qam main
git -C "$CONFLICT" merge side >/dev/null 2>&1 || true

out=$(bin/omarchy-git-status "$CONFLICT")
assert_eq "omarchy-git-status merge conflict counted as conflict" \
  "$(printf '%s\n' "$CONFLICT" 'main' 'ahead 0 behind 0' 'staged 0 modified 0 untracked 0 conflict 1')" \
  "$out"

DETACHED="$TMP/detached"
git init -q -b main "$DETACHED"
printf 'x\n' >"$DETACHED/x.txt"
git -C "$DETACHED" add .
git -C "$DETACHED" commit -qm one
git -C "$DETACHED" checkout -q --detach
sha=$(git -C "$DETACHED" rev-parse --short HEAD)

out=$(bin/omarchy-git-status "$DETACHED")
assert_eq "omarchy-git-status detached head reports short sha" \
  "$(printf '%s\n' "$DETACHED" "detached $sha" 'ahead 0 behind 0' 'staged 0 modified 0 untracked 0 conflict 0')" \
  "$out"

EMPTY="$TMP/empty"
git init -q -b main "$EMPTY"

out=$(bin/omarchy-git-status "$EMPTY")
assert_eq "omarchy-git-status unborn head does not crash" \
  "$(printf '%s\n' "$EMPTY" 'main' 'ahead 0 behind 0' 'staged 0 modified 0 untracked 0 conflict 0')" \
  "$out"

PLAIN="$TMP/plain"
mkdir -p "$PLAIN"
printf 'not a repo\n' >"$PLAIN/note.txt"

out=$(bin/omarchy-git-status "$PLAIN")
assert_eq "omarchy-git-status non-repo yields empty first line" "" "$out"

out=$(bin/omarchy-git-status "$TMP/does-not-exist")
assert_eq "omarchy-git-status nonexistent cwd yields empty first line" "" "$out"

###############################################################################
# tmux pane cwd resolution (bin/omarchy-cmd-terminal-cwd)
###############################################################################

source bin/omarchy-cmd-terminal-cwd

wait_for_client() { # socket -> prints client pid, empty on timeout
  local socket="$1" pid=""
  for _ in $(seq 1 50); do
    pid=$(tmux -S "$socket" list-clients -F '#{client_pid}' 2>/dev/null | head -n1) || true
    [[ -n $pid ]] && { printf '%s\n' "$pid"; return 0; }
    sleep 0.1
  done
  return 1
}

tmux_test() {
  local tname="gitpulse-test-$$"
  tmux -L "$tname" new-session -d -c "$TMP" >/dev/null
  script -qec "tmux -L '$tname' attach" /dev/null >/dev/null 2>&1 &
  local attach_pid=$!
  local socket="/tmp/tmux-$(id -u)/$tname"
  local client_pid cwd

  client_pid=$(wait_for_client "$socket") || fail "tmux client appears for attached session"
  [[ -n $client_pid ]] || fail "tmux client appears for attached session"

  cwd=$(tmux_client_pane_cwd "$client_pid") || fail "tmux pane cwd resolvable from client pid"
  assert_eq "tmux pane cwd resolves to session start dir (socket from client environ)" "$TMP" "$cwd"

  cwd=$(terminal_tmux_pane_cwd "$attach_pid") || fail "tmux pane cwd resolvable via terminal children"
  assert_eq "tmux pane cwd resolvable by walking terminal children" "$TMP" "$cwd"

  if cwd=$(tmux_client_pane_cwd "$$"); then
    fail "unmatched client pid rejected" "expected resolution to fail for pid $$"
  fi
  pass "unmatched client pid rejected"

  tmux -L "$tname" kill-server >/dev/null 2>&1 || true
  kill "$attach_pid" 2>/dev/null || true
  wait "$attach_pid" 2>/dev/null || true
}
tmux_test

tmux_tmpdir_test() {
  local alt="$TMP/tmux-alt" tname="gpalt-$$"
  mkdir -p "$alt"
  env TMUX_TMPDIR="$alt" tmux -L "$tname" new-session -d -c "$TMP" >/dev/null
  env TMUX_TMPDIR="$alt" script -qec "tmux -L '$tname' attach" /dev/null >/dev/null 2>&1 &
  local attach_pid=$!
  local socket="$alt/tmux-$(id -u)/$tname"
  local client_pid cwd

  client_pid=$(wait_for_client "$socket") || fail "tmux client appears with custom TMUX_TMPDIR"
  [[ -n $client_pid ]] || fail "tmux client appears with custom TMUX_TMPDIR"

  cwd=$(tmux_client_pane_cwd "$client_pid") || fail "tmux pane cwd resolvable with custom TMUX_TMPDIR"
  assert_eq "tmux client TMUX_TMPDIR socket directory honored" "$TMP" "$cwd"

  tmux -S "$socket" kill-server >/dev/null 2>&1 || true
  kill "$attach_pid" 2>/dev/null || true
  wait "$attach_pid" 2>/dev/null || true
}
tmux_tmpdir_test

cwd=$(bin/omarchy-cmd-terminal-cwd)
[[ -n $cwd && -d $cwd ]] || fail "omarchy-cmd-terminal-cwd exits with an existing directory"
pass "omarchy-cmd-terminal-cwd smoke test prints an existing directory"

###############################################################################
# GitPulseModel.js (node)
###############################################################################

run_node_test <<'JS'
const m = requireFromRoot('shell/plugins/bar/widgets/GitPulseModel.js')

// --- parseStatus -----------------------------------------------------------
const st = m.parseStatus(
  '/repo/src\nfeature/x\nahead 2 behind 3\nstaged 1 modified 2 untracked 3 conflict 1\n'
)
assertEqual(st.isRepo, true, 'parseStatus marks repo')
assertEqual(st.topLevel, '/repo/src', 'parseStatus parses top-level path')
assertEqual(st.branch, 'feature/x', 'parseStatus parses branch')
assertEqual(st.ahead, 2, 'parseStatus parses ahead')
assertEqual(st.behind, 3, 'parseStatus parses behind')
assertEqual(st.staged, 1, 'parseStatus parses staged')
assertEqual(st.modified, 2, 'parseStatus parses modified')
assertEqual(st.untracked, 3, 'parseStatus parses untracked')
assertEqual(st.conflict, 1, 'parseStatus parses conflict')

const clean = m.parseStatus(
  '/repo\nmain\nahead 0 behind 0\nstaged 0 modified 0 untracked 0 conflict 0\n'
)
assertEqual(clean.isRepo, true, 'parseStatus handles clean repo')

const notRepo = m.parseStatus('')
assertEqual(notRepo.isRepo, false, 'parseStatus empty output means no repo')

// --- labels ----------------------------------------------------------------
assertEqual(m.labelText(clean, false, false), m.GIT_GLYPH + ' main', 'clean label is glyph + branch')
assertEqual(m.labelText(clean, true, true), m.GIT_GLYPH + ' main', 'clean label ignores toggles')
assertEqual(
  m.labelText(st, false, false),
  m.GIT_GLYPH + ' feature/x +2 ~2',
  'conflicts fold into staged count; untracked hidden by default'
)
assertEqual(
  m.labelText(st, true, false),
  m.GIT_GLYPH + ' feature/x +2 ~2 ?3',
  'untracked shown when opted in'
)
assertEqual(
  m.labelText(st, false, true),
  m.GIT_GLYPH + ' feature/x \u21912\u21933 +2 ~2',
  'ahead/behind arrows shown when opted in'
)

const detached = m.parseStatus(
  '/r\ndetached abc1234\nahead 0 behind 0\nstaged 0 modified 0 untracked 0 conflict 0\n'
)
assertEqual(detached.detached, true, 'detached flag parsed')
assertEqual(detached.sha, 'abc1234', 'detached sha parsed')
assertEqual(m.branchLabel(detached), 'detached abc1234', 'detached branch label')
assertEqual(m.labelText(detached, false, false), m.GIT_GLYPH + ' detached abc1234', 'detached pill label')

assertEqual(m.labelText(notRepo, false, false), '', 'no label outside a repo')

// --- popup text ------------------------------------------------------------
assertEqual(m.countsSummary(st), 'staged 1 \u00b7 modified 2 \u00b7 untracked 3 \u00b7 conflict 1', 'countsSummary joins non-zero groups')
assertEqual(m.countsSummary(clean), '', 'countsSummary empty for clean repo')
assertEqual(m.tooltipText(st), '/repo/src (3 untracked)', 'tooltip shows top and untracked count')
assertEqual(m.tooltipText(clean), '/repo', 'tooltip shows top for clean repo')
assertEqual(m.tooltipText(notRepo), '', 'no tooltip outside a repo')

// --- cache -----------------------------------------------------------------
const winA = {}, winB = {}, winC = {}
let cache = m.cacheUpsert([], winA, 'text-a1', 1000)
assertEqual(cache.length, 1, 'cache stores first entry')

cache = m.cacheUpsert(cache, winA, 'text-a2', 2000)
assertEqual(cache.length, 1, 'cache upsert replaces same toplevel by reference')
assertEqual(cache[0].statusText, 'text-a2', 'cache keeps newest text for same toplevel')

cache = m.cacheUpsert(cache, winB, 'text-b', 3000)
assertEqual(cache.length, 2, 'cache keeps distinct toplevels')

assertEqual(m.cacheLookup(cache, winA, 3000, 10000).statusText, 'text-a2', 'cache lookup hits within ttl')
assertEqual(m.cacheLookup(cache, winA, 12000, 10000), null, 'cache lookup misses after ttl')
assertEqual(m.cacheLookup(cache, winB, 14000, 10000), null, 'cache lookup misses per-entry after ttl')

let pruned = m.cacheUpsert([], winA, 'a', 1000)
pruned = m.cacheUpsert(pruned, winB, 'b', 1100, 50)
assertEqual(pruned.length, 1, 'cache upsert prunes stale entries')
assertEqual(pruned[0].toplevel === winB, true, 'cache keeps only the fresh entry')

// --- parse helpers ---------------------------------------------------------
assertEqual(m.parseBranch('main').branch, 'main', 'parseBranch plain branch')
assertEqual(m.parseBranch('detached deadbeef').sha, 'deadbeef', 'parseBranch detached sha')
assertEqual(m.parsePosition('ahead 4 behind 7').ahead, 4, 'parsePosition ahead')
assertEqual(m.parseCounts('staged 5 modified 0 untracked 2 conflict 0').untracked, 2, 'parseCounts untracked')
JS