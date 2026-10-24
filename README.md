# ANEZUF — RU Relay

Проброс VLESS REALITY и других VPN-подключений через российский VPS на EU-сервер с помощью **iptables + UFW**.

`Клиент → RU Relay → EU VPS → Интернет / WARP`

RU Relay не расшифровывает VLESS-трафик: он перенаправляет пакеты через DNAT/SNAT.

## 1. Подготовка RU-сервера

Ubuntu / Debian, доступ `root` по SSH. Желательно использовать выделенный VPS без других NAT-правил.

```bash
apt update && apt upgrade -y && apt install -y curl
```

## 2. Установка

```bash
curl -fsSL https://raw.githubusercontent.com/anezuf/RU-Relay-iptables/main/install.sh -o install.sh
bash install.sh
```

Укажи **RU IP**, **EU IP**, порты для проброса и SSH-порт. Подтверди установку словом `YES`.

После успешной настройки появится итоговый экран **ANEZUF** с адресами и портами. По умолчанию пробрасываются TCP/UDP `443,8443`. Диапазоны можно добавить при установке, например `443,8443,10000:60000`.

## 3. Полное удаление настроек RU Relay

```bash
curl -fsSL https://raw.githubusercontent.com/anezuf/RU-Relay-iptables/main/install.sh -o install.sh
bash install.sh --uninstall
```

Подтверди удаление словом `DELETE`. Команда удаляет помеченный NAT-блок, восстанавливает сохранённые настройки пересылки и применяет UFW. Поддерживается удаление после прерванной установки.

**Безопасность:** SSH-разрешение, UFW, Docker, другие правила и общие системные пакеты намеренно сохраняются. Для установки старой версии без файла состояния удаляются помеченные NAT-правила и однозначно принадлежащий ей файл `99-ru-relay.conf`; исходная политика UFW без метаданных не угадывается.

## 4. Управление

**Проверить состояние:**

```bash
bash install.sh --status
```

**Обновить локальный скрипт с GitHub:**

```bash
curl -fsSL https://raw.githubusercontent.com/anezuf/RU-Relay-iptables/main/install.sh -o install.sh
```

---

## Как устроено подключение

| Компонент | Значение |
|---|---|
| Клиентский адрес | `RU_IP:443` |
| RU Relay | DNAT/SNAT, UFW, IPv4 forwarding |
| EU Nginx | Публичный порт `443` |
| EU Xray REALITY | Внутренний порт `127.0.0.1:8443` |
| REALITY Flow | `xtls-rprx-vision` |

На EU-сервере с [ANEZUF VLESS REALITY](https://github.com/anezuf/VLESS-REALITY) укажи RU IP при установке. Используй **внешний порт `443`** в клиентской ссылке; `8443` — внутренний порт Xray.

> **Важно:** меняя маршрутизацию или UFW по SSH, сохраняй доступ к консоли хостера. Скрипт не предназначен для серверов с существующей сложной NAT-конфигурацией.
