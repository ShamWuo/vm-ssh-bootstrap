# vm-ssh-bootstrap

One file that turns a fresh Linux VM into an SSH server.

Fresh VMs boot to a console with no remote access, so every task starts with
pasting commands through a hypervisor window. This script does the whole setup in
one run and then prints the exact `ssh` command to use from your laptop.

- **One file, no dependencies** — nothing else to copy into the guest.
- **Idempotent** — safe to run twice, safe to re-run after a reboot.
- **Guarded** — backs up `sshd_config` and refuses to restart a config that
  `sshd -t` rejects.
- **Never disables SSH** — it only turns the service on.

Works on Ubuntu/Debian (apt) and RHEL/Fedora (dnf/yum) with systemd.

## Quick start

In the VM, at the console:

```bash
curl -fsSL https://raw.githubusercontent.com/ShamWuo/vm-ssh-bootstrap/main/vm-ssh-bootstrap.sh | sudo bash
```

With options:

```bash
# non-default port (scenario mandates it)
curl -fsSL https://raw.githubusercontent.com/ShamWuo/vm-ssh-bootstrap/main/vm-ssh-bootstrap.sh \
  | sudo bash -s -- --port 2222

# key-only login, no password auth
curl -fsSL https://raw.githubusercontent.com/ShamWuo/vm-ssh-bootstrap/main/vm-ssh-bootstrap.sh \
  | sudo bash -s -- --pubkey "$(cat ~/.ssh/id_ed25519.pub)"
```

No internet in the guest? Download it and paste it in:

```bash
# on your laptop
curl -fsSLO https://raw.githubusercontent.com/ShamWuo/vm-ssh-bootstrap/main/vm-ssh-bootstrap.sh

# in the VM console: create the file, paste, Ctrl-D
cat > vm-ssh-bootstrap.sh
sudo bash vm-ssh-bootstrap.sh
```

## Options

| Option | Meaning |
| --- | --- |
| `--port`, `-p N` | Listen on port `N` (validated, 1-65535). Writes the port into `sshd_config`, replacing any existing `Port` line. |
| `--pubkey`, `-k K` | Install public key `K` for the login user and leave password auth at the image's default. |
| `--status` | Read-only report: sshd path, service state, listening socket, login user, address. No root needed. |
| `--help`, `-h` | Usage. |

## What it does

1. Installs `openssh-server` if it isn't there (`apt-get`, `dnf`, or `yum`).
2. Generates any missing host keys with `ssh-keygen -A`.
3. Enables `PasswordAuthentication yes` — in a `sshd_config.d` drop-in when the
   main config includes that directory (so it beats a `50-cloud-init.conf`
   default), otherwise by editing `sshd_config` in place.
4. Installs your public key, if you passed one.
5. Runs `sshd -t`. If the config is rejected, it restores the backup and exits
   non-zero **without restarting anything**.
6. Enables and starts the service, and opens the port in UFW or firewalld.
7. Prints the `ssh` / `ssh-copy-id` / `scp` lines for your client machine.

## Reaching the VM from another machine

This is the part the script cannot do for you: it configures the guest, not the
hypervisor or the host firewall. The VM's network mode decides who can connect.

| VM network mode | Who can SSH in |
| --- | --- |
| **NAT** (VMware default, VirtualBox default) | Only the machine running the hypervisor. The printed `192.168.x.x` is not routable from elsewhere. |
| **Host-only** | Only the machine running the hypervisor. |
| **Bridged** | Any machine on the same LAN — this is what you want for a teammate or a second computer. |
| Different network entirely | Nothing here helps: use a tailnet/VPN or forward a port on the router in front. |

**VMware Workstation on Windows — bridged:** VM Settings → Network Adapter →
Bridged. Re-run `--status` to get the new LAN address. Windows Defender Firewall
does not sit in the path for bridged traffic, but networks with client isolation
(guest Wi-Fi, some corporate VLANs) will still block client-to-client.

**VMware Workstation on Windows — keep NAT, forward a port:** note the guest IP
inside the VM (`ip -4 addr`; make it static or the forward breaks on reboot),
then on Windows open **Edit → Virtual Network Editor → Change Settings** (needs
an administrator) → **VMnet8** → **NAT Settings… → Add…** with host port `2222`,
type `TCP`, the guest IP, and VM port `22`. From the other computer:

```bash
ssh -p 2222 <user>@<windows-host-lan-ip>
```

Port forwarding lives only in NAT mode and only in Workstation Pro, not Player.

**Verifying:** a timeout means networking, not sshd.

```bash
nc -vz <vm-ip> 22        # or: nc -vz <host-ip> 2222 for a port forward
```

`Connection refused` on a reachable address means sshd isn't running or is on a
different port. A connection that reaches auth and fails means no password is
set (`sudo passwd <user>`) or the account may not log in (`PermitRootLogin no`).

## Safety notes

- Edited files are backed up first as `<file>.bak.<epoch>` and restored if
  validation fails.
- The script never edits anything outside `/etc/ssh`, the login user's
  `~/.ssh`, and the UFW/firewalld rules for the SSH port.
- It does not create users, set passwords, or change `PermitRootLogin`. If the
  only candidate account is root it prints a warning, because most cloud and
  competition images ship `PermitRootLogin no`.
- If the policy of your image or scenario says SSH must be off, this is the
  wrong tool: leaving a remote way in can be worse than removing it.

## Testing

CI on every push runs `bash -n`, `shellcheck -S warning`, and a small CLI
contract check (`--help` exits 0; bad `--port` values and unknown flags exit
non-zero). Locally:

```bash
bash -n vm-ssh-bootstrap.sh
shellcheck vm-ssh-bootstrap.sh
```

## License

MIT — see [LICENSE](LICENSE).

This script is also part of a larger private CyberPatriot toolkit; this
repository is the standalone distributable of the same file.
