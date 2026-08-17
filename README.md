# MonolithDeploy

Production-ready single-server deployment of SiteMonolit and HubMonolith. One Docker Compose project runs isolated **production** and **test** databases, Hub storage and site containers behind a shared Nginx gateway.

## Architecture

```text
Internet :80
    Nginx gateway
      ├─ PROD_SITE_HOST ── prod-site
      ├─ PROD_HUB_HOST  ── prod-hub ── prod-db + prod storage
      ├─ TEST_SITE_HOST ── test-site
      └─ TEST_HUB_HOST  ── test-hub ── test-db + test storage
```

Only Nginx is exposed. PostgreSQL and both Hub containers are private. Hub migrations are executed by the upstream image entrypoint. The deployment consumes the existing upstream Dockerfiles and does not modify either source repository.

## First deployment on Debian/Ubuntu

Create DNS A/AAAA records for all four hosts, clone this repository, then:

```bash
sudo mkdir -p /opt/monolith
sudo chown "$USER":"$USER" /opt/monolith
git clone https://github.com/Amulet-software/MonolithDeploy.git /opt/monolith
cd /opt/monolith
cp .env.example .env
nano .env
sudo ./bootstrap.sh
```

`bootstrap.sh` installs Docker Engine/Compose, generates four independent secrets when they still equal `change-me`, builds the upstream projects and starts the stack. Keep `.env` mode `600` and never commit it.

## Routine deployment

Choose immutable tags or commit SHAs in `HUB_REF` and `SITE_REF`, then run:

```bash
sudo ./deploy.sh
```

The script fetches the selected revisions, validates Compose, rebuilds, performs a rolling container replacement and waits for all four public endpoints. Re-running it is safe. A failed health check prints container state and exits non-zero, making the script suitable for GitHub Actions over SSH.

## Health and operations

```bash
./health-check.sh
docker compose ps
docker compose logs -f prod-hub
docker compose logs -f gateway
```

Hub readiness endpoints are `/health/ready`; liveness endpoints are `/health/live`. Site health checks request `/` inside each container.

## Backups

```bash
sudo ./backup.sh
```

Each timestamped directory contains PostgreSQL custom-format dumps, Hub storage archives and SHA-256 checksums for both contours. Old backup directories are removed after `BACKUP_RETENTION_DAYS`. Copy backups off-server. Example daily cron:

```cron
15 3 * * * cd /opt/monolith && ./backup.sh >> /var/log/monolith-backup.log 2>&1
```

Restore into an empty contour by stopping its Hub, restoring the matching database with `pg_restore --clean --if-exists`, replacing its storage volume contents, then starting Hub and running `health-check.sh`.

## HTTPS

The initial stack intentionally starts on HTTP so it can boot before certificates exist. Put Cloudflare or another TLS-terminating load balancer in front, or install Certbot on the host and extend the gateway with mounted certificates and port `443`. Do not expose Hub publicly over plain HTTP in production; set `HUB_PUBLIC_BASE_URL` and CORS origins to `https://...` after TLS is enabled.

## Security checklist

- replace all domains and verify generated secrets;
- pin `HUB_REF` and `SITE_REF` to reviewed tags/commits;
- allow inbound ports 80/443 only; never publish 5432 or 8080;
- keep signed `.monmod` enforcement enabled;
- store off-server encrypted backups and test restores;
- restrict SSH and the CI deploy key to this server/repository.

