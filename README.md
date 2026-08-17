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
- Site собирается с `VITE_MONOLITH_HUB_URL=http://192.168.1.32:8080`.
- DEV build включает `VITE_MONOLITH_ENABLE_DEVELOPMENT=true`; публичные Site-сборки по умолчанию Development не показывают.

## Профили

| Профиль | Целевой адрес | Состояние |
|---|---|---|
| `dev` | `http://192.168.1.32` | включён |
| `test` | `https://amuletsimple.ru:8443/` | зарезервирован, деплой заблокирован |
| `production` | `https://amuletsimple.ru/` | зарезервирован, деплой заблокирован |

`bootstrap.sh` и `deploy.sh` намеренно разрешают только `dev`. Test и Production этой репой пока не изменяются.

## DEV source refs

DEV по умолчанию использует `main`:

```env
HUB_REF=main
SITE_REF=main
```

Для воспроизводимого релиза можно закрепить tag или commit SHA.

## Первый запуск DEV вручную

На Debian/Ubuntu:

```bash
sudo mkdir -p /opt/monolith
sudo chown "$USER":"$USER" /opt/monolith
git clone https://github.com/Amulet-software/MonolithDeploy.git /opt/monolith
cd /opt/monolith
sudo ./bootstrap.sh dev
```

`bootstrap.sh dev` устанавливает Docker/Compose/Git/OpenSSH/rsync, создаёт пользователя `monolith`, `.env.dev`, случайные секреты PostgreSQL/Hub, выдаёт `monolith` доступ к Docker и затем выполняет `deploy.sh dev` от имени `monolith`.

Для приватных HubMonolith/SiteMonolit заранее настройте read-доступ именно для пользователя `monolith`: SSH либо `GITHUB_TOKEN_FILE` в `.env.dev`. Для HTTPS fine-grained token рекомендуется файл `/home/monolith/.config/monolith/github-token` с владельцем `monolith` и режимом `600`.

## Подготовка к первому CI/CD-тесту

Чтобы **первый реальный deploy выполнил GitHub Actions**, а не bootstrap, используйте:

```bash
cd /opt/monolith
sudo ./bootstrap.sh dev --prepare-only
```

Этот режим ставит инфраструктурные зависимости, создаёт пользователя/секреты/права, но Site/Hub не запускает.

Затем:

1. настройте read-доступ `monolith` к приватным HubMonolith и SiteMonolit;
2. зарегистрируйте repository-scoped self-hosted runner репозитория `MonolithDeploy` от пользователя `monolith`;
3. при `config.sh` добавьте custom label `monolith-dev`;
4. установите runner как systemd service от пользователя `monolith`;
5. в GitHub Actions вручную запустите workflow **Deploy DEV**, введя подтверждение `DEPLOY-DEV`.

Подробная пошаговая инструкция: [`docs/first-cicd-test.md`](docs/first-cicd-test.md).

## Что делает Deploy DEV workflow

```text
manual workflow_dispatch
        ↓
repository-scoped runner
self-hosted + linux + x64 + monolith-dev
        ↓
проверка user/IP/Docker/.env.dev
        ↓
синхронизация MonolithDeploy → /opt/monolith
        ↓
DEV preflight
        ↓
fetch HubMonolith main
fetch SiteMonolit main
        ↓
docker compose build --pull
        ↓
docker compose up -d
        ↓
health-check Site + Hub
```

На первом этапе workflow **только ручной**. Merge в Hub/Site сам по себе DEV не обновляет. Автоматический trigger после успешного CI подключается только после успешного первого end-to-end теста.

## Ручное обновление DEV

```bash
cd /opt/monolith
sudo -u monolith ./deploy.sh dev
```

PostgreSQL и Hub storage находятся в именованных Docker volumes и не удаляются при обычной пересборке контейнеров.

## Проверка и журналы

```bash
cd /opt/monolith
sudo -u monolith ./health-check.sh dev
docker compose --project-name monolith-dev --env-file .env.dev --profile dev ps
docker compose --project-name monolith-dev --env-file .env.dev --profile dev logs -f hub
docker compose --project-name monolith-dev --env-file .env.dev --profile dev logs -f site
docker compose --project-name monolith-dev --env-file .env.dev --profile dev logs -f nginx
```

## Резервное копирование

```bash
cd /opt/monolith
sudo -u monolith ./backup.sh dev
```

Результат сохраняется в `backups/dev/<UTC timestamp>/`:

- `database.dump` — PostgreSQL custom-format dump;
- `hub-storage.tar.gz` — Hub storage;
- `SHA256SUMS` — контрольные суммы.

Срок хранения задаётся `BACKUP_RETENTION_DAYS` в `.env.dev`.

## Безопасность

- наружу публикуются только `192.168.1.32:80` и `192.168.1.32:8080`;
- PostgreSQL `5432` не публикуется;
- `.env.dev`, `.runtime/` и `backups/` не попадают в Git;
- signed `.monmod` enforcement включён;
- runner работает не от root, а от отдельного пользователя `monolith`;
- runner рекомендуется регистрировать только в `MonolithDeploy`, не на всю организацию;
- workflow требует label `monolith-dev` и ручное подтверждение `DEPLOY-DEV`;
- Test/Production текущими deploy-скриптами запустить нельзя.

## CI MonolithDeploy

Обычный CI проверяет shell-синтаксис инфраструктурных скриптов и `docker compose config` для DEV. Реальный deployment выполняет отдельный manual workflow `Deploy DEV` только на DEV self-hosted runner.
