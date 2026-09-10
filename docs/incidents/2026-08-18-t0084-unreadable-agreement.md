# A Brief pointed at a CLAUDE.md the worker could not read

**Date:** 2026-08-18 · **Card:** T-0084 (ip-landing)

## What happened

The Brief said the project's own CLAUDE.md was the authoritative working agreement. That file existed only on the unmerged onboarding branch (`task/T-0079-onboard`); on `main`, which the worker branched from, there was no CLAUDE.md at all. The worker never saw the check-out-the-dev-branch rule and left the repo on its task branch; shepherd returned it to `main` by hand. The same mechanism meant every new task branch off `main` lacked all prior verified work — T-0085 depended on T-0084's code and could not branch. §6 strips repo rules out of every Brief on the assumption the file is readable, so when it is not, nothing else in the system supplies them.

## What changed

The registry card gained `working-agreement:` — the branch on which the project's CLAUDE.md is actually readable, or `none` — set from a live check (`shepherd-working-agreement`) and never from PR state. When it is not the dev branch, triage inlines the template's four standing rules into `### Context` and deletes the Constraints line that points at the file; dispatch's preflight re-runs the check at every launch, holds a Brief that arrived without the rules, and flips the field once the onboarding PR merges. For ip-landing itself Saket ruled merge-as-you-go the same day.

## Where the rule stands

`docs/protocols.md` § Working agreement; the manual §6 (repo rules live in the project's CLAUDE.md, and only this field decides inlining).
