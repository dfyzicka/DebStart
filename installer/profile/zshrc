# Keep Powerlevel10k's instant prompt near the beginning of startup.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

typeset -U path
path=("$HOME/.local/bin" $path)
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
zstyle ':omz:update' mode disabled

plugins=(
  sudo
  z
  zsh-interactive-cd
  fzf
  zsh-autosuggestions
  zsh-syntax-highlighting
)
source "$ZSH/oh-my-zsh.sh"
[[ ! -r "$HOME/.p10k.zsh" ]] || source "$HOME/.p10k.zsh"

if (( $+commands[eza] )); then
  alias sl='eza -bghHliS'
else
  alias sl='exa -bghHliS'
fi
alias fd='fdfind'
if (( $+commands[batcat] )); then
  alias bat='batcat'
fi
if (( $+commands[fastfetch] )); then
  alias neofetch='fastfetch'
fi
alias st='speedtest-cli --no-upload'
alias bt='bpytop'
alias cls='clear'
alias sys='sudo systemctl'
if (( $+commands[dry] )); then
  alias dk='sudo dry'
fi
