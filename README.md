# scripts

Personal Unix toolbox. Each tool lives in its own subdirectory with its
implementation, tests, and README. `bin/` holds relative symlinks to each tool's
entrypoint and is the single directory placed on `PATH`.

## Layout

```
bin/            # on PATH — relative symlinks to entrypoints only
<tool>/         # one dir per tool: impl + tests + README
```

## Tools

- **sancla** — launch Claude Code with secret-looking env vars stripped.

## Install

```sh
git clone git@github.com:snhasani/scripts.git ~/workspace/lab/scripts
# add to your shell rc (config, keep it in your dotfiles):
export PATH="$HOME/workspace/lab/scripts/bin:$PATH"
```

Symlinks in `bin/` are relative and committed, so a fresh clone works with no
per-tool setup — just the one `PATH` line.

## Add a tool

```sh
mkdir mytool
# add mytool/mytool (+x), mytool/README.md, tests
ln -s ../mytool/mytool bin/mytool
```

## Development

Tooling is pinned with [mise](https://mise.jdx.dev) and formatting runs on commit
via [lefthook](https://lefthook.dev):

```sh
mise install     # shfmt, shellcheck, lefthook at the versions in mise.toml
lefthook install # install the pre-commit hook
```

Tasks (shell scripts are selected by shebang + `*.sh`; `bin/` symlinks are skipped):

```sh
mise run fmt   # format in place (shfmt -w)
mise run lint  # shellcheck
mise run test  # run every *.smoke.sh with bash
```

`pre-commit` formats staged shell scripts with `mise run fmt` and re-stages them,
so what gets committed is always formatted. Lint and test run in CI.
