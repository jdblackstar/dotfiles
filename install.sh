#!/bin/bash

# Function to create and verify symbolic links
create_and_verify_symlink() {
  local source_file=$1
  local target_file=$2

  if [ -f "$source_file" ]; then
    ln -sf "$source_file" "$target_file"
    if [ "$(readlink "$target_file")" == "$source_file" ]; then
      echo "Successfully linked $target_file to $source_file"
    else
      echo "Failed to link $target_file to $source_file"
    fi
  else
    echo "$source_file not found!"
  fi
}

# create symbolic links required for proper system function
create_and_verify_symlink ~/.dotfiles/git/.gitconfig ~/.gitconfig
create_and_verify_symlink ~/.dotfiles/git/.gitignore_global ~/.gitignore_global
create_and_verify_symlink ~/.dotfiles/config/.zshrc ~/.zshrc
create_and_verify_symlink ~/.dotfiles/config/Brewfile ~/Brewfile

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