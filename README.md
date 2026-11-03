# Monorepo

| Path | What it is | Vendored from |
|---|---|---|
| `server/` | Stalwart mail & collaboration server (Rust workspace, v1.0.2) | [stalwartlabs/stalwart](https://github.com/stalwartlabs/stalwart) |
| `webui/` | Stalwart WebUI — admin `/admin` + portal `/account` SPA (v2.0.4) | [stalwartlabs/webui](https://github.com/stalwartlabs/webui) |

## Deploying

Docker configuration lives at the repo root: `Dockerfile` (single image with the
server + WebUI bundled from `webui/`), `docker-compose.yml` (Coolify resource),
and a step-by-step guide in [DEPLOY.md](DEPLOY.md).

## WebUI build & wiring

The server downloads its web UI at runtime by default. In this layout, the server's
`dev_mode` default points at `file://../webui/.ignore/webui.zip`, so a local build
resolves with no configuration change:

```sh
cd webui
./build.sh        # npm ci + vite build, zips dist/ -> .ignore/webui.zip
```

To serve a local build in a non-dev setup, set the `Application` object's
`resource_url` to a `file://` URL pointing at `webui/.ignore/webui.zip`.

Both projects are dual-licensed AGPL-3.0 / Stalwart Enterprise License — see
`server/LICENSES/` and `webui/LICENSES/`.
