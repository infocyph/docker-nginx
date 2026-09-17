# docker-nginx — Hardening, Local Routing & Release Plan

## Status

Planning branch: `plan/docker-nginx-hardening`

Baseline:

- Repository: `infocyph/docker-nginx`
- Default branch: `main`
- Current baseline release: `0.3.21`
- Current base image: `nginx:alpine`
- Runtime role: LocalDevStack edge proxy / local TLS termination / service router
- Lower-layer dependency already completed: `infocyph/runner:0.5`
- Shared foundations already completed:
  - Scriptomatic canonical branch: `main`
  - Toolset stable release installer: latest release asset with checksum verification
  - Runner `0.5` hardened CI/publish pattern

This plan supersedes the earlier ecosystem-only Nginx draft in LocalDevStack and the first version of this branch plan. It now includes a full review of the current `docker-nginx` codebase, its generated Nginx includes, the current LocalDevStack Nginx Compose contract, and the current `docker-tools` Nginx templates.

---

# 1. Goal

Harden `docker-nginx` as the stable HTTP/TLS edge for LocalDevStack without turning it into a general-purpose control plane.

Nginx should continue to own:

1. local HTTP -> HTTPS routing;
2. local TLS termination with LocalDevStack-managed certificates;
3. generated PHP/Apache/Node/project vhosts;
4. reserved LocalDevStack convenience hosts;
5. WebSocket/HMR, SSE and streaming proxy behavior;
6. safe recovery from temporarily invalid generated vhosts;
7. routing to optional infrastructure such as the local LLM service.

Nginx must not own:

- certificate issuance;
- project/service lifecycle;
- model lifecycle;
- database lifecycle;
- Docker orchestration;
- LocalDevStack service selection;
- Ollama model installation or model storage.

Those responsibilities remain in `docker-tools`, `docker-llm-sm` and LocalDevStack.

---

# 2. Architecture invariants

Preserve these contracts unless a test proves they are wrong:

- Nginx exposes only ports `80` and `443`.
- `nginx:alpine` remains the rolling upstream base. Do not pin it to an old Nginx/Alpine release.
- LocalDevStack owns and mounts TLS certificates, private keys and root CA material.
- Generated project vhosts remain hot-reloadable.
- Project/service routing uses Docker DNS/service names instead of static IP assumptions.
- Missing optional upstream containers must not prevent Nginx startup.
- `LOCALHOST_ROUTES` remains additive and cannot override reserved LocalDevStack hosts.
- Existing PHP-FPM, PHP-via-Apache, Node, WebSocket/HMR and opt-in streaming behavior remains compatible.
- Runtime scripts that can be POSIX `sh` should remain POSIX `sh`; Bash should remain only where its features are actually used.
- Nginx remains a small edge image. Do not move LocalDevStack administration or orchestration into it.
- Rolling upstream behavior is handled through permanent CI and observable release artifacts rather than pretending mutable inputs are reproducible.

---

# 3. Codebase review — concrete findings

The current code is small and understandable, but the review found several real issues that should be addressed in this cycle rather than deferred.

## 3.1 Dependency acquisition is still mutable and weakly validated

Current Dockerfile behavior:

- `Scriptomatic/master` is fetched with remote `ADD`;
- `Toolset/main/ChromaCat/chromacat` is fetched with remote `ADD`;
- no bounded download retry/timeout exists;
- the Toolset checksum-verifying installer is not used.

Required change:

- Scriptomatic: `master` -> `main`;
- Toolset: raw `main` file -> latest stable release installer;
- use `curl` with bounded retries/timeouts;
- validate non-empty downloads and shell syntax;
- verify `chromacat --version`;
- keep the current rolling-source policy explicit and observable.

## 3.2 The convenience router currently does not explicitly preserve the client Host header

`/etc/nginx/proxy_params` intentionally does not set the upstream `Host` header. This is correct for the shared include because current `docker-tools` project templates set `Host` explicitly for Node, Apache and fixed-IP proxy modes.

However, `render-locals.sh` uses the shared include without an explicit:

```nginx
proxy_set_header Host $host;
```

Therefore the reserved convenience router can expose Nginx's default upstream Host behavior instead of the requested local hostname.

Required change:

- keep `/etc/nginx/proxy_params` neutral;
- set `proxy_set_header Host $host;` explicitly in the convenience router and the dedicated LLM route;
- test the upstream-observed `Host` header.

Do not globally add `Host` to `proxy_params`, because the existing project templates deliberately override it.

## 3.3 Convenience routes currently omit the generated timeout include

`proxy-params.sh` generates:

```text
/etc/nginx/proxy_timeouts
```

with dev-friendly connect/send/read timeouts, but `render-locals.sh` does not include it.

Consequences:

- long admin operations use Nginx defaults instead of the documented/generated values;
- `/api/tail` can be closed by the default proxy read timeout during idle periods;
- a future LLM route could time out unexpectedly unless it gets dedicated timeout handling.

Required change:

- include `/etc/nginx/proxy_timeouts` for appropriate convenience routes;
- explicitly test idle SSE/log-tail behavior;
- explicitly test long LLM generation behavior.

## 3.4 WebSocket headers are currently applied to every convenience request

The current convenience router includes `/etc/nginx/proxy_websocket` globally. That include sets:

```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
```

and the current map resolves a non-upgrade request to `Connection: close`.

This works functionally, but it unnecessarily disables upstream HTTP/1.1 keepalive for ordinary non-WebSocket convenience traffic.

Required change:

- preserve WebSocket compatibility;
- stop forcing `Connection: close` on ordinary requests;
- prefer a conditional map where a real upgrade receives `upgrade` and a normal request omits the `Connection` header;
- test both WebSocket upgrade and normal keepalive-safe HTTP behavior.

Because the rolling Nginx line can change upstream proxy defaults, keep this behavior explicit and covered by tests.

## 3.5 The generic proxy include forwards spoofable vendor-IP headers

Current `/etc/nginx/proxy_params` forwards incoming:

- `CF-Connecting-IP`;
- `True-Client-IP`;
- `Fastly-Client-IP`.

For this LocalDevStack edge, these values are not coming from a trusted Cloudflare/Fastly boundary. A client can provide them directly and they are forwarded unchanged.

Required change:

- remove these vendor-specific passthrough headers from the generic proxy contract unless a concrete trusted LocalDevStack use case exists;
- keep canonical `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Host`, `X-Forwarded-Proto`, `X-Forwarded-Port` and `X-Request-ID`.

If vendor headers are ever needed, add an explicit opt-in include rather than making them global defaults.

## 3.6 FastCGI newline/idempotency logic is flawed

`fcgi-params.sh` checks the final byte through command substitution. Bash strips trailing newlines from command substitution, so the current newline check can append an extra newline even when the file already ends correctly.

The script also conditionally avoids duplicate keys but does not distinguish between:

- a truly missing FastCGI parameter; and
- an upstream `nginx:alpine` parameter that already exists with a different value.

Required change:

- replace the EOF-newline check with a byte-safe implementation or remove the need for append-oriented mutation;
- test repeat execution before final image assembly and require byte-identical output after the first successful generation;
- explicitly audit current upstream `fastcgi_params` keys/values on every rolling-base CI build;
- do not silently create duplicate `fastcgi_param` keys.

Prefer additive custom parameters over overriding upstream defaults unless a framework compatibility test proves an override is required.

## 3.7 Build helper scripts self-delete

Both build-time generator scripts delete themselves with `rm -f -- "$0"`.

That works during the current Docker build, but it makes the build contract surprising and complicates local/debug testing.

Required change:

- stop scripts from deleting themselves;
- make lifecycle ownership explicit in the Dockerfile;
- after generation succeeds, remove build-only generators in the Dockerfile if they should not remain in the runtime image;
- alternatively use a small helper stage if doing so remains simpler than the current pattern.

## 3.8 Banner initialization has two different code paths

The profile hook computes `NGINX_VERSION`, while the `.bashrc` append uses `${NGINX_VERSION}` without computing it there.

Required change:

- use one small, deterministic interactive banner hook pattern;
- compute the version in the same hook that displays it;
- follow the simpler `runner 0.5` convention where practical;
- ensure non-interactive shells do not emit banners.

## 3.9 `locals.conf` injection depends on the upstream `nginx.conf` layout

The Dockerfile uses `sed` to insert:

```nginx
include /etc/nginx/locals.conf;
```

before the official `conf.d/*.conf` include.

With a rolling base, the upstream file layout may eventually change. The current build does not strongly assert that the insertion actually occurred after `sed` runs.

Required change:

- keep the separate `/etc/nginx/locals.conf` design because `/etc/nginx/conf.d` is mounted by LocalDevStack;
- after mutation, explicitly verify the include exists exactly once;
- fail the image build if the upstream layout no longer supports the insertion;
- test the final assembled `nginx.conf`, not only individual fragments.

## 3.10 Official `default.conf` should not leak into a fresh mounted vhost volume

The official Nginx Alpine image normally contains `/etc/nginx/conf.d/default.conf`. LocalDevStack mounts a named volume at `/etc/nginx/conf.d`, and Docker can seed a new named volume from image contents.

Required change:

- remove the official default vhost from the image during build before LocalDevStack can initialize a fresh vhost volume from it;
- add a test proving the runtime image has no upstream sample/default site;
- add a LocalDevStack migration note for already-existing named volumes that may still contain an old `default.conf`.

Do not make the entrypoint blindly delete an arbitrary user-created `default.conf` from an existing mounted volume.

## 3.11 HTTP unknown-host handling is not explicit

A server with a finite `server_name` list still becomes the default listener when no explicit default server exists. Therefore an unknown Host can fall into the first `listen 80` server rather than being truly excluded.

The current redirect uses:

```nginx
return 301 https://$host$request_uri;
```

Required change:

- add an explicit default/catch-all HTTP server that rejects unknown hosts;
- add an explicit TLS default/catch-all server using the LocalDevStack certificate and returning a small rejection response;
- keep routed convenience hosts in dedicated non-default servers;
- test unknown/malformed Host behavior and ensure there is no arbitrary-host redirect.

A local-only edge is still expected to have deterministic Host routing.

## 3.12 `LOCALHOST_ROUTES` validation is syntactic but incomplete

Current validation accepts a broad `[a-z0-9.-]+` hostname and any numeric port string.

Required change:

- require valid DNS-label structure;
- require the user route to remain inside the intended `.localhost` namespace unless a future explicit contract expands it;
- reject empty labels, leading/trailing hyphens and malformed dots;
- validate the upstream port range as `1..65535`;
- preserve Docker DNS/service-name compatibility;
- keep predefined hosts non-overridable;
- keep deterministic first-user-entry wins behavior for duplicate user hosts;
- add hostile/malformed input tests.

Do not use `eval` or shell interpolation of route values.

## 3.13 `$log_host` is currently dead configuration

`render-locals.sh` generates a safe `$log_host` map but the convenience router writes to fixed:

```text
localhost.access.log
localhost.error.log
```

Required change:

- remove the unused map unless per-host log files are actually introduced;
- do not keep dead generated config;
- prefer the simpler combined convenience log unless a concrete operational need requires per-host logs.

## 3.14 `client_max_body_size 10G` should become an explicit contract

The current convenience server accepts up to `10G`. That may be intentional for local development, but it is currently a magic value.

Required change:

- preserve compatibility for this release unless tests/downstream usage justify a reduction;
- document it;
- preferably make the convenience-route body-size value configurable through a strictly validated environment value while retaining the current value as the compatibility default;
- do not silently lower the limit in a hardening release.

## 3.15 Entrypoint auto-restore can oscillate and misses a replacement-file case

The current entrypoint can repeatedly:

1. restore an unchanged invalid file;
2. fail validation;
3. disable it again;
4. retry later.

There is also a replacement-file edge case: if an external generator creates a corrected active `foo.conf` while `foo.conf.disabled` still exists, `restore_disabled_confs` skips the disabled file because the target exists. The later reload decision currently depends on the disabled-file count decreasing, so a valid replacement may not trigger the intended reload path.

Required change:

- redesign quarantine retry around configuration state changes rather than a blind periodic restore;
- do not retry an unchanged quarantined file forever;
- detect a changed quarantined file or a newly-created replacement active file;
- if the active configuration becomes valid, reload Nginx even when the disabled-file count itself did not decrease;
- keep stale quarantined files as diagnostics or archive them deterministically; do not silently delete user configuration;
- preserve clear stderr diagnostics.

A small fingerprint based on file metadata/content hash is preferred over exponential retry if it keeps the implementation simpler and deterministic.

## 3.16 Entrypoint numeric controls are not fully validated

`AUTO_RESTORE_INTERVAL_SECONDS` has basic validation; `MAX_DISABLE_ATTEMPTS` does not.

Required change:

- validate both as bounded positive integers;
- preserve compatibility defaults unless there is a strong reason to change them;
- fail clearly or fall back predictably for invalid values;
- avoid shell arithmetic errors under `set -e`.

## 3.17 Entrypoint background work should be tied to actual Nginx daemon startup

The entrypoint currently prepares the configuration and can start the background auto-restore loop before executing any supplied command.

Required change:

- retain configuration rendering/validation where useful;
- start the long-lived restore/reload helper only when the container is actually launching the Nginx daemon;
- do not leave a background Nginx-management loop running for diagnostic commands or an interactive shell;
- preserve final `exec "$@"` so Nginx receives container signals correctly.

## 3.18 Healthcheck should represent the running edge, not only config syntax

Current healthcheck is only:

```text
nginx -t
```

This proves configuration syntax but not that the expected Nginx master is alive.

Required change:

- add a small `nginx-healthcheck` helper or equivalent command that checks:
  - Nginx master/process liveness;
  - current config syntax;
- keep it network-independent so optional upstream services do not make Nginx unhealthy;
- do not healthcheck `llm-sm`, databases, mail or other optional dependencies from the Nginx container.

---

# 4. Foundation contracts to consume

## 4.1 Scriptomatic

Canonical source:

```text
https://raw.githubusercontent.com/infocyph/Scriptomatic/main/bash/banner.sh
```

Requirements:

- remove `Scriptomatic/master`;
- fetch with `curl -fsSL` plus bounded retry/connect timeout behavior matching `runner 0.5`;
- verify the downloaded file is non-empty;
- `bash -n` before installation/use;
- record the resolved Scriptomatic `main` revision and installed banner SHA-256 in publish summaries;
- do not invent a release/tag requirement that Scriptomatic does not provide.

## 4.2 Toolset

Canonical installer:

```text
https://github.com/infocyph/Toolset/releases/latest/download/install.sh
```

Requirements:

- use the latest stable Toolset release through the checksum-verifying installer;
- do not pin the Dockerfile to Toolset `2.0`; `2.0` is the current published release, while the contract is latest stable;
- verify installer file non-empty;
- `bash -n` the installer;
- install only `chromacat` into `/usr/local/bin`;
- run `chromacat --version` during image build;
- remove the temporary installer afterward;
- record resolved Toolset release/chromacat version in CI/publish summaries.

## 4.3 Rolling base

Keep exactly:

```dockerfile
FROM nginx:alpine
```

Compensate for the rolling base with:

- permanent CI;
- `pull: true` fresh candidate builds;
- actual image/runtime/config smoke tests;
- amd64 and arm64 gates;
- publish summaries recording resolved Nginx and Alpine versions;
- scheduled `latest` refresh from the latest stable docker-nginx release source.

Do not claim byte-for-byte reproducibility for a build that intentionally consumes mutable upstream inputs.

---

# 5. Local LLM endpoint

This remains a required feature of the release.

## 5.1 Canonical route

Reserve:

```text
llm.localhost -> llm-sm:11434
```

User-facing access:

```text
https://llm.localhost/api/chat
https://llm.localhost/api/generate
https://llm.localhost/api/tags
https://llm.localhost/api/version
https://llm.localhost/v1/...
```

Keep:

```text
admin.localhost -> server-tools:9911
```

Do not overload `admin.localhost` with Ollama.

## 5.2 Direct Ollama access remains outside this image

Nginx must not:

- listen on `11434`;
- expose `11434`;
- embed Ollama.

If LocalDevStack later exposes:

```text
http://127.0.0.1:11434
```

that belongs to the `llm-sm` Compose service.

## 5.3 Use a dedicated LLM TLS server block

Preferred implementation:

- keep LLM route metadata in the predefined route set for reservation/audit purposes;
- include `llm.localhost` in HTTP -> HTTPS redirect handling;
- exclude `llm.localhost` from the generic convenience TLS proxy server;
- render one dedicated `server_name llm.localhost` TLS server.

This avoids complex host-conditional buffering behavior and makes LLM streaming policy obvious.

Do not render duplicate TLS `server_name llm.localhost` blocks.

## 5.4 LLM proxy behavior

Required directives/semantics:

```nginx
proxy_http_version 1.1;
proxy_set_header Host $host;
proxy_set_header Connection "";
proxy_buffering off;
proxy_request_buffering off;
proxy_max_temp_file_size 0;
gzip off;
```

Also apply:

- canonical forwarding/request-ID headers;
- explicit dev-friendly connect/send/read timeouts;
- `proxy_redirect off`;
- lazy Docker DNS resolution.

Do not force WebSocket headers. Native Ollama token output is streamed HTTP/NDJSON; OpenAI-compatible streaming is HTTP/SSE style.

## 5.5 Optional-service DNS behavior

`llm-sm` is optional. Nginx must start normally when it is absent.

Continue runtime Docker DNS resolution with:

```text
127.0.0.11
```

and variable/lazy `proxy_pass` or an equivalent runtime-resolution mechanism.

Improve local recovery latency:

- use a short resolver validity window appropriate for dynamic local containers rather than keeping a failed lookup effectively stale for a long period;
- retain a short resolver timeout;
- test this sequence explicitly:
  1. start Nginx without `llm-sm`;
  2. request `llm.localhost` and receive an upstream error;
  3. start mock `llm-sm`;
  4. verify the same Nginx instance begins routing successfully without reload/rebuild.

Do not resolve optional service names in shell and write static container IPs.

## 5.6 CORS

Do not add permissive wildcard CORS headers in Nginx.

If browser-based local tools need cross-origin Ollama access, define that policy in the LLM/Ollama runtime contract rather than weakening all edge routes.

---

# 6. File-by-file implementation plan

## 6.1 `Dockerfile`

Required work:

1. Keep `FROM nginx:alpine`.
2. Add only packages genuinely required by runtime/build helper installation; include `curl` and `ca-certificates` for controlled dependency acquisition.
3. Run `update-ca-certificates` when appropriate.
4. Replace remote `ADD` dependency downloads with validated `curl` flows.
5. Scriptomatic `master` -> `main`.
6. Toolset raw `main` -> latest stable installer.
7. Verify `show-banner` syntax and `chromacat --version`.
8. Keep repository-owned runtime scripts explicit.
9. Generate proxy/FastCGI includes deterministically.
10. Remove build-only generators explicitly after successful generation if they are not runtime dependencies.
11. Remove official `/etc/nginx/conf.d/default.conf` from the image.
12. Preserve `/etc/nginx/locals.conf` outside the mounted `conf.d` directory.
13. Verify `locals.conf` is included exactly once in the final `nginx.conf`.
14. Preserve `/etc/share/rootCA`, `/etc/mkcert`, `/var/log/nginx` paths.
15. Keep `EXPOSE 80 443` only.
16. Add/retain a runtime healthcheck that checks Nginx liveness plus config syntax, not optional upstreams.
17. Keep Nginx foreground execution and clean signal behavior.
18. Simplify/fix interactive banner initialization.
19. Let publish workflow add revision/version OCI labels.
20. Record resolved Nginx/Alpine/helper versions in CI.

A multi-stage helper-fetch stage is allowed only if it reduces final-image dependencies without making the Dockerfile harder to maintain.

## 6.2 `scripts/fcgi-params.sh`

Required work:

1. Fix EOF newline detection.
2. Preserve one original backup only if in-place upstream-file augmentation remains.
3. Audit upstream `fastcgi_params` on every fresh rolling-base build.
4. Add only missing custom parameters; avoid duplicate keys.
5. Preserve framework HTTPS/request-ID awareness.
6. Preserve direct PHP-FPM compatibility.
7. Keep `/etc/nginx/fastcgi_streaming` opt-in.
8. Make generated streaming include atomic/deterministic.
9. Remove self-deletion.
10. Add an idempotency test requiring identical second-run output.
11. Validate representative PHP vhosts with `nginx -t`.

Do not redesign all `docker-tools` templates merely to avoid touching upstream `fastcgi_params` unless that redesign is clearly simpler and tested end-to-end.

## 6.3 `scripts/proxy-params.sh`

Required work:

1. Keep deterministic atomic generation.
2. Preserve first-backup behavior if still useful.
3. Remove untrusted vendor-IP header passthrough from generic defaults.
4. Preserve canonical forwarding headers and `X-Request-ID`.
5. Keep shared `proxy_params` neutral regarding upstream `Host`.
6. Keep `/etc/nginx/proxy_timeouts` explicit.
7. Keep normal buffering opt-in/default for normal project routes.
8. Keep streaming as a separate opt-in include.
9. Update WebSocket connection mapping so normal non-upgrade requests do not force `Connection: close`.
10. Preserve `proxy_h2_sanitize` for templates that need hop-by-hop response cleanup.
11. Keep CSP relaxation explicitly local-dev-only and opt-in.
12. Remove self-deletion.
13. Include `PROXY_H2_SANITIZE_FILE` in success output if status output is retained.
14. Fix stale/duplicate comments while touching the generator, but do not perform unrelated cosmetic churn.
15. Add generated-file content and idempotency tests.

## 6.4 `scripts/render-locals.sh`

Predefined routes remain:

```text
admin.localhost   -> server-tools:9911
webmail.localhost -> mailpit:8025
db.localhost      -> cloud-beaver:8978
ri.localhost      -> redis-insight:5540
me.localhost      -> mongo-express:8081
kibana.localhost  -> kibana:5601
```

Add:

```text
llm.localhost     -> llm-sm:11434
```

Required work:

1. Keep reserved routes explicit and non-overridable.
2. Tighten user-route hostname and port validation.
3. Keep `LOCALHOST_ROUTES` additive.
4. Keep route generation deterministic.
5. Keep atomic replace-on-change output.
6. Add explicit default/catch-all servers for unknown hosts.
7. Keep HTTP -> HTTPS for routed hosts.
8. Add `proxy_set_header Host $host` to the generic convenience proxy.
9. Include appropriate timeout policy in convenience routes.
10. Preserve `/api/tail` unbuffered behavior and test idle streaming.
11. Stop globally forcing WebSocket `Connection: close` semantics on normal traffic.
12. Render `llm.localhost` with dedicated streaming TLS behavior.
13. Keep lazy Docker DNS resolution for optional services.
14. Use a short DNS validity interval suitable for services that can start after Nginx.
15. Remove the unused `$log_host` map unless per-host logs are actually adopted.
16. Preserve `client_max_body_size 10G` compatibility or make it validated/configurable with `10G` as the compatibility default.
17. Review TLS cipher configuration against the current rolling OpenSSL/Nginx line.
18. Keep TLS 1.2 + 1.3.
19. Remove obsolete CBC/legacy cipher entries if modern-client compatibility tests pass; TLS 1.3 should rely on the current platform mechanism rather than pretending `ssl_ciphers` controls it.
20. Test unknown Host, malformed Host, invalid route input and reserved-host override attempts.
21. Test that missing optional services never make `nginx -t` fail.
22. Test upstream-observed Host/forwarding/request-ID headers.

## 6.5 `scripts/nginx-entrypoint.sh`

Required work:

1. Preserve timezone setup.
2. Preserve final `exec "$@"`.
3. Validate `MAX_DISABLE_ATTEMPTS`.
4. Validate/bound `AUTO_RESTORE_INTERVAL_SECONDS`.
5. Preserve opt-out controls for quarantine and auto-restore.
6. Keep unrelated/global Nginx errors fatal.
7. Quarantine only identifiable files under `/etc/nginx/conf.d`.
8. Detect read-only config mounts and fail clearly when quarantine would require mutation.
9. Replace blind periodic restore with change-aware retry.
10. Handle corrected replacement active files even when the old disabled artifact still exists.
11. Reload when configuration transitions from invalid/quarantined state to a valid active state.
12. Avoid unchanged invalid-file oscillation/log spam.
13. Start the long-lived restore helper only when launching the Nginx daemon.
14. Keep optional `llm-sm` absence completely outside quarantine logic.
15. Verify background-helper shutdown behavior.
16. Add multiple-invalid-file, attempt-limit, repair and signal tests.

## 6.6 New `scripts/nginx-healthcheck.sh` or equivalent

Prefer one tiny explicit healthcheck contract:

- verify the Nginx master PID/process is alive;
- run `nginx -t` quietly;
- return non-zero otherwise;
- never depend on optional application/upstream availability.

Use it from Docker `HEALTHCHECK` and from CI smoke tests.

---

# 7. TLS policy review

The current local TLS configuration is intentionally development-oriented, but rolling Nginx/OpenSSL means it should be tested rather than frozen indefinitely.

Required policy:

- TLS 1.2 and TLS 1.3 remain supported;
- no HSTS is added by default for LocalDevStack;
- certificate issuance remains outside this image;
- TLS configuration must pass current Nginx/OpenSSL syntax in permanent CI;
- simplify the TLS 1.2 cipher list to modern AEAD suites if browser/client compatibility tests pass;
- do not rely on `ssl_ciphers` as if it configures TLS 1.3 cipher suites;
- keep session settings only when current syntax supports them;
- do not introduce HTTP/3/QUIC in this hardening release.

---

# 8. CI — new `.github/workflows/check.yml`

Follow the current `runner 0.5` CI style.

## Triggers

- pushes to maintained branches;
- pull requests;
- manual dispatch.

## Workflow controls

- `permissions: contents: read`;
- concurrency per workflow/ref with `cancel-in-progress: true`;
- sensible job timeouts.

## Static/contract job

Use current compatible action majors, including `actions/checkout@v7`.

Run:

- `sh -n` for POSIX scripts;
- `bash -n` for Bash scripts;
- ShellCheck with the correct shell mode;
- actionlint;
- stale dependency contract checks;
- reject `Scriptomatic/master`;
- reject raw `Toolset/main` consumption;
- verify required image scripts/paths are represented by tests.

## amd64 runtime job

- `docker/setup-buildx-action@v4`;
- `docker/build-push-action@v7`;
- fresh `linux/amd64` build with `pull: true`;
- run full release gate against the built image.

Validate:

- Nginx version;
- Alpine version;
- `show-banner` syntax;
- `chromacat --version`;
- generated includes;
- no official `default.conf`;
- `locals.conf` included exactly once;
- healthcheck;
- clean SIGTERM/SIGQUIT-compatible container stop behavior.

## arm64 job

- `docker/setup-qemu-action@v4`;
- fresh `linux/arm64` image;
- startup/config/healthcheck smoke;
- verify architecture is `aarch64`;
- verify helper commands.

## Route/runtime integration job

Use small mock upstream containers, not real heavyweight services.

Validate:

- reserved convenience host routing;
- additive `LOCALHOST_ROUTES` routing;
- reserved override rejection;
- unknown-host rejection;
- HTTP -> HTTPS redirect;
- Host and forwarding headers;
- WebSocket upgrade;
- ordinary non-WebSocket request behavior;
- `/api/tail` streaming;
- LLM native and OpenAI-compatible paths;
- LLM incremental streaming;
- optional upstream missing at startup;
- late upstream start/DNS recovery.

## Invalid-vhost job/gate

Validate:

- one invalid file is quarantined;
- multiple invalid files are bounded;
- unrelated global errors remain fatal;
- unchanged invalid file does not thrash;
- changed/fixed disabled file can return;
- corrected replacement active file triggers valid reload behavior;
- read-only failure is explicit;
- helper shuts down with the container.

---

# 9. Tests and fixtures

Keep workflow YAML thin. Put behavior in repository test scripts.

Suggested structure:

```text
tests/
├── static.sh
├── dependency-contract.sh
├── generated-config.sh
├── render-locals.sh
├── image-smoke.sh
├── route-smoke.sh
├── websocket-smoke.sh
├── streaming-smoke.sh
├── llm-route-smoke.sh
├── invalid-vhost-smoke.sh
├── signal-smoke.sh
├── release-contract.sh
├── release-gate.sh
└── fixtures/
    ├── conf.d/
    └── mock-upstreams/
```

TLS fixtures should normally be generated during tests rather than committing reusable private keys.

`release-gate.sh` should be callable locally and from CI and should be the single final candidate gate before publishing.

---

# 10. Publish/release hardening

Replace the current small publish workflow with the hardened `runner 0.5` pattern adapted to the Nginx image.

## 10.1 Triggers

- GitHub release published;
- weekly scheduled refresh;
- manual dispatch.

Add:

```yaml
concurrency:
  group: docker-publish
  cancel-in-progress: false
```

and a sensible publish timeout.

## 10.2 Source selection

Release event:

- use the exact released docker-nginx tag;
- publish immutable version tag + `latest`.

Schedule/manual:

- resolve the latest stable published docker-nginx release source;
- rebuild it against current `nginx:alpine`, Scriptomatic `main` and latest stable Toolset;
- publish only `latest`.

Do not republish/overwrite historical version tags during scheduled refresh.

Explicitly reject draft/prerelease source for the stable scheduled `latest` path.

## 10.3 Image names

Keep explicit image targets:

```text
docker.io/infocyph/nginx
ghcr.io/infocyph/nginx
```

Do not rely on fragile repository-name string transformation when a fixed image name is already part of the LocalDevStack contract.

## 10.4 Candidate gates

Before registry push:

1. checkout exact source tag;
2. capture source SHA;
3. build fresh amd64 candidate with `pull: true` and preferably `no-cache: true` for release publication;
4. record resolved Nginx/Alpine/Scriptomatic/Toolset/chromacat values;
5. run full amd64 release gate;
6. build fresh arm64 candidate;
7. run arm64 runtime gate;
8. only then log in/publish.

## 10.5 Immutable release tags

Before a release event publishes `<version>`:

- verify the tag is absent from Docker Hub;
- verify the tag is absent from GHCR;
- fail closed on registry-inspection ambiguity;
- never overwrite an existing immutable release tag.

## 10.6 Current action majors

Follow the now-published runner pattern:

- `actions/checkout@v7`
- `docker/setup-qemu-action@v4`
- `docker/setup-buildx-action@v4`
- `docker/login-action@v4`
- `docker/metadata-action@v6`
- `docker/build-push-action@v7`
- `actions/attest@v4`

Keep action-major versions aligned with the shared ecosystem pattern when that pattern is upgraded later.

## 10.7 Multi-architecture

Publish:

```text
linux/amd64
linux/arm64
```

only after both candidate gates pass.

## 10.8 Supply-chain metadata

Publish:

- BuildKit provenance (`mode=max` where supported);
- SBOM;
- Docker Hub provenance attestation;
- GHCR provenance attestation;
- OCI source/revision/version labels.

## 10.9 Post-publish verification

After push:

- pull GHCR image by digest for `linux/amd64`;
- run health/config smoke against the actual pushed digest;
- inspect multi-platform manifest;
- summarize:
  - source release;
  - source SHA;
  - pushed digest;
  - platforms;
  - resolved Nginx version;
  - resolved Alpine version;
  - Scriptomatic revision/banner SHA;
  - Toolset release/chromacat version.

Docker Hub and GHCR should resolve to the same multi-platform content digest produced by the publish step.

---

# 11. `.dockerignore`, metadata and repository hygiene

## `.dockerignore`

Review against actual build context.

- keep `.git`, docs and unrelated local artifacts out of runtime build context;
- keep tests available to GitHub Actions from the checkout even if they are not sent to Docker build context;
- do not accidentally exclude repository-owned scripts used by `COPY`;
- do not expand ignores cosmetically.

## `.gitattributes`

Preserve LF behavior. Add explicit shell/YAML patterns only if cross-platform tests show a real need.

## `.gitignore`

Ignore only generated test artifacts/certificates if necessary.

## README

Add a real README after behavior is implemented and tested.

Document:

- image purpose;
- Docker Hub/GHCR names;
- ports `80`/`443`;
- LocalDevStack mounts;
- helper includes;
- predefined routes;
- `LOCALHOST_ROUTES` format and `.localhost` restriction;
- invalid-vhost quarantine controls;
- healthcheck semantics;
- rolling `latest` semantics;
- immutable release tags;
- supported architectures;
- `llm.localhost` examples;
- optional direct Ollama port being a LocalDevStack/`llm-sm` concern.

---

# 12. LocalDevStack integration follow-up

Do not implement these downstream orchestration changes inside `docker-nginx`, but keep them as explicit release gates.

After the Nginx image is published:

1. raise/pin LocalDevStack to the new Nginx release;
2. ensure LocalDevStack uses runner `0.5` or newer agreed baseline;
3. add optional `llm-sm` service/profile;
4. put Nginx and `llm-sm` on a shared Docker network with service-name DNS;
5. preserve Ollama model volume/storage outside Nginx;
6. optionally expose `127.0.0.1:11434` from `llm-sm`, not Nginx;
7. validate real `https://llm.localhost` against `infocyph/llm-sm`;
8. validate OpenAI-compatible clients against `/v1`;
9. validate PHP direct-FPM routes;
10. validate PHP-via-Apache routes;
11. validate Node/HMR/WebSocket routes;
12. validate admin/mail/database convenience routes;
13. inspect/clean legacy `lds_nginx_host` volume content for upstream `default.conf` where required;
14. remove static IP assignments only after the broader LocalDevStack DNS migration passes its own gates.

The Nginx release itself should already be DNS-safe before LocalDevStack removes static addresses.

---

# 13. Security / trust-boundary rules

Even though this is a local development edge:

- certificates remain LocalDevStack-owned;
- generated vhosts are config input, never shell input;
- never `eval` route/config values;
- quarantine only known Nginx config paths;
- reject unknown Host routing explicitly;
- do not forward untrusted CDN/vendor client-IP headers by default;
- missing services cause request-time upstream failures, not startup failure;
- do not expose Ollama publicly from this image;
- do not add wildcard CORS;
- keep CSP relaxation opt-in and clearly local-dev-only;
- do not add Docker socket access to Nginx;
- do not add an authentication gateway in this cycle.

---

# 14. Performance / developer experience

Priorities:

- fast startup;
- no waiting for optional services;
- atomic generated config updates;
- Docker DNS rather than static IP probing;
- immediate LLM/SSE streaming where requested;
- normal buffering for routes that benefit from it;
- preserve upstream keepalive on ordinary HTTP requests;
- keep WebSocket/HMR low latency;
- short DNS recovery for containers started after Nginx;
- no service mesh/control-plane complexity;
- no unnecessary heavy test dependencies or real LLM model downloads in Nginx CI.

---

# 15. Implementation order

## Phase 1 — CI baseline

1. add test tree and release gate;
2. add ShellCheck/actionlint/static contracts;
3. build current rolling image on amd64/arm64;
4. capture current routing/quarantine behavior with regression tests.

## Phase 2 — image/dependency cleanup

1. Scriptomatic `master` -> `main`;
2. Toolset raw `main` -> latest stable checksum-verifying installer;
3. validated `curl` acquisition;
4. remove official `default.conf`;
5. harden `locals.conf` injection postcondition;
6. fix banner initialization;
7. explicit build-helper lifecycle;
8. add healthcheck helper.

## Phase 3 — generated include hardening

1. fix FastCGI newline/idempotency;
2. audit upstream FastCGI key conflicts;
3. remove spoofable vendor proxy headers;
4. improve WebSocket non-upgrade connection semantics;
5. preserve timeout/buffer/streaming separation;
6. deterministic include tests.

## Phase 4 — convenience router hardening

1. tighten `LOCALHOST_ROUTES` validation;
2. add default unknown-host rejection;
3. explicit upstream Host preservation;
4. apply timeout policy;
5. preserve `/api/tail` streaming;
6. remove dead `$log_host` config;
7. review TLS/cipher policy;
8. validate body-size contract.

## Phase 5 — LLM route

1. reserve `llm.localhost`;
2. dedicated TLS streaming server;
3. lazy Docker DNS;
4. short late-start recovery window;
5. mock `/api/chat`, `/api/generate`, `/api/tags`, `/v1` tests;
6. no real model download in this repo.

## Phase 6 — entrypoint hardening

1. validate numeric controls;
2. replace blind restore loop with change-aware retry;
3. handle replacement-file recovery;
4. reload on valid state transition;
5. avoid non-Nginx background helper startup;
6. test read-only mounts, multiple bad files and signals.

## Phase 7 — publish hardening

1. runner-0.5-style current actions;
2. exact release-source handling;
3. stable scheduled/manual source resolution;
4. immutable version tags;
5. amd64 + arm64 candidate gates;
6. multi-arch publish;
7. SBOM/provenance/attestation;
8. post-push digest verification.

## Phase 8 — documentation/release

1. add README;
2. verify docs against actual behavior;
3. final release gate;
4. publish next docker-nginx release;
5. update LocalDevStack downstream.

---

# 16. Acceptance criteria

The work is complete only when all of the following are true:

1. `nginx:alpine` remains the rolling base.
2. Permanent CI builds against a freshly pulled base.
3. amd64 and arm64 build/runtime gates pass.
4. No `Scriptomatic/master` dependency remains.
5. Scriptomatic is consumed from `main` with bounded validated download behavior.
6. No raw Toolset `main` dependency remains.
7. Latest stable Toolset installer is used and `chromacat --version` passes.
8. Official Nginx `default.conf` is absent from the runtime image.
9. `/etc/nginx/locals.conf` is included exactly once.
10. FastCGI generation is deterministic/idempotent and has no duplicate/conflicting parameters introduced by this image.
11. Generic proxy headers no longer forward untrusted vendor-IP headers by default.
12. Project template Host overrides remain compatible.
13. Convenience routes explicitly forward the requested Host.
14. Normal non-WebSocket convenience traffic is not forced to `Connection: close`.
15. WebSocket/HMR behavior still passes.
16. `/api/tail` remains incrementally streaming and survives normal idle intervals.
17. Unknown hosts are rejected rather than falling into routed redirect/proxy behavior.
18. `LOCALHOST_ROUTES` validation is strict and reserved hosts cannot be overridden.
19. Optional unresolved upstreams do not make Nginx startup/config validation fail.
20. `llm.localhost` is reserved and maps to `llm-sm:11434`.
21. `https://llm.localhost/api/chat` streams incrementally.
22. `https://llm.localhost/api/generate` streams incrementally.
23. `https://llm.localhost/v1/...` proxies correctly.
24. LLM requests preserve body, Host and forwarding/request-ID headers correctly.
25. Nginx starts successfully with no `llm-sm` container.
26. Starting `llm-sm` later becomes usable without rebuilding/restarting Nginx after the intended short DNS recovery interval.
27. Nginx still exposes only ports `80/443`.
28. Direct `11434` exposure remains an `llm-sm`/LocalDevStack concern.
29. Invalid-vhost quarantine is bounded.
30. Unchanged bad config does not oscillate indefinitely.
31. A corrected replacement config can become active and trigger reload even if an old disabled artifact exists.
32. Read-only quarantine failure is explicit.
33. Background recovery helper is not started for unrelated diagnostic commands.
34. Container shutdown is clean.
35. Healthcheck validates Nginx liveness/config without depending on optional upstreams.
36. Release events cannot overwrite existing version tags in Docker Hub or GHCR.
37. Scheduled/manual refresh updates only `latest` from the latest stable docker-nginx release source.
38. Prerelease/draft sources do not become stable scheduled `latest` accidentally.
39. Published images support `linux/amd64` and `linux/arm64`.
40. SBOM and provenance are published.
41. Docker Hub and GHCR publication is based on the same multi-platform build digest.
42. The pushed artifact is verified by digest after publication.
43. Publish summary records source SHA and resolved rolling dependencies.
44. README matches actual runtime behavior.
45. Real `infocyph/llm-sm` integration passes downstream in LocalDevStack before the LocalDevStack AI profile is considered complete.

---

# 17. Explicit non-goals

Do not use this cycle to:

- rewrite LocalDevStack orchestration;
- move `mkcert`/CA generation into Nginx;
- build an Nginx UI/control panel;
- add Docker socket access;
- manage Ollama models;
- embed `docker-llm-sm`;
- expose Nginx port `11434`;
- add a generic auth gateway;
- add wildcard CORS;
- convert every route to unbuffered streaming;
- remove Apache/Node/PHP compatibility;
- introduce HTTP/3/QUIC;
- introduce a service mesh or custom service-discovery daemon;
- perform the later LocalDevStack static-IP migration inside this repository.

The intended result is a hardened, observable, testable LocalDevStack edge image with robust existing routing plus one new first-class capability: a clean streaming local LLM endpoint at `https://llm.localhost`.