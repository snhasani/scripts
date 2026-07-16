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

# A fresh repo carrying an origin remote, so tracker repo-slug detection has
# input (github backend derives `repo` from `git remote get-url origin`).
fresh_repo_origin() {
	local r
	r="$(fresh_repo)"
	git -C "$r" remote add origin "https://github.com/acme/widget.git"
	printf '%s' "$r"
}

# Skills-dir fixtures for deterministic triage presence/absence — point rig at
# these via RIG_SKILLS_DIR instead of depending on the host's ~/skills.
SKILLS_WITH="$(mktemp -d "$BASE/skills-with.XXXXXX")"
mkdir -p "$SKILLS_WITH/triage"
SKILLS_NONE="$(mktemp -d "$BASE/skills-none.XXXXXX")"

# Count exact occurrences of a fixed string across a file: a single integer, 0
# when the file is missing OR has zero matches (grep -c prints 0 and exits 1 on
# zero matches, so the fallback must not also fire and emit a second line).
count() {
	local n
	n=$(grep -cF "$2" "$1" 2>/dev/null) || n=0
	printf '%s' "$n"
}

printf 'smoke: %s\n' "$RIG"
printf 'base:  %s\n' "$BASE"

OPEN='<!-- rig:config -->'
CLOSE='<!-- /rig:config -->'

# --- count(): zero matches in an existing file is a single "0" ----------------
# Guards the helper the marker-count assertions depend on: grep -c prints "0" and
# exits 1 on zero matches, so a naive `|| printf 0` fallback double-fires and
# returns a two-line "0\n0", silently breaking every equality check below.
probe="$(mktemp "$BASE/count-probe.XXXXXX")"
printf 'a present line\n' >"$probe"
z="$(count "$probe" 'marker-absent-from-file')"
if [ "$z" = "0" ]; then
	ok "count(): zero matches in an existing file returns a single 0"
else
	bad "count(): zero matches in an existing file returns a single 0" "[$z]"
fi

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

# --- scratch: ignore write never glues onto a newline-less last line ---------
# A committed .gitignore whose content lacks a trailing newline must not have the
# scratch entry glued onto its final line (node_modules -> node_modules.tmp/).
# A footprint comment attributes the entry, and a second run stays byte-stable.
gi="$(fresh_repo)"
printf 'node_modules' >"$gi/.gitignore"
(cd "$gi" && RIG_SKILLS_DIR="$SKILLS_NONE" bash "$RIG" --yes </dev/null >/dev/null 2>&1)

if grep -qx 'node_modules' "$gi/.gitignore"; then
	ok "scratch: newline-less last line survives intact on its own line"
else
	bad "scratch: newline-less last line survives intact on its own line" "$(cat "$gi/.gitignore")"
fi

if grep -qF '# rig: agent-skills scratch root' "$gi/.gitignore"; then
	ok "scratch: footprint comment attributes the ignore entry"
else
	bad "scratch: footprint comment attributes the ignore entry" "$(cat "$gi/.gitignore")"
fi

if (cd "$gi" && git check-ignore -q .tmp); then
	ok "scratch: .tmp ignored via the committed .gitignore"
else
	bad "scratch: .tmp ignored via the committed .gitignore"
fi

gib="$(mktemp "$BASE/gitignore.XXXXXX")"
cp "$gi/.gitignore" "$gib"
(cd "$gi" && RIG_SKILLS_DIR="$SKILLS_NONE" bash "$RIG" --yes </dev/null >/dev/null 2>&1)
if cmp -s "$gib" "$gi/.gitignore"; then
	ok "scratch: second run leaves .gitignore byte-identical (no duplicate entry)"
else
	bad "scratch: second run leaves .gitignore byte-identical (no duplicate entry)" "$(diff "$gib" "$gi/.gitignore" 2>&1 | head -5)"
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

# --- safety: RIG_AGENT_FILE outside the repo root is refused -----------------
# BASE sits outside any repo, so an absolute agent-file path there escapes the
# throwaway repo's root. rig must refuse (nonzero) and write no file outside.
esc="$(fresh_repo)"
escfile="$BASE/rig-escape.md"
rm -f "$escfile"
if (cd "$esc" && RIG_AGENT_FILE="$escfile" bash "$RIG" --yes </dev/null >/dev/null 2>&1); then
	bad "RIG_AGENT_FILE outside the repo: nonzero exit"
else
	ok "RIG_AGENT_FILE outside the repo: nonzero exit"
fi
if [ ! -e "$escfile" ]; then
	ok "RIG_AGENT_FILE outside the repo: no file created outside the root"
else
	bad "RIG_AGENT_FILE outside the repo: no file created outside the root"
	rm -f "$escfile"
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

# --- tracker: github backend, repo from the origin remote --------------------
tk="$(fresh_repo_origin)"
(cd "$tk" && RIG_SKILLS_DIR="$SKILLS_NONE" bash "$RIG" --yes </dev/null >/dev/null 2>&1)
if grep -qF 'backend: github' "$tk/AGENTS.md" && grep -qF 'repo: acme/widget' "$tk/AGENTS.md"; then
	ok "tracker: github backend, repo detected from origin remote"
else
	bad "tracker: github backend, repo detected from origin remote" "$(grep -F tracker "$tk/AGENTS.md" 2>&1)"
fi

# --- tracker: shortcut backend, workspace set, token never written -----------
sc="$(fresh_repo)"
(cd "$sc" && SHORTCUT_API_TOKEN=leaky-token RIG_TRACKER=shortcut RIG_SHORTCUT_WORKSPACE=acme-ws \
	RIG_SKILLS_DIR="$SKILLS_NONE" bash "$RIG" --yes </dev/null >/dev/null 2>&1)
if grep -qF 'backend: shortcut' "$sc/AGENTS.md" && grep -qF 'shortcut_workspace: acme-ws' "$sc/AGENTS.md"; then
	ok "tracker: shortcut backend with workspace"
else
	bad "tracker: shortcut backend with workspace" "$(grep -F tracker "$sc/AGENTS.md" 2>&1)"
fi

if ! grep -qE 'leaky-token|SHORTCUT_API_TOKEN' "$sc/AGENTS.md"; then
	ok "tracker: shortcut token is never written into the config block"
else
	bad "tracker: shortcut token is never written into the config block"
fi

# --- triage present: five canonical roles in the config block ----------------
tp="$(fresh_repo)"
(cd "$tp" && RIG_SKILLS_DIR="$SKILLS_WITH" bash "$RIG" --yes </dev/null >/dev/null 2>&1)
missing=""
for role in needs-triage needs-info ready-for-agent ready-for-human wontfix; do
	grep -qF "${role}:" "$tp/AGENTS.md" || missing="$missing $role"
done
if grep -q '^triage:' "$tp/AGENTS.md" && [ -z "$missing" ]; then
	ok "triage present: config block has a triage map with all five canonical roles"
else
	bad "triage present: config block has a triage map with all five canonical roles" "missing:${missing:-<none>}"
fi

# --- triage absent: the triage key is omitted entirely -----------------------
ta="$(fresh_repo)"
(cd "$ta" && RIG_SKILLS_DIR="$SKILLS_NONE" bash "$RIG" --yes </dev/null >/dev/null 2>&1)
if ! grep -q '^triage:' "$ta/AGENTS.md"; then
	ok "triage absent: no triage key in the config block"
else
	bad "triage absent: no triage key in the config block"
fi

# --- domain: single-context scaffold by default ------------------------------
ds="$(fresh_repo)"
(cd "$ds" && RIG_SKILLS_DIR="$SKILLS_NONE" bash "$RIG" --yes </dev/null >/dev/null 2>&1)
if [ -f "$ds/CONTEXT.md" ] && [ -d "$ds/docs/adr" ] && [ ! -e "$ds/CONTEXT-MAP.md" ]; then
	ok "domain single-context: CONTEXT.md + docs/adr/, no CONTEXT-MAP.md"
else
	bad "domain single-context: CONTEXT.md + docs/adr/, no CONTEXT-MAP.md" "$(ls -a "$ds")"
fi

# --- domain: multi-context scaffold on a monorepo signal ---------------------
dm="$(fresh_repo)"
printf 'packages:\n  - "packages/*"\n' >"$dm/pnpm-workspace.yaml"
(cd "$dm" && RIG_SKILLS_DIR="$SKILLS_NONE" bash "$RIG" --yes </dev/null >/dev/null 2>&1)
if [ -f "$dm/CONTEXT-MAP.md" ] && [ -d "$dm/docs/adr" ]; then
	ok "domain multi-context: CONTEXT-MAP.md + docs/adr/ on a monorepo signal"
else
	bad "domain multi-context: CONTEXT-MAP.md + docs/adr/ on a monorepo signal" "$(ls -a "$dm")"
fi

# --- idempotency across the config block AND the domain scaffold -------------
idr="$(fresh_repo_origin)"
(cd "$idr" && RIG_SKILLS_DIR="$SKILLS_WITH" bash "$RIG" --yes </dev/null >/dev/null 2>&1)
afb="$(mktemp "$BASE/af2.XXXXXX")"
cp "$idr/AGENTS.md" "$afb"
ctxb="$(mktemp "$BASE/ctx2.XXXXXX")"
cp "$idr/CONTEXT.md" "$ctxb"
(cd "$idr" && RIG_SKILLS_DIR="$SKILLS_WITH" bash "$RIG" --yes </dev/null >/dev/null 2>&1)

if cmp -s "$afb" "$idr/AGENTS.md" && cmp -s "$ctxb" "$idr/CONTEXT.md"; then
	ok "second run: AGENTS.md and CONTEXT.md byte-identical (config + domain idempotent)"
else
	bad "second run: AGENTS.md and CONTEXT.md byte-identical" "$(diff "$afb" "$idr/AGENTS.md" 2>&1 | head -5)"
fi

t="$(count "$idr/AGENTS.md" 'tracker:')"
tr="$(grep -c '^triage:' "$idr/AGENTS.md")"
if [ "$t" = "1" ] && [ "$tr" = "1" ]; then
	ok "second run: exactly one tracker: and one triage: key (no duplicates)"
else
	bad "second run: exactly one tracker: and one triage: key (no duplicates)" "tracker=$t triage=$tr"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
