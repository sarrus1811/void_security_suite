#!/usr/bin/env bash

trap 'tput cnorm' EXIT

OPTIONS=(
  "1. Full setup"
  "2. Install program"
  "3. Install by group"
  "4. Update"
  "5. Exit"
)

SELECTED=0
TOTAL=${#OPTIONS[@]}

# ANSI escape codes
ESC=$(printf '\033')
CURSOR_UP="${ESC}[A"
CLEAR_LINE="${ESC}[2K"
BOLD="${ESC}[1m"
RESET="${ESC}[0m"
HIGHLIGHT="${ESC}[7m"   # reverse video (highlight)

# Hide cursor while navigating
tput civis

draw_menu() {
  for i in "${!OPTIONS[@]}"; do
    printf "\r${CLEAR_LINE}"
    if [[ $i -eq $SELECTED ]]; then
      printf "  ${HIGHLIGHT}${BOLD} › ${OPTIONS[$i]} ${RESET}\n"
    else
      printf "    ${OPTIONS[$i]}\n"
    fi
  done
}

# Move cursor back up to top of menu
move_to_top() {
  for (( i=0; i<TOTAL; i++ )); do
    printf "${CURSOR_UP}"
  done
}

# Initial draw
draw_menu

# Read keystrokes
while true; do
  IFS= read -rsn1 key

  if [[ $key == $'\x1b' ]]; then          # ESC prefix
    IFS= read -rsn1 -t 0.1 key2
    IFS= read -rsn1 -t 0.1 key3
    case "${key2}${key3}" in
      '[A')   # Up arrow
        (( SELECTED = (SELECTED - 1 + TOTAL) % TOTAL ))
        ;;
      '[B')   # Down arrow
        (( SELECTED = (SELECTED + 1) % TOTAL ))
        ;;
    esac
    move_to_top
    draw_menu
  elif [[ $key == $'\x10' ]]; then        # Ctrl+P (up)
    (( SELECTED = (SELECTED - 1 + TOTAL) % TOTAL ))
    move_to_top
    draw_menu
  elif [[ $key == $'\x0e' ]]; then        # Ctrl+N (down)
    (( SELECTED = (SELECTED + 1) % TOTAL ))
    move_to_top
    draw_menu
  elif [[ $key == $'\x0a' || $key == $'\x0d' || $key == "" ]]; then  # Enter
    break
  fi
done

# Push cursor below the menu
printf "\n"

# Restore cursor
tput cnorm

# -------
# Sub install functions

install_antigravity(){
  sudo mkdir -p /opt/antigravity
  sudo tar -xzf ~/Downloads/antigravity-linux-x64.tar.gz -C /opt/antigravity --strip-components=1
}


# -------
# Main install functions

install_utils() {
  sudo xbps-install -Su
  sudo xbps-install -S terminator tmux fzf ripgrep chromium tor proxychains-ng socat wget git openvpn jq yq bleachbit -y
}

install_containers(){
  :
}

install_cloud(){
  :
}

install_forensics(){
  :
}

install_reverse(){
  :
}

install_password(){
  :
}

install_wireless(){
  :
}

install_network(){
  :
}

install_exploitation(){
  :
}

install_web_testing(){
  :
}

install_recon(){
  :
}

install_scripts(){
  mkdir ~/scripts && cd ~/scripts
  curl -LO https://github.com/peass-ng/PEASS-ng/releases/latest/download/linpeas.sh
  mkdir /usr/share/wordlists && cd /usr/share/wordlists
  git clone --depth 1 https://github.com/danielmiessler/SecLists.git
  mkdir ~/scripts/winPEAS && cd ~/scripts/winPEAS
  curl -LO https://github.com/peass-ng/PEASS-ng/releases/latest/download/winPEASany.exe
  cd ~
}

install_development(){
  sudo xbps-install -Su go rust mise emacs
  install_antigravity
}

echo "  You selected: ${BOLD}${OPTIONS[$SELECTED]}${RESET}"
# Result
case $SELECTED in
  0) echo "  → Full setup..." ;;
  1) echo "  → Installing program..." ;;
  2) echo "  → Installing category..." ;;
  3) echo "  → Updating...";;
  4) echo "  → Goodbye!"; exit 0;;
esac
