#!/usr/bin/env bash
# Smoke test for macos-appearance-watcher. Exercises mode resolution and the
# atomic state-file write in a throwaway XDG_STATE_HOME, plus --check against
# the real machine. Deliberately does NOT run the tmux-mutating path for real -
# that would flip the developer's actual running tmux sessions as a side effect
# of "just testing." See the README's ## Test section for that, run by hand.
#
# Usage: bash macos-appearance-watcher.smoke.sh [path-to-script]
#        (defaults to ./macos-appearance-watcher beside this file)

set -uo pipefail

WATCHER="${1:-$(cd "$(dirname "$0")" && pwd)/macos-appearance-watcher}"
[ -f "$WATCHER" ] || {
	printf 'macos-appearance-watcher not found at %s\n' "$WATCHER" >&2
	exit 2
}

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

base="${TMPDIR:-/tmp}/macos-appearance-watcher-smoke.$$"
mkdir -p "$base" || {
	printf 'cannot create throwaway dir %s\n' "$base" >&2
	exit 2
}
trap 'rm -rf "$base"' EXIT

printf 'smoke: %s\n' "$WATCHER"

# Isolate the state file from the real ~/.local/state/appearance - the tmux
# push is skipped whenever `tmux list-sessions` fails, which it will here since
# TMUX_BIN still resolves to the real binary but there's no reason to assume
# (or require) a session exists in this environment.
run() { XDG_STATE_HOME="$base/state" "$WATCHER" "$@"; }

# 1. "light" resolves to Light and writes the state file
run light >/dev/null
got=$(cat "$base/state/appearance/mode" 2>/dev/null)
[ "$got" = "Light" ] && ok "light -> Light" || bad "light -> Light" "$got"

# 2. "dark" resolves to Dark
run dark >/dev/null
got=$(cat "$base/state/appearance/mode" 2>/dev/null)
[ "$got" = "Dark" ] && ok "dark -> Dark" || bad "dark -> Dark" "$got"

# 3. anything else defaults to Dark (only "light" flips it)
run bogus >/dev/null
got=$(cat "$base/state/appearance/mode" 2>/dev/null)
[ "$got" = "Dark" ] && ok "unrecognized mode defaults to Dark" || bad "unrecognized mode defaults to Dark" "$got"

# 4. no leftover .tmp file after a run (atomic write via rename)
if [ -e "$base/state/appearance/mode.tmp" ]; then
	bad "no leftover mode.tmp after write" "still present"
else
	ok "no leftover mode.tmp after write"
fi

# 5. --check exits 0 and reports both dependencies when they're actually installed
out=$("$WATCHER" --check)
rc=$?
case "$out" in
*"OK      dark-notify"* | *"MISSING dark-notify"*) : ;;
*) bad "--check reports dark-notify status" "$out" ;;
esac
if [ $rc -eq 0 ]; then
	ok "--check exits 0 (dark-notify + tmux both found)"
else
	printf '  \033[33mskip\033[0m --check exited %d - a dependency is missing on this machine\n' "$rc"
	printf '%s\n' "$out" | sed 's/^/       /'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
