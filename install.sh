#!/bin/bash

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

# since installing oh-my-zsh will write to our ~/.zshrc file,
# let's install oh-my-zsh here so we can overwrite with our symlink
# Check if oh-my-zsh is installed
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  echo "Installing oh-my-zsh..."
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
  echo "oh-my-zsh installed successfully."
else
  echo "oh-my-zsh is already installed."
fi


# create symbolic links required for proper system function
# Safely remove existing files before creating symlinks
for file in ~/.gitconfig ~/.gitignore_global ~/.zshrc; do
  if [ -f "$file" ]; then
    echo "Backing up existing $file to ${file}.bak"
    mv "$file" "${file}.bak"
  elif [ -L "$file" ]; then
    echo "Removing existing symlink $file"
    rm "$file"
  fi
done

create_and_verify_symlink ~/.dotfiles/git/.gitconfig ~/.gitconfig
create_and_verify_symlink ~/.dotfiles/git/.gitignore_global ~/.gitignore_global
create_and_verify_symlink ~/.dotfiles/config/.zshrc ~/.zshrc

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