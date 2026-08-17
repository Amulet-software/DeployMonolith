# MonolithDeploy

Инфраструктура Monolith по схеме **«один профиль = один сервер»**. На сервере запускается один независимый набор контейнеров: Nginx, SiteMonolit, HubMonolith и PostgreSQL.

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
- Swagger: `http://192.168.1.32:8080/docs`
- Hub readiness: `http://192.168.1.32:8080/health/ready`
- PostgreSQL не публикуется на хост и доступен только внутри Docker-сети.
- Site собирается с `VITE_MONOLITH_HUB_URL=http://192.168.1.32:8080`, поэтому DEV-сайт использует DEV Hub.

## Профили

| Профиль | Целевой адрес | Состояние |
|---|---|---|
| `dev` | `http://192.168.1.32` | включён |
| `test` | `https://amuletsimple.ru:8443/` | зарезервирован, деплой заблокирован |
| `production` | `https://amuletsimple.ru/` | зарезервирован, деплой заблокирован |

`bootstrap.sh` и `deploy.sh` намеренно разрешают только `dev`. Действующие Test и Production этой репой пока не изменяются.

## Что должно быть слито перед первым DEV deploy

DEV по умолчанию использует `main`:

```env
HUB_REF=main
SITE_REF=main
```

Перед первым реальным деплоем в `main` должны находиться согласованные версии HubMonolith и SiteMonolit с поддержкой release channels и `VITE_MONOLITH_HUB_URL`.

## Доступ к приватным GitHub-репозиториям

`deploy.sh` сначала выполняет read-only preflight для HubMonolith и SiteMonolit. Docker build не начнётся, если сервер не может прочитать оба репозитория.

Поддерживаются два варианта.

### Вариант A: SSH

Так как `bootstrap.sh` и рекомендуемый deploy запускаются через `sudo`, SSH-доступ должен быть доступен именно root-пользователю либо передан через корректно настроенный root `ssh-agent`/`SSH_AUTH_SOCK`. Для отдельной серверной machine-учётной записи GitHub укажите SSH URL в `.env.dev`:

```env
HUB_REPOSITORY=git@github.com:Amulet-software/HubMonolith.git
SITE_REPOSITORY=git@github.com:Amulet-software/SiteMonolit.git
GITHUB_TOKEN_FILE=
```

Проверка в том же контексте, в котором выполняется deploy:

```bash
sudo git ls-remote git@github.com:Amulet-software/HubMonolith.git HEAD
sudo git ls-remote git@github.com:Amulet-software/SiteMonolit.git HEAD
```

### Вариант B: fine-grained GitHub token по HTTPS

Для первого DEV этот вариант проще: создайте fine-grained token только с read-доступом к нужным приватным репозиториям и `Contents: Read`, затем на DEV-сервере:

```bash
sudo install -d -m 700 /root/.config/monolith
sudo nano /root/.config/monolith/github-token
sudo chmod 600 /root/.config/monolith/github-token
```

В `.env.dev`:

```env
GITHUB_TOKEN_FILE=/root/.config/monolith/github-token
HUB_REPOSITORY=https://github.com/Amulet-software/HubMonolith.git
SITE_REPOSITORY=https://github.com/Amulet-software/SiteMonolit.git
```

Токен не записывается в Git remote URL и не передаётся в контейнеры; `deploy.sh` использует временный `GIT_ASKPASS` только для Git-операций.

## Первый запуск DEV на Debian/Ubuntu

Сервер должен иметь адрес `192.168.1.32`. Сначала получите сам MonolithDeploy через уже настроенный Git-доступ, затем:

```bash
sudo mkdir -p /opt/monolith
sudo chown "$USER":"$USER" /opt/monolith
git clone https://github.com/Amulet-software/MonolithDeploy.git /opt/monolith
cd /opt/monolith
sudo ./bootstrap.sh dev
```

Если MonolithDeploy клонируется по SSH, используйте соответствующий SSH URL.

`bootstrap.sh dev`:

1. устанавливает Docker Engine, Docker Compose, Git, OpenSSL и OpenSSH client;
2. создаёт `.env.dev` из `profiles/dev.env.example`;
3. генерирует пароль PostgreSQL и Hub Admin API key;
4. запускает `deploy.sh dev`;
5. `deploy.sh` проверяет доступ к Hub/Site, загружает `main`, валидирует Compose и собирает контейнеры;
6. Site получает адрес DEV Hub как Vite build arg;
7. запускаются `db`, `hub`, `site`, `nginx`;
8. выполняется внешний health-check Site и Hub.

`.env.dev` имеет права `600`, исключён из Git и должен резервироваться отдельно как секрет.

## Обновление DEV

После merge изменений в `main`:

```bash
cd /opt/monolith
sudo ./deploy.sh dev
```

Скрипт:

```text
GitHub access preflight
        ↓
fetch HubMonolith main
fetch SiteMonolit main
        ↓
docker compose config
        ↓
docker compose build --pull
        ↓
docker compose up -d
        ↓
health-check
```

PostgreSQL и Hub storage находятся в именованных Docker volumes и не удаляются при обычной пересборке контейнеров.

Для воспроизводимого релиза вместо `main` можно закрепить tag или commit SHA в `HUB_REF`/`SITE_REF`.

## Проверка и журналы

```bash
./health-check.sh dev
docker compose --project-name monolith-dev --env-file .env.dev --profile dev ps
docker compose --project-name monolith-dev --env-file .env.dev --profile dev logs -f hub
docker compose --project-name monolith-dev --env-file .env.dev --profile dev logs -f site
docker compose --project-name monolith-dev --env-file .env.dev --profile dev logs -f nginx
```

## Резервное копирование

```bash
sudo ./backup.sh dev
```

Результат сохраняется в `backups/dev/<UTC timestamp>/`:

- `database.dump` — PostgreSQL custom-format dump;
- `hub-storage.tar.gz` — файлы Hub;
- `SHA256SUMS` — контрольные суммы.

Срок хранения задаётся `BACKUP_RETENTION_DAYS` в `.env.dev`. Копии необходимо переносить за пределы DEV-сервера.

Пример ежедневного cron:

```cron
15 3 * * * cd /opt/monolith && ./backup.sh dev >> /var/log/monolith-backup.log 2>&1
```

## Безопасность

- наружу публикуются только `192.168.1.32:80` и `192.168.1.32:8080`;
- PostgreSQL `5432` не публикуется;
- `.env.dev`, `.runtime/` и `backups/` не попадают в Git;
- проверка подписанных `.monmod` включена;
- GitHub token, если используется, хранится отдельным root-only файлом;
- Test/Production нельзя случайно поднять текущими bootstrap/deploy-скриптами.

## CI MonolithDeploy

GitHub Actions проверяет shell-синтаксис скриптов и `docker compose config` для DEV-профиля. Это не заменяет реальный smoke test на `192.168.1.32`, но блокирует очевидно сломанную инфраструктурную конфигурацию до merge.
