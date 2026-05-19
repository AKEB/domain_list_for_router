# domain_list_for_router

Списки доменов для Keenetic (object-group fqdn). Имя файла в `lists/` = поле `description` в конфиге роутера.

## Синхронизация на роутер

На сервере с git нужны `sshpass` и SSH-доступ к Keenetic (`ROUTER_*` в `.env`). На роутере — каталог `REMOTE_REPO_DIR` для скриптов и списков.

```bash
cp .env.example .env
# отредактировать .env

chmod +x scripts/*.sh

# один проход
./scripts/sync-domains.sh once

# фоновый опрос git (каждые 60 с)
./scripts/sync-domains.sh watch
```

### systemd (опционально)

```ini
[Unit]
Description=Sync domain lists to Keenetic
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/domain_list_for_router
ExecStart=/opt/domain_list_for_router/scripts/sync-domains.sh watch
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

## Как это работает

1. `sync-domains.sh` делает `git pull` из `git@github.com:AKEB/domain_list_for_router.git`.
2. При изменениях в `lists/*.txt` копирует файлы на роутер и вызывает `apply-domain-list.sh`.
3. **Новый файл** в `lists/` — создаётся `object-group fqdn` (свободный `domain-listN`), все домены из файла и маршрут `dns-proxy` (интерфейс из `ROUTER_DNS_ROUTE_INTERFACE`, по умолчанию `Wireguard0`).
4. **Изменённый файл** — обновляются только изменившиеся `include`.
5. **Удалённый файл** — удаляются маршрут `dns-proxy` и `object-group` с роутера.

Имя файла = поле `description` на роутере (без `.txt`). Для другого VPN укажите в `.env`, например `ROUTER_DNS_ROUTE_INTERFACE=OpenVPN0`.

## Зависимости

- `git`, `bash`, `sshpass`, `openssh-client`
- На роутере: включён SSH (компонент «Сервер SSH»), пользователь с правом изменения конфигурации
