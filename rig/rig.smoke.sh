#!/usr/bin/env bash
# Smoke test for rig. Drives the real tool HEADLESSLY (--yes + non-TTY stdin) in
# throwaway git repos under a sandbox-writable base. Asserts EXTERNAL behavior
# only — files, the marker-wrapped config block, git check-ignore, exit codes —
# never script internals.
#
# Usage: bash rig.smoke.sh [path-to-rig]   (defaults to ./rig beside this file)

set -uo pipefail

RIG="${1:-$(cd "$(dirname "$0")" && pwd)/rig}"
[ -f "$RIG" ] || {
	printf 'rig not found at %s\n' "$RIG" >&2
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

# Probe a sandbox-writable base for throwaway repos. /tmp may be denied; the
# $PWD fallback covers a working tree with no usable temp. A base that resolves
# INSIDE a git repo is rejected — a partially-failed nested `git init` there
# would let rig ascend to the parent repo and edit it. So the chosen base is
# always outside any repo, which also makes the refuse-outside-a-repo case real.
pick_base() {
	local b d
	for b in "${TMPDIR:-}" /tmp "$PWD"; do
		[ -n "$b" ] && [ -d "$b" ] || continue
		d="$(mktemp -d "$b/rig-smoke.XXXXXX" 2>/dev/null)" || continue
		if git -C "$d" rev-parse --show-toplevel >/dev/null 2>&1; then
			rmdir "$d" 2>/dev/null
			continue
		fi
		printf '%s' "$d"
		return 0
	done
	return 1
}

BASE="$(pick_base)" || {
	printf 'no writable base for throwaway repos\n' >&2
	exit 2
}
trap 'rm -rf "$BASE"' EXIT

# A fresh, empty git repo under BASE; prints its path.
fresh_repo() {
	local r
	r="$(mktemp -d "$BASE/repo.XXXXXX")"
	git -C "$r" init -q
	printf '%s' "$r"
}

# Count exact occurrences of a fixed string across a file (0 if absent).
count() { grep -cF "$2" "$1" 2>/dev/null || printf '0'; }

printf 'smoke: %s\n' "$RIG"
printf 'base:  %s\n' "$BASE"

OPEN='<!-- rig:config -->'
CLOSE='<!-- /rig:config -->'

# --- fresh repo, one headless run --------------------------------------------
repo="$(fresh_repo)"
(cd "$repo" && bash "$RIG" --yes </dev/null >/dev/null 2>&1)

if [ -f "$repo/AGENTS.md" ] && [ ! -L "$repo/AGENTS.md" ]; then
	ok "fresh repo: creates a real AGENTS.md"
else
	bad "fresh repo: creates a real AGENTS.md"
fi

if [ -L "$repo/CLAUDE.md" ] && [ "$(readlink "$repo/CLAUDE.md")" = "AGENTS.md" ]; then
	ok "fresh repo: CLAUDE.md is a symlink to AGENTS.md"
else
	bad "fresh repo: CLAUDE.md is a symlink to AGENTS.md" "$(ls -l "$repo/CLAUDE.md" 2>&1)"
fi

o="$(count "$repo/AGENTS.md" "$OPEN")"
c="$(count "$repo/AGENTS.md" "$CLOSE")"
if [ "$o" = "1" ] && [ "$c" = "1" ]; then
	ok "config block present, exactly one open + one close marker"
else
	bad "config block present, exactly one open + one close marker" "open=$o close=$c"
fi

if [ -d "$repo/.tmp" ]; then
	ok "provisions scratch root .tmp/"
else
	bad "provisions scratch root .tmp/"
fi

if (cd "$repo" && git check-ignore -q .tmp); then
	ok "git check-ignore reports .tmp ignored"
else
	bad "git check-ignore reports .tmp ignored"
fi

# --- idempotency: a second run changes nothing -------------------------------
before="$(mktemp "$BASE/before.XXXXXX")"
cp "$repo/AGENTS.md" "$before"
(cd "$repo" && bash "$RIG" --yes </dev/null >/dev/null 2>&1)

if cmp -s "$before" "$repo/AGENTS.md"; then
	ok "second run leaves AGENTS.md byte-identical"
else
	bad "second run leaves AGENTS.md byte-identical" "$(diff "$before" "$repo/AGENTS.md" 2>&1 | head -5)"
fi

o="$(count "$repo/AGENTS.md" "$OPEN")"
if [ "$o" = "1" ]; then
	ok "second run keeps the marker count at 1 (no duplicate block)"
else
	bad "second run keeps the marker count at 1 (no duplicate block)" "open=$o"
fi

# --- safety: refuses outside a git repo --------------------------------------
# GIT_CEILING_DIRECTORIES=BASE stops git ascending into any repo containing BASE,
# so the assertion holds even when the fallback base sits inside one.
nogit="$(mktemp -d "$BASE/nogit.XXXXXX")"
if (cd "$nogit" && GIT_CEILING_DIRECTORIES="$BASE" bash "$RIG" --yes </dev/null >/dev/null 2>&1); then
	bad "refuses to run outside a git repo (nonzero exit)"
else
	ok "refuses to run outside a git repo (nonzero exit)"
fi

# --- safety: --dry-run writes nothing ----------------------------------------
dry="$(fresh_repo)"
(cd "$dry" && bash "$RIG" --yes --dry-run </dev/null >/dev/null 2>&1)
if [ ! -e "$dry/AGENTS.md" ] && [ ! -e "$dry/CLAUDE.md" ] && [ ! -d "$dry/.tmp" ]; then
	ok "--dry-run writes nothing on a fresh repo"
else
	bad "--dry-run writes nothing on a fresh repo" "$(ls -a "$dry")"
fi

# --- pre-existing agent file: prose preserved, no second file ----------------
prose="$(fresh_repo)"
printf '# My project\n\nExisting prose.\nSecond line.\n' >"$prose/AGENTS.md"
orig="$(mktemp "$BASE/orig.XXXXXX")"
cp "$prose/AGENTS.md" "$orig"
osize="$(wc -c <"$orig")"
(cd "$prose" && bash "$RIG" --yes </dev/null >/dev/null 2>&1)

if head -c "$osize" "$prose/AGENTS.md" | cmp -s - "$orig"; then
	ok "existing prose preserved byte-for-byte outside the block"
else
	bad "existing prose preserved byte-for-byte outside the block"
fi

if [ ! -e "$prose/CLAUDE.md" ]; then
	ok "existing AGENTS.md: no CLAUDE.md created"
else
	bad "existing AGENTS.md: no CLAUDE.md created"
fi

o="$(count "$prose/AGENTS.md" "$OPEN")"
if [ "$o" = "1" ]; then
	ok "existing agent file gets exactly one config block"
else
	bad "existing agent file gets exactly one config block" "open=$o"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
