#!/usr/bin/env bash
# ANEZUF RU Relay — UFW + iptables installer/uninstaller (IPv4)
# Version: 1.1.0
set -Eeuo pipefail
umask 077

STATE_DIR='/var/lib/anezuf-ru-relay'
STATE_FILE="$STATE_DIR/state.env"
BACKUP_DIR="$STATE_DIR/backup"
BEFORE_RULES='/etc/ufw/before.rules'
SYSCTL_FILE='/etc/sysctl.d/99-ru-relay.conf'
UFW_DEFAULT='/etc/default/ufw'
START='# BEGIN RU-RELAY'
END='# END RU-RELAY'

say() { printf '\n%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

banner() {
  cat <<'EOF'
     _    _   _ _____ _____ _   _ _____
    / \  | \ | | ____|__  /| | | |  ___|
   / _ \ |  \| |  _|   / / | | | | |_ 
  / ___ \| |\  | |___ / /_ | |_| |  _|
 /_/   \_\_| \_|_____/____| \___/|_|

              R U   R E L A Y
EOF
}

usage() {
  cat <<'EOF'
Usage:
  bash install.sh                     Install RU Relay
  bash install.sh --uninstall         Remove only ANEZUF RU Relay settings
  bash install.sh --status            Show RU Relay status
  bash install.sh --help              Show this help

Run as root via SSH. Uninstall keeps installed packages and SSH firewall access.
EOF
}

need_root() { (( EUID == 0 )) || err 'Запусти от root: sudo bash install.sh'; }
require_os() {
  [[ -f /etc/os-release ]] || err 'Не найдена /etc/os-release'
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == ubuntu || "${ID:-}" == debian ]] || err 'Поддерживаются Ubuntu и Debian'
}
need_tty() {
  [[ -r /dev/tty && -w /dev/tty ]] || err 'Нужна интерактивная SSH-сессия'
  exec 3<>/dev/tty || err 'Невозможно открыть /dev/tty'
}
ask() {
  local value
  printf '%s' "$1" >&3
  IFS= read -r -u 3 value || err 'Ввод прерван'
  REPLY=$value
}
valid_ipv4() {
  local ip=$1 part
  local -a octets
  [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a octets <<<"$ip"
  ((${#octets[@]} == 4)) || return 1
  for part in "${octets[@]}"; do
    [[ $part =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$part <= 255 )) || return 1
  done
}
read_ip() {
  local label=$1 default=${2:-} value
  while :; do
    ask "$label${default:+ [$default]}: "
    value=${REPLY:-$default}
    if valid_ipv4 "$value"; then REPLY=$value; return; fi
    say 'Укажи корректный IPv4.'
  done
}
read_ports() {
  local raw token low high valid
  local -a parts
  while :; do
    ask 'Порты TCP и UDP [443,8443]: '
    raw=${REPLY:-443,8443}
    raw=${raw//[[:space:]]/}
    [[ $raw =~ ^[0-9,:-]+$ ]] || { say 'Недопустимые символы.'; continue; }
    IFS=, read -r -a parts <<<"$raw"
    ((${#parts[@]} >= 1 && ${#parts[@]} <= 15)) || { say 'От 1 до 15 элементов.'; continue; }
    valid=1
    for token in "${parts[@]}"; do
      if [[ $token =~ ^([0-9]{1,5})[:-]([0-9]{1,5})$ ]]; then
        low=${BASH_REMATCH[1]}; high=${BASH_REMATCH[2]}
        if (( 10#$low < 1 || 10#$high > 65535 || 10#$low > 10#$high )); then valid=0; break; fi
      elif [[ $token =~ ^[0-9]{1,5}$ ]]; then
        if (( 10#$token < 1 || 10#$token > 65535 )); then valid=0; break; fi
      else valid=0; break
      fi
    done
    ((valid)) || { say 'Некорректные порты. Пример: 443,8443,10000:60000'; continue; }
    PORTS=$raw
    return
  done
}

# Remove only our marked NAT section (never other chains/rules).
# If the marker pair is corrupt, fail rather than remove a guessed range.
remove_marked_nat() {
  local file=$1 output=$2
  awk '
    /^# BEGIN RU-RELAY[[:space:]]*$/ { if (inside || ended) exit 42; inside=1; started=1; next }
    /^# END RU-RELAY[[:space:]]*$/ { if (!inside) exit 42; inside=0; ended=1; next }
    !inside { print }
    END { if ((started && !ended) || inside) exit 42 }
  ' "$file" > "$output" || return 1
}

read_state() {
  if [[ -f $STATE_FILE ]]; then
    # The file is created by this installer and readable only by root.
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    [[ ${MANAGED_BY:-} == 'ANEZUF_RU_RELAY' ]] || err 'Неизвестный формат файла состояния; удаление остановлено'
    return 0
  fi
  return 1
}

print_status() {
  banner
  say 'Статус RU Relay'
  if [[ -f $STATE_FILE ]]; then
    read_state
    printf 'RU IP: %s\nEU IP: %s\nPorts: %s\n' "${RU_IP:-unknown}" "${EU_IP:-unknown}" "${PORTS:-unknown}"
  else
    echo 'State: не найден (возможна старая установка)'
  fi
  if [[ -f $BEFORE_RULES ]] && grep -Fqx "$START" "$BEFORE_RULES"; then
    echo 'NAT block: present'
  else
    echo 'NAT block: absent'
  fi
  command -v ufw >/dev/null 2>&1 && ufw status | head -n 1 || true
  sysctl net.ipv4.ip_forward 2>/dev/null || true
}

uninstall_relay() {
  need_tty
  banner
  local known=0 marker=0 work_file backup_file current_forward current_policy
  if read_state; then known=1; fi
  if [[ -f $BEFORE_RULES ]] && grep -Fqx "$START" "$BEFORE_RULES"; then marker=1; fi
  if (( ! known && ! marker )); then
    say 'Настроек ANEZUF RU Relay не найдено. Удалять нечего.'
    return 0
  fi
  say 'Удаление ANEZUF RU Relay'
  echo 'Будут удалены только принадлежащие установщику правила NAT и сохранённые параметры forwarding.'
  echo 'SSH, Docker, прочие правила UFW/iptables и системные пакеты сохраняются.'
  if (( ! known )); then
    echo 'ВНИМАНИЕ: состояние старой установки отсутствует — будут удалены только правила с маркером RU-RELAY.'
  fi
  ask 'Для подтверждения введи DELETE: '
  [[ $REPLY == DELETE ]] || { echo 'Отменено.'; return 0; }

  if (( marker )); then
    backup_file="/root/anezuf-ru-relay-before-uninstall-$(date -u +%Y%m%dT%H%M%SZ).rules"
    cp -a "$BEFORE_RULES" "$backup_file"
    work_file=$(mktemp /etc/ufw/.anezuf-before-rules.XXXXXX)
    if ! remove_marked_nat "$BEFORE_RULES" "$work_file"; then
      rm -f "$work_file"
      err 'Повреждены маркеры RU-RELAY; правила не менялись'
    fi
    if command -v iptables-restore >/dev/null 2>&1; then
      if ! iptables-restore --test < "$work_file"; then
        rm -f "$work_file"
        err 'NAT после удаления не проходит проверку; правила не менялись'
      fi
    fi
    cat "$work_file" > "$BEFORE_RULES"
    rm -f "$work_file"
    echo 'PASS: Удалён только NAT-блок RU-RELAY'
  fi

  # Legacy installs had a dedicated forwarding file but no state.env.
  # Remove it only if it contains nothing except the expected setting/comments.
  if (( ! known )) && [[ -f $SYSCTL_FILE ]]; then
    if awk '
      /^[[:space:]]*$/ { next }
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1[[:space:]]*$/ { found=1; next }
      { bad=1 }
      END { exit (found && !bad) ? 0 : 1 }
    ' "$SYSCTL_FILE"; then
      rm -f "$SYSCTL_FILE"
      echo 'PASS: Удалён старый файл /etc/sysctl.d/99-ru-relay.conf'
      echo 'INFO: Исходная политика UFW неизвестна; она оставлена без изменений.'
    fi
  fi

  if ((known)); then
    if [[ -f $SYSCTL_FILE ]] && grep -Fxq 'net.ipv4.ip_forward=1' "$SYSCTL_FILE"; then
      if [[ ${SYSCTL_FILE_EXISTED:-0} == 1 && -f $BACKUP_DIR/sysctl-original ]]; then
        cp -a "$BACKUP_DIR/sysctl-original" "$SYSCTL_FILE"
      else
        rm -f "$SYSCTL_FILE"
      fi
      echo 'PASS: Восстановлен файл IP forwarding'
    fi

    if [[ -f $UFW_DEFAULT ]] && [[ -n ${UFW_POLICY_OLD:-} ]]; then
      current_policy=$(sed -n 's/^DEFAULT_FORWARD_POLICY=//p' "$UFW_DEFAULT" | head -n1)
      if [[ $current_policy == '"ACCEPT"' ]]; then
        sed -i "s/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY=${UFW_POLICY_OLD//\//\/}/" "$UFW_DEFAULT"
        echo 'PASS: Восстановлена политика UFW forwarding'
      else
        echo 'INFO: Политика UFW уже изменена вручную; оставлена без изменений'
      fi
    fi
  fi

  # First apply restored UFW config to remove currently loaded NAT rules.
  if command -v ufw >/dev/null 2>&1 && [[ $(ufw status 2>/dev/null | head -n1) == 'Status: active' ]]; then
    if ufw reload; then echo 'PASS: UFW перезагружен'; else
      echo 'WARNING: Не удалось перезагрузить UFW; проверь активные NAT-правила' >&2
      return 1
    fi
  fi

  if ((known)); then
    if [[ ${IP_FORWARD_OLD:-1} == 0 ]] && [[ $(sysctl -n net.ipv4.ip_forward) == 1 ]]; then
      # Leave enabled if another system configuration also requests it.
      if ! grep -RhsE '^\s*net\.ipv4\.ip_forward\s*=\s*1' /etc/sysctl.conf /etc/sysctl.d /usr/lib/sysctl.d /run/sysctl.d 2>/dev/null | grep -q .; then
        sysctl -w net.ipv4.ip_forward=0 >/dev/null
        echo 'PASS: Восстановлено исходное значение IP forwarding'
      else
        echo 'INFO: IP forwarding сохранён (он используется другой конфигурацией)'
      fi
    fi
    rm -rf -- "$STATE_DIR"
  fi
  echo
  echo 'УДАЛЕНИЕ RU RELAY ЗАВЕРШЕНО'
  echo 'UFW и SSH-доступ оставлены включёнными для безопасности.'
  echo 'Неиспользуемый SSH allow-rule, созданный при установке, оставлен во избежание потери доступа.'
}

install_relay() {
  need_tty
  banner
  say 'Установка ANEZUF RU Relay'
  [[ ! -f $STATE_FILE ]] || err 'Обнаружена текущая или прерванная установка. Сначала: bash install.sh --uninstall'
  if [[ -f $BEFORE_RULES ]] && grep -Eq '^# BEGIN RU-RELAY[[:space:]]*$|^\*nat([[:space:]]|$)' "$BEFORE_RULES"; then
    err 'В before.rules уже есть NAT или RU-RELAY. Для старой установки — сначала --uninstall. Чужие NAT-правила не изменяем.'
  fi
  [[ ! -e $SYSCTL_FILE ]] || err "Файл $SYSCTL_FILE уже существует. Во избежание перезаписи проверь его вручную."
  local detected ssh_default ssh_port old_ip_forward old_ufw_policy ufw_was_active
  detected=$(ip -4 -o addr show scope global | awk '$4 !~ /^172\./ {split($4,a,"/"); print a[1]; exit}')
  read_ip 'Публичный IPv4 RU сервера' "$detected"; RU_IP=$REPLY
  read_ip 'Публичный IPv4 EU сервера'; EU_IP=$REPLY
  [[ $RU_IP != "$EU_IP" ]] || err 'RU IP и EU IP должны различаться'
  read_ports
  ssh_default=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)
  ssh_default=${ssh_default:-22}
  while :; do
    ask "Порт SSH [$ssh_default]: "
    ssh_port=${REPLY:-$ssh_default}
    if [[ $ssh_port =~ ^[0-9]{1,5}$ ]] && (( 10#$ssh_port >= 1 && 10#$ssh_port <= 65535 )); then break; fi
    echo 'Неверный SSH-порт.'
  done

  echo
  printf 'RU: %s\nEU: %s\nПорты: %s (TCP/UDP)\nSSH: %s/tcp\n' "$RU_IP" "$EU_IP" "$PORTS" "$ssh_port"
  echo 'ВНИМАНИЕ: Forward policy UFW будет ACCEPT. Используй выделенный RU VPS.'
  echo 'Сохрани доступ к консоли хостера на случай проблем с UFW.'
  ask 'Для подтверждения введи YES: '
  [[ $REPLY == YES ]] || { echo 'Отменено.'; return 0; }

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ufw iptables
  for cmd in ufw iptables-restore iptables-save sysctl sed awk mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || err "Отсутствует команда $cmd"
  done
  [[ -f $BEFORE_RULES && -f $UFW_DEFAULT ]] || err 'UFW не создал ожидаемые файлы настроек'
  [[ ! -e $SYSCTL_FILE ]] || err 'Файл sysctl появился во время установки; изменения не внесены'
  if grep -Eq '^# BEGIN RU-RELAY[[:space:]]*$|^\*nat([[:space:]]|$)' "$BEFORE_RULES"; then
    err 'В before.rules обнаружены NAT-правила; установка остановлена'
  fi

  old_ip_forward=$(sysctl -n net.ipv4.ip_forward)
  old_ufw_policy=$(sed -n 's/^DEFAULT_FORWARD_POLICY=//p' "$UFW_DEFAULT" | head -n1)
  [[ -n $old_ufw_policy ]] || err 'Не удалось определить исходную политику UFW'
  ufw_was_active=0
  [[ $(ufw status 2>/dev/null | head -n1) != 'Status: active' ]] || ufw_was_active=1

  mkdir -p "$BACKUP_DIR"
  cp -a "$BEFORE_RULES" "$BACKUP_DIR/before.rules"
  cp -a "$UFW_DEFAULT" "$BACKUP_DIR/default-ufw"
  # Install is refused if the sysctl file already exists; metadata is explicit nonetheless.
  cat > "$STATE_FILE" <<EOF
MANAGED_BY=ANEZUF_RU_RELAY
RU_IP=$RU_IP
EU_IP=$EU_IP
PORTS=$PORTS
SSH_PORT=$ssh_port
IP_FORWARD_OLD=$old_ip_forward
UFW_WAS_ACTIVE=$ufw_was_active
UFW_POLICY_OLD=$(printf '%q' "$old_ufw_policy")
SYSCTL_FILE_EXISTED=0
EOF
  chmod 600 "$STATE_FILE"

  cat > "$SYSCTL_FILE" <<'EOF'
# ANEZUF RU Relay — created by install.sh
net.ipv4.ip_forward=1
EOF
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' "$UFW_DEFAULT"
  # Keep SSH reachable before enabling UFW (including custom SSH ports).
  ufw allow "$ssh_port/tcp"

  cat >> "$BEFORE_RULES" <<EOF
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
  if ! iptables-restore --test < "$BEFORE_RULES"; then
    err 'NAT не прошёл проверку. Исправление: bash install.sh --uninstall'
  fi
  LC_ALL=C.UTF-8 ufw --force enable
  systemctl enable ufw >/dev/null
  ufw reload >/dev/null
  # Check that UFW applied both rules, not just accepted their syntax.
  iptables -t nat -S | grep -F -- "--to-destination $EU_IP" >/dev/null || err 'DNAT не загружен после включения UFW'
  iptables -t nat -S | grep -F -- "--to-source $RU_IP" >/dev/null || err 'SNAT не загружен после включения UFW'
  [[ $(sysctl -n net.ipv4.ip_forward) == 1 ]] || err 'IP forwarding не включился'

  if [[ -t 1 && -n ${TERM:-} && ${TERM:-} != dumb ]]; then clear || true; fi
  banner
  printf '\n  УСТАНОВКА RU RELAY ЗАВЕРШЕНА\n  ────────────────────────────────────\n'
  printf '  RU IP:     %s\n  EU IP:     %s\n  Порты:     %s (TCP/UDP)\n  SSH:       %s/tcp\n' "$RU_IP" "$EU_IP" "$PORTS" "$ssh_port"
  printf '  Forwarding: включён\n  UFW:        активен\n  ────────────────────────────────────\n'
  echo '  Клиентский REALITY: RU_IP:443 (если включён проброс 443)'
  echo '  Удаление: bash install.sh --uninstall'
  echo
}

main() {
  need_root
  require_os
  case ${1:-} in
    '') install_relay ;;
    --uninstall) [[ $# == 1 ]] || err 'Неизвестные аргументы удаления'; uninstall_relay ;;
    --status) [[ $# == 1 ]] || err 'Неизвестные аргументы'; print_status ;;
    --help|-h) usage ;;
    *) usage; err "Неизвестный параметр: $1" ;;
  esac
}

main "$@"
