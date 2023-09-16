# navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ~='cd ~'

# listing
alias ll='ls -l'
alias la='ls -A'
alias l='ls -CF'

# quick access
alias dt='cd ~/Desktop'
alias dl='cd ~/Downloads'

# sys ops
alias c='clear'
alias h='history'
alias df='df -h'

# programming
alias x='code .'
alias x.='code ..'
alias xx='cursor .'
alias xx.='cursor ..'

# macOS stuff
alias spotoff="sudo mdutil -a -i off"
alias spoton="sudo mdutil -a -i on"
alias update='sudo softwareupdate -i -a; brew update; brew upgrade; brew cleanup; omz update'

# -> http://xkcd.com/530/
alias stfu="osascript -e 'set volume output muted true'"
alias pumpitup="osascript -e 'set volume output volume 100'"

# browser stuff
alias chrome='/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome'
alias chromekill="ps ux | grep '[C]hrome Helper --type=renderer' | grep -v extension-process | tr -s ' ' | cut -d ' ' -f2 | xargs kill"