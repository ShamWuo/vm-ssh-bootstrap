#!/usr/bin/env bash
# =============================================================================
#  vm-ssh-bootstrap.sh - Turn a fresh Linux VM into an SSH server
#  v2.0.0  -  https://github.com/ShamWuo/vm-ssh-bootstrap
#
#  One file, no dependencies beyond what a stock Ubuntu/Debian, Linux Mint or
#  RHEL/Fedora image already ships. Paste it into a VMware/VirtualBox console
#  (or curl it), run it, and it prints the exact ssh command for your client.
#
#  Diagnostics first: every step reports what it found, what it changed and
#  what it skipped. A failure prints the failing tool's own output plus
#  targeted follow-up checks, and the whole transcript is written to
#  /tmp/vm-ssh-bootstrap.<epoch>.log (override with --log PATH).
#
#  Idempotent. Backs up sshd_config before editing and refuses to restart a
#  configuration that fails `sshd -t`.
#
#  Usage:
#    sudo bash vm-ssh-bootstrap.sh                  # set up SSH, print client cmd
#    sudo bash vm-ssh-bootstrap.sh --debug          # + full output, traced log
#    sudo bash vm-ssh-bootstrap.sh --status         # read-only report
#    sudo bash vm-ssh-bootstrap.sh --port 2222      # non-default port
#    sudo bash vm-ssh-bootstrap.sh --pubkey "ssh-ed25519 AAAA... you@laptop"
#    sudo bash vm-ssh-bootstrap.sh --help
#
#  Test hooks (unset in normal use): VMSSH_CONF, VMSSH_DROPIN_DIR, VMSSH_SSHD,
#  VMSSH_LOG relocate the config, drop-in directory, sshd binary and log.
# =============================================================================

# -e/-u/-o pipefail only: NOT -E, so the ERR trap is not inherited by command
# substitutions, where harmless failures (a missing file) would be reported as
# real errors.
set -euo pipefail

ORIG_ARGS=("$@")
SCRIPT_VERSION=2.0.0
CONF="${VMSSH_CONF:-/etc/ssh/sshd_config}"
DROPIN_DIR="${VMSSH_DROPIN_DIR:-/etc/ssh/sshd_config.d}"
DROPIN_NAME=00-vm-ssh-bootstrap.conf
LEGACY_DROPIN_NAME=00-fhs-vm-ssh.conf
LOG_FILE="${VMSSH_LOG:-/tmp/vm-ssh-bootstrap.$(date +%s).log}"

PORT=22
PORT_EXPLICIT=0
PUBKEY=""
STATUS_ONLY=0
DEBUG=0

usage() {
    cat <<'USAGE'
vm-ssh-bootstrap.sh - turn a fresh Linux VM into an SSH server

Usage:
  sudo bash vm-ssh-bootstrap.sh [options]

Options:
  --port, -p N     Listen on port N (default 22, or whatever sshd already uses)
  --pubkey, -k K   Install public key K for the login user (skips password auth)
  --status         Read-only report: versions, service, config, firewall, address
  --debug, -d      Print every command's output; trace each command into the log
  --log PATH       Transcript path (default /tmp/vm-ssh-bootstrap.<epoch>.log)
  --help, -h       This message

Every run is logged. If a step fails, the script prints that tool's own output
plus follow-up checks, and leaves the transcript path in the final summary.

Does not disable SSH: on a scored image, removing the grader's only way in is
worse than leaving the service up. Follow your scenario's rules.
USAGE
}

# =============================================================================
#  Output helpers. Everything printed also lands in the transcript.
# =============================================================================
_log() {
    printf '%s\n' "$*" >>"$LOG_FILE" 2>/dev/null || true
}

_log_block() {   # _log_block <title> <body>
    local title="$1" body="$2"
    _log "----- ${title} -----"
    if [[ -n "$body" ]]; then _log "$body"; fi
    return 0
}

say()  { printf '%s\n' "$*"; _log "$*"; }
info() { say "[*] $*"; }
ok()   { say "[+] $*"; }
warn() { printf '%s\n' "[!] $*" >&2; _log "[!] $*"; }
note() { printf '%s\n' "$*" >&2; _log "$*"; }

dbg() {
    if [[ $DEBUG -eq 1 ]]; then
        printf '%s\n' "[dbg] $*" >&2
    fi
    _log "[dbg] $*"
    return 0
}

# A labelled block of captured tool output: shown (indented) and logged whole.
diag_block() {   # diag_block <title> <body>
    local title="$1" body="$2"
    _log_block "$title" "$body"
    if [[ -z "$body" ]]; then
        note "      ${title}: (no output)"
        return 0
    fi
    note "      ${title}:"
    printf '%s\n' "$body" | head -35 | sed 's/^/        /' >&2
    return 0
}

die() {
    warn "$*"
    warn "Nothing further was changed."
    warn "Full transcript: ${LOG_FILE}"
    exit 1
}

# Any uncaught non-zero exit reports the exact line and command.
IN_ERR=0
on_err() {
    local rc="$1" line="$2" cmd="$3"
    if [[ $IN_ERR -eq 1 ]]; then return 0; fi
    IN_ERR=1
    printf '\n%s\n' "[!] FAILED: exit ${rc} at line ${line}" >&2
    printf '%s\n' "    command: ${cmd}" >&2
    _log "[!] FAILED: exit ${rc} at line ${line} :: ${cmd}"
    return 0
}
trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR

# =============================================================================
#  Argument parsing
# =============================================================================
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
        --debug|-d) DEBUG=1; shift ;;
        --log)
            [[ $# -ge 2 ]] || die "--log requires a path"
            LOG_FILE="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "[!] Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# ----- Transcript setup -------------------------------------------------------
init_log() {
    local dir
    dir="$(dirname "$LOG_FILE")"
    mkdir -p "$dir" 2>/dev/null || true
    if ! : >>"$LOG_FILE" 2>/dev/null; then
        printf '%s\n' "[!] cannot write ${LOG_FILE}; continuing without a transcript" >&2
        LOG_FILE=/dev/null
        return 0
    fi
    _log "===== vm-ssh-bootstrap v${SCRIPT_VERSION} $(date -Is 2>/dev/null || date) ====="
    _log "argv: $0 ${ORIG_ARGS[*]:-}"
    return 0
}
init_log "$@"

# In debug mode every executed command is traced into the transcript. Requires
# bash 4.1+ (BASH_XTRACEFD); on older shells the trace stays on the console.
if [[ $DEBUG -eq 1 ]]; then
    if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 1) )) \
        && exec 4>>"$LOG_FILE" 2>/dev/null; then
        BASH_XTRACEFD=4
        PS4='+[${LINENO}] '
        set -x
        info "Debug mode: full command output shown; every command traced into ${LOG_FILE}"
    else
        info "Debug mode: full command output shown (bash ${BASH_VERSION} cannot trace into the transcript)"
    fi
fi

# ----- Root check -------------------------------------------------------------
if [[ $EUID -ne 0 && $STATUS_ONLY -eq 0 ]]; then
    die "must run as root to install sshd and open the firewall.
    Re-run as root: sudo bash vm-ssh-bootstrap.sh"
fi

# =============================================================================
#  Detection
# =============================================================================
detect_user() {
    local candidate=""
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        dbg "login user: SUDO_USER=${SUDO_USER}"
        echo "${SUDO_USER}"; return
    fi
    candidate="$(logname 2>/dev/null || true)"
    dbg "login user: logname -> '${candidate}'"
    if [[ -z "$candidate" || "$candidate" == "root" ]]; then
        candidate="$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd 2>/dev/null || true)"
        dbg "login user: first uid>=1000 in /etc/passwd -> '${candidate}'"
    fi
    [[ -n "$candidate" ]] || candidate="root"
    if [[ "$candidate" == "root" ]]; then
        echo "[*] Warning: no non-root account found; many images forbid root SSH login" >&2
        echo "    (PermitRootLogin no). Create or authorize a user first." >&2
    fi
    echo "$candidate"
}

detect_ip() {
    local ip=""
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}' || true)"
    if [[ -z "$ip" ]]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    fi
    dbg "detected address: '${ip}'"
    echo "$ip"
}

detect_gateway() {
    local gw=""
    gw="$(ip -4 route show default 2>/dev/null | awk '/default/ {print $3; exit}' || true)"
    if [[ -z "$gw" ]]; then
        gw="$(ip -4 route 2>/dev/null | awk '/^default/ {print $3; exit}' || true)"
    fi
    echo "$gw"
}

os_release_value() {   # os_release_value KEY
    sed -n "s/^$1=//p" /etc/os-release 2>/dev/null | tr -d '"' | head -1 || true
}

TARGET_USER="$(detect_user)"
VM_IP="$(detect_ip)"
VM_GW="$(detect_gateway)"

SSHD_BIN="${VMSSH_SSHD:-}"
if [[ -z "$SSHD_BIN" ]]; then
    SSHD_BIN="$(command -v sshd 2>/dev/null || true)"
fi
if [[ -z "$SSHD_BIN" ]]; then
    SSHD_BIN=/usr/sbin/sshd
fi
dbg "sshd candidate: ${SSHD_BIN} (executable: $([[ -x "$SSHD_BIN" ]] && echo yes || echo no))"

# Effective port when --port was not given: follow what sshd will actually use,
# so the printed client command and the firewall rule match reality. A scenario
# that mandates a custom port must not get a bare `ssh user@ip`.
EFFECTIVE=""
if [[ $PORT_EXPLICIT -eq 0 ]]; then
    if [[ -x "$SSHD_BIN" ]]; then
        EFFECTIVE="$("$SSHD_BIN" -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true)"
        dbg "sshd -T reports port: '${EFFECTIVE}'"
    fi
    if [[ -z "$EFFECTIVE" ]]; then
        EFFECTIVE="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' "$CONF" 2>/dev/null || true)"
        dbg "config parse reports port: '${EFFECTIVE}'"
    fi
    if [[ -n "$EFFECTIVE" ]]; then
        PORT="$EFFECTIVE"
    fi
fi

# Fail before touching anything if the key has nowhere to go.
USER_HOME=""
if [[ -n "$PUBKEY" ]]; then
    USER_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"
    [[ -n "$USER_HOME" && -d "$USER_HOME" ]] || die "no home directory for ${TARGET_USER} (looked up '${USER_HOME:-<none>}'); cannot install the key."
    dbg "key target: ${USER_HOME}/.ssh/authorized_keys"
fi

# =============================================================================
#  Reports
# =============================================================================
print_fingerprint() {
    local free_mb=""
    info "=== environment ==="
    say "  distro:       $(os_release_value PRETTY_NAME) [codename $(os_release_value VERSION_CODENAME)]"
    say "  kernel:       $(uname -srm 2>/dev/null || echo unknown)"
    say "  init:         $(ps -p 1 -o comm= 2>/dev/null || echo unknown)"
    say "  running as:   $(id -un 2>/dev/null || echo unknown) (uid ${EUID}), login user: ${TARGET_USER}"
    say "  script:       v${SCRIPT_VERSION}"
    say "  transcript:   ${LOG_FILE}"
    say "  sshd:         ${SSHD_BIN} $([[ -x "$SSHD_BIN" ]] && echo "(present)" || echo "(not installed)")"
    say "  sshd_config:  ${CONF} $([[ -f "$CONF" ]] && echo "(present)" || echo "(missing)")"
    say "  port:         ${PORT} $([[ $PORT_EXPLICIT -eq 1 ]] && echo "(explicit)" || echo "(detected/default)")"
    say "  address:      ${VM_IP:-none detected}"
    say "  gateway:      ${VM_GW:-none detected}  (.2 on a NAT network, the LAN router when bridged)"
    if [[ -d "$DROPIN_DIR" ]]; then
        say "  drop-ins:     $(ls -1 "$DROPIN_DIR" 2>/dev/null | paste -sd' ' - || true)"
    else
        say "  drop-ins:     ${DROPIN_DIR} (absent)"
    fi
    free_mb="$(df -k / 2>/dev/null | awk 'NR==2 {print int($4/1024)}')"
    if [[ -n "$free_mb" ]]; then
        say "  free on /:    ${free_mb} MB"
        if [[ "$free_mb" -lt 200 ]]; then
            warn "low disk space (${free_mb} MB free); package installation may fail"
        fi
    fi
    return 0
}

conf_summary() {
    local lines="" line=""
    lines="$(grep -nE '^[[:space:]]*(Port|ListenAddress|PasswordAuthentication|PubkeyAuthentication|PermitRootLogin|Include)[[:space:]]' "$CONF" 2>/dev/null || true)"
    if [[ -z "$lines" ]]; then
        say "  ${CONF}: no relevant directives (built-in defaults apply)"
        return 0
    fi
    while IFS= read -r line; do
        say "  ${CONF}:${line}"
    done <<<"$lines"
    return 0
}

service_state() {
    if systemctl is-active --quiet ssh 2>/dev/null; then echo "active (ssh)"; return 0; fi
    if systemctl is-active --quiet sshd 2>/dev/null; then echo "active (sshd)"; return 0; fi
    echo "not active"
}

listeners() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E "[:.]${PORT}\$" | paste -sd' ' - || true
    fi
}

firewall_state() {
    if command -v ufw >/dev/null 2>&1; then
        echo "ufw: $(ufw status 2>/dev/null | head -1 || echo unknown)"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        echo "firewalld: $(firewall-cmd --state 2>/dev/null || echo unknown)"
    else
        echo "no ufw/firewalld found"
    fi
}

show_command() {
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    local port_flag="" scp_flag=""
    if [[ "$PORT" != "22" ]]; then
        port_flag=" -p ${PORT}"
        scp_flag=" -P ${PORT}"
    fi

    say ""
    say "======================================================================"
    say "  RUN THIS ON YOUR CLIENT MACHINE:"
    say "======================================================================"
    if [[ -z "$VM_IP" ]]; then
        say "  [!] No non-loopback IPv4 address found on this VM."
        say "      Give the adapter a routable address first:"
        say "        VMware Fusion:      Network Adapter -> Bridged (or NAT to reach"
        say "                            the host Mac only)"
        say "        VMware Workstation: Network Adapter -> Bridged (or NAT plus a"
        say "                            VMnet8 port forward to reach it off-host)"
        say "      then re-run: sudo bash vm-ssh-bootstrap.sh --status"
    else
        say "  ssh ${ssh_opts}${port_flag} ${TARGET_USER}@${VM_IP}"
        say ""
        say "  Passwordless login:  ssh-copy-id ${ssh_opts}${port_flag} ${TARGET_USER}@${VM_IP}"
        say "  Copy files over:     scp -r ${ssh_opts}${scp_flag} <local-path> ${TARGET_USER}@${VM_IP}:~/"
        say ""
        say "  Reaching this VM from another machine depends on the VM network"
        say "  mode: NAT is reachable from the hypervisor host only, Bridged is"
        say "  reachable from anywhere on the same LAN. See the README."
    fi
    say "======================================================================"
    return 0
}

# =============================================================================
#  --status : read-only
# =============================================================================
if [[ $STATUS_ONLY -eq 1 ]]; then
    print_fingerprint
    say ""
    info "=== ssh service ==="
    say "  service:      $(service_state)"
    say "  listening:    $(listeners || true)"
    say "  firewall:     $(firewall_state)"
    say ""
    info "=== configuration ==="
    conf_summary
    say ""
    info "=== failed systemd units (if any) ==="
    if command -v systemctl >/dev/null 2>&1; then
        failed_units="$(systemctl --failed --no-pager --no-legend 2>/dev/null | head -10 || true)"
        if [[ -n "$failed_units" ]]; then
            while IFS= read -r unit_line; do say "  ${unit_line}"; done <<<"$failed_units"
        else
            say "  none"
        fi
    else
        say "  systemctl not available"
    fi
    show_command
    exit 0
fi

# =============================================================================
#  Failure diagnostics
# =============================================================================
apt_diagnostics() {
    local body=""
    warn "=== apt diagnostics ==="

    body="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"') / codename $(os_release_value VERSION_CODENAME)"
    say "  distro:       ${body}"

    diag_block "dpkg --audit" "$(dpkg --audit 2>&1 || true)"
    diag_block "held packages (apt-mark showhold)" "$(apt-mark showhold 2>/dev/null || true)"
    diag_block "dpkg state" "$(dpkg -l openssh-server openssh-client 2>/dev/null | tail -n +6 || true)"
    diag_block "apt-cache policy" "$(apt-cache policy openssh-server openssh-client 2>/dev/null || true)"
    diag_block "apt sources and their codenames" "$(
        {
            grep -rhE '^[[:space:]]*deb(-src)?[[:space:]]' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null \
                | awk '{print $1, $2, $3}' || true
            grep -rhE '^(URIs|Suites|Components):' /etc/apt/sources.list.d/ 2>/dev/null || true
        } | sort -u
    )"
    # -s = simulate: shows why the resolver refuses, changes nothing.
    diag_block "resolver reasoning (simulated install)" "$(
        apt-get -s -o Debug::pkgProblemResolver=yes install openssh-server 2>&1 | head -30 || true
    )"
    diag_block "free space" "$(df -h / /var 2>/dev/null | awk 'NR==1 || !seen[$1]++' || true)"
    diag_block "dns resolution" "$(getent hosts archive.ubuntu.com 2>&1 || getent hosts deb.debian.org 2>&1 || true)"
    diag_block "failed systemd units" "$(systemctl --failed --no-pager --no-legend 2>/dev/null | head -10 || true)"

    warn "  If this is a held package, prefer the scenario README over"
    warn "  'apt-mark unhold': holds on a scored image are sometimes deliberate."
    warn "=== end apt diagnostics ==="
    return 0
}

rpm_diagnostics() {
    warn "=== dnf/yum diagnostics ==="
    diag_block "repos" "$("${PKG_MGR}" repolist 2>&1 | head -20 || true)"
    diag_block "package state" "$(rpm -q openssh-server openssh-clients 2>&1 || true)"
    diag_block "dsync" "$("${PKG_MGR}" distro-sync --assumeno 2>&1 | head -20 || true)"
    warn "=== end dnf/yum diagnostics ==="
    return 0
}

# run a command, log everything, show output on failure (always) or success (--debug)
capture() {   # capture <description> <command...>
    local desc="$1" rc=0 out=""
    shift
    dbg "exec: ${desc} -> $*"
    out="$("$@" 2>&1)" || rc=$?
    _log_block "${desc} [exit ${rc}]" "$out"
    if [[ $rc -ne 0 ]]; then
        warn "${desc} failed (exit ${rc}):"
        if [[ -n "$out" ]]; then printf '%s\n' "$out" | head -40 | sed 's/^/      /' >&2; fi
    elif [[ $DEBUG -eq 1 && -n "$out" ]]; then
        printf '%s\n' "$out" | head -40 | sed 's/^/      /' >&2
    fi
    return $rc
}

# =============================================================================
#  1. Install openssh-server
# =============================================================================
info "[1/7] openssh-server"
if [[ -x "$SSHD_BIN" ]]; then
    ok "already installed: $("$SSHD_BIN" -V 2>&1 | head -1 || true)"
else
    info "not installed (no executable at ${SSHD_BIN}); installing"
    PKG_MGR=""
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR=apt-get
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR=dnf
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR=yum
    else
        die "no supported package manager found (need apt-get, dnf or yum)."
    fi
    info "package manager: ${PKG_MGR}"

    if [[ "$PKG_MGR" == "apt-get" ]]; then
        dbg "refreshing package lists"
        if ! capture "apt-get update" env DEBIAN_FRONTEND=noninteractive apt-get update; then
            warn "package lists could not be refreshed; trying the install with cached lists"
        fi
        if ! capture "apt-get install openssh-server" \
                env DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server; then
            warn "apt-get could not install openssh-server."
            apt_diagnostics
            die "installation failed. The diagnostics above name the blocker; nothing in sshd_config was changed."
        fi
    else
        if ! capture "${PKG_MGR} install openssh-server" "${PKG_MGR}" install -y openssh-server; then
            rpm_diagnostics
            die "installation failed. See the diagnostics above; nothing in sshd_config was changed."
        fi
    fi

    if [[ -x "$SSHD_BIN" ]]; then
        ok "installed: $("$SSHD_BIN" -V 2>&1 | head -1 || true)"
    else
        die "${PKG_MGR} reported success but ${SSHD_BIN} is still missing."
    fi
fi

# =============================================================================
#  2. Host keys
# =============================================================================
info "[2/7] host keys"
ssh-keygen -A 2>/dev/null || true
HOSTKEYS="$(ls -1 /etc/ssh/ssh_host_*_key 2>/dev/null | paste -sd' ' - || true)"
ok "host keys: ${HOSTKEYS:-none (ssh-keygen -A produced nothing)}"

# =============================================================================
#  3. Configuration
# =============================================================================
info "[3/7] configuration"
# Authentication prefers a drop-in when sshd_config includes that directory:
# drop-ins are read first, so ours beats a conflicting default in
# 50-cloud-init.conf. Port is always handled in the main file -- sshd listens
# on every Port line it accumulates, so the old one must be replaced, not
# merely shadowed by a drop-in.
DROPIN=""
if [[ -d "$DROPIN_DIR" ]] && grep -qE "^[[:space:]]*Include[[:space:]]+${DROPIN_DIR}" "$CONF" 2>/dev/null; then
    DROPIN="${DROPIN_DIR}/${DROPIN_NAME}"
    info "using drop-in: ${DROPIN}"
else
    info "using ${CONF} directly (no usable Include for ${DROPIN_DIR})"
fi
dbg "existing directives before changes: $(grep -cE '^[[:space:]]*[A-Za-z]' "$CONF" 2>/dev/null || echo 0) non-comment lines"

BACKUP=""
backup_conf() {   # back up whichever file we are about to touch, once
    local target="$1"
    [[ -n "$BACKUP" ]] && return 0
    BACKUP="${target}.bak.$(date +%s)"
    cp -p "$target" "$BACKUP"
    ok "backed up ${target} -> ${BACKUP}"
    return 0
}

# A drop-in written by an older version of this script would keep forcing
# password auth even on a key-only run, so retire it when we own it.
LEGACY_DROPIN="${DROPIN_DIR}/${LEGACY_DROPIN_NAME}"
if [[ -f "$LEGACY_DROPIN" ]] && grep -q 'Managed by' "$LEGACY_DROPIN" 2>/dev/null; then
    rm -f "$LEGACY_DROPIN"
    ok "removed superseded drop-in ${LEGACY_DROPIN}"
fi

# 3a. Password authentication (only when no key was supplied)
if [[ -z "$PUBKEY" ]]; then
    if [[ -n "$DROPIN" ]]; then
        {
            echo "# Managed by vm-ssh-bootstrap.sh"
            echo "PasswordAuthentication yes"
        } >"$DROPIN"
        chmod 644 "$DROPIN"
        ok "wrote ${DROPIN}: PasswordAuthentication yes"
    elif grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+no' "$CONF" 2>/dev/null; then
        backup_conf "$CONF"
        # Plain BRE + a temp file (no sed -i, no +): identical on GNU and BSD sed.
        tmp_conf="$(mktemp)"
        sed 's/^[[:space:]]*PasswordAuthentication[[:space:]][[:space:]]*no/PasswordAuthentication yes/' \
            "$CONF" >"$tmp_conf" && cat "$tmp_conf" >"$CONF"
        rm -f "$tmp_conf"
        if grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+yes' "$CONF"; then
            ok "enabled PasswordAuthentication in ${CONF}"
        else
            warn "could not flip PasswordAuthentication in ${CONF}; set it by hand"
        fi
    else
        info "password auth already permitted by ${CONF}; no edit needed"
    fi
elif [[ -n "$DROPIN" && -f "$DROPIN" ]]; then
    # A previous password-auth run left our drop-in behind; with a key in hand
    # the image's own setting should apply again.
    rm -f "$DROPIN"
    ok "removed ${DROPIN} (key login only)"
else
    info "key supplied: leaving password-auth settings untouched"
fi

# 3b. Port, only when explicitly requested and only when it differs.
if [[ $PORT_EXPLICIT -eq 1 ]]; then
    ACTIVE_PORT="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' "$CONF" 2>/dev/null || true)"
    if [[ "$ACTIVE_PORT" == "$PORT" ]]; then
        info "${CONF} already sets Port ${PORT}; no edit needed"
    elif [[ -z "$ACTIVE_PORT" && "$PORT" == "22" ]]; then
        info "port stays at the sshd default of 22"
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
        ' "$CONF" >"$tmp" && cat "$tmp" >"$CONF"
        rm -f "$tmp"
        ok "set Port ${PORT} in ${CONF} (was '${ACTIVE_PORT:-unset}')"
    fi
else
    info "port not requested; effective port ${PORT}"
fi

# =============================================================================
#  4. Optional public key
# =============================================================================
info "[4/7] authorized key"
if [[ -n "$PUBKEY" ]]; then
    mkdir -p "${USER_HOME}/.ssh"
    touch "${USER_HOME}/.ssh/authorized_keys"
    chown -R "${TARGET_USER}:" "${USER_HOME}/.ssh" 2>/dev/null || true
    if grep -qxF "$PUBKEY" "${USER_HOME}/.ssh/authorized_keys" 2>/dev/null; then
        ok "key already present for ${TARGET_USER}"
    else
        printf '%s\n' "$PUBKEY" >>"${USER_HOME}/.ssh/authorized_keys"
        ok "installed key for ${TARGET_USER} (${#PUBKEY} chars, type: $(printf '%s' "$PUBKEY" | awk '{print $1}'))"
    fi
    chmod 700 "${USER_HOME}/.ssh"
    chmod 600 "${USER_HOME}/.ssh/authorized_keys"
    chown "${TARGET_USER}:" "${USER_HOME}/.ssh/authorized_keys" 2>/dev/null || true
    dbg "authorized_keys entries: $(wc -l <"${USER_HOME}/.ssh/authorized_keys" 2>/dev/null || echo 0)"
else
    info "no --pubkey given; password authentication will be used"
fi

# =============================================================================
#  5. Validate before restarting anything
# =============================================================================
info "[5/7] validate config"
mkdir -p /run/sshd 2>/dev/null || true
if ! err="$("$SSHD_BIN" -t 2>&1)"; then
    warn "sshd -t rejected the configuration:"
    if [[ -n "$err" ]]; then printf '%s\n' "$err" | sed 's/^/      /' >&2; fi
    _log_block "sshd -t error" "$err"
    if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
        diag_block "diff against backup (${BACKUP})" "$(diff -u "$BACKUP" "${BACKUP%.bak.*}" 2>&1 | head -40 || true)"
        cp -p "$BACKUP" "${BACKUP%.bak.*}"
        warn "restored ${BACKUP%.bak.*} from the backup; nothing was restarted"
    fi
    if [[ -n "$DROPIN" && -f "$DROPIN" ]]; then
        diag_block "drop-in contents (${DROPIN})" "$(cat "$DROPIN" 2>/dev/null || true)"
        rm -f "$DROPIN"
        warn "removed ${DROPIN}; nothing was restarted"
    fi
    exit 1
fi
ok "sshd -t: configuration OK"
if [[ $DEBUG -eq 1 ]]; then
    capture "sshd -T (effective settings)" bash -c "'$SSHD_BIN' -T 2>/dev/null | head -25" || true
fi

# =============================================================================
#  6. Enable and start
# =============================================================================
info "[6/7] start service"
START_OK=0
systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null \
    || service ssh start 2>/dev/null || service sshd start 2>/dev/null || true
if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
    START_OK=1
    ok "SSH is enabled and running (port ${PORT}, listening: $(listeners || echo none))"
else
    warn "SSH did not start. Collecting evidence:"
    if command -v systemctl >/dev/null 2>&1; then
        diag_block "systemctl status ssh" "$(systemctl status ssh --no-pager -l 2>&1 | head -30 || true)"
        diag_block "journalctl -u ssh (last 30)" "$(journalctl -u ssh --no-pager -n 30 2>&1 || true)"
    else
        diag_block "init system" "$(ps -p 1 -o comm= 2>&1 || true)"
    fi
    diag_block "current listeners" "$( (command -v ss >/dev/null 2>&1 && ss -ltnp 2>/dev/null | head -20) || netstat -ltnp 2>/dev/null | head -20 || true)"
    diag_block "sshd version" "$("$SSHD_BIN" -V 2>&1 | head -3 || true)"
fi

# =============================================================================
#  7. Firewall
# =============================================================================
info "[7/7] firewall"
if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
    dbg "ufw status: $(ufw status 2>/dev/null | head -5 | paste -sd';' - || echo unknown)"
    ok "UFW rule present: allow ${PORT}/tcp ($(ufw status 2>/dev/null | head -1 || echo unknown state))"
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    ok "firewalld rule added: ${PORT}/tcp"
else
    info "no active ufw/firewalld found; nothing to open"
fi

# =============================================================================
#  Summary
# =============================================================================
info "=== summary ==="
say "  sshd:        ${SSHD_BIN}"
say "  service:     $(service_state)"
say "  listening:   $(listeners || echo none)"
say "  login user:  ${TARGET_USER}"
say "  address:     ${VM_IP:-none}   gateway: ${VM_GW:-none}"
say "  firewall:    $(firewall_state)"
conf_summary
say "  transcript:  ${LOG_FILE}"
show_command
say "  [i] Only leave SSH running if your scenario or image policy allows it."
say "  [i] Need help? Paste the transcript:  cat ${LOG_FILE}"
if [[ $START_OK -eq 0 ]]; then
    exit 1
fi
