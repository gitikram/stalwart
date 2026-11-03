# Deploying to a VPS with Coolify

This repo deploys as **one Docker image** that contains everything:

- the **Stalwart server**, compiled from `server/` (cargo-chef multi-stage build, same recipe as upstream),
- the **WebUI**, built from `webui/` inside the image and **bundled into it** at `/opt/stalwart/webui.zip`.

The server's default UI URL is pinned to the bundled zip (the builder stage rewrites
the upstream GitHub download URL to `file:///opt/stalwart/webui.zip`), so the admin
panel and account portal are always **your local build** — the container never
downloads anything from GitHub at runtime. Every image build picks up whatever is
in `webui/` at that moment; redeploying ships UI updates automatically.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Builds server + WebUI into one image |
| `docker-compose.yml` | Coolify "Docker Compose" resource definition |
| `.dockerignore` | Keeps the build context to what's needed |

## Prerequisites

1. **Push this repo to a git remote** (GitHub/GitLab — Coolify clones from it).
2. **VPS sizing**: the Rust release build wants memory. ≥ 4 GB RAM recommended.
   On a 2 GB VPS, uncomment in `docker-compose.yml`:
   ```yaml
   args:
     BUILD_LTO: "false"
     BUILD_CODEGEN_UNITS: "16"
   ```
3. **DNS (before deploy)**: an `A` (and/or `AAAA`) record for your mail hostname,
   e.g. `mail.example.com → VPS IP`. Mail-specific records (MX, SPF, DKIM, DMARC)
   are covered in *Mail setup* below.
4. **Firewall**: allow inbound 25, 465, 993, 995, 4190 (and 80/443 which Coolify's
   proxy already manages). Outbound **port 25 must not be blocked** — many providers
   (Hetzner, DigitalOcean, Oracle…) block it by default; request the block removed
   or your mail can't be delivered.

## Deploy steps

1. Coolify dashboard → your project → **New Resource → Docker Compose**.
2. Select the repo + branch. Compose file: `./docker-compose.yml`.
3. Assign a **domain** to the `stalwart` service, pointing at the container's HTTP
   port: `https://mail.example.com:8080` (the trailing `:8080` = container port;
   Coolify's proxy terminates HTTPS in front of it).
4. Optionally add environment variables on the service:
   - `STALWART_HOSTNAME=mail.example.com`
   - `STALWART_PUBLIC_URL=https://mail.example.com`
5. **Deploy.** First build compiles the whole Rust workspace — expect **20–45 min**;
   later builds are incremental (cargo-chef caches dependencies per Dockerfile layer).
6. Open your domain → Stalwart runs its **first-boot setup wizard** (bootstrap mode,
   port 8080). Create the admin account; keep the default local data store
   (SQLite/RocksDB paths inside the `/var/lib/stalwart` volume) for a single node.

> The healthcheck allows a long start period (300 s) so the container isn't marked
> unhealthy while it waits for you to finish the wizard.

## Mail setup (after the wizard)

1. **DNS records** — create in your DNS provider, values from the admin UI:
   - `MX` → `mail.example.com` (priority 10)
   - `SPF`: TXT `v=spf1 mx -all`
   - `DKIM`: the admin UI generates keys per domain — publish the selector TXT it shows
   - `DMARC`: TXT `_dmarc` → `v=DMARC1; p=quarantine; rua=mailto:dmarc@example.com`
2. **rDNS/PTR**: set the reverse DNS of your VPS IP to `mail.example.com` with your
   provider — major receivers reject mail without it.
3. **TLS for mail protocols**: Coolify's proxy owns ports 80/443, so Stalwart can't
   do HTTP-01/TLS-ALPN ACME. Use **DNS-01** in the admin UI
   (TLS → certificate authorities → Let's Encrypt → DNS challenge + your DNS
   provider's API credentials). SMTP (465), IMAPS (993), POP3S (995) then get
   proper certificates. Until then they present self-signed certs.
4. **Optional ports**: to offer STARTTLS submission (587) or plain IMAP/POP3 (143/110),
   create the listeners in the admin UI first, then uncomment the matching lines in
   `docker-compose.yml` and redeploy.

## Operations

- **Updates**: `git push` → Coolify **Redeploy**. Server and WebUI rebuild from source.
- **Backups** (Coolify → service → Backups): schedule backups of the named volumes
  `stalwart-data` (all mail + registry) and `stalwart-config` (bootstrap config).
- **Logs**: Coolify log viewer, or `docker logs` — the healthcheck endpoints are
  `/healthz/live` on 8080 (HTTP) and 443 (HTTPS).
- **Admin UI hardening**: enable 2FA for the admin account; the UI is internet-facing
  through your domain.

## Troubleshooting

- **Build dies / OOM on the VPS** → use the `BUILD_LTO=false` / `BUILD_CODEGEN_UNITS=16`
  args, or build the image on a bigger machine (or CI) and point the compose file at
  the pushed image instead of `build:`.
- **UI shows a setup wizard after you already configured** → the config volume
  (`stalwart-config`) was lost; check both volumes are attached.
- **Can receive but not send mail** → outbound port 25 blocked by the provider (see
  Prerequisites) or missing PTR/SPF/DKIM.
