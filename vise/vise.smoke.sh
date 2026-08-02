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

# --- default filter: hides uncatalogued rows, keeps real editor tooling -----
# vise's row set unions the catalog with everything mise manages (see
# vise::render's $observed); anything absent from the catalog reports kind
# "?". The picker exists to browse LSPs/linters/formatters, not the runtimes
# and package managers mise also happens to run, so uncatalogued rows must be
# hidden by default. VISE_FILTER=all (ctrl-a) is the escape hatch back to
# everything.
#
# A synthetic single-row catalog stands in for the real one: against the real
# ~500-row catalog almost nothing observed lands as "?", so the exact case
# under test — uncatalogued rows leaking into the default view — would go
# unexercised. cargo:rnix-lsp (kind lsp, language nix) is a real catalog.tsv
# row picked for the same reason as the alejandra fixture above: Nix tooling
# is absent from machines that run this suite, so nothing here installs or
# configures it by coincidence.
FILTER_CATALOG="$(mktemp -d "$BASE/filter-catalog.XXXXXX")/catalog.tsv"
cat >"$FILTER_CATALOG" <<'EOF'
cargo:rnix-lsp	rnix-lsp	lsp	nix
EOF
if mise ls --json 2>/dev/null | jq -e 'has("cargo:rnix-lsp")' >/dev/null 2>&1; then
    printf 'fixture cargo:rnix-lsp is installed locally, pick another\n' >&2
    exit 2
fi

# kind lives in column 4, right-padded to KIND_W with spaces (vise::render's
# pad()); trim the padding before comparing.
kind_field() { awk -F'\t' '{ k = $4; sub(/[ \t]+$/, "", k); print k }'; }

default_out="$(cd "$REPO_ROOT" && VISE_CATALOG="$FILTER_CATALOG" bash "$VISE" list 2>&1)"

unclassified=$(printf '%s\n' "$default_out" | kind_field | grep -cx '?') || unclassified=0
if [ "$unclassified" = "0" ]; then
    ok "default filter: no uncatalogued (?) rows"
else
    bad "default filter: no uncatalogued (?) rows" "$unclassified row(s)"
fi

# Control for the assertion above: a bug that hides EVERYTHING (not just "?"
# rows) would pass it too. The fixture's own catalogued tool must survive.
if printf '%s\n' "$default_out" | awk -F'\t' '$1 == "cargo:rnix-lsp"' | grep -q .; then
    ok "default filter: still shows real tooling (rnix-lsp)"
else
    bad "default filter: still shows real tooling (rnix-lsp)" "$default_out"
fi

# VISE_FILTER=all needs at least one observed tool outside the fixture catalog
# to prove anything widened. This repo's own mise.toml (shfmt, shellcheck,
# lefthook) guarantees that when run from REPO_ROOT, but check rather than
# assume — skip instead of failing if the precondition doesn't hold.
if {
    mise config ls --json 2>/dev/null | jq -r '.[].tools[]?'
    mise ls --json 2>/dev/null | jq -r 'keys[]?'
} |
    grep -vxF 'cargo:rnix-lsp' | grep -q .; then
    all_out="$(cd "$REPO_ROOT" && VISE_FILTER=all VISE_CATALOG="$FILTER_CATALOG" bash "$VISE" list 2>&1)"
    default_n=$(printf '%s\n' "$default_out" | grep -c .) || default_n=0
    all_n=$(printf '%s\n' "$all_out" | grep -c .) || all_n=0
    all_unclassified=$(printf '%s\n' "$all_out" | kind_field | grep -cx '?') || all_unclassified=0
    if [ "$all_n" -gt "$default_n" ] && [ "$all_unclassified" -gt "0" ]; then
        ok "VISE_FILTER=all widens: more rows, includes uncatalogued (?)"
    else
        bad "VISE_FILTER=all widens: more rows, includes uncatalogued (?)" \
            "default=$default_n all=$all_n unclassified=$all_unclassified"
    fi
else
    printf '  \033[33mskip\033[0m VISE_FILTER=all widens (no uncatalogued mise tool observed here)\n'
fi

# VISE_FILTER=tooling explicit must match the new default byte-for-byte: the
# flip changes which mode starts active, never what "tooling" mode does.
tooling_out="$(cd "$REPO_ROOT" && VISE_FILTER=tooling VISE_CATALOG="$FILTER_CATALOG" bash "$VISE" list 2>&1)"
if [ "$tooling_out" = "$default_out" ]; then
    ok "VISE_FILTER=tooling explicit matches the default"
else
    bad "VISE_FILTER=tooling explicit matches the default" \
        "$(diff <(printf '%s\n' "$default_out") <(printf '%s\n' "$tooling_out") | head -5)"
fi

# --- default filter: the interactive picker seeds the same default ----------
# `list` never touches vise::tui — it calls vise::render directly, so every
# assertion above exercises only vise::filter_mode's fallback, not the
# separate "${VISE_FILTER:-tooling}" seed vise::tui writes to VISE_STATE
# before fzf ever starts. The two must agree (see the comment at that seed);
# a stub fzf stands in for the real one so this can assert the seeded value
# without a TTY or a real picker session.
STUB_BIN="$(mktemp -d "$BASE/stubbin.XXXXXX")"
cat >"$STUB_BIN/fzf" <<'EOF'
#!/bin/sh
# Drains the rendered rows like a real fzf would, reports vise::tui's initial
# VISE_STATE content to a side file, then quits with no selection.
cat >/dev/null
[ -n "${VISE_STATE:-}" ] && cat "$VISE_STATE" >"$FZF_STUB_OUT" 2>/dev/null
exit 130
EOF
chmod +x "$STUB_BIN/fzf"

TUI_STATE_OUT="$(mktemp "$BASE/tui-state.XXXXXX")"
(cd "$REPO_ROOT" && PATH="$STUB_BIN:$PATH" FZF_STUB_OUT="$TUI_STATE_OUT" \
    VISE_CATALOG="$FILTER_CATALOG" bash "$VISE" >/dev/null 2>&1)
seeded="$(cat "$TUI_STATE_OUT" 2>/dev/null)"
if [ "$seeded" = "tooling" ]; then
    ok "vise::tui seeds VISE_STATE to tooling by default"
else
    bad "vise::tui seeds VISE_STATE to tooling by default" "[$seeded]"
fi

# --- atomic catalog writes (vise::write_atomic via __write-atomic) ----------
# vise::sync's final block used to redirect straight into the live catalog
# (`{ ... } >"$out"`): the shell truncates $out the moment that redirect is
# set up, before any of the block's commands run, so a mid-pipeline failure
# (malformed override, sort killed, disk full, Ctrl-C) destroyed the
# committed catalog and left only whatever had been printed so far — with no
# "sync failed" message, since the abort happened after truncation. A pipe's
# reading side can't tell a producer that finished from one that wrote a few
# lines and died (EOF looks identical either way), so vise::write_atomic runs
# the producer itself, checked via a plain redirect, and only renames its
# temp file over dest when that redirect's own exit status says it may.
WA_DIR="$(mktemp -d "$BASE/write-atomic.XXXXXX")"

# 1. success: seeded dest gets fully replaced by the producer's output.
wa_dest="$WA_DIR/success.tsv"
printf 'old content\n' >"$wa_dest"
bash "$VISE" __write-atomic "$wa_dest" printf 'new content\n' >/dev/null 2>&1
got="$(cat "$wa_dest")"
if [ "$got" = "new content" ]; then
    ok "write_atomic: success path replaces dest with the producer's output"
else
    bad "write_atomic: success path replaces dest with the producer's output" "$got"
fi

# 2. failure: THE point of this slice — a producer that emits a few lines
# then dies must not touch dest at all. This is the assertion that would
# have caught the original bug.
wa_dest2="$WA_DIR/failure.tsv"
printf 'original catalog content\n' >"$wa_dest2"
bash "$VISE" __write-atomic "$wa_dest2" bash -c 'printf "a\nb\n"; exit 1' >/dev/null 2>&1
rc=$?
got2="$(cat "$wa_dest2")"
if [ "$rc" -ne 0 ] && [ "$got2" = "original catalog content" ]; then
    ok "write_atomic: failing producer leaves dest byte-identical and reports failure"
else
    bad "write_atomic: failing producer leaves dest byte-identical and reports failure" "rc=$rc got=[$got2]"
fi

# 3. no litter: nothing from the failed attempt above may remain beside dest.
litter="$(find "$WA_DIR" -maxdepth 1 -name '.vise-*' 2>/dev/null)"
if [ -z "$litter" ]; then
    ok "write_atomic: no leftover temp file after a failed write"
else
    bad "write_atomic: no leftover temp file after a failed write" "$litter"
fi

# 4. mode preserved: a rename must not silently loosen or tighten permissions.
wa_dest3="$WA_DIR/mode.tsv"
printf 'content\n' >"$wa_dest3"
chmod 0640 "$wa_dest3"
bash "$VISE" __write-atomic "$wa_dest3" printf 'new content\n' >/dev/null 2>&1
mode_after=$(stat -f '%Lp' "$wa_dest3" 2>/dev/null || stat -c '%a' "$wa_dest3" 2>/dev/null)
if [ "$mode_after" = "640" ]; then
    ok "write_atomic: preserves the destination's existing mode"
else
    bad "write_atomic: preserves the destination's existing mode" "$mode_after"
fi

# 5. new file: sync's first run on a fresh checkout has no catalog.tsv yet.
wa_dest4="$WA_DIR/new.tsv"
bash "$VISE" __write-atomic "$wa_dest4" printf 'first content\n' >/dev/null 2>&1
got4="$([ -f "$wa_dest4" ] && cat "$wa_dest4")"
if [ "$got4" = "first content" ]; then
    ok "write_atomic: creates dest when it doesn't exist yet"
else
    bad "write_atomic: creates dest when it doesn't exist yet" "$got4"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
