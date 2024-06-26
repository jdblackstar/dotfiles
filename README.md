## Steps to bootstrap a new Mac

1. Install Apple's Command Line Tools, which are prerequisites for Git and Homebrew.

```zsh
xcode-select --install
```


2. Clone repo into new directory.

```zsh
# Use SSH (if set up)...
git clone git@github.com:jdblackstar/dotfiles.git ~/.dotfiles

# ...or use HTTPS and switch remotes later.
git clone https://github.com/jdblackstar/dotfiles.git ~/.dotfiles
```

3. Change to the newly cloned directory
```zsh
cd ~/.dotfiles
```

4. Add execute permissions to the install.sh script

```zsh
chmod +x scripts/install.sh
```

5. Run the install script

```zsh
./scripts/install.sh
```

### Once setup of most applications is done (specifically 1password, as this is our ssh-agent) we can run the `cleanup.sh` script to finish up

6. Add execute permission to the cleanup.sh script

```zsh
chmod +x scripts/cleanup.sh
```

7. Run the cleanup script

```zsh
./scripts/cleanup.sh
```

## TODO List
[ ] - Flexoki Light & Dark theme for Cursor
[ ] - Amphetamine install and setup
[ ] - look into making the install.sh script a curl command, so include `xcode-select --install`