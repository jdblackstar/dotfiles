## Bootstrap a machine

### Preferred: one-command bootstrap

This repo now supports a thin bootstrap entrypoint that clones or updates `~/.dotfiles` and then runs the local installer:

```zsh
curl -fsSL https://raw.githubusercontent.com/jdblackstar/dotfiles/main/bootstrap.sh | sh
```

Once `blackstar.dev/install` is wired up to serve the same script, the intended public install command is:

```zsh
curl -fsSL https://blackstar.dev/install | sh
```

The default profile is `personal`, and the installer auto-detects `macos` or `linux` from `uname`. To choose another profile, pass it through with `sh -s --`:

```zsh
curl -fsSL https://raw.githubusercontent.com/jdblackstar/dotfiles/main/bootstrap.sh | sh -s -- --profile work
```

For an agent/container setup:

```zsh
curl -fsSL https://raw.githubusercontent.com/jdblackstar/dotfiles/main/bootstrap.sh | sh -s -- --profile agent
```

To override platform detection:

```zsh
curl -fsSL https://raw.githubusercontent.com/jdblackstar/dotfiles/main/bootstrap.sh | sh -s -- --profile work --platform linux
```

### Profiles

- `personal`: primary personal workstation setup, personal Git identity/signing, personal package layer, relay config.
- `work`: everyday coding setup, shared dev tools, relay agent config, work-safe Git config with local identity override.
- `agent`: headless dev setup, terminal links, relay agent config, no GUI package layer, no personal Git identity.

### Platforms

- `macos`: Homebrew package layers and optional macOS defaults.
- `linux`: Linux package layers when available; no macOS defaults or Homebrew casks.

### What the bootstrap does

1. Ensures `git` is available.
2. Clones this repo to `~/.dotfiles` if it is missing.
3. Pulls the latest changes if `~/.dotfiles` already exists and is clean.
4. Runs `install.sh` from the local clone with the selected profile and detected platform.

If the local repo has uncommitted changes, the bootstrap script leaves it alone and reuses the existing checkout.

On a brand new macOS install, the first run may prompt you to install Apple's Command Line Tools so `git` is available. After that finishes, rerun the same bootstrap command.

### Manual fallback

If you prefer not to pipe into `sh`, you can still bootstrap manually:

```zsh
xcode-select --install
git clone https://github.com/jdblackstar/dotfiles.git ~/.dotfiles
bash ~/.dotfiles/install.sh --profile work --platform macos
```

### After 1Password / SSH setup

The repo is cloned over HTTPS first so it works on a fresh machine before SSH signing is ready. Once 1Password and SSH are configured, run:

```zsh
bash ~/.dotfiles/cleanup.sh
```

`cleanup.sh` safely switches the repo remote from HTTPS to SSH when it recognizes the expected GitHub URL.

## Notes

- `install.sh` is designed to be idempotent and safe to rerun.
- `cleanup.sh` is also rerun-safe; it exits cleanly if the remote already uses SSH.
- The installer creates required config directories, records the selected profile at `~/.config/dotfiles/profile` and platform at `~/.config/dotfiles/platform`, links managed dotfiles, and runs only the package/defaults layers owned by that profile/platform pair.

## Testing

### Hermetic suite (CI + local)

Run the automated test suite with:

```zsh
bash tests/run.sh
```

If `bats` is already installed, the runner will use it. Otherwise it will fetch a temporary copy of `bats-core` and run the suite from there.

GitHub Actions runs the same command on every push and pull request (see [`.github/workflows/tests.yml`](.github/workflows/tests.yml)).

**What this suite is meant to catch**

- `bootstrap.sh` clone/update behavior and installer handoff
- `install.sh` profile/platform selection, symlink layout, backups, idempotency, brew-bundle flow (with stubs), Linux package skip behavior, Darwin defaults hook (minimal fixture script + stubbed `killall`), TPM edge cases, and unknown-flag handling
- `cleanup.sh` remote URL rewriting
- `config/.zshrc` syntax and basic load behavior (requires `zsh` on the runner)

**What it deliberately does *not* do**

- Real Homebrew installs or full `brew bundle`
- Real `xcode-select --install` or live Oh My Zsh / TPM downloads (those calls are stubbed or satisfied with fixtures)
- Applying your full [`config/.macos`](config/.macos) script (installer tests use a tiny fixture in place of the real defaults script)

Contributor note: `install.sh` honors `DOTFILES_TEST_BREW_BIN`, `DOTFILES_SKIP_HOMEBREW_INSTALL`, `DOTFILES_TEST_IGNORE_SYSTEM_BREW`, and `DOTFILES_SKIP_LINUX_PACKAGES` only for hermetic tests; they are unused during a normal install.

### Mac install verification (real machine, read-only)

After a real bootstrap on a Mac, you can sanity-check the result without mutating anything:

```zsh
bash tests/verify-mac-install.sh --profile personal
```

For a work laptop, run:

```zsh
bash tests/verify-mac-install.sh --profile work
```

This checks expected profile symlinks, profile markers, a set of CLI tools that match [`packages/brew/base.Brewfile`](packages/brew/base.Brewfile), relay config, Oh My Zsh when the profile installs it, and TPM. It warns (but does not fail) if a profile-specific local Git identity file is missing. Override the repo location with `DOTFILES_DIR` if needed.

**What remains manual or environment-specific**

- Signing into the Mac App Store or GUI apps installed via cask
- Work Git identity in `~/.gitconfig.work.local`
- Agent Git identity in `~/.gitconfig.agent.local`
- 1Password / SSH agent and any org-specific SSO
- Full macOS defaults from `config/.macos` (sudo, Finder/Dock preferences)
