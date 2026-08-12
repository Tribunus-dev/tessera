# Premium Agent-Centric UX with AI Fatigue as a First-Class Constraint

A research brief for translating into a Mavis skill. Date: 2026-08-12. The brief is written for a Mavis / Claude Code / Cursor agent being briefed to design or evaluate a premium agent product. It is evidence-anchored, opinionated, and structured so an agent can reason from it rather than just pattern-match.

## One-sentence verdict

Premium agent UX is the design discipline of *maximizing value delivered per unit of human attention and trust spent*, with AI fatigue as the load-bearing constraint. Every pattern in this brief is a tactic for spending that budget well; the skill must teach the agent to think in units of attention and trust, not in units of features and screens.

## The validated constraint: AI fatigue

AI fatigue is not a vibe. It is a validated four-factor psychological construct, with a 15-item measurement scale published in 2026 by Lau, Hartanto et al. in *Computers in Human Behavior Reports* [1]. Four studies, n = 717 (one summary reports n = 720), scale reliability α = .92, two-week test–retest ICC(2,1) = .65, four-factor model: cognitive, emotional, physical, behavioural. The scale is a measurement instrument, not a marketing term.

The 15 items are the operational definition. A skill that does not internalize these four factors will ship patterns that fight one while worsening another.

| Factor | What it measures | Sample item |
|---|---|---|
| Cognitive | Overwhelm from volume, complexity, pace of AI content | "I find it difficult to process the large amount of AI content I encounter online." |
| Emotional | Strain, frustration, negative affect | (items 5–7) |
| Behavioural | Avoidance, disengagement | (items 8–11) |
| Physical | Eye strain, fatigue, sleep disruption | "My eyes can feel strained after extended time with AI." |

The convergent and discriminant validity is what makes the construct load-bearing. AI fatigue is *distinct* from general fatigue, clinical fatigue, digital fatigue, technostress, AI dependency, AI attachment, and critical-thinking style. The skill should not collapse it into any of those — they are neighbours, not synonyms.

The construct predicts downstream behaviour. Greater AI fatigue predicted lower current AI use and stronger intentions to reduce use in the next three months, *above and beyond* general, clinical, and digital fatigue and AI-specific technostress. In plain terms: this is a fatigue people act on, and they act on it specifically because of AI.

There are parallel validated constructs the skill must distinguish. The 2025 academic consensus on AI cognitive offload, led by Baldeo in *Technology, Mind, and Behavior* (n = 1,923 North American workers), found that 58% ± 7% agreed "AI did most of the thinking" on simulated executive tasks, and that greater prompt dependence and lower override frequency correlated with reduced self-reported confidence in independent reasoning (r = −.61, p < .01) [2]. The Acta Psychologica 2025 study on 580 Chinese university students found cognitive fatigue mediates the link between AI dependence and reduced critical thinking, with information literacy a partial moderator [3]. The skill should treat cognitive offload as a mechanism *behind* the cognitive factor of AI fatigue — not a separate construct, but the causal story that explains the cognitive exhaustion.

Caveat: the Baldeo study is currently under a formal review by APA's *Technology, Mind, and Behavior*. Editor-in-chief Richard N. Landers has confirmed an investigation into methodology, data integrity, and research ethics. The numbers above are from the original publication and are widely cited; the skill should treat them as evidence-in-good-faith subject to a community-pending review. The single-sourced aspect is one reason this brief avoids putting that one paper at the centre of any argument on its own.

Three related constructs, each with their own measurement and a different mitigator:

- **Confirmation fatigue**: the security-graded phenomenon where humans habituate to repetitive approval prompts and click through reflexively after 3+ confirmations. Now classified as a security vulnerability in OWASP ASI09 (Human-Agent Trust Exploitation), item 9 of the *OWASP Top 10 for Agentic Applications 2026* [4]. Anthropomorphism abuse, authority bias, and confirmation fatigue are the three vectors; the four operational controls are friction-by-design, structured presentation, rate-limiting with approval budgets, and adversarial-frame detection. Treating confirmation fatigue as "just UX" misses the security framing.
- **Notification fatigue**: the empirical ceiling on unsolicited AI updates. Tian Pan's 2026 analysis puts the daily tolerance at ~3–5 across all sources combined, against a backdrop of 46–63 push notifications per day from all apps; recovery from a single interruption averages ~23 minutes; ~50% of users who disable push notifications eventually churn from the product entirely [5]. The metric that actually predicts retention is *notifications acted on*, weighted by action value, not notifications sent.
- **Flow destruction**: foundational work by Gloria Mark (UC Irvine, CHI 2005 and CHI 2008) and Mark/Gudith/Klocke found it takes 23 minutes and 15 seconds to recover the same depth of focus after an interruption; interruptions as short as five seconds triple error rates during complex cognitive work; people who are interrupted frequently begin *interrupting themselves* [6]. Csikszentmihalyi's flow theory — clear goals, immediate feedback, challenge-skill balance — names the conditions the agent loop breaks every time it pulls the user out to evaluate output. The agentic prompt-wait-evaluate loop is the structural anti-flow state.

These four constructs are the constraint surface the skill must engineer against. They map onto each other (notification fatigue is mostly cognitive + emotional; confirmation fatigue is mostly cognitive + behavioural; flow destruction is cognitive; AI fatigue is the umbrella) but each has its own evidence base and its own mitigator. The skill must not treat them as interchangeable.

## The premium agent journey

A premium agent product is not a chat surface. The journey is the end-to-end arc the user moves through, and the chat default is the *least* premium surface on it. The premium surfaces are structured, contextual, and reversible: file diff, artifact, inline suggestion, calendar card, approval chip, audit log, progress feed. The chat thread is a fallback, not a destination.

Seven stages, each with the load-bearing design question and the AI-fatigue factor most at risk:

1. **Discovery / landing** — first impression. The premium move is editorial restraint: typography chosen with intent, palette disciplined, no purple gradient, no stacked-card SaaS grid, no "elevate / seamless / unleash" copy. The Anthropic *Frontend Aesthetics Cookbook* names the failure mode directly: "You tend to converge toward generic, 'on distribution' outputs. In frontend design, this creates what users call the 'AI slop' aesthetic" [7]. The default LLM output *is* the AI slop baseline; premium is what survives the cookbook's anti-cliché pass. Fatigue risk: emotional (cheap-feeling surface creates low-grade contempt that compounds).
2. **Onboarding / first 5 minutes** — the aha moment. Different products have different ahas, and the skill must not default to "ask the user". Devin's aha is a repo-aware plan with citations before any code is touched (Cognition reported PR merge rate 34% → 67% YoY). Cursor's aha is VS Code settings migration in 30–60 seconds. Claude Code's aha is the `/init` command producing a CLAUDE.md that demonstrates the agent understands the project. Replit's aha is deployed app in 15 minutes. Lindy's aha is the template-driven "hire an employee" flow [8]. The unifying rule: kill the blank canvas, show 3–5 guided first tasks, make wait states productive (Devin produces DeepWiki documentation during indexing). Industry bar: 60 seconds to meaningful output. AI/ML category activation rate is 54.8% (highest of all SaaS categories), but 90% of users who fail to get value in the first week churn. Fatigue risk: cognitive + emotional.
3. **First task** — the verification paradox made visible. The user has to verify the agent's first output. The most expensive cost in the entire agent product is the cognitive cost of trusting it. 43% of the 503-respondent Human Clarity Institute dataset report verification of AI output as mentally taxing; 32% report prompt construction as mentally taxing [9]. Make verification cheap: side-by-side evidence, structured diffs, provenance surfaces, confidence signals that change visibly with input. Fatigue risk: cognitive (the dominant one).
4. **Sustained use / agent loop** — the prompt-wait-evaluate cycle. This is the flow-destruction stage. The fix is not fewer interruptions, it is *batched* and *bounded* interruptions: separate AI-assisted phases (planning, refactoring, documentation, test generation) from flow-zone phases (deep problem solving, architecture, core logic). The 23-minute Mark recovery number is the budget the agent loop spends every time it demands a turn. Fatigue risk: cognitive + emotional + physical.
5. **Proactive / ambient mode** — the off-ramp adjacent. Background agents that fire 10 notifications a week are the same agents users mute by Friday. The 3–5/day ceiling is the budget; the planner inside the agent must see the budget as part of its state. If it has spent the budget, the next candidate must displace an already-fired notification (almost never the right move) or wait [5]. Fatigue risk: emotional + behavioural (this is where people stop opening notifications, then stop opening the product).
6. **Off-ramp / kill switch** — the first-class stage. CSIRO's Responsible AI Pattern Catalogue's *AI Mode Switcher* is the canonical pattern: a kill switch for the AI component that can immediately shut it down at runtime, deferring the architectural decision to the user at execution time [10]. Microsoft Research's *HAX Toolkit* (the 18 Guidelines for Human-AI Interaction, validated through 20+ years of research) lists "Support efficient dismissal" as an explicit guideline [11]. Anthropomorphism, authority bias, and trust are all healed in part by a real, visible, inline exit. The instinct to bury the off-ramp in settings is the wrong instinct. Fatigue risk: emotional (control restoration is the strongest single defence against AI-induced autonomy loss).
7. **Recovery from failure** — the trust-rebuild stage. The Three-Phase Trust Lifecycle (Tian Pan, 2026): initial over-trust (algorithm appreciation) → jarring failure → over-correction to under-trust (algorithm aversion) [12]. Trust builds slowly, breaks fast; one high-salience failure outweighs 100 quietly correct suggestions. *Recovery* with well-designed explanations can exceed pre-failure levels because the failure becomes a calibration reference point. The error design must distinguish "the AI was uncertain and said so" from "the AI was confident and was wrong" — only the second is a trust update. Fatigue risk: emotional (broken trust converts to behavioural disengagement).

The premium feel is the consistency of these stages. It is what survives the failure to be perfectly executed at any single one. A product with mediocre onboarding but excellent off-ramp outlasts a product with spectacular onboarding and a hidden kill switch. The off-ramp is the same weight class as the first 5 minutes.

## The pattern catalog, with provenance and fatigue mitigation

The following patterns have all appeared in the 2026 agent-UX literature, most in multiple sources. Each is paired with the fatigue factor it most reduces and the failure mode that flips it into a net negative.

| Pattern | Source / provenance | Fatigue factor reduced | Failure mode if misused |
|---|---|---|---|
| Intent Preview (plan summary before execution) | Smashing Magazine 2026-02 [13]; Mantlr 10-pattern catalog [14] | Cognitive (verification) | Becomes a confirmation prompt that fabricates fatigue |
| Autonomy Dial (per-task permission level) | Smashing Magazine 2026-02 [13]; Mantlr [14] | Emotional (loss of control) | Global dial grants too much or refuses too much |
| Risk-Tiered Approval Gates (Tier 0/1/2/3) | OWASP ASI09 [4]; GaaS [15] | Cognitive + emotional (confirmation fatigue) | Tier 0/1 boundary drift; non-urgent gates on every action |
| Approval-Budget Rate-Limiting (cap per session, escalate beyond) | Zealynx OWASP ASI09 explainer [4]; Truto [16] | Confirmation fatigue (security) | Budget that the planner can game around |
| Batched Approvals (homogeneous low-stakes actions in one review) | Menu Agentic [17] | Cognitive + emotional | Lists the user still won't read |
| Structured Presentation (parsed call data, not agent-authored prose) | OWASP ASI09 [4] | Cognitive (verification) | Loses the prose framing in cases where prose *is* more useful |
| Adversarial-Frame Detection (strip urgency/authority/anthropomorphic claims) | OWASP ASI09 [4] | Confirmation fatigue (security) | False positives that strip legitimate urgency |
| Progress Feed (lightweight async narration of agent activity) | Agent Market Cap 2026-04 [18]; Zylos [19] | Cognitive (status check cost) | Pollutes the screen, becomes a notification |
| Plan-and-Execute (show plan, get implicit/explicit approval, then act) | Smashing Magazine [13]; AYDesign [20] | Cognitive (verification) | Plans too verbose; users stop reading the plan |
| Generative UI: Static (tool-bound components the agent picks) | Zylos 2026-05-28 [21] | Cognitive (UI inconsistency) | Inventory grows without governance |
| Generative UI: Declarative A2UI / JSON schema | Zylos [21] | Cognitive (UI consistency) | Schema drift between agent and renderer |
| Live Tool Execution Visibility (every call with inputs/outputs/elapsed) | Zylos [21]; Smashing Magazine [13] | Cognitive (trust calibration) | Becomes a wall of JSON; not skimmable |
| Confidence Signal (categorical High/Medium/Low, not numeric %) | Tian Pan [12]; Google PAIR | Trust miscalibration | Numeric confidence misinterpreted (LLMs themselves are miscalibrated) |
| Explainable Rationale ("Because you said X, I did Y") | Smashing Magazine [13]; Google PAIR | Trust miscalibration | Becomes a wall of generated prose |
| Action Audit Log (chronological list of every action + outcome) | Smashing Magazine [13]; Anthropic Artifacts | Trust + reversibility | Forgetting the un-undo button; stale entries |
| Time-Limited Undo ("available for 15 minutes") | Smashing Magazine [13] | Emotional (regret cost) | Time window not visible; user surprised at expiry |
| Escalation Pathway (handoff to human when stuck) | Smashing Magazine [13] | Emotional (dead-end frustration) | Used as a fallback for normal failures |
| AI Mode Switcher (kill switch for the AI component) | CSIRO [10] | Emotional + behavioural (autonomy) | Hidden in settings; doesn't actually kill |
| "Big friendly stop button" inline at the moment of action | Medium agentic UX essays [22] | Emotional (loss of control) | Not a hard stop; AI resumes after manual take |
| Off-ramp in the same menu / toolbar as the action | Roger Wong "Agent UX" 7 principles [23] | Emotional (loss of control) | Off-ramp is 3 screens away |
| Ambient Agent: Notify / Question / Review (3-tier pattern) | LangChain AAP [24] | Notification + emotional | Silent ambient agent is forgotten; loud one is muted |
| Notification Budget (3–5/day cap, value-vs-attention scoring) | Tian Pan 2026-05-13 [5] | Notification + emotional | Budget that the planner can game; misuse of "high-value" override |
| Batched Notification Digsests (time-of-day windows) | Zylos [25] | Notification + cognitive | Forcing the user into a window they don't use |
| First-5-Minutes: define aha explicitly, kill blank canvas | Zylos 2026-03-29 [8] | Cognitive + emotional (activation) | Vague "aha" never lands; curated tasks go stale |
| Autonomy progression gated on ≥85% acceptance rate | Zylos [8] | Trust + emotional | Premature promotion to autonomy burns trust |
| Empty-State Suggestions (3–5 curated first tasks at all times) | Zylos [8] | Cognitive + emotional | Suggestions go stale, become noise |
| Personalised task ping within 24h of empty state | Zylos [8] | Behavioural (activation) | Pings that fire every time the agent is idle |
| Onboarding as context gathering, not education | Zylos [8] | Cognitive + emotional | Treating the user as a student |
| Active use > passive use (override, refine, reject for cognitive engagement) | Baldeo APA TMB 2025 [2] | Cognitive (offload atrophy) | UI that only offers accept; no edit affordance |
| Reversibility-engineered design ("make the action reversible first, then maybe drop the gate") | Menu Agentic [17] | Emotional (regret cost) | Reversibility as a check-the-box claim |
| Adaptive notification threshold (learn per-user dismiss behaviour) | Tian Pan 2026-05-13 [5] | Notification | Treating all users the same |
| Pre-action limitation disclosure (tell users what the AI can't do, up front) | Tian Pan [12] | Trust + emotional | Disclaimers that read like legal copy |
| Error design that distinguishes "uncertain" from "confident and wrong" | Tian Pan [12] | Trust + emotional | All failures treated as catastrophic |

Two rules that govern the catalog as a whole:

1. **The dimension that matters for tiering is reversibility and blast radius, not action type.** "Confirm before any write" is the anti-pattern that manufactures fatigue. Tier by consequence: is it reversible cheaply, what is the worst case, can we make the action reversible first so the heavy gate becomes unnecessary.
2. **Any pattern that demands the user's attention costs fatigue.** The skill's job is to minimize *count* of decisions, not just their friction. A gate the user clears in under a second is not a gate — it's a reflex being trained.

## The six load-bearing paradoxes

These are the non-obvious tensions the skill must teach the agent to *diagnose*, not just pattern-match against.

**The verification paradox.** AI is supposed to reduce cognitive load, but the cognitive cost *of using AI* is dominated by the cost of verifying AI outputs. ~43% of users in the 2025 HCI dataset find verification mentally taxing; the cognitive cost of *using* AI is the cost of *trusting* AI. The premium moves are therefore about making verification cheap — structured diffs, side-by-side evidence, provenance surfaces, confidence signals that change with input — not about removing the need to verify. A skill that promises "the AI just works, no need to check" is selling a security disaster and a fatigue accelerant in one breath.

**The autonomy paradox.** More autonomy → more fatigue, not less. The human must monitor more, not fewer agent actions. The Autonomy Dial is the answer, but it must be per-task, not global: a global dial either grants too much or refuses too much, and the user can't tell which is worse until it is. The premium pattern is the dial *and* the approval budget, applied per-task, with rate-limited escalation when the budget is spent.

**The chat-default paradox.** The chat-first LLM interface is the *least* premium surface for an agent product. It hides verification, hides reversibility, hides audit, and concentrates the user's attention on the lowest-bandwidth surface in the product. The premium surfaces — file diff, artifact, inline suggestion, calendar card, approval chip, audit log, progress feed — are all structured, contextual, and reversible. The skill should treat chat as a fallback, not a destination.

**The empty-canvas paradox.** "Ask me anything" → paralysis. Curated starter prompts → activation. This is a free win and the most-violated pattern in 2026 agent products. The skill should treat the empty prompt surface as a bug, not a feature. Always show 3–5 guided first tasks. Always show suggested follow-up tasks after a successful one. The empty state is the highest-leverage state in the entire product and the one most often ignored.

**The off-ramp paradox.** People will try a feature they know they can escape from instantly. The exit is what makes them comfortable entering. The instinct to bury the off-ramp in settings is wrong; the instinct to omit it is worse. The off-ramp is the same weight class as the first 5 minutes. The skill should treat the off-ramp as a *positive* design element, not a safety check, because its primary function is to make the on-ramp work.

**The XAI paradox.** Explanations meant to build trust can instead trigger automation bias by overloading working memory. Detailed explanations overload working memory and inadvertently encourage cognitive shortcuts [26]. The premium move is the minimum explanation that changes trust: categorical confidence over numeric, single-line rationale over multi-paragraph, evidence surface over prose description. More explanation is not always more trust; sometimes it is less.

**The proactive-agent paradox** (the seventh, for the off-ramp-adjacent stage). Background agents that don't interrupt are forgotten; background agents that do are muted. The 3–5/day ceiling is the budget; the planner inside the agent must see the budget as part of its state. If it has spent the budget, the next candidate must *displace* an already-fired notification (almost never the right move) or *wait*. Treat notifications as withdrawals from a finite account, not deposits into an engagement funnel.

## The off-ramp as a first-class stage

The off-ramp gets its own section because the literature and the user-fatigue research both keep surfacing it as the single most under-designed stage. Three sources of evidence, three different framings, one consistent conclusion:

- **CSIRO Responsible AI Pattern Catalogue's AI Mode Switcher** [10]: a kill switch for the AI component that can immediately shut it down at runtime, deferring the architectural decision to the user at execution time. The framing is *contestability and autonomy*: users must be able to override the AI at any runtime.
- **Microsoft Research's HAX Toolkit Guidelines 9 and 14** [11]: "Support efficient dismissal" and "Provide global controls" — both 2019 CHI-validated guidelines for human-AI interaction, sitting in the *During Interaction* and *Over Time* buckets.
- **OWASP ASI09 (Human-Agent Trust Exploitation)** [4]: confirmation fatigue is a security vulnerability, not a UX annoyance. The off-ramp reduces the attack surface for anthropomorphism abuse and authority bias because the user has a structural way to exit a manipulation flow.

The off-ramp has three required affordances:

1. **Inline at the moment of action** — a visible, large, labelled button at the same place the agent is acting, not a buried settings toggle. Microsoft's HAX "efficient dismissal" is the principle; the implementation is *in the same surface as the action*.
2. **A hard stop, not a deferral** — taking over should not be undoing the AI's work. The thermostat-on-a-schedule metaphor is the right model: a manual nudge holds until the next scheduled slot.
3. **A first-class control, not a safety hatch** — the off-ramp is not a confession of failure; it is the *positive* design element that makes the on-ramp work. People will try features they can escape from. The off-ramp is the trust signal that earns the right to be in the user's loop at all.

The premium framing is: *the off-ramp is part of the value proposition, not a safety feature.*

## Product exemplar matrix

The patterns are real because they ship. The matrix below pairs each pattern family with a specific shipped move from a real 2026 product, drawn from the research base.

| Pattern family | Exemplar | The specific move |
|---|---|---|
| Plan-and-execute | Claude Code | `/init` produces CLAUDE.md before the first task; plan mode + todo list makes the agent's reasoning legible before any tool call [8] |
| File diff as primary surface | Cursor 3 (2026) | Wired: text-first agent IDE, file diffs as conversation, agent sidebar [27] |
| Reversibility + replayable session | Devin | Browser+shell+editor in one session window; Session Insights with timeline, feedback, improved prompts; Knowledge Cards; PR merge rate 34% → 67% YoY [8] |
| In-context activation | Notion AI | No wizard; AI activates inside the existing document [20] |
| Utility minimalism | Granola | Real product screenshots, honest density, quiet brand color [28] |
| Editorial restraint / warm monochrome | Anthropic Claude | Tinted cream canvas, serif display headlines, warm coral CTAs, dark navy product surfaces, slab-serif display [29] |
| Anti-AI-slop guardrails (system-prompted) | Anthropic Claude Design (2026-04-17) | The <frontend_aesthetics> system prompt that ships in the cookbook, banning Inter/Roboto/Arial/Space Grotesk, purple gradients, generic SaaS card grids [7] |
| Hired-employee mental model | Lindy | Template library → form wizard → integration setup → test run → go-live; "hire" language throughout [8] |
| Zero-barrier trial + 60s to output | Replit Agent | No environment setup; agent immediately accessible in-browser; deployed app in 15 minutes [8] |
| Ambient agentic surface | Anthropic Artifacts (2024) | Right-rail artifact surface for generated code, documents, designs; chat thread is the discussion, artifact is the deliverable |
| Agent permission gating | Microsoft Copilot | Approval gate before emails, spend, destructive file operations [20] |
| Private / device-local default | Apple Intelligence | System-wide Siri intents with on-device processing; privacy as a premium position |
| Generated side-by-side artifact | ChatGPT Canvas | Editable side-by-side document, the chat is the prompt, the canvas is the artifact |

These are not endorsements. They are evidence that the patterns have shipped in products that are *also* premium in their craft. The skill can use them as anchor points: "this is what the pattern looks like in production".

## The premium craft language (anti-AI-slop guardrails)

The skill must be opinionated about taste because the default LLM output *is* the AI slop baseline. The premium move is to ban the defaults by name, not to instruct in the abstract. The verbatim list from Anthropic's cookbook [7] is the canonical set:

**Banned fonts (use anything else):** Inter, Roboto, Arial, Space Grotesk, system fonts. (OpenAI's parallel `frontend-skill` and Anthropic's `frontend-design` both list this; the OpenAI version shipped alongside GPT-5.4 with identical guardrails.)

**Banned colors and patterns:** purple gradients on white backgrounds, pastel rainbow accents, indigo-to-violet hero washes, generic glassmorphism, animated gradient blobs, soft drop shadows used as decoration.

**Banned layouts:** centered hero with eyebrow + 64-pt headline + subhead + two CTAs, three-up feature cards, logo soup, pricing toggle, FAQ accordion, stacked-card SaaS grids, Shadcn-default cards, Tailwind-default rounded-xl buttons.

**Banned copy:** "Elevate", "Seamless", "Unleash", "Next-Gen", "Game-changer", "Delve" and the wider "AI copywriting cliché" vocabulary.

**Banned copy *about AI itself*:** the line that ships in 2026 marketing: "Powered by AI", "Intelligent assistant", "Smart", "Next-generation". Premium AI products describe what the product does, not what technology it uses.

**The three default looks the cookbook names directly**, all legitimate for some briefs but defaults rather than choices:
1. A warm cream background (near `#F4F1EA`) with a high-contrast serif display and a terracotta accent.
2. A near-black background with a single bright acid-green or vermilion accent.
3. A broadsheet-style layout with hairline rules, zero border-radius, and dense newspaper-like columns.

The Anthropic `frontend-design` skill names the same three looks. Anthropic's own Claude Design marketing page falls into look #1 by their own admission [7]. The skill must teach the agent to recognize that those defaults are not premium, just *familiar*. Premium is what survives an explicit named aesthetic choice, not what lands in the centroid.

**The premium craft vocabulary** the skill should hand the agent:
- **Aesthetic families to pick from**: Editorial Minimalism (Linear, Stripe, Vercel, Mintlify); Terminal-Core (Ollama, Warp, Raycast, OpenCode); Warm Editorial (Anthropic, Notion, Resend, Substack); Data-Dense Pro (ClickHouse, PostHog, Grafana, Sentry); Cinematic Dark (Runway, ElevenLabs, Midjourney); Playful Color (Figma, Duolingo, Mailchimp, Cal.com); Glass/Soft-Futurism (Apple, Arc, Airbnb, Spotify); Neon Brutalist (The Verge, Pitchfork, PlayStation); Cult/Indie (A24, Criterion, Letterboxd, Obsidian) [29].
- **Type principles**: pair display and body faces deliberately, set a clear type scale with intentional weights, widths, and spacing; make the type treatment itself memorable.
- **Color discipline**: dominant colors with sharp accents outperform timid, evenly-distributed palettes; draw from IDE themes and cultural aesthetics; use CSS variables.
- **Motion**: orchestrated, not scattered; one well-timed page load with staggered reveals beats scattered micro-interactions.
- **Surfaces**: editorial minimalism — cream/bone canvases, thin 1px borders, no large drop shadows, flat cards, no pill shapes on large containers, no emoji as icons.

**A working anti-cliché snippet the skill can drop into a project system prompt**, derived directly from the Anthropic cookbook:

```
You tend to converge toward generic, "on distribution" outputs. In frontend design,
this creates what users call the "AI slop" aesthetic. Avoid this. Make creative,
distinctive frontends that surprise and delight.

Typography: Choose fonts that are beautiful, unique, and interesting. Avoid generic
fonts like Arial and Inter; opt for distinctive choices that elevate the frontend's
aesthetics.

Color & Theme: Commit to a cohesive aesthetic. Use CSS variables for consistency.
Dominant colors with sharp accents outperform timid, evenly-distributed palettes.

Motion: Use animations for effects and micro-interactions. Prioritize CSS-only
solutions for HTML. Focus on high-impact moments: one well-orchestrated page load
with staggered reveals creates more delight than scattered micro-interactions.

Backgrounds: Create atmosphere and depth rather than defaulting to solid colors.
Layer CSS gradients, use geometric patterns, or add contextual effects.

Avoid generic AI-generated aesthetics: overused font families (Inter, Roboto, Arial,
system fonts); clichéd color schemes (particularly purple gradients on white
backgrounds); predictable layouts and component patterns; cookie-cutter design
that lacks context-specific character. Vary between light and dark themes, different
fonts, different aesthetics. [7]
```

A known bug in the upstream skill's instruction "never converge across generations" is technically incoherent — a single conversation has no memory of previous generations. A 75% win rate has been reported in a community fork that rewrote the rule to be actionable within a single generation [7]. The skill should ship the corrected version.

## Translating the research into a Mavis skill

The deliverable is a Mavis `SKILL.md` file. The format is standardized and load-bearing; getting it wrong means the skill will not activate when the user needs it.

### SKILL.md format essentials

The Agent Skills standard is documented at [agentskills.io/specification](https://agentskills.io/specification) and verified in production by the Anthropic `frontend-design` skill (8.07 KB, 55 lines, 277,000+ installs as of March 2026). The required structure:

- **YAML frontmatter** at byte 0 (no leading whitespace, no BOM), delimited by `---`. Required fields: `name` (1–64 chars, lowercase letters/numbers/hyphens, must match the parent directory name, no leading/trailing hyphens, no consecutive hyphens) and `description` (1–1024 chars, drives auto-loading — the most important field in the file). Optional: `license`, `compatibility`, `metadata`, `allowed-tools`.
- **Markdown body** after the closing `---`. The agent reads the body on demand when the skill is activated. Recommended sections: step-by-step instructions, input/output examples, common edge cases.
- **Progressive disclosure**: `name` + `description` loaded at startup for all skills (~100 tokens), full body loaded on activation (<5000 tokens recommended), referenced files in `scripts/`, `references/`, `assets/` loaded only when required.

### Frontmatter `description` best practices

The description determines whether the skill activates. From the Agent Skills documentation, the principles [30]:

- **Imperative phrasing**. "Use this skill when..." rather than "This skill does...". The agent is deciding whether to act; tell it when to act.
- **Focus on user intent, not implementation**. Match against what the user asked for.
- **Be pushy**. Explicitly list contexts where the skill applies, including cases where the user doesn't name the domain directly.
- **Be concise**. A few sentences to a short paragraph.

A candidate `description` field for this skill (under 1024 chars):

```
Use this skill when the user is designing, reviewing, or shipping an AI agent
product, AI assistant, AI employee, AI co-pilot, AI workflow automation, or any
product where an AI system acts on the user's behalf with some autonomy. Apply
to: agent UX journeys (onboarding, first task, sustained use, ambient mode,
off-ramp), approval and confirmation patterns, notification and interruption
design, trust calibration surfaces, anti-AI-slop craft choices, premium product
positioning. Do NOT use for non-agent AI products (pure chat, image generation,
code completion without tool use). Load when the user says "agent UX", "agent
design", "AI fatigue", "confirmation fatigue", "notification fatigue", "trust
calibration", "premium agent", or asks how to make an AI product feel premium
without burning the user out.
```

### Recommended skill structure (one canonical artifact, no versioned siblings)

The user has stated a preference for no versioned parallel implementations. The skill ships as one canonical artifact. The body is organized in seven sections, each with a defined purpose:

1. **TL;DR — the one-sentence verdict** the agent should internalize: *premium agent UX is the design discipline of maximizing value delivered per unit of human attention and trust spent, with AI fatigue as the load-bearing constraint.*

2. **The four-factor AI fatigue model** — the 15-item scale summarized in one table, with the four factors (cognitive, emotional, physical, behavioural) and a one-line example item for each. This is the constraint surface. Every pattern below is evaluated against which factor it reduces.

3. **The premium agent journey** — the seven stages (discovery, onboarding, first task, sustained use, ambient mode, off-ramp, failure recovery) with the load-bearing design question and dominant fatigue factor for each. Stage 6 (off-ramp) is the same weight class as stage 2 (onboarding).

4. **The pattern catalog** — the 30+ patterns in a single compact table, columns: pattern, fatigue factor reduced, failure mode if misused. The skill should be readable as a single screen. Each pattern's full description lives behind the table.

5. **The paradoxes** — the seven load-bearing tensions the agent must diagnose. Each gets one paragraph: name the paradox, name the mechanism, name the premium mitigation. The verification paradox and the autonomy paradox are the two most-cited.

6. **The off-ramp as a first-class stage** — its own section because the literature and the user-fatigue research both keep surfacing it. Inline at the moment of action; hard stop, not deferral; positive design element, not safety hatch.

7. **The premium craft guardrails** — the anti-AI-slop rules in operational form: banned fonts, banned colors, banned layouts, banned copy, named aesthetic families, the verified anti-slop system-prompt snippet. The skill should ship the snippet so the agent can drop it into a project.

8. **The skill brief appendix** — what the agent should produce when the user asks for an agent UX review or design. A short decision tree: what stage of the journey is the user at; which fatigue factor is most at risk; which patterns apply; what is the smallest set of moves that closes the biggest fatigue gap. The skill should not produce a 50-item checklist; it should produce the smallest move that does the most work.

9. **Anti-patterns to refuse** — explicit list. The chat-default surface. The "ask me anything" empty canvas. The blanket "confirm every action" gate. The trust-via-numeric-percentage disclosure. The off-ramp buried in settings. The agent-authored prose without structural data. The progress bar without a progress *feed*.

10. **Open questions and unverified claims** — short list. The Devin PR merge rate 34% → 67% YoY is from a single secondary source and should be presented with that caveat. The Baldeo APA TMB 2025 paper is under community-pending review; the n = 1,923 / 58% / r = −.61 numbers are widely cited but should be flagged. The 3–5/day notification ceiling comes from a single secondary analysis; the underlying cognitive cost research (Mark 2005/2008, 23-minute recovery) is rock-solid.

### What the skill does *not* cover (out of scope, by design)

- LLM model architecture, fine-tuning, RAG, embeddings, vector DBs.
- Pricing, packaging, GTM, enterprise procurement.
- EU AI Act, sector regulation, accessibility (WCAG), internationalization — all ambient design constraints, none of them the skill's subject.
- Voice-first agents, embodied agents, robotics — different design space.
- Marketing pages, brand identity, naming.

## Open questions and caveats

- **Devin PR merge rate 34% → 67% YoY**: from Zylos's 2026-03-29 research, attributed to a Cognition performance review. Single secondary source. The number is plausible given Devin's positioning but should be marked as second-hand until a Cognition source is found.
- **Baldeo APA TMB 2025 (n = 1,923)**: under formal review by APA's *Technology, Mind, and Behavior* as of 2026. The 58% offload / r = −.61 numbers are widely cited. The skill should treat them as evidence-in-good-faith subject to community review, not as settled.
- **OWASP ASI09 as 2026 standard**: the 2026 edition of the *OWASP Top 10 for Agentic Applications* is recent; ASI09 is item 9. The standard is a published list, the explainers (Zealynx, etc.) are secondary. The four-mitigation pattern is consensus but the security framing of confirmation fatigue is OWASP-driven, not the agent-UX community's traditional framing.
- **3–5 unsolicited AI notifications per day ceiling**: single-source (Tian Pan, 2026-05-13). The 46–63 push notifications per day baseline is a separate stable industry number; the specific 3–5/day AI ceiling is the new claim. The number is widely cited but the underlying methodology is an industry analysis, not a controlled study.
- **Microsoft 2025 Work Trend Index (interruptions every 2 minutes, 80% feel they don't have enough time)**: cited in the Tian Pan notification post and the courier.com post. The Microsoft WTI 2025 report itself is the primary source; the number is plausible and consistent with Mark's earlier work but should be checked against the WTI 2025 PDF directly before being quoted in the skill.
- **Claude Design launch 2026-04-17, Opus 4.7, Figma stock −12% within 2 weeks**: from secondary sources (pasqualepillitteri.it, theadpharm.com). Plausible and widely reported, but the Figma stock move should be checked against a financial source before being quoted.
- **Trust calibration curve (74% of companies struggle to scale AI value; 6% of organizations fully trust AI agents for core processes)**: from Tian Pan's 2026-04-12 post, attributed to BCG. The 74% number is real and well-publicized from BCG's October 2024 AI adoption report. The 6% is harder to source and may be a secondary restatement. Both are useful directional signals, not precise metrics.
- **GitClear 41% higher code churn in AI-assisted code**: from Tian Pan's post, attributed to GitClear research. Real and well-publicized but the methodology (churn as a proxy for quality) is contested in the engineering community. The skill can use the number as a directional signal, not as a quality verdict.

## References

[1] Lau, G. R., Kasturiratna, K. T. A. S., Goh, A. Y. H., Tong, E. M. W., & Hartanto, A. (2026). AI fatigue in human–AI interaction: Conceptual framework, scale development and validation, and associations with AI engagement. *Computers in Human Behavior Reports*, 23, 1–19. https://doi.org/10.1016/j.chbr.2026.101186. Also: https://ink.library.smu.edu.sg/soss_research/4462/. Preprint: https://sciety.org/articles/activity/10.31234/osf.io/kp7zs_v1. Includes the full 15-item AI Fatigue Scale wording.

[2] Baldeo, S. (2026). Generative artificial intelligence reliance and executive function attenuation: Behavioral evidence of cognitive offload in high-use adults. *Technology, Mind, and Behavior*. https://doi.org/10.1037/tmb0000191. (Note: under formal review by APA TMB as of 2026; see https://www.academicjobs.com/research-publication-news/apa-journal-probes-generative-ai-cognitive-study-or-research-news-23455. Press release: https://www.newswire.ca/news-releases/new-research-finds-ai-can-improve-cognition-818896363.html.)

[3] Learners' AI dependence and critical thinking: The psychological mechanism of fatigue and the social buffering role of AI literacy. *Acta Psychologica*, 260, 105725. https://doi.org/10.1016/j.actpsy.2025.105725. https://pubmed.ncbi.nlm.nih.gov/41076923/.

[4] OWASP Top 10 for Agentic Applications 2026 — item ASI09 Human-Agent Trust Exploitation. Primary: https://genai.owasp.org/resource/owasp-top-10-for-agentic-applications-for-2026/. Operational explainer with the four mitigation patterns (friction-by-design, structured presentation, rate-limiting/approval budgets, adversarial-frame detection): https://www.zealynx.io/blogs/owasp-asi09-human-agent-trust. Also: https://www.zealynx.io/glossary/approval-budget-rate-limiting.

[5] Pan, T. (2026-05-13). Background Agents and the Notification Budget: Why Proactive AI Hits a Hard Ceiling at User Attention. https://tianpan.co/blog/2026-05-13-background-agents-notification-budget-attention-economy. Underlying cognitive cost: Mark, G. (2005) and Mark, Gudith, Klocke (2008) at https://ics.uci.edu/~gmark/chi08-mark.pdf. Microsoft 2025 Work Trend Index via https://www.courier.com/notification-fatigue-is-real-and-getting-worse-e4fc248dc29f/.

[6] Mark, G. (CHI 2005). No Task Left Behind? Examining the Nature of Fragmented Work. https://ics.uci.edu/~gmark/chi08-mark.pdf. Also Csikszentmihalyi flow theory as summarized in https://clearing-ai.com/flow-state.html and https://www.sandordargo.com/blog/2026/07/15/how-ai-kills-flow.

[7] Anthropic Frontend Aesthetics Cookbook (2025-10), authored by Prithvi Rajasekaran. https://platform.claude.com/cookbook/coding-prompting-for-frontend-aesthetics. Anthropic `frontend-design` skill: https://github.com/anthropics/skills/blob/main/skills/frontend-design/SKILL.md (8.07 KB, 277,000+ installs as of March 2026). Analysis of Claude Design's anti-slop philosophy: https://www.theadpharm.com/insights/claude-design-without-the-ai-slop-look. Aesthetic family taxonomy: https://github.com/rohitg00/awesome-claude-design.

[8] Zylos Research (2026-03-29). Digital Employee Onboarding UX: Designing the First 5 Minutes for AI Agent Products. https://zylos.ai/research/2026-03-29-ai-agent-onboarding-ux-first-five-minutes/. Covers Devin, Cursor, Claude Code, Replit, Lindy, with aha-moment definitions, time-to-value benchmarks (54.8% AI/ML category activation, 90% first-week churn, Day 1 21% → Day 7 12%).

[9] Human Clarity Institute. (2025). Cognitive Load, Fatigue & Decision Offloading 2025 (Dataset). n = 503, data collected 2025-11-18 via Prolific. https://doi.org/10.5281/zenodo.17636370. https://humanclarityinstitute.com/data/ai-fatigue-decision-2025/.

[10] CSIRO Software Systems. AI Mode Switcher. Responsible AI Pattern Catalogue. https://research.csiro.au/ss/science/projects/responsible-ai-pattern-catalogue/ai-mode-switcher/. (Pattern in catalogue since 2022; updated 2024.)

[11] Microsoft Research. Guidelines for Human-AI Interaction (2019 CHI, 18 guidelines, validated). https://www.microsoft.com/en-us/research/publication/guidelines-for-human-ai-interaction/. HAX Toolkit: https://www.microsoft.com/en-us/haxtoolkit/. Specific guideline G11 "Support efficient dismissal" and G14 "Provide global controls" are the off-ramp-relevant subset.

[12] Pan, T. (2026-04-12). The Trust Calibration Curve: How Users Learn to (Mis)Trust AI. https://tianpan.co/blog/2026-04-12-trust-calibration-curve-how-users-learn-to-mistrust-ai. Underlying research: Lee, J. D. & See, K. A. (2004), https://journals.sagepub.com/doi/10.1518/hfes.46.1.50_30392; Microsoft "Overreliance on AI" literature review; Google PAIR https://pair.withgoogle.com/chapter/explainability-trust/; GitClear https://www.gitclear.com/coding_on_copilot_data_shows_ais_downward_pressure_on_code_quality; BCG AI adoption 2024 https://www.bcg.com/press/24october2024-ai-adoption-in-2024-74-of-companies-struggle-to-achieve-and-scale-value.

[13] Smashing Magazine (2026-02). Designing For Agentic AI: Practical UX Patterns For Control, Consent, And Accountability. https://www.smashingmagazine.com/2026/02/designing-agentic-ai-practical-ux-patterns/. Three phases × six patterns: Pre-Action (Intent Preview, Autonomy Dial), In-Action (Explainable Rationale, Confidence Signal), Post-Action (Action Audit & Undo, Escalation Pathway). Phase 1/2/3 rollout: Foundational Safety → Calibrated Autonomy → Proactive Delegation.

[14] Mantlr (2026). Designing For AI Agents: 10 UX Patterns. https://mantlr.com/blog/designing-for-ai-agents-ux-patterns-2026. Names the same canonical ten patterns and the golden rule: "users should always feel like they're driving, even when the agent does the work."

[15] GaaS. The Agent Permissioning UX Problem. https://gaas.co.com/trust/the-agent-permissioning-ux-problem/.

[16] Truto. Implementing Human-in-the-Loop Approval Workflows for Consequential SaaS API Actions. https://truto.one/blog/implementing-human-in-the-loop-approval-workflows-for-consequential-saas-api-actions/.

[17] Menu Agentic. Approval & Confirmation UX. https://menuagentic.com/playbooks/agent-ux-and-human-interaction/approval-and-confirmation-ux. Clawpilot: https://blog.clawpilot.ai/posts/confirmation-fatigue-is-your-agent-adoption-killer. mrmr: https://getmrmr.com/blog/approval-fatigue. Tian Pan (2026-06-25): https://tianpan.co/blog/2026-06-25-approval-fatigue-how-human-in-the-loop-gates-decay-into-rubber-stamps.

[18] Agent Market Cap (2026-04-09). Agent-Native UX: Designing for Autonomous Workflows in 2026. https://agentmarketcap.ai/blog/2026/04/09/agent-native-ux-patterns-2026-human-agent-collaboration. Also https://agentmarketcap.ai/blog/2026/04/09/real-time-human-agent-collaboration-ux-2026.

[19] Zylos Research (2026-07-16). Desktop Agent UIs and the Rise of Ambient Computing. https://zylos.ai/research/2026-07-16-desktop-agent-uis-ambient-computing/.

[20] AYDesign (2026). Best AI Coding Agent UX Examples in 2026. https://www.aydesign.ai/blog/best-ai-coding-agent-ux-examples-2026. Tool-call UX, memory UX, trust/citation UX, speed comparison across Cursor 9.4, Claude Code 9.3, Devin 8.6.

[21] Zylos Research (2026-05-28). Agentic UX: Frontend Design Patterns for AI Agents in 2026. https://zylos.ai/research/2026-05-28-agentic-ux-frontend-design-patterns-ai-agents/. Covers live tool execution visibility, GenUI patterns (static, A2UI, open-ended), and the four anti-slop moves for agent UIs.

[22] Mubarak, S. (2025-2026). Designing AI to Step Aside When Users Want Control. https://www.linkedin.com/posts/syed-mubarak_designpattern-vibecoding-aiux-activity-7468255327399026688-ghk1. Also: https://medium.com/generative-ai-revolution-ai-native-transformation/why-agentic-ux-will-change-everything-you-know-about-design-0394486f5add.

[23] Wong, R. (2026). Agentic UX: 7 principles for designing systems with agents. https://rogerwong.me/2026/03/agentic-ux-7-principles-designing-agents. Principle 3: "Let Users Dial Autonomy Like a Thermostat".

[24] Agentic Design — Ambient Agent Patterns (AAP). https://agentic-design.ai/patterns/ui-ux-patterns/ambient-agent-patterns. Three-tier interaction model: Notify, Question, Review.

[25] Zylos Research (2026-04-23). Agent Notification Intelligence: Smart Alerting, Triage, and Batching. https://zylos.ai/zh/research/2026-04-23-agent-notification-intelligence-smart-alerting-triage/.

[26] A Lifecycle Taxonomy of Sociotechnical Risks and Cascading Failures (2026). Identifies six recurring risk clusters: Trust Miscalibration, Cognitive Burden, Accountability Gap, Capability Erosion, Goal Misalignment, AI Anxiety & Technostress. https://arxiv.org/html/2608.05614v1. The "Cognitive Burden" cluster explicitly names the XAI paradox.

[27] Wired (2026). Cursor Launches a New AI Agent Experience to Take On Claude Code and Codex. https://www.wired.com/story/cusor-launches-coding-agent-openai-anthropic/. Cursor 3 features: text-first agent IDE, file diffs as primary surface, agent sidebar, coexisting with the existing IDE.

[28] AYDesign (2026). Best Minimalist SaaS Designs in 2026. https://www.aydesign.ai/blog/best-minimalist-saas-designs-2026. Anthropic, Granola, Linear signatures.

[29] Anthropic Claude Design launch (2026-04-17, Opus 4.7). https://www.anthropic.com/news/claude-design-anthropic-labs. Claude Design product page: https://claude.com/product/design. Anthropic's design system DNA captured at https://www.designmd.co/category/ai and https://www.aydesign.ai/blog/best-minimalist-saas-designs-2026. The <frontend_aesthetics> verbatim system prompt: https://www.theadpharm.com/insights/claude-design-without-the-ai-slop-look.

[30] Agent Skills Specification — `description` field optimization. https://agentskills.io/skill-creation/optimizing-descriptions. SKILL.md format: https://skillmd.com/docs/format. Specification: https://agentskills.io/specification. Cross-vendor field compatibility: https://www.agensi.io/learn/skill-md-format-reference and https://agentpatterns.ai/tool-engineering/skill-frontmatter-reference/.

---

*End of research brief. This document is the input to a Mavis skill. The next deliverable is a `SKILL.md` built from this brief using the structure in the "Translating the research into a Mavis skill" section.*
