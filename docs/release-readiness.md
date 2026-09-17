# docker-nginx release readiness

This document is the final handoff checklist for the hardened docker-nginx release. It intentionally separates what must be complete in this repository from downstream LocalDevStack changes that should happen only after an immutable docker-nginx release exists.

## In-repository release gate

Before publishing a new stable docker-nginx release:

- [ ] PR CI is green on shell syntax, ShellCheck, dependency contracts, publish contracts, actionlint, amd64 release gate, and arm64 smoke.
- [ ] `FROM nginx:alpine` remains the rolling base.
- [ ] Scriptomatic is consumed from canonical `main` with bounded retry/connect-timeout handling.
- [ ] Toolset is consumed through the latest stable checksum-verifying installer with bounded retry/connect-timeout handling.
- [ ] the runtime image exposes only `80` and `443`.
- [ ] the official upstream `default.conf` is absent.
- [ ] `/etc/nginx/locals.conf` is included exactly once and before `conf.d/*.conf`.
- [ ] FastCGI parameters are unique and preserve the audited upstream values expected by this image.
- [ ] TLS 1.2 and TLS 1.3 remain enabled; TLS 1.2 uses the modern AEAD-only cipher policy and the live TLS 1.2 route smoke passes.
- [ ] convenience routing, WebSocket behavior, `/api/tail`, LLM streaming, late Docker-DNS recovery, quarantine/recovery, health, and signals pass the final release gate.
- [ ] the publish workflow uses the current action majors enforced by `tests/release-contract.sh`.
- [ ] stable release tags are immutable in both Docker Hub and GHCR.
- [ ] scheduled/manual publishing resolves the latest stable docker-nginx release and updates only `latest`.
- [ ] rolling publish inputs (`nginx:alpine`, Scriptomatic `main`, Toolset latest installer) are snapshotted before candidate builds and revalidated before registry publication.
- [ ] the final multi-architecture publish reuses the gated candidate caches instead of forcing another base pull.
- [ ] multi-platform publishing targets `linux/amd64` and `linux/arm64`.
- [ ] SBOM, BuildKit provenance, and GitHub/Sigstore attestations are enabled.
- [ ] Docker Hub and GHCR manifest digests are verified equal after push.
- [ ] the pushed amd64 image is pulled and smoke-tested by digest.
- [ ] published Nginx/Alpine/chromacat/banner fingerprints still match the gated amd64 candidate.

## Current LocalDevStack main baseline

At the time this checklist was added, LocalDevStack `main` still has these relevant contracts:

- Nginx image: `infocyph/nginx:latest`.
- Nginx publishes host HTTP/HTTPS ports to container `80/443`.
- Nginx mounts `lds_nginx_host` at `/etc/nginx/conf.d`.
- TLS material is mounted read-only from `lds_ssl_keys` and `lds_ssl_roots`.
- Nginx currently has a static frontend address (`172.28.0.10`).
- `server-tools` remains a required dependency.
- no `llm-sm` service is present yet.
- Runner currently uses `infocyph/runner:latest`; the hardened runner baseline is already available from runner `0.5` onward.

These observations are handoff context, not requirements to mutate LocalDevStack from this repository.

## Downstream LocalDevStack handoff

After the new docker-nginx release is published:

1. replace the LocalDevStack Nginx reference with the agreed new immutable docker-nginx release tag rather than relying on an unreviewed `latest` transition;
2. ensure the LocalDevStack runner selection is runner `0.5` or a newer explicitly accepted release;
3. inspect existing `lds_nginx_host` volumes for an old upstream `default.conf` and remove it only where it is confirmed to be legacy seed content;
4. add the optional `llm-sm` service/profile;
5. place Nginx and `llm-sm` on a shared Docker network where `llm-sm` resolves by service name;
6. persist Ollama/model storage outside Nginx;
7. if direct Ollama access is desired, expose `127.0.0.1:11434` from `llm-sm`, never from the Nginx image;
8. validate `https://llm.localhost/api/chat`, `/api/generate`, `/api/tags`, `/api/version`, and `/v1/...` against the real `infocyph/llm-sm` image;
9. validate PHP direct-FPM, PHP-via-Apache, Node/HMR/WebSocket, admin, mail, database, Redis, Mongo, and Kibana routes;
10. keep the existing static Nginx address initially if needed for compatibility; remove static addresses only as part of a separately-tested broader LocalDevStack DNS migration.

## Release event behavior

The stable publish workflow is intentionally strict:

- a stable GitHub release publishes its exact source tag as an immutable image tag and also updates `latest`;
- draft/prerelease events are rejected by the stable pipeline;
- weekly/manual refreshes rebuild only `latest` from the latest stable published docker-nginx source;
- historical version tags are never refreshed or overwritten;
- rolling upstream inputs are snapshotted before candidate builds and revalidated after both architecture gates, before registry login/publish;
- candidate images are tested before registry login/publish;
- the final multi-architecture build consumes the gated candidate caches without another forced base pull;
- the pushed artifact is verified after publication rather than treating a successful push as the end of the release gate.

## Non-goals for the docker-nginx release

Do not block this release on:

- removing every LocalDevStack static IP;
- exposing Ollama directly;
- introducing HTTP/3/QUIC;
- adding an authentication gateway;
- moving certificate generation into Nginx;
- downloading a real LLM model in docker-nginx CI.
