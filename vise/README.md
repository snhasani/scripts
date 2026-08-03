# vise

Mason-like fzf picker over mise-managed LSPs, linters and formatters.

## Why

Editor tooling (LSPs, linters, formatters) is scattered across package
ecosystems (npm, go, pipx, cargo, aqua, ubi, …) with no single place to browse
what exists, see what is installed, or install/remove it. mise already has
backends for all of these; `vise` is a picker on top: one catalog, one key to
install globally or per-project, one key to remove or upgrade. The picker
itself is entirely offline — `vise sync` is the only command that touches the
network.

## Usage

```sh
vise                # fzf TUI
vise -l | list       # plain rows, no fzf
vise -s | sync       # rebuild catalog.tsv (needs network)
vise doctor          # lint catalog.tsv offline; nonzero exit if broken
vise -h | --help     # full reference

-v  | --verbose      # log what is happening
-vv | --debug        # plus timings and counts
```

## Keys

| key | does |
|---|---|
| `ctrl-g` | install to global config |
| `ctrl-t` | install to this project |
| `ctrl-x` | remove (resolves each tool's own scope) |
| `ctrl-u` | upgrade |
| `ctrl-o` | open the tool's homepage in a browser |
| `ctrl-s` | cycle scope: all → global → project → all |
| `ctrl-a` | toggle tooling-only / everything (starts tooling-only) |
| `ctrl-r` | reload |

`ctrl-s` and `ctrl-a` are independent — they compose.

The prompt shows the active mode: `vise all> `, `vise global> `,
`vise project +tooling> `.

`tab` multi-selects. All actions apply to the whole selection.

## Glyphs

`●` global · `◐` this project · `◍` both · `○` not installed · `✗` no mise
backend (listed for parity; install is refused with a reason)

## Files

- `vise` — the script. bash + fzf + jq + mise, nothing else.
- `catalog.tsv` — **the default catalog, generated and committed** so a fresh
  clone works offline. Every LSP, linter and formatter in the Mason registry,
  with the overrides merged over the top. Do not hand-edit — rebuild with
  `vise sync`, the only command that touches the network.
- `catalog-overrides.tsv` — hand-curated rows that win the merge, for tools
  whose upstream coordinate mise cannot install. 4 columns: `coordinate <TAB>
  name <TAB> kind <TAB> language`. `#` comments allowed. This is the file you
  edit.

### How the join works

The same tool is spelled differently per backend: `aqua:tamasfe/taplo`,
`github:tamasfe/taplo` and the bare shorthand `taplo` are one tool. Rows are
joined on an ecosystem+identity key, not the coordinate string, so all three
collapse to one row. `aqua:` and `ubi:` both resolve to GitHub repos and fold
into `gh`. A bare shorthand's identity comes from its `mise registry` backends.

The row keeps the coordinate you actually installed with, so remove and
upgrade act on the real config entry.

Not covered: the same tool distributed through two ecosystems. `pipx:pyrefly`
and `github:facebook/pyrefly` are different identities and stay separate. That
needs an explicit alias, not normalisation.

Add a tool by appending a row to `catalog-overrides.tsv`. That is the whole
update path.

### How `doctor` works

`vise doctor` is a single offline pass over `catalog.tsv` plus the local
`mise registry --json` — no network, no `mise ls-remote`. Ten checks, silent
and exit 0 on a clean catalog, otherwise every violation printed and a
nonzero exit:

| check | catches |
|---|---|
| column count | a row with other than 8 tab-separated fields |
| empty field | a blank coordinate, name, kind or language |
| duplicate coordinate | two names sharing one coordinate (an override-merge collision — see below) |
| duplicate name | two coordinates sharing one name |
| dead shorthand | a bare coordinate (no `backend:` prefix) absent from `mise registry`'s shorthands |
| wrongly excluded | an `unavailable:` row whose name is actually a `mise registry` shorthand |
| dead override | a `catalog-overrides.tsv` row that matched nothing and forks a coordinate an existing row already owns (a genuinely new coordinate — a deliberate addition — is silent) |
| coord syntax | a literal `%40`, whitespace, `::`, a leading/trailing `:`, a leftover `@version`, or a malformed `github:` owner/repo |
| kind domain | a kind outside `lsp`/`linter`/`formatter` |
| field shape | stars not numeric-or-`-`, or updated not `YYYY-MM-DD`-or-`-` |

Not checked: whether a coordinate actually resolves (Mason's `bin` vs. its
PURL, or `mise ls-remote`) — deciding that needs the network and is a
separate, opt-in mode.

`mise run test` runs `vise doctor` after the smoke suite, so a broken
catalog fails the repo's test task even when every smoke assertion passes.

### `vise.pty.sh` — the fzf key bindings themselves

`vise.smoke.sh` drives every `__*` handler directly; it never presses a real
key inside a real fzf process, so fzf's own `{+1}`/`{1}..{10}` placeholder
expansion, `execute()` vs `execute-silent()`, and `reload()`/`transform-
prompt()` chaining were never exercised end-to-end — exactly where the
empty-selection bulk-upgrade bug lived. `vise.pty.sh` opens the real picker
inside a real `tmux` pty and presses keys.

Covered, each with a killed mutant: `ctrl-a`, `ctrl-s`, `ctrl-o`, `ctrl-r`,
`ctrl-g`, `ctrl-t`, `ctrl-x`, `ctrl-u`. The last four's post-action pause
(the `read` that holds mise's output on screen — see "Keys" above) used to
never actually pause: fzf runs `execute()` via `$SHELL -c`, and under a zsh
login shell `read -p` means "read from a coprocess", not "print a prompt",
so it errored and returned instantly regardless of stdin — and even under
bash, `execute()`'s child inherits fzf's own stdin, which is the pipe
`vise::render` feeds fzf, already at EOF. Both are fixed by routing the pause
through a real `__pause` subcommand (always runs under vise's own bash, and
reads `</dev/tty`) instead of inlining `read` in the bind string. See the
file's header comment for the full trail, including why `ctrl-u` on a
zero-match filter still can't be driven through the exact code path
originally expected (fzf itself now skips that execute() outright — a
stronger guarantee, verified live, than the one the bug report assumed).

Not run by `mise run test` — starts a real fzf per case, an order of
magnitude slower than the rest of the suite, and needs `tmux` + `fzf`
installed. Opt in with `mise run test-pty` or `bash vise/vise.pty.sh`.

## Env

- `VISE_DRY_RUN=1` — print mise commands instead of running them.
- `VISE_FILTER=all` — widen `list`/the picker to every mise-managed tool.
  Default is `tooling`, which hides rows absent from the catalog (runtimes,
  package managers, anything not an LSP/linter/formatter).
- `VISE_SCOPE=global|project` — start in that scope view.
- `VISE_CATALOG=<path>` — use a different catalog.
- `VISE_OVERRIDES=<path>` — use a different overrides file during sync.
- `VISE_CACHE=<dir>` — cache location (default
  `${XDG_CACHE_HOME:-~/.cache}/vise`).
- `VISE_NO_GH=1` — skip GitHub stars/last-push during sync.
- `VISE_PREVIEW_POS=up` — move the detail pane above the list, which puts the
  key guide on the literal bottom row. Default is `down`.

Test seams, not user-facing config — a fixture file stands in for the
matching `mise ... --json` call, used by `vise.smoke.sh`:

- `VISE_CONFIG_JSON=<path>` — replaces `mise config ls --json`.
- `VISE_LS_JSON=<path>` — replaces `mise ls --json`.
- `VISE_REGISTRY_JSON=<path>` — replaces `mise registry --json`.
- `VISE_PREVIEW_LS_TEXT=<path>` — replaces `mise ls -- <coord>` inside the
  preview pane. Plain text, not JSON — `mise ls` without `--json` has a
  different shape than `VISE_LS_JSON`'s fixtures.

## Install

Relative symlink in `bin/` (committed), on `PATH` via the toolbox's one line:

```sh
ln -s ../vise/vise bin/vise
```
