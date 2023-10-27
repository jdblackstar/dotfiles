#!/bin/bash

# create symbolic links required for proper system function
for file in .gitconfig .gitignore_global .zshrc Brewfile; do
  if [ -f ~/.dotfiles/$file ]; then
    ln -s ~/.dotfiles/$file ~/$file
  else
    echo "$file not found!"
  fi
done

# check if homebrew is installed, otherwise install it
if test ! $(which brew); then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# update homebrew
brew update

# if the first argument is not --no-brew, install from Brewfile
if [ "$1" != "--no-brew" ]; then
  # install everything in the Brewfile
  brew bundle --file ~/.dotfiles/Brewfile
fi

# install the macosdefaults.sh script
source ~/.dotfiles/.macos