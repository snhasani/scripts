#!/usr/bin/env bash
# Smoke test for sancla. Exercises the strip / keep-exception logic via
# SANCLA_DEBUG (no Claude launch), plus one real launch if `claude` is present.
#
# Usage: bash sancla.smoke.sh [path-to-sancla]   (defaults to ./sancla beside this file)

set -uo pipefail

SANCLA="${1:-$(cd "$(dirname "$0")" && pwd)/sancla}"
[ -f "$SANCLA" ] || {
	printf 'sancla not found at %s\n' "$SANCLA" >&2
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
	printf '       got: %s\n' "$2"
	fail=$((fail + 1))
}
has() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac } # word membership

# Run sancla in debug with the given NAME=val assignments; return its output.
dbg() { env "$@" SANCLA_DEBUG=1 bash "$SANCLA"; }
# Pull the 'stripped:' / 'kept-exc:' name lists out of a debug run.
strip_of() { printf '%s\n' "$1" | sed -n 's/^stripped: //p'; }
kept_of() { printf '%s\n' "$1" | sed -n 's/^kept-exc: //p'; }

printf 'smoke: %s\n' "$SANCLA"

# 1. a secret-looking var is stripped
out=$(dbg FOO_TOKEN=x)
if has "$(strip_of "$out")" FOO_TOKEN; then
	ok "strips secret-looking name (FOO_TOKEN)"
else
	bad "strips secret-looking name (FOO_TOKEN)" "$(strip_of "$out")"
fi

# 2. a plain var passes through (not stripped)
out=$(dbg PLAIN_VAR=x)
if has "$(strip_of "$out")" PLAIN_VAR; then
	bad "passes plain name through (PLAIN_VAR)" "$(strip_of "$out")"
else
	ok "passes plain name through (PLAIN_VAR)"
fi

# 3. mixed: secret stripped, sibling plain var kept, in one run
out=$(dbg SECRET_X=1 NORMAL_Y=1)
if has "$(strip_of "$out")" SECRET_X && ! has "$(strip_of "$out")" NORMAL_Y; then
	ok "mixed run: SECRET_X stripped, NORMAL_Y kept"
else
	bad "mixed run: SECRET_X stripped, NORMAL_Y kept" "$(strip_of "$out")"
fi

# 4. several patterns all match
out=$(dbg A_SECRET=1 B_PASSWORD=1 C_API_KEY=1 D_CREDENTIAL=1)
s=$(strip_of "$out")
if has "$s" A_SECRET && has "$s" B_PASSWORD && has "$s" C_API_KEY && has "$s" D_CREDENTIAL; then
	ok "multiple patterns (SECRET/PASSWORD/API_KEY/CREDENTIAL)"
else
	bad "multiple patterns (SECRET/PASSWORD/API_KEY/CREDENTIAL)" "$s"
fi

# 5. matching is case-insensitive (lowercase var name)
out=$(dbg authtoken=1)
if has "$(strip_of "$out")" authtoken; then
	ok "case-insensitive match (authtoken)"
else
	bad "case-insensitive match (authtoken)" "$(strip_of "$out")"
fi

# 6. SANCLA_KEEP exception spares a matching var
out=$(dbg FOO_TOKEN=x SANCLA_KEEP=FOO_TOKEN)
if ! has "$(strip_of "$out")" FOO_TOKEN && has "$(kept_of "$out")" FOO_TOKEN; then
	ok "SANCLA_KEEP exception spares FOO_TOKEN"
else
	bad "SANCLA_KEEP exception spares FOO_TOKEN" "strip=[$(strip_of "$out")] kept=[$(kept_of "$out")]"
fi

# 7. real launch (only if claude is installed): version prints, exits 0
if command -v claude >/dev/null 2>&1; then
	ver=$(env PROBE_TOKEN=x bash "$SANCLA" --version 2>/dev/null)
	case "$ver" in
	*Claude\ Code*) ok "real launch: sancla --version -> $ver" ;;
	*) bad "real launch: sancla --version" "$ver" ;;
	esac
else
	printf '  \033[33mskip\033[0m real launch (claude not on PATH)\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
