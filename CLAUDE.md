# gstack

This machine has [gstack](https://github.com/garrytan/gstack) installed at `~/.claude/skills/gstack`, a set of Claude Code skills covering planning, review, QA, shipping, and browser automation.

Available skills:

- `/office-hours` — YC Office Hours style product interrogation
- `/plan-ceo-review`, `/plan-eng-review`, `/plan-design-review`, `/plan-devex-review` — plan review from different perspectives
- `/design-consultation`, `/design-shotgun`, `/design-html`, `/design-review` — design workflow
- `/review` — pre-landing PR review
- `/ship`, `/land-and-deploy` — ship / deploy workflow
- `/canary` — post-deploy canary monitoring
- `/benchmark`, `/benchmark-models` — performance / cross-model benchmarking
- `/browse`, `/connect-chrome`, `/setup-browser-cookies` — headless/AI-controlled browser for QA and scraping
- `/qa`, `/qa-only` — QA testing
- `/setup-gbrain`, `/sync-gbrain` — persistent project memory
- `/setup-deploy` — deploy configuration
- `/retro` — weekly engineering retrospective
- `/investigate` — systematic debugging
- `/document-release`, `/document-generate` — documentation generation
- `/codex` — second-opinion review via OpenAI Codex CLI
- `/cso` — security review mode
- `/autoplan` — automated multi-perspective plan review pipeline
- `/careful`, `/freeze`, `/guard`, `/unfreeze` — destructive-command guardrails / edit scoping
- `/gstack-upgrade` — upgrade gstack
- `/learn` — manage project learnings

## Browser tool choice

For web browsing/QA in this project, default to the built-in `mcp__claude-in-chrome__*` tools (your real, already-logged-in Chrome) rather than gstack's `/browse` skill, since most browsing work here needs an authenticated session. Use `/browse` only for unauthenticated, repeatable tasks (e.g. scraping) where its caching (`/scrape` + `/skillify`) is worth it.
