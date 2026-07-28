#!/usr/bin/env bash

# if [ "$EUID" -ne 0 ]; then
#   echo "Please run as root (sudo)"
#   exit
# fi

# ----------------------
# Sub install functions
# ----------------------
setup_environment_paths() {
  local path_export='export PATH="$HOME/.local/bin:$HOME/go/bin:$PATH"'
  if ! grep -Fxq "$path_export" ~/.bashrc; then
    echo -e "\n# Security Lab Paths\n$path_export" >> ~/.bashrc
  fi
  export PATH="$HOME/.local/bin:$HOME/go/bin:$PATH"
}

ensure_user_path() {
  local CURRENT_USER="${SUDO_USER:-$USER}"
  local USER_HOME
  USER_HOME="$(eval echo "~$CURRENT_USER")"

  echo "[*] Configuring shell environment in $USER_HOME/.bashrc..."

  if ! grep -q '\.cargo/bin' "$USER_HOME/.bashrc"; then
    echo 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"' >> "$USER_HOME/.bashrc"
  fi

  if ! grep -q 'mise activate bash' "$USER_HOME/.bashrc"; then
    echo 'eval "$($HOME/.local/bin/mise activate bash)"' >> "$USER_HOME/.bashrc"
  fi

  chown "$CURRENT_USER:" "$USER_HOME/.bashrc"
}

install_nix() {
  echo "Installing Nix package manager..."
  local CURRENT_USER="${SUDO_USER:-$USER}"
  local USER_HOME
  USER_HOME="$(eval echo "~$CURRENT_USER")"

  if command -v xbps-install >/dev/null 2>&1; then
    echo "Ensuring base dependencies are present..."
    sudo xbps-install -Sy curl tar xz ca-certificates
  fi

  if [ -L /var/service/nix-daemon ]; then
    echo "Stopping active nix-daemon service..."
    sudo sv down nix-daemon >/dev/null 2>&1 || true
    sudo rm -f /var/service/nix-daemon
  fi
  sudo pkill -x nix-daemon >/dev/null 2>&1 || true

  echo "Cleaning up leftover backup files..."
  sudo rm -f /etc/bashrc.backup-before-nix \
             /etc/zshrc.backup-before-nix \
             /etc/bash.bashrc.backup-before-nix

  if ! command -v nix >/dev/null 2>&1; then
    echo "Installing official Nix binary..."
    yes | sh <(curl -L https://nixos.org/nix/install) --daemon
  else
    echo "Nix binary is already installed."
  fi

  echo "Setting up Void Linux SSL certificate environment..."
  sudo mkdir -p /etc/profile.d
  cat << 'EOF' | sudo tee /etc/profile.d/nix-ssl.sh > /dev/null
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
EOF
  sudo chmod +x /etc/profile.d/nix-ssl.sh
  . /etc/profile.d/nix-ssl.sh

  echo "Configuring runit service for nix-daemon..."
  sudo mkdir -p /etc/sv/nix-daemon
  cat << 'EOF' | sudo tee /etc/sv/nix-daemon/run > /dev/null
#!/bin/sh
exec 2>&1
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
exec /nix/var/nix/profiles/default/bin/nix-daemon
EOF
  sudo chmod +x /etc/sv/nix-daemon/run

  sudo ln -sf /etc/sv/nix-daemon /var/service/

  echo "Waiting for runit to initialize service..."
  local sv_wait=10
  while [ ! -d /etc/sv/nix-daemon/supervise ] && [ "$sv_wait" -gt 0 ]; do
    sleep 1
    sv_wait=$((sv_wait - 1))
  done

  sudo sv up nix-daemon

  if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  fi

  echo "Configuring /etc/nix/nix.conf..."
  sudo mkdir -p /etc/nix
  cat << EOF | sudo tee /etc/nix/nix.conf > /dev/null
experimental-features = nix-command flakes
trusted-users = root ${CURRENT_USER}
EOF

  # Target the ACTUAL user's config directory, not root's ~
  sudo -u "$CURRENT_USER" mkdir -p "$USER_HOME/.config/nixpkgs"
  echo '{ allowUnfree = true; }' | sudo -u "$CURRENT_USER" tee "$USER_HOME/.config/nixpkgs/config.nix" >/dev/null

  sudo sv restart nix-daemon

  echo "Verifying daemon store connection..."
  local NIX_BIN="/nix/var/nix/profiles/default/bin/nix"
  local retries=15
  until "$NIX_BIN" store ping >/dev/null 2>&1 || [ "$retries" -eq 0 ]; do
    sleep 1
    retries=$((retries - 1))
  done

  if [ "$retries" -eq 0 ]; then
    echo "Error: nix-daemon failed to respond in time."
    return 1
  fi

  echo "Done..."
}

install_uv() {
  echo "Installing uv..."
  local CURRENT_USER="${SUDO_USER:-$USER}"
  local USER_HOME
  USER_HOME="$(eval echo "~$CURRENT_USER")"

  echo "Installing uv for $CURRENT_USER..."
  sudo -u "$CURRENT_USER" env HOME="$USER_HOME" sh -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'

  ensure_user_path
  echo "Done..."
}

install_mise() {
  echo "Installing mise..."
  local CURRENT_USER="${SUDO_USER:-$USER}"
  local USER_HOME
  USER_HOME="$(eval echo "~$CURRENT_USER")"

  echo "Installing mise for $CURRENT_USER..."
  sudo -u "$CURRENT_USER" env HOME="$USER_HOME" sh -c 'curl https://mise.jdx.dev/install.sh | sh'

  # Refresh environment paths before using mise commands
  ensure_user_path

  echo "[*] Installing languages via mise..."
  sudo -u "$CURRENT_USER" env HOME="$USER_HOME" PATH="$PATH" "$USER_HOME/.local/bin/mise" use -g go@latest
  sudo -u "$CURRENT_USER" env HOME="$USER_HOME" PATH="$PATH" "$USER_HOME/.local/bin/mise" use -g python@3.12
  sudo -u "$CURRENT_USER" env HOME="$USER_HOME" PATH="$PATH" "$USER_HOME/.local/bin/mise" use -g rust@latest
  echo "Done..."
}


install_autopsy(){
  echo "Installing Autopsy..."
  sudo xbps-install -S -y sleuthkit openjdk17-jre testdisk afflib-devel libewf-devel wget unzip

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
  echo "Installing Burp Suite..."
  INSTALL_DIR="$HOME/Tools/BurpSuite"
  mkdir -p "$INSTALL_DIR"

  if [ -f "$INSTALL_DIR/burpsuite_community" ]; then
    echo "Burp Suite already installed."
  else
    wget -O /tmp/burp_installer.sh "https://portswigger.net/burp/releases/download?product=community&version=2026.3&type=Linux"
    chmod +x /tmp/burp_installer.sh
    /tmp/burp_installer.sh -c -q -dir "$INSTALL_DIR"
    # CLEANUP: Remove installer after success
    rm -f /tmp/burp_installer.sh
  fi

  BUNDLED_JAVA=$(find "$INSTALL_DIR" -name java -type f | head -n 1)
  [ -n "$BUNDLED_JAVA" ] && sudo setcap 'cap_net_bind_service=+ep' "$BUNDLED_JAVA"

  ln -sf "$INSTALL_DIR/burpsuite_community" "$HOME/.local/bin/burpsuite"
  echo "Done..."
}

install_caido(){
  echo "Installing Caido..."
  # DEPENDENCY: Ensure fuse is installed for AppImage execution
  sudo xbps-install -S -y fuse

  VERSION="0.55.3"
  INSTALL_DIR="$HOME/Tools/caido"
  mkdir -p "$INSTALL_DIR"

  # Install CLI
  if [ ! -f "$INSTALL_DIR/caido-cli" ]; then
    wget -O "$INSTALL_DIR/caido-cli.tar.gz" "https://github.com/caido/caido/releases/download/v${VERSION}/caido-cli-v${VERSION}-linux-x86_64.tar.gz"
    tar -xzf "$INSTALL_DIR/caido-cli.tar.gz" -C "$INSTALL_DIR"
    rm -f "$INSTALL_DIR/caido-cli.tar.gz" # Cleanup
    chmod +x "$INSTALL_DIR/caido-cli"
    sudo setcap 'cap_net_bind_service=+ep' "$INSTALL_DIR/caido-cli"
  fi
  ln -sf "$INSTALL_DIR/caido-cli" "$HOME/.local/bin/caido-cli"

  # Install Desktop
  if [ ! -f "$INSTALL_DIR/caido-desktop.AppImage" ]; then
    wget -O "$INSTALL_DIR/caido-desktop.AppImage" "https://github.com/caido/caido/releases/download/v${VERSION}/caido-desktop-v${VERSION}-linux-x86_64.AppImage"
    chmod +x "$INSTALL_DIR/caido-desktop.AppImage"
  fi
  ln -sf "$INSTALL_DIR/caido-desktop.AppImage" "$HOME/.local/bin/caido"
  echo "Done..."
}

install_adaptix() {
  echo "Installing Adaptix..."
  sudo xbps-install -S -y go qt6-base-devel qt6-svg-devel qt6-declarative-devel gcc make cmake git
  INSTALL_DIR="$HOME/Tools/adaptix"
  mkdir -p "$INSTALL_DIR"

  if [ ! -d "$INSTALL_DIR/AdaptixC2" ]; then
    git clone --recursive https://github.com/Adaptix-Framework/AdaptixC2.git "$INSTALL_DIR/AdaptixC2"
  else
    cd "$INSTALL_DIR/AdaptixC2" && git pull --recurse-submodules
  fi

  cd "$INSTALL_DIR/AdaptixC2"

  # Build Server
  cd AdaptixServer
  go build -o ../bin/teamserver main.go
  cd ..

  # Build Client
  mkdir -p build && cd build
  cmake .. && make -j$(nproc)
  cp AdaptixClient ../bin/
  cd ..

  sudo setcap 'cap_net_bind_service=+ep' bin/teamserver
  ln -sf "$INSTALL_DIR/AdaptixC2/bin/teamserver" "$HOME/.local/bin/adaptix-server"
  ln -sf "$INSTALL_DIR/AdaptixC2/bin/AdaptixClient" "$HOME/.local/bin/adaptix-client"
  echo "Adaptix ready."
}

install_pretender() {
    echo "Installing pretender..."
    export GOPATH="${GOPATH:-$HOME/.local/share/go}"
    export PATH="$GOPATH/bin:$PATH"
    go install github.com/RedTeamPentesting/pretender@latest

    if [ -f "$GOPATH/bin/pretender" ]; then
        sudo setcap cap_net_raw,cap_net_admin=eip "$GOPATH/bin/pretender"
        echo "Successfully set capabilities for pretender."
    else
        echo "Error: pretender binary not found at $GOPATH/bin/pretender"
        return 1
    fi
    echo "Done..."
}

install_sliver() {
  echo "Installing Sliver Adversary Emulation Framework..."
  VERSION="1.5.42" # Update this to the latest BishopFox release as needed
  SERVER_URL="https://github.com/BishopFox/sliver/releases/download/v${VERSION}/sliver-server_linux"
  CLIENT_URL="https://github.com/BishopFox/sliver/releases/download/v${VERSION}/sliver-client_linux"
  INSTALL_DIR="$HOME/Tools/sliver"

  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  wget -O sliver-server "$SERVER_URL"
  wget -O sliver-client "$CLIENT_URL"
  chmod +x sliver-server sliver-client

  # Mingw for generating Windows-specific payloads.
  sudo xbps-install -S -y mingw-w64-gcc

  # Capabilities for listeners
  sudo setcap 'cap_net_bind_service=+ep' "$INSTALL_DIR/sliver-server"

  # Sync Launchers
  ln -sf "$INSTALL_DIR/sliver-server" "$HOME/.local/bin/sliver-server"
  ln -sf "$INSTALL_DIR/sliver-client" "$HOME/.local/bin/sliver-client"
  echo "Sliver ready."
}

# ----------------------
# Main install functions
# ----------------------
install_utilities() {
  sudo xbps-install -Su -y xtools terminator tmux fzf bat ripgrep chromium tor proxychains-ng socat wget git openvpn openssl jq yq bleachbit
  install_mise
  install_uv
  install_nix
  ensure_user_path
}

install_container_tools(){
  set -e
  sudo xbps-install -Su -y docker docker-compose podman incus shadow

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
  echo "Installing cloud tools..."
  uv tool install prowler
  uv tool install pacu
  uv tool install cloudsplaining

  # Recon & Scanning
  mise use -g github:trufflesecurity/trufflehog@latest
  mise use -g github:aquasecurity/trivy@latest

  # Install Steampipe
  mise use -g github:turbot/steampipe@latest
  steampipe plugin install aws gcp azure

  # Secrets
  mise use -g github:zricethezav/gitleaks@latest
  uv tool install kube-hunter
  echo "Done..."
}

install_forensics(){
  sudo xbps-install -Su -y binwalk foremost stegseek yara exiftool
  uv tool install volatility3

  # Install logparsring tools
  cargo install evtx
  # Install Autopsy
  install_autopsy
}

install_reverse(){
  echo "Installing reverse engineering tools..."
  local CURRENT_USER="${SUDO_USER:-$USER}"
  local USER_HOME
  USER_HOME="$(eval echo "~$CURRENT_USER")"

  export PATH="$USER_HOME/.local/bin:$USER_HOME/.local/share/mise/bin:$PATH"

  echo "[*] Installing reverse engineering system packages..."
  sudo xbps-install -Su -y xxd imhex ghidra rizin cutter gdb strace ltrace \
                           openjdk17 libxcb-devel xcb-util-wm-devel xcb-util-image-devel \
                           xcb-util-keysyms-devel xcb-util-renderutil-devel

  sudo xbps-alternatives -s openjdk17

  # Android tools
  echo "[*] Installing Android tools..."
  sudo xbps-install -Su -y android-tools apktool

  sudo groupadd -f adbusers
  sudo usermod -aG adbusers "$CURRENT_USER"

  echo "[*] Installing Python RE tools..."
  sudo -u "$CURRENT_USER" env HOME="$USER_HOME" PATH="$PATH" uv tool install ropgadget
  sudo -u "$CURRENT_USER" env HOME="$USER_HOME" PATH="$PATH" uv tool install angr-management
  sudo -u "$CURRENT_USER" env HOME="$USER_HOME" PATH="$PATH" uv tool install frida-tools
  sudo -u "$CURRENT_USER" env HOME="$USER_HOME" PATH="$PATH" uv tool install objection

  echo "[*] Installing JADX..."
  sudo -u "$CURRENT_USER" env HOME="$USER_HOME" PATH="$PATH" "$USER_HOME/.local/bin/mise" use -g github:skylot/jadx@latest
  echo "Done..."
}

install_password(){
  sudo xbps-install -Su -y hashcat john thc-hydra cewl
}

install_wireless(){
  sudo xbps-install -Su -y aircrack-ng kismet hxctools hcxdumptool

  # Install airgeddon
  git clone --depth 1 https://github.com/v1s1t0r1sh3r3/airgeddon.git
  cd airgeddon
  sudo bash airgeddon.sh
}

install_network(){
  echo "Installing and refreshing network tools..."
  local CURRENT_USER="${SUDO_USER:-$USER}"
  local USER_HOME
  USER_HOME="$(eval echo "~$CURRENT_USER")"

  # Ensure user local binary directories exist
  sudo -u "$CURRENT_USER" mkdir -p "$USER_HOME/.local/bin" "$USER_HOME/.cargo/bin"

  # Environment paths
  export PATH="$USER_HOME/.local/bin:$USER_HOME/.cargo/bin:$USER_HOME/.local/share/mise/shims:$PATH"

  echo "[*] Installing system network tools..."
  # Added 'net-tools' for netstat support in bettercap
  sudo xbps-install -Su -y wireshark tcpdump arpwatch proxychains-ng netcat \
                           libpcap-devel libseccomp-devel cargo net-tools

  sudo groupadd -f wireshark
  sudo usermod -aG wireshark "$CURRENT_USER"

  # Compatibility symlink for precompiled bettercap
  [ ! -e /usr/lib/libpcap.so.0.8 ] && sudo ln -s /usr/lib/libpcap.so /usr/lib/libpcap.so.0.8

  echo "[*] Installing Scapy with cryptography and IPython shell..."
  # Replaced pyx with ipython for auto-completion and clean shell history
  sudo -u "$CURRENT_USER" env HOME="$USER_HOME" PATH="$PATH" uv tool install --force scapy --with cryptography --with ipython
  SCAPY_PATH="$USER_HOME/.local/bin/scapy"
  [ -f "$SCAPY_PATH" ] && sudo setcap cap_net_raw,cap_net_admin=eip "$SCAPY_PATH"

  echo "[*] Installing Sniffglue..."
  sudo -u "$CURRENT_USER" env HOME="$USER_HOME" PATH="$PATH" cargo install --force sniffglue
  SNIFFGLUE_PATH="$USER_HOME/.cargo/bin/sniffglue"
  [ -f "$SNIFFGLUE_PATH" ] && sudo setcap cap_net_raw,cap_net_admin=eip "$SNIFFGLUE_PATH"

  echo "[*] Installing Bettercap..."
  sudo -u "$CURRENT_USER" env HOME="$USER_HOME" PATH="$PATH" "$USER_HOME/.local/bin/mise" use -g --force github:bettercap/bettercap@latest

  RAW_BETTERCAP="$(sudo -u "$CURRENT_USER" env HOME="$USER_HOME" PATH="$PATH" "$USER_HOME/.local/bin/mise" which bettercap 2>/dev/null)"
  if [ -n "$RAW_BETTERCAP" ]; then
    REAL_BETTERCAP="$(readlink -f "$RAW_BETTERCAP")"
    [ -f "$REAL_BETTERCAP" ] && sudo setcap cap_net_raw,cap_net_admin=eip "$REAL_BETTERCAP"
  fi

  echo "Done..."
}

install_recon_and_scanning(){
  sudo xbps-install -Su -y nmap masscan

  # Install project discovery suite
  mise use -g github:projectdiscovery/subfinder@latest
  mise use -g github:projectdiscovery/httpx@latest
  mise use -g github:projectdiscovery/dnsx@latest
  mise use -g github:projectdiscovery/nuclei@latest
  mise use -g github:projectdiscovery/naabu@latest
  mise use -g github:projectdiscovery/cvemap@latest
  sudo setcap 'cap_net_raw,cap_net_admin+eip' $(which naabu)

  mise use -g github:epi052/feroxbuster@latest

  # Install amass
  mise use -g github:owasp-amass/amass@latest
  mkdir -p ~/Documents/Engagements/_amass_db
  # e.g. usage: amass enum -d example.com -dir ~/Documents/Engagements/_amass_db
}

install_exploitation(){
  uv tool install impacket
  uv tool install responder
  uv tool install evil-winrm
  uv tool install netexec
  uv tool install certipy-ad
  uv tool install mitm6

  # Install pwntools
  sudo xbps-install -S binutils-multiarch libelf-devel libffi-devel openssl-devel -y
  uv tool install pwntools

  # Install searchsploit
  sudo git clone https://gitlab.com/exploit-database/exploitdb.git /opt/exploitdb
  sudo ln -sf /opt/exploitdb/searchsploit /usr/local/bin/searchsploit
  cp -n /opt/exploit-database/.searchsploit_rc ~/

  # Install metasploit
  nix profile add nixpkgs#metasploit

  # Payloads & Utilities
  nix profile add nixpkgs#cosign

  # SharpCollection (Syncing to Tools)
  mkdir -p ~/Tools/SharpCollection
  git clone --depth 1 https://github.com/Flangvik/SharpCollection.git ~/Tools/SharpCollection

  # --- C2 & Capability-Required Tooling ---
  # Install Adaptix
  install_adaptix

  # Install sliver
  nix profile add nixpkgs#sliver

  # Install Pretender
  nix profile add nixpkgs#bloodhound

  export PATH="$HOME/.local/bin:$HOME/.nix-profile/bin:$PATH"
  alias bloodhound='BloodHound --no-sandbox'
}

install_web_testing(){
  echo "Updating system packages..."
  sudo xbps-install -S nikto

  echo "Installing Python-based tools..."
  uv tool install sqlmap
  uv tool install xsstrike

  echo "Installing Go/Binary tools..."
  mise use -g go@latest
  go install github.com/ffuf/ffuf/v2@latest
  go install github.com/OJ/gobuster/v3@latest
  go install github.com/epi052/feroxbuster@latest
  go install github.com/hahwul/dalfox/v3@latest

  install_burp
  install_caido

  local bashrc="$HOME/.bashrc"

  grep -q "alias burpsuite=" "$bashrc" || \
    echo "alias burpsuite='LD_LIBRARY_PATH=\$HOME/Tools/BurpSuite/lib burpsuite'" >> "$bashrc"

  grep -q "alias caido=" "$bashrc" || \
    echo "alias caido='caido --no-sandbox'" >> "$bashrc"
}

install_scripts(){
  echo "Installing scripts..."
  local SCRIPT_DIR="$HOME/.local/share/scripts"
  mkdir -p "$SCRIPT_DIR/linux" "$SCRIPT_DIR/windows" "$SCRIPT_DIR/wordlists"
  curl -fsSL https://github.com/peass-ng/PEASS-ng/releases/latest/download/linpeas.sh \
    -o "$SCRIPT_DIR/linux/linpeas.sh"
  curl -fsSL https://raw.githubusercontent.com/mzet-/linux-exploit-suggester/master/linux-exploit-suggester.sh \
    -o "$SCRIPT_DIR/linux/les.sh"
  chmod +x "$SCRIPT_DIR/linux/"*.sh
  curl -fsSL https://github.com/peass-ng/PEASS-ng/releases/latest/download/winPEASany.exe \
    -o "$SCRIPT_DIR/windows/winPEAS.exe"
  curl -fsSL https://raw.githubusercontent.com/PowerShellMafia/PowerSploit/master/Recon/PowerView.ps1 \
    -o "$SCRIPT_DIR/windows/PowerView.ps1"
  if [ ! -d "$SCRIPT_DIR/wordlists/SecLists" ]; then
    git clone --depth 1 https://github.com/danielmiessler/SecLists.git "$SCRIPT_DIR/wordlists/SecLists"
  fi
  sudo ln -sfn "$SCRIPT_DIR/wordlists" /usr/share/wordlists 2>/dev/null || echo "(!) Note: Manual sudo required to link /usr/share/wordlists"
  echo "Scripts available in $SCRIPT_DIR..."
  echo "Done..."
}

install_reporting(){
  # Install reporting tools
  nix profile add nixpkgs#quarto

}

install_development(){
  sudo xbps-install -Su python3 cargo emacs joe -y
}

full_install() {
  install_utilities
  install_development
  install_network
  install_container_tools
  install_recon_and_scanning
  install_exploitation
  install_wireless
  install_web_testing
  install_scripts
  install_password
  install_forensics
  install_reverse
  install_cloud
  echo "===================================================="
  echo " BUILD COMPLETE: Your system is live."
  echo "===================================================="
}

#!/usr/bin/env bash

multi_install() {
  local funcs=(
    "install_utilities"
    "install_development"
    "install_network"
    "install_container_tools"
    "install_recon_and_scanning"
    "install_exploitation"
    "install_wireless"
    "install_web_testing"
    "install_scripts"
    "install_password"
    "install_forensics"
    "install_reverse"
    "install_cloud"
  )

  local labels=(
    "Basic Utilities"
    "Development Tools"
    "Networking Utilities"
    "Container Tools (Incus / Podman)"
    "Reconnaissance & Scanning"
    "Exploitation Frameworks"
    "Wireless Security Tools"
    "Web Application Testing"
    "Custom Scripts & Wordlists"
    "Password & Hash Cracking"
    "Digital Forensics Tools"
    "Reverse Engineering"
    "Cloud Security Tools"
  )

  local count=${#funcs[@]}
  local choices=()
  for ((i=0; i<count; i++)); do
    choices[i]=0 # 0 = unselected, 1 = selected
  done

  local current=0

  cursor_off() { printf "\e[?25l"; }
  cursor_on()  { printf "\e[?25h"; }
  trap 'cursor_on; echo -e "\n\e[31m[!] Selection cancelled.\e[0m"; return 1' INT TERM

  draw_menu() {
    printf "\e[1;33m=== Custom Platform Module Selection ===\e[0m\n\n"
    for ((i=0; i<count; i++)); do
      local mark="[ ]"
      [[ ${choices[i]} -eq 1 ]] && mark="[\e[32mX\e[0m]"

      if [[ $i -eq $current ]]; then
        printf " \e[1;36m>\e[0m %b \e[1;37m%s\e[0m\n" "$mark" "${labels[i]}"
      else
        printf "   %b %s\n" "$mark" "${labels[i]}"
      fi
    done
    printf "\n\e[90mControls: [↑/↓ or C-p/C-n] Move | [Space] Toggle | [a] Select All | [n] Select None | [Enter] Confirm\e[0m\n"
  }

  clear_menu() {
    local lines_to_clear=$((count + 4))
    for ((i=0; i<lines_to_clear; i++)); do
      printf "\e[1A\e[K"
    done
  }

  cursor_off
  draw_menu

  while true; do
    IFS= read -rsn1 key
    case "$key" in
      $'\x1b')
        read -rsn2 -t 0.1 key2
        case "$key2" in
          '[A'|'OA')
            ((current--))
            [[ $current -lt 0 ]] && current=$((count - 1))
            ;;
          '[B'|'OB')
            ((current++))
            [[ $current -ge $count ]] && current=0
            ;;
        esac
        ;;
      $'\x10')
        ((current--))
        [[ $current -lt 0 ]] && current=$((count - 1))
        ;;
      $'\x0e')
        ((current++))
        [[ $current -ge $count ]] && current=0
        ;;
      ' ')
        choices[current]=$((1 - choices[current]))
        ;;
      'a'|'A')
        for ((i=0; i<count; i++)); do choices[i]=1; done
        ;;
      'n'|'N')
        for ((i=0; i<count; i++)); do choices[i]=0; done
        ;;
      ''|$'\n'|$'\r')
        break
        ;;
    esac
    clear_menu
    draw_menu
  done

  cursor_on
  echo ""

  local selected_funcs=()
  for ((i=0; i<count; i++)); do
    if [[ ${choices[i]} -eq 1 ]]; then
      selected_funcs+=("${funcs[i]}")
    fi
  done

  if [[ ${#selected_funcs[@]} -eq 0 ]]; then
    echo -e "\e[33m[!] No modules selected. Returning to main menu.\e[0m"
    return 0
  fi

  echo -e "\e[1;32m[*] Executing ${#selected_funcs[@]} selected installation block(s)...\e[0m\n"
  for fn in "${selected_funcs[@]}"; do
    echo -e "\e[1;34m[>] Running step: $fn\e[0m"
    "$fn"
  done

  echo -e "\n\e[1;32m[+] Selected installations completed successfully!\e[0m"
}

update_system() {
  echo "Syncing repositories and updating Void Linux..."
  sudo xbps-install -Su -y
}

test_function(){
  install_exploitation
}

trap 'tput cnorm' EXIT

OPTIONS=(
  "1. Full setup"
  "2. Select And Install"
  "3. Update"
  "4. Test"
  "5. Exit"
)


# UI related functions
SELECTED=0
TOTAL=${#OPTIONS[@]}

# ANSI escape codes
ESC=$(printf '\033')
CURSOR_UP="${ESC}[A"
CLEAR_LINE="${ESC}[2K"
BOLD="${ESC}[1m"
RESET="${ESC}[0m"
HIGHLIGHT="${ESC}[7m"   # reverse video

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

case $SELECTED in
  0) echo "  → Full setup..." ;;
  1)
    echo "  → Selection Install..."
    multi_install ;;
  2) echo "  → Updating...";;
  3) echo "  → Testing..." ;;
  4) echo "  → Goodbye!"; exit 0;;
esac
