# Four silent launch downgrades, found in one audit

**Date:** 2026-09-06 · **Source:** `docs/reports/2026-09-06-audit.md` (F2, F4, F5) · **Card:** T-0233

## What happened

1. **Shepherd's own model drifted (F2).** The canonical launch line pinned neither `--model` nor `--effort`. Without `--model` a session starts on the settings-saved model — what `/model` writes as the default for new sessions — and effort resolves an explicit `--effort` first, then the level an interactive `/effort` saved for that model, then the model default `high`. Instances ran Opus 5 from 2026-09-03 to 2026-09-06 that way while the manual assumed Fable (measured from the session transcripts).
2. **The subagent pin became a ceiling (F4).** `CLAUDE_CODE_SUBAGENT_MODEL=opus` had been set on 2026-07-28 as a *floor* (no implementation subagent below Sonnet), when the variable overrode every per-call model. Since Claude Code v2.1.251 it is a **default**, third in the resolution order — a per-call `model`, then agent frontmatter, then the variable, then the main conversation's model — so under a Fable worker the pin at `opus` held its Explore, Plan and review subagents *down* to Opus, and the T-0220/T-0221 panes showed explicit-model subagents on Opus, Sonnet and Haiku regardless. Verified live on 2.1.263: an unlabeled subagent under `=fable` ran Fable 5.1, a `model: haiku` one ran Haiku 4.5, and neither carried the worker's output style.
3. **Workers ran without Claude Code's software-engineering instructions.** The operator's user-global output style reaches every worker, and a custom style keeps those instructions only with `keep-coding-instructions: true` in its frontmatter. The style file lacked it from 2026-08-14 to 2026-09-06, and nothing noticed.
4. **An SDD/TDD skill chain from the M0 skeleton** still sat in the Brief template after the brainstorming mandate, prescribing a per-size implementation chain the worker plans better itself.

## What changed

The launch line pins `--model fable --effort high` (Saket's default, 2026-09-06). The worker ladder is one line, `tiers:` in CLAUDE.md §0, read by dispatch at launch; the env var is set to the worker's own alias so subagents follow the worker, and `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` stays unset because it would buy the pin back at the price of the worker's own choice; the Sonnet floor holds because implementation stays in the worker's session. `scripts/output-style-check.sh` runs at wake step 1 and at init, answering `style: ok` or `style: DEGRADED` with the one-line repair — a running session cannot pick the repair up, only the next session or `/clear` does. The template mandates brainstorming and then leaves planning and implementation in the worker's session ([Model configuration](https://code.claude.com/docs/en/model-config), [Subagents](https://code.claude.com/docs/en/sub-agents) § "Choose a model", [Output styles](https://code.claude.com/docs/en/output-styles), all read 2026-09-06).

## Where the rule stands

CLAUDE.md §1 (the pinned launch line), §6 (subagents follow the worker; plans stay in the worker; the style check); adapter R3; `templates/task-card.md`.
