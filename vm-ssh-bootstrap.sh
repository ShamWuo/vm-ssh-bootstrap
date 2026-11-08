#!/usr/bin/env bash
# =============================================================================
#  vm-ssh-bootstrap.sh - Turn a fresh Linux VM into an SSH server
#  https://github.com/ShamWuo/vm-ssh-bootstrap
#
#  One file, no dependencies beyond what a stock Ubuntu/Debian or RHEL/Fedora
#  image already ships. Paste it into a VMware/VirtualBox console (or curl it),
#  run it, and it prints the exact ssh command for your client machine.
#
#  Idempotent. Backs up sshd_config before editing and refuses to restart a
#  configuration that fails `sshd -t`.
#
#  Usage:
#    sudo bash vm-ssh-bootstrap.sh                  # set up SSH, print client cmd
#    sudo bash vm-ssh-bootstrap.sh --status         # report only, no changes
#    sudo bash vm-ssh-bootstrap.sh --port 2222      # non-default port
#    sudo bash vm-ssh-bootstrap.sh --pubkey "ssh-ed25519 AAAA... you@laptop"
#    sudo bash vm-ssh-bootstrap.sh --help
# =============================================================================

set -euo pipefail

CONF=/etc/ssh/sshd_config
PORT=22
PORT_EXPLICIT=0
PUBKEY=""
STATUS_ONLY=0

usage() {
    cat <<'USAGE'
vm-ssh-bootstrap.sh - turn a fresh Linux VM into an SSH server

Usage:
  sudo bash vm-ssh-bootstrap.sh [options]

Options:
  --port, -p N     Listen on port N (default 22)
  --pubkey, -k K   Install public key K for the login user (skips password auth)
  --status         Show current SSH state and the client command; change nothing
  --help, -h       This message

Does not disable SSH: on a scored image, removing the grader's only way in is
worse than leaving the service up. Follow your scenario's rules.
USAGE
}

die() { echo "[!] $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port|-p)
            [[ $# -ge 2 ]] || die "--port requires a value"
            [[ "$2" =~ ^[0-9]+$ ]] || die "--port must be a number, got: $2"
            # 10# forces base 10 so "08" is 8 and not an invalid octal literal.
            (( 10#$2 >= 1 && 10#$2 <= 65535 )) || die "--port must be 1-65535, got: $2"
            PORT="$((10#$2))"; PORT_EXPLICIT=1; shift 2 ;;
        --pubkey|-k)
            [[ $# -ge 2 ]] || die "--pubkey requires a value"
            PUBKEY="$2"; shift 2 ;;
        --status) STATUS_ONLY=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "[!] Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# ----- Root check -------------------------------------------------------------
if [[ $EUID -ne 0 && $STATUS_ONLY -eq 0 ]]; then
    die "must run as root to install sshd and open the firewall.
    Re-run as root: sudo bash vm-ssh-bootstrap.sh
    Or non-interactively: curl -fsSL <script-url> | sudo bash"
fi

# ----- Detect login user (never root unless there is no one else) ------------
detect_user() {
    local candidate=""
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        echo "${SUDO_USER}"; return
    fi
    candidate="$(logname 2>/dev/null || true)"
    if [[ -z "$candidate" || "$candidate" == "root" ]]; then
        candidate="$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd 2>/dev/null || true)"
    fi
    [[ -n "$candidate" ]] || candidate="root"
    if [[ "$candidate" == "root" ]]; then
        echo "[*] Warning: no non-root account found; many images forbid root SSH login" >&2
        echo "    (PermitRootLogin no). Create or authorize a user first." >&2
    fi
    echo "$candidate"
}

# ----- Detect the address a client machine should dial -----------------------
detect_ip() {
    local ip=""
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}' || true)"
    if [[ -z "$ip" ]]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    fi
    echo "$ip"
}

TARGET_USER="$(detect_user)"
VM_IP="$(detect_ip)"
SSHD_BIN="$(command -v sshd 2>/dev/null || true)"
if [[ -z "$SSHD_BIN" ]]; then
    SSHD_BIN=/usr/sbin/sshd
fi

# Effective port when --port was not given: follow what sshd will actually use,
# so the printed client command and the firewall rule match reality. A scenario
# that mandates a custom port must not get a bare `ssh user@ip`.
if [[ $PORT_EXPLICIT -eq 0 ]]; then
    EFFECTIVE=""
    if [[ -x "$SSHD_BIN" ]]; then
        EFFECTIVE="$("$SSHD_BIN" -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true)"
    fi
    if [[ -z "$EFFECTIVE" ]]; then
        EFFECTIVE="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' "$CONF" 2>/dev/null || true)"
    fi
    if [[ -n "$EFFECTIVE" ]]; then
        PORT="$EFFECTIVE"
    fi
fi

# Fail before touching anything if the key has nowhere to go.
USER_HOME=""
if [[ -n "$PUBKEY" ]]; then
    USER_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"
    [[ -n "$USER_HOME" && -d "$USER_HOME" ]] || die "no home directory for ${TARGET_USER}; cannot install the key."
fi

show_command() {
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    local port_flag="" scp_flag=""
    if [[ "$PORT" != "22" ]]; then
        port_flag=" -p ${PORT}"
        scp_flag=" -P ${PORT}"
    fi

    echo
    echo "======================================================================"
    echo "  RUN THIS ON YOUR CLIENT MACHINE:"
    echo "======================================================================"
    if [[ -z "$VM_IP" ]]; then
        echo "  [!] No non-loopback IPv4 address found on this VM."
        echo "      Give the adapter a routable address first:"
        echo "        VMware Fusion:      Network Adapter -> Bridged (or NAT to reach"
        echo "                            the host Mac only)"
        echo "        VMware Workstation: Network Adapter -> Bridged (or NAT plus a"
        echo "                            VMnet8 port forward to reach it off-host)"
        echo "      then re-run: sudo bash vm-ssh-bootstrap.sh --status"
    else
        echo "  ssh ${ssh_opts}${port_flag} ${TARGET_USER}@${VM_IP}"
        echo
        echo "  Passwordless login:  ssh-copy-id ${ssh_opts}${port_flag} ${TARGET_USER}@${VM_IP}"
        echo "  Copy files over:     scp -r ${ssh_opts}${scp_flag} <local-path> ${TARGET_USER}@${VM_IP}:~/"
        echo
        echo "  Reaching this VM from another machine depends on the VM network"
        echo "  mode: NAT is reachable from the hypervisor host only, Bridged is"
        echo "  reachable from anywhere on the same LAN. See the README."
    fi
    echo "======================================================================"
}

# ----- --status ---------------------------------------------------------------
if [[ $STATUS_ONLY -eq 1 ]]; then
    if [[ -x "$SSHD_BIN" ]]; then
        echo "[*] sshd binary:    ${SSHD_BIN}"
    else
        echo "[*] sshd binary:    not installed"
    fi
    if systemctl is-active --quiet ssh 2>/dev/null; then
        echo "[*] ssh service:    active"
    elif systemctl is-active --quiet sshd 2>/dev/null; then
        echo "[*] sshd service:   active"
    else
        echo "[*] ssh service:    not active"
    fi
    if command -v ss >/dev/null 2>&1; then
        echo "[*] listening on ${PORT}: $(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E "[:.]${PORT}\$" | paste -sd' ' - || true)"
    fi
    echo "[*] login user:     ${TARGET_USER}"
    echo "[*] VM address:     ${VM_IP:-none detected}"
    show_command
    exit 0
fi

# ----- 1. Install openssh-server if missing ----------------------------------
if [[ -x "$SSHD_BIN" ]]; then
    echo "[*] OpenSSH Server already installed."
else
    echo "[*] Installing openssh-server..."
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server \
            || die "apt-get install openssh-server failed. Check the VM's network/NAT."
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y openssh-server >/dev/null || die "dnf install openssh-server failed."
    elif command -v yum >/dev/null 2>&1; then
        yum install -y openssh-server >/dev/null || die "yum install openssh-server failed."
    else
        die "no supported package manager found (apt/dnf/yum)."
    fi
    echo "[+] openssh-server installed."
fi

# ----- 2. Host keys -----------------------------------------------------------
ssh-keygen -A >/dev/null 2>&1 || true

# ----- 3. Configuration -------------------------------------------------------
# Authentication prefers a drop-in when sshd_config includes that directory:
# drop-ins are read first, so ours beats a conflicting default in
# 50-cloud-init.conf. Port is always handled in the main file -- sshd listens
# on every Port line it accumulates, so the old one must be replaced, not
# merely shadowed by a drop-in.
DROPIN=""
if [[ -d /etc/ssh/sshd_config.d ]] && grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d' "$CONF" 2>/dev/null; then
    DROPIN=/etc/ssh/sshd_config.d/00-vm-ssh-bootstrap.conf
fi

BACKUP=""
backup_conf() {   # back up whichever file we are about to touch, once
    local target="$1"
    [[ -n "$BACKUP" ]] && return 0
    BACKUP="${target}.bak.$(date +%s)"
    cp -p "$target" "$BACKUP"
    echo "[*] Backed up ${target} -> ${BACKUP}"
}

# 3a. Password authentication (only when no key was supplied)
if [[ -z "$PUBKEY" ]]; then
    if [[ -n "$DROPIN" ]]; then
        # Ours to manage: rewrite on every run so re-runs stay idempotent.
        {
            echo "# Managed by vm-ssh-bootstrap.sh"
            echo "PasswordAuthentication yes"
        } > "$DROPIN"
        chmod 644 "$DROPIN"
        echo "[+] Wrote ${DROPIN}"
    elif grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+no' "$CONF" 2>/dev/null; then
        backup_conf "$CONF"
        # Plain BRE + a temp file (no sed -i, no +): identical on GNU and BSD sed.
        tmp_conf="$(mktemp)"
        sed 's/^[[:space:]]*PasswordAuthentication[[:space:]][[:space:]]*no/PasswordAuthentication yes/' \
            "$CONF" > "$tmp_conf" && cat "$tmp_conf" > "$CONF"
        rm -f "$tmp_conf"
        if grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+yes' "$CONF"; then
            echo "[+] Enabled PasswordAuthentication in ${CONF}"
        else
            echo "[!] Could not flip PasswordAuthentication in ${CONF}; set it by hand." >&2
        fi
    fi
elif [[ -n "$DROPIN" && -f "$DROPIN" ]]; then
    # A previous password-auth run left our drop-in behind; with a key in hand
    # the image's own setting should apply again.
    rm -f "$DROPIN"
    echo "[*] Removed ${DROPIN} (key login only)."
fi

# 3b. Port, only when explicitly requested and only when it differs.
if [[ $PORT_EXPLICIT -eq 1 ]]; then
    ACTIVE_PORT="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' "$CONF" 2>/dev/null || true)"
    if [[ "$ACTIVE_PORT" == "$PORT" ]]; then
        echo "[*] ${CONF} already sets Port ${PORT}."
    elif [[ -z "$ACTIVE_PORT" && "$PORT" == "22" ]]; then
        echo "[*] Port stays at the sshd default of 22."
    else
        backup_conf "$CONF"
        # Replace an existing Port line, else insert before the first Match
        # block, else append (a Port line inside Match would be invalid).
        tmp="$(mktemp)"
        awk -v p="$PORT" '
            /^[[:space:]]*Port[[:space:]]/ { print "Port " p; seen = 1; next }
            /^[[:space:]]*Match[[:space:]]/ && !seen { print "Port " p; seen = 1 }
            { print }
            END { if (!seen) print "Port " p }
        ' "$CONF" > "$tmp" && cat "$tmp" > "$CONF"
        rm -f "$tmp"
        echo "[+] Port set to ${PORT} in ${CONF}"
    fi
fi

# ----- 4. Optional public key ------------------------------------------------
if [[ -n "$PUBKEY" ]]; then
    mkdir -p "${USER_HOME}/.ssh"
    touch "${USER_HOME}/.ssh/authorized_keys"
    chown -R "${TARGET_USER}:" "${USER_HOME}/.ssh" 2>/dev/null || true
    if grep -qxF "$PUBKEY" "${USER_HOME}/.ssh/authorized_keys" 2>/dev/null; then
        echo "[*] Key already present for ${TARGET_USER}."
    else
        echo "$PUBKEY" >> "${USER_HOME}/.ssh/authorized_keys"
        echo "[+] Key installed for ${TARGET_USER}."
    fi
    chmod 700 "${USER_HOME}/.ssh"
    chmod 600 "${USER_HOME}/.ssh/authorized_keys"
    chown "${TARGET_USER}:" "${USER_HOME}/.ssh/authorized_keys" 2>/dev/null || true
fi

# ----- 5. Validate before restarting anything --------------------------------
mkdir -p /run/sshd 2>/dev/null || true
if ! err="$("$SSHD_BIN" -t 2>&1)"; then
    echo "[!] sshd -t rejects the configuration:" >&2
    echo "    ${err}" >&2
    if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
        cp -p "$BACKUP" "${BACKUP%.bak.*}"
        echo "[!] Restored ${BACKUP%.bak.*} from backup. Nothing was restarted." >&2
    fi
    if [[ -n "$DROPIN" && -f "$DROPIN" ]]; then
        rm -f "$DROPIN"
        echo "[!] Removed ${DROPIN}. Nothing was restarted." >&2
    fi
    exit 1
fi
echo "[+] sshd -t: configuration OK."

# ----- 6. Enable and start ---------------------------------------------------
START_OK=0
systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null \
    || service ssh start 2>/dev/null || service sshd start 2>/dev/null || true
if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
    START_OK=1
    echo "[+] SSH is enabled and running."
else
    echo "[!] SSH did not start. Check: systemctl status ssh" >&2
fi

# ----- 7. Firewall -----------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
    echo "[+] UFW rule present: allow ${PORT}/tcp."
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    echo "[+] firewalld rule added: ${PORT}/tcp."
fi

show_command
echo "  [i] Only leave SSH running if your scenario or image policy allows it."
if [[ $START_OK -eq 0 ]]; then
    exit 1
fi
