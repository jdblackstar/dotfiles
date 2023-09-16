#!/bin/bash

# Get the current working directory
current_dir=$(pwd)

# Check if the current directory is .dotfiles
if [[ $current_dir != *".dotfiles" ]]; then
  echo "Changing directory to .dotfiles"
  cd ~/.dotfiles
fi

# Check if the remote URL is the HTTPS version
if git remote get-url origin | grep -q '^https://'; then
  # If it is, switch it to the SSH version
  git remote set-url origin git@github.com:jdblackstar/dotfiles.git
fi