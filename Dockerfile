# qbzd — QBZ headless Qobuz playback daemon
#
# Upstream ships prebuilt linux amd64/aarch64 tarballs (glibc 2.35 baseline),
# so this image downloads a release instead of building the Rust workspace.
# The binary links only libasound.so.2 beyond libc, hence the tiny runtime.

ARG QBZD_VERSION=2.0.2

FROM debian:bookworm-slim AS fetch
ARG QBZD_VERSION
ARG TARGETARCH
# sha256 of the upstream release tarballs for QBZD_VERSION. Update both when
# bumping the version, or the build fails the integrity check on purpose.
ARG QBZD_SHA256_AMD64=6bcdb2616f339b7905fc58f48edf7e3bc2e0e9eadc1ce6235b60c7fdf34b804c
ARG QBZD_SHA256_ARM64=adade56509544c00187476d58acef78538d3e5d475370263d98397dc61f200c9

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) rel_arch=amd64;   sha="$QBZD_SHA256_AMD64" ;; \
      arm64) rel_arch=aarch64; sha="$QBZD_SHA256_ARM64" ;; \
      *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/vicrodh/qbz/releases/download/v${QBZD_VERSION}/qbzd-${QBZD_VERSION}-linux-${rel_arch}.tar.gz"; \
    curl -fsSL -o /tmp/qbzd.tar.gz "$url"; \
    echo "${sha}  /tmp/qbzd.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/qbzd.tar.gz -C /tmp; \
    install -Dm755 "/tmp/qbzd-${QBZD_VERSION}-linux-${rel_arch}/qbzd" /out/usr/bin/qbzd


FROM debian:bookworm-slim
ARG QBZD_VERSION

LABEL org.opencontainers.image.title="qbzd" \
      org.opencontainers.image.description="QBZ headless Qobuz playback daemon" \
      org.opencontainers.image.source="https://github.com/vicrodh/qbz" \
      org.opencontainers.image.version="${QBZD_VERSION}" \
      org.opencontainers.image.licenses="MIT"

# libasound2: the only shared library qbzd needs beyond libc.
# alsa-utils: `aplay -L` to discover DAC device names for `audio.device`.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libasound2 alsa-utils \
 && rm -rf /var/lib/apt/lists/*

COPY --from=fetch /out/usr/bin/qbzd /usr/bin/qbzd
COPY qbzd.toml.example /usr/share/qbzd/qbzd.toml.example
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY volume-bridge.sh /usr/local/bin/volume-bridge.sh

# Credential encryption derives its key from a machine identifier, trying
# /etc/machine-id first. Debian images ship that file empty, which would make
# the daemon fall back to $HOSTNAME — a value Docker regenerates on every
# `docker compose up --force-recreate`, silently invalidating the stored
# session. A fixed id keeps the key stable; per-install uniqueness still comes
# from the random salt persisted in the config volume.
RUN printf '%s\n' 'a7f3c1e0b45d4f18a9c2d6e80f3b7c51' > /etc/machine-id \
 && chmod 0444 /etc/machine-id \
 && useradd --uid 1000 --no-create-home --home-dir /data --shell /usr/sbin/nologin qbzd \
 && mkdir -p /data && chown qbzd:qbzd /data

# The daemon keeps a profile fully separate from the desktop app:
# $XDG_CONFIG_HOME/qbzd, $XDG_DATA_HOME/qbzd, $XDG_CACHE_HOME/qbzd. Pointing
# all three under /data puts config, credentials, databases and cache in the
# single mounted volume.
ENV HOME=/data \
    XDG_CONFIG_HOME=/data/config \
    XDG_DATA_HOME=/data/share \
    XDG_CACHE_HOME=/data/cache \
    QBZD_MPRIS=0

EXPOSE 8182
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD qbzd ping --json || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["qbzd", "run"]
