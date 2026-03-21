#!/usr/bin/env bash

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit
fi

trap 'tput cnorm' EXIT

OPTIONS=(
  "1. Full setup"
  "2. Install by category"
  "3. Update"
  "4. Exit"
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

install_uv() {
  curl -LsSf https://astral.sh/uv/install.sh | sh

  local bin_path='export PATH="$HOME/.local/bin:$PATH"'
  if ! grep -Fxq "$bin_path" ~/.bashrc; then
    echo -e "\n# Local Bin Path\n$bin_path" >> ~/.bashrc
  fi

  local uv_completion='eval "$(uv generate-shell-completion bash)"'
  if ! grep -Fxq "$uv_completion" ~/.bashrc; then
    echo "$uv_completion" >> ~/.bashrc
    echo "Added uv shell completion to ~/.bashrc"
  fi

  export PATH="$HOME/.local/bin:$PATH"
  eval "$(uv generate-shell-completion bash)"
  echo "uv is ready! Try typing 'uv ' and hitting Tab."
}

install_mise(){
  echo "--- Installing Mise & Runtimes ---"
  curl https://mise.jdx.dev/install.sh | sh
  export PATH="$HOME/.local/share/mise/bin:$PATH"
  eval "$(mise activate bash)"
  mise install go@latest python@3.12 rust@latest
}

# -------
# Main install functions

setup_void_packages(){
  cd ~
  git clone --depth 1 https://github.com/void-linux/void-packages.git
  cd void-packages

  # Bootstrap the masterdir (the build container)
  ./xbps-src binary-bootstrap
}

install_utils() {
  sudo xbps-install -Su
  sudo xbps-install -S xtools terminator tmux fzf ripgrep chromium tor proxychains-ng socat wget git openvpn openssl jq yq bleachbit -y
}

install_container_tools(){
  set -e

  sudo xbps-install -Su docker docker-compose podman incus shadow

  # Configure Docker
  [ ! -L /var/service/containerd ] && sudo ln -s /etc/sv/containerd /var/service/
  [ ! -L /var/service/docker ] && sudo ln -s /etc/sv/docker /var/service/
  sudo usermod -aG docker "${USER}"

  # Configure Podman
  if ! grep -q "${USER}" /etc/subuid; then
    echo "Adding ${USER} to /etc/subuid and /etc/subgid..."
    # Assign a range of 65536 IDs starting at 100000
    echo "${USER}:100000:65536" | sudo tee -a /etc/subuid
    echo "${USER}:100000:65536" | sudo tee -a /etc/subgid
  fi

  # Configure Incus
  [ ! -L /var/service/incus ] && sudo ln -s /etc/sv/incus /var/service/
  [ ! -L /var/service/incus-user ] && sudo ln -s /etc/sv/incus-user /var/service/
  sudo usermod -aG _incus-admin ${USER}
}

install_cloud(){
  :
}

install_forensics(){
  sudo xbps-install -Su binwalk foremost stegseek yara exiftool
  uv tool install volatility3

  # Install Autopsy
  echo "Installing System Dependencies via XBPS"
  sudo xbps-install -S sleuthkit openjdk17-jre testdisk afflib-devel libewf-devel wget unzip -y

  # Directory Setup
  INSTALL_DIR="$HOME/Tools/autopsy"
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"
  URL="https://github.com/sleuthkit/autopsy/releases/download/autopsy-4.22.1/autopsy-4.22.1_v2.zip"
  ZIP_FILE="autopsy-4.22.1_v2.zip"

  if [ ! -f "$ZIP_FILE" ]; then
    echo "Downloading Autopsy 4.22.1_v2"
    wget "$URL"
  fi

  echo "Extracting Autopsy"
  unzip -q "$ZIP_FILE"
  cd autopsy-4.22.1

  # Unix Setup Script
  echo "Running Autopsy Unix Setup "
  chmod +x unix_setup.sh
  ./unix_setup.sh

  # Grant capabilities
  JAVA_PATH=$(which java)
  echo "Granting Network/Disk Capabilities to Java ($JAVA_PATH)"
  sudo setcap 'cap_dac_read_search,cap_sys_admin,cap_device_read+eip' "$JAVA_PATH"

  # Create Shortcuts
  echo "Creating Launcher"
  cat <<EOF > "$HOME/.local/bin/autopsy"
  #!/bin/bash
  cd $INSTALL_DIR/autopsy-4.22.1 && ./bin/autopsy
  EOF

  chmod +x "$HOME/.local/bin/autopsy"
  echo "Setup Complete! Launch by typing 'autopsy' in your terminal."

  # Todo - Test autopsy
}

install_reverse(){
  :
}

install_password(){
  sudo xbps-install -Su hashcat john thc-hydra -y
}

install_wireless(){
  sudo xbps-install -Su aircrack-ng kismet hxctools hcxdumptool -y

  # Install airgeddon
  git clone --depth 1 https://github.com/v1s1t0r1sh3r3/airgeddon.git
  cd airgeddon
  sudo bash airgeddon.sh
}

install_network(){
  sudo xbps-install -Su nmap masscan netcat wireshark tcpdump arpwatch proxychains-ng

  # Install scapy
  git clone --depth 1 https://github.com/void-linux/void-packages.git
  cd void-packages
  ./xbps-src binary-bootstrap
  ./xbps-src pkg scapy
  # sudo xi scapy
  sudo xbps-install --repository=hostdir/binpkgs scapy
  sudo setcap cap_net_raw,cap_net_admin=eip /usr/bin/scapy

  #Install bettercap
  ./xbps-src pkg bettercap
  sudo xbps-install --repository=hostdir/binpkgs bettercap
}

install_exploitation(){
  uv tool install impacket
  uv tool install responder
  uv tool install crackmapexec
  uv tool install evil-winrm
  uv tool install netexec

  # Install searchsploit
  sudo git clone https://gitlab.com/exploit-database/exploitdb.git /opt/exploitdb
  sudo ln -sf /opt/exploitdb/searchsploit /usr/local/bin/searchsploit
  cp -n /opt/exploit-database/.searchsploit_rc ~/

  # Install Pretender
  cd ~/void-packages

  # Configuration
  PKG_NAME="pretender"
  VERSION="1.3.2"
  REPO_DIR=$(pwd)
  TEMPLATE_DIR="$REPO_DIR/srcpkgs/$PKG_NAME"

  # Safety Check: Ensure the location is void-packages root
  if [ ! -d "$REPO_DIR/srcpkgs" ]; then
  echo "Error: Please run this script from the root of your void-packages directory."
  exit 1
  fi

  echo "--- Preparing to build $PKG_NAME v$VERSION ---"
  mkdir -p "$TEMPLATE_DIR"
  cat <<EOF > "$TEMPLATE_DIR/template"
# Template file for '$PKG_NAME'
pkgname=$PKG_NAME
version=$VERSION
revision=1
build_style=go
go_import_path="github.com/RedTeamPentesting/pretender"
distfiles="https://github.com/RedTeamPentesting/pretender/archive/refs/tags/v\${version}.tar.gz"
checksum=686884860d5e865487779f4105826f06774e6229413693952a6592231268615e
short_desc="MitM sidekick for relaying attacks (DHCPv6, mDNS, LLMNR)"
maintainer="User <user@voidlinux.org>"
license="MIT"
homepage="https://github.com/RedTeamPentesting/pretender"
EOF
  echo "Check: Template created at $TEMPLATE_DIR/template"

  ./xbps-src xgensum -i "$PKG_NAME"
  ./xbps-src pkg "$PKG_NAME"

  if [ $? -eq 0 ]; then
  echo "Build successful! Installing..."
  sudo xbps-install --repository=hostdir/binpkgs "$PKG_NAME"
  else
    echo "Error: Build failed. Check the output above."
    exit 1
  fi

  sudo setcap cap_net_raw,cap_net_admin,cap_net_bind_service=eip /usr/bin/pretender
  echo "--- $PKG_NAME v$VERSION is now installed and ready! ---"
  # Todo - Test Pretender
}

install_web_testing(){
  uv tool install sqlmap
  uv tool install xsstrike
}

install_recon(){
  :
}

install_scripts(){
  mkdir ~/scripts && cd ~/scripts
  curl -LO https://github.com/peass-ng/PEASS-ng/releases/latest/download/linpeas.sh
  mkdir ~/scripts/winPEAS && cd ~/scripts/winPEAS
  curl -LO https://github.com/peass-ng/PEASS-ng/releases/latest/download/winPEASany.exe
  mkdir /usr/share/wordlists && cd /usr/share/wordlists
  git clone --depth 1 https://github.com/danielmiessler/SecLists.git
  cd ~
}

install_development(){
  sudo xbps-install -Su go rust python3 emacs helix -y
}

echo "  You selected: ${BOLD}${OPTIONS[$SELECTED]}${RESET}"
# Result
case $SELECTED in
  0) echo "  → Full setup..." ;;
  1) echo "  → Installing category..." ;;
  2) echo "  → Updating...";;
  3) echo "  → Goodbye!"; exit 0;;
esac
