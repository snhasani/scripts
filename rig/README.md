# rig

Bootstrap a repo for the agent-skills collection: write the per-repo config the
skills read, in the places they read it.

## Why

Skills like `to-tracker`, `triage`, `code-review`, and `write-findings` expect a
repo to already carry two things: a config block (which tracker + repo) and a
git-ignored scratch root for their disposable state. Wiring that by hand is
ad-hoc and easy to get wrong. `rig` does it in one idempotent, non-destructive
run — headless-driveable, safe to re-run.

Config lives **in the agent file** (`AGENTS.md`/`CLAUDE.md`), which is already
loaded into every agent's context, so the skills read it for free — no extra
file, no extra read.

## Model

Each concern is a **section** — shell functions shaped `detect → draft → apply`
— walked from an ordered registry by the main loop, which supplies the shared
confirm phase. Idempotency is per-section:

- **agent-file** — ensure the agent file exists, then upsert a marker-wrapped
  `rig:config` block. Neither `AGENTS.md` nor `CLAUDE.md` exists → create a real
  `AGENTS.md` plus a `CLAUDE.md` symlink to it. One already exists → use it,
  never create or overwrite the other. The block is guarded by its markers
  (`<!-- rig:config -->` … `<!-- /rig:config -->`): re-run replaces the marked
  region in place, never duplicating and never touching content outside it.
- **scratch** — provision the fixed scratch root `.tmp/` and git-ignore it via
  the repo's own convention (committed `.gitignore` if present, else
  `.git/info/exclude`). `git check-ignore` is the idempotency guard.

All paths resolve under `git rev-parse --show-toplevel`; rig refuses to run
outside a git repo.

## Usage

```sh
rig              # inspect, propose, confirm on a TTY, then write
rig --yes        # headless: accept detected defaults, no prompts
rig --dry-run    # print the intended edits, write nothing
rig --debug      # verbose diagnostics on stderr
rig --help
```

Non-TTY invocation (piped/CI) is headless automatically.

### Env

`RIG_`-namespaced, with detected defaults:

- `RIG_AGENT_FILE` — force which agent file to use/create (default: `AGENTS.md`,
  else an existing `CLAUDE.md`). When forced, rig uses that one file and skips
  the `AGENTS.md` + `CLAUDE.md` symlink default.

The scratch root is a fixed `.tmp/` — no path override, because that is the name
`write-findings` and the other skills look for.

## Config block

```markdown
<!-- rig:config -->
```yaml
tracker: { backend: github, repo: owner/name }
```
<!-- /rig:config -->
```

`repo` is detected from `git remote get-url origin` (`unknown` when there is no
remote, keeping the block valid YAML). The `tracker`/`triage` values are filled
by rig's skill-config sections.

## Test

```sh
bash rig.smoke.sh            # tests ./rig beside it
bash rig.smoke.sh /path/to/rig
```

Drives real `rig` headlessly in throwaway git repos under a sandbox-writable
base. Exit 0 = all green.

## Install

Relative symlink in `bin/` (committed), on `PATH` via the toolbox's one line:

```sh
ln -s ../rig/rig bin/rig
```
