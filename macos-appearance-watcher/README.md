# macos-appearance-watcher

Keep tmux (and anything reading its state file) synced with macOS light/dark
appearance, live — including transitions that happen while nothing was attached
to observe them.

## Why

tmux's `client-light-theme`/`client-dark-theme` hooks are push-only: they fire
only on a live transition observed by an attached, subscribed client (via DEC
mode 2031, relayed through the terminal). If the OS appearance flips while no
such client is attached — a session left running unfocused, or created earlier
in a different mode — the hook never fires. Reloading tmux config or restarting
a shell doesn't retroactively trigger it either; nothing replays a transition
that already happened.

This script sidesteps the relay entirely: it watches macOS's own appearance
notification directly (via `dark-notify`, which also reports the *current* mode
immediately on start, not just future changes) and pushes state to tmux and a
plain file, so every consumer reads current truth instead of hoping it caught
the last live event.

## Model

1. `dark-notify -c macos-appearance-watcher` runs as a LaunchAgent, invoking this
   script with `light`/`dark` on start and on every subsequent change.
2. Writes the resolved mode (`Light`/`Dark`) to
   `~/.local/state/appearance/mode`, atomically (temp file + rename).
3. Sets tmux's `@tokyo-night-tmux_theme` global option directly and re-runs the
   `tokyo-night-tmux` plugin — server-wide, so every session (attached or not)
   picks it up immediately.

`~/.config/zsh/.zprofile` reads the state file (falling back to
`defaults read -g AppleInterfaceStyle` if it doesn't exist yet), and
`~/.config/zsh/conf.d/appearance-live-sync.zsh` adds a `precmd` hook so an
already-running shell notices a change and reloads (`exec zsh`) instead of only
picking it up on next login.

## Install

```sh
ln -s "$PWD/macos-appearance-watcher" ~/workspace/lab/scripts/bin/macos-appearance-watcher
brew install cormacrelf/tap/dark-notify
```

Then load `~/Library/LaunchAgents/com.k1.appearance-watcher.plist`
(`ProgramArguments` should point at this script's real path, not the `bin/`
symlink, since LaunchAgents resolve paths with a minimal environment):

```sh
launchctl load ~/Library/LaunchAgents/com.k1.appearance-watcher.plist
```

## Test

```sh
osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to true'
cat ~/.local/state/appearance/mode   # Dark
tmux show-options -g | grep tokyo-night-tmux_theme   # night
```
