# Model Card - Hosted LLM Providers

Covers cloud providers surfaced via tessera-studio-linux config.

## Overview

Each provider entry maps to a CloudProvider in src/core/config.cpp
(base_url + default_model). The app does not host models; it routes
to provider APIs.

| provider | model family | data control | training on inputs |
|---|---|---|---|
| openai | gpt-4o | zero-data-retention available on enterprise agreement | no (ZDR) |
| anthropic | claude 4 | no training on API inputs per policy 2025 | no |
| google | gemini 2.0 | no training on API inputs | no |
| generic/local | ollama llama3 | on-device, no egress | no |

## Non-US Providers (blocked in enterprise default)

alibaba/qwen, zai/glm, deepseek - see subprocessors.md and provider.cpp
is_non_us_provider. Enterprise returns placeholder.

## Evaluation

Capability eval and anonymizer in TesseraCore/Learning; Linux port
tracks token_usage in DuckDB and traces in receipt_chain.

## No Training on Government Data

Per OMB M-25-22 and GSA clause: customer inputs and outputs are not
used to train vendor or provider models. See system-card.md.

## Limitations

Provider rate limits, context length per model card, and network
availability. Fallback is PlaceholderProvider echo.

## Updates

Model versions pinned per provider default_model; customer may override
via gsettings cloud-model.
