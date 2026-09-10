# <slug>
path: <absolute path of the base checkout>
memory-dir: <the project's resolved auto-memory directory: ~/.claude/projects/<git toplevel of the base checkout, / → ->/memory/ — record what a session in that checkout reports, never a guess from the slug; every worktree and subdirectory of one repository shares it (code.claude.com/docs/en/memory, read 2026-09-06)>
stack: <one line a Brief can copy into its Context: runtimes, frameworks, stores, deploy target>
test: <the DoD command>   # what it proves, and what it does not
dev-branch: <branch>   # verified against origin HEAD; say so when main is production
working-agreement: <dev-branch | task/T-NNNN-onboard | none>   # `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Working agreement's check, never the state of a PR
preview: <none — <why> | <mechanism> — <URL pattern> — by <push|worker|shepherd>>   # can a branch be seen running before it merges? `by` names who produces it: `push`, the platform builds it from the pushed branch and nobody runs a command; `worker`, the worker runs a preview-only command inside the task; `shepherd`, the worker builds and pushes and shepherd runs the one deploy command at verification from its allow list, reading no code. Cloudflare's two shapes are `<version-prefix or alias>-<worker>.<subdomain>.workers.dev` for a Worker and a unique `<hash>.<project>.pages.dev` that may always be visited, plus a branch alias that follows the branch, for Pages (developers.cloudflare.com/workers/configuration/previews, developers.cloudflare.com/pages/configuration/preview-deployments, read 2026-09-07). Where `by` is `worker` or `shepherd`, `<mechanism>` carries the command that produces it, because nothing else records it and the one who runs it reads this line. `none` is the honest answer and a cheap one: a promotion to a shared environment is never called a preview, and no project's build pipeline is examined to find one (Saket, 2026-09-07). What a Linear ask gets from either answer is triage's, not this line's
onboarded: <no | in-progress | yes>   # date and task once yes
active-task: none
pane: none
clone-seed: <paths copied from the base checkout into a fresh worktree; omit the line for the default .dev.vars .env .env.local, or leave the value empty to copy nothing>
install: <command run once in a fresh worktree; omit the line for the default npm install, or `true` for a repo that needs no install>
keywords: <slug, aliases, the product words the operator uses — the index row copies these>

## Product
<What is built, Why, Who really uses it, How — then the onboarding Q&A verbatim, and every escalation answer banked since. Briefs copy from here, and a design question already answered here is never asked again>

## Context notes
- Parallel lanes: <safe | hazard — what two live working copies would share: ports, a local database, a Docker daemon, build caches> (onboarding Q&A, <date>)

## Gotchas

## History

## Clones
| clone-id | path | active-task | pane |
|---|---|---|---|
