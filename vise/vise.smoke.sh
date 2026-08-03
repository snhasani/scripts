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

# --- override merge: seam parity ---------------------------------------------
# vise::merge_overrides is vise::sync's override-merge step pulled out into
# its own function, driven here through __merge-overrides instead of a real
# sync (network, rewrites the committed catalog.tsv). These two cases are the
# shapes the merge has always handled: an override matching an existing row
# by name rewrites that row, and an override matching nothing appends as a
# synthetic row with metadata columns "-". A pass-through row (no matching
# override at all) must survive untouched.
MERGE_DIR="$(mktemp -d "$BASE/merge-seam.XXXXXX")"
MERGE_BASE="$MERGE_DIR/base.tsv"
cat >"$MERGE_BASE" <<'EOF'
npm:old-coord	renamed-tool	linter	javascript	https://example.com/old	10	2026-01-01	Old description
npm:untouched	untouched-tool	linter	javascript	https://example.com/untouched	5	2026-01-01	Untouched
EOF
MERGE_OVERRIDES="$MERGE_DIR/overrides.tsv"
cat >"$MERGE_OVERRIDES" <<'EOF'
npm:new-coord	renamed-tool	lsp	typescript
dotnet:brand-new	brand-new-tool	lsp	csharp
EOF
merge_out=$(bash "$VISE" __merge-overrides "$MERGE_BASE" "$MERGE_OVERRIDES" 2>&1)
if printf '%s\n' "$merge_out" | grep -qx $'npm:new-coord\trenamed-tool\tlsp\ttypescript\thttps://example.com/old\t10\t2026-01-01\tOld description'; then
    ok "merge seam: override matching an existing row's name rewrites it in place"
else
    bad "merge seam: override matching an existing row's name rewrites it in place" "$merge_out"
fi
if printf '%s\n' "$merge_out" | grep -qx $'dotnet:brand-new\tbrand-new-tool\tlsp\tcsharp\t-\t-\t-\t-'; then
    ok "merge seam: override matching nothing appends as a synthetic row"
else
    bad "merge seam: override matching nothing appends as a synthetic row" "$merge_out"
fi
if printf '%s\n' "$merge_out" | grep -qx $'npm:untouched\tuntouched-tool\tlinter\tjavascript\thttps://example.com/untouched\t5\t2026-01-01\tUntouched'; then
    ok "merge seam: a row with no matching override passes through unchanged"
else
    bad "merge seam: a row with no matching override passes through unchanged" "$merge_out"
fi

# --- override merge: a renaming override must not fork a duplicate ----------
# The confirmed bug (spec item 3): the merge matches an override to a base
# row by NAME. An override that RENAMES an existing row — its own coordinate
# already equals that row's coordinate, but its name differs — finds no name
# match, so the row passes through untouched and the override's own
# coordinate is appended below as a second, mostly blank row: two rows
# sharing one coordinate. Real instance: dotnet:csharp-ls's Mason row is
# named "csharp-language-server"; catalog-overrides.tsv renames it to
# "csharp-ls", and today that produces exactly this fork.
FORK_DIR="$(mktemp -d "$BASE/merge-fork.XXXXXX")"
FORK_BASE="$FORK_DIR/base.tsv"
cat >"$FORK_BASE" <<'EOF'
dotnet:csharp-ls	csharp-language-server	lsp	c#	https://github.com/razzmatazz/csharp-language-server	960	2026-07-25	Roslyn-based LSP language server for C#.
EOF
FORK_OVERRIDES="$FORK_DIR/overrides.tsv"
cat >"$FORK_OVERRIDES" <<'EOF'
dotnet:csharp-ls	csharp-ls	lsp	csharp
EOF
fork_out=$(bash "$VISE" __merge-overrides "$FORK_BASE" "$FORK_OVERRIDES" 2>&1)
fork_rows=$(printf '%s\n' "$fork_out" | awk -F'\t' '$1 == "dotnet:csharp-ls"' | grep -c .)
if [ "$fork_rows" = "1" ]; then
    ok "merge: a renaming override rewrites the existing row instead of forking a duplicate coordinate"
else
    bad "merge: a renaming override rewrites the existing row instead of forking a duplicate coordinate" "$fork_out"
fi
if printf '%s\n' "$fork_out" | grep -qx $'dotnet:csharp-ls\tcsharp-ls\tlsp\tcsharp\thttps://github.com/razzmatazz/csharp-language-server\t960\t2026-07-25\tRoslyn-based LSP language server for C#.'; then
    ok "merge: the rewritten row keeps the catalog's homepage/stars/updated/description"
else
    bad "merge: the rewritten row keeps the catalog's homepage/stars/updated/description" "$fork_out"
fi

# Control: an override matching no row by name OR coordinate is genuinely
# new and must still append as its own synthetic row — the fix has to tell
# "renaming an existing row" apart from "adding a new one" by coordinate,
# not swallow every unmatched-by-name override into whatever row comes first.
cat >"$FORK_OVERRIDES" <<'EOF'
dotnet:csharp-ls	csharp-ls	lsp	csharp
npm:brand-new-tool	brand-new-tool	linter	javascript
EOF
new_out=$(bash "$VISE" __merge-overrides "$FORK_BASE" "$FORK_OVERRIDES" 2>&1)
if printf '%s\n' "$new_out" | grep -qx $'npm:brand-new-tool\tbrand-new-tool\tlinter\tjavascript\t-\t-\t-\t-'; then
    ok "merge: an override matching no existing coordinate still appends as a synthetic row"
else
    bad "merge: an override matching no existing coordinate still appends as a synthetic row" "$new_out"
fi

# Invariant: whatever the merge produces, no two rows may ever share a
# coordinate — this is exactly what vise doctor's duplicate-coordinate check
# guards in the real catalog after every sync.
dup_coords=$(printf '%s\n' "$new_out" | awk -F'\t' '{print $1}' | sort | uniq -d)
if [ -z "$dup_coords" ]; then
    ok "merge: no two output rows share a coordinate"
else
    bad "merge: no two output rows share a coordinate" "$dup_coords"
fi

# --- override merge: an override ambiguous across two different base rows --
# The double-apply bug: an override whose own COORDINATE equals one base
# row's coordinate, while its own NAME equals a DIFFERENT base row's name,
# used to fire the name-match branch on the first row AND the coordinate-
# match branch on the second, independently — one row renamed onto the
# override's coordinate, the other's coordinate rewritten to that same
# value, landing both on it. There is no way to tell from the override alone
# which row it meant, so neither may be touched; this must be reported, not
# guessed.
AMBIG_DIR="$(mktemp -d "$BASE/merge-ambiguous.XXXXXX")"
AMBIG_BASE="$AMBIG_DIR/base.tsv"
cat >"$AMBIG_BASE" <<'EOF'
alpha	mytool	lsp	go	https://a	1	2026-01-01	A row
zeta	other	lsp	go	https://b	2	2026-01-02	B row
EOF
AMBIG_OVERRIDES="$AMBIG_DIR/overrides.tsv"
cat >"$AMBIG_OVERRIDES" <<'EOF'
zeta	mytool	linter	rust
EOF
ambig_out=$(bash "$VISE" __merge-overrides "$AMBIG_BASE" "$AMBIG_OVERRIDES" 2>"$AMBIG_DIR/err")
ambig_rc=$?
ambig_dupcoord=$(printf '%s\n' "$ambig_out" | awk -F'\t' '{print $1}' | sort | uniq -d)
if [ "$ambig_rc" -ne 0 ] && [ -z "$ambig_dupcoord" ] &&
    printf '%s\n' "$ambig_out" | grep -qx $'alpha\tmytool\tlsp\tgo\thttps://a\t1\t2026-01-01\tA row' &&
    printf '%s\n' "$ambig_out" | grep -qx $'zeta\tother\tlsp\tgo\thttps://b\t2\t2026-01-02\tB row' &&
    grep -q '.' "$AMBIG_DIR/err"; then
    ok "merge: an override ambiguous across two base rows touches neither, reports, and exits nonzero"
else
    bad "merge: an override ambiguous across two base rows touches neither, reports, and exits nonzero" \
        "rc=$ambig_rc out=[$ambig_out] err=[$(cat "$AMBIG_DIR/err")]"
fi

# --- override merge: two different overrides converging on one base row ----
# The same collision from the other direction: override A matches a row by
# name, override B independently matches the SAME row by coordinate.
# Whichever applied would silently discard the other's intent, so neither
# may apply — and the row must survive untouched, not half-mutated.
COLLIDE_DIR="$(mktemp -d "$BASE/merge-collide.XXXXXX")"
COLLIDE_BASE="$COLLIDE_DIR/base.tsv"
cat >"$COLLIDE_BASE" <<'EOF'
npm:shared-coord	shared-name	linter	javascript	https://c	3	2026-01-03	C row
EOF
COLLIDE_OVERRIDES="$COLLIDE_DIR/overrides.tsv"
cat >"$COLLIDE_OVERRIDES" <<'EOF'
npm:from-name-override	shared-name	lsp	typescript
npm:shared-coord	renamed-by-coord	lsp	typescript
EOF
collide_out=$(bash "$VISE" __merge-overrides "$COLLIDE_BASE" "$COLLIDE_OVERRIDES" 2>"$COLLIDE_DIR/err")
collide_rc=$?
collide_rows=$(printf '%s\n' "$collide_out" | grep -c .)
if [ "$collide_rc" -ne 0 ] && [ "$collide_rows" = "1" ] &&
    printf '%s\n' "$collide_out" | grep -qx $'npm:shared-coord\tshared-name\tlinter\tjavascript\thttps://c\t3\t2026-01-03\tC row' &&
    grep -q '.' "$COLLIDE_DIR/err"; then
    ok "merge: two overrides converging on one base row touch neither, report, and exit nonzero"
else
    bad "merge: two overrides converging on one base row touch neither, report, and exit nonzero" \
        "rc=$collide_rc rows=$collide_rows out=[$collide_out] err=[$(cat "$COLLIDE_DIR/err")]"
fi

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

# 6. wrongly excluded: an `unavailable:` row means "Mason lists it but mise
# has no backend". If mise's registry actually has a shorthand for that
# exact name, the exclusion is stale and the row should be installable.
EXCLUDED_DIR="$(mktemp -d "$DOCTOR_DIR/excluded.XXXXXX")"
EXCLUDED_CATALOG="$EXCLUDED_DIR/catalog.tsv"
cat >"$EXCLUDED_CATALOG" <<'EOF'
unavailable:genuinely-unsupported	genuinely-unsupported	linter	misc	-	-	-	-
unavailable:gofumpt	gofumpt	formatter	go	-	-	-	-
EOF
EXCLUDED_REGISTRY="$EXCLUDED_DIR/registry.json"
cat >"$EXCLUDED_REGISTRY" <<'EOF'
[{"short": "gofumpt", "backends": ["go:mvdan.cc/gofumpt/cmd/gofumpt"], "description": "A stricter gofmt"}]
EOF
out=$(VISE_CATALOG="$EXCLUDED_CATALOG" VISE_REGISTRY_JSON="$EXCLUDED_REGISTRY" \
    VISE_OVERRIDES="$DOCTOR_EMPTY_OVERRIDES" bash "$VISE" doctor 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'wrongly excluded' &&
    printf '%s\n' "$out" | grep -q 'gofumpt' &&
    ! printf '%s\n' "$out" | grep -q 'genuinely-unsupported'; then
    ok "doctor: wrongly excluded catches an unavailable row that mise can actually install"
else
    bad "doctor: wrongly excluded catches an unavailable row that mise can actually install" "rc=$rc out=[$out]"
fi

# 7. dead override, split by coordinate: sync merges catalog-overrides.tsv
# onto the Mason-derived base by name; an override whose name matches
# nothing there becomes a synthetic row instead — homepage and description
# both stamped "-" (see vise::sync's END block). That shape alone is not a
# bug: catalog-overrides.tsv deliberately adds tools Mason never lists at
# all (npm:eslint, npm:typescript, pipx:clang-tidy in the live catalog), and
# every one of those is a synthetic row by design. The real bug is narrower —
# an override's coordinate landing on one that ALREADY belongs to a
# different row, forking it — so the check is split by whether that
# coordinate is otherwise unique in the catalog.

# 7a. brand-new coordinate: the override's synthetic row is the ONLY row at
# that coordinate. A deliberate addition, not a bug — silent, like the 3
# live ones above. A real (non-synthetic-shaped) override-matched row is the
# control, same as before.
NEWCOORD_DIR="$(mktemp -d "$DOCTOR_DIR/newcoord.XXXXXX")"
NEWCOORD_CATALOG="$NEWCOORD_DIR/catalog.tsv"
cat >"$NEWCOORD_CATALOG" <<'EOF'
dotnet:brand-new-tool	brand-new-tool	lsp	csharp	-	-	-	-
npm:live-tool	live-tool	linter	javascript	https://example.com/live	42	2026-01-01	A real Mason description
EOF
NEWCOORD_FILE="$NEWCOORD_DIR/overrides.tsv"
cat >"$NEWCOORD_FILE" <<'EOF'
dotnet:brand-new-tool	brand-new-tool	lsp	csharp
npm:live-tool	live-tool	linter	javascript
EOF
out=$(VISE_CATALOG="$NEWCOORD_CATALOG" VISE_REGISTRY_JSON="$DOCTOR_EMPTY_REGISTRY" \
    VISE_OVERRIDES="$NEWCOORD_FILE" bash "$VISE" doctor 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    ok "doctor: dead override stays silent when the synthetic row's coordinate is new"
else
    bad "doctor: dead override stays silent when the synthetic row's coordinate is new" "rc=$rc out=[$out]"
fi

# 7b. forking coordinate: the override's synthetic row shares its coordinate
# with a second, different row that already owns it — the actual bug this
# check exists to catch.
FORKCOORD_DIR="$(mktemp -d "$DOCTOR_DIR/forkcoord.XXXXXX")"
FORKCOORD_CATALOG="$FORKCOORD_DIR/catalog.tsv"
cat >"$FORKCOORD_CATALOG" <<'EOF'
dotnet:dead-tool	dead-tool	lsp	csharp	-	-	-	-
dotnet:dead-tool	other-name	lsp	csharp	https://example.com/other	7	2026-01-01	Already owns this coordinate
npm:live-tool	live-tool	linter	javascript	https://example.com/live	42	2026-01-01	A real Mason description
EOF
FORKCOORD_FILE="$FORKCOORD_DIR/overrides.tsv"
cat >"$FORKCOORD_FILE" <<'EOF'
dotnet:dead-tool	dead-tool	lsp	csharp
npm:live-tool	live-tool	linter	javascript
EOF
out=$(VISE_CATALOG="$FORKCOORD_CATALOG" VISE_REGISTRY_JSON="$DOCTOR_EMPTY_REGISTRY" \
    VISE_OVERRIDES="$FORKCOORD_FILE" bash "$VISE" doctor 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'dead override' &&
    printf '%s\n' "$out" | grep -q 'dead-tool' &&
    printf '%s\n' "$out" | grep -q 'forks' &&
    ! printf '%s\n' "$out" | grep -q 'live-tool'; then
    ok "doctor: dead override errors when the synthetic row's coordinate forks an existing row"
else
    bad "doctor: dead override errors when the synthetic row's coordinate forks an existing row" "rc=$rc out=[$out]"
fi

# 8. coord syntax: several distinct malformations, one check. The npm scoped
# control row (a real catalog.tsv shape: npm:@angular/language-server) must
# survive untouched — an "@" is legitimate right after the backend prefix,
# only a *trailing* "@version" left over from PURL parsing is the bug.
SYNTAX_CATALOG="$(mktemp -d "$DOCTOR_DIR/syntax.XXXXXX")/catalog.tsv"
# A scope starting with a digit (a real one: @1password) would look like a
# leftover version to a naive split-on-"@" that ignores position.
cat >"$SYNTAX_CATALOG" <<'EOF'
npm:@angular/language-server	scoped-ok	lsp	typescript	-	-	-	-
npm:@1password/op-cli	scoped-digit-ok	lsp	shell	-	-	-	-
npm:has%40escape	has-escape	linter	javascript	-	-	-	-
npm:has space	has-space	linter	javascript	-	-	-	-
npm::doublecolon	doublecolon	linter	javascript	-	-	-	-
:leadingcolon	leadingcolon	linter	javascript	-	-	-	-
trailingcolon:	trailingcolon	linter	javascript	-	-	-	-
cargo:leftover@1.2.3	leftover	linter	rust	-	-	-	-
github:noslash	noslash	lsp	go	-	-	-	-
github:owner/repo/extra	extraslash	lsp	go	-	-	-	-
EOF
out=$(VISE_CATALOG="$SYNTAX_CATALOG" VISE_REGISTRY_JSON="$DOCTOR_EMPTY_REGISTRY" \
    VISE_OVERRIDES="$DOCTOR_EMPTY_OVERRIDES" bash "$VISE" doctor 2>&1)
rc=$?
bad_row_count=$(printf '%s\n' "$out" | grep -c 'coord syntax')
if [ "$rc" -ne 0 ] && [ "$bad_row_count" = "8" ] &&
    ! printf '%s\n' "$out" | grep -q 'scoped-ok' &&
    ! printf '%s\n' "$out" | grep -q 'scoped-digit-ok'; then
    ok "doctor: coord syntax catches malformed coordinates, spares a legit npm scope"
else
    bad "doctor: coord syntax catches malformed coordinates, spares a legit npm scope" \
        "rc=$rc bad_row_count=$bad_row_count out=[$out]"
fi

# 9. kind domain: $3 is a comma-split list; every member must be one of
# lsp/linter/formatter. A multi-kind row (lsp,linter,formatter) is the
# control — comma-splitting must not itself be mistaken for the bug.
KIND_CATALOG="$(mktemp -d "$DOCTOR_DIR/kind.XXXXXX")/catalog.tsv"
cat >"$KIND_CATALOG" <<'EOF'
npm:multi-kind-ok	multi-kind-ok	lsp,linter,formatter	javascript	-	-	-	-
npm:bad-kind	bad-kind	linter,runtime	javascript	-	-	-	-
EOF
out=$(VISE_CATALOG="$KIND_CATALOG" VISE_REGISTRY_JSON="$DOCTOR_EMPTY_REGISTRY" \
    VISE_OVERRIDES="$DOCTOR_EMPTY_OVERRIDES" bash "$VISE" doctor 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'kind domain' &&
    printf '%s\n' "$out" | grep -q 'bad-kind' &&
    ! printf '%s\n' "$out" | grep -q 'multi-kind-ok'; then
    ok "doctor: kind domain catches a kind outside lsp/linter/formatter"
else
    bad "doctor: kind domain catches a kind outside lsp/linter/formatter" "rc=$rc out=[$out]"
fi

# 10. field shape: stars ($6) is numeric-or-"-"; updated ($7) is
# YYYY-MM-DD-or-"-". A clean row with real stars/date is the control.
SHAPE_CATALOG="$(mktemp -d "$DOCTOR_DIR/shape.XXXXXX")/catalog.tsv"
cat >"$SHAPE_CATALOG" <<'EOF'
npm:shape-ok	shape-ok	linter	javascript	https://example.com/ok	42	2026-01-01	Fine
npm:bad-stars	bad-stars	linter	javascript	-	not-a-number	-	Bad stars
npm:bad-date	bad-date	linter	javascript	-	-	01/01/2026	Bad date
EOF
out=$(VISE_CATALOG="$SHAPE_CATALOG" VISE_REGISTRY_JSON="$DOCTOR_EMPTY_REGISTRY" \
    VISE_OVERRIDES="$DOCTOR_EMPTY_OVERRIDES" bash "$VISE" doctor 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'field shape' &&
    printf '%s\n' "$out" | grep -q 'bad-stars' &&
    printf '%s\n' "$out" | grep -q 'bad-date' &&
    ! printf '%s\n' "$out" | grep -q 'shape-ok'; then
    ok "doctor: field shape catches malformed stars and updated-date columns"
else
    bad "doctor: field shape catches malformed stars and updated-date columns" "rc=$rc out=[$out]"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
