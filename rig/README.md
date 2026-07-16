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
confirm phase. Registry order: **agent-file → tracker → triage → scratch →
domain**. Idempotency is per-section:

- **agent-file** — ensure the agent file exists, then upsert a marker-wrapped
  `rig:config` block. Neither `AGENTS.md` nor `CLAUDE.md` exists → create a real
  `AGENTS.md` plus a `CLAUDE.md` symlink to it. One already exists → use it,
  never create or overwrite the other. The block is guarded by its markers
  (`<!-- rig:config -->` … `<!-- /rig:config -->`): re-run replaces the marked
  region in place, never duplicating and never touching content outside it.
- **tracker** — write the `tracker:` line into the `rig:config` block. The
  backend is chosen by a `case` seam on `RIG_TRACKER` (default `github`); each
  arm is one small function producing one YAML line, so a new backend is one
  function plus one `case` arm. `github` derives `repo` from the origin remote
  (`owner/name`); `shortcut` records `shortcut_workspace` (the Shortcut token is
  read from `$SHORTCUT_API_TOKEN` at skill-runtime and is **never** stored).
- **triage** — only when a `triage` skill is present, write a `triage.labels`
  map with the five canonical roles (`needs-triage`, `needs-info`,
  `ready-for-agent`, `ready-for-human`, `wontfix`) into the same block; each
  label string defaults to its role name. No triage skill → the `triage:` key is
  omitted entirely.
- **scratch** — provision the fixed scratch root `.tmp/` and git-ignore it via
  the repo's own convention (committed `.gitignore` if present, else
  `.git/info/exclude`). The `.tmp/` line is written under a `# rig:` footprint
  comment so the entry is attributable (parity with the config block's markers),
  and preceded by a newline when the target already has content so a file
  lacking a trailing newline is never corrupted. `git check-ignore` is the
  idempotency guard.
- **domain** — scaffold the domain-doc layout the `domain-modeling` skill fills
  in: single-context (`CONTEXT.md` + `docs/adr/`) by default, or multi-context
  (`CONTEXT-MAP.md` + a per-context `CONTEXT.md` + `docs/adr/`) when a monorepo
  signal is present (`pnpm-workspace.yaml`, a `workspaces` field in
  `package.json`, or a populated `packages/*` with its own `src/`). Files are
  seeded minimal — real content is `domain-modeling`'s job. Existence is the
  idempotency guard: only-if-absent, never clobber.

The `rig:config` block is a single marker-guarded region assembled by one pure,
deterministic function; the block-owning sections re-upsert that content, so a
re-run reproduces it byte-for-byte.

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
  else an existing `CLAUDE.md`). Must resolve within the repo root; an absolute
  or `../` path that escapes it is refused. When forced, rig uses that one file
  and skips the `AGENTS.md` + `CLAUDE.md` symlink default.
- `RIG_TRACKER` — tracker backend: `github` (default) or `shortcut`.
- `RIG_REPO` — override the `github` backend's repo slug (default: from the
  origin remote).
- `RIG_SHORTCUT_WORKSPACE` — workspace for the `shortcut` backend.
- `RIG_SKILLS_DIR` — skills collection to probe for a `triage` skill (default:
  `~/skills`, the skillshare-managed collection).
- `RIG_TRIAGE` — force triage on (`1`) or off (`0`), bypassing detection.

The scratch root is a fixed `.tmp/` — no path override, because that is the name
`write-findings` and the other skills look for.

## Config block

With the `github` backend and a `triage` skill present:

```markdown
<!-- rig:config -->
```yaml
tracker: { backend: github, repo: owner/name }
triage:
  labels:
    needs-triage: needs-triage
    needs-info: needs-info
    ready-for-agent: ready-for-agent
    ready-for-human: ready-for-human
    wontfix: wontfix
```
<!-- /rig:config -->
```

`repo` is detected from `git remote get-url origin` (`unknown` when there is no
remote, keeping the block valid YAML). The `shortcut` backend replaces the
`tracker:` line with `{ backend: shortcut, shortcut_workspace: <ws> }`. The
`triage:` key is present only when a `triage` skill is detected.

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
