#!/usr/bin/env bash
set -Eeuo pipefail

# RU Relay installer for Ubuntu/Debian + UFW (IPv4).
# Run as root on the RU VPS.

if [[ ${EUID} -ne 0 ]]; then echo 'Run as root: sudo bash install.sh' >&2; exit 1; fi
if [[ ! -r /etc/os-release ]]; then echo 'Unsupported OS' >&2; exit 1; fi
. /etc/os-release
if [[ ${ID:-} != ubuntu && ${ID:-} != debian ]]; then echo "Unsupported OS: ${ID:-unknown}" >&2; exit 1; fi
for c in ip awk grep sed date cp mktemp; do command -v "$c" >/dev/null || { echo "Missing: $c" >&2; exit 1; }; done

is_ipv4() {
  local ip=$1 part
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a parts <<< "$ip"
  ((${#parts[@]} == 4)) || return 1
  for part in "${parts[@]}"; do
    [[ $part =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$part <= 255)) || return 1
  done
}

read_ipv4() {
  local prompt=$1 default=${2:-} value
  while true; do
    read -r -p "$prompt${default:+ [$default]}: " value
    value=${value:-$default}
    if is_ipv4 "$value"; then REPLY=$value; return; fi
    echo 'Enter a valid IPv4 address.'
  done
}

read_ports() {
  local raw token lo hi
  while true; do
    read -r -p 'Ports (TCP+UDP), comma-separated [443,8443]: ' raw
    raw=${raw:-443,8443}
    raw=${raw//[[:space:]]/}
    [[ $raw =~ ^[0-9,:-]+$ ]] || { echo 'Invalid characters.'; continue; }
    local -a tokens
    IFS=, read -r -a tokens <<< "$raw"
    ((${#tokens[@]} >= 1 && ${#tokens[@]} <= 15)) || { echo '1 to 15 entries.'; continue; }
    local ok=1
    for token in "${tokens[@]}"; do
      if [[ "$token" =~ ^([0-9]{1,5}):([0-9]{1,5})$ || "$token" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
        lo=${BASH_REMATCH[1]}; hi=${BASH_REMATCH[2]}
        if ((10#$lo < 1 || 10#$hi > 65535 || 10#$lo > 10#$hi)); then ok=0; break; fi
      elif [[ "$token" =~ ^[0-9]{1,5}$ ]]; then
        if ((10#$token < 1 || 10#$token > 65535)); then ok=0; break; fi
      else ok=0; break
      fi
    done
    ((ok)) || { echo 'Invalid ports. Example: 443,8443,10000:60000'; continue; }
    PORTS=$raw; return
  done
}

main() {
  echo '=== RU Relay installer (UFW + iptables) ==='
  local detected_ip ssh_default ssh_port token
  detected_ip=$(ip -4 -o addr show scope global | awk '$4 !~ /^172\./ {split($4,a,"/"); print a[1]; exit}')
  read_ipv4 'RU public IPv4' "$detected_ip"; RU_IP=$REPLY
  read_ipv4 'EU public IPv4'; EU_IP=$REPLY
  if [[ $RU_IP == "$EU_IP" ]]; then echo 'RU and EU addresses must differ.' >&2; exit 1; fi
  read_ports
  ssh_default=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)
  ssh_default=${ssh_default:-22}
  while true; do
    read -r -p "SSH port [$ssh_default]: " ssh_port
    ssh_port=${ssh_port:-$ssh_default}
    if [[ $ssh_port =~ ^[0-9]{1,5}$ ]] && ((10#$ssh_port >= 1 && 10#$ssh_port <= 65535)); then break; fi
    echo 'Invalid SSH port.'
  done
  echo
  echo "RU:    $RU_IP"
  echo "EU:    $EU_IP"
  echo "Ports: $PORTS (TCP/UDP)"
  echo "SSH:   $ssh_port/tcp"
  echo 'The UFW routed policy will be ACCEPT. This is a broad forwarding policy.'
  echo 'Do not use on a host with existing custom NAT/firewall rules without review.'
  read -r -p 'Apply configuration? Type YES: ' confirm
  [[ $confirm == YES ]] || { echo 'Cancelled.'; exit 0; }

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ufw iptables

  local backup_dir stamp file
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  backup_dir="/root/ru-relay-backup-$stamp"
  mkdir -p "$backup_dir"
  for file in /etc/ufw/before.rules /etc/default/ufw /etc/ufw/ufw.conf /etc/sysctl.d/99-ru-relay.conf; do
    if [[ -e $file ]]; then mkdir -p "$backup_dir$(dirname "$file")"; cp -a "$file" "$backup_dir$file"; fi
  done
  ufw status verbose > "$backup_dir/ufw-status-before.txt" || true
  iptables-save > "$backup_dir/iptables-before.v4"

  # Avoid inserting a second *nat section or clobbering another NAT setup.
  if grep -Eq '^\*nat([[:space:]]|$)|^# BEGIN RU-RELAY' /etc/ufw/before.rules; then
    echo 'Existing NAT configuration in /etc/ufw/before.rules: manual review required.' >&2
    echo "Backup: $backup_dir" >&2
    exit 1
  fi
  cat > /etc/sysctl.d/99-ru-relay.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
  ufw allow "$ssh_port/tcp"

  # Use exact destination to avoid redirecting container or other public IPs.
  # iptables-restore supports comma-separated ports and colon ranges.
  cat >> /etc/ufw/before.rules <<EOF

# BEGIN RU-RELAY
*nat
:PREROUTING ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A PREROUTING -d $RU_IP -p tcp -m multiport --dports $PORTS -j DNAT --to-destination $EU_IP
-A PREROUTING -d $RU_IP -p udp -m multiport --dports $PORTS -j DNAT --to-destination $EU_IP
-A POSTROUTING -d $EU_IP -p tcp -m conntrack --ctstate DNAT -j SNAT --to-source $RU_IP
-A POSTROUTING -d $EU_IP -p udp -m conntrack --ctstate DNAT -j SNAT --to-source $RU_IP
COMMIT
# END RU-RELAY
EOF
  # Validate UFW-managed rules; do not apply via iptables-restore directly.
  if ! iptables-restore --test < /etc/ufw/before.rules; then
    echo "ERROR: NAT validation failed. Restore /etc/ufw/before.rules from $backup_dir" >&2
    exit 1
  fi
  LC_ALL=C.UTF-8 ufw --force enable
  systemctl enable ufw >/dev/null
  echo
  echo '=== Status ==='
  ufw status verbose
  echo "UFW boot setting: $(systemctl is-enabled ufw)"
  grep '^ENABLED=' /etc/ufw/ufw.conf
  sysctl net.ipv4.ip_forward
  iptables -t nat -S | grep -E '(DNAT|SNAT)' || true
  echo "Backup: $backup_dir"
  echo 'Connect to VPN via the RU address and check counters.'
  echo 'CAUTION: No reboot has been performed; verify persistence later via console access.'
}
main "$@"
