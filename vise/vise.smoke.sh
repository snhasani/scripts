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
if printf '%s\n' "$out" | grep -qx 'DRY: mise upgrade -- shfmt'; then
    ok "non-empty upgrade still dry-runs"
else
    bad "non-empty upgrade still dry-runs" "$out"
fi

# --- mixed availability in a multi-select: one bad row must not cancel -------
# the rest. --help promises "every action applies to the whole selection";
# tab-selecting an unavailable: row (24 exist in the catalog) alongside good
# ones must not silently withhold the good ones too.
for pair in "__use-global:mise use -g" "__use-project:mise use" "__upgrade:mise upgrade"; do
    action="${pair%%:*}"
    mise_cmd="${pair#*:}"
    out=$(VISE_DRY_RUN=1 bash "$VISE" "$action" good-tool unavailable:some-tool 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ] &&
        printf '%s\n' "$out" | grep -qx "DRY: $mise_cmd -- good-tool" &&
        printf '%s\n' "$out" | grep -q 'some-tool has no mise backend'; then
        ok "$action: valid coordinate installs despite an unavailable row in the selection"
    else
        bad "$action: valid coordinate installs despite an unavailable row in the selection" "rc=$rc out=[$out]"
    fi
done

# --- "--" before coordinates: a coordinate spelled like a flag must not be ---
# parsed as one. Paired with a fixture coordinate that starts with "-" so
# these tests would redden without the separator.
for pair in "__use-global:mise use -g" "__use-project:mise use" "__upgrade:mise upgrade"; do
    action="${pair%%:*}"
    mise_cmd="${pair#*:}"
    out=$(VISE_DRY_RUN=1 bash "$VISE" "$action" -flaglike-coord 2>&1)
    if printf '%s\n' "$out" | grep -qx "DRY: $mise_cmd -- -flaglike-coord"; then
        ok "$action: -- separates flags from a coordinate starting with -"
    else
        bad "$action: -- separates flags from a coordinate starting with -" "$out"
    fi
done

# vise::rm resolves scope via a stubbed `mise config ls --json` (see the
# batch-removal stub below) rather than VISE_DRY_RUN, so it needs its own
# fixture rather than reusing the loop above.
DASH_RM_DIR="$(mktemp -d "$BASE/dash-rm.XXXXXX")"
DASH_RM_STUB_BIN="$(mktemp -d "$BASE/dash-rm-stubbin.XXXXXX")"
DASH_RM_GLOBAL_CFG="$DASH_RM_DIR/global-config.toml"
: >"$DASH_RM_GLOBAL_CFG"
DASH_RM_CALLS="$DASH_RM_DIR/calls.log"
: >"$DASH_RM_CALLS"
cat >"$DASH_RM_STUB_BIN/mise" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>'$DASH_RM_CALLS'
if [ "\$1" = "config" ] && [ "\$2" = "ls" ]; then
    printf '[{"path": "%s", "tools": ["-flaglike-coord"]}]\n' '$DASH_RM_GLOBAL_CFG'
    exit 0
fi
exit 0
EOF
chmod +x "$DASH_RM_STUB_BIN/mise"
(cd "$REPO_ROOT" && PATH="$DASH_RM_STUB_BIN:$PATH" \
    MISE_GLOBAL_CONFIG_FILE="$DASH_RM_GLOBAL_CFG" \
    bash "$VISE" __rm -flaglike-coord >/dev/null 2>&1)
if grep -qx -- 'rm -g -- -flaglike-coord' "$DASH_RM_CALLS"; then
    ok "__rm: -- separates flags from a coordinate starting with -"
else
    bad "__rm: -- separates flags from a coordinate starting with -" "$(cat "$DASH_RM_CALLS")"
fi

# vise::preview's `mise ls "$coord"` call (plain-text detail pane) needs the
# same guard; a stub logs its argv to prove the separator reached it.
DASH_PREVIEW_STUB_BIN="$(mktemp -d "$BASE/dash-preview-stubbin.XXXXXX")"
DASH_PREVIEW_CALLS="$(mktemp "$BASE/dash-preview-calls.XXXXXX")"
cat >"$DASH_PREVIEW_STUB_BIN/mise" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>'$DASH_PREVIEW_CALLS'
exit 0
EOF
chmod +x "$DASH_PREVIEW_STUB_BIN/mise"
(cd "$REPO_ROOT" && PATH="$DASH_PREVIEW_STUB_BIN:$PATH" \
    bash "$VISE" __preview -flaglike-coord none name kind lang ver stars - - - >/dev/null 2>&1)
if grep -qx -- 'ls -- -flaglike-coord' "$DASH_PREVIEW_CALLS"; then
    ok "__preview: -- separates flags from a coordinate starting with -"
else
    bad "__preview: -- separates flags from a coordinate starting with -" "$(cat "$DASH_PREVIEW_CALLS")"
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
# mktemp's own mode (0600) must not leak through to the renamed file — a
# fresh catalog.tsv should land at the usual ~0644, not owner-only.
wa_dest4="$WA_DIR/new.tsv"
bash "$VISE" __write-atomic "$wa_dest4" printf 'first content\n' >/dev/null 2>&1
got4="$([ -f "$wa_dest4" ] && cat "$wa_dest4")"
if [ "$got4" = "first content" ]; then
    ok "write_atomic: creates dest when it doesn't exist yet"
else
    bad "write_atomic: creates dest when it doesn't exist yet" "$got4"
fi

mode4=$(stat -f '%Lp' "$wa_dest4" 2>/dev/null || stat -c '%a' "$wa_dest4" 2>/dev/null)
if [ "$mode4" = "644" ]; then
    ok "write_atomic: fresh file lands at 644, not mktemp's 600"
else
    bad "write_atomic: fresh file lands at 644, not mktemp's 600" "$mode4"
fi

# 6. trap ordering: `[[ -e "$dest" ]] && mode=$(vise::mode_of "$dest")` runs
# before the EXIT trap is installed. The right operand of && is NOT
# set -e-exempt, so a failing mode_of aborts the function before the trap
# that would clean up the temp file exists — a stubbed `stat` that always
# fails forces mode_of to fail without needing a real race.
STAT_FAIL_BIN="$(mktemp -d "$BASE/stat-fail-bin.XXXXXX")"
cat >"$STAT_FAIL_BIN/stat" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$STAT_FAIL_BIN/stat"

wa_dest5="$WA_DIR/trap-order.tsv"
printf 'existing content\n' >"$wa_dest5"
(cd "$REPO_ROOT" && PATH="$STAT_FAIL_BIN:$PATH" bash "$VISE" __write-atomic "$wa_dest5" printf 'new content\n' >/dev/null 2>&1)
litter5="$(find "$WA_DIR" -maxdepth 1 -name '.vise-*' 2>/dev/null)"
if [ -z "$litter5" ]; then
    ok "write_atomic: no leftover temp file when mode_of fails before the trap"
else
    bad "write_atomic: no leftover temp file when mode_of fails before the trap" "$litter5"
fi

# --- partial failure during batch removal: every coordinate is attempted ----
# vise::rm used to loop `vise::mutate mise rm ...` unguarded, so under this
# script's `set -e` the first failure killed the function (and the process),
# leaving every coordinate selected after it untouched and printing no
# summary of what happened or didn't. VISE_DRY_RUN can't exercise this — it
# intercepts inside vise::mutate before a real failure is possible — so a
# stub mise stands in for the real one, answering `config ls --json` (how
# vise::scope_of decides each coordinate's scope) and failing `rm` for one
# specific coordinate only.
RM_DIR="$(mktemp -d "$BASE/rm-batch.XXXXXX")"
RM_STUB_BIN="$(mktemp -d "$BASE/rm-stubbin.XXXXXX")"
RM_GLOBAL_CFG="$RM_DIR/global-config.toml"
: >"$RM_GLOBAL_CFG"
RM_CALLS="$RM_DIR/calls.log"
: >"$RM_CALLS"

cat >"$RM_STUB_BIN/mise" <<EOF
#!/bin/sh
# Logs every invocation (so the test can see which coordinates the loop
# reached) and fails "rm" only for \$RM_FAIL_COORD, to make the mid-batch
# failure deterministic.
printf '%s\n' "\$*" >>'$RM_CALLS'
if [ "\$1" = "config" ] && [ "\$2" = "ls" ]; then
    printf '[{"path": "%s", "tools": ["tool-a", "tool-b", "tool-c"]}]\n' '$RM_GLOBAL_CFG'
    exit 0
fi
if [ "\$1" = "ls" ] && [ "\$2" = "--json" ]; then
    echo '{}'
    exit 0
fi
if [ "\$1" = "registry" ] && [ "\$2" = "--json" ]; then
    echo '[]'
    exit 0
fi
if [ "\$1" = "rm" ]; then
    shift
    [ "\$1" = "-g" ] && shift
    [ "\$1" = "--" ] && shift
    if [ "\$1" = "\$RM_FAIL_COORD" ]; then
        echo "mise: failed to remove \$1" >&2
        exit 1
    fi
    exit 0
fi
exit 0
EOF
chmod +x "$RM_STUB_BIN/mise"

rm_out=$(cd "$REPO_ROOT" && PATH="$RM_STUB_BIN:$PATH" \
    MISE_GLOBAL_CONFIG_FILE="$RM_GLOBAL_CFG" RM_FAIL_COORD="tool-b" \
    bash "$VISE" __rm tool-a tool-b tool-c 2>&1)
rm_rc=$?

attempted=$(grep -c '^rm -g -- tool-' "$RM_CALLS")
if [ "$attempted" = "3" ]; then
    ok "batch removal: every coordinate attempted despite a mid-batch failure"
else
    bad "batch removal: every coordinate attempted despite a mid-batch failure" "$(cat "$RM_CALLS")"
fi

if [ "$rm_rc" -ne 0 ]; then
    ok "batch removal: exits non-zero when any coordinate fails"
else
    bad "batch removal: exits non-zero when any coordinate fails" "rc=$rm_rc"
fi

if printf '%s\n' "$rm_out" | grep -q 'tool-b' &&
    ! printf '%s\n' "$rm_out" | grep -qE 'failed to remove:.*tool-a|failed to remove:.*tool-c'; then
    ok "batch removal: summary names the failed coordinate, not the ones that succeeded"
else
    bad "batch removal: summary names the failed coordinate, not the ones that succeeded" "$rm_out"
fi

# --- fixture seams: VISE_CONFIG_JSON / VISE_LS_JSON / VISE_REGISTRY_JSON ----
# vise::config_json and vise::render otherwise shell out to `mise` directly,
# so nothing above this line can exercise the identity join without real mise
# state on the machine running the suite. These three env vars are TEST SEAMS
# (see vise::usage's TEST SEAMS block) — a fixture file stands in for the
# corresponding `mise ... --json` call, at the exact call site, with zero
# effect unless a test sets it. PATH is stripped of every `mise` on this
# machine for both checks below: if a seam were missing or miswired, the
# fallback `mise ...` branch would run and fail with "command not found"
# instead of quietly reading real machine state.
SEAM_DIR="$(mktemp -d "$BASE/seams.XXXXXX")"
NO_MISE_PATH="/usr/bin:/bin"
if [ -n "$(PATH="$NO_MISE_PATH" command -v mise 2>/dev/null)" ]; then
    printf 'mise is reachable on %s, seam tests would be meaningless, pick a narrower PATH\n' "$NO_MISE_PATH" >&2
    exit 2
fi

# 1. VISE_CONFIG_JSON stands in for `mise config ls --json`, used by
# vise::scope_of (and so vise::rm) independently of vise::render/list.
SEAM_GLOBAL_CFG="$SEAM_DIR/global.toml"
cat >"$SEAM_DIR/config.json" <<EOF
[{"path": "$SEAM_GLOBAL_CFG", "tools": ["seam-tool"]}]
EOF
out=$(PATH="$NO_MISE_PATH" VISE_CONFIG_JSON="$SEAM_DIR/config.json" \
    MISE_GLOBAL_CONFIG_FILE="$SEAM_GLOBAL_CFG" VISE_DRY_RUN=1 \
    bash "$VISE" __rm seam-tool 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qx 'DRY: mise rm -g -- seam-tool'; then
    ok "VISE_CONFIG_JSON stands in for mise config ls --json (no real mise on PATH)"
else
    bad "VISE_CONFIG_JSON stands in for mise config ls --json (no real mise on PATH)" "rc=$rc out=[$out]"
fi

# 2. VISE_LS_JSON + VISE_REGISTRY_JSON stand in inside vise::render (list also
# needs VISE_CONFIG_JSON, since render calls vise::config_json too).
SEAM_CATALOG="$SEAM_DIR/catalog.tsv"
cat >"$SEAM_CATALOG" <<'EOF'
seam:coord	seam-name	lsp	seamlang
EOF
cat >"$SEAM_DIR/ls.json" <<'EOF'
{"seam:coord": [{"version": "9.9.9", "active": true}]}
EOF
echo '[]' >"$SEAM_DIR/registry.json"
out=$(PATH="$NO_MISE_PATH" VISE_CATALOG="$SEAM_CATALOG" \
    VISE_CONFIG_JSON="$SEAM_DIR/config.json" VISE_LS_JSON="$SEAM_DIR/ls.json" \
    VISE_REGISTRY_JSON="$SEAM_DIR/registry.json" \
    MISE_GLOBAL_CONFIG_FILE="$SEAM_GLOBAL_CFG" \
    bash "$VISE" list 2>&1)
rc=$?
if [ "$rc" -eq 0 ] &&
    printf '%s\n' "$out" | awk -F'\t' '$1 == "seam:coord"' | grep -q 'seam-name' &&
    printf '%s\n' "$out" | awk -F'\t' '$1 == "seam:coord" {print $6}' | grep -q '9.9.9'; then
    ok "VISE_LS_JSON + VISE_REGISTRY_JSON stand in for mise ls/registry --json (no real mise on PATH)"
else
    bad "VISE_LS_JSON + VISE_REGISTRY_JSON stand in for mise ls/registry --json (no real mise on PATH)" "rc=$rc out=[$out]"
fi

# --- coordinate identity join: 3 spellings collapse to ONE row --------------
# aqua:tamasfe/taplo (the catalog's own coordinate), github:tamasfe/taplo, and
# the bare shorthand taplo are one tool under three different backends. The
# bug this join exists to prevent: install it under ANY ONE of these
# spellings and, without the join, it would show as TWO rows instead of
# one — a phantom "not installed" ghost of the catalog's own coordinate, plus
# an "uncatalogued" (kind "?") row for whatever you actually typed. Each
# spelling is tested independently, one real install at a time: a single tool
# never arrives through all three backends simultaneously.
ORIG_PATH="$PATH"
JOIN_DIR="$(mktemp -d "$BASE/join.XXXXXX")"
JOIN_GLOBAL_CFG="$JOIN_DIR/global.toml"
JOIN_CATALOG="$JOIN_DIR/catalog.tsv"
cat >"$JOIN_CATALOG" <<'EOF'
aqua:tamasfe/taplo	taplo	lsp,formatter	toml
EOF
cat >"$JOIN_DIR/registry.json" <<'EOF'
[{"short": "taplo", "backends": ["aqua:tamasfe/taplo", "cargo:taplo-cli"], "description": "A TOML toolkit"}]
EOF

for spelling in "aqua:tamasfe/taplo" "github:tamasfe/taplo" "taplo"; do
    cat >"$JOIN_DIR/config.json" <<EOF
[{"path": "$JOIN_GLOBAL_CFG", "tools": ["$spelling"]}]
EOF
    cat >"$JOIN_DIR/ls.json" <<EOF
{"$spelling": [{"version": "0.10.0", "active": true}]}
EOF
    out=$(cd "$REPO_ROOT" && VISE_CATALOG="$JOIN_CATALOG" VISE_CONFIG_JSON="$JOIN_DIR/config.json" \
        VISE_LS_JSON="$JOIN_DIR/ls.json" VISE_REGISTRY_JSON="$JOIN_DIR/registry.json" \
        MISE_GLOBAL_CONFIG_FILE="$JOIN_GLOBAL_CFG" bash "$VISE" list 2>&1)
    rows=$(printf '%s\n' "$out" | grep -c .)
    row=$(printf '%s\n' "$out" | awk -F'\t' -v c="$spelling" '$1 == c')
    if [ "$rows" = "1" ] && [ -n "$row" ] && printf '%s\n' "$row" | grep -q 'taplo'; then
        ok "join: $spelling collapses to one row carrying the catalog's name/kind"
    else
        bad "join: $spelling collapses to one row carrying the catalog's name/kind" "rows=$rows out=[$out]"
    fi
done

# --- coordinate identity join: non-collapse across ecosystems ---------------
# Counterfactual to the test above: without it, a join that over-eagerly
# folds ecosystems together would pass the taplo assertions too. pipx:pyrefly
# and github:facebook/pyrefly are different identities (see vise/README.md,
# "How the join works") and must stay two separate rows even though one of
# them is installed.
NC_DIR="$(mktemp -d "$BASE/noncollapse.XXXXXX")"
NC_GLOBAL_CFG="$NC_DIR/global.toml"
NC_CATALOG="$NC_DIR/catalog.tsv"
cat >"$NC_CATALOG" <<'EOF'
github:facebook/pyrefly	pyrefly	lsp,linter	python
pipx:pyrefly	pyrefly-pipx	linter	python
EOF
cat >"$NC_DIR/config.json" <<EOF
[{"path": "$NC_GLOBAL_CFG", "tools": ["github:facebook/pyrefly"]}]
EOF
cat >"$NC_DIR/ls.json" <<'EOF'
{"github:facebook/pyrefly": [{"version": "1.1.1", "active": true}]}
EOF
echo '[]' >"$NC_DIR/registry.json"
nc_out=$(cd "$REPO_ROOT" && VISE_CATALOG="$NC_CATALOG" VISE_CONFIG_JSON="$NC_DIR/config.json" \
    VISE_LS_JSON="$NC_DIR/ls.json" VISE_REGISTRY_JSON="$NC_DIR/registry.json" \
    MISE_GLOBAL_CONFIG_FILE="$NC_GLOBAL_CFG" bash "$VISE" list 2>&1)
nc_rows=$(printf '%s\n' "$nc_out" | grep -c .)
gh_row=$(printf '%s\n' "$nc_out" | awk -F'\t' '$1 == "github:facebook/pyrefly"')
pipx_row=$(printf '%s\n' "$nc_out" | awk -F'\t' '$1 == "pipx:pyrefly"')
if [ "$nc_rows" = "2" ] && printf '%s\n' "$gh_row" | grep -qv 'pyrefly-pipx' &&
    printf '%s\n' "$gh_row" | grep -q 'pyrefly' && printf '%s\n' "$pipx_row" | grep -q 'pyrefly-pipx'; then
    ok "join: pipx:pyrefly and github:facebook/pyrefly stay separate rows (no cross-ecosystem collapse)"
else
    bad "join: pipx:pyrefly and github:facebook/pyrefly stay separate rows (no cross-ecosystem collapse)" \
        "rows=$nc_rows gh=[$gh_row] pipx=[$pipx_row]"
fi

# --- coordinate identity join: scope glyphs are config-derived --------------
# Scope (global/project/both/none, and the unavailable ✗ override) must come
# purely from which config file(s) list a coordinate — never from whether
# mise happens to have it installed. Two rows below make that split visible:
# orphan-tool is in `mise ls` but in no config file (○, yet still reports its
# real version), and ghost-tool is the reverse — declared in project config
# but never actually installed (◐, version "-"). A scope computed from
# install state instead of config would get both of these backwards.
SCOPE_DIR="$(mktemp -d "$BASE/scope.XXXXXX")"
SCOPE_GLOBAL_CFG="$SCOPE_DIR/global.toml"
SCOPE_CATALOG="$SCOPE_DIR/catalog.tsv"
cat >"$SCOPE_CATALOG" <<'EOF'
npm:yaml-language-server	yaml-language-server	lsp	yaml
pipx:clang-tidy	clang-tidy	linter	c,cpp
github:koalaman/shellcheck	shellcheck	linter	bash
github:golangci/golangci-lint	golangci-lint	linter	go
unavailable:jdtls-classic	jdtls-classic	lsp	java
cargo:ghost-tool	ghost-tool	linter	rust
pipx:orphan-tool	orphan-tool	formatter	misc
EOF
cat >"$SCOPE_DIR/config.json" <<EOF
[
  {"path": "$SCOPE_GLOBAL_CFG", "tools": ["npm:yaml-language-server", "github:koalaman/shellcheck"]},
  {"path": "$SCOPE_DIR/project.toml", "tools": ["pipx:clang-tidy", "github:koalaman/shellcheck", "cargo:ghost-tool"]}
]
EOF
cat >"$SCOPE_DIR/ls.json" <<'EOF'
{
  "npm:yaml-language-server": [{"version": "1.24.0", "active": true}],
  "pipx:clang-tidy": [{"version": "22.1.8", "active": true}],
  "github:koalaman/shellcheck": [{"version": "0.11.0", "active": true}],
  "pipx:orphan-tool": [{"version": "3.3.3", "active": true}]
}
EOF
echo '[]' >"$SCOPE_DIR/registry.json"

# field 2 is the plain-ASCII scopecode; field 3 is "<glyph> <name>" padded —
# splitting on whitespace lifts just the glyph without slicing the UTF-8
# character, which byte-based substr()/cut would risk.
scope_of_row() { printf '%s\n' "$1" | awk -F'\t' -v c="$2" '$1 == c { print $2 }'; }
glyph_of_row() { printf '%s\n' "$1" | awk -F'\t' -v c="$2" '$1 == c { print $3 }' | awk '{ print $1 }'; }
version_of_row() { printf '%s\n' "$1" | awk -F'\t' -v c="$2" '$1 == c { v = $6; sub(/[ \t]+$/, "", v); print v }'; }

run_scope() {
    PATH="$1" VISE_CATALOG="$SCOPE_CATALOG" VISE_CONFIG_JSON="$SCOPE_DIR/config.json" \
        VISE_LS_JSON="$SCOPE_DIR/ls.json" VISE_REGISTRY_JSON="$SCOPE_DIR/registry.json" \
        MISE_GLOBAL_CONFIG_FILE="$SCOPE_GLOBAL_CFG" bash "$VISE" list 2>&1
}
scope_out="$(cd "$REPO_ROOT" && run_scope "$ORIG_PATH")"

check_scope() {
    local coord="$1" want_scope="$2" want_glyph="$3" label="$4"
    local got_scope got_glyph
    got_scope=$(scope_of_row "$scope_out" "$coord")
    got_glyph=$(glyph_of_row "$scope_out" "$coord")
    if [ "$got_scope" = "$want_scope" ] && [ "$got_glyph" = "$want_glyph" ]; then
        ok "$label"
    else
        bad "$label" "scope=$got_scope glyph=$got_glyph"
    fi
}
check_scope "npm:yaml-language-server" "global" "●" "scope glyph: installed globally shows ●"
check_scope "pipx:clang-tidy" "project" "◐" "scope glyph: installed in this project shows ◐"
check_scope "github:koalaman/shellcheck" "both" "◍" "scope glyph: installed in both configs shows ◍"
check_scope "github:golangci/golangci-lint" "none" "○" "scope glyph: absent from config and mise ls shows ○"
check_scope "unavailable:jdtls-classic" "none" "✗" "scope glyph: unavailable coordinate shows ✗ regardless of scope"

got_v=$(version_of_row "$scope_out" "pipx:orphan-tool")
if [ "$got_v" = "3.3.3" ]; then
    ok "scope is config-derived: absent-from-config tool (○) still reports its real mise-ls version"
else
    bad "scope is config-derived: absent-from-config tool (○) still reports its real mise-ls version" "$got_v"
fi

got_v=$(version_of_row "$scope_out" "cargo:ghost-tool")
if [ "$got_v" = "-" ]; then
    ok "scope is config-derived: declared-but-not-installed tool (◐) reports no version"
else
    bad "scope is config-derived: declared-but-not-installed tool (◐) reports no version" "$got_v"
fi

# --- determinism + hermeticity: same fixtures, twice, with mise unreachable -
# Re-runs the scope fixture above verbatim. run2 (same PATH) proves the join
# is a pure function of its inputs; run3 (mise stripped from PATH entirely)
# proves it never fell through to a real mise call for any of the three
# seams — if it had, run3 would hard-fail with "command not found" instead of
# reproducing run1 byte-for-byte.
scope_out2="$(cd "$REPO_ROOT" && run_scope "$ORIG_PATH")"
if [ "$scope_out2" = "$scope_out" ]; then
    ok "determinism: identical fixtures produce byte-identical output"
else
    bad "determinism: identical fixtures produce byte-identical output" \
        "$(diff <(printf '%s\n' "$scope_out") <(printf '%s\n' "$scope_out2") | head -5)"
fi

scope_out3="$(cd "$REPO_ROOT" && run_scope "$NO_MISE_PATH")"
rc3=$?
if [ "$rc3" -eq 0 ] && [ "$scope_out3" = "$scope_out" ]; then
    ok "hermeticity: same output with mise unreachable on PATH (all three seams cover every mise call render makes)"
else
    bad "hermeticity: same output with mise unreachable on PATH (all three seams cover every mise call render makes)" \
        "rc=$rc3 out=[$scope_out3]"
fi

# vise::preview is explicitly OUT OF SCOPE for the seams/join tests above.
# It calls `mise ls "$coord" 2>/dev/null || true` directly and unseamed — and
# that `|| true` swallows a missing-mise "command not found" (127) the exact
# same way it swallows a genuine "not installed" empty result, so a
# PATH-stripped __preview run would misreport (not installed) as if it were a
# real, verified result. Do not assume the PATH-stripping trick above proves
# __preview is hermetic too — it isn't, and it doesn't.

# --- vise doctor: offline lint over catalog.tsv --------------------------
# Every fixture below is self-contained (own catalog, own registry, own
# overrides) so a check's test can never pass by accident from repo state:
# a fixture catalog's coordinates never appear in the real catalog-overrides
# or registry, so unrelated checks are provably inert on any one fixture.
DOCTOR_DIR="$(mktemp -d "$BASE/doctor.XXXXXX")"
DOCTOR_EMPTY_REGISTRY="$DOCTOR_DIR/empty-registry.json"
echo '[]' >"$DOCTOR_EMPTY_REGISTRY"
DOCTOR_EMPTY_OVERRIDES="$DOCTOR_DIR/empty-overrides.tsv"
: >"$DOCTOR_EMPTY_OVERRIDES"

# 1. column count: NF != 8 on a data row must be caught and named.
COL_CATALOG="$(mktemp -d "$DOCTOR_DIR/columns.XXXXXX")/catalog.tsv"
cat >"$COL_CATALOG" <<'EOF'
npm:good-tool	good-tool	linter	javascript	https://example.com/good	1	2026-01-01	A good row
npm:short-row	short-row	linter	javascript
EOF
out=$(VISE_CATALOG="$COL_CATALOG" VISE_REGISTRY_JSON="$DOCTOR_EMPTY_REGISTRY" \
    VISE_OVERRIDES="$DOCTOR_EMPTY_OVERRIDES" bash "$VISE" doctor 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'column count' &&
    printf '%s\n' "$out" | grep -q 'npm:short-row'; then
    ok "doctor: column count catches a row with the wrong field count"
else
    bad "doctor: column count catches a row with the wrong field count" "rc=$rc out=[$out]"
fi

# 2. empty field: coordinate/name/kind/language ($1..$4) must not be blank.
EMPTY_CATALOG="$(mktemp -d "$DOCTOR_DIR/empty.XXXXXX")/catalog.tsv"
printf 'npm:good-tool\tgood-tool\tlinter\tjavascript\thttps://example.com/good\t1\t2026-01-01\tA good row\n\tno-coord\tlinter\tjavascript\t-\t-\t-\t-\n' >"$EMPTY_CATALOG"
out=$(VISE_CATALOG="$EMPTY_CATALOG" VISE_REGISTRY_JSON="$DOCTOR_EMPTY_REGISTRY" \
    VISE_OVERRIDES="$DOCTOR_EMPTY_OVERRIDES" bash "$VISE" doctor 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'empty field' &&
    printf '%s\n' "$out" | grep -q 'no-coord'; then
    ok "doctor: empty field catches a blank coordinate"
else
    bad "doctor: empty field catches a blank coordinate" "rc=$rc out=[$out]"
fi

# 3. duplicate coordinate: the one confirmed bug (item 3 in the spec) — an
# override-merge collision stamps one coordinate onto two rows under
# different names. This is the check `doctor` exists for.
DUPCOORD_CATALOG="$(mktemp -d "$DOCTOR_DIR/dupcoord.XXXXXX")/catalog.tsv"
cat >"$DUPCOORD_CATALOG" <<'EOF'
npm:unique-tool	unique-tool	linter	javascript	-	-	-	-
dotnet:same-coord	first-name	lsp	csharp	-	-	-	-
dotnet:same-coord	second-name	lsp	csharp	-	-	-	-
EOF
out=$(VISE_CATALOG="$DUPCOORD_CATALOG" VISE_REGISTRY_JSON="$DOCTOR_EMPTY_REGISTRY" \
    VISE_OVERRIDES="$DOCTOR_EMPTY_OVERRIDES" bash "$VISE" doctor 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'duplicate coordinate' &&
    printf '%s\n' "$out" | grep -q 'dotnet:same-coord' &&
    ! printf '%s\n' "$out" | grep -q 'npm:unique-tool'; then
    ok "doctor: duplicate coordinate catches two names sharing one coordinate"
else
    bad "doctor: duplicate coordinate catches two names sharing one coordinate" "rc=$rc out=[$out]"
fi

# 4. duplicate name: regression guard (0 today in the real catalog) — two
# different coordinates sharing one name would confuse the picker's join.
DUPNAME_CATALOG="$(mktemp -d "$DOCTOR_DIR/dupname.XXXXXX")/catalog.tsv"
cat >"$DUPNAME_CATALOG" <<'EOF'
npm:unique-tool	unique-tool	linter	javascript	-	-	-	-
cargo:first-coord	same-name	linter	rust	-	-	-	-
go:second-coord	same-name	linter	go	-	-	-	-
EOF
out=$(VISE_CATALOG="$DUPNAME_CATALOG" VISE_REGISTRY_JSON="$DOCTOR_EMPTY_REGISTRY" \
    VISE_OVERRIDES="$DOCTOR_EMPTY_OVERRIDES" bash "$VISE" doctor 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'duplicate name' &&
    printf '%s\n' "$out" | grep -q 'same-name' &&
    ! printf '%s\n' "$out" | grep -q 'unique-tool'; then
    ok "doctor: duplicate name catches two coordinates sharing one name"
else
    bad "doctor: duplicate name catches two coordinates sharing one name" "rc=$rc out=[$out]"
fi

# 5. dead shorthand: a bare coordinate (no backend prefix) only resolves if
# mise's own registry recognizes it as a shorthand. registry.json here is a
# small filtered subset (per the seam's convention), not a real dump.
SHORTHAND_DIR="$(mktemp -d "$DOCTOR_DIR/shorthand.XXXXXX")"
SHORTHAND_CATALOG="$SHORTHAND_DIR/catalog.tsv"
cat >"$SHORTHAND_CATALOG" <<'EOF'
gofumpt	gofumpt	formatter	go	-	-	-	-
nonexistent-tool	nonexistent-tool	linter	misc	-	-	-	-
EOF
SHORTHAND_REGISTRY="$SHORTHAND_DIR/registry.json"
cat >"$SHORTHAND_REGISTRY" <<'EOF'
[{"short": "gofumpt", "backends": ["go:mvdan.cc/gofumpt/cmd/gofumpt"], "description": "A stricter gofmt"}]
EOF
out=$(VISE_CATALOG="$SHORTHAND_CATALOG" VISE_REGISTRY_JSON="$SHORTHAND_REGISTRY" \
    VISE_OVERRIDES="$DOCTOR_EMPTY_OVERRIDES" bash "$VISE" doctor 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'dead shorthand' &&
    printf '%s\n' "$out" | grep -q 'nonexistent-tool' &&
    ! printf '%s\n' "$out" | grep -q 'gofumpt'; then
    ok "doctor: dead shorthand catches a bare coordinate absent from the registry"
else
    bad "doctor: dead shorthand catches a bare coordinate absent from the registry" "rc=$rc out=[$out]"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
