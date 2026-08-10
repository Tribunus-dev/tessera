# Subprocessors

Tessera Studio Linux Enterprise - 2026-08-08

## Cloud LLM Providers (via src/core/config.cpp catalog, 13)

| id | display | base_url | default_model | US | notes |
|---|---|---|---|---|---|
| openai | OpenAI | https://api.openai.com/v1 | gpt-4o | US | |
| anthropic | Anthropic | https://api.anthropic.com | claude-4 | US | |
| google | Google | https://generativelanguage.googleapis.com/v1 | gemini-2.0 | US | |
| grok | xAI Grok | https://api.x.ai/v1 | grok-4 | US | |
| azure | Azure OpenAI | https://YOUR.openai.azure.com/openai/v1 | gpt-4o | US | customer tenant |
| openrouter | OpenRouter | https://openrouter.ai/api/v1 | openai/gpt-4o | US | aggregates foreign models - allow_non_us_subprocessors needed |
| vertex | Vertex AI | https://aiplatform.googleapis.com/v1 | gemini-2.0 | US | GCP |
| ollama | Ollama (local) | http://localhost:11434/v1 | llama3 | US-local | no network |
| generic | Generic OAI | http://localhost:8080 | | local | |
| alibaba | Alibaba Qwen | https://dashscope.aliyuncs.com/compatible-mode/v1 | qwen-plus | non-US (CN) | blocked in enterprise default |
| zai | Z.ai | https://api.z.ai/api/paas/v4 | glm-4-plus | non-US (CN) | blocked |
| glm | GLM Zhipu | https://open.bigmodel.cn/api/paas/v4 | glm-4-plus | non-US (CN) | blocked |
| deepseek | DeepSeek | https://api.deepseek.com/v1 | deepseek-chat | non-US (CN) | blocked |

Enterprise default (TESSERA_ENTERPRISE): provider=placeholder or US-only
(openai/anthropic/google). Non-US ids above return PlaceholderProvider
with on_error Buy American unless allow_non_us_subprocessors is explicitly
compiled in (not offered in enterprise Flatpak). Personal SKU allows all.

## Local Dependencies (no data egress unless configured)

| component | pkg | purpose | network |
|---|---|---|---|
| libpq | postgresql-libs | Postgres source of truth | localhost:5432 |
| hiredis | hiredis | Valkey cache | localhost:6379 |
| EDS | evolution-data-server | calendar/contacts local | none |
| libetpan | libetpan | email IMAP (oauth2) | IMAP host only |
| WebKitGTK | webkitgtk6.0 | BrowserTool snapshot | target URL only |
| AT-SPI | at-spi2-core | DesktopTool | none |
| libsecret | libsecret | api key + LUKS secret | none |
| DuckDB | duckdb | analytics | none |

## Buy American Note

Econ Act 41 U.S.C. 8301: Enterprise SKU defaults to domestic end
products. Foreign LLM APIs are non-domestic services; Fed customers
obtain a non-availability determination before enabling non-US ids.

## Change Log

2026-08-08 initial list (13 cloud + 8 local).
