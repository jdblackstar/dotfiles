: '
Table of Contents:
1. PATH
2. keybindings
3. oh-my-zsh
4. fzf
5. sourcing of other dotfiles
6. evals
'

# 1. PATH
export ZSH="$HOME/.oh-my-zsh"
export PATH=~/.npm-global/bin:$PATH
export PATH="/Users/josh/.local/bin:$PATH"
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"

# ---------------------------

# 2. keybindings
# ctrl + E, brings up an fzf menu that will open the selected file in vim
bindkey -s '^e' 'FILE=$(fzf) && [ -n "$FILE" ] && vim "$FILE"\n'
# ctrl + Q, brings up an fzf menu that will open the selected file in Finder
bindkey -s '^q' 'FILE=$(fzf) && [ -n "$FILE" ] && open -R "$FILE"\n'

# keybinds for history based suggestions
# commented out because this is handled by oh-my-zsh
# double-check the binding for up and down, ducky keyboards are weird
# bindkey '^[OA' history-beginning-search-backward
# bindkey '^[OB' history-beginning-search-forward

# ---------------------------

# 3. oh-my-zsh
zstyle ':omz:update' mode reminder  # just remind me to update when it's time
zstyle ':omz:update' frequency 13

ZSH_THEME="robbyrussell"
ENABLE_CORRECTION="true"
plugins=(
    git
)

source $ZSH/oh-my-zsh.sh

# ---------------------------

# 4. fzf
# catppuccin mocha
export FZF_DEFAULT_OPTS=" \
--color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8 \
--color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc \
--color=marker:#f5e0dc,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8"

# directories to ignore when using fzf
if [[ "$OSTYPE" == "darwin"* ]]; then # macOS specifically
  export FZF_DEFAULT_COMMAND='rg --files --hidden \
    --glob "!.git" \
    --glob "!node_modules" \
    --glob "!Library" \
    --glob "!Movies" \
    --glob "!Music" \
    --glob "!Pictures" \
    --glob "!Public" \
    '
else # other OS
  export FZF_DEFAULT_COMMAND='rg --files --hidden \
    --glob "!.git" \
    --glob "!node_modules" \
    '
fi

# ---------------------------

# 5. sourcing of other dotfiles
# aliases
source ~/.dotfiles/config/.aliases
# functions
find ~/.dotfiles/functions -type f | while read file; do
    source $file
done

# ---------------------------

# 6. evals
eval "$(zoxide init --cmd cd zsh)"
eval "$(starship init zsh)"
source /Users/josh/.config/op/plugins.sh
source ~/.config/op/plugins.sh
