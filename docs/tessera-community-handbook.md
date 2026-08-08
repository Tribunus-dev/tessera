# Tessera community handbook

Effective: 2026-08-05. Companion to [`tessera-positioning.md`](tessera-positioning.md).

This handbook is for anyone publishing a model, calibration aggregate, or
finetune under a Tessera-controlled Hugging Face organization. Read it
before pushing.

## The three orgs

Each org has a single, structural license. The license is the URL.

| HF org | License of every repo under it | Who writes | Who reads |
| --- | --- | --- | --- |
| `tessera-vanilla/<model>` | Upstream model license + attribution (per-quant, derived from the recipe) | Julian Alejandro Torres Nieto and named maintainers | Anyone; default-fetch tier in Tessera Studio |
| `tessera-finetune/<model>` | CC BY-NC-SA 4.0 ([`TESSERA_ARTIFACT_LICENSE_NOTICE.md`](TESSERA_ARTIFACT_LICENSE_NOTICE.md)) | Julian Alejandro Torres Nieto and named maintainers | Community under the NC terms; commercial use requires a license |
| `tessera-community/<hf-user>/<model>` | Per-repo, auto-attached by the upload tool from the recipe | Anyone with a HF account and a Tessera Studio install | Anyone; the recipe is the source of truth |

There is no fourth org. A `tessera-personal/` namespace is **not** a
Tessera-controlled location; use your own HF account for private publishing.

## The recipe - `tessera.recipe.v1`

Every published repo carries a `tessera.recipe.json` at the root. The recipe
is the contract. The schema:

```json
{
  "schema": "tessera.recipe.v1",
  "source": {
    "hf_repo": "<upstream model id>",
    "revision": "<upstream git sha>",
    "upstream_license": "<spdx-or-custom>",
    "upstream_aup_url": "<url>"
  },
  "tessera_dataset": {
    "used": true,
    "snapshot_fingerprint": "sha256:...",
    "snapshot_attribution": "Tessera Calibration Commons YYYY-MM-DD",
    "contribution_terms_version": "1.0",
    "shipping": "metadata-only"
  },
  "private_dataset": {
    "used": false
  },
  "quantization": {
    "policy_id": "<quant recipe id>",
    "policy_version": "<git sha>",
    "sidecar_sha256": "..."
  },
  "evaluation": {
    "suite": "<eval suite id>",
    "metrics": { "ppl_delta_pct": 0.7, "mmlu_delta_pct": -0.4 },
    "floor_passed": true
  },
  "receipt": {
    "signer": "tessera-receipt-signer-v1",
    "signature": "...",
    "signed_at": "ISO-8601"
  },
  "published_license": {
    "spdx": "...",
    "human": "...",
    "attribution_required": true,
    "share_alike": true,
    "non_commercial": true,
    "commercial_license_available": true,
    "commercial_contact": "julian@tribunus.dev"
  }
}
```

`tessera_dataset.used` and `private_dataset.used` are mutually exclusive.
The upload tool rejects recipes with both set, with neither set on a
finetune, or with `tessera_dataset.used = true` and an unknown snapshot
fingerprint.

## Auto-computed published license

The `published_license` block is computed by the upload tool. The rules:

1. If `tessera_dataset.used = true` -> **CC BY-NC-SA 4.0** (Tessera artifact
   terms). The Tessera data is the binding ingredient.
2. Else if `source.upstream_license` is in an NC family -> inherit the
   upstream NC license, with attribution and a `commercial_license_available`
   flag pointing to `julian@tribunus.dev`.
3. Else inherit the upstream license verbatim, with attribution.

The tool refuses to push when the `LICENSE` file in the candidate repo does
not textually contain the auto-computed SPDX.

## The upload tool workflow

Tessera Studio exposes `PublishToHubTool` as part of the standard tool
registry. The recommended way to drive it is via the `tessera-community-upload`
skill, which is a `SKILL.md` shipped with the studio. The flow:

1. Resolve the upstream model and verify the AUP.
2. Run `Calibrate` -> `Quantize` -> `Evaluate` (the existing toolchain).
3. Generate the recipe. Auto-compute the published license.
4. Verify: sidecar hash in recipe matches, receipt signature verifies,
   `LICENSE` file matches, dataset fingerprint is in the registry.
5. Push to the destination org. The HF token is read from the
   `tessera-hf-token` env var or the macOS keychain.
6. The CI gate fires on the new repo (see below).

## The CI gate

`tes sera-community` is a meta-repo on HF whose only job is to host a GitHub
Action. When a `tessera-community/<user>/<model>` repo receives a push, the
Action:

1. Reads `tessera.recipe.json`.
2. Re-runs calibration + quantization from the upstream SHA in the recipe.
3. Compares the sidecar hash. Reject on mismatch.
4. Verifies the receipt signature against the published signer public key.
5. Runs the eval suite. Reject on floor failure.
6. Posts a status check on the commit.

A 7-day quiet-period follows a successful gate, during which
Julian Alejandro Torres Nieto may pull the artifact without notice. After
the quiet-period, the repo is considered community-blessed.

## Eval floor (TBD)

The default floor is `ppl_delta_pct <= 1.0` and `mmlu_delta_pct >= -2.0` on
`tessera-higgs-proxy-138`. The exact numbers are the architect's call.
Once locked, the floor lives in the `tessera-community` meta-repo's
`FLOOR.json` and is read by the CI gate.

## The fingerprint registry

A public, append-only ledger of every Calibration Commons snapshot. Lives
in a small HF repo (`tessera-commons-registry`), one signed JSONL entry
per snapshot, mirrored under CC BY-NC-SA 4.0. The upload tool and the
CI gate read it as a public dependency.

The registry is itself a Tessera artifact, so it is NC for the
distribution. It is public, signed, and anyone can verify a snapshot is
a real Commons entry.

## Quick reference - what you can and cannot publish

| You did | You can publish to | Under license |
| --- | --- | --- |
| Vanilla quant of an upstream model, no Tessera data | `tessera-community/<you>/<model>` | Upstream license + attribution |
| Vanilla quant, no Tessera data, you are a maintainer | `tessera-vanilla/<model>` | Upstream license + attribution |
| Finetune on a Tessera Commons snapshot | `tessera-finetune/<model>` (maintainers) or `tessera-community/<you>/<model>` (anyone) | CC BY-NC-SA 4.0 (Tessera artifact terms) |
| Finetune on your own private data | Your own HF namespace, not a Tessera org | Whatever license you choose; Tessera does not govern it |
| Calibration stats you want to contribute to the Commons | `tessera-commons/<snapshot>` | You sign the contribution terms; the resulting dataset is CC BY-NC-SA 4.0 |

If your case is not in the table, ask before publishing.

## Where to ask

- License / commercial use: `julian@tribunus.dev`
- Recipe / upload tool: open an issue on the Tessera repo
- Contribution to the Commons: see [`TESSERA_CALIBRATION_CONTRIBUTION_TERMS_1.0.md`](TESSERA_CALIBRATION_CONTRIBUTION_TERMS_1.0.md)
- Anything else: the architect

## See also

- [`tessera-positioning.md`](tessera-positioning.md) - the 30-second version
- [`TESSERA_ARTIFACT_LICENSE_NOTICE.md`](TESSERA_ARTIFACT_LICENSE_NOTICE.md) - artifact license text
- [`TESSERA_CALIBRATION_CONTRIBUTION_TERMS_1.0.md`](TESSERA_CALIBRATION_CONTRIBUTION_TERMS_1.0.md) - contribution contract
- [`tessera-s2s-design.md`](tessera-s2s-design.md) section 8 - consent lane pattern
