# OmaControl

A task manager in your Omarchy top bar: live CPU, memory, GPU, disk and
network stats, per-app history, process control, and alerts when an app uses
your camera, microphone or location.

<img width="1600" height="1120" alt="OmaControl preview" src="https://github.com/user-attachments/assets/df68baa0-a1b8-4d63-8e0e-78bf6dcaf091" />

This is a fork of [Davedes83/OmaControl](https://github.com/Davedes83/OmaControl)
with performance, privacy and accuracy fixes (see below).

## Install

```bash
omarchy plugin add https://github.com/spaghetticodez/OmaControl.git --enable
```

Pick a bar section when asked. Update later with
`omarchy plugin update davedes.omcontrol`.

Needs `sqlite3` and `python3`. GPU stats use `nvidia-smi` or AMD's sysfs.

## Use

- **Left-click** opens the app window: live graphs, running apps, alerts,
  events and settings.
- **Middle-click** refreshes.
- **Right-click** opens a menu: jump to a tab, apply rules, stop the top
  process.

From the app window you can stop, pause, resume or reprioritize an app, or
block it from starting again. History is kept in
`~/.local/share/omcontrol/history.db`.

The plugin folder also has a command-line tool:

```bash
~/.config/omarchy/plugins/davedes.omcontrol/omcontrol status
~/.config/omarchy/plugins/davedes.omcontrol/omcontrol --help
```

### Record history while the shell is closed (optional)

```bash
systemctl --user enable --now ~/.config/omarchy/plugins/davedes.omcontrol/systemd/omcontrol-collect.service
```

## What this fork changes

- **Lighter:** the collector uses about 70% less CPU per update and no
  longer pauses on each update.
- **Live CPU:** the process list shows what is using the CPU right now, like
  `top`, instead of an average over each process's lifetime.
- **Private:** command lines (which can hold passwords or tokens) are no
  longer saved to the history database, and old ones are wiped.
- **AMD CPU temperature** works (it showed 0 °C on Ryzen boards).
- Smaller fixes: btrfs subvolumes show as one disk, short-lived state lives
  in RAM instead of on disk, and collector errors are no longer hidden.

## Remove

```bash
systemctl --user disable --now omcontrol-collect
omarchy plugin remove davedes.omcontrol
rm -rf ~/.local/share/omcontrol   # optional: permanently deletes history and settings
```

## Development

```bash
tests/run-tests.sh bash
tests/run-tests.sh "bash --posix"
```

CI runs the tests under `dash`, `bash` and `bash --posix`, plus shellcheck
and shfmt. Tests use throwaway data, never your real history.

## Credits

OmaControl was created by **Davedes83**:
[github.com/Davedes83/OmaControl](https://github.com/Davedes83/OmaControl).
Like the plugin? ♥️ it on the Omarchy Marketplace to help others find it,
and support the author:

<a href='https://ko-fi.com/O3N726LJT4' target='_blank'><img height='36' style='border:0px;height:36px;' src='https://storage.ko-fi.com/cdn/kofi5.png?v=6' border='0' alt='Buy Me a Coffee at ko-fi.com' /></a>

MIT license.
