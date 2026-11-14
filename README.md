# <img src="docs/icon.png" alt="Actualizate" width="64" height="64" style="vertical-align: middle;">&nbsp;&nbsp;Actualizate

*Check every update source on your Mac at once, then install only what you pick*

![Platform](https://img.shields.io/badge/Platform-macOS_26+-black) ![Architecture](https://img.shields.io/badge/Architecture-Apple_Silicon-black) ![License](https://img.shields.io/badge/License-MIT-blue)

**Actualizate** is a SwiftUI app built on `actualizar`, a zsh script that checks Homebrew, the Mac App Store, Sparkle feeds, Microsoft AutoUpdate and macOS in parallel. The app lists what is pending by section, you tick what to update, and each app gets its own progress bar while it installs. The same script works on its own in Terminal.

> [!NOTE]
> The interface is in Spanish.

[Leer en español](README.es.md)

---

## Features

- **Check first, change nothing:** the check runs every source in parallel (about 30 s) and only reports.
- **Sections:**
  - Casks from your own Homebrew tap that you bump by hand (optional, see [Configuration](#configuration)).
  - Homebrew formulas.
  - Homebrew casks, including `--greedy` ones. Casks whose app already updated itself are skipped, so nothing is reinstalled or downgraded.
  - Mac App Store, through `mas`.
  - Apps with a Sparkle feed newer than Homebrew. They install with Sparkle's own installer after checking the vendor's EdDSA signature.
  - Apps without Homebrew or Sparkle: notice only (optional).
  - macOS and Safari: notice only, because they usually need a restart.
  - Microsoft AutoUpdate, which it also repairs when its privileged helper is missing.
- **Per-app progress bar** while installing, read from Homebrew's own output.
- **Background check** with a notification when something is pending. Lives in the menu bar, the Dock, or both.
- **App adoption:** lists every installed app with its Homebrew status and replaces manual installs with the Homebrew cask, with a backup and a full check before removing the original.
- **Optional passwordless updates** through a small root helper (see below).

---

## Requirements

- macOS 26 or later, Apple Silicon (Homebrew in `/opt/homebrew`).
- Xcode 26. The full Xcode, not only the Command Line Tools: `actool` compiles the Icon Composer icon.
- [Homebrew](https://brew.sh), plus `brew install jq mas`.
- For the Sparkle section: Sparkle's command-line tool `sparkle.app` (sparkle-cli, Sparkle 2) in `~/.local/opt/sparkle.app`, taken from a [Sparkle release](https://github.com/sparkle-project/Sparkle/releases).
- Optional, for passwordless updates: an Apple-issued code signing identity (Apple Development or Developer ID Application) in your keychain.

---

## Build and install

```bash
git clone https://github.com/asubervirojas/actualizate.git
cd actualizate
./compilar.sh --instalar
```

This leaves the app in `~/Applications/Actualizate.app`. The script signs it with the first Apple Development or Developer ID Application identity it finds, or the one in `ACTUALIZATE_FIRMA`. Without one it signs ad hoc and leaves out the root helper.

Then install the helper scripts the engine uses and, if you want the command in Terminal, link it:

```bash
mkdir -p ~/.local/bin
install -m 755 ayudantes/brew-casks-pendientes ayudantes/sparkle-pendientes ~/.local/bin/
swiftc -O ayudantes/ed25519-verify.swift -o ~/.local/bin/ed25519-verify
ln -sf ~/Applications/Actualizate.app/Contents/Resources/actualizar ~/.local/bin/actualizar
```

---

## Terminal

```bash
actualizar                                   # check and install everything
actualizar revisar                           # check only, changes nothing
actualizar instalar --etapas formulas,casks  # install only those sections
actualizar instalar --casks firefox,vlc      # install only those casks
actualizar adoptables                        # list installed apps and their Homebrew status
actualizar --help
```

The script exports `HOMEBREW_NO_ASK=1`, so Homebrew 7 does not stop to ask `[y/n]`: you already chose what to install.

---

## Configuration

Two optional lists sit at the top of `Recursos/actualizar`, with examples:

- `PROPIOS` and `TAP`: casks in your own tap whose version and `sha256` the script bumps from a `latest-mac.yml` feed or a GitHub release.
- `MANUALES`: apps outside Homebrew and Sparkle that only get a notice, each with a small function that prints the latest version.

Run `./compilar.sh --instalar` again after editing.

---

## Passwordless updates (optional)

Homebrew runs `sudo` for `.pkg` casks, `launchctl`, `mas` and some file operations. In **Ajustes > Contraseña > Actualizar sin contraseña** the app registers a LaunchDaemon that ships inside it (`SMAppService`). macOS asks you to approve it once in System Settings > General > Login Items & Extensions.

The helper:

- Only accepts connections from this app signed by the same Apple team as the helper, and only from admin accounts.
- Only writes or removes `/etc/sudoers.d/zz_actualizate`. The rule text is in `Sources/ActualizateRaiz/Regla.swift` and is checked with `visudo` before it is put in place.

The rule is `NOPASSWD:SETENV` for `installer`, `pkgutil`, `launchctl`, common file commands (`rm`, `cp`, `mv`, `chmod`, `chown`, `ditto`, and others), `mas` and Homebrew's portable Ruby. `SETENV` is needed because Homebrew always calls `sudo -E VAR=...`. The file sorts after Homebrew's own `brew_setenv` rule, so it wins.

> [!WARNING]
> This is a real trade-off: any program running as your user can then run those commands as root without asking. Turn it off from the same place. If you delete the app without turning it off first, remove the rule by hand: `sudo rm /etc/sudoers.d/zz_actualizate`.

Tools that write a custom icon into the app bundle break its strict signature check, and macOS can then refuse the helper. Leave Actualizate out of them.

---

## Permissions

The first time it updates apps, macOS asks for Actualizate:

- **App Management** (Privacy & Security), so Homebrew and Sparkle can replace apps in `/Applications`.
- **Automation**, to quit and reopen apps (Microsoft, AdGuard).
- **Notifications**, when an install finishes or the background check finds something.

---

## Microsoft AutoUpdate

Microsoft AutoUpdate installs through a privileged helper, `/Library/PrivilegedHelperTools/com.microsoft.autoupdate.helper`. When it is missing, AutoUpdate downloads updates but stays in "Installing" forever. Actualizate warns about it when checking and, when installing, repairs it first with `brew install --cask microsoft-auto-update`, then waits for AutoUpdate to finish (up to 45 minutes). An empty or invalid answer from `msupdate` is never read as "up to date".

---

## App adoption

The box-with-arrow button (or `actualizar adoptables`) lists every app in `/Applications`, `~/Applications` and `/System/Applications` with its status: can be adopted, already managed by Homebrew, not managed, App Store, Apple. `actualizar adoptar --casks a,b` installs the Homebrew copy and checks its receipt, location, bundle id, version and executable before removing the original. If anything fails, the backup is restored. It never uses `--zap`, never deletes data or preferences, and never downgrades.

---

## Logs and tests

Each run is saved in `~/Library/Logs/Actualizar/` (the last 60).

```bash
python3 -I Tests/test_microsoft.py
python3 -I Tests/test_adoptar.py
```

The tests use a fake `msupdate` and a fake `brew`; they change nothing on your Mac.

---

## Uninstall

1. If passwordless updates are on: **Ajustes > Contraseña > Quitar**.
2. Quit the app and delete `~/Applications/Actualizate.app`.
3. `rm ~/.local/bin/actualizar` and `defaults delete local.armando.actualizar`.

---

## Notes

- Not affiliated with Homebrew, Sparkle, Microsoft or Apple.
- Built with AI assistance.

## License

[MIT](LICENSE)
