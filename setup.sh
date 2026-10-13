#!/usr/bin/env bash

# Sub install functions
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

  # Target user's config directory.
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
  echo -e "\n\e[1;33m[!] IMPORTANT: Nix has been installed, but your current terminal doesn't know about it yet.\e[0m"
  echo -e "\e[1;33m[!] Run 'source ~/.bashrc' or open a new terminal window to start using Nix.\e[0m\n"
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

  ensure_user_path

  echo "[*] Installing languages via mise..."
  sudo -u "$CURRENT_USER" env HOME="$USER_HOME" PATH="$PATH" "$USER_HOME/.local/bin/mise" use -g go@latest
  sudo -u "$CURRENT_USER" env HOME="$USER_HOME" PATH="$PATH" "$USER_HOME/.local/bin/mise" use -g python@3.12
  sudo -u "$CURRENT_USER" env HOME="$USER_HOME" PATH="$PATH" "$USER_HOME/.local/bin/mise" use -g rust@latest
  echo "Done..."
}

install_burp(){
  echo "Installing Burp Suite..."

  echo "Installing system Java dependency..."
  sudo xbps-install -Sy openjdk21
  local INSTALL_DIR="$TARGET_HOME/Tools/BurpSuite"
  as_user mkdir -p "$INSTALL_DIR"

  local BURP_EXEC=$(find "$INSTALL_DIR" -maxdepth 2 -name "BurpSuiteCommunity" -type f | head -n 1)

  if [ -n "$BURP_EXEC" ] && [ -x "$BURP_EXEC" ]; then
    echo "Burp Suite is already installed at $BURP_EXEC"
  else
    echo "Downloading installer..."
    as_user wget -q --show-progress -O /tmp/burp_installer.sh "https://portswigger.net/burp/releases/download?product=community&version=2026.3&type=Linux"
    chmod +x /tmp/burp_installer.sh

    echo "Running quiet installer as standard user..."
    as_user /tmp/burp_installer.sh -q -dir "$INSTALL_DIR"
    rm -f /tmp/burp_installer.sh

    BURP_EXEC=$(find "$INSTALL_DIR" -maxdepth 2 -name "BurpSuiteCommunity" -type f | head -n 1)
  fi

  if [ -z "$BURP_EXEC" ]; then
    echo "Error: Burp Suite binary could not be found in $INSTALL_DIR"
    return 1
  fi

  local BUNDLED_JAVA=$(find "$INSTALL_DIR" -name java -type f | head -n 1)
  if [ -n "$BUNDLED_JAVA" ]; then
    sudo setcap 'cap_net_bind_service=+ep' "$BUNDLED_JAVA"
  fi

  as_user rm -f "$TARGET_HOME/.local/bin/burpsuite"

  # Create a wrapper script that explicitly sets the Java path
  cat <<EOF | as_user tee "$TARGET_HOME/.local/bin/burpsuite" > /dev/null
#!/bin/bash
export INSTALL4J_JAVA_HOME="$INSTALL_DIR/jre"
exec "$BURP_EXEC" "\$@"
EOF

  as_user chmod +x "$TARGET_HOME/.local/bin/burpsuite"

  echo "Burp Suite installation complete! Run 'burpsuite' to launch."
}

install_caido(){
  echo "Installing Caido..."

  if ! xbps-query -s fuse >/dev/null 2>&1; then
    sudo xbps-install -Sy fuse
  fi

  # NOTE: Using TARGET_HOME here so it goes to /home/void!
  local INSTALL_DIR="$TARGET_HOME/Tools/caido"
  as_user mkdir -p "$INSTALL_DIR" "$TARGET_HOME/.local/bin"

  local VERSION=$(curl -s https://caido.download/releases/latest | grep -oP '"version":\s*"\K[^"]+' || echo "0.58.3")
  echo "Targeting Caido version: v${VERSION}"

  if [ ! -f "$INSTALL_DIR/caido-cli" ]; then
    echo "Downloading Caido CLI..."
    local CLI_URL="https://caido.download/releases/v${VERSION}/caido-cli-v${VERSION}-linux-x86_64.tar.gz"

    if as_user wget -q --show-progress -O "$INSTALL_DIR/caido-cli.tar.gz" "$CLI_URL"; then
      as_user tar -xzf "$INSTALL_DIR/caido-cli.tar.gz" -C "$INSTALL_DIR"
      as_user rm -f "$INSTALL_DIR/caido-cli.tar.gz"
      as_user chmod +x "$INSTALL_DIR/caido-cli"

      sudo setcap 'cap_net_bind_service=+ep' "$INSTALL_DIR/caido-cli"
    else
      echo "Error downloading Caido CLI from $CLI_URL"
      return 1
    fi
  fi
  as_user ln -sf "$INSTALL_DIR/caido-cli" "$TARGET_HOME/.local/bin/caido-cli"

  if [ ! -f "$INSTALL_DIR/caido-desktop.AppImage" ]; then
    echo "Downloading Caido Desktop..."
    local DESKTOP_URL="https://caido.download/releases/v${VERSION}/caido-desktop-v${VERSION}-linux-x86_64.AppImage"

    if as_user wget -q --show-progress -O "$INSTALL_DIR/caido-desktop.AppImage" "$DESKTOP_URL"; then
      as_user chmod +x "$INSTALL_DIR/caido-desktop.AppImage"
    else
      echo "Error downloading Caido Desktop AppImage from $DESKTOP_URL"
      return 1
    fi
  fi
  as_user ln -sf "$INSTALL_DIR/caido-desktop.AppImage" "$TARGET_HOME/.local/bin/caido"

  echo "Caido installation complete!"
}

install_adaptix() {
  echo "[*] Installing Adaptix Framework..."

  sudo xbps-install -y go qt6-base-devel qt6-svg-devel qt6-declarative-devel gcc make cmake git

  local INSTALL_DIR="$TARGET_HOME/Tools/adaptix"
  as_user mkdir -p "$INSTALL_DIR"

  echo " -> Fetching AdaptixC2 repository..."
  if [ ! -d "$INSTALL_DIR/AdaptixC2/.git" ]; then
    as_user git clone --recursive https://github.com/Adaptix-Framework/AdaptixC2.git "$INSTALL_DIR/AdaptixC2"
  else
    (cd "$INSTALL_DIR/AdaptixC2" && as_user git pull --recurse-submodules)
  fi

  echo " -> Compiling Teamserver..."
  (
    cd "$INSTALL_DIR/AdaptixC2/AdaptixServer" || return
    as_user mkdir -p ../bin
    as_user env GOPATH="$TARGET_HOME/go" go build -o ../bin/teamserver main.go
  )

  echo " -> Compiling Client (this may take a while)..."
  (
    cd "$INSTALL_DIR/AdaptixC2" || return
    as_user mkdir -p build
    cd build || return
    as_user cmake ..
    as_user make -j$(nproc)
    as_user cp AdaptixClient ../bin/
  )

  echo " -> Setting capabilities and linking..."
  sudo setcap 'cap_net_bind_service=+ep' "$INSTALL_DIR/AdaptixC2/bin/teamserver"

  as_user mkdir -p "$TARGET_HOME/.local/bin"
  as_user ln -sf "$INSTALL_DIR/AdaptixC2/bin/teamserver" "$TARGET_HOME/.local/bin/adaptix-server"
  as_user ln -sf "$INSTALL_DIR/AdaptixC2/bin/AdaptixClient" "$TARGET_HOME/.local/bin/adaptix-client"

  echo "[+] Adaptix installed successfully."
}

install_sliver() {
  echo "[*] Installing Sliver C2 Framework..."

  local INSTALL_DIR="$TARGET_HOME/Tools/sliver"
  as_user mkdir -p "$INSTALL_DIR" "$TARGET_HOME/.local/bin"

  echo " -> Downloading latest Sliver binaries from GitHub..."
  local SERVER_URL="https://github.com/BishopFox/sliver/releases/latest/download/sliver-server_linux"
  local CLIENT_URL="https://github.com/BishopFox/sliver/releases/latest/download/sliver-client_linux"

  as_user curl -# -L -o "$INSTALL_DIR/sliver-server" "$SERVER_URL"
  as_user curl -# -L -o "$INSTALL_DIR/sliver-client" "$CLIENT_URL"

  echo " -> Setting permissions and capabilities..."
  as_user chmod +x "$INSTALL_DIR/sliver-server" "$INSTALL_DIR/sliver-client"

  sudo setcap 'cap_net_bind_service=+ep' "$INSTALL_DIR/sliver-server"

  echo " -> Creating symlinks..."
  as_user ln -sf "$INSTALL_DIR/sliver-server" "$TARGET_HOME/.local/bin/sliver-server"
  as_user ln -sf "$INSTALL_DIR/sliver-client" "$TARGET_HOME/.local/bin/sliver-client"
  as_user ln -sf "$INSTALL_DIR/sliver-client" "$TARGET_HOME/.local/bin/sliver"

  echo "[+] Sliver installed successfully."
}

# Main install functions
install_utilities() {
  sudo xbps-install -u xbps
  sudo xbps-install -Su -y xtools terminator tmux fzf bat ripgrep chromium tor proxychains-ng socat wget git openvpn openssl jq yq bleachbit
  install_mise
  install_uv
  install_nix
  ensure_user_path
}

install_container_tools(){
  set -e
  sudo xbps-install -Su -y docker docker-compose podman incus shadow

  [ ! -L /var/service/containerd ] && sudo ln -s /etc/sv/containerd /var/service/
  [ ! -L /var/service/docker ] && sudo ln -s /etc/sv/docker /var/service/
  sudo usermod -aG docker "${USER}"

  if ! grep -q "${USER}" /etc/subuid; then
    echo "Adding ${USER} to /etc/subuid and /etc/subgid..."
    echo "${USER}:100000:65536" | sudo tee -a /etc/subuid
    echo "${USER}:100000:65536" | sudo tee -a /etc/subgid
  fi

  [ ! -L /var/service/incus ] && sudo ln -s /etc/sv/incus /var/service/
  [ ! -L /var/service/incus-user ] && sudo ln -s /etc/sv/incus-user /var/service/
  sudo usermod -aG _incus-admin ${USER}
}

install_cloud(){
  echo "Installing cloud tools..."

  as_user mkdir -p "$TARGET_HOME/.local/bin" "$TARGET_HOME/.config/mise"

  if [ -f "$TARGET_HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    . "$TARGET_HOME/.nix-profile/etc/profile.d/nix.sh"
  elif [ -f /nix/var/nix/profiles/default/etc/profile.d/nix.sh ]; then
    . /nix/var/nix/profiles/default/etc/profile.d/nix.sh
  fi

  echo "[*] Installing Cloud CLIs and Session Manager plugin via Nix..."
  as_user nix-env -iA nixpkgs.awscli2 nixpkgs.ssm-session-manager-plugin nixpkgs.google-cloud-sdk nixpkgs.azure-cli

  echo "[*] Setting up uv via mise..."
  mise_user use -g --force uv@latest

  echo "[*] Installing Python cloud security tools via uv..."
  local cloud_py_tools=(prowler pacu cloudsplaining kube-hunter)
  for tool in "${cloud_py_tools[@]}"; do
    uv_user tool install --force "$tool"
  done

  echo "[*] Installing binary recon and secrets tools via mise..."
  mise_user use -g --force github:trufflesecurity/trufflehog@latest
  mise_user use -g --force github:aquasecurity/trivy@latest
  mise_user use -g --force github:zricethezav/gitleaks@latest

  echo "[*] Installing Steampipe & plugins via mise..."
  mise_user use -g --force github:turbot/steampipe@latest
  as_user steampipe plugin install aws gcp azure

  echo "Cloud tools installation complete!"
}

install_forensics(){
  echo "Installing Forensic tools..."

  as_user mkdir -p "$TARGET_HOME/.local/bin" "$TARGET_HOME/.config/mise"

  echo "[*] Installing core system forensics packages..."
  sudo xbps-install -Sy binwalk foremost stegseek yara exiftool sleuthkit testdisk poppler-utils

  echo "[*] Setting up uv and cargo dependencies..."
  mise_user use -g --force uv@latest

  echo "[*] Installing Python DFIR tools via uv..."
  uv_user tool install --force volatility3
  uv_user tool install --force git+https://github.com/decalage2/ViperMonkey.git

  echo "[*] Installing Rust-based log analysis tools via cargo..."
  as_user cargo install --force evtx
  as_user cargo install --force chainsaw-cli

  echo "Forensics tools installation complete!"
}

install_reverse(){
  echo "Installing reverse engineering tools..."

  as_user mkdir -p "$TARGET_HOME/.local/bin" "$TARGET_HOME/.config/mise"

  echo "[*] Installing core system RE, Android, and Ruby packages via xbps..."
  sudo xbps-install -Sy xxd imhex ghidra binwalk rizin cutter gdb strace ltrace \
                    openjdk17 libxcb-devel xcb-util-wm-devel xcb-util-image-devel \
                    xcb-util-keysyms-devel xcb-util-renderutil-devel \
                    android-tools apktool ruby

  sudo xbps-alternatives -s openjdk17

  echo "[*] Configuring adbusers group..."
  sudo groupadd -f adbusers
  sudo usermod -aG adbusers "$TARGET_USER"

  echo "[*] Setting up uv via mise..."
  mise_user use -g --force uv@latest

  echo "[*] Installing Python RE, mobile security & emulation tools via uv..."
  local py_re_tools=(ropgadget angr-management frida-tools objection qiling)
  for tool in "${py_re_tools[@]}"; do
    uv_user tool install --force "$tool"
  done

  echo "[*] Installing one_gadget via gem..."
  as_user gem install --user-install one_gadget

  echo "[*] Linking Ruby gem binaries to ~/.local/bin..."
  local gem_bin_dir
  gem_bin_dir=$(as_user ruby -e 'print File.join(Gem.user_dir, "bin")' 2>/dev/null)
  if [ -d "$gem_bin_dir" ]; then
    for bin in "$gem_bin_dir"/*; do
      [ -f "$bin" ] && as_user ln -sf "$bin" "$TARGET_HOME/.local/bin/"
    done
  fi

  echo "[*] Installing JADX via mise..."
  mise_user use -g github:skylot/jadx@latest

  echo "Reverse engineering tools installation complete!"
}

install_password(){
  echo "Installing Password & Hash Cracking tools..."

  echo "[*] Installing core cracking packages..."
  sudo xbps-install -Sy hashcat john thc-hydra

  echo "[*] Installing Name-That-Hash (Hash identification)..."
  as_user mkdir -p "$TARGET_HOME/.local/bin"
  mise_user use -g --force uv@latest

  uv_user tool install --force name-that-hash

  echo "Password tools installation complete!"
}

install_wireless() {
  echo "Installing Wireless Security Tools..."
  as_user mkdir -p "$TARGET_HOME/Tools" "$TARGET_HOME/.local/bin"

  echo "[*] Installing core wireless packages and Airgeddon dependencies..."
  sudo xbps-install -Sy aircrack-ng kismet hcxtools hcxdumptool xterm \
    dnsmasq hostapd tcpdump wireshark hashcat john crunch lighttpd bettercap ettercap

  local INSTALL_DIR="$TARGET_HOME/Tools/airgeddon"

  echo "[*] Fetching Airgeddon..."
  if [ ! -d "$INSTALL_DIR/.git" ]; then
    as_user git clone --depth 1 https://github.com/v1s1t0r1sh3r3/airgeddon.git "$INSTALL_DIR"
  else
    (cd "$INSTALL_DIR" && as_user git pull)
  fi

  echo "[*] Linking Airgeddon to PATH..."
  as_user ln -sf "$INSTALL_DIR/airgeddon.sh" "$TARGET_HOME/.local/bin/airgeddon"

  echo "[+] Wireless tools installation complete!"
}

install_network(){
  echo "Installing and refreshing network tools..."
  local CURRENT_USER="${SUDO_USER:-$USER}"
  local USER_HOME
  USER_HOME="$(eval echo "~$CURRENT_USER")"

  sudo -u "$CURRENT_USER" mkdir -p "$USER_HOME/.local/bin" "$USER_HOME/.cargo/bin"

  export PATH="$USER_HOME/.local/bin:$USER_HOME/.cargo/bin:$USER_HOME/.local/share/mise/shims:$PATH"
  sudo xbps-install -Su -y wireshark wireshark-qt tcpdump arpwatch proxychains-ng netcat \
                           libpcap-devel libseccomp-devel cargo net-tools

  sudo groupadd -f wireshark
  sudo usermod -aG wireshark "$CURRENT_USER"

  [ ! -e /usr/lib/libpcap.so.0.8 ] && sudo ln -s /usr/lib/libpcap.so /usr/lib/libpcap.so.0.8

  echo "[*] Installing Scapy..."
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
  echo "Installing non-free repository and scanning tools..."
  sudo xbps-install -y void-repo-nonfree
  sudo xbps-install -Su -y nmap masscan

  echo "Installing ProjectDiscovery tools via mise..."
  mise_user use -g github:projectdiscovery/subfinder@latest
  mise_user use -g github:projectdiscovery/httpx@latest
  mise_user use -g github:projectdiscovery/dnsx@latest
  mise_user use -g github:projectdiscovery/nuclei@latest
  mise_user use -g github:projectdiscovery/naabu@latest
  mise_user use -g github:projectdiscovery/cvemap@latest

  local NAABU_BIN
  NAABU_BIN=$(mise_user which naabu)

  echo "Setting network capabilities for Naabu at: $NAABU_BIN"
  sudo setcap 'cap_net_raw,cap_net_admin+eip' "$NAABU_BIN"

  echo "Installing remaining wordlist and recon tools..."
  mise_user use -g github:epi052/feroxbuster@latest
  mise_user use -g github:owasp-amass/amass@latest

  as_user mkdir -p "$TARGET_HOME/Documents/Engagements/_amass_db"
}

install_exploitation(){
  echo "Installing exploitation tools..."

  as_user mkdir -p "$TARGET_HOME/.local/bin" "$TARGET_HOME/Tools" "$TARGET_HOME/.config/mise"

  echo "[*] Installing system dependencies..."
  sudo xbps-install -Sy binutils-multiarch libelf-devel libffi-devel openssl-devel mingw-w64-gcc

  echo "[*] Setting up uv and vulnx via mise..."
  mise_user use -g --force uv@latest
  mise_user use -g github:projectdiscovery/vulnx@latest

  echo "[*] Installing Python exploitation tools via uv..."
  local py_tools=(impacket responder certipy-ad mitm6 pwntools)
  for tool in "${py_tools[@]}"; do
    uv_user tool install --force "$tool"
  done

  uv_user tool install --force git+https://github.com/Pennyw0rth/NetExec

  echo "[*] Installing ExploitDB and searchsploit..."
  if [ ! -d "/opt/exploitdb" ]; then
    sudo git clone --depth 1 https://gitlab.com/exploit-database/exploitdb.git /opt/exploitdb
  else
    (cd /opt/exploitdb && sudo git pull)
  fi
  sudo ln -sf /opt/exploitdb/searchsploit /usr/local/bin/searchsploit

  if [ ! -f "$TARGET_HOME/.searchsploit_rc" ]; then
    as_user cp /opt/exploitdb/.searchsploit_rc "$TARGET_HOME/"
  fi

  echo "[*] Installing Nix exploitation packages..."
  local nix_pkgs=(metasploit cosign pretender evil-winrm)

  for pkg in "${nix_pkgs[@]}"; do
    echo " -> Installing $pkg..."
    nix_env_user -iA "nixpkgs.$pkg" || echo -e "\e[31m[!] Failed to install $pkg (skipping)\e[0m"
  done

  echo "[*] Granting network capabilities to Pretender..."
  local pretender_bin
  pretender_bin=$(readlink -f "$TARGET_HOME/.nix-profile/bin/pretender" 2>/dev/null)
  [ -f "$pretender_bin" ] && sudo setcap 'cap_net_raw,cap_net_admin=+ep' "$pretender_bin"

  echo "[*] Syncing SharpCollection..."
  if [ ! -d "$TARGET_HOME/Tools/SharpCollection/.git" ]; then
    as_user git clone --depth 1 https://github.com/Flangvik/SharpCollection.git "$TARGET_HOME/Tools/SharpCollection"
  else
    (cd "$TARGET_HOME/Tools/SharpCollection" && as_user git pull)
  fi

  echo "Exploitation tools installation complete!"
}

install_c2(){
  echo "Installing C2 tools..."
  echo "Installing Command and Control (C2) Frameworks..."

  as_user mkdir -p "$TARGET_HOME/.local/bin" "$TARGET_HOME/Tools"

  install_adaptix
  install_sliver
  # install_mythic
  # install_cobaltstrike

  echo "Done..."
}

install_web_testing(){
  echo "Installing web testing tools..."

  as_user mkdir -p "$TARGET_HOME/.local/bin" "$TARGET_HOME/.cargo/bin" "$TARGET_HOME/go/bin"
  sudo xbps-install -Su -y nikto sqlmap

  echo "[*] Installing Python web tools via uv..."
  uv_user tool install --force git+https://github.com/s0md3v/XSStrike
  uv_user tool install --force arjun

  echo "[*] Setting up Go via mise..."
  mise_user use -g --force go@latest

  echo "[*] Installing Go web tools..."
  as_user env GOPATH="$TARGET_HOME/go" go install github.com/ffuf/ffuf/v2@latest
  as_user env GOPATH="$TARGET_HOME/go" go install github.com/OJ/gobuster/v3@latest
  as_user env GOPATH="$TARGET_HOME/go" go install github.com/hahwul/dalfox/v3@latest
  as_user env GOPATH="$TARGET_HOME/go" go install github.com/projectdiscovery/katana/cmd/katana@latest
  as_user env GOPATH="$TARGET_HOME/go" go install github.com/projectdiscovery/interactsh/cmd/interactsh-client@latest

  echo "[*] Installing Rust web tools..."
  as_user cargo install --force feroxbuster

  [ "$(type -t install_burp)" = "function" ] && install_burp
  [ "$(type -t install_caido)" = "function" ] && install_caido

  echo "Web Testing installation complete!"
}

install_scripts(){
  echo "Installing scripts..."

  local SCRIPT_DIR="$TARGET_HOME/.local/share/scripts"

  as_user mkdir -p "$SCRIPT_DIR/linux" "$SCRIPT_DIR/windows" "$SCRIPT_DIR/wordlists"

  echo "[*] Downloading Linux enumeration scripts..."
  as_user curl -# -fsSL https://github.com/peass-ng/PEASS-ng/releases/latest/download/linpeas.sh \
    -o "$SCRIPT_DIR/linux/linpeas.sh"
  as_user curl -# -fsSL https://raw.githubusercontent.com/mzet-/linux-exploit-suggester/master/linux-exploit-suggester.sh \
    -o "$SCRIPT_DIR/linux/les.sh"
  as_user chmod +x "$SCRIPT_DIR/linux/linpeas.sh" "$SCRIPT_DIR/linux/les.sh"

  echo "[*] Downloading Windows enumeration scripts..."
  as_user curl -# -fsSL https://github.com/peass-ng/PEASS-ng/releases/latest/download/winPEASany.exe \
    -o "$SCRIPT_DIR/windows/winPEAS.exe"
  as_user curl -# -fsSL https://raw.githubusercontent.com/PowerShellMafia/PowerSploit/master/Recon/PowerView.ps1 \
    -o "$SCRIPT_DIR/windows/PowerView.ps1"

  echo "[*] Cloning SecLists..."
  if [ ! -d "$SCRIPT_DIR/wordlists/SecLists/.git" ]; then
    as_user git clone --depth 1 https://github.com/danielmiessler/SecLists.git "$SCRIPT_DIR/wordlists/SecLists"
  else
    (cd "$SCRIPT_DIR/wordlists/SecLists" && as_user git pull)
  fi

  echo "[*] Linking to /usr/share/wordlists..."
  sudo mkdir -p /usr/share/wordlists
  sudo ln -sfn "$SCRIPT_DIR/wordlists/SecLists" /usr/share/wordlists/SecLists 2>/dev/null || echo "(!) Note: Manual sudo required to link /usr/share/wordlists"

  echo "Scripts available in $SCRIPT_DIR..."
  echo "Done..."
}

install_reporting(){
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
    "install_c2"
  )

  local labels=(
    "Utilities"
    "Development"
    "Networking"
    "Container Tools (Incus / Podman)"
    "Reconnaissance & Scanning"
    "Exploitation"
    "Wireless"
    "Web Application Testing"
    "Custom Scripts & Wordlists"
    "Password & Hash Cracking"
    "Digital Forensics"
    "Reverse Engineering"
    "Cloud Security Tools"
    "C2"
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

  # Permanent path Injection
  echo -e "\n\e[1;34m[*] Configuring permanent Master PATH in .bashrc...\e[0m"
  local bashrc="$TARGET_HOME/.bashrc"

  if ! grep -q "# --- SECURITY TOOLS PATH ---" "$bashrc" 2>/dev/null; then
    cat << 'EOF' | sudo -u "$TARGET_USER" tee -a "$bashrc" > /dev/null

# --- SECURITY TOOLS PATH ---
export PATH="$HOME/.local/bin:$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$HOME/.local/share/mise/shims:$HOME/.cargo/bin:$HOME/go/bin:$PATH"
EOF
  fi
  # --------------------------------

  echo -e "\n\e[1;32m[+] Selected installations completed successfully!\e[0m"
  echo -e "\e[1;33m[!] IMPORTANT: Run 'source ~/.bashrc' or open a new terminal window to start using your new tools.\e[0m\n"
}

update_system() {
  echo "Syncing repositories and updating Void Linux..."
  sudo xbps-install -Syu
}

test_function(){
  install_exploitation
}

# --- Global User & Environment Helpers ---
export TARGET_USER="${SUDO_USER:-$USER}"
export TARGET_HOME="$(eval echo "~$TARGET_USER")"

as_user() {
  local user_path="$TARGET_HOME/.local/bin:$TARGET_HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$TARGET_HOME/.local/share/mise/shims:$TARGET_HOME/.cargo/bin:$TARGET_HOME/go/bin:$PATH"
  sudo -u "$TARGET_USER" env HOME="$TARGET_HOME" PATH="$user_path" "$@"
}

mise_user() {
  as_user "$TARGET_HOME/.local/bin/mise" "$@"
}

uv_user() {
  as_user "$TARGET_HOME/.local/bin/uv" "$@"
}

nix_env_user() {
  as_user nix-env "$@"
}

trap 'tput cnorm' EXIT

OPTIONS=(
  "1. Full setup"
  "2. Select And Install"
  "3. Update"
  "4. Exit"
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

move_to_top() {
  for (( i=0; i<TOTAL; i++ )); do
    printf "${CURSOR_UP}"
  done
}

draw_menu

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

move_to_top
printf "${ESC}[J"

tput cnorm

echo "  You selected: ${BOLD}${OPTIONS[$SELECTED]}${RESET}"

case $SELECTED in
  0) echo "  → Full setup..." ;;
  1)
    echo "  → Selection Install..."
    multi_install ;;
  2) echo "  → Updating..."
    update_system ;;
  3) echo "  → Goodbye!"; exit 0;;
esac
