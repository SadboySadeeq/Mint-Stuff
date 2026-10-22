#!/usr/bin/env bash
# cypat_final.sh
# Final merged CyberPatriot / CIS-informed interactive hardening script
# Target: Debian / Ubuntu / Linux Mint
# Make a backup/snapshot before running.
# === Title Art ===
cat << "EOF"
_________                      __     .__  .__                        _________            .__        __   
╲_   ___ ╲___.__.___________ _╱  │_   │  │ │__│ ____  __ _____  ___  ╱   _____╱ ___________│__│______╱  │_ 
╱    ╲  ╲<   │  │╲____ ╲__  ╲╲   __╲  │  │ │  │╱    ╲│  │  ╲  ╲╱  ╱  ╲_____  ╲_╱ ___╲_  __ ╲  ╲____ ╲   __╲
╲     ╲___╲___  ││  │_> > __ ╲│  │    │  │_│  │   │  ╲  │  ╱>    <   ╱        ╲  ╲___│  │ ╲╱  │  │_> >  │  
 ╲______  ╱ ____││   __(____  ╱__│____│____╱__│___│  ╱____╱╱__╱╲_ ╲ ╱_______  ╱╲___  >__│  │__│   __╱│__│  
        ╲╱╲╱     │__│       ╲╱  ╱_____╱            ╲╱            ╲╱         ╲╱     ╲╱         │__│           
                                                                                  
                        L I N U X   _   C Y P A T   S C R I P T
EOF
set -o pipefail
IFS=$'\n\t'

# -------------------------
# Basic runtime settings
# -------------------------
DRY_RUN=${DRY_RUN:-false}   # set to true to dry-run
LOG_DIR="${HOME:-/root}/Documents"
LOG_FILE="$LOG_DIR/cypat_log"
BACKUP_DIR="$LOG_DIR/cypat_backups"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR" "$BACKUP_DIR"
: > "$LOG_FILE"

# If invoked as root, don't prefix commands with sudo
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# -------------------------
# Colors for console output
# -------------------------
GREEN="\e[1;32m"
YELLOW="\e[1;33m"
RED="\e[1;31m"
BLUE="\e[1;34m"
RESET="\e[0m"

# -------------------------
# Logging helpers
# -------------------------
log()         { printf "%s\n" "$1" >> "$LOG_FILE"; }
log_success() { printf "[SUCCESS] %s\n" "$1" | tee -a "$LOG_FILE"; }
log_warn()    { printf "[WARN]    %s\n" "$1" | tee -a "$LOG_FILE"; }
log_fail()    { printf "[FAILED]  %s\n" "$1" | tee -a "$LOG_FILE"; }

c_print_success() { echo -e "${GREEN}[OK]${RESET} $1"; log_success "$1"; }
c_print_warn()    { echo -e "${YELLOW}[WARN]${RESET} $1"; log_warn "$1"; }
c_print_fail()    { echo -e "${RED}[FAIL]${RESET} $1"; log_fail "$1"; }
c_print_info()    { echo -e "${BLUE}[..]${RESET} $1"; log "$1"; }

# -------------------------
# Utility helpers
# -------------------------
backup_file() {
    local src="$1"
    [ -z "$src" ] && return 1
    if [ -e "$src" ] || [ -L "$src" ]; then
        local dest="$BACKUP_DIR/$(basename "$src").bak.$TIMESTAMP"
        $SUDO cp -a "$src" "$dest" 2>/dev/null || $SUDO cp -a "$src" "$dest" || true
        log "Backed up $src to $dest"
    fi
}

trim() { # trim whitespace
    local x="$*"
    x="${x#"${x%%[![:space:]]*}"}"
    x="${x%"${x##*[![:space:]]}"}"
    printf "%s" "$x"
}

prompt_confirm() { # returns 0 for yes, 1 for no
    local prompt="${1:-Are you sure?}"
    local ans
    while true; do
        read -rp "$prompt [y/n]: " ans
        case "$ans" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

safe_apt_install() {
    if [ "${DRY_RUN:-false}" = "true" ]; then
        c_print_info "DRY_RUN: would install: $*"
        return 0
    fi
    c_print_info "Installing: $*"
    $SUDO apt-get update -qq || true
    if $SUDO DEBIAN_FRONTEND=noninteractive apt-get -y -qq install "$@"; then
        c_print_success "Installed: $*"
    else
        c_print_warn "Install had issues – check apt output."
    fi
}

run_command() { # run with logging and optional dry run
    local label="$1"; shift
    if [ "${DRY_RUN:-false}" = "true" ]; then
        c_print_info "DRY_RUN: would run: $*"
    else
        log "RUN: $*"
        eval "$@" 2>&1 | tee -a "$LOG_FILE"
        return ${PIPESTATUS[0]:-0}
    fi
}

# -------------------------
# Basic sanity checks
# -------------------------
if ! command -v apt-get >/dev/null 2>&1; then
    c_print_fail "apt-get not found. This script is for Debian/Ubuntu/Mint. Exiting."
    exit 1
fi

# -------------------------
# Hardening functions
# -------------------------

# 1) apt update & fix/upgrade
apt_update_upgrade() {
    c_print_info "=== apt: update & upgrade (with fixes) ==="
    if [ "${DRY_RUN:-false}" = "true" ]; then
        c_print_info "DRY_RUN: would run apt update/upgrade and fix broken packages"
        return 0
    fi

    $SUDO apt-get update || { c_print_warn "apt-get update failed"; }
    $SUDO dpkg --configure -a || c_print_warn "dpkg --configure had issues"
    $SUDO apt-get -f install -y || c_print_warn "apt --fix-broken had issues"
    $SUDO DEBIAN_FRONTEND=noninteractive apt-get -y upgrade || c_print_warn "apt upgrade reported issues"

    if prompt_confirm "Run full dist-upgrade (may change kernels/packages)?"; then
        $SUDO DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade || c_print_warn "dist-upgrade reported issues"
    fi

    c_print_success "apt update/upgrade attempts complete; check output above for errors."
    log "Completed apt_update_upgrade"
}

# 2) Ensure security repo lines (asks for codename)
ensure_security_repo() {
    c_print_info "=== Ensure security repo lines ==="
    if ! prompt_confirm "Auto-add Debian/Ubuntu security repo lines if missing?"; then
        c_print_warn "Skipping repo edits."
        return 0
    fi
    if [ "${DRY_RUN:-false}" = "true" ]; then
        c_print_info "DRY_RUN: would inspect and add security repo lines to /etc/apt/sources.list"
        return 0
    fi
    backup_file /etc/apt/sources.list
    if grep -Eqi 'security\.debian\.org|ubuntu.*security' /etc/apt/sources.list; then
        c_print_info "Security lines appear present already."
        return 0
    fi
    read -rp "Enter distro codename (e.g., bookworm, bullseye, jammy, focal): " codename
    codename="$(trim "$codename")"
    if [ -z "$codename" ]; then
        c_print_warn "No codename given; skipping automatic repo insertion."
        return 0
    fi
    printf "\n# Added by cypat_final\n" | $SUDO tee -a /etc/apt/sources.list >/dev/null
    printf "deb http://security.ubuntu.com/ubuntu %s-security main restricted universe multiverse\n" "$codename" | $SUDO tee -a /etc/apt/sources.list >/dev/null
    printf "deb http://security.debian.org/debian-security %s-security main\n" "$codename" | $SUDO tee -a /etc/apt/sources.list >/dev/null
    c_print_success "Security repo lines appended to /etc/apt/sources.list (verify correctness for your distro)."
    log "ensure_security_repo: done"
}

# 3) Configure unattended-upgrades (security only)
configure_unattended_upgrades() {
    c_print_info "=== Configure unattended-upgrades (security-only, daily) ==="
    if [ "${DRY_RUN:-false}" = "true" ]; then
        c_print_info "DRY_RUN: would install and configure unattended-upgrades"
        return 0
    fi
    safe_apt_install unattended-upgrades apt-listchanges || true
    backup_file /etc/apt/apt.conf.d/50unattended-upgrades
    $SUDO sed -n '1,200p' /etc/apt/apt.conf.d/50unattended-upgrades >/dev/null 2>&1 || true
    # Enable security origin line (non-destructive attempt)
    $SUDO sed -i 's@//\s*"\${distro_id}:\${distro_codename}-security";@"${distro_id}:${distro_codename}-security";@' /etc/apt/apt.conf.d/50unattended-upgrades || true
    # Create 20auto-upgrades
    $SUDO tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
    $SUDO systemctl enable --now unattended-upgrades 2>/dev/null || true
    c_print_success "unattended-upgrades configured (security only) and enabled."
    log "configure_unattended_upgrades: done"
}

# 4) Remove potentially unwanted packages (interactive)
remove_unwanted_packages_interactive() {
    c_print_info "=== Remove potentially unwanted packages (interactive) ==="
    patterns='telnet|ftp|rsh|rlogin|tftp|rpcbind|samba|vsftpd|nfs-server|openvpn|wireshark|nmap|john|hydra|aircrack|metasploit|burp|zaproxy|nikto|masscan|sqlmap|ftp'
    mapfile -t installed_matches < <(dpkg -l 2>/dev/null | awk '/^ii/ {print $2}' | grep -E -i "$patterns" || true)

    if [ ${#installed_matches[@]} -eq 0 ]; then
        c_print_info "No matching unwanted packages detected."
        return 0
    fi

    c_print_info "Found candidate packages (review before purge):"
    for p in "${installed_matches[@]}"; do
        echo " - $p"
    done

    if ! prompt_confirm "Purge these packages? (recommended to review and confirm each)"; then
        c_print_warn "Skipping package purge."
        return 0
    fi

    for p in "${installed_matches[@]}"; do
        if prompt_confirm "Purge package $p?"; then
            if [ "${DRY_RUN:-false}" = "true" ]; then
                c_print_info "DRY_RUN: would purge $p"
            else
                $SUDO apt-get -y purge "$p" || c_print_warn "Failed to purge $p (may be protected)"
                $SUDO apt-get -y autoremove || true
                c_print_success "Attempted purge of $p"
            fi
        else
            log "Skipped purge of $p per operator"
        fi
    done

    c_print_success "Package cleanup pass done."
    log "remove_unwanted_packages_interactive: done"
}

# 5) Firewall baseline (UFW)
configure_firewall_baseline() {
    c_print_info "=== UFW baseline ==="
    if [ "${DRY_RUN:-false}" = "true" ]; then
        c_print_info "DRY_RUN: would install and configure ufw"
        return 0
    fi

    safe_apt_install ufw iptables iptables-persistent || true
    backup_file /etc/ufw/ufw.conf || true

    $SUDO ufw default deny incoming || true
    $SUDO ufw default allow outgoing || true
    $SUDO ufw allow out 53/tcp || true
    $SUDO ufw allow out 53/udp || true

    if prompt_confirm "Allow OpenSSH through UFW? (if remote access is required)"; then
        $SUDO ufw allow OpenSSH || true
        c_print_success "OpenSSH allowed"
    else
        c_print_warn "OpenSSH left blocked per operator choice"
    fi

    if prompt_confirm "Enable UFW now? (recommended)"; then
        $SUDO ufw --force enable || true
        c_print_success "UFW enabled"
    else
        c_print_warn "UFW not enabled"
    fi

    $SUDO iptables-save | $SUDO tee /etc/iptables/rules.v4 >/dev/null 2>&1 || true
    log "configure_firewall_baseline: done"
}

# 6) SSH hardening (safe)
harden_ssh_safe() {
    c_print_info "=== SSH hardening (safe) ==="
    backup_file /etc/ssh/sshd_config
    if [ "${DRY_RUN:-false}" = "true" ]; then
        c_print_info "DRY_RUN: would edit /etc/ssh/sshd_config"
        return 0
    fi

    if prompt_confirm "Apply hardened sshd_config (will default to Port 3784 and disable password auth)?"; then
        $SUDO bash -c 'cat > /etc/ssh/sshd_config <<EOF
# CIS-inspired SSH hardening (generated)
Port 3784
Protocol 2
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 0
MaxAuthTries 4
AllowTcpForwarding no
UseDNS no
LogLevel VERBOSE
Subsystem sftp /usr/lib/openssh/sftp-server
EOF'
        $SUDO chown root:root /etc/ssh/sshd_config
        $SUDO chmod 600 /etc/ssh/sshd_config
        $SUDO systemctl restart sshd 2>/dev/null || $SUDO systemctl restart ssh 2>/dev/null || c_print_warn "ssh restart reported issues"
        c_print_success "SSH hardening applied (port 3784; key auth only). Ensure key-based access before applying remotely."
        log "harden_ssh_safe: applied"
    else
        c_print_warn "SSH hardening skipped by operator."
    fi
}

# 7) Password policy & PAM (Option B — safe)
configure_password_policy() {
    c_print_info "=== Password Policies & PAM (Option B: deny=3, unlock_time=1800, root not locked) ==="

    # Backup critical files
    backup_file /etc/login.defs
    backup_file /etc/pam.d/common-auth
    backup_file /etc/pam.d/common-password
    backup_file /etc/pam.d/common-account

    # Update login.defs (safe edits)
    $SUDO sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS    30/' /etc/login.defs || true
    $SUDO sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS    2/' /etc/login.defs || true
    $SUDO sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE    7/' /etc/login.defs || true

    # Ensure required packages are installed
    apt-get install -y libpam-pwquality libpam-modules libpam-runtime || true

    # Prepare safe pam_faillock lines (Option B: deny=3 unlock_time=1800, no even_deny_root)
    local PREAUTH="auth    required    pam_faillock.so preauth silent deny=3 unlock_time=1800"
    local AUTHFAIL="auth    [default=die]    pam_faillock.so authfail deny=3 unlock_time=1800"
    local AUTHSUCC="auth    sufficient    pam_faillock.so authsucc"

    # Insert pam_faillock into common-auth safely
    if ! $SUDO grep -qF "$PREAUTH" /etc/pam.d/common-auth 2>/dev/null; then
        tmpfile="$(mktemp /tmp/common-auth.XXXXXX)" || tmpfile="/tmp/common-auth.$$"
        $SUDO awk -v pre="$PREAUTH" -v fail="$AUTHFAIL" -v succ="$AUTHSUCC" '
        BEGIN { found_unix = 0; }
        {
            if (!found_unix && $0 ~ /^auth/ && $0 ~ /pam_unix\.so/) {
                print pre
                print $0
                print fail
                found_unix = 1
                next
            }
            print $0
        }
        END {
            if (!found_unix) {
                print pre
                print fail
            }
            print succ
        }' /etc/pam.d/common-auth > "$tmpfile"
        $SUDO mv "$tmpfile" /etc/pam.d/common-auth
        $SUDO chmod 644 /etc/pam.d/common-auth
        c_print_success "Inserted pam_faillock entries into /etc/pam.d/common-auth (preauth/authfail/authsucc)."
        log "pam_faillock inserted into common-auth (deny=3 unlock_time=1800)."
    else
        c_print_info "pam_faillock preauth already present in common-auth; skipping insertion."
    fi

    # Ensure account line required for pam_faillock is present in /etc/pam.d/common-account
    if ! $SUDO grep -qF "account required pam_faillock.so" /etc/pam.d/common-account 2>/dev/null; then
        tmpacct="$(mktemp /tmp/common-account.XXXXXX)" || tmpacct="/tmp/common-account.$$"
        $SUDO awk '
        BEGIN { added = 0 }
        {
            print $0
            if (!added && $0 ~ /^account/ && $0 !~ /^#/) {
                print "account required pam_faillock.so"
                added = 1
            }
        }
        END {
            if (!added) print "account required pam_faillock.so"
        }' /etc/pam.d/common-account > "$tmpacct"
        $SUDO mv "$tmpacct" /etc/pam.d/common-account
        $SUDO chmod 644 /etc/pam.d/common-account
        c_print_success "Added account required pam_faillock.so to /etc/pam.d/common-account."
        log "pam_faillock account line added to common-account."
    else
        c_print_info "pam_faillock account entry already exists in common-account."
    fi

    # Configure password quality (pam_pwquality) in common-password: ensure a single controlled line
    $SUDO sed -i '/pam_pwquality/d' /etc/pam.d/common-password || true
    $SUDO bash -c 'cat >> /etc/pam.d/common-password <<EOF
password requisite pam_pwquality.so try_first_pass retry=3 minlen=14 lcredit=-1 ucredit=-1 dcredit=-1 ocredit=-1 maxrepeat=2 reject_username enforce_for_root dictcheck=1
EOF'
    c_print_success "Configured pam_pwquality in /etc/pam.d/common-password."
    log "pam_pwquality set in common-password."

    # Apply pam-auth-update (non-fatal)
    $SUDO pam-auth-update --force || c_print_warn "pam-auth-update reported issues (check /etc/pam.d/*)."

    c_print_success "Password policy and PAM configured (Option B: deny=3 unlock_time=1800, root not locked)."
    log "PAM and login.defs updated; backups created."

    # Optionally reset faillock counters
    if prompt_confirm "If someone is locked, reset faillock counters now?"; then
        read -rp "Enter username to reset (or 'all' to list then choose): " reset_user
        reset_user="$(trim "$reset_user")"
        if [ "$reset_user" = "all" ]; then
            c_print_info "Listing faillock records (if any):"
            $SUDO faillock || true
            read -rp "Enter username from list to reset (blank to skip): " ru
            ru="$(trim "$ru")"
            if [ -n "$ru" ]; then
                $SUDO faillock --reset --user "$ru" && c_print_success "Reset faillock for $ru" || c_print_warn "Failed to reset $ru"
            else
                c_print_info "Skipping reset."
            fi
        else
            if [ -n "$reset_user" ]; then
                $SUDO faillock --reset --user "$reset_user" && c_print_success "Reset faillock for $reset_user" || c_print_warn "Failed to reset $reset_user"
            else
                c_print_info "No user provided; skipping reset."
            fi
        fi
    fi

    return 0
}

# 8) Kernel & sysctl hardening
harden_kernel_sysctl() {
    c_print_info "=== Kernel & sysctl hardening ==="
    backup_file /etc/sysctl.conf
    if [ "${DRY_RUN:-false}" = "true" ]; then
        c_print_info "DRY_RUN: would write /etc/sysctl.conf"
        return 0
    fi

    $SUDO bash -c 'cat > /etc/sysctl.conf <<EOF
# CIS-inspired sysctl settings
net.ipv4.ip_forward = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.accept_redirects = 0
net.ip6.conf.all.accept_redirects = 0
net.ipv4.icmp_echo_ignore_all = 1
fs.suid_dumpable = 0
fs.protected_symlinks = 1
kernel.randomize_va_space = 2
kernel.sysrq = 0
kernel.unprivileged_bpf_disabled = 1
kernel.dmesg_restrict = 1
fs.protected_hardlinks = 1
kernel.kptr_restrict = 2
kernel.perf_event_paranoid = 3
EOF'
    if $SUDO sysctl -p >/dev/null 2>&1; then
        c_print_success "sysctl applied."
    else
        c_print_warn "sysctl reported issues; review /etc/sysctl.conf"
    fi
    $SUDO systemctl daemon-reload || true
    log "harden_kernel_sysctl: applied"
}

# 9) Media file scan (non-destructive)
scan_media_files() {
    c_print_info "=== Media file scan (logged) ==="
    extensions=( "*.mp3" "*.mp4" "*.avi" "*.mkv" "*.jpg" "*.jpeg" "*.png" "*.gif" "*.wav" "*.flac" )
    excluded_dirs=( "/proc" "/run" "/sys" "/dev" "/var/log" )
    prune_expr=""
    for dir in "${excluded_dirs[@]}"; do
        prune_expr="$prune_expr -path $dir -prune -o"
    done
    echo "==== Media file scan results: $(date) ====" >> "$LOG_FILE"
    for ext in "${extensions[@]}"; do
        sudo find / $prune_expr -name "$ext" -type f -print 2>/dev/null >> "$LOG_FILE" || true
    done
    c_print_success "Media file scan finished; results appended to $LOG_FILE"
    log "Media file scan completed."
}

# 10) Service review & hardening (interactive)
configure_services() {
    c_print_info "=== Service review & hardening ==="
    services=( "apache2" "nginx" "samba" "vsftpd" "nfs-server" "rpcbind" "avahi-daemon" "bluetooth" )
    for svc in "${services[@]}"; do
        if systemctl list-unit-files | grep -q "^${svc}"; then
            if systemctl is-active --quiet "$svc"; then
                c_print_info "Service $svc is active."
                if prompt_confirm "Keep and configure $svc (y) or disable it (n)?"; then
                    case $svc in
                        apache2)
                            $SUDO a2enmod headers 2>/dev/null || true
                            echo "Header always set X-Content-Type-Options 'nosniff'" | $SUDO tee -a /etc/apache2/conf-available/security.conf >/dev/null 2>&1 || true
                            $SUDO systemctl restart apache2 2>/dev/null || true
                            ;;
                        nginx)
                            $SUDO sed -i '/server_tokens/c\    server_tokens off;' /etc/nginx/nginx.conf 2>/dev/null || true
                            $SUDO systemctl restart nginx 2>/dev/null || true
                            ;;
                        samba)
                            $SUDO sed -i '/^[[:space:]]*guest ok[[:space:]]*=.*/c\    guest ok = no' /etc/samba/smb.conf 2>/dev/null || true
                            $SUDO systemctl restart smbd 2>/dev/null || true
                            ;;
                        vsftpd)
                            $SUDO sed -i '/^anonymous_enable/c\anonymous_enable=NO' /etc/vsftpd.conf 2>/dev/null || true
                            $SUDO systemctl restart vsftpd 2>/dev/null || true
                            ;;
                        nfs-server|rpcbind)
                            $SUDO ufw allow from 192.168.0.0/24 to any port nfs 2>/dev/null || true
                            ;;
                    esac
                    c_print_success "Configured $svc as requested."
                else
                    $SUDO systemctl stop "$svc" 2>/dev/null || true
                    $SUDO systemctl disable "$svc" 2>/dev/null || true
                    c_print_warn "Stopped & disabled $svc."
                    if dpkg -l 2>/dev/null | awk '/^ii/ {print $2}' | grep -xq "$svc"; then
                        if prompt_confirm "Remove package $svc?"; then
                            $SUDO apt-get purge -y "$svc" || true
                            c_print_success "Removed $svc package."
                        fi
                    fi
                fi
            fi
        fi
    done
    log "Service hardening pass completed."
}

# 11) Cron handling
configure_crontabs_restrict() {
    c_print_info "=== Cron & scheduled tasks ==="
    backup_file /etc/crontab
    if prompt_confirm "Remove all non-root user crontabs (recommended for locked images)?"; then
        $SUDO crontab -r 2>/dev/null || true
        $SUDO rm -f /etc/cron.d/* /var/spool/cron/crontabs/* 2>/dev/null || true
        echo root | $SUDO tee /etc/cron.allow >/dev/null
        echo root | $SUDO tee /etc/at.allow >/dev/null
        $SUDO chown root:root /etc/cron.allow /etc/at.allow 2>/dev/null || true
        $SUDO chmod 400 /etc/cron.allow /etc/at.allow 2>/dev/null || true
        c_print_success "Cron restricted to root."
    else
        c_print_warn "Cron user crontabs preserved."
    fi
    log "configure_crontabs_restrict: done"
}

# 12) File permissions hardening
secure_file_permissions() {
    c_print_info "=== File permission hardening ==="
    if [ "${DRY_RUN:-false}" = "true" ]; then
        c_print_info "DRY_RUN: would set critical file permissions"
        return 0
    fi
    backup_file /etc/shadow
    $SUDO chmod 600 /etc/shadow 2>/dev/null || true
    $SUDO chmod 644 /etc/passwd 2>/dev/null || true
    $SUDO chmod 640 /etc/gshadow 2>/dev/null || true
    $SUDO chmod 644 /etc/group 2>/dev/null || true
    $SUDO chmod 644 /etc/shells 2>/dev/null || true
    $SUDO chmod 644 /etc/crontab 2>/dev/null || true
    $SUDO chmod 644 /etc/fstab 2>/dev/null || true
    [ -f /etc/sudoers ] && backup_file /etc/sudoers && $SUDO chmod 440 /etc/sudoers 2>/dev/null || true

    if [ -d /root/.ssh ]; then
        $SUDO chmod 700 /root/.ssh 2>/dev/null || true
        [ -f /root/.ssh/authorized_keys ] && $SUDO chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
        $SUDO chown -R root:root /root/.ssh 2>/dev/null || true
    fi

    for u in $(awk -F: '($3 >= 1000 && $3 < 65534) {print $1}' /etc/passwd); do
        [ -d "/home/${u}" ] && $SUDO chmod -R 750 "/home/${u}" || true
    done

    c_print_success "Critical file and home directory permissions set."
    log "File permission adjustments done."
}

# 13) System updates & security tooling
system_updates_tools() {
    c_print_info "=== System updates & security tooling ==="
    if [ "${DRY_RUN:-false}" = "true" ]; then
        c_print_info "DRY_RUN: would attempt installs of security tooling"
        return 0
    fi
    $SUDO apt-get -y -qq -f install || true
    safe_apt_install auditd audispd-plugins rkhunter lynis chkrootkit clamav clamav-daemon aide gufw || true
    $SUDO systemctl enable --now auditd 2>/dev/null || true
    $SUDO systemctl start clamav-daemon 2>/dev/null || true
    c_print_success "Attempted updates & installed selected security tools."
    log "Updates/tools attempted; review apt output above."
}

# 14) Additional security (LightDM, SysRq, DNS)
additional_security() {
    c_print_info "=== Additional security configurations ==="
    if [ -d /etc/lightdm ]; then
        backup_file /etc/lightdm/lightdm.conf
        $SUDO bash -c 'cat > /etc/lightdm/lightdm.conf <<EOF
[SeatDefaults]
allow-guest=false
greeter-hide-users=true
greeter-show-manual-login=true
EOF'
        $SUDO chmod 644 /etc/lightdm/lightdm.conf 2>/dev/null || true
        c_print_success "LightDM configured."
    fi

    if [ -f /etc/default/irqbalance ]; then
        backup_file /etc/default/irqbalance
        $SUDO bash -c 'cat > /etc/default/irqbalance <<EOF
ENABLED="0"
ONESHOT="0"
EOF'
        c_print_success "IRQ balance disabled."
    fi

    if [ -w /proc/sys/kernel/sysrq ]; then
        echo 0 | $SUDO tee /proc/sys/kernel/sysrq >/dev/null 2>&1 || true
        c_print_success "SysRq disabled at runtime."
    fi

    c_print_info "DNS check..."
    if command -v resolvectl >/dev/null 2>&1; then
        if prompt_confirm "Flush systemd-resolved DNS cache now?"; then
            $SUDO resolvectl flush-caches && c_print_success "resolvectl flush-caches executed" || c_print_warn "resolvectl flush-caches had issues"
        fi
    elif $SUDO systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        if prompt_confirm "Restart systemd-resolved to refresh DNS?"; then
            $SUDO systemctl restart systemd-resolved && c_print_success "systemd-resolved restarted" || c_print_warn "Restart reported issues"
        fi
    fi

    if [ -f /etc/resolv.conf ]; then
        if [ -L /etc/resolv.conf ]; then
            c_print_warn "/etc/resolv.conf is a symlink; changing it may affect systemd-resolved."
            if prompt_confirm "Replace /etc/resolv.conf with recommended DNS servers?"; then
                backup_file /etc/resolv.conf
                $SUDO bash -c 'cat > /etc/resolv.conf <<EOF
# Managed by cypat_final
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
options timeout:2 attempts:3 rotate
EOF'
                c_print_success "/etc/resolv.conf replaced."
            else
                c_print_warn "Skipped changing /etc/resolv.conf."
            fi
        else
            if prompt_confirm "Overwrite /etc/resolv.conf with recommended DNS servers?"; then
                backup_file /etc/resolv.conf
                $SUDO bash -c 'cat > /etc/resolv.conf <<EOF
# Managed by cypat_final
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
options timeout:2 attempts:3 rotate
EOF'
                c_print_success "/etc/resolv.conf replaced."
            else
                c_print_warn "Skipped changing /etc/resolv.conf."
            fi
        fi
    fi
    log "Additional security settings applied where operator approved."
}

# 15) Audit configuration
configure_audit() {
    c_print_info "=== Audit: auditd & AIDE (optional) ==="
    safe_apt_install auditd audispd-plugins aide || true
    $SUDO systemctl enable --now auditd 2>/dev/null || true
    $SUDO auditctl -e 1 2>/dev/null || true

    if prompt_confirm "Enable execve auditing for root (useful for scoring but noisy)?"; then
        $SUDO auditctl -a exit,always -F arch=b64 -F euid=0 -S execve -k rootcmd || true
        $SUDO auditctl -a exit,always -F arch=b32 -F euid=0 -S execve -k rootcmd || true
        c_print_success "Added execve audit rules for root."
    else
        c_print_warn "Skipped execve audit rules."
    fi

    if prompt_confirm "Install & initialize AIDE (filesystem integrity) now?"; then
        $SUDO aideinit || true
        c_print_success "AIDE init attempted (check /var/lib/aide)."
    else
        c_print_warn "Skipped AIDE initialization."
    fi
    log "Audit configuration completed."
}

# 16) Anti-USB
anti_usb() {
    c_print_info "=== Anti-USB measures ==="
    if prompt_confirm "Block usb-storage module (reboot required) by installing stub?"; then
        backup_file /etc/modprobe.d/99-cis-usb.conf
        $SUDO bash -c 'echo "install usb-storage /bin/true" > /etc/modprobe.d/99-cis-usb.conf'
        $SUDO bash -c 'echo "blacklist usb_storage" >> /etc/modprobe.d/99-cis-usb.conf'
        c_print_success "Wrote /etc/modprobe.d/99-cis-usb.conf; reboot required."
    else
        c_print_warn "Skipped blocking usb-storage."
    fi
    if prompt_confirm "Restrict /media permissions to 700? (may affect auto-mount)"; then
        $SUDO chmod 700 /media || true
        c_print_success "/media permissions set to 700"
    else
        c_print_warn "Skipped /media permission change."
    fi
    log "anti_usb: done"
}

# 17) Reset all passwords (optimized version)
reset_all_passwords() {
    c_print_info "=== Reset ALL user passwords (interactive) ==="

    if ! prompt_confirm "Would you like to reset passwords for non-system users?"; then
        c_print_warn "Password reset module skipped by operator."
        return 0
    fi

    if prompt_confirm "Reset passwords for ALL non-system users? (No = manually select users)"; then
        mode="all"
    else
        mode="select"
    fi

    if [ "${DRY_RUN:-false}" = "true" ]; then
        c_print_info "DRY_RUN: would prompt for passwords & apply changes."
        return 0
    fi

    read -rsp "Enter the NEW password to apply: " new_pass
    echo
    read -rsp "Confirm the NEW password: " new_pass_confirm
    echo
    if [ "$new_pass" != "$new_pass_confirm" ]; then
        c_print_fail "Passwords do not match. Aborting."
        return 1
    fi

    all_users=( $(awk -F: '
        ($3 >= 1000 && $3 < 60000) && $1 != "nobody" && $7 !~ /(nologin|false)/ {print $1}
    ' /etc/passwd) )

    filtered_users=()
    for u in "${all_users[@]}"; do
        [ "$u" = "root" ] && continue
        filtered_users+=("$u")
    done

    if [ "$mode" = "select" ]; then
        c_print_info "Detected users: ${filtered_users[*]}"
        read -rp "Enter usernames to reset (space-separated): " -a sel
        users_to_update=()
        for u in "${sel[@]}"; do
            if printf "%s\n" "${filtered_users[@]}" | grep -qx "$u"; then
                users_to_update+=("$u")
            else
                c_print_warn "Skipping unknown or system user: $u"
            fi
        done
    else
        users_to_update=( "${filtered_users[@]}" )
    fi

    if [ ${#users_to_update[@]} -eq 0 ]; then
        c_print_warn "No valid users selected. Nothing to do."
        return 0
    fi

    log "Resetting passwords for: ${users_to_update[*]}"
    c_print_info "Updating passwords..."

    for usr in "${users_to_update[@]}"; do
        if echo "$usr:$new_pass" | $SUDO chpasswd 2>/dev/null; then
            c_print_success "Password reset: $usr"
            log_success "Password updated for $usr"
        else
            c_print_fail "Failed to update: $usr"
            log_fail "Failed to update $usr"
        fi
    done

    c_print_success "All selected password resets completed."
    c_print_warn "Password was NOT stored in any log."
    return 0
}

# 18) User management (enhanced: add/remove users, groups create/remove, add users to groups)
manage_users() {
    c_print_info "=== User & Sudoers Management ==="

    if prompt_confirm "Add new users now?"; then
        read -rp "Enter usernames to add (comma or space separated): " user_input
        user_input="$(trim "$user_input")"
        IFS=$' ,\t' read -r -a uadd <<< "$user_input"
        for u in "${uadd[@]}"; do
            [ -z "$u" ] && continue
            if [[ "$u" =~ [[:space:]] ]]; then
                c_print_warn "Skipping username with whitespace: $u"
                continue
            fi
            if id "$u" &>/dev/null; then
                c_print_warn "User '$u' already exists, skipping..."
                continue
            fi
            if [ "${DRY_RUN:-false}" = "true" ]; then
                c_print_info "DRY_RUN: would add user $u"
            else
                $SUDO adduser --gecos "" --disabled-password "$u" && c_print_success "Added user $u" || c_print_warn "Could not add $u"
            fi
        done

        # Offer adding new users to groups
        if prompt_confirm "After creating users, do you want to add them to groups now?"; then
            read -rp "Enter group name to add to (existing or new): " grp
            grp="$(trim "$grp")"
            if [ -z "$grp" ]; then
                c_print_warn "No group provided, skipping group assignment."
            else
                if ! getent group "$grp" >/dev/null; then
                    if prompt_confirm "Group $grp doesn't exist. Create it?"; then
                        $SUDO groupadd "$grp" && c_print_success "Created group $grp" || c_print_warn "Failed to create group $grp"
                    else
                        c_print_warn "Skipping creation of $grp"
                        grp=""
                    fi
                fi
                if [ -n "$grp" ]; then
                    for u in "${uadd[@]}"; do
                        [ -z "$u" ] && continue
                        if id "$u" &>/dev/null; then
                            $SUDO usermod -aG "$grp" "$u" && c_print_success "Added $u to $grp" || c_print_warn "Failed adding $u to $grp"
                        fi
                    done
                fi
            fi
        fi
    fi

    if prompt_confirm "Remove users now?"; then
        read -rp "Enter usernames to remove (space-separated): " -a rmlist
        for u in "${rmlist[@]}"; do
            [ -z "$u" ] && continue
            if [ "${DRY_RUN:-false}" = "true" ]; then
                c_print_info "DRY_RUN: would remove user $u"
            else
                $SUDO deluser --remove-home "$u" && c_print_success "Removed $u" || c_print_warn "Could not remove $u"
            fi
        done
    fi

    if prompt_confirm "Create a new group now?"; then
        read -rp "Enter group name to create: " newg
        newg="$(trim "$newg")"
        if [ -n "$newg" ]; then
            if getent group "$newg" >/dev/null; then
                c_print_warn "Group $newg already exists."
            else
                $SUDO groupadd "$newg" && c_print_success "Group $newg created" || c_print_warn "Failed to create $newg"
            fi
        fi
    fi

    if prompt_confirm "Remove an existing group now?"; then
        read -rp "Enter group name to remove: " remg
        remg="$(trim "$remg")"
        if [ -n "$remg" ]; then
            if getent group "$remg" >/dev/null; then
                $SUDO groupdel "$remg" && c_print_success "Group $remg removed" || c_print_warn "Failed to remove $remg"
            else
                c_print_warn "Group $remg not found."
            fi
        fi
    fi

    if prompt_confirm "Modify group membership now?"; then
        read -rp "Enter username to modify: " modu
        read -rp "Enter group to add (leave blank to skip): " addg
        read -rp "Enter group to remove (leave blank to skip): " remg2
        modu="$(trim "$modu")"
        addg="$(trim "$addg")"
        remg2="$(trim "$remg2")"
        if [ -n "$addg" ]; then
            if ! getent group "$addg" >/dev/null; then
                if prompt_confirm "Group $addg doesn't exist. Create it?"; then
                    $SUDO groupadd "$addg" || c_print_warn "Failed to create $addg"
                fi
            fi
            $SUDO usermod -aG "$addg" "$modu" && c_print_success "Added $modu to $addg" || c_print_warn "Failed to add $modu to $addg"
        fi
        if [ -n "$remg2" ]; then
            $SUDO gpasswd -d "$modu" "$remg2" && c_print_success "Removed $modu from $remg2" || c_print_warn "Failed to remove $modu from $remg2"
        fi
    fi

    if prompt_confirm "Sanitize sudoers (remove NOPASSWD / !authenticate)? Recommended"; then
        backup_file /etc/sudoers
        if [ -f /etc/sudoers ]; then
            $SUDO sed -i '/!authenticate/d' /etc/sudoers || true
            $SUDO sed -i '/NOPASSWD/d' /etc/sudoers || true
            $SUDO sed -i 's/Defaults\s*!env_reset/Defaults    env_reset/' /etc/sudoers || true
        fi
        for f in /etc/sudoers.d/*; do
            [ -f "$f" ] || continue
            backup_file "$f"
            $SUDO sed -i '/!authenticate/d' "$f" || true
            $SUDO sed -i '/NOPASSWD/d' "$f" || true
            $SUDO sed -i 's/Defaults\s*!env_reset/Defaults    env_reset/' "$f" || true
        done
        c_print_success "Sudoers sanitized to enforce authentication."
    else
        c_print_warn "Sudoers sanitation skipped."
    fi

    log "User management completed."
    return 0
}

# 19) Audit for scanners etc.
audit_for_scanners() {
    c_print_info "=== Scan for network scanner / password-cracking packages ==="
    candidates='nmap|masscan|wireshark|tcpdump|aircrack|john|hydra|hashcat|sqlmap|nikto|metasploit|burpsuite|zaproxy'
    dpkg -l 2>/dev/null | awk '/^ii/ {print $2}' | grep -Ei "$candidates" || c_print_info "No suspicious scanner packages detected (based on patterns)."
}

# -------------------------
# Run-all sequence
# -------------------------
run_all() {
    c_print_info "=== Running all selected hardening functions (interactive) ==="
    steps=( apt_update_upgrade ensure_security_repo configure_unattended_upgrades remove_unwanted_packages_interactive \
            configure_firewall_baseline harden_ssh_safe configure_password_policy harden_kernel_sysctl \
            scan_media_files configure_services configure_crontabs_restrict secure_file_permissions \
            system_updates_tools additional_security configure_audit anti_usb reset_all_passwords manage_users )
    for f in "${steps[@]}"; do
        c_print_info "Running: $f"
        $f || c_print_warn "Function $f returned non-zero; check $LOG_FILE"
        sleep 1
    done
    c_print_success "Completed run-all sequence."
    log "Run-all sequence finished."
}

# -------------------------
# Menu
# -------------------------
show_menu() {
    cat <<'MENU'
CyberPatriot / CIS Hardening Script - Menu
a) Execute recommended all functions
1) apt update & upgrade + fixes
2) Ensure security repo lines
3) Configure unattended-upgrades (security)
4) Remove potentially unwanted packages
5) Firewall & Network (UFW baseline)
6) SSH Hardening (safe)
7) Password Policies & PAM (Option B)
8) Kernel & sysctl Hardening
9) Media File Scan
10) Service Review & Hardening
11) Cron & scheduled tasks (restrict)
12) File Permissions
13) Install security tools & updates
14) Additional security (LightDM, SysRq, DNS)
15) Audit (auditd & AIDE)
16) Anti-USB Measures
17) Reset all user passwords
18) User Management & Sudoers (add/remove groups/users)
19) Scan for scanners/password tools
0) Exit
MENU
}

# -------------------------
# Main interactive loop
# -------------------------
while true; do
    show_menu
    read -rp "Choose option (0-19, a): " choice
    case "$choice" in
        a) if prompt_confirm "Run ALL functions now? (interactive prompts will still appear)"; then run_all; fi ;;
        1) apt_update_upgrade ;;
        2) ensure_security_repo ;;
        3) configure_unattended_upgrades ;;
        4) remove_unwanted_packages_interactive ;;
        5) configure_firewall_baseline ;;
        6) harden_ssh_safe ;;
        7) configure_password_policy ;;
        8) harden_kernel_sysctl ;;
        9) scan_media_files ;;
        10) configure_services ;;
        11) configure_crontabs_restrict ;;
        12) secure_file_permissions ;;
        13) system_updates_tools ;;
        14) additional_security ;;
        15) configure_audit ;;
        16) anti_usb ;;
        17) reset_all_passwords ;;
        18) manage_users ;;
        19) audit_for_scanners ;;
        0) c_print_info "Exiting. Log: $LOG_FILE  Backups: $BACKUP_DIR"; exit 0 ;;
        *) echo "Invalid option." ;;
    esac
    echo
    read -rp "Press Enter to return to menu..." unused
done
