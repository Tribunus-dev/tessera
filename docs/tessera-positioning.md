# Tessera positioning

Effective: 2026-08-05. Version 1.0. Author: Julian Alejandro Torres Nieto, Tribunus.dev.

> **Tessera is a free, open-source tool for running and quantizing local models.
> Models we train on our sanitized dataset are source-available under
> CC BY-NC-SA 4.0 for non-commercial use.
> Commercial use is a conversation - write to `julian@tribunus.dev`.**

That is the whole position. Everything below is the proof.

## The three tiers

Tessera's relationship with any user, contributor, or business partner falls
into exactly one of three tiers. The boundary between tiers is the boundary
between the existing license docs and is not negotiable per artifact.

| Tier | What lives here | License | Audience |
| --- | --- | --- | --- |
| **Community (free)** | Tessera engine, Tessera Studio, recipes, vanilla quants of upstream models, documentation, skills | [`LICENSE-TESSERA`](../LICENSE-TESSERA) PolyForm Noncommercial 1.0.0 for code; upstream model license for vanilla quants | Researchers, hobbyists, contributors, anyone who evaluates locally |
| **Tessera-trained (NC)** | Models trained on the Tessera sanitized dataset, the dataset snapshots themselves, the Calibration Commons aggregates | [`TESSERA_ARTIFACT_LICENSE_NOTICE.md`](TESSERA_ARTIFACT_LICENSE_NOTICE.md) CC BY-NC-SA 4.0 | Community who want to *use* trained models; contributors to the Calibration Commons |
| **Commercial** | Any of the above, used commercially | Separate commercial license from `julian@tribunus.dev` | Business partners, production users, custom development |

A published artifact's tier is determined by the recipe, not by the user.
See [tessera-community-handbook.md](tessera-community-handbook.md) for the
auto-computation rules.

## What the sanitization pipeline is, and is not

The Tessera training dataset is the output of a data sanitization pipeline
that turns raw usage signals and personal data into license-clean, truly
anonymized training material. The pipeline is the proprietary data work that
makes the trained models defensible. The pipeline is **not** open source.

What is public:
- The contracts that govern contributions and uses
  ([`TESSERA_CALIBRATION_CONTRIBUTION_TERMS_1.0.md`](TESSERA_CALIBRATION_CONTRIBUTION_TERMS_1.0.md),
  the artifact license, the commercial contact).
- The dataset snapshots themselves, in the Calibration Commons.
- The auditability of every published model: each carries a `tessera.recipe.v1`
  with the upstream source SHA, the dataset snapshot fingerprint, the
  evaluation results, and a signed receipt. Anyone can verify *that* the data
  was sanitized and *what* came out; no one needs to reverse-engineer *how*.

What is not public:
- The pipeline source.
- The pipeline's internal thresholds, heuristics, or model-assisted steps.
- The un-sanitized inputs.

This is the same posture as the S2S Route B consent lane: the contract and
the auditability are public, the method is not.

## Reciprocity

Tessera-trained models exist because contributors gave calibration statistics
to the Calibration Commons under the contribution terms. Contributors retain
ownership of their contributions; Julian Alejandro Torres Nieto receives a
worldwide, perpetual, irrevocable, sublicensable, royalty-free license over
each contribution, including commercial use. Contributors get access to the
trained models, the next snapshot, and the recipe audit trail in return.

The community tier is not a charity; it is the front door of a relationship.
The commercial tier exists because some relationships become commercial.

## What is not in scope

- **No paywalled features** in Tessera Studio. The studio is the community
  tier, full stop.
- **No "premium models."** Tessera-trained models are NC for everyone; the
  commercial path is a license, not a different artifact.
- **No separate data license.** Tessera-trained artifacts inherit the
  artifact license. There is no per-model data sublicense.
- **No implicit commercial rights.** The PolyForm Noncommercial 1.0.0
  license for the code and the CC BY-NC-SA 4.0 license for the artifacts
  are explicit. If you are unsure whether your use is commercial, the
  answer is to ask.

## See also

- [`LICENSE-TESSERA`](../LICENSE-TESSERA) - code license
- [`TESSERA_ARTIFACT_LICENSE_NOTICE.md`](TESSERA_ARTIFACT_LICENSE_NOTICE.md) - artifact license
- [`TESSERA_CALIBRATION_CONTRIBUTION_TERMS_1.0.md`](TESSERA_CALIBRATION_CONTRIBUTION_TERMS_1.0.md) - contribution terms
- [`tessera-community-handbook.md`](tessera-community-handbook.md) - how to publish under a Tessera org
- [`tessera-s2s-design.md`](tessera-s2s-design.md) section 8 - the consent lane pattern
