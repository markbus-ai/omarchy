// Parsing, label math, and the focus-churn cache for the git-pulse widget,
// kept Qt-free so it can be unit tested under node
// (test/shell.d/git-pulse-test.sh).

// nf-oct-git_branch, the branch glyph the bar renders (JetBrainsMono Nerd
// Font). Written as an escape to keep editing tools from touching the glyph.
var GIT_GLYPH = "\uf418"

function emptyState() {
  return {
    isRepo: false,
    topLevel: "",
    branch: "",
    detached: false,
    sha: "",
    ahead: 0,
    behind: 0,
    staged: 0,
    modified: 0,
    untracked: 0,
    conflict: 0
  }
}

// Consumes the four-line output of omarchy-git-status into a display state:
//   line 1: repo top-level path, empty when not in a repo
//   line 2: branch name, or "detached <short sha>"
//   line 3: ahead <n> behind <m>
//   line 4: staged <n> modified <n> untracked <n> conflict <n>
function parseStatus(text) {
  var lines = String(text == null ? "" : text).split("\n")
  var top = String(lines[0] || "").trim()

  if (top === "") return emptyState()

  var branchInfo = parseBranch(lines[1] || "")
  var position = parsePosition(lines[2] || "")
  var counts = parseCounts(lines[3] || "")

  return {
    isRepo: true,
    topLevel: top,
    branch: branchInfo.branch,
    detached: branchInfo.detached,
    sha: branchInfo.sha,
    ahead: position.ahead,
    behind: position.behind,
    staged: counts.staged,
    modified: counts.modified,
    untracked: counts.untracked,
    conflict: counts.conflict
  }
}

function parseBranch(line) {
  line = String(line || "").trim()
  if (line.indexOf("detached ") === 0)
    return { branch: "", detached: true, sha: line.slice("detached ".length) }
  return { branch: line, detached: false, sha: "" }
}

function parsePosition(text) {
  var aheadMatch = /ahead (\d+)/.exec(String(text))
  var behindMatch = /behind (\d+)/.exec(String(text))
  return {
    ahead: aheadMatch ? parseInt(aheadMatch[1], 10) : 0,
    behind: behindMatch ? parseInt(behindMatch[1], 10) : 0
  }
}

function parseCounts(text) {
  text = String(text)
  var value = function(name) {
    var match = new RegExp(name + " (\\d+)").exec(text)
    return match ? parseInt(match[1], 10) : 0
  }
  return {
    staged: value("staged"),
    modified: value("modified"),
    untracked: value("untracked"),
    conflict: value("conflict")
  }
}

function branchLabel(state) {
  if (!state || !state.isRepo) return ""
  if (state.detached) return state.sha ? "detached " + state.sha : "detached"
  return state.branch || ""
}

// Compact bar pill, e.g. "<glyph> main +2 ~1". Conflicts fold into the
// staged count (they are staged by definition); untracked and the
// ahead/behind arrows only appear when the user opts in, keeping the pill
// slim for the common clean-ish state.
function labelText(state, showUntracked, showAheadBehind) {
  if (!state || !state.isRepo) return ""

  var parts = [GIT_GLYPH + " " + branchLabel(state)]

  if (showAheadBehind && (state.ahead > 0 || state.behind > 0)) {
    var arrows = ""
    if (state.ahead > 0) arrows += "\u2191" + state.ahead
    if (state.behind > 0) arrows += "\u2193" + state.behind
    parts.push(arrows)
  }

  var plus = state.staged + state.conflict
  if (plus > 0) parts.push("+" + plus)
  if (state.modified > 0) parts.push("~" + state.modified)
  if (showUntracked && state.untracked > 0) parts.push("?" + state.untracked)

  return parts.join(" ")
}

// One-line popup summary of the counters, skipping zero groups.
function countsSummary(state) {
  if (!state || !state.isRepo) return ""
  var groups = []
  if (state.staged > 0) groups.push("staged " + state.staged)
  if (state.modified > 0) groups.push("modified " + state.modified)
  if (state.untracked > 0) groups.push("untracked " + state.untracked)
  if (state.conflict > 0) groups.push("conflict " + state.conflict)
  return groups.join(" \u00b7 ")
}

// Popup counters as display entries, one per non-zero group. The QML side
// maps `kind` to a theme color role, keeping color decisions out of JS.
function countEntries(state) {
  if (!state || !state.isRepo) return []
  var entries = []
  if (state.staged > 0) entries.push({ kind: "staged", count: state.staged })
  if (state.modified > 0) entries.push({ kind: "modified", count: state.modified })
  if (state.untracked > 0) entries.push({ kind: "untracked", count: state.untracked })
  if (state.conflict > 0) entries.push({ kind: "conflict", count: state.conflict })
  return entries
}

// What the "copy" action puts on the clipboard: the branch name, or the
// detached short sha.
function copyValue(state) {
  if (!state || !state.isRepo) return ""
  if (state.detached) return state.sha || ""
  return state.branch || ""
}

// Normalize a git remote URL to a browsable https://github.com/org/repo URL,
// or "" when the remote is not GitHub (gitlab, bitbucket, a local path, ...).
function githubUrlFromRemote(remote) {
  remote = String(remote == null ? "" : remote).trim()
  if (remote === "") return ""

  var match = /^(?:git@github\.com:|https?:\/\/github\.com\/)([^/]+\/[^/\s]+?)(?:\.git)?\/?$/.exec(remote)
  if (!match) return ""
  return "https://github.com/" + match[1]
}

function tooltipText(state) {
  if (!state || !state.isRepo) return ""
  var text = state.topLevel
  if (state.untracked > 0) text += " (" + state.untracked + " untracked)"
  return text
}

// Focus-churn guard. Cache entries are keyed by the toplevel object itself
// (Quickshell toplevels expose no stable address string to QML), so entries
// are matched by reference and a window that was measured within ttlMs never
// re-runs the git pipeline. Stale entries are pruned on upsert.
function cacheLookup(cache, toplevel, now, ttlMs) {
  var list = cache || []
  for (var i = 0; i < list.length; i++) {
    if (list[i].toplevel === toplevel && now - list[i].timestamp < ttlMs)
      return list[i]
  }
  return null
}

function cacheUpsert(cache, toplevel, statusText, now, maxAgeMs) {
  var list = cache || []
  var pruned = []
  var oldest = now - (maxAgeMs == null ? 20000 : maxAgeMs)

  for (var i = 0; i < list.length; i++) {
    if (list[i].toplevel === toplevel) continue
    if (list[i].timestamp < oldest) continue
    pruned.push(list[i])
  }

  pruned.push({
    toplevel: toplevel,
    statusText: String(statusText),
    timestamp: now
  })

  return pruned
}

if (typeof module !== "undefined") {
  module.exports = {
    GIT_GLYPH: GIT_GLYPH,
    emptyState: emptyState,
    parseStatus: parseStatus,
    parseBranch: parseBranch,
    parsePosition: parsePosition,
    parseCounts: parseCounts,
    branchLabel: branchLabel,
    labelText: labelText,
    countsSummary: countsSummary,
    countEntries: countEntries,
    copyValue: copyValue,
    githubUrlFromRemote: githubUrlFromRemote,
    tooltipText: tooltipText,
    cacheLookup: cacheLookup,
    cacheUpsert: cacheUpsert
  }
}