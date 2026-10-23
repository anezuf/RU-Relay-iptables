# RU Relay — настройка проброса через iptables + UFW

Промежуточный сервер для перенаправления VPN-трафика на зарубежный VPS.

```text
Клиент → RU Relay → EU Server → WARP → Интернет
```

RU Relay не расшифровывает VPN-трафик, а только перенаправляет пакеты через DNAT/SNAT.

> **Требования:** Ubuntu 22.04/24.04, root-доступ, настроенный VPN на EU сервере.

## 0. Установка скриптом

```bash
curl -fL https://raw.githubusercontent.com/anezuf/RU-Relay-iptables/main/install.sh -o install.sh
sudo bash install.sh
```

---

## 1. Подготовка

Установить необходимые пакеты:

```bash
apt update && apt install -y ufw iptables fail2ban
```

Указать свои IP:

```bash
RU_IP=""
EU_IP=""
```

## 2. Включить IP forwarding

```bash
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ru-relay.conf
sysctl --system
```

## 3. Настроить UFW

Разрешить пересылку пакетов:

```bash
sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
```

Разрешить SSH (замени `22`, если используешь другой порт):

```bash
ufw allow 22/tcp
```

> **Важно:** убедись, что SSH разрешён, прежде чем включать UFW. Желательно иметь доступ к консоли VPS.

## 4. Настроить DNAT/SNAT

Правила сохраняются в `/etc/ufw/before.rules` и загружаются вместе с UFW.

Создать резервную копию:

```bash
cp /etc/ufw/before.rules /etc/ufw/before.rules.bak
```

Добавить NAT-правила:

```bash
cat >> /etc/ufw/before.rules << EOF

# RU Relay NAT
*nat
:PREROUTING ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]

-A PREROUTING -d ${RU_IP} -p tcp -m multiport --dports 443,8443,10000:60000 -j DNAT --to-destination ${EU_IP}
-A PREROUTING -d ${RU_IP} -p udp -m multiport --dports 443,8443,10000:60000 -j DNAT --to-destination ${EU_IP}

-A POSTROUTING -d ${EU_IP} -p tcp -m conntrack --ctstate DNAT -j SNAT --to-source ${RU_IP}
-A POSTROUTING -d ${EU_IP} -p udp -m conntrack --ctstate DNAT -j SNAT --to-source ${RU_IP}

COMMIT
EOF
```

> **Порты:** `443`, `8443`, `10000–60000` (TCP/UDP). Оставь только необходимые. Не добавляй второй блок `*nat`, если он уже существует.

## 5. Включить UFW и автозапуск

```bash
LC_ALL=C.UTF-8 ufw --force enable
systemctl enable ufw
```

Проверить:

```bash
ufw status
systemctl is-enabled ufw
grep '^ENABLED=' /etc/ufw/ufw.conf
```

Ожидаемый результат:

```text
Status: active
enabled
ENABLED=yes
```

## 6. Настроить Fail2ban

```bash
cat > /etc/fail2ban/jail.d/sshd.local << 'EOF'
[sshd]
enabled = true
backend = systemd
bantime = 24h
findtime = 10m
maxretry = 5
EOF

systemctl enable --now fail2ban
systemctl restart fail2ban
```

## 7. Проверка

```bash
# IP forwarding
sysctl net.ipv4.ip_forward

# DNAT / SNAT
iptables -t nat -L -n -v

# Пересылка пакетов
iptables -L FORWARD -n -v

# Состояние UFW
ufw status verbose
```

Мониторинг подключений:

```bash
watch -n 1 'iptables -t nat -L -n -v | grep -E "DNAT|SNAT"'
```

Счётчики правил должны расти при новых VPN-подключениях.

---

## Настройка EU сервера (3x-ui)

**VLESS Reality:** в настройках подключения клиента (например, External Proxy) укажи `RU_IP` вместо адреса EU сервера. Порт и параметры Reality не меняй.

**Hysteria2:** замени адрес сервера в ссылке, сохранив SNI сертификата.

```text
hysteria2://PASSWORD@RU_IP:443?sni=your-domain.com#Hy2-RU
```

---

## VPN перестал работать после перезагрузки?

Проверь UFW:

```bash
ufw status
```

Если `inactive`, убедись, что SSH разрешён, затем выполни:

```bash
LC_ALL=C.UTF-8 ufw --force enable
```

Проверь восстановление NAT:

```bash
iptables -t nat -L -n -v
```

**Для постоянной работы обязательно:**

```text
UFW:           active
UFW autostart: enabled
ENABLED:       yes
IP forwarding: 1
DNAT/SNAT:     присутствуют
```

---

> **Безопасность:** не пробрасывай SSH, панель 3x-ui и другие служебные порты. Учитывай, что при разрешённом forwarding транзитный трафик не ограничивается обычными правилами `ufw allow`.
