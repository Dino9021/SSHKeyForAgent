#!/usr/bin/env bash
# enable-ssh-key-login.sh - run on the REMOTE Linux host with sudo.
# Usage: sudo ./enable-ssh-key-login.sh <user> '<public key line>' [allow-from-cidr]
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run with sudo." >&2; exit 1; fi
if [[ $# -lt 2 ]]; then echo "Usage: sudo $0 <user> '<public key line>' [allow-from-cidr]" >&2; exit 1; fi

user="$1"
pubkey="$(printf '%s' "$2" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
allow="${3:-}"

home="$(getent passwd "$user" | cut -d: -f6 || true)"
if [[ -z "$home" ]]; then echo "No such user: $user" >&2; exit 1; fi
group="$(id -gn "$user")"

if ! [[ "$pubkey" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))\ [A-Za-z0-9+/]+=*(\ [^[:space:]]+)?$ ]]; then
    echo "Not an OpenSSH public key line." >&2; exit 1
fi

# 1. OpenSSH server (install only when missing).
if ! command -v sshd >/dev/null 2>&1 && [[ ! -x /usr/sbin/sshd ]]; then
    if command -v apt-get >/dev/null; then apt-get update -q && apt-get install -y -q openssh-server
    elif command -v dnf >/dev/null; then dnf install -y -q openssh-server
    else echo "Install openssh-server by hand, then re-run." >&2; exit 1; fi
fi
SSHD="$(command -v sshd || echo /usr/sbin/sshd)"

# 2. authorized_keys with the permissions sshd insists on.
install -d -m 700 -o "$user" -g "$group" "$home/.ssh"
auth="$home/.ssh/authorized_keys"
touch "$auth"
if grep -qxF "$pubkey" "$auth"; then
    echo "Key already present in $auth"
else
    printf '%s\n' "$pubkey" >> "$auth"
    echo "Key added to $auth"
fi
chown "$user:$group" "$auth"; chmod 600 "$auth"
command -v restorecon >/dev/null && restorecon -R "$home/.ssh" || true   # SELinux hosts

# 3. Public-key login on (password login is left as it is).
if [[ "$("$SSHD" -T 2>/dev/null | awk '/^pubkeyauthentication/{print $2}')" != "yes" ]]; then
    if [[ -d /etc/ssh/sshd_config.d ]] && grep -qE '^\s*Include\s+/etc/ssh/sshd_config.d' /etc/ssh/sshd_config; then
        echo "PubkeyAuthentication yes" > /etc/ssh/sshd_config.d/10-pubkey.conf
    else
        echo "PubkeyAuthentication is off and there is no sshd_config.d include - set it in /etc/ssh/sshd_config by hand." >&2
    fi
fi
"$SSHD" -t   # refuse to restart on a broken config

# 4. Service (Debian/Ubuntu: ssh; RHEL family: sshd).
if systemctl cat ssh.service >/dev/null 2>&1; then svc=ssh; else svc=sshd; fi
systemctl enable "$svc" >/dev/null 2>&1 || true
systemctl restart "$svc"

# 5. Optional firewall restriction.
if [[ -n "$allow" ]]; then
    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow from "$allow" to any port 22 proto tcp
    elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$allow port port=22 protocol=tcp accept"
        firewall-cmd --reload
    else
        echo "No active ufw/firewalld - allow-from ignored." >&2
    fi
fi

echo
echo "Done. Test from the local machine with: ssh <the short name you gave script 1>"
