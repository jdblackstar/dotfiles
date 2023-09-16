#!/bin/bash

# create symbolic links required for proper system function
ln -s ~/.dotfiles/git/.gitconfig ~/.gitconfig
ln -s ~/.dotfiles/git/.gitignore_global ~/.gitignore_global
ln -s ~/.dotfiles/.zshrc ~/.zshrc

# check if homebrew is installed, otherwise install it
if test ! $(which brew); then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# update homebrew
brew update

# install everything in the Brewfile
brew bundle --file ~/.dotfiles/Brewfile

# install the macosdefaults.sh script
source ~/.dotfiles/macos