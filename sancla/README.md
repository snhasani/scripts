# sancla

Launch Claude Code with secret-looking environment variables stripped.

## Why

Claude Code inherits the launching shell's full environment — including launchd
session vars (`launchctl setenv`) — and passes it to every Bash subprocess. A
`SessionStart` scrub hook runs too late to stop launchd-injected secrets. `sancla`
cleans the environment *at launch*, before `claude` starts, so subprocesses never
see the stripped vars.

Scope: **environment hygiene only**. The OS sandbox (filesystem/network) and the
auto-mode classifier are the real guards against misuse. This is a light layer,
not a wall.

## Model

Pass-through **denylist**:

1. Inherit the full shell environment (new vars your tools inject just work).
2. `unset` any var whose **name** matches a `BLOCK` word
   (TOKEN, SECRET, PASSWORD, API_KEY, CREDENTIAL, …).
3. `KEEP` = exact names spared even if they match — for keys an agent needs.
4. `exec claude` with the cleaned environment.

Accepted trade-off: a secret whose name contains no common word (e.g.
`ACME_DEPLOY_XYZ`) passes through. The sandbox + network limit contain it.

## Usage

```sh
sancla                       # normal launch
SANCLA_KEEP="OPENAI_API_KEY" sancla   # keep a needed key for this launch
SANCLA_DEBUG=1 sancla        # print strip/keep decisions (names only), don't launch
```

Permanent exceptions: add names to the `KEEP=( )` array in the script.
Permission mode is not set here — it comes from your Claude Code settings
(`defaultMode`).

## Test

```sh
bash sancla.smoke.sh            # tests ./sancla beside it
bash sancla.smoke.sh /path/to/sancla
```

Exit 0 = all green. Covers strip, pass-through, keep-exception, case-insensitivity,
multiple patterns, and a real `--version` launch.

## Install

Symlink onto `PATH` (edit-in-repo → instantly live, no deploy step):

```sh
ln -s "$PWD/sancla" ~/.local/bin/sancla
```
