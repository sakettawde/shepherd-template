# shepherd instance

This repository is a shepherd instance. It holds data only — the ledger, the
registry, the decision log and the reports. The framework is the `shepherd`
plugin: `.claude/shepherd-manual.md` below is a **generated** copy of the
plugin's manual, refreshed by the plugin's `SessionStart` hook and committed by
wake step 1. Never edit it; edit the plugin and cut a release.

Session start runs `/shepherd:wake`, always, as the first act.

@.claude/shepherd-manual.md
@.shepherd/instance.env

## Local overrides

<!-- Standing rules only this instance needs. Keep it short: anything here is a
     candidate for the next plugin release, and a rule that belongs to the
     framework belongs in the plugin, not here. -->
