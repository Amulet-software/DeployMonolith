# MonolithDeploy

Инфраструктура Monolith по схеме **«один профиль = один сервер»**. На сервере запускается только один независимый набор контейнеров: Nginx, SiteMonolit, HubMonolith и PostgreSQL.

## Текущий DEV

```text
192.168.1.32:80
    Nginx ──> SiteMonolit:80

192.168.1.32:8080
    Nginx ──> HubMonolith:8080 ──> PostgreSQL:5432
                              └──> Hub storage
```

- Site: `http://192.168.1.32`
- Hub: `http://192.168.1.32:8080`
- PostgreSQL не публикуется на хост и доступен только внутри Docker-сети.
- Исходники Hub и Site загружаются из существующих репозиториев; этот репозиторий их не изменяет.

## Профили

| Профиль | Целевой адрес | Состояние |
|---|---|---|
| `dev` | `http://192.168.1.32` | включён |
| `test` | `https://amuletsimple.ru:8443/` | зарезервирован, деплой заблокирован |
| `production` | `https://amuletsimple.ru/` | зарезервирован, деплой заблокирован |

Конфигурации test/production сохранены только как целевые шаблоны. `bootstrap.sh` и `deploy.sh` намеренно отказываются их запускать; действующие Test и Production не затрагиваются.

## Первый запуск DEV на Debian/Ubuntu

У сервера должен быть адрес `192.168.1.32`. Затем:

```bash
sudo mkdir -p /opt/monolith
sudo chown "$USER":"$USER" /opt/monolith
git clone https://github.com/Amulet-software/MonolithDeploy.git /opt/monolith
cd /opt/monolith
sudo ./bootstrap.sh dev
```

`bootstrap.sh dev`:

1. устанавливает Docker Engine и Docker Compose;
2. создаёт `.env.dev` из `profiles/dev.env.example`;
3. генерирует отдельные пароли PostgreSQL и Hub Admin API;
4. запускает `deploy.sh dev`;
5. ожидает успешных health-check Site и Hub.

Файл `.env.dev` имеет права `600`, исключён из Git и должен резервироваться отдельно как секрет.

## Обновление DEV

При необходимости закрепите теги или commit SHA в `HUB_REF` и `SITE_REF` файла `.env.dev`, затем:

```bash
sudo ./deploy.sh dev
```

Скрипт обновит только рабочие копии в `.runtime/`, проверит Compose, пересоберёт контейнеры профиля `dev` и выполнит health-check.

## Проверка и журналы

```bash
./health-check.sh dev
docker compose --project-name monolith-dev --env-file .env.dev --profile dev ps
docker compose --project-name monolith-dev --env-file .env.dev --profile dev logs -f hub
docker compose --project-name monolith-dev --env-file .env.dev --profile dev logs -f nginx
```

Hub предоставляет `/health/live` и `/health/ready`. Nginx также проверяет оба внутренних upstream-контейнера.

## Резервное копирование

```bash
sudo ./backup.sh dev
```

Результат сохраняется в `backups/dev/<UTC timestamp>/`:

- `database.dump` — PostgreSQL custom-format dump;
- `hub-storage.tar.gz` — файлы Hub;
- `SHA256SUMS` — контрольные суммы.

Срок хранения задаётся `BACKUP_RETENTION_DAYS` в `.env.dev`. Копии необходимо регулярно переносить за пределы DEV-сервера.

Пример ежедневного cron:

```cron
15 3 * * * cd /opt/monolith && ./backup.sh dev >> /var/log/monolith-backup.log 2>&1
```

## Безопасность

- наружу публикуются только `192.168.1.32:80` и `192.168.1.32:8080`;
- порт PostgreSQL `5432` не публикуется;
- `.env.dev`, `.runtime/` и `backups/` не попадают в Git;
- проверка подписанных `.monmod` включена;
- Test/Production нельзя случайно поднять текущими bootstrap/deploy-скриптами.

