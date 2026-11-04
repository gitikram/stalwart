# Deploying to a VPS with Coolify

The workflow is: **GitHub Actions builds the image, Coolify pulls it.** Every push
to `main` triggers `.github/workflows/docker-image.yml`, which builds a single
multi-arch image (amd64 + arm64) containing:

- the **Stalwart server**, compiled from `server/` (cargo-chef build, upstream's recipe),
- the **WebUI**, built from `webui/` and **bundled into the image** at `/opt/stalwart/webui.zip`.

The server's default UI URL is pinned to the bundled zip (the builder stage rewrites
the upstream GitHub download URL to `file:///opt/stalwart/webui.zip`), so the admin
panel and portal are always **your local build** — nothing is downloaded from GitHub
at runtime, and redeploying ships your latest UI changes automatically.

This split exists because compiling Stalwart on a small VPS takes 1–2+ hours and
lots of RAM; GitHub's runners do it for free — natively on both x86 and ARM
machines in parallel (no emulation) — so the VPS only ever pulls a ready-made
image (~1 min deploys).

## Files

| File | Purpose |
|---|---|
| `.github/workflows/docker-image.yml` | CI: builds + pushes the image to GHCR on every push to `main` |
| `Dockerfile` | Builds server + WebUI into one image |
| `docker-compose.yml` | Coolify resource — pulls `ghcr.io/gitikram/stalwart:main` |
| `.dockerignore` | Keeps the build context to what's needed |

## Prerequisites

1. This repo on GitHub (`gitikram/stalwart`) — CI runs automatically on push.
2. **VPS sizing**: running Stalwart is light (~0.5–1 GB RAM + mail storage). Any
   1–2 GB VPS works when using the CI image. (Only *building* on the VPS needs
   4 GB+ — see the alternative below.)
3. **DNS (before deploy)**: an `A` (and/or `AAAA`) record for your mail hostname,
   e.g. `mail.example.com → VPS IP`. Mail-specific records (MX, SPF, DKIM, DMARC)
   are covered in *Mail setup* below.
4. **Firewall**: allow inbound 25, 465, 993, 995, 4190 (80/443 are managed by
   Coolify's proxy). Outbound **port 25 must not be blocked** — many providers
   (Hetzner, DigitalOcean, Oracle…) block it by default; request the block removed
   or your mail can't be delivered.
5. **GHCR package visibility (one-time)**: the first CI run creates the package
   **private**. Either make it public — GitHub repo → Packages → `stalwart` →
   *Package settings* → *Change visibility* → Public (source is AGPL anyway) —
   or keep it private and add a read-credentials registry entry in Coolify
   (Server → Registries, PAT with `read:packages`).

## Deploy steps

1. Wait for the CI run to finish: GitHub repo → **Actions** → "Build Docker image"
   green, and the image exists at `ghcr.io/gitikram/stalwart:main`.
2. Make the GHCR package public (or set up registry credentials, see Prerequisites).
3. Coolify dashboard → your project → **New Resource → Docker Compose**.
4. Select the repo + branch. Compose file: `./docker-compose.yml`.
5. Assign a **domain** to the `stalwart` service: `https://mail.example.com:8080`
   (the trailing `:8080` = *container* port; Coolify's proxy terminates HTTPS on
   443 in front of it — no conflict with Coolify itself, which uses 8000/6001 and
   proxy ports 80/443, none of which we publish).
6. Optionally add environment variables on the service:
   - `STALWART_HOSTNAME=mail.example.com`
   - `STALWART_PUBLIC_URL=https://mail.example.com`
7. **Deploy** — it just pulls the image and starts (~1–2 min).
8. Open your domain → Stalwart runs its **first-boot setup wizard** (bootstrap
   mode, port 8080). Create the admin account; keep the default local data store
   (SQLite/RocksDB paths inside the `/var/lib/stalwart` volume) for a single node.

> The healthcheck allows a long start period (300 s) so the container isn't marked
> unhealthy while it waits for you to finish the wizard.

## Alternative: build on the VPS (not recommended)

If you ever want the VPS to build instead of pulling:

1. In `docker-compose.yml` comment the `image:` line and uncomment the `build:` block.
2. Raise Coolify's deployment timeout: Server → Settings → **Advanced → Builds**
   (set e.g. 7200 s) — the default 3600 s *will* kill the first build.
3. On a VPS with < 4 GB RAM also uncomment `BUILD_LTO: "false"` and
   `BUILD_CODEGEN_UNITS: "16"`, and add swap, or the build will thrash/OOM.

Expect 1–2+ hours for the first build and long rebuilds afterwards — the CI route
exists precisely to avoid this.

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

- **Updates**: `git push` → CI builds a new image → Coolify **Redeploy** (pulls
  `main` tag). Server and WebUI rebuild from source. To fully automate, enable
  webhooks for the resource in Coolify so pushes trigger redeploy.
- **Backups** (Coolify → service → Backups): schedule backups of the named volumes
  `stalwart-data` (all mail + registry) and `stalwart-config` (bootstrap config).
- **Logs**: Coolify log viewer, or `docker logs` — the healthcheck endpoints are
  `/healthz/live` on 8080 (HTTP) and 443 (HTTPS).
- **Admin UI hardening**: enable 2FA for the admin account; the UI is internet-facing
  through your domain.

## Troubleshooting

- **"Image not found" / pull error on deploy** → the GHCR package is still private
  (make it public, see Prerequisites) or the CI run hasn't finished yet.
- **UI shows a setup wizard after you already configured** → the config volume
  (`stalwart-config`) was lost; check both volumes are attached.
- **Can receive but not send mail** → outbound port 25 blocked by the provider (see
  Prerequisites) or missing PTR/SPF/DKIM.
