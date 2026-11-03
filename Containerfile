# hermes-agent-patched: the official Hermes Agent image (Nous Research, MIT)
# with security fixes upstream has not shipped yet. Unofficial.
#
# Every change is listed in README.md with the advisory it closes, and is
# dropped once an upstream release carries the fix. BASE is the upstream image
# pinned by digest (upstream.env).
ARG BASE
ARG FETCH=docker.io/library/debian:trixie-slim@sha256:1e1a22175fbf1b32157ddaf0219e1db4e5401fab2b94ed285add64d18587cd2d

# ---- fetch: downloads and signature checks, so the image gains no curl/gpg.
FROM ${FETCH} AS fetch
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# Docker's apt signing key, checked against its published fingerprint.
ARG DOCKER_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
# npm release tarball, by sha256 (= the registry's sha512 integrity, checked when pinned).
ARG NPM_VERSION=12.2.1
ARG NPM_SHA256=228bd64aaef23270dbdbd2cf3d5ef5c467602ef38c4066246cef1984adab9a67
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg >/dev/null
RUN curl -fsSL https://download.docker.com/linux/debian/gpg -o /docker.asc \
 && gpg --show-keys --with-colons /docker.asc | grep -qx "fpr:::::::::${DOCKER_KEY_FPR}:" \
 && gpg --dearmor -o /docker.gpg /docker.asc
# undici for npm's bundle: npm 12.2.1 still ships 6.29.0 (TLS validation bypass,
# GHSA-2m5v-pch6-74hx, and two DoS).
ARG UNDICI_VERSION=6.29.1
ARG UNDICI_SHA256=29c4b8e0b2d86cb8795571c1959012ce057a14ecfd34858335f47c31e770a04f
RUN curl -fsSL -o /npm.tgz "https://registry.npmjs.org/npm/-/npm-${NPM_VERSION}.tgz" \
 && echo "${NPM_SHA256}  /npm.tgz" | sha256sum -c - \
 && curl -fsSL -o /undici.tgz "https://registry.npmjs.org/undici/-/undici-${UNDICI_VERSION}.tgz" \
 && echo "${UNDICI_SHA256}  /undici.tgz" | sha256sum -c -

# ---- the image
FROM ${BASE}
# pipefail: a failing command before a pipe fails the build. Checks for "nothing
# left" use [ -z "$(...)" ], not `! ... | grep -q`, which SIGPIPE can invert.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive

# 1. Debian: every security fix in trixie-security (e.g. libbrotli1
#    1.1.0-2+deb13u1, CVE-2026-111497, CISA KEV), plus Debian's Chromium,
#    which follows Chrome stable security releases.
RUN apt-get update -qq \
 && apt-get upgrade -y -qq \
 && apt-get install -y -qq --no-install-recommends chromium fonts-liberation \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' libbrotli1)" ge 1.1.0-2+deb13u1

# 2. Chrome: Hermes bundles Chrome for Testing 145.0.7632.6 (pinned in its
#    pm/lock.json up to v0.22.6 at least; four CISA KEV remote code execution
#    bugs, ~1,700 findings, and Hermes runs it with --no-sandbox in
#    containers). Each bundled chrome/chromium binary becomes a link to
#    Debian's Chromium, so every way a Hermes version resolves its browser
#    (pm's record, the baked path files, AGENT_BROWSER_EXECUTABLE_PATH) lands
#    on the patched one: v0.22.5 reads agent-browser-executable-path, v0.22.6
#    chromium-executable-path; both are written.
RUN set -e; for dir in /opt/hermes/tools/chromium-[0-9]*; do \
      [ -d "$dir" ] || continue; \
      bins=$(find "$dir" -type f \( -name chrome -o -name chromium \) -perm -u+x -printf '%P\n'); \
      [ -n "$bins" ]; \
      find "$dir" -mindepth 1 -maxdepth 1 ! -name INSTALLATION_COMPLETE -exec rm -rf {} +; \
      for b in $bins; do mkdir -p "$(dirname "$dir/$b")" && ln -s /usr/bin/chromium "$dir/$b"; done; \
    done \
 && mkdir -p /etc/hermes \
 && printf '%s' /usr/bin/chromium > /etc/hermes/agent-browser-executable-path \
 && printf '%s' /usr/bin/chromium > /etc/hermes/chromium-executable-path \
 && [ -z "$(find /opt/hermes/tools -type f \( -name chrome -o -name chromium \))" ] \
 && /usr/bin/chromium --version

# 3. Python packages in Hermes' venv (patches/python-requirements.txt), only
#    those this Hermes ships (patches/select.py), with the uv Hermes ships;
#    their old wheels leave Hermes' uv cache.
COPY patches/python-requirements.txt patches/select.py /tmp/patched/
RUN uv=$(find /opt/hermes/tools -name uv -type f -perm -u+x -print -quit) && [ -n "$uv" ] \
 && /opt/hermes/.venv/bin/python /tmp/patched/select.py /tmp/patched/python-requirements.txt > /tmp/patched/req.txt \
 && "$uv" pip install -q --python /opt/hermes/.venv/bin/python --no-deps --no-cache \
      --require-hashes --only-binary :all: -r /tmp/patched/req.txt \
 && sed -n 's/==.*//p' /tmp/patched/req.txt | xargs -r "$uv" cache clean -q --cache-dir /opt/hermes/uv-cache \
 && rm -rf /tmp/patched

# 4. Docker CLI: Debian's docker-cli 26.1.5 is built with Go 1.24.4 (3
#    Critical, 33 High in the Go standard library). Docker's own signed
#    repository has current builds. Hermes uses it for the docker terminal
#    backend (needs a socket mounted).
COPY --from=fetch /docker.gpg /etc/apt/keyrings/docker.gpg
RUN echo "deb [signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update -qq \
 && apt-get purge -y -qq docker-cli \
 && apt-get install -y -qq --no-install-recommends docker-ce-cli \
 && rm /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && docker --version

# 5. npm: the two copies Hermes ships (its own npm-12.0.2 and the one bundled
#    with Node) bundle old undici, ip-address, brace-expansion, tar and
#    postcss-selector-parser. Replaced in place with the npm release above;
#    the directory names (pm's records) stay.
COPY --from=fetch /npm.tgz /undici.tgz /tmp/
RUN for d in /opt/hermes/tools/npm-*/lib/node_modules/npm /opt/hermes/tools/node-*/lib/node_modules/npm; do \
      [ -d "$d" ] || continue; rm -rf "$d" && mkdir "$d" \
      && tar xzf /tmp/npm.tgz -C "$d" --strip-components=1 --no-same-owner \
      && rm -rf "$d/node_modules/undici" && mkdir "$d/node_modules/undici" \
      && tar xzf /tmp/undici.tgz -C "$d/node_modules/undici" --strip-components=1 --no-same-owner; \
    done \
 && rm /tmp/npm.tgz /tmp/undici.tgz \
 && test "$(npm --version)" = 12.2.1 \
 && npm view undici@6.29.1 version >/dev/null

# 6. Photon platform sidecar: undici 7.30.0 (pinned in its overrides) and
#    zod 4.5.4 raised to their fixed releases.
# hadolint ignore=DL3003
RUN cd /opt/hermes/plugins/platforms/photon/sidecar \
 && npm pkg set overrides.undici=7.30.1 overrides.zod=4.6.6 \
 && npm install --no-audit --no-fund --omit=dev --loglevel=error \
 && test "$(node -p 'require("./node_modules/undici/package.json").version')" = 7.30.1 \
 && [ -z "$(find node_modules -path '*/zod/package.json' -exec grep -l '"version": "4.5' {} +)" ] \
 && node --input-type=module -e "await import('spectrum-ts')" \
 && npm cache clean --force --loglevel=error

LABEL org.opencontainers.image.title="hermes-agent-patched" \
      org.opencontainers.image.description="Unofficial: Hermes Agent with security fixes not yet upstream" \
      org.opencontainers.image.licenses="MIT"
