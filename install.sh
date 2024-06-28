#!/bin/bash

# TABLE OF CONTENTS
# 1. Create and verify symbolic links of config files
# 2. Install Homebrew and Brewfile
# 3. Install macOS specific settings
# 4. Terminal, and TMUX setup

# Function to create and verify symbolic links
create_and_verify_symlink() {
  # source_file is where we make changes
  local source_file=$1
  # clone file is the blank file we want to point at the source_file
  local clone_file=$2

  if [ -f "$source_file" ]; then
    ln -sf "$source_file" "$clone_file"
    if [ "$(readlink "$clone_file")" == "$source_file" ]; then
      echo "Successfully linked $clone_file to $source_file"
    else
      echo "Failed to link $clone_file to $source_file"
    fi
  else
    echo "$source_file not found!"
  fi
}

# create symbolic links required for proper system function
create_and_verify_symlink ~/.dotfiles/git/.gitconfig ~/.gitconfig
create_and_verify_symlink ~/.dotfiles/git/.gitignore_global ~/.gitignore_global
create_and_verify_symlink ~/.dotfiles/config/.zshrc ~/.zshrc
create_and_verify_symlink ~/.dotfiles/config/tmux.conf ~/.tmux.conf
create_and_verify_symlink ~/.dotfiles/config/starship.toml ~/.config/starship.toml

# check if homebrew is installed, otherwise install it
if test ! $(which brew); then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
else
  # update homebrew if already installed
  brew update
fi

# if the first argument is not --no-brew, install from Brewfile
if [ "${1:-}" != "--no-brew" ]; then
  if [ -f ~/.dotfiles/config/Brewfile ]; then
    # install everything in the Brewfile
    brew bundle --file ~/.dotfiles/config/Brewfile
  else
    echo "Brewfile not found in ~/.dotfiles!"
  fi
fi

# Execute the .macos script
if [ -f ~/.dotfiles/config/.macos ]; then
  echo "Executing ~/.dotfiles/config/.macos"
  chmod +x ~/.dotfiles/config/.macos
  ~/.dotfiles/config/.macos
  echo "Finished executing ~/.dotfiles/config/.macos"

  killall Dock
else
  echo "~/.dotfiles/config/.macos not found!"
fi

# Terminal set up
# download the catppuccin mocha theme
curl -Lo ~/.config/alacritty/catppuccin-mocha.toml https://github.com/catppuccin/alacritty/raw/main/catppuccin-mocha.toml

# Install TPM (Tmux Plugin Manager)
TPM_DIR="$HOME/.tmux/plugins/tpm"
if [ ! -d "$TPM_DIR" ]; then
  echo "TPM not found. Installing..."
  git clone https://github.com/tmux-plugins/tpm "$TPM_DIR"
  if [ $? -eq 0 ]; then
    echo "TPM installed successfully."
  else
    echo "Failed to install TPM. Please check your internet connection and try again."
  fi
else
  echo "TPM is already installed."
fi
