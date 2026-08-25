## Project structure

- apps/mobile = Flutter mobile app
- apps/web = Next.js web app
- services/api = FastAPI backend
- services/worker = background jobs
- docs = architecture, decisions, benchmarks, research, plans

## Instruction hierarchy

- This root AGENTS.md defines repository-wide rules.
- A nested AGENTS.md supplements or overrides these rules only within its own subtree.
- Always read all applicable AGENTS.md files before editing.
- Do not modify generated or existing nested AGENTS.md files unless the task explicitly requires it.
- In particular, preserve apps/web/AGENTS.md unless a human explicitly requests a change.

## Engineering workflow

- Always inspect relevant existing code and documentation before editing.
- Before every task, check and invoke applicable installed skills.
- Use Superpowers workflows when applicable.
- Feature and bugfix implementation must follow TDD using the applicable Superpowers workflow.
- Bugs and failures must use systematic root-cause debugging.
- Never claim completion without fresh verification evidence.
- Prefer simple, maintainable solutions; avoid unnecessary abstractions.

## Architecture guardrails

- Backend is the source of truth for realtime sessions and AI orchestration.
- Web and Mobile clients must not call STT, Translation, TTS, or LLM providers directly.
- External AI providers must be integrated behind provider adapters/interfaces.
- Do not change approved architecture without explicit human approval.
- Do not change REST or WebSocket contracts without explicit human approval.
- Do not add a major dependency without explaining why and obtaining approval.
- Avoid unrelated refactors while implementing scoped tasks.

## Git and safety

- You may inspect, edit, create files, run tests, analyzers, builds, and local development commands inside the approved scope.
- Local commits are allowed only when explicitly requested.
- Never push without explicit human approval.
- Never merge a branch or pull request without explicit human approval.
- Never rewrite Git history.
- Never delete branches unless explicitly requested.
- Never use destructive Git commands to discard work unless explicitly approved.
- Never overwrite, discard, revert, or clean up pre-existing user changes that are outside the approved task scope.
- If the working tree is unexpectedly dirty, stop and report it before editing.
- Never commit secrets, tokens, API keys, credentials, keystores, or local environment files.
- Never print secret values into logs or reports.

## Scope discipline

- Stay strictly inside the requested task scope.
- If implementation requires an architecture/API-contract/dependency change, stop and request approval.
- If unexpected complexity appears, stop and report the blocker before expanding scope.

## Verification

Before declaring a task complete:

- run the relevant automated tests
- run relevant static analysis/lint
- run relevant build checks when applicable
- inspect git diff
- report any warnings or known technical debt honestly

### Standard subsystem checks

Run only checks relevant to the affected subsystem unless a broader verification is explicitly required.

Backend:

- working directory: services/api
- python -m pytest

Web:

- working directory: apps/web
- npm run lint
- npm run build

Mobile:

- working directory: apps/mobile
- flutter test
- flutter analyze
- flutter build apk --debug

For documentation-only or governance-only changes, application tests/builds are not required unless the change can affect runtime behavior.

## Required final task report

Every implementation task must end with:

- summary
- files changed
- tests/checks run
- exact results
- blockers or known issues
- git diff/status summary
- whether a commit was created
- explicit statement that no push/merge occurred unless the human requested it
