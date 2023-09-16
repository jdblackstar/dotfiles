#!/bin/bash

# Check if the remote URL is the HTTPS version
if git remote get-url origin | grep -q '^https://'; then
  # If it is, switch it to the SSH version
  git remote set-url origin git@github.com:jdblackstar/dotfiles.git
fi