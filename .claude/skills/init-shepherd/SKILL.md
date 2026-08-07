---
name: init-shepherd
description: First-run setup for a fresh shepherd clone - interviews the operator, writes the Operator block, registers the worker hooks user-globally, and seeds the project registry. Idempotent - re-run it after cloning to a new machine to re-register hooks and refresh paths. Run it from a Claude session opened inside the clone.
---

# init-shepherd

Resolve `<shepherd-root>` = absolute path of the current working directory (verify it contains `CLAUDE.md` with a `## 0. Operator` section and `.claude/skills/herdr-adapter/`; if not, stop — you are not inside a shepherd clone).

Fresh clone if `CLAUDE.md` contains the literal line `- name: (run init-shepherd)`; otherwise this is a re-run (new machine or settings repair) — skip the interview questions whose answers already stand in the Operator block unless the operator wants them changed.

## Steps

1. **Environment gate** — run the herdr-adapter R1 gate (`HERDR_ENV`, `herdr --version` against the pin in CLAUDE.md §7, `herdr status`). Not inside herdr or version mismatch → report exactly what failed and what to install/fix, then stop. Nothing below runs on a failed gate.
2. **Interview** — ask, one at a time: the operator's name; the absolute path of their code directory (where project repos live — offer `$(dirname <shepherd-root>)` as the default); whether notification sounds are wanted (default yes).
3. **Write the Operator block** — replace the three value lines under `## 0. Operator` in CLAUDE.md with the answers (`- name: <name>`, `- code-dir: <path>`, `- notifications: <sounds on (done / request) | silent>`). Never touch any other section.
4. **Register hooks user-globally** — merge into `~/.claude/settings.json` (create it as `{}` if absent) using the python3 snippet below: a `Stop` entry (matcher `*`) running `bash '<shepherd-root>/hooks/worker-stop.sh'`, a `Notification` entry (matcher `permission_prompt|idle_prompt|elicitation_dialog`) running `bash '<shepherd-root>/hooks/worker-notify.sh'`, and a `PreToolUse` entry (matcher `Bash`) running `bash '<shepherd-root>/hooks/worker-git-guardrail.sh'` (blocks destructive git in worker sessions), all `timeout: 10`. The snippet first removes any existing hook whose command ends in the same script name (that is the re-run/new-PC path), then appends the fresh entries. All unrelated settings and hooks are preserved verbatim.

   ```bash
   SHEPHERD_ROOT="$(pwd)" python3 - <<'PY'
   import json, os, pathlib
   root = os.environ["SHEPHERD_ROOT"]
   p = pathlib.Path.home() / ".claude" / "settings.json"
   t = p.read_text() if p.exists() else ""
   s = json.loads(t) if t.strip() else {}
   hooks = s.setdefault("hooks", {})
   def install(event, matcher, script):
       cmd = f"bash '{root}/hooks/{script}'"
       entries = hooks.setdefault(event, [])
       for e in entries:
           e["hooks"] = [h for h in e.get("hooks", []) if not h.get("command", "").endswith(f"{script}'")]
       entries[:] = [e for e in entries if e.get("hooks")]
       entries.append({"matcher": matcher, "hooks": [{"type": "command", "command": cmd, "timeout": 10}]})
   install("Stop", "*", "worker-stop.sh")
   install("Notification", "permission_prompt|idle_prompt|elicitation_dialog", "worker-notify.sh")
   install("PreToolUse", "Bash", "worker-git-guardrail.sh")
   p.parent.mkdir(parents=True, exist_ok=True)
   p.write_text(json.dumps(s, indent=2) + "\n")
   print("hooks registered ->", p)
   PY
   ```

5. **Seed the registry** — `sh scripts/bootstrap-registry.sh <code-dir>` with the interviewed path. Report the row count.
6. **Commit** — `git add -A && git commit -m "init: shepherd instance configured for <name>"`. On a re-run with no file changes (hooks-only repair), say so instead of committing.
7. **Confirm** — one line: operator name, code dir, hook file path, registry rows, and the canonical launch command from CLAUDE.md §1. Remind the operator that hooks fire only in *worker* sessions (they exit instantly without `SHEPHERD_TASK_ID`).

## Hard lines

- Never overwrite `~/.claude/settings.json` wholesale — always the merge above.
- Never modify anything outside the Operator block, `registry/projects.md`, and the user-global settings file.
- A failed step stops the run — report it; never leave the clone half-initialized silently.
