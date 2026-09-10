# herdr 0.8.2 — surfaces shepherd does not use

Noted so nobody re-invents them, and dated so the next regeneration hunts for changes that happened. `${CLAUDE_PLUGIN_ROOT}/tests/test-docs.sh` holds the table to the schema diff.

Protocol 16 → 20 across 0.7.4 → 0.8.2. Diffing `schemas.request` methods across the two `${CLAUDE_PLUGIN_ROOT}/docs/herdr-schema-*.json` snapshots (read 2026-09-02): `agent.send` removed; added `agent.prompt`, `agent.send_keys`, `agent.wait`, `agent.view.set`, `agent.view.clear`, `pane.input.set`, `workspace.move_block` — 0.7.5 per the [release notes](https://github.com/herdrdev/herdr/releases) (read 2026-09-02), except `pane.input.set` (0.8.2). `test-docs.sh` holds the table to that diff.

| Surface | Since | What it is, and why shepherd might care |
|---|---|---|
| `events.subscribe` (socket) | 0.7.4 or earlier (in the 0.7.4 snapshot) | Real push for pane/tab/workspace/worktree events; external consumers only, subscribed narrowly — [herdr issue #650](https://github.com/herdrdev/herdr/issues/650) (read 2026-09-02) is a phantom-`focused` storm |
| `herdr plugin <install\|link\|list\|action\|pane>` + `plugin.*` (socket) | 0.7.4 or earlier — identical in both snapshots ([herdr.dev/docs/plugins](https://herdr.dev/docs/plugins), read 2026-09-02) | Native plugins (manifest, actions, hooks, plugin-owned panes); the way to ship a herdr-side daemon or hook |
| `agent.view.set` / `agent.view.clear` (socket) | 0.7.5 (release notes; absent from the 0.7.4 snapshot) | Server-side agent-list filter — an "agents needing input" view |
| `pane.input.set` (`herdr pane input`) | 0.8.2 (release notes; absent from the 0.7.4 snapshot) | Right-click routing per pane ([herdr.dev/docs/socket-api](https://herdr.dev/docs/socket-api), read 2026-09-02); shepherd never right-clicks |
| `workspace.move_block` (socket), `workspace.reordered` event | 0.7.5 (release notes; absent from the 0.7.4 snapshot) | Workspace reordering; untested |
| `herdr integration status` (CLI) | undated — neither snapshot nor the release notes mention it | Installed agent-state integrations; confirms the claude hook is current (`claude: current (v8)`) |

The CLI has no subscribe verb; blocking waits (R5) stay shepherd's only CLI-level signal.
