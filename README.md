# wezterm-layouts

Saves a wezterm window (tabs, splits, cwd, nvim tabs) and opens it back up.

## Setup

In the pwsh profile:

```powershell
Set-Alias wzl ~\Projects\wezterm-layouts\wzl.ps1
```

In wsl:

```bash
ln -s /mnt/c/Users/JonahW/Projects/wezterm-layouts/wzl ~/.local/bin/wzl
```

In `.wezterm.lua`, so wsl can see which pane it's in (wezterm adds its own `TERM` ones on after):

```lua
config.set_environment_variables = { WSLENV = "WEZTERM_PANE" }
```

Without it wsl panes still get saved, but come back as pwsh. Panes wzl opens set it themselves.

## Usage

```powershell
wzl               # menu: open, save or remove, then which layout
wzl save [name]   # save this window, name defaults to the current folder
wzl <name>        # open it
wzl ls
wzl rm [name]     # picks if no name, always asks before deleting
wzl <name> -Window  # into a new window instead of this one
```

Menus take arrows, j/k or the number, enter to pick, esc to cancel.

Opening puts the tabs in the current window. If the pane it was run from is alone in its tab it gets closed, so opening wezterm and running `wzl` leaves just the layout.

Layouts go in `~\.config\wezterm\layouts\<name>\`, or `$env:WZL_DIR`.

## How it works

- splits are worked out from the pane positions in `wezterm cli list` and rebuilt with `split-pane --percent`, so they scale to whatever size the window is
- every nvim listens on a pipe and inherits `WEZTERM_PANE`, so each one gets asked which pane it's in and to `:mksession` into the layout folder. Restored panes run `nvim -S` under `pwsh -NoExit`, quitting nvim leaves a shell
- zoomed panes are unzoomed for a moment to read the real splits
- wsl panes are found by `./wzl _probe`, which runs in each running distro, matches shells and nvims to panes by `WEZTERM_PANE` and reads their cwd from `/proc`. They come back as `wsl -d <distro> --cd <dir>` from cmd, same as typing `wsl`, with `bash -ic "nvim -S ..."` if there was an nvim
- `./wzl` is also the wsl command, it just runs `wzl.ps1` through `pwsh.exe`

## Notes

- sessions don't keep unsaved changes, and only nvim gets restarted. Anything else (lazygit, btop) comes back as a shell in the same folder
- pwsh's `cd` doesn't move the process, so wezterm only knows a shell's real cwd if the prompt reports it. The pane you run `save` from, nvim panes and wsl panes are always right. For the rest add `"pwd": "osc7"` to the oh-my-posh config
- wezterm doesn't give back memory from closed windows (~150-250MB each, 20240203 and nightly), so `-Window` adds up over a day. tabs and splits don't leak, so opening into the current window is fine
