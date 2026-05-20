# domain_list_for_router

Списки доменов для Keenetic (`object-group fqdn`). Имя файла в `lists/` = поле `description` на роутере (без `.txt`).

## Установка на gate-сервере

Репозиторий и скрипт синхронизации лежат в **`/root/domain_list_for_router`** (путь задан в `sync-on-gate.sh`).

```bash
git clone git@github.com:AKEB/domain_list_for_router.git /root/domain_list_for_router
cd /root/domain_list_for_router

cp .env.example .env
# ROUTER_HOST, ROUTER_USER, ROUTER_PASSWORD

# опционально: не заливать все списки, а только перечисленные (см. lists.include.example)
cp lists.include.example lists.include
# отредактируйте lists.include — одна строка = один lists/*.txt

chmod +x sync-on-gate.sh

# один проход после git push
./sync-on-gate.sh once

# фоновый опрос git (каждые 60 с)
./sync-on-gate.sh watch

# первичная синхронизация всех lists/*.txt (один снимок конфига роутера)
./sync-on-gate.sh bootstrap-all
```

### systemd (опционально)

```ini
[Unit]
Description=Sync domain lists to Keenetic
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/root/domain_list_for_router
ExecStart=/root/domain_list_for_router/sync-on-gate.sh watch
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

## Как это работает

1. `sync-on-gate.sh` на gate делает `git pull` из `git@github.com:AKEB/domain_list_for_router.git`.
2. Если в git изменились файлы в `lists/`, один раз снимает `show running-config` и строит снимок всех `domain-listN`, `description`, `include` и `dns-proxy route`. Без изменений в `lists/` роутер не трогается. Если на gate есть файл `lists.include` (не в git), обрабатываются только перечисленные в нём `lists/*.txt`; остальные изменения в репозитории подтягиваются через `git merge`, но на роутер не отправляются.
3. Для изменённых/новых/удалённых файлов в `lists/` собирает команды Keenetic CLI и отправляет **по одной строке** по SSH (пауза `ROUTER_COMMAND_DELAY`, по умолчанию 0.1 с).
4. В конце — одна команда `system configuration save`.

| Событие в git | Действие на роутере |
|---------------|---------------------|
| Новый файл | Свободный `domain-listN`, `description`, все `include`, маршрут `dns-proxy` |
| Изменённый файл | Только diff (`no include` / `include`) |
| Удалённый файл | `dns-proxy no route …`, `no object-group fqdn …` |

Для новых списков интерфейс VPN задаётся в `.env`: `ROUTER_DNS_ROUTE_INTERFACE` (по умолчанию `Wireguard0`).

### Проверка без применения

```bash
DRY_RUN=1 ./sync-on-gate.sh once
```

## Переменные `.env`

| Переменная | Назначение |
|------------|------------|
| `ROUTER_HOST` | IP роутера |
| `ROUTER_USER` | SSH-пользователь (обычно `admin`) |
| `ROUTER_PASSWORD` | Пароль SSH |
| `ROUTER_DNS_ROUTE_INTERFACE` | VPN для новых списков |
| `ROUTER_COMMAND_DELAY` | Пауза между командами CLI (сек) |
| `GIT_BRANCH` | Ветка для pull (по умолчанию `main`) |
| `CHECK_INTERVAL` | Интервал `watch` (сек) |
| `LISTS_INCLUDE_FILE` | Путь к allowlist списков (по умолчанию `lists.include` в корне репо) |

## Зависимости

- `git`, `bash`, `sshpass`, `openssh-client`
- На роутере: компонент «Сервер SSH», пользователь с правом изменения конфигурации
