#!/bin/bash

# Get the current working directory
current_dir=$(pwd)

# Check if the current directory is .dotfiles
if [[ $current_dir != *".dotfiles" ]]; then
  # Check if .dotfiles directory exists
  if [ -d ~/.dotfiles ]; then
    echo "Changing directory to .dotfiles"
    cd ~/.dotfiles
  else
    echo "~/.dotfiles directory not found!"
    exit 1
  fi
fi

# Check if the current directory is a git repository
if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  # Check if the remote URL is the HTTPS version
  if git remote get-url origin | grep -q '^https://'; then
    # If it is, switch it to the SSH version
    echo "changing remote URL from https to SSH"
    git remote set-url origin git@github.com:jdblackstar/dotfiles.git
  fi
else
  echo "The current directory is not a git repository!"
  exit 1
fi