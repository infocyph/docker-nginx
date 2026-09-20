# docker-nginx — LLM Provider Abstraction Plan

Status: implementation branch `llm-provider-abstraction`

## Goal

Expose one stable LocalDevStack LLM identity while retaining provider-specific routes.

```text
llm.localhost          -> selected provider
llm-ollama.localhost   -> Ollama
llm-fastflow.localhost -> FastFlow
```

The common Docker DNS identity is `llm`. LocalDevStack normalizes the active provider
onto internal port `11434`, so provider-neutral clients use:

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
- streaming remains unbuffered with the dedicated LLM timeout.

## Security

- no wildcard CORS policy in Nginx;
- native port remains intended for loopback-only host publication;
- unknown/custom routes cannot override any of the three reserved LLM hosts.

## Validation

Release smoke must prove:

1. all three reserved hosts redirect HTTP -> HTTPS;
2. all three resolve lazily after provider startup;
3. Ollama native API survives on `llm-ollama.localhost`;
4. OpenAI SSE survives common, Ollama and FastFlow identities;
5. native `11434` resolves only through the common `llm` alias.
