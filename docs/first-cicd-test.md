# Первый CI/CD-тест DEV

Цель: первый реальный запуск SiteMonolit + HubMonolith + PostgreSQL + Nginx на `192.168.1.32` должен выполнить GitHub Actions через repository-scoped self-hosted runner. Production/Test не используются.

## 1. Подготовить голый сервер без deploy

Получите `MonolithDeploy` в `/opt/monolith`, затем:

```bash
cd /opt/monolith
sudo ./bootstrap.sh dev --prepare-only
```

После команды должны существовать:

- пользователь `monolith`;
- Docker Engine + Compose;
- `/opt/monolith/.env.dev` с режимом `600` и владельцем `monolith`;
- каталоги `.runtime/` и `backups/`;
- пользователь `monolith` в группе `docker`.

Проверка:

```bash
id monolith
sudo -u monolith docker info >/dev/null && echo Docker_OK
ls -l /opt/monolith/.env.dev
```

Если Docker group была добавлена только что, runner нужно запускать уже после bootstrap, чтобы service получил актуальные группы.

## 2. Дать `monolith` read-доступ к HubMonolith и SiteMonolit

Для первого теста проще использовать fine-grained GitHub token только с `Contents: Read` на `HubMonolith` и `SiteMonolit`.

```bash
sudo -u monolith mkdir -p /home/monolith/.config/monolith
sudo -u monolith nano /home/monolith/.config/monolith/github-token
sudo chmod 600 /home/monolith/.config/monolith/github-token
sudo chown monolith:monolith /home/monolith/.config/monolith/github-token
```

В `/opt/monolith/.env.dev`:

```env
GITHUB_TOKEN_FILE=/home/monolith/.config/monolith/github-token
HUB_REPOSITORY=https://github.com/Amulet-software/HubMonolith.git
HUB_REF=main
SITE_REPOSITORY=https://github.com/Amulet-software/SiteMonolit.git
SITE_REF=main
```

Не помещайте token в `.env.dev` напрямую и не вставляйте его в remote URL.

## 3. Проверить private-repo access вручную

`deploy.sh` сам делает preflight, но до регистрации runner полезно проверить:

```bash
sudo -u monolith /opt/monolith/deploy.sh dev
```

Для первого CI/CD-теста эту команду **не выполняйте до конца**, если хотите, чтобы именно GitHub Actions был первым deploy. Вместо этого достаточно убедиться, что token-файл существует и читается; реальный repository preflight выполнит workflow перед Docker build.

## 4. Зарегистрировать repository-scoped self-hosted runner

В GitHub откройте:

`Amulet-software/MonolithDeploy → Settings → Actions → Runners → New self-hosted runner`

Выберите Linux x64. GitHub покажет актуальные команды скачивания runner и одноразовый registration token. Выполняйте команды от пользователя `monolith`:

```bash
sudo -iu monolith
mkdir -p ~/actions-runner
cd ~/actions-runner
```

Выполните команды скачивания/распаковки, которые показывает GitHub. Для конфигурации используйте показанный token и добавьте имя/label:

```bash
./config.sh \
  --url https://github.com/Amulet-software/MonolithDeploy \
  --token <ONE_TIME_REGISTRATION_TOKEN> \
  --name monolith-dev-192-168-1-32 \
  --labels monolith-dev \
  --unattended
```

После успешного `config.sh` выйдите из shell пользователя `monolith` и установите runner как systemd service от его имени:

```bash
exit
cd /home/monolith/actions-runner
sudo ./svc.sh install monolith
sudo ./svc.sh start
sudo ./svc.sh status
```

В GitHub runner должен быть Online и иметь labels как минимум:

```text
self-hosted
linux
x64
monolith-dev
```

## 5. Локальный runner preflight

На сервере:

```bash
cd /opt/monolith
sudo -u monolith bash ./cicd-preflight.sh dev
```

Ожидаемый результат:

```text
DEV CI/CD preflight passed: user=monolith host=192.168.1.32 docker=ready
```

## 6. Первый GitHub Actions deploy

В `MonolithDeploy` откройте `Actions → Deploy DEV → Run workflow`.

В поле confirmation введите строго:

```text
DEPLOY-DEV
```

Workflow должен пройти этапы:

```text
Checkout MonolithDeploy
Verify DEV runner
Sync deployment definition
Run DEV preflight
Deploy DEV
Verify public DEV endpoints
Deployment summary
```

На первом тесте workflow работает только вручную. Push/Merge в `HubMonolith` или `SiteMonolit` сам deploy не запускает.

## 7. Что проверить после success

С рабочего ПК:

```text
http://192.168.1.32
http://192.168.1.32:8080/docs
http://192.168.1.32:8080/health/ready
```

На сервере:

```bash
cd /opt/monolith
docker compose --project-name monolith-dev --env-file .env.dev --profile dev ps
sudo -u monolith ./health-check.sh dev
```

Ожидаются четыре сервиса:

```text
db
hub
site
nginx
```

PostgreSQL не должен иметь published host port `5432`.

## 8. После первого успешного теста

Только после успешного end-to-end теста добавляем автоматический CD trigger после успешного CI Hub/Site. До этого `Deploy DEV` остаётся ручным, чтобы исключить неожиданные выкаты во время настройки сервера.
