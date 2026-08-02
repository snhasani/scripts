#!/usr/bin/env bash
# Smoke test for vise. Exercises `list` through real filesystem symlinks —
# the repo's only intended invocation path is `bin/vise -> ../vise/vise` — so
# catalog resolution has to survive dirname-of-argv0 not being the script's
# real directory.
#
# Usage: bash vise.smoke.sh [path-to-vise]   (defaults to ./vise beside this file)

set -uo pipefail

VISE="${1:-$(cd "$(dirname "$0")" && pwd)/vise}"
[ -f "$VISE" ] || {
	printf 'vise not found at %s\n' "$VISE" >&2
	exit 2
}
CATALOG_SRC="$(dirname "$VISE")/catalog.tsv"
[ -r "$CATALOG_SRC" ] || {
	printf 'catalog not found at %s\n' "$CATALOG_SRC" >&2
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

# Probe a sandbox-writable base for the symlink fixtures. /tmp may be denied;
# the $PWD fallback covers a working tree with no usable temp.
pick_base() {
	local b d
	for b in "${TMPDIR:-}" /tmp "$PWD"; do
		[ -n "$b" ] && [ -d "$b" ] || continue
		d="$(mktemp -d "$b/vise-smoke.XXXXXX" 2>/dev/null)" || continue
		printf '%s' "$d"
		return 0
	done
	return 1
}

BASE="$(pick_base)" || {
	printf 'no writable base for symlink fixtures\n' >&2
	exit 2
}
trap 'rm -rf "$BASE"' EXIT

printf 'smoke: %s\n' "$VISE"
printf 'base:  %s\n' "$BASE"

# Fixture tool: github:kamadorueda/alejandra (kind=formatter) is a real row in
# catalog.tsv. It is a Nix formatter, and this test runs on machines with no
# Nix tooling, so nothing here claims it via mise ls/registry and its row
# stays unclaimed — which is what makes it a reliable "was the catalog
# actually read" probe: with the catalog unreachable, this coordinate has no
# row at all (not merely a "?" kind), since unclaimed catalog rows are the
# ONLY source that can produce it.
FIXTURE_COORD="github:kamadorueda/alejandra"
FIXTURE_KIND="formatter"
if ! grep -qF "$FIXTURE_COORD" "$CATALOG_SRC"; then
	printf 'fixture %s not found in %s, pick another\n' "$FIXTURE_COORD" "$CATALOG_SRC" >&2
	exit 2
fi
if mise ls --json 2>/dev/null | jq -e --arg c "$FIXTURE_COORD" 'has($c)' >/dev/null 2>&1; then
	printf 'fixture %s is installed locally, pick another\n' "$FIXTURE_COORD" >&2
	exit 2
fi

# Runs `<vise_path> list` with the given cwd and prints the fixture's kind
# column (trimmed), or NOTFOUND if the coordinate has no row at all.
fixture_kind_via() {
	local dir="$1" vise_path="$2" raw
	raw=$(cd "$dir" && bash "$vise_path" list 2>/dev/null | awk -F'\t' -v coord="$FIXTURE_COORD" '
    $1 == coord { print $4; found=1 }
    END { if (!found) print "NOTFOUND" }
  ')
	# shellcheck disable=SC2086 # word-splitting trims the kind column's padding
	echo $raw
}

REPO_ROOT="$(cd "$(dirname "$VISE")/.." && pwd)"

# --- direct: bash vise/vise list ---------------------------------------------
direct_kind="$(fixture_kind_via "$REPO_ROOT" "$VISE")"
if [ "$direct_kind" = "$FIXTURE_KIND" ]; then
	ok "direct invocation: catalog resolved ($FIXTURE_COORD -> $FIXTURE_KIND)"
else
	bad "direct invocation: catalog resolved ($FIXTURE_COORD -> $FIXTURE_KIND)" "$direct_kind"
fi

# --- hermetic mirror of the repo's bin/vise -> ../vise/vise install shape ----
# Built here rather than reused from the repo's own bin/, so the test is
# self-contained and exercises the general case, not one specific path.
mkdir -p "$BASE/pkg/vise" "$BASE/pkg/bin"
cp "$VISE" "$BASE/pkg/vise/vise"
ln -s "$CATALOG_SRC" "$BASE/pkg/vise/catalog.tsv"
ln -s "../vise/vise" "$BASE/pkg/bin/vise"

# --- (b) via a relative symlink one dir down, mirroring bin/vise ------------
got="$(fixture_kind_via "$REPO_ROOT" "$BASE/pkg/bin/vise")"
if [ "$got" = "$FIXTURE_KIND" ]; then
	ok "one-level symlink (bin/vise-style): catalog resolved"
else
	bad "one-level symlink (bin/vise-style): catalog resolved" "$got"
fi

# --- (c) via a symlink chain: link -> link -> real file ----------------------
ln -s "$BASE/pkg/vise/vise" "$BASE/pkg/hop1"
ln -s "hop1" "$BASE/pkg/hop2"
got="$(fixture_kind_via "$REPO_ROOT" "$BASE/pkg/hop2")"
if [ "$got" = "$FIXTURE_KIND" ]; then
	ok "symlink chain (link -> link -> real file): catalog resolved"
else
	bad "symlink chain (link -> link -> real file): catalog resolved" "$got"
fi

# --- (d) invoked from a completely different cwd -----------------------------
mkdir -p "$BASE/elsewhere"
got="$(fixture_kind_via "$BASE/elsewhere" "$BASE/pkg/bin/vise")"
if [ "$got" = "$FIXTURE_KIND" ]; then
	ok "different cwd: catalog resolved"
else
	bad "different cwd: catalog resolved" "$got"
fi

# --- empty-selection guards on mutating actions ------------------------------
# fzf's {+1} placeholder expands to nothing when the filtered list has zero
# matches and nothing is tab-selected — an ordinary state (type a query with
# no hits, then hit a bind key), not a contrived one. Every mutating action
# must refuse that instead of handing mise a bare command: `mise upgrade`
# with no tool argument upgrades every installed tool, not "none".

# 1. the money test: empty upgrade must refuse, not fan out to the whole
# machine's toolchain.
out=$(VISE_DRY_RUN=1 bash "$VISE" __upgrade 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && ! printf '%s\n' "$out" | grep -qx 'DRY: mise upgrade' &&
	printf '%s\n' "$out" | grep -q '^vise: '; then
	ok "empty upgrade refuses instead of upgrading every installed tool"
else
	bad "empty upgrade refuses instead of upgrading every installed tool" "rc=$rc out=[$out]"
fi

# 2. the other mutating actions get the same guard.
for action in __use-global __use-project __rm; do
	out=$(VISE_DRY_RUN=1 bash "$VISE" "$action" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ] && ! printf '%s\n' "$out" | grep -q '^DRY: mise ' &&
		printf '%s\n' "$out" | grep -q '^vise: '; then
		ok "empty $action refuses (no mutation attempted)"
	else
		bad "empty $action refuses (no mutation attempted)" "rc=$rc out=[$out]"
	fi
done

# 3. control: a real selection must still go through unguarded — without
# this, a guard that refuses everything would pass the assertions above too.
out=$(VISE_DRY_RUN=1 bash "$VISE" __upgrade shfmt 2>&1)
if printf '%s\n' "$out" | grep -qx 'DRY: mise upgrade shfmt'; then
	ok "non-empty upgrade still dry-runs"
else
	bad "non-empty upgrade still dry-runs" "$out"
fi

# --- bash 3.2 compatibility ---------------------------------------------------
# macOS ships /bin/bash 3.2.57. Bash below 4.4 treats "${ARR[@]}" on a
# zero-length array as an unset variable under `set -u`, aborting the script
# — exactly the empty-selection path exercised above. `#!/usr/bin/env bash`
# only reaches a newer bash if one sits earlier on PATH, so this must hold
# against /bin/bash directly, not whatever bash happens to be default.
if [ ! -x /bin/bash ]; then
	printf '  \033[33mskip\033[0m bash 3.2 compatibility (/bin/bash not present)\n'
elif ! /bin/bash -c '((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4)))' 2>/dev/null; then
	crashed=0
	for action in __preview __use-global __use-project __upgrade __rm; do
		out=$(VISE_DRY_RUN=1 /bin/bash "$VISE" "$action" 2>&1)
		case "$out" in
		*'unbound variable'*) crashed=1 ;;
		esac
	done
	if [ "$crashed" -eq 0 ]; then
		ok "empty-selection dispatch survives /bin/bash 3.2 (no unbound variable)"
	else
		bad "empty-selection dispatch survives /bin/bash 3.2 (no unbound variable)" "$out"
	fi
else
	sys_ver=$(/bin/bash -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"')
	printf '  \033[33mskip\033[0m bash 3.2 compatibility (/bin/bash is %s, not pre-4.4)\n' "$sys_ver"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
