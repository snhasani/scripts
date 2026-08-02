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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
