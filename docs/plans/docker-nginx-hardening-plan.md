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
- Shared foundations already completed: Scriptomatic hardened on `main`, Toolset stable release installer available

This plan supersedes the earlier ecosystem-only `03-docker-nginx-plan.md` draft in LocalDevStack. It is based on the current `docker-nginx` source plus the contracts that actually shipped in the completed lower layers.

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
- LocalDevStack service selection.

Those responsibilities remain in `docker-tools`, `docker-llm-sm` and LocalDevStack.

---

# 2. Architecture invariants

Preserve these contracts unless a test proves they are broken:

- Nginx remains the primary LocalDevStack edge on ports `80` and `443`.
- `nginx:alpine` remains the default rolling upstream base for this development image. Do not silently pin it to an old Nginx/Alpine version.
- LocalDevStack provides the TLS certificate, private key and root CA mounts.
- Generated project vhosts remain hot-reloadable.
- Project/service routing uses Docker DNS/service names, not static IP addresses.
- Missing optional upstream containers must not prevent Nginx from starting.
- User-provided `LOCALHOST_ROUTES` remain additive and cannot override reserved LocalDevStack hosts.
- PHP-FPM, Apache, Node, WebSocket/HMR and streaming/SSE behavior remain compatible.
- Runtime scripts that can be POSIX `sh` should stay POSIX `sh`; Bash is only retained where genuinely required.
- Nginx remains small. Do not move LocalDevStack admin/control-plane responsibilities into this image.

---

# 3. Foundation contracts to consume

## 3.1 Scriptomatic

The completed Scriptomatic contract defines `main` as its canonical distribution source.

Match the convention that shipped with `runner 0.5`:

```text
https://raw.githubusercontent.com/infocyph/Scriptomatic/main/bash/banner.sh
```

Requirements:

- remove the stale `Scriptomatic/master` dependency;
- fetch with bounded retries/timeouts;
- verify the downloaded file is non-empty;
- syntax-check it before installation;
- optionally record its resolved SHA/checksum in the publish summary;
- do not invent a Scriptomatic tag/release requirement.

A future exact-SHA build can still be supported if the ecosystem later standardizes build arguments for this, but the default contract should match the completed lower-layer policy rather than diverging from it.

## 3.2 Toolset

Match `runner 0.5` and the completed Toolset distribution contract:

```text
https://github.com/infocyph/Toolset/releases/latest/download/install.sh
```

Use the checksum-verifying Toolset installer and install only what this image needs, currently `chromacat`.

Requirements:

- remove raw `Toolset/main/...` consumption;
- syntax-check the installer before execution;
- install `chromacat` into `/usr/local/bin`;
- verify `chromacat --version` during the build;
- do not copy unrelated Toolset utilities into the Nginx image.

## 3.3 Rolling base policy

Keep:

```dockerfile
FROM nginx:alpine
```

This image intentionally tracks the current official Nginx Alpine line, similar to `runner 0.5` tracking `alpine:latest`.

Compensate for the rolling base with:

- permanent CI;
- fresh-image release candidates;
- actual runtime/config smoke tests;
- publish summaries that record the resolved Nginx/Alpine versions.

Do not pretend a mutable upstream base is reproducible. Instead make the resolved release artifact observable and tested.

---

# 4. New Local LLM endpoint

This is a required part of this Nginx release plan.

## 4.1 Canonical host

Add a reserved LocalDevStack convenience host:

```text
llm.localhost -> llm-sm:11434
```

User-facing endpoint:

```text
https://llm.localhost
```

Examples after LocalDevStack enables the LLM service:

```text
https://llm.localhost/api/chat
https://llm.localhost/api/generate
https://llm.localhost/api/tags
https://llm.localhost/api/version
https://llm.localhost/v1/...
```

The `/api/*` paths are the native Ollama API and `/v1/*` is available for OpenAI-compatible clients supported by Ollama.

## 4.2 Do not reuse `admin.localhost`

Keep the existing contract:

```text
admin.localhost -> server-tools:9911
```

Do **not** redefine the LLM as `admin.localhost:11434`.

Reasons:

- `admin.localhost` already has a clear product meaning: LocalDevStack administration;
- Nginx host routing should use a distinct hostname rather than overloading a hostname by port;
- `llm.localhost` is self-describing;
- `.localhost` resolves locally without requiring a custom public DNS record;
- clients can use a clean TLS URL with no nonstandard port.

## 4.3 Direct Ollama port remains separate

Do not add Nginx `listen 11434` and do not add `EXPOSE 11434` to this image merely for Ollama.

If LocalDevStack wants to preserve a native direct endpoint such as:

```text
http://127.0.0.1:11434
```

that belongs to the `llm-sm` LocalDevStack Compose service through an optional/direct port mapping.

Therefore we can support both concepts without coupling them:

```text
https://llm.localhost         # LocalDevStack TLS edge through Nginx
http://127.0.0.1:11434        # optional direct Ollama endpoint from llm-sm Compose
```

## 4.4 LLM proxy mode must be streaming-aware

Ollama's chat/generate APIs stream by default. The LLM route therefore must not use the ordinary buffered UI proxy behavior unchanged.

For `llm.localhost` ensure:

```nginx
proxy_http_version 1.1;
proxy_buffering off;
proxy_request_buffering off;
proxy_max_temp_file_size 0;
gzip off;
```

Retain a long read/send timeout suitable for local inference; the existing dev-friendly `600s` proxy timeout is an acceptable baseline unless testing shows a better value.

Do not force WebSocket headers for Ollama unless an endpoint actually requires them. Native Ollama token streaming is HTTP streaming, and OpenAI-compatible streaming is SSE-style HTTP streaming.

## 4.5 Optional service safety

`llm-sm` is optional. Nginx must remain healthy when no LLM container is running.

Do not introduce a fixed upstream declaration that forces Docker DNS resolution during Nginx startup.

Continue using runtime Docker DNS resolution (`127.0.0.11`) with variable `proxy_pass` or an equivalent lazy-resolution design so:

- Nginx starts with LLM disabled;
- `https://llm.localhost` returns an upstream failure only when called without the service;
- starting `llm-sm` later makes the route usable without rebuilding Nginx.

## 4.6 Reserved route behavior

`llm.localhost` becomes a reserved route exactly like `admin.localhost`, `webmail.localhost`, etc.

`LOCALHOST_ROUTES` must not be allowed to replace it.

## 4.7 Browser/CORS policy

Do not inject permissive wildcard CORS headers from Nginx by default.

If browser-based tools need cross-origin Ollama access, handle the supported origin policy deliberately through the LLM/Ollama runtime contract rather than weakening every local proxy route.

## 4.8 Tests for the LLM route

Nginx CI should not download a multi-GB LLM model.

Use a tiny mock HTTP upstream named/resolved like `llm-sm` to validate:

- `/api/chat` forwarding;
- `/api/generate` forwarding;
- `/v1/*` forwarding;
- request body passthrough;
- streamed chunks arrive incrementally instead of being buffered until completion;
- long-running response does not hit an inappropriate short timeout;
- missing LLM upstream does not invalidate Nginx configuration/startup;
- `LOCALHOST_ROUTES` cannot override `llm.localhost`.

Then perform the real `infocyph/llm-sm` integration smoke test later in LocalDevStack where the full service topology belongs.

---

# 5. File-by-file implementation plan

## 5.1 `Dockerfile`

Current issues:

- consumes `Scriptomatic/master`;
- consumes raw mutable `Toolset/main` source;
- does not validate downloaded helper contracts;
- has no release metadata supplied by the modern publish workflow;
- current build/publish process does not prove actual runtime routing behavior.

Plan:

1. Keep `FROM nginx:alpine`.
2. Retain only runtime packages needed by the edge image and interactive helper presentation.
3. Ensure `ca-certificates`/`curl` are available for controlled dependency acquisition if needed by the selected installation design.
4. Fetch `show-banner` from Scriptomatic `main` with retry/timeout behavior.
5. Syntax-check `show-banner` before installing it.
6. Install `chromacat` through Toolset's latest stable release installer.
7. Verify `chromacat --version`.
8. Keep repository-owned scripts copied from this repo:
   - `scripts/fcgi-params.sh`
   - `scripts/proxy-params.sh`
   - `scripts/render-locals.sh`
   - `scripts/nginx-entrypoint.sh`
9. Continue generating the static include files at image build time.
10. Preserve `/etc/nginx/locals.conf` inclusion.
11. Preserve `/etc/share/rootCA`, `/etc/mkcert`, `/var/log/nginx` runtime directories.
12. Keep `EXPOSE 80 443` only.
13. Keep `nginx-entrypoint` as image entrypoint.
14. Keep Nginx foreground as CMD.
15. Let the publish workflow inject OCI revision/version metadata instead of hard-coding release identifiers.
16. Record resolved Nginx and Alpine versions during CI/publishing.

Review package use before deleting anything. Do not perform cosmetic package churn that risks breaking the interactive banner or existing scripts.

### Optional build cleanup

If dependency fetching can be cleanly separated into a fetch stage without increasing complexity, consider a multi-stage helper fetch so download-only tooling does not remain in the final image.

Do not make this mandatory if the result is harder to maintain than the small package savings justify.

---

## 5.2 `scripts/fcgi-params.sh`

Current role:

- augments official Nginx `fastcgi_params`;
- writes forwarded headers/framework HTTPS awareness;
- creates `/etc/nginx/fastcgi_streaming`.

Plan:

1. Preserve idempotent generation and first-backup behavior.
2. Validate every generated parameter against representative PHP-FPM vhosts.
3. Preserve:
   - real client IP;
   - forwarded chain;
   - scheme/host/port;
   - request ID;
   - `HTTPS`/forwarded SSL awareness.
4. Confirm no duplicate or conflicting key from current upstream `nginx:alpine` `fastcgi_params` causes ambiguity.
5. Keep `fastcgi_streaming` as opt-in rather than globally disabling FastCGI buffering.
6. Validate the generated file with `nginx -t` in CI.
7. Add deterministic output/idempotency tests: second run must not append duplicates.
8. Keep PHP TCP and Unix-socket compatibility where LocalDevStack templates require it.
9. Remove the build-time generator after successful image generation only if the current self-delete contract remains useful; tests should validate the final generated artifacts, not depend on re-running a removed build helper inside the runtime image.

---

## 5.3 `scripts/proxy-params.sh`

Current generated includes:

- `/etc/nginx/proxy_params`
- `/etc/nginx/proxy_fixedip_headers`
- `/etc/nginx/proxy_timeouts`
- `/etc/nginx/proxy_buffers`
- `/etc/nginx/proxy_websocket`
- `/etc/nginx/proxy_streaming`
- `/etc/nginx/proxy_csp_relax`
- `/etc/nginx/proxy_h2_sanitize`

Plan:

1. Preserve deterministic atomic generation.
2. Preserve first-backup behavior.
3. Verify current upstream Nginx syntax for every generated directive.
4. Keep normal proxy buffering enabled for UI/backend routes where useful.
5. Keep streaming as an explicit opt-in include.
6. Use the streaming include for the new LLM route.
7. Retain WebSocket/HMR support for Node/Vite/Next/Socket.IO routes.
8. Preserve client identity/forwarding headers.
9. Preserve request correlation through `X-Request-ID`.
10. Review `proxy_fixedip_headers` separately during the later LocalDevStack static-IP removal; do not delete it solely because LocalDevStack service networking will move to DNS.
11. Verify timeout defaults with:
    - ordinary local admin UI;
    - Node dev server;
    - streaming endpoint;
    - LLM long generation.
12. Avoid turning all routes into unbuffered routes just to support LLM streaming.
13. Keep CSP relaxation explicitly opt-in.
14. Add tests that compare expected generated includes and run `nginx -t` using them.

### LLM-specific generated include

Prefer reusing `/etc/nginx/proxy_streaming` rather than creating nearly identical LLM-only directives.

If additional LLM-specific directives become necessary, create one focused include such as:

```text
/etc/nginx/proxy_llm
```

only if it materially improves clarity. Do not introduce a new include merely to rename existing streaming behavior.

---

## 5.4 `scripts/render-locals.sh`

This is the most important runtime-routing file in this repository.

Current predefined routes:

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

Plan:

1. Keep reserved routes explicit and easy to audit.
2. Keep `LOCALHOST_ROUTES` additive.
3. Keep reserved routes non-overridable.
4. Keep strict hostname and upstream validation.
5. Keep runtime Docker resolver behavior so optional services do not need to exist at Nginx startup.
6. Preserve admin log-tail streaming behavior for `/api/tail`.
7. Add special handling for `llm.localhost` so the entire Ollama API surface can stream correctly.
8. Do not accidentally apply LLM buffering changes globally to all reserved hosts.
9. Preserve HTTP -> HTTPS redirects for all convenience hosts, including `llm.localhost`.
10. Preserve TLS termination from LocalDevStack-provided certs.
11. Review the hard-coded cipher configuration against the Nginx/OpenSSL version resolved by the rolling base. Simplify only with explicit compatibility tests.
12. Keep TLS 1.2 + 1.3 unless there is a concrete LocalDevStack compatibility reason to change it.
13. Review the currently generated `$log_host` map: it is defined but the current convenience server writes to fixed `localhost.access.log`/`localhost.error.log`. Either use it deliberately for safe per-host logging or remove the dead mapping. Do not keep unused config indefinitely.
14. Keep large-body behavior compatible with development tooling, but verify that `10G` is still intentional before preserving it blindly.
15. Keep generated output atomic (`.tmp` + replace-on-change).
16. Add a deterministic test for route ordering/deduplication.
17. Add tests for malicious/invalid `LOCALHOST_ROUTES` values.
18. Add a test proving optional unresolved upstream names do not make `nginx -t` fail.

### Recommended LLM rendering shape

Do not simply put `llm.localhost` into the generic host map and call it done if that means it inherits buffered behavior.

Prefer one of these designs, in order:

**Preferred:** keep route data together but render a dedicated `server_name llm.localhost` TLS server using lazy Docker DNS and the streaming include.

**Acceptable:** retain the shared TLS server but render host/path-specific streaming behavior that is demonstrably correct and does not weaken unrelated hosts.

Choose the simplest implementation that passes the streaming tests.

---

## 5.5 `scripts/nginx-entrypoint.sh`

Current behavior:

- timezone setup;
- restore disabled vhosts;
- render `locals.conf`;
- validate Nginx;
- quarantine invalid files from `/etc/nginx/conf.d`;
- background retry/restore loop;
- `exec "$@"` for Nginx signal semantics.

Plan:

1. Preserve final `exec "$@"`.
2. Validate `MAX_DISABLE_ATTEMPTS` as a bounded positive integer before use.
3. Keep validation for `AUTO_RESTORE_INTERVAL_SECONDS` and bound unreasonable values if necessary.
4. Preserve optional `AUTO_DISABLE_INVALID_CONFS`.
5. Preserve optional `AUTO_RESTORE_DISABLED_CONFS`.
6. Prevent unchanged permanently-invalid files from entering a noisy disable -> restore -> disable loop forever.
7. Implement either:
   - retry only after the disabled file content/mtime changes; or
   - bounded/exponential retry with clear diagnostics.
8. Keep failures visible on stderr.
9. Keep unrelated global Nginx errors fatal; only isolate errors attributable to one generated file under `/etc/nginx/conf.d`.
10. Validate behavior when the mounted config directory is read-only; fail clearly instead of partially mutating state.
11. Verify background restore helper does not create orphan/process shutdown problems.
12. Add signal/shutdown tests.
13. Add tests for multiple invalid files and attempt limits.
14. Ensure `render-locals` failure is fatal before Nginx starts.
15. Ensure the optional missing `llm-sm` container does not interact with invalid-vhost quarantine at all.

---

## 5.6 `.github/workflows/check.yml` — new

Add permanent validation for pull requests and relevant pushes.

Suggested jobs/gates:

### Static shell validation

- `sh -n` for POSIX scripts;
- `bash -n` for Bash scripts;
- ShellCheck with correct shell mode;
- fail on real ShellCheck errors;
- do not add blanket disables to make CI green.

### Image build

Build a fresh image with upstream pull enabled.

Validate:

- Nginx version resolves;
- Alpine version resolves;
- `show-banner` exists/syntax is valid;
- `chromacat --version` works;
- generated proxy/FastCGI files exist;
- `/etc/nginx/locals.conf` is included in `nginx.conf`.

### Default config smoke

Provide disposable TLS fixtures and ensure:

```text
nginx -t
```

passes with no optional LocalDevStack services running.

### Local route smoke

Use tiny mock HTTP services to validate:

- `admin.localhost`;
- one additive `LOCALHOST_ROUTES` host;
- reserved-host override rejection;
- HTTP -> HTTPS behavior.

### LLM streaming smoke

Use a mock `llm-sm:11434` service that emits at least two delayed chunks.

Assert the first chunk reaches the client before the upstream response finishes.

Also test:

- native `/api/chat` path;
- `/v1` path;
- request bodies;
- missing upstream behavior.

### Invalid-vhost smoke

Test:

- one invalid vhost gets isolated;
- valid vhost remains enabled;
- unchanged bad config does not thrash indefinitely;
- fixed config can be restored/reloaded;
- attempt limit works.

### Signal smoke

Start the actual image and verify clean shutdown on SIGTERM.

### Architecture

After amd64 behavior is stable, validate `linux/arm64` as well, matching the multi-architecture approach that shipped in `runner 0.5`.

---

## 5.7 `.github/workflows/docker.publish.yml`

Replace the old publication workflow with the hardened ecosystem pattern already proven by `runner 0.5`.

Required behavior:

### Triggers

- release published;
- weekly scheduled refresh;
- manual dispatch.

Keep the existing weekly refresh cadence unless we deliberately change the ecosystem schedule later.

### Release source

- release event: use the exact released tag;
- scheduled/manual refresh: resolve the latest stable published Nginx release source;
- rebuild that source against current `nginx:alpine`, Scriptomatic `main`, and latest stable Toolset.

### Tag semantics

On release:

```text
<release>
latest
```

On schedule/manual refresh:

```text
latest
```

Do not overwrite immutable release-version tags on scheduled refresh.

Before release publishing, actively verify that the version tag is absent in both Docker Hub and GHCR and fail rather than overwrite it.

### Candidate verification

Before registry login/push:

1. build a fresh amd64 release candidate;
2. run the full Nginx release gate;
3. record resolved:
   - Nginx version;
   - Alpine version;
   - Scriptomatic main revision/checksum used;
   - Toolset latest release/chromacat version;
4. build/test arm64 candidate;
5. only then publish.

### Multi-architecture

Publish:

```text
linux/amd64
linux/arm64
```

provided both runtime gates pass.

### Supply chain metadata

Match the modern lower-layer convention:

- BuildKit provenance;
- SBOM;
- Docker Hub provenance attestation;
- GHCR provenance attestation;
- OCI source/revision/version labels.

### Actions

Use current compatible action majors, following the already-published runner workflow where appropriate:

- `actions/checkout@v7`
- `docker/setup-qemu-action@v4`
- `docker/setup-buildx-action@v4`
- `docker/login-action@v4`
- `docker/metadata-action@v6`
- `docker/build-push-action@v7`
- `actions/attest@v4`

### Workflow safety

Add:

```yaml
concurrency:
  group: docker-publish
  cancel-in-progress: false
```

Use a sensible publish timeout.

### Post-publish verification

Pull the image by digest and verify at least amd64 runtime/config behavior from the actual pushed artifact.

Summarize digest/platforms/resolved upstream versions in the workflow summary.

---

## 5.8 `.dockerignore`

Review against the actual build context.

Keep only what the Docker build needs.

Do not expand it cosmetically.

When adding `tests/` and `docs/`, decide deliberately whether they belong in build context; CI can access repository tests without copying them into the runtime image.

---

## 5.9 `.gitattributes`

Preserve LF line endings for shell/config files.

Add patterns only if new fixtures expose a real cross-platform issue.

---

## 5.10 `.gitignore`

Add only generated test outputs/temp certificates if required.

Do not ignore committed fixtures that CI needs.

---

## 5.11 `README.md` — new

The current repository has no README. Add one after runtime behavior is finalized.

Document:

- image purpose;
- Docker Hub/GHCR image names;
- LocalDevStack relationship;
- ports `80`/`443`;
- expected certificate/root-CA/vhost/log mounts;
- generated helper includes;
- predefined convenience routes;
- `LOCALHOST_ROUTES` syntax;
- invalid-vhost quarantine settings;
- healthcheck behavior;
- release tags and `latest` rolling-refresh semantics;
- supported architectures;
- `llm.localhost` endpoint.

The LLM section should show:

```text
https://llm.localhost/api/chat
https://llm.localhost/api/generate
https://llm.localhost/v1
```

and explain that `llm.localhost` proxies to `llm-sm:11434` when that optional service is enabled.

Do not document `admin.localhost:11434` as the LLM endpoint.

---

## 5.12 `LICENSE`

No change.

---

# 6. New tests and fixtures

Create a focused test tree instead of embedding long validation scripts directly in workflows.

Suggested files:

```text
tests/
├── static.sh
├── image-smoke.sh
├── config-smoke.sh
├── render-locals.sh
├── llm-route-smoke.sh
├── invalid-vhost-smoke.sh
├── release-gate.sh
└── fixtures/
    ├── conf.d/
    │   ├── valid.conf
    │   └── invalid.conf
    └── mock-upstreams/
```

TLS certificates should normally be generated during tests rather than committing private-key fixtures.

## `tests/static.sh`

- syntax validation;
- ShellCheck;
- distribution-file checks;
- reject stale `Scriptomatic/master`;
- reject raw `Toolset/main` dependency;
- verify required scripts remain executable in built image.

## `tests/image-smoke.sh`

- start actual built image;
- mount/generated test certs;
- wait until healthy;
- `nginx -t`;
- verify current Nginx/Alpine versions are reportable;
- clean stop.

## `tests/config-smoke.sh`

- assert generated proxy/FastCGI include content;
- idempotency where generators are tested before final image assembly;
- representative PHP/Node/proxy config syntax.

## `tests/render-locals.sh`

- all reserved routes present;
- `llm.localhost` present;
- valid user route accepted;
- malformed route rejected/ignored;
- reserved override rejected;
- duplicate user host deterministic.

## `tests/llm-route-smoke.sh`

- mock `llm-sm:11434`;
- validate native Ollama and `/v1` forwarding;
- validate streaming timing;
- validate service absence does not break Nginx startup;
- validate TLS route through `llm.localhost`.

## `tests/invalid-vhost-smoke.sh`

- quarantine;
- bounded retry;
- repair/restore;
- no infinite oscillation.

## `tests/release-gate.sh`

One release-level entrypoint that verifies the built candidate before publication.

It should be callable both locally and from CI.

---

# 7. LocalDevStack integration follow-up

Do not implement these changes in this repository, but make them explicit downstream gates.

After the hardened Nginx image is published:

1. raise/pin LocalDevStack to the new Nginx release;
2. raise/pin LocalDevStack Runner to the already-published `0.5` where not already done;
3. add the optional `llm-sm` service/profile to LocalDevStack;
4. put Nginx and `llm-sm` on a shared Docker network where `llm-sm` is resolvable by service/container DNS;
5. preserve persistent Ollama model storage in LocalDevStack;
6. expose direct `127.0.0.1:11434` only if desired as a separate LLM-service decision;
7. validate `https://llm.localhost` through the real `infocyph/llm-sm` image;
8. validate Graphify or other Ollama clients against either:
   - `https://llm.localhost/v1`, or
   - direct `http://127.0.0.1:11434/v1` when the direct port is enabled;
9. validate PHP direct-FPM routes;
10. validate PHP-via-Apache routes;
11. validate Node/HMR/WebSocket routes;
12. validate admin/mail/database convenience routes;
13. later remove LocalDevStack static IP assignments after all DNS-routing gates pass.

The Nginx release must not depend on that later static-IP migration. It should already be DNS-safe before LocalDevStack consumes it.

---

# 8. Security / trust-boundary review

This is a local development edge, but keep clear boundaries.

## Certificates

- Nginx consumes LocalDevStack-managed certs.
- Do not generate a competing CA inside this image.
- Fail clearly when required TLS material is missing rather than silently generating unrelated certs.

## Generated configs

- Treat mounted/generated vhosts as configuration input, not trusted shell input.
- Never `eval` vhost/config values.
- Keep route validation strict.
- Restrict automatic quarantine to known config paths.

## Optional upstreams

- Missing services should produce request-time `502`/upstream errors, not Nginx startup failure.
- Never resolve optional service names in shell and write static container IPs.

## LLM

- `llm.localhost` is local development infrastructure, not a public ingress design.
- Do not add wildcard CORS automatically.
- Do not expose Ollama to `0.0.0.0:11434` from this Nginx image.
- Do not add authentication concerns to this image unless LocalDevStack later defines a broader local-access policy.

## CSP helper

Keep the existing CSP-relax include explicitly opt-in and clearly labeled local-dev-only.

---

# 9. Performance / developer experience

Prioritize fast local feedback rather than production-style complexity.

- Keep Nginx startup quick.
- Avoid blocking startup waiting for optional services.
- Keep generated route updates atomic.
- Avoid unnecessary DNS/static-IP probing.
- Keep WebSocket/HMR behavior low-latency.
- Keep LLM token streaming immediate by disabling buffering only where needed.
- Do not add a service mesh, discovery daemon or dynamic control plane when Docker DNS is sufficient.

---

# 10. Implementation order

Execute in this order so every later step builds on a stable lower layer.

## Phase 1 — CI foundation

1. add test helpers/fixtures;
2. add static shell validation;
3. add real image build smoke;
4. establish current behavior before changing runtime logic.

## Phase 2 — dependency/distribution cleanup

1. Scriptomatic `master` -> `main`;
2. raw Toolset `main` -> latest stable installer;
3. verify helper installation;
4. keep `nginx:alpine` rolling base;
5. capture resolved upstream versions.

## Phase 3 — generated include hardening

1. `fcgi-params.sh`;
2. `proxy-params.sh`;
3. deterministic/idempotent output tests;
4. representative config syntax tests.

## Phase 4 — local router + LLM

1. add reserved `llm.localhost` route;
2. add streaming-aware LLM proxy mode;
3. retain lazy Docker DNS;
4. add mock Ollama route tests;
5. reconcile `$log_host` dead/unused mapping;
6. verify all existing convenience hosts.

## Phase 5 — entrypoint hardening

1. validate numeric inputs;
2. stop invalid-vhost restore oscillation;
3. preserve repair/reload developer experience;
4. verify shutdown behavior.

## Phase 6 — publish hardening

1. modern actions;
2. release-source resolution;
3. immutable version tags;
4. schedule/manual `latest` refresh only;
5. amd64 + arm64 candidate gates;
6. multi-arch publish;
7. provenance + SBOM;
8. post-publish digest verification.

## Phase 7 — documentation and release

1. add README;
2. reconcile all documented routes/env variables with actual behavior;
3. final release-gate run;
4. publish next Nginx release;
5. then update LocalDevStack.

---

# 11. Acceptance criteria

The Nginx work is complete only when all of the following are true.

1. Static shell validation is permanently enforced in CI.
2. A fresh `nginx:alpine` image build succeeds.
3. `nginx -t` passes with generated LocalDevStack helper config.
4. amd64 runtime smoke passes.
5. arm64 runtime smoke passes.
6. Existing admin/mail/database convenience routes remain compatible.
7. PHP proxy/FastCGI behavior remains compatible.
8. Node/WebSocket/HMR behavior remains compatible.
9. `/api/tail` streaming remains compatible.
10. `llm.localhost` is reserved and maps to `llm-sm:11434`.
11. `https://llm.localhost/api/chat` supports incremental streaming.
12. `https://llm.localhost/api/generate` supports incremental streaming.
13. `https://llm.localhost/v1/...` proxies correctly.
14. Nginx starts successfully when `llm-sm` is absent.
15. `LOCALHOST_ROUTES` cannot override `llm.localhost` or other reserved hosts.
16. Invalid-vhost quarantine is bounded and does not oscillate endlessly.
17. Repaired vhosts can be restored/reloaded correctly.
18. Container SIGTERM shutdown is clean.
19. No stale `Scriptomatic/master` dependency remains.
20. No raw Toolset `main` dependency remains.
21. Release tags cannot be overwritten by scheduled/manual refreshes.
22. Scheduled/manual refresh publishes only `latest` from the latest stable released source.
23. Docker Hub and GHCR receive the same multi-platform release digest.
24. Provenance/SBOM are published.
25. Published artifact is verified by digest after push.
26. README matches actual runtime behavior.
27. LocalDevStack can consume the new Nginx release without static-IP assumptions inside this image.
28. Real `infocyph/llm-sm` integration is validated downstream before the LocalDevStack AI profile is considered complete.

---

# 12. Explicit non-goals

Do not use this Nginx cycle to:

- rewrite LocalDevStack orchestration;
- move `mkcert` into Nginx;
- build an Nginx UI/control panel;
- add Docker socket access to Nginx;
- manage Ollama models;
- embed `docker-llm-sm` inside the Nginx image;
- expose a new public port `11434` from Nginx;
- add authentication/proxy gateways unrelated to local development;
- convert all proxy routes to unbuffered streaming;
- remove Apache/Node/PHP compatibility without explicit downstream migration.

The intended result is a hardened, observable, testable LocalDevStack edge image with one new first-class capability: a clean local LLM endpoint at `https://llm.localhost`.