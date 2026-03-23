!/usr/bin/env bash

# if [ "$EUID" -ne 0 ]; then
#   echo "Please run as root (sudo)"
#   exit
# fi

# ----------------------
# Sub install functions
# ----------------------
install_uv() {
  echo "Installing uv..."
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
  echo "Done..."
}

install_mise() {
    echo "Installing mise..."

    curl https://mise.jdx.dev/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    export PATH="$HOME/.local/share/mise/bin:$PATH"
    if ! grep -q 'mise activate bash' "$HOME/.bashrc"; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
        echo 'eval "$(~/.local/bin/mise activate bash)"' >> "$HOME/.bashrc"
        echo "--- Added Mise activation to .bashrc ---"
    fi
    eval "$($HOME/.local/bin/mise activate bash)"

    mise use -g go@latest
    mise use -g python@3.12
    mise use -g rust@latest

    echo "Done..."
}

install_autopsy(){
  echo "Installing Autopsy..."
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
}

install_burp(){
  echo "Installing burpsuite"
  BURP_URL="https://portswigger.net/burp/releases/download?product=pro&version=2026.3&type=Linux"
  INSTALLER_NAME="burpsuite_community_linux.sh"
  INSTALL_DIR="$HOME/Tools/BurpSuite"

  echo "Preparing Burp Suite Installation"
  mkdir -p "$INSTALL_DIR"

  #  Download Installer
  if [ ! -f "$INSTALLER_NAME" ]; then
  echo "Downloading Burp Suite Community"
  wget -O "$INSTALLER_NAME" "$BURP_URL"
  fi

  echo "Running Installer"
  chmod +x "$INSTALLER_NAME"
  ./"$INSTALLER_NAME" -c

  echo "Granting Network Capabilities to Burp's Bundled JRE"
  BUNDLED_JAVA=$(find "$INSTALL_DIR" -name java -type f)

  if [ -n "$BUNDLED_JAVA" ]; then
  sudo setcap 'cap_net_bind_service=+ep' "$BUNDLED_JAVA"
  echo "Capabilities applied to: $BUNDLED_JAVA"
  else
    echo "Warning: Could not find bundled Java to apply capabilities."
  fi

  # Launcher Sync
  if [ -f "$INSTALL_DIR/burpsuite_community" ]; then
    ln -sf "$INSTALL_DIR/burpsuite_community" "$HOME/.local/bin/burpsuite"
    echo "Setup Complete! Run with 'burpsuite'"
  fi
}

install_caido(){
  echo "Installing Caido..."
  VERSION="0.55.3"
  CAIDO_CLI_URL="https://github.com/caido/caido/releases/download/v${VERSION}/caido-cli-v${VERSION}-linux-x86_64.tar.gz"
  CAIDO_APP_URL="https://github.com/caido/caido/releases/download/v${VERSION}/caido-desktop-v${VERSION}-linux-x86_64.AppImage"
  INSTALL_DIR="$HOME/Tools/caido"

  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  # Install CLI
  wget -O caido-cli.tar.gz "$CAIDO_CLI_URL"
  tar -xzf caido-cli.tar.gz
  chmod +x caido-cli
  ln -sf "$INSTALL_DIR/caido-cli" "$HOME/.local/bin/caido-cli"

  # Install Desktop (AppImage)
  wget -O caido-desktop.AppImage "$CAIDO_APP_URL"
  chmod +x caido-desktop.AppImage
  ln -sf "$INSTALL_DIR/caido-desktop.AppImage" "$HOME/.local/bin/caido"

  # Capabilities (The Security Step)
  echo "Granting Network Capabilities to Caido CLI"
  sudo setcap 'cap_net_bind_service=+ep' "$INSTALL_DIR/caido-cli"
  echo "Done..."
}

install_adaptix() {
  echo "Installing adaptix..."
  sudo xbps-install -S go qt6-base-devel qt6-svg-devel qt6-declarative-devel \
    gcc make cmake git -y

  INSTALL_DIR="$HOME/Tools/adaptix"
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  if [ ! -d "AdaptixC2" ]; then
    git clone --recursive https://github.com/Adaptix-Framework/AdaptixC2.git
  fi
  cd AdaptixC2

  cd AdaptixServer
  go build -o ../bin/teamserver main.go
  cd ..

  mkdir -p build && cd build
  cmake ..
  make -j$(nproc)
  cp AdaptixClient ../bin/
  cd ..

  sudo setcap 'cap_net_bind_service=+ep' bin/teamserver

  ln -sf "$INSTALL_DIR/AdaptixC2/bin/teamserver" "$HOME/.local/bin/adaptix-server"
  ln -sf "$INSTALL_DIR/AdaptixC2/bin/AdaptixClient" "$HOME/.local/bin/adaptix-client"
  echo "Done..."
}

install_pretender() {
  echo "Installing pretender..."
  cd ~/void-packages
  PKG_NAME="pretender"
  VERSION="1.3.2"
  REPO_DIR=$(pwd)
  TEMPLATE_DIR="$REPO_DIR/srcpkgs/$PKG_NAME"

  # Safety Check: Ensure the location is void-packages root
  if [ ! -d "$REPO_DIR/srcpkgs" ]; then
  echo "Error: Please run this script from the root of your void-packages directory."
  exit 1
  fi

  echo "Preparing to build $PKG_NAME v$VERSION ..."
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
  echo "$PKG_NAME v$VERSION is now installed and ready!"
}

install_msf() {
  echo "Installing metasploit..."
  sudo xbps-install -S postgresql postgresql-libs-devel libpcap-devel \
    libxml2-devel libxslt-devel readline-devel sqlite-devel \
    ncurses-devel libffi-devel openssl-devel zlib-devel -y

  INSTALL_DIR="$HOME/Tools/metasploit"
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  curl https://raw.githubusercontent.com/rapid7/metasploit-omnibus/master/config/templates/metasploit-framework-wrappers/msfupdate.erb > msfinstall
  chmod +x msfinstall
  ./msfinstall

  # Capabilities
  MSF_RUBY="/opt/metasploit-framework/embedded/bin/ruby"
  sudo setcap 'cap_net_bind_service=+ep' "$MSF_RUBY"

  echo "Initializing Metasploit Database..."
  msfdb init

  # Sync Launchers
  ln -sf /opt/metasploit-framework/bin/msfconsole "$HOME/.local/bin/msfconsole"
  ln -sf /opt/metasploit-framework/bin/msfvenom "$HOME/.local/bin/msfvenom"

  echo "Done..."
}

install_sliver() {
  echo "Installing sliver Adversary Emulation Framework..."
  VERSION="1.7.3"
  SERVER_URL="https://github.com/BishopFox/sliver/releases/download/v${VERSION}/sliver-server_linux"
  CLIENT_URL="https://github.com/BishopFox/sliver/releases/download/v${VERSION}/sliver-client_linux"
  INSTALL_DIR="$HOME/Tools/sliver"
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  wget -O sliver-server "$SERVER_URL"
  wget -O sliver-client "$CLIENT_URL"
  chmod +x sliver-server sliver-client

  # Mingw for generating Windows-specific payloads.
  sudo xbps-install -S mingw-w64-gcc -y

  # Capabilities
  sudo setcap 'cap_net_bind_service=+ep' "$INSTALL_DIR/sliver-server"

  # Sync Launchers
  ln -sf "$INSTALL_DIR/sliver-server" "$HOME/.local/bin/sliver-server"
  ln -sf "$INSTALL_DIR/sliver-client" "$HOME/.local/bin/sliver-client"
  echo "Done..."
}

install_bloodhound() {
  echo "Installing bloodhound"
  mkdir -p ~/Tools/bloodhound && cd ~/Tools/bloodhound
  tar -xvzf bloodhound-cli-linux-amd64.tar.gz
  ./bloodhound-cli install
  ln -sf ~/Tools/bloodhound/bloodhound-cli ~/.local/bin/bloodhound-cli
}

# ----------------------
# Main install functions
# ----------------------

setup_void_packages(){
  cd ~
  git clone --depth 1 https://github.com/void-linux/void-packages.git
  cd void-packages
  ./xbps-src binary-bootstrap
}

install_utils() {
  sudo xbps-install -Su
  sudo xbps-install -S xtools terminator tmux fzf ripgrep chromium tor proxychains-ng socat wget git openvpn openssl jq yq bleachbit -y
  install_mise
  install_uv
  setup_void_packages
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
  # install_autopsy
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
  sudo xbps-install -Su wireshark tcpdump arpwatch proxychains-ng

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

  # Install pwntools
  sudo xbps-install -S binutils-multiarch libelf-devel libffi-devel openssl-devel -y
  uv tool install pwntools

  # Install searchsploit
  sudo git clone https://gitlab.com/exploit-database/exploitdb.git /opt/exploitdb
  sudo ln -sf /opt/exploitdb/searchsploit /usr/local/bin/searchsploit
  cp -n /opt/exploit-database/.searchsploit_rc ~/

  # Install Pretender
  # install_pretender
  # Todo - Test Pretender
}

install_web_testing(){
  sudo xbps-install -S nikto
  uv tool install sqlmap
  uv tool install xsstrike

  # Install ffuf
  mise use -g github:ffuf/ffuf@latest

  # Install gobuster
  mise use -g github:OJ/gobuster@latest

  # Install feroxbuster
  mise use -g github:epi052/feroxbuster@latest

  # Install dalfox
  mise use -g github:hahwul/dalfox@latest

  # Install Burp
  # install_burp

  # Install Caido
  # install_caido

}

install_recon_and_scanning(){
  sudo xbps-install -Su nmap masscan netcat -y

  # Install project discovery suite
  mise use -g github:projectdiscovery/subfinder@latest
  mise use -g github:projectdiscovery/httpx@latest
  mise use -g github:projectdiscovery/dnsx@latest
  mise use -g github:projectdiscovery/nuclei@latest
  mise use -g github:projectdiscovery/naabu@latest
  mise use -g github:projectdiscovery/cvemap@latest

  sudo setcap 'cap_net_raw,cap_net_admin+eip' $(which naabu)

  # Install amass
  mise use -g github:owasp-amass/amass@latest
  mkdir -p ~/Documents/Engagements/_amass_db
  # e.g. usage: amass enum -d example.com -dir ~/Documents/Engagements/_amass_db
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
  sudo xbps-install -Su python3 emacs helix -y
}

trap 'tput cnorm' EXIT

OPTIONS=(
  "1. Full setup"
  "2. Install by category"
  "3. Update"
  "4. Testing"
  "5. Exit"
)

# ----------------------
# UI related functions
#-----------------------
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

echo "  You selected: ${BOLD}${OPTIONS[$SELECTED]}${RESET}"
# Result
case $SELECTED in
  0) echo "  → Full setup..." ;;
  1) echo "  → Installing category..." ;;
  2) echo "  → Updating...";;
  3)
    echo "  → Testing"
    install_mise ;;
  4) echo "  → Goodbye!"; exit 0;;
esac
