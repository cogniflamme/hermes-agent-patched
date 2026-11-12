# hermes-agent-patched: the official Hermes Agent image (Nous Research, MIT)
# with security fixes upstream has not shipped yet. Unofficial.
#
# Every change is listed in README.md with the advisory it closes, and is
# dropped once an upstream release carries the fix. BASE is the upstream image
# pinned by digest (upstream.env).
ARG BASE
# The multi-arch INDEX digest (not a per-architecture one): arm64 builds need it.
ARG FETCH=docker.io/library/debian:trixie-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4

# ---- fetch: downloads and signature checks, so the image gains no curl/gpg.
FROM ${FETCH} AS fetch
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# Docker's apt signing key, checked against its published fingerprint.
ARG DOCKER_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
# npm release tarball, by sha256 (= the registry's sha512 integrity, checked when pinned).
ARG NPM_VERSION=12.2.1
ARG NPM_SHA256=228bd64aaef23270dbdbd2cf3d5ef5c467602ef38c4066246cef1984adab9a67
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg unzip >/dev/null
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
# Chrome for Testing (chrome.env), by sha256 for this architecture. Used by
# step 2 only while it is newer than Debian's Chromium. Widevine (Google's
# proprietary DRM module, nothing an agent needs) is removed here, before it
# reaches any image layer; so is the setuid sandbox helper Hermes never uses.
ARG TARGETARCH
ARG CFT_VERSION
ARG CFT_SHA256_AMD64
ARG CFT_SHA256_ARM64
RUN case "${TARGETARCH}" in \
      amd64) plat=linux64 sum=${CFT_SHA256_AMD64} ;; \
      arm64) plat=linux-arm64 sum=${CFT_SHA256_ARM64} ;; \
      *) echo "no Chrome for Testing for ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && [ -n "${CFT_VERSION}" ] && [ -n "$sum" ] \
 && curl -fsSL --retry 3 -o /cft.zip \
      "https://storage.googleapis.com/chrome-for-testing-public/${CFT_VERSION}/${plat}/chrome-${plat}.zip" \
 && echo "$sum  /cft.zip" | sha256sum -c - \
 && mkdir /cft && unzip -q /cft.zip -d /cft && mv "/cft/chrome-${plat}" /cft/chrome \
 && rm -rf /cft/chrome/WidevineCdm /cft/chrome/chrome_sandbox \
 && [ -z "$(find /cft -iname '*widevine*')" ] \
 && printf '%s' "${CFT_VERSION}" > /cft/VERSION && rm /cft.zip

# ---- the image
FROM ${BASE}
# pipefail: a failing command before a pipe fails the build. Checks for "nothing
# left" use [ -z "$(...)" ], not `! ... | grep -q`, which SIGPIPE can invert.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive

# 1. Debian: every security fix in trixie-security (e.g. libbrotli1
#    1.1.0-2+deb13u1, CVE-2026-111497, CISA KEV), plus Debian's Chromium,
#    which follows Chrome stable security releases (sometimes days behind:
#    step 2 then swaps in Chrome for Testing and keeps only its libraries).
RUN apt-get update -qq \
 && apt-get upgrade -y -qq \
 && apt-get install -y -qq --no-install-recommends chromium fonts-liberation \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' libbrotli1)" ge 1.1.0-2+deb13u1

# 2a. The newer Chromium wins. Debian's when it has caught up; else Chrome
#    for Testing (chrome.env), e.g. 157.0.8103.78 on 2026-11-12 while Debian
#    had 156.0.8078.79 (CVE-2026-125350, CISA KEV, fixed in 157.0.8103.50).
#    Debian's package is then purged but every library it pulled in stays
#    (marked manual), which is also what Chrome's deb.deps lists, so no
#    vulnerable chromium package is left for scanners or for anyone to run.
#    Either way /usr/bin/chromium is the browser. For Chrome for Testing it is
#    a small launcher (patches/chromium-launcher) keeping what Debian's
#    launcher does that matters in a container: --disable-dev-shm-usage when
#    /dev/shm is small (Docker's default is 64 MB; without it pages crash).
COPY --from=fetch /cft /opt/chrome-for-testing
COPY patches/chromium-launcher /opt/chrome-for-testing/chromium-launcher
RUN deb=$(dpkg-query -W -f='${Version}' chromium) \
 && cft=$(cat /opt/chrome-for-testing/VERSION) \
 && if dpkg --compare-versions "${deb%%-*}" ge "$cft"; then \
      echo "Chromium: Debian ${deb} (>= Chrome for Testing ${cft})"; \
      rm -rf /opt/chrome-for-testing; \
    else \
      echo "Chromium: Chrome for Testing ${cft} (Debian has ${deb})"; \
      deps=$(apt-cache depends --installed --no-recommends --no-suggests chromium chromium-common \
             | awk '/^ *(Pre)?Depends:/ {print $2}' | grep -v '^<' | grep -vx 'chromium-common' | sort -u); \
      apt-mark manual $deps >/dev/null; \
      apt-get purge -y -qq chromium chromium-common >/dev/null; \
      cp /opt/chrome-for-testing/chromium-launcher /usr/bin/chromium; chmod 0755 /usr/bin/chromium; \
    fi \
 && /usr/bin/chromium --version \
 && { [ ! -d /opt/chrome-for-testing ] \
      || [ -z "$(ldd /opt/chrome-for-testing/chrome/chrome | grep 'not found')" ]; }

# 2b. Chrome: Hermes bundles Chrome for Testing 145.0.7632.6 (pinned in its
#    pm/lock.json up to v0.22.6 at least; four CISA KEV remote code execution
#    bugs, ~1,700 findings, and Hermes runs it with --no-sandbox in
#    containers). Each bundled chrome/chromium binary becomes a link to
#    /usr/bin/chromium (2a), so every way a Hermes version resolves its browser
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
