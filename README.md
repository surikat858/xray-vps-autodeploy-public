# Xray VPS Autodeploy

Развёртывание **нового VPS** на **Ubuntu 24.04 LTS (x86_64)** с **3X-UI v3.11.0**, Xray-core, **VLESS + WebSocket + TLS** и сертификатом Let's Encrypt. Репозиторий содержит только общие установочные скрипты и примеры; **никаких реальных паролей, ключей, IP, доменов и клиентских UUID**.

> **Осторожно:** сценарий предназначен только для **чистой установки**. Не запускайте `install.sh` на VPS с действующей 3X-UI/VPN: установщик не рассчитан на миграцию и откажется при существующей базе. Полный end-to-end запуск одной командой на новом VPS не подтверждён; сначала протестируйте на временном сервере.

## Что устанавливается

- 3X-UI версии `v3.11.0` из официального релиза.
- Xray-core: последний стабильный релиз на момент установки (`XRAY_VERSION=latest`) или указанная версия.
- VLESS inbound на TCP 443, WebSocket path из конфигурации, TLS (`http/1.1`).
- Let's Encrypt (Certbot standalone HTTP-01) и штатное продление Certbot.
- Панель управления **только на 127.0.0.1** с доступом через SSH-туннель.
- Локальные резервные копии SQLite и сертификатов; таймер локальных бэкапов.
- Ограничение доступа извне к порту подписок 2096 (IPv4 и IPv6).
- По умолчанию **не** меняет SSH-аутентификацию и **не** включает общий DROP firewall, чтобы не заблокировать SSH.

Проект **не** реализует автоматическое переключение VPS, балансировку, перенос пользователей между узлами или резервное копирование в облако.

## Требования

- Чистая Ubuntu 24.04 LTS x86_64, root/sudo, желательно не менее 2 ГБ RAM и 20 ГБ диска.
- Публичный IPv4, DNS-имя вида `vpn-example.duckdns.org`, указывающее на сервер.
- Открытые входящие TCP **80** (для выпуска/продления LE) и TCP **443** (VPN), включая настройки firewall провайдера.
- Рабочий SSH-доступ. Держите **вторую SSH-сессию** открытой при обновлении ОС и настройке.
- Email для Let's Encrypt; настроенный DuckDNS-домен. Токен DuckDNS необязателен, если DNS уже выставлен вручную.

## Быстрая установка

**1. В самом начале развертывания обновите Ubuntu:**

```bash
sudo apt update && sudo apt upgrade -y
```

Если обновились ядро или критичные пакеты, проверьте необходимость перезагрузки:

```bash
if [ -f /var/run/reboot-required ]; then
  echo "Требуется перезагрузка ОС перед продолжением."
fi
```

При необходимости безопасно перезагрузите VPS и повторно подключитесь по SSH **до установки VPN**. Установщик выполняет `apt-get update` / `apt-get upgrade -y` повторно — это сделано намеренно, если начальный шаг был пропущен.

**2. Подготовьте git и скачайте проект:**

```bash
sudo apt install -y git
git clone https://github.com/surikat858/xray-vps-autodeploy-public.git
cd xray-vps-autodeploy-public
```

**3. Создайте локальную конфигурацию:**

```bash
cp config.example.env config.env
chmod 600 config.env
nano config.env
```

Пример (замените фиктивные значения):

```dotenv
DOMAIN=vpn-example.duckdns.org
LE_EMAIL=admin@example.com
DUCKDNS_TOKEN=
SSH_PORT=22
VPN_PORT=443
WS_PATH=/vpn-ws-2026
CLIENT_NAME=phone01
XUI_VERSION=v3.11.0
XRAY_VERSION=latest
STRICT_FIREWALL=no
```

**4. Установите:**

```bash
sudo bash install.sh
```

Процесс: проверка ОС, прав, ресурсов и свободных портов → **apt update/upgrade** → зависимости → проверка IP/DNS → сертификат LE → 3X-UI → панель на loopback → VLESS inbound → Xray → безопасные firewall-правила → проверка и локальный бэкап.

`DUCKDNS_TOKEN`, если указан, позволяет установщику изменить A-запись **указанного** домена через DuckDNS API. Если переключение DNS недопустимо, оставьте токен пустым и заранее установите адрес вручную.

## Доступ к 3X-UI из Windows

Панель **не** открывается через публичный IP. Установщик генерирует собственный URL-путь и учётные данные. Посмотреть локально на VPS:

```bash
sudo bash scripts/panel_access.sh --show-credentials
```

Используйте напечатанную команду в PowerShell на Windows, примерно:

```powershell
ssh -N -o ExitOnForwardFailure=yes -L 8443:127.0.0.1:48013 root@YOUR_VPS_IP
```

Затем откройте в браузере адрес, выведенный скриптом, вида `http://127.0.0.1:8443/YOUR_SECRET_BASE_PATH/`. Порт панели `48013` — **пример**, фактический порт и путь отличаются. Не публикуйте скриншоты, пароль или `/etc/x-ui/install-result.env`. Если порт 8443 на ПК занят — используйте иной локальный порт в туннеле и URL.



### Проверка версий компонентов и точного адреса панели

На VPS из каталога репозитория выполнить **только диагностические команды**:

```bash
echo '=== Ubuntu / kernel ==='
. /etc/os-release; echo "$PRETTY_NAME"
uname -r

echo '=== 3X-UI ==='
/usr/local/x-ui/x-ui version

echo '=== Xray-core ==='
/usr/local/x-ui/bin/xray-linux-amd64 version | head -n 1

echo '=== Основные пакеты ==='
dpkg-query -W -f='\${binary:Package}: \${Version}\n' \
  certbot openssl curl git python3 iptables iptables-persistent 2>/dev/null || true

echo '=== Состояние и версия Certbot ==='
certbot --version
systemctl is-active x-ui
systemctl is-active certbot.timer

echo '=== Путь и URL панели (без пароля) ==='
sudo bash scripts/panel_access.sh
```

Последняя команда выводит **фактический** `Panel URL` и готовую команду `SSH tunnel`, используя `/etc/x-ui/install-result.env`. Значение `YOUR_SECRET_BASE_PATH` в примере `http://127.0.0.1:8443/YOUR_SECRET_BASE_PATH/` — **заполнитель**, его нужно заменить путём из строки `Panel URL`. Например, при `Panel URL: http://127.0.0.1:8443/abc123/` открывают именно этот URL **после запуска SSH-туннеля в Windows**. Команда без `--show-credentials` не печатает пароль. Не публикуйте действительный секретный путь панели в открытых логах или issue.

## Проверка после установки

На VPS:

```bash
sudo bash scripts/verify.sh
sudo bash scripts/healthcheck.sh
sudo bash scripts/cert_status.sh
systemctl is-active x-ui
ss -lntp '( sport = :443 )'
```

С другой сети проверьте **реальный VLESS-трафик** (не только открытый 443, WebSocket или TLS). Клиентская конфигурация доступна на VPS в файлах `/etc/x-ui/autodeploy-client.*` с root-правами. Не публикуйте её.

## Резервные копии и обновления

```bash
sudo bash scripts/backup.sh
sudo bash scripts/check_source.sh
systemctl list-timers --all xui-autodeploy-backup.timer
```

На свежей установке включается локальный таймер бэкапов и Certbot deploy hook: после **фактического успешного продления** сертификата он перезапускает 3X-UI. TCP 80 должен оставаться доступным для последующих проверок HTTP-01. Резервные копии содержат ключи и пароли — храните зашифрованную копию вне VPS. Локальный бэкап сам по себе не защищает от потери VPS.

Версия Xray фиксируется на момент установки: `latest` **не** означает непрерывное автообновление. Для целевого обновления/отката предусмотрены `scripts/upgrade_xray.sh` и `scripts/rollback.sh`, применять с диагностикой и тестом VPN.

## Firewall

Установка **не** включает глобальный запрет INPUT/DROP, чтобы не обрубить SSH. Дополнительное ужесточение — только после независимой проверки SSH и с готовым откатом:

```bash
sudo bash scripts/harden_firewall.sh apply
# Проверьте доступ с новой SSH-сессии, только затем:
sudo bash scripts/harden_firewall.sh confirm
```

Не выполняйте эти команды без резервного способа доступа к VPS. Настройка `STRICT_FIREWALL` в `config.env` зарезервирована и сама по себе **ничего не включает**.

## Типичные проблемы

| Симптом | Проверка |
| --- | --- |
| Не выпускается LE-сертификат | A-запись, внешний TCP 80, лимиты LE, `journalctl`/вывод Certbot |
| Панель недоступна напрямую | Так задумано: используйте SSH-туннель к 127.0.0.1 |
| VPN не подключается | TCP 443 на VPS и у провайдера; DNS, SNI, WS path, клиентский UUID |
| Сервис активен, трафика нет | Проверить полный клиентский VLESS-сеанс, а не только `systemctl` |
| После apt upgrade нужен reboot | Завершить обновления и перезагрузиться до установки на новом VPS |
| Установщик отказывает | Проверить, что VPS действительно чистый, ОС Ubuntu 24.04, порты свободны |

## Безопасность и ограничения

- Не коммитьте `config.env`, реальные `*.pem`, `*.key`, `*.db`, `*.vless`, бэкапы, токены и UUID.
- Секреты хранятся локально с правами root. Вывод `--show-credentials` — конфиденциальный.
- Не используйте этот сценарий для автоматического обновления **уже работающего** VPN.
- Нужен тест на одноразовом VPS перед эксплуатацией: успешная статическая проверка не гарантирует корректность API или поведения актуальных пакетов.

## Файлы проекта

| Файл | Назначение |
| --- | --- |
| `install.sh` | Установка на чистом сервере, включая apt update/upgrade |
| `config.example.env` | Пример параметров |
| `scripts/api_inbound.py` | Создание inbound в 3X-UI по localhost API |
| `scripts/panel_access.sh` | SSH-туннель и доступ к панели |
| `scripts/install_cert_hook.sh` | Certbot deploy hook |
| `scripts/upgrade_xray.sh`, `rollback.sh` | Обновление Xray и локальный откат |
| `scripts/backup.sh`, `install_backup_timer.sh` | Локальные бэкапы |
| `scripts/verify.sh`, `healthcheck.sh`, `cert_status.sh`, `check_source.sh` | Проверки |
| `scripts/harden_firewall.sh` | Ручная усиленная firewall-политика |

Исходные проекты: [3X-UI](https://github.com/MHSanaei/3x-ui), [Xray-core](https://github.com/XTLS/Xray-core).

Лицензия на исходные компоненты определяется соответствующими upstream-проектами. Этот репозиторий не связан с их разработчиками.
