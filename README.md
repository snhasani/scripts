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
