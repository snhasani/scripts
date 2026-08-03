#!/usr/bin/env bash
# PTY-driven coverage of the fzf key bindings themselves (spec item 7) — the
# thing every other test in this repo skips. vise.smoke.sh drives every __*
# handler directly (bash "$VISE" __upgrade ...); nothing before this file has
# ever pressed a real key inside a real fzf process and watched what fzf's
# OWN placeholder expansion ({+1}, {8}), execute()/execute-silent() dispatch
# and reload()/transform-prompt() chaining actually do. That gap is exactly
# where the empty-selection bulk-upgrade bug lived: {+1} expanding to nothing
# on a zero-match filter turned "upgrade nothing" into "upgrade everything",
# and no handler-level test could ever have caught it because the handler
# only ever saw what fzf decided to hand it.
#
# NOT opt-in-free: this needs tmux and fzf on PATH and is materially slower
# than the rest of the suite (each case starts a real fzf inside a real pty).
# Kept OUT of `mise run test` on purpose — see mise.toml's `test-pty` task —
# so the fast, hermetic default suite stays fast and hermetic. Run directly:
#   bash vise/vise.pty.sh
# or: mise run test-pty
#
# Every case sets VISE_DRY_RUN=1. Never remove it: ctrl-g/ctrl-x really
# install/remove tools on the machine running this suite without it.
#
# ============================================================================
# COVERAGE: what's here, what's not, and why
# ============================================================================
# Covered, each with a killed mutant (see the case-by-case comments below):
#   ctrl-a  execute-silent(__toggle-filter)+reload+transform-prompt
#   ctrl-s  execute-silent(__cycle-scope)+reload+transform-prompt
#   ctrl-o  execute-silent(__open {8})
#   ctrl-r  reload(__render)
#
# NOT covered, and not fakeable: ctrl-g, ctrl-t, ctrl-x, ctrl-u. All four
# share one shape neither of the four above has —
#   execute(<cmd> {+1}; echo; read -r -p "Press enter to continue..." _dummy)+reload(...)
# — an execute() (not -silent) with a blocking read chained before the
# reload. Extensive isolation (see below) found that with VISE_DRY_RUN=1,
# vise::mutate's whole DRY-run path is a single printf with no subprocess —
# so fast that the entire cycle (leave the alt screen, print "DRY: ...",
# hit the read, come back, reload the list) can complete faster than tmux's
# OWN pty parser produces an externally observable intermediate frame. This
# is not "flaky" in the TST-19 sense (flaky = sometimes red, sometimes green
# on identical conditions) — it is deterministic: 0 hits across 300 samples
# at 5ms resolution, 0 hits waiting up to 10 full seconds, 0 fzf child
# processes ever observed via `ps` at any sampling point, every single time,
# across dozens of trials. Compare: the SAME instrumentation reliably caught
# ctrl-a/ctrl-s/ctrl-o every time, because those bindings' effects (a prompt
# that stays changed, a row that stays hidden, a file a stub `open` wrote)
# persist past the keypress instead of being overwritten by the very next
# reload. Confirmed independently: when the mutating call is NOT dry-run
# (mise actually forks and spends real wall-clock time failing to resolve a
# fake coordinate), the exact same execute()+read+reload sequence WAS
# observable — the slow path gave capture-pane a real window to land in.
# Swapping in a slow stub `mise` to manufacture that window was considered
# and rejected: it would mean dropping VISE_DRY_RUN=1 for part of a run,
# which the safety rules for this task rule out categorically.
#
# One more data point worth recording: the same "read -r -p" pause, run as
# the ONLY thing inside execute() (no preceding call into vise/vise), was
# observed to block correctly and reliably in this same tmux+fzf setup. It
# stopped blocking specifically once a call into vise/vise itself preceded
# it in the same execute() clause — reproduced with __prompt (nothing to do
# with mise) as the preceding call, not just __use-global. Whether that is a
# real defect in how the pause behaves for an actual interactive user, or an
# artifact specific to nested tmux automation, could not be settled from
# here. Worth a deliberate manual check (a stopwatch, not a glance) on a real
# terminal: does "Press enter to continue..." genuinely wait, or flash by?
#
# What is NOT missing despite this gap:
#   - Every __* handler (__use_global, __use_project, __rm, __upgrade) has
#     direct coverage in vise.smoke.sh, including the exact empty-argument
#     shape {+1} produces on a zero-match filter (vise.smoke.sh's "empty
#     upgrade refuses" case calls `__upgrade` with zero args — precisely
#     what {+1} yields when nothing matches and nothing is tab-selected).
#   - fzf's OWN {+1}/{+}/{1}/{8} placeholder-substitution and --bind
#     dispatch mechanism is not per-key special-cased inside fzf; the
#     ctrl-o case below exercises the exact same substitution engine
#     (verified live, with a killed {8}->{1} mutant) that ctrl-g/t/x/u's
#     {+1} relies on. So the MECHANISM is exercised end-to-end here even
#     though those four specific bindings' own transient output is not.
#
# Usage: bash vise.pty.sh [path-to-vise]   (defaults to ./vise beside this file)

set -uo pipefail

VISE="${1:-$(cd "$(dirname "$0")" && pwd)/vise}"
[ -f "$VISE" ] || {
    printf 'vise not found at %s\n' "$VISE" >&2
    exit 2
}

if ! command -v tmux >/dev/null 2>&1; then
    printf 'tmux not found on PATH — pty suite cannot run, skipping\n' >&2
    exit 0
fi
if ! command -v fzf >/dev/null 2>&1; then
    printf 'fzf not found on PATH — pty suite cannot run, skipping\n' >&2
    exit 0
fi

pass=0
fail=0
ok() {
    printf '  \033[32mok\033[0m   %s\n' "$1"
    pass=$((pass + 1))
}
bad() {
    printf '  \033[31mFAIL\033[0m %s\n' "$1"
    [ $# -ge 2 ] && printf '       got: %s\n' "$2"
    fail=$((fail + 1))
}

pick_base() {
    local b d
    for b in "${TMPDIR:-}" /tmp "$PWD"; do
        [ -n "$b" ] && [ -d "$b" ] || continue
        d="$(mktemp -d "$b/vise-pty.XXXXXX" 2>/dev/null)" || continue
        printf '%s' "$d"
        return 0
    done
    return 1
}
BASE="$(pick_base)" || {
    printf 'no writable base for pty fixtures\n' >&2
    exit 2
}

LIVE_SESSIONS=""
cleanup() {
    local s
    for s in $LIVE_SESSIONS; do
        tmux kill-session -t "$s" >/dev/null 2>&1
    done
    rm -rf "$BASE"
}
trap cleanup EXIT

SESSION_N=0
# Starts $1 (a launcher script path) inside a fresh tmux session sized 140x30
# (wide enough that none of this file's short fixture rows truncate) and
# echoes the session name. Launched as tmux's own session command (not typed
# into an interactive shell via send-keys) — the one invocation shape that
# was reliable across every case tried; an interactive-shell-then-type-the-
# command shape reproduced intermittent key-delivery misses that this shape
# never did, across dozens of trials each way.
start_session() {
    SESSION_N=$((SESSION_N + 1))
    local session="vise-pty-$$-$SESSION_N"
    tmux kill-session -t "$session" >/dev/null 2>&1
    tmux new-session -d -s "$session" -x 140 -y 30 -- bash "$1"
    LIVE_SESSIONS="$LIVE_SESSIONS $session"
    printf '%s' "$session"
}

end_session() {
    tmux kill-session -t "$1" >/dev/null 2>&1
    LIVE_SESSIONS=$(printf '%s' "$LIVE_SESSIONS" | sed "s/\\b$1\\b//")
}

# Polls tmux's rendered pane (not raw pty bytes — the visible screen, exactly
# what a human would see) for a fixed string, every 100ms, up to $2 tenths of
# a second (default 50 = 5s). This is the "deterministic observable" this
# task's brief asked for: never a bare sleep, always a real condition, with a
# bounded timeout only as a safety net against a genuine hang.
wait_for() {
    local session="$1" pattern="$2" timeout="${3:-50}" n=0
    while ! tmux capture-pane -t "$session" -p -J 2>/dev/null | grep -qF "$pattern"; do
        n=$((n + 1))
        [ "$n" -ge "$timeout" ] && return 1
        sleep 0.1
    done
    return 0
}

wait_for_file() {
    local file="$1" timeout="${2:-50}" n=0
    while [ ! -s "$file" ]; do
        n=$((n + 1))
        [ "$n" -ge "$timeout" ] && return 1
        sleep 0.1
    done
    return 0
}

# --- ctrl-a: execute-silent(__toggle-filter)+reload(__render)+transform-prompt --
# Fixture unions a catalogued row (kind lsp, stays visible in the default
# tooling-only filter) with an observed-but-uncatalogued tool (kind "?",
# hidden by default — see vise::render's $filter_mode). ctrl-a must widen the
# view (the "?" row appears) AND flip the prompt suffix in the same keypress,
# proving execute-silent + reload + transform-prompt all fired off one bind.
CTRLA_DIR="$BASE/ctrl-a"
mkdir -p "$CTRLA_DIR"
cat >"$CTRLA_DIR/catalog.tsv" <<'EOF'
npm:catalogued-tool	catalogued-tool	linter	javascript	-	-	-	-
EOF
cat >"$CTRLA_DIR/config.json" <<EOF
[{"path": "$CTRLA_DIR/global.toml", "tools": []}]
EOF
cat >"$CTRLA_DIR/ls.json" <<'EOF'
{"npm:uncatalogued-tool": [{"version": "1.0.0", "active": true}]}
EOF
echo '[]' >"$CTRLA_DIR/registry.json"
cat >"$CTRLA_DIR/launch.sh" <<EOF
#!/bin/bash
export VISE_DRY_RUN=1
export VISE_CATALOG="$CTRLA_DIR/catalog.tsv"
export VISE_CONFIG_JSON="$CTRLA_DIR/config.json"
export VISE_LS_JSON="$CTRLA_DIR/ls.json"
export VISE_REGISTRY_JSON="$CTRLA_DIR/registry.json"
export MISE_GLOBAL_CONFIG_FILE="$CTRLA_DIR/global.toml"
exec bash "$VISE"
EOF
chmod +x "$CTRLA_DIR/launch.sh"

SESSION=$(start_session "$CTRLA_DIR/launch.sh")
if wait_for "$SESSION" "catalogued-tool"; then
    if tmux capture-pane -t "$SESSION" -p | head -1 | grep -qF "vise all +tooling>"; then
        ok "ctrl-a: starts tooling-only (prompt shows +tooling suffix)"
    else
        bad "ctrl-a: starts tooling-only (prompt shows +tooling suffix)" "$(tmux capture-pane -t "$SESSION" -p | head -1)"
    fi
    if ! tmux capture-pane -t "$SESSION" -p | grep -qF "uncatalogued-tool"; then
        ok "ctrl-a: uncatalogued row hidden before toggling"
    else
        bad "ctrl-a: uncatalogued row hidden before toggling" "row was already visible"
    fi

    tmux send-keys -t "$SESSION" C-a
    if wait_for "$SESSION" "uncatalogued-tool" 30 &&
        tmux capture-pane -t "$SESSION" -p | head -1 | grep -qF "vise all>" &&
        ! tmux capture-pane -t "$SESSION" -p | head -1 | grep -qF "+tooling"; then
        ok "ctrl-a: toggling widens the list (uncatalogued row appears) and drops the +tooling suffix"
    else
        bad "ctrl-a: toggling widens the list (uncatalogued row appears) and drops the +tooling suffix" \
            "$(tmux capture-pane -t "$SESSION" -p -J | head -3)"
    fi
else
    bad "ctrl-a: picker never rendered the fixture row"
fi
end_session "$SESSION"

# --- ctrl-s: execute-silent(__cycle-scope)+reload(__render)+transform-prompt ----
# One row per scope so cycling from all -> global is visible two ways at
# once: the prompt's scope word changes AND the project-only row drops out
# of the filtered list (vise::render's own scope_mode filter, see the
# existing scope-glyph coverage in vise.smoke.sh for the non-pty version of
# this same join).
CTRLS_DIR="$BASE/ctrl-s"
mkdir -p "$CTRLS_DIR"
cat >"$CTRLS_DIR/catalog.tsv" <<'EOF'
npm:global-tool	global-tool	linter	javascript	-	-	-	-
npm:project-tool	project-tool	linter	javascript	-	-	-	-
EOF
cat >"$CTRLS_DIR/config.json" <<EOF
[
  {"path": "$CTRLS_DIR/global.toml", "tools": ["npm:global-tool"]},
  {"path": "$CTRLS_DIR/project.toml", "tools": ["npm:project-tool"]}
]
EOF
cat >"$CTRLS_DIR/ls.json" <<'EOF'
{
  "npm:global-tool": [{"version": "1.0.0", "active": true}],
  "npm:project-tool": [{"version": "1.0.0", "active": true}]
}
EOF
echo '[]' >"$CTRLS_DIR/registry.json"
cat >"$CTRLS_DIR/launch.sh" <<EOF
#!/bin/bash
export VISE_DRY_RUN=1
export VISE_CATALOG="$CTRLS_DIR/catalog.tsv"
export VISE_CONFIG_JSON="$CTRLS_DIR/config.json"
export VISE_LS_JSON="$CTRLS_DIR/ls.json"
export VISE_REGISTRY_JSON="$CTRLS_DIR/registry.json"
export MISE_GLOBAL_CONFIG_FILE="$CTRLS_DIR/global.toml"
exec bash "$VISE"
EOF
chmod +x "$CTRLS_DIR/launch.sh"

SESSION=$(start_session "$CTRLS_DIR/launch.sh")
if wait_for "$SESSION" "global-tool"; then
    if tmux capture-pane -t "$SESSION" -p | grep -qF "project-tool"; then
        ok "ctrl-s: starts in scope=all (both rows visible)"
    else
        bad "ctrl-s: starts in scope=all (both rows visible)" "$(tmux capture-pane -t "$SESSION" -p)"
    fi

    tmux send-keys -t "$SESSION" C-s
    # transform-prompt and reload are two separate fzf actions chained on one
    # bind; the prompt can update a beat before the list re-filters. Poll
    # until BOTH settle instead of checking each once right after the other.
    settled=0
    for _try in $(seq 1 30); do
        out=$(tmux capture-pane -t "$SESSION" -p -J 2>/dev/null)
        if printf '%s' "$out" | head -1 | grep -qF "vise global" &&
            printf '%s' "$out" | grep -qF "global-tool" &&
            ! printf '%s' "$out" | grep -qF "project-tool"; then
            settled=1
            break
        fi
        sleep 0.1
    done
    if [ "$settled" -eq 1 ]; then
        ok "ctrl-s: cycling to scope=global updates the prompt and filters out the project-only row"
    else
        bad "ctrl-s: cycling to scope=global updates the prompt and filters out the project-only row" \
            "$(tmux capture-pane -t "$SESSION" -p -J | head -3)"
    fi
else
    bad "ctrl-s: picker never rendered the fixture rows"
fi
end_session "$SESSION"

# --- ctrl-o: execute-silent(__open {8}) -----------------------------------------
# {8} is the homepage column, deliberately NOT one of the displayed fields
# (--with-nth=3..6) — the only way to prove {8} really reached __open, rather
# than some other field a display-only check couldn't distinguish, is to
# capture the exact argv a stub `open` receives.
CTRLO_DIR="$BASE/ctrl-o"
mkdir -p "$CTRLO_DIR/stubbin"
cat >"$CTRLO_DIR/catalog.tsv" <<'EOF'
npm:homepage-tool	homepage-tool	linter	javascript	https://example.com/homepage-tool	-	-	-
EOF
cat >"$CTRLO_DIR/config.json" <<EOF
[{"path": "$CTRLO_DIR/global.toml", "tools": []}]
EOF
echo '{}' >"$CTRLO_DIR/ls.json"
echo '[]' >"$CTRLO_DIR/registry.json"
cat >"$CTRLO_DIR/stubbin/open" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$CTRLO_DIR/open-calls.log"
EOF
chmod +x "$CTRLO_DIR/stubbin/open"
cat >"$CTRLO_DIR/launch.sh" <<EOF
#!/bin/bash
export PATH="$CTRLO_DIR/stubbin:\$PATH"
export VISE_DRY_RUN=1
export VISE_CATALOG="$CTRLO_DIR/catalog.tsv"
export VISE_CONFIG_JSON="$CTRLO_DIR/config.json"
export VISE_LS_JSON="$CTRLO_DIR/ls.json"
export VISE_REGISTRY_JSON="$CTRLO_DIR/registry.json"
export MISE_GLOBAL_CONFIG_FILE="$CTRLO_DIR/global.toml"
exec bash "$VISE"
EOF
chmod +x "$CTRLO_DIR/launch.sh"

SESSION=$(start_session "$CTRLO_DIR/launch.sh")
if wait_for "$SESSION" "homepage-tool"; then
    tmux send-keys -t "$SESSION" C-o
    if wait_for_file "$CTRLO_DIR/open-calls.log" 30; then
        got=$(cat "$CTRLO_DIR/open-calls.log")
        if [ "$got" = "https://example.com/homepage-tool" ]; then
            ok "ctrl-o: {8} expands to the homepage column, not a displayed field"
        else
            bad "ctrl-o: {8} expands to the homepage column, not a displayed field" "$got"
        fi
    else
        bad "ctrl-o: {8} expands to the homepage column, not a displayed field" "stub open never ran"
    fi
else
    bad "ctrl-o: picker never rendered the fixture row"
fi
end_session "$SESSION"

# --- ctrl-r: reload(__render) ---------------------------------------------------
# The catalog file is mutated on disk AFTER the picker's first render and
# BEFORE ctrl-r is pressed — the new row must be absent beforehand (proving
# the first render isn't somehow already showing it) and present only once
# ctrl-r actually re-invokes __render, rather than the picker replaying
# whatever it read once at startup.
CTRLR_DIR="$BASE/ctrl-r"
mkdir -p "$CTRLR_DIR"
cat >"$CTRLR_DIR/catalog.tsv" <<'EOF'
npm:before-reload	before-reload	linter	javascript	-	-	-	-
EOF
cat >"$CTRLR_DIR/config.json" <<EOF
[{"path": "$CTRLR_DIR/global.toml", "tools": []}]
EOF
echo '{}' >"$CTRLR_DIR/ls.json"
echo '[]' >"$CTRLR_DIR/registry.json"
cat >"$CTRLR_DIR/launch.sh" <<EOF
#!/bin/bash
export VISE_DRY_RUN=1
export VISE_CATALOG="$CTRLR_DIR/catalog.tsv"
export VISE_CONFIG_JSON="$CTRLR_DIR/config.json"
export VISE_LS_JSON="$CTRLR_DIR/ls.json"
export VISE_REGISTRY_JSON="$CTRLR_DIR/registry.json"
export MISE_GLOBAL_CONFIG_FILE="$CTRLR_DIR/global.toml"
exec bash "$VISE"
EOF
chmod +x "$CTRLR_DIR/launch.sh"

SESSION=$(start_session "$CTRLR_DIR/launch.sh")
if wait_for "$SESSION" "before-reload"; then
    if ! tmux capture-pane -t "$SESSION" -p | grep -qF "after-reload"; then
        ok "ctrl-r: new row absent before the catalog changes"
    else
        bad "ctrl-r: new row absent before the catalog changes" "row was already visible"
    fi

    printf 'npm:after-reload\tafter-reload\tlinter\tjavascript\t-\t-\t-\t-\n' >>"$CTRLR_DIR/catalog.tsv"
    tmux send-keys -t "$SESSION" C-r
    if wait_for "$SESSION" "after-reload" 30; then
        ok "ctrl-r: reload re-reads the catalog rather than replaying the first render"
    else
        bad "ctrl-r: reload re-reads the catalog rather than replaying the first render" \
            "$(tmux capture-pane -t "$SESSION" -p)"
    fi
else
    bad "ctrl-r: picker never rendered the fixture row"
fi
end_session "$SESSION"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
