# syntax=docker/dockerfile:1
###############################################################################
# Stalwart monorepo image
#
# Builds both components of this repo and produces a single self-contained
# server image:
#   - webui   (stage "webui"):  Vite build of webui/ -> webui.zip bundle
#   - server  (stages "chef*"): cargo-chef release build of server/
#
# The webui bundle is shipped inside the image at /opt/stalwart/webui.zip and
# the server's default Application URL is pinned to it (see the sed step in
# the builder stage), so the admin UI works with zero runtime downloads.
#
# Build args (useful on small VPS where the Rust release build may OOM):
#   BUILD_LTO=false            disable LTO (upstream default: true)
#   BUILD_CODEGEN_UNITS=16     more parallel codegen units (upstream default: 1)
###############################################################################

###############################################################################
# Stage 1 — WebUI bundle (admin panel + account portal SPA)
###############################################################################
FROM docker.io/library/node:22-alpine AS webui
WORKDIR /build/webui
RUN apk add --no-cache zip
COPY webui/package.json webui/package-lock.json ./
RUN npm ci
COPY webui/ ./
RUN npm run build
# Same packaging as the upstream webui build.sh:
# dist/ (incl. the stalwart-app.json manifest) -> .ignore/webui.zip
RUN mkdir -p .ignore && cd dist && zip -qr ../.ignore/webui.zip .

###############################################################################
# Stage 2-4 — Server (cargo-chef, mirrors upstream server/Dockerfile)
###############################################################################
FROM docker.io/lukemathwalker/cargo-chef:latest-rust-slim-trixie AS chef
WORKDIR /build

FROM chef AS planner
COPY server/ .
RUN cargo chef prepare --recipe-path /recipe.json

FROM --platform=$BUILDPLATFORM chef AS builder
ARG TARGETPLATFORM
ARG BUILD_LTO=true
ARG BUILD_CODEGEN_UNITS=1
RUN case "${TARGETPLATFORM}" in \
    "linux/arm64") echo "aarch64-unknown-linux-gnu" > /target.txt && echo "-C linker=aarch64-linux-gnu-gcc" > /flags.txt ;; \
    "linux/amd64") echo "x86_64-unknown-linux-gnu" > /target.txt && echo "-C linker=x86_64-linux-gnu-gcc" > /flags.txt ;; \
    *) exit 1 ;; \
    esac
RUN export DEBIAN_FRONTEND=noninteractive && \
    apt-get update && \
    apt-get install -yq --no-install-recommends build-essential libclang-19-dev \
    g++-aarch64-linux-gnu binutils-aarch64-linux-gnu \
    g++-x86-64-linux-gnu binutils-x86-64-linux-gnu
RUN rustup target add "$(cat /target.txt)"
# Cargo profile overrides — let small VPS trade binary perf for build feasibility.
ENV CARGO_PROFILE_RELEASE_LTO=${BUILD_LTO} \
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS=${BUILD_CODEGEN_UNITS}
COPY --from=planner /recipe.json /recipe.json
RUN RUSTFLAGS="$(cat /flags.txt)" cargo chef cook --target "$(cat /target.txt)" --release --no-default-features --features "sqlite postgres mysql rocks s3 redis azure nats enterprise" --recipe-path /recipe.json
COPY server/ .
# Pin the WebUI to the bundle baked into this image instead of the GitHub
# release download, so first boot and UI updates never depend on GitHub
# availability. Fails the build loudly if the upstream default changes.
RUN grep -q "https://github.com/stalwartlabs/webui/releases/download/v2/webui.zip" \
      crates/common/src/manager/defaults.rs \
    && sed -i 's|https://github.com/stalwartlabs/webui/releases/download/v2/webui.zip|file:///opt/stalwart/webui.zip|' \
      crates/common/src/manager/defaults.rs
RUN RUSTFLAGS="$(cat /flags.txt)" cargo build --target "$(cat /target.txt)" --release -p stalwart --no-default-features --features "sqlite postgres mysql rocks s3 redis azure nats enterprise"
RUN mv "/build/target/$(cat /target.txt)/release" "/output"

###############################################################################
# Final image
###############################################################################
FROM docker.io/debian:trixie-slim
RUN export DEBIAN_FRONTEND=noninteractive && \
    apt-get update && \
    apt-get install -yq --no-install-recommends ca-certificates curl libcap2-bin && \
    rm -rf /var/lib/apt/lists/* && \
    groupadd -r -g 2000 stalwart && \
    useradd -r -u 2000 -g 2000 -s /usr/sbin/nologin -M stalwart && \
    mkdir -p /etc/stalwart /var/lib/stalwart /opt/stalwart && \
    chown stalwart:stalwart /etc/stalwart /var/lib/stalwart
COPY --from=builder --chmod=0755 /output/stalwart /usr/local/bin/stalwart
COPY --from=webui --chmod=0644 /build/webui/.ignore/webui.zip /opt/stalwart/webui.zip
RUN setcap 'cap_net_bind_service=+ep' /usr/local/bin/stalwart
USER stalwart
WORKDIR /var/lib/stalwart
VOLUME ["/etc/stalwart", "/var/lib/stalwart"]
EXPOSE	443 25 110 587 465 143 993 995 4190 8080
ENV STALWART_HEALTHCHECK_URL=https://127.0.0.1:443/healthz/live
HEALTHCHECK --interval=30s --timeout=5s --start-period=300s --retries=5 \
    CMD curl -fsSk "$STALWART_HEALTHCHECK_URL" || curl -fsS http://127.0.0.1:8080/healthz/live || exit 1
ENTRYPOINT ["/usr/local/bin/stalwart"]
CMD ["--config", "/etc/stalwart/config.json"]
