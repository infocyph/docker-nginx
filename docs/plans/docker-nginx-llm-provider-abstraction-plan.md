# docker-nginx — LLM Provider Abstraction Plan

Status: implementation branch `llm-provider-abstraction`

## Goal

Expose one stable LocalDevStack LLM identity while retaining provider-specific routes.

```text
llm.localhost          -> selected provider
llm-ollama.localhost   -> Ollama
llm-fastflow.localhost -> FastFlow
```

The common Docker DNS identity is `llm`. The provider services are mutually exclusive:
`llm-ollama` and `llm-fastflow` never run at the same time. LocalDevStack gives the
selected provider the `llm` alias and normalizes it onto internal port `11434`, so
provider-neutral clients use:

```text
http://llm:11434/v1
```

## Routing contract

- native host listener `127.0.0.1:11434` -> `llm:11434`;
- common HTTPS route -> `llm:11434`;
- Ollama HTTPS route -> `llm-ollama:11434`;
- FastFlow HTTPS route -> `llm-fastflow:11434`;
- portable common API is OpenAI-compatible `/v1`;
- Ollama-native `/api/*` stays provider-specific;
- all LLM DNS is lazy so absent providers do not prevent Nginx startup;
- exactly one provider owns the common `llm` alias at a time;
- inactive provider-specific routes fail with 502 rather than being silently redirected
  to the active provider;
- streaming remains unbuffered with the dedicated LLM timeout.

## Security

- no wildcard CORS policy in Nginx;
- native port remains intended for loopback-only host publication;
- unknown/custom routes cannot override any of the three reserved LLM hosts.

## Validation

Release smoke must prove:

1. all three reserved hosts redirect HTTP -> HTTPS;
2. with no provider, all LLM HTTPS/native routes fail lazily without breaking Nginx;
3. Ollama-only phase owns `llm` + `llm-ollama`, while FastFlow stays unavailable;
4. Ollama native API survives on `llm-ollama.localhost`;
5. Ollama is removed before FastFlow starts;
6. FastFlow-only phase owns `llm` + `llm-fastflow`, while Ollama stays unavailable;
7. OpenAI SSE survives the common route in both phases;
8. native `11434` always resolves only through the selected common `llm` alias.
