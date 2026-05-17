## Bootstrap a new Mac

### Preferred: one-command bootstrap

This repo now supports a thin bootstrap entrypoint that clones or updates `~/.dotfiles` and then runs the local installer:

```zsh
curl -fsSL https://raw.githubusercontent.com/jdblackstar/dotfiles/main/bootstrap.sh | sh
```

Once `blackstar.dev/install` is wired up to serve the same script, the intended public install command is:

```zsh
curl -fsSL https://blackstar.dev/install | sh
```

If you want to pass flags through to the local installer, use `sh -s --`:

```zsh
curl -fsSL https://raw.githubusercontent.com/jdblackstar/dotfiles/main/bootstrap.sh | sh -s -- --no-brew
```

### What the bootstrap does

1. Ensures `git` is available.
2. Clones this repo to `~/.dotfiles` if it is missing.
3. Pulls the latest changes if `~/.dotfiles` already exists and is clean.
4. Runs `install.sh` from the local clone.

If the local repo has uncommitted changes, the bootstrap script leaves it alone and reuses the existing checkout.

On a brand new macOS install, the first run may prompt you to install Apple's Command Line Tools so `git` is available. After that finishes, rerun the same bootstrap command.

### Manual fallback

If you prefer not to pipe into `sh`, you can still bootstrap manually:

```zsh
xcode-select --install
git clone https://github.com/jdblackstar/dotfiles.git ~/.dotfiles
bash ~/.dotfiles/install.sh
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
- The installer creates required config directories, links managed dotfiles, installs bootstrap dependencies, and only updates downloaded assets when they change.

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
- `install.sh` symlink layout, backups, idempotency, `--no-brew`, brew-bundle flow (with stubs), Darwin defaults hook (minimal fixture script + stubbed `killall`), TPM edge cases, and unknown-flag handling
- `cleanup.sh` remote URL rewriting
- `config/.zshrc` syntax and basic load behavior (requires `zsh` on the runner)

**What it deliberately does *not* do**

- Real Homebrew installs or full `brew bundle`
- Real `xcode-select --install` or live Oh My Zsh / TPM downloads (those calls are stubbed or satisfied with fixtures)
- Applying your full [`config/.macos`](config/.macos) script (installer tests use a tiny fixture in place of the real defaults script)

Contributor note: `install.sh` honors `DOTFILES_TEST_BREW_BIN`, `DOTFILES_SKIP_HOMEBREW_INSTALL`, and `DOTFILES_TEST_IGNORE_SYSTEM_BREW` only for hermetic tests; they are unused during a normal install.

### Work-laptop verification (real machine, read-only)

After a real bootstrap on a Mac, you can sanity-check the result without mutating anything:

```zsh
bash tests/verify-work-laptop.sh
```

This checks expected symlinks, a set of CLI tools that match [`config/Brewfile`](config/Brewfile), Oh My Zsh, TPM, and the Alacritty theme file. It warns (but does not fail) if the 1Password SSH signer path from [`git/.gitconfig`](git/.gitconfig) is missing. Override the repo location with `DOTFILES_DIR` if needed.

**What remains manual or environment-specific**

- Signing into the Mac App Store or GUI apps installed via cask
- 1Password / SSH agent and any org-specific SSO
- Full macOS defaults from `config/.macos` (sudo, Finder/Dock preferences)