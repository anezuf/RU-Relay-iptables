# Настройка RU Relay сервера (iptables)

## Схема
```
Клиент → RU сервер (relay) → EU сервер → WARP → Интернет
```

РКН видит только соединение с российским IP. EU сервер и содержимое трафика полностью скрыты — VLESS/Hy2 шифрует всё end-to-end, RU сервер просто пересылает пакеты не расшифровывая их.

---

## Шаг 1 — Обновить систему

Обновляем пакеты перед началом настройки.

```bash
apt update && apt upgrade -y
```

---

## Шаг 2 — Включить форвардинг пакетов

Разрешает ядру Linux пересылать пакеты между интерфейсами. Без этого relay работать не будет.

```bash
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p
```

---

## Шаг 3 — Отключить rp_filter (нужно для UDP)

rp_filter проверяет откуда пришёл пакет и может блокировать форвардинг UDP трафика. Сначала проверь значение:

```bash
sysctl net.ipv4.conf.all.rp_filter
```

Если результат `2` — выполни команды ниже. Если `0` или `1` — пропусти этот шаг.

```bash
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.default.rp_filter=0
echo "net.ipv4.conf.all.rp_filter=0" >> /etc/sysctl.conf
echo "net.ipv4.conf.default.rp_filter=0" >> /etc/sysctl.conf
```

---

## Шаг 4 — Разрешить форвардинг в UFW

По умолчанию UFW блокирует транзитный трафик. Это разрешает пакетам проходить сквозь сервер.

```bash
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
```

---

## Шаг 5 — Открыть порты в UFW

Открываем порты которые будем пробрасывать на EU сервер.

```bash
ufw allow 443/tcp
ufw allow 443/udp
ufw allow 8443/tcp
ufw reload
```

---

## Шаг 6 — Настроить проброс портов через before.rules

Записываем правила iptables в `/etc/ufw/before.rules` — они применяются при каждом запуске UFW и переживают любые перезагрузки.

DNAT перенаправляет входящие пакеты на EU сервер. SNAT подменяет обратный адрес на IP RU сервера — без этого EU сервер не знал бы куда отвечать.

> Замени `EU_IP` и `RU_IP` на свои значения

```bash
cat >> /etc/ufw/before.rules << 'EOF'

*nat
:PREROUTING ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
# Проброс портов
-A PREROUTING -p tcp -m multiport --dports 443,8443,10000:60000 -j DNAT --to-destination EU_IP
-A PREROUTING -p udp -m multiport --dports 443,8443,10000:60000 -j DNAT --to-destination EU_IP
# Маскировка под IP RU сервера
-A POSTROUTING -p tcp -d EU_IP -j SNAT --to-source RU_IP
-A POSTROUTING -p udp -d EU_IP -j SNAT --to-source RU_IP
COMMIT
EOF
```

```bash
ufw reload
```

---

## Шаг 7 — Установить Fail2ban

Защищает SSH от брутфорса — автоматически банит IP после нескольких неудачных попыток входа.

```bash
apt install fail2ban -y

cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 24h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF

systemctl enable --now fail2ban
```

---

## Шаг 8 — Проверка

```bash
# Правила на месте?
iptables -t nat -L -n --line-numbers

# Форвардинг включён?
sysctl net.ipv4.ip_forward

# Мониторинг трафика в реальном времени (пакеты должны расти при использовании VPN)
watch -n 1 'iptables -t nat -L -n -v | grep DNAT'
```

---

## Что нужно отредактировать на EU сервере (3x-ui)

### VLESS
В настройках каждого inbound найди поле **External Proxy** и измени адрес с домена/EU IP на **RU IP**. Порт оставь без изменений. После сохранения скопируй ссылку заново — в ней будет RU IP автоматически.

### Hysteria2
Hysteria2 настраивается вручную через конфиг. Сформируй ссылку — замени только адрес сервера на RU IP, SNI оставь от домена сертификата:

```
hy2://user:password@RU_IP:443?sni=твой_домен#Hy2-RU-Relay
```

---

> **Важно:** панель 3x-ui, SSH и другие служебные порты — **не пробрасывать**.
