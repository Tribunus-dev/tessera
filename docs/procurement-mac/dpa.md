# DPA - Data Processing Addendum (Personal SKU Cloud Opt-In)

Tessera Studio Mac - Personal SKU

This DPA applies only when a personal-SKU user opts into a cloud LLM
provider by providing their own API key. It does not apply to the
default on-device inference mode.

---

## 1. Parties and Roles

**User ("you"):**

You are the data controller. You decide what queries to send to the
cloud provider, what data to include in those queries, and when to
revoke the API key.

**Tessera Inc. ("we"):**

We are a mere conduit. We forward your query to the provider you
selected and return the response. We do not store, log, or retain
your prompts or the provider's responses. We do not train on your
queries.

**Cloud LLM Provider (OpenAI, Anthropic, Google, or other):**

The provider processes your query under their own privacy policy and
DPA. We are not their agent and cannot bind them. Their terms govern
their data practices.

---

## 2. Scope of Processing

When you provide an API key for a cloud LLM provider:

- **Input**: your query text, sent directly to the provider's API
  endpoint over TLS. Optionally, your active document context (if you
  enable "include document context" in Settings).
- **Output**: the provider's text response, streamed back to your
  device and displayed in the Tessera chat panel.
- **Tessera's role**: transport only. We do not parse, store, or log
  the query or response.
- **Tessera does NOT receive**: your API key (it stays in Keychain),
  your prompt, the provider's output, or any token counts.

---

## 3. Your API Key

- **Storage**: your API key is stored in Apple Keychain under the
  Tessera service, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
  It is never transmitted except to the provider's authentication
  endpoint.
- **Tessera never sees the key**: the Keychain is accessed via the
  system Security framework; the key value does not pass through
  Tessera application code in plaintext.
- **Revocation**: you may revoke the key at any time from the provider's
  dashboard. Revoking the key immediately invalidates it for Tessera.
- **Deletion**: removing the Tessera app destroys the Keychain entry.
  "Plead the Fifth" crypto-shred also destroys the Keychain entry.

---

## 4. What Tessera Does NOT Do

We explicitly state for avoidance of doubt:

- Tessera does **not** receive copies of your queries or the provider's
  responses.
- Tessera does **not** log prompts or outputs to any Tessera-managed
  storage.
- Tessera does **not** use your queries or outputs for model training.
- Tessera does **not** share your API key, query data, or provider
  identity with any third party.
- Tessera does **not** have access to your provider account, usage
  records, or billing information.

---

## 5. Cloud Provider's Responsibilities

Your query is governed by the cloud provider's terms:

- **OpenAI**: [Privacy Policy](https://openai.com/privacy),
  [Business Agreement](https://openai.com/enterprise-privacy).
- **Anthropic**: [Privacy Policy](https://anthropic.com/privacy),
  [Enterprise Agreement](https://anthropic.com/business).
- **Google AI**: [Privacy Policy](https://policies.google.com/privacy),
  [Gemini API Data Processing Amendment](https://cloud.google.com/terms/data-processing-addendum).

Review the provider's current privacy policy before opting in. Tessera
is not responsible for the provider's data practices.

---

## 6. Data Minimization and Retention

- **Tessera-side**: no retention. Queries and responses are not written
  to Postgres, Valkey, DuckDB, or SwiftData. They are not written to
  the receipt chain (the receipt records the provider name and model,
  not the content).
- **Provider-side**: governed by the provider's retention policy.
  OpenAI retains API inputs and outputs for 30 days by default for
  abuse monitoring (subject to their Business Agreement). Anthropic
  retains for 30 days for the same purpose. Review the current policy
  for the provider you choose.
- **Receipt chain record**: each cloud inference generates a receipt
  entry with `{ provider, model, timestamp, success }`. The prompt
  text and output text are NOT in the receipt.

---

## 7. Deletion

- **Tessera-side**: no Tessera data to delete. Deleting the app removes
  all local state (including the Keychain entry if you delete the
  Keychain item or use Plead the Fifth).
- **Provider-side**: revoke your API key from the provider's dashboard.
  Tessera cannot delete data held by the provider.
- **Future portability**: if you want a record of which queries you
  sent, use the provider's data export tools directly.

---

## 8. Security

- **TLS in transit**: all API calls use TLS 1.2+.
- **Keychain**: API key protected by `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- **No Tessera-managed secrets management**: the key is in your local
  Keychain, not in Tessera's infrastructure.
- **Encrypted volume**: the Keychain entry lives inside the encrypted
  volume mount; the volume password is in a separate Keychain entry.
  Both are destroyed on Plead the Fifth.

---

## 9. Compliance Notes for the User

This DPA is provided for your information. You are responsible for:

- Ensuring your use of cloud LLM providers complies with your
  organization's policies.
- Reviewing the provider's current privacy policy and DPA.
- Determining whether your data in the provider's system meets your
  regulatory requirements (HIPAA, FERPA, GDPR, etc.).
- The Enterprise SKU (see `../procurement/DPA.md`) provides a Tessera-managed
  BAA for regulated environments. The personal SKU does not.

---

## 10. Contact

Privacy: `privacy@tessera.example`
