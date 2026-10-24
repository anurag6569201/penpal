# Agent Workbench POC

This is the first **single-workspace IDE integration** for the idea: a Workbench panel inside VS Code or Cursor, provider and model selection for Claude Code and Codex, with native terminals, and project memory that both receive when started.

The editor and file explorer remain the host IDE for this first build. The Workbench brings the provider choice and shared project context into the same window. It does not copy subscription tokens or call model APIs: it launches each provider's installed CLI, which uses its own sign-in and normal approval flow.

## Run it in VS Code or Cursor

1. Open this `vscode-extension` folder in VS Code or Cursor.
2. Press **F5** to open an Extension Development Host.
3. In that new window, open the Penpal project folder.
4. Select the **Workbench** icon in the Activity Bar.
5. Enter a task and choose Claude Code or Codex. Their terminals open in the project with the saved memory and handoff included.

The first launch creates `agent-handoff-poc/state/PROJECT_MEMORY.md` and `HANDOFF.md` inside the selected project when you save or start an agent. These local files are ignored by Git. Both agents are instructed to read them before work and update the handoff before finishing. Save stable architecture and conventions in project memory; put active task details in the handoff.

## Scope of this trial

- One editor window and one project workspace.
- Provider selection and per-provider model selection for Claude Code and Codex. Authenticate each native CLI with its own provider.
- Editable, project-scoped shared memory.
- New agent tasks start in a fresh native terminal, with memory injected as instructions.
- The current editor supplies its file tree and code editor.

Antigravity and Cursor are visible as planned provider adapters, but are not wired in this first build. Their native sign-in, runtime, and model catalogs must be connected through their supported interfaces before those selections can launch. A standalone editor, automatic transcript capture, agent session resume, and richer memory retrieval are follow-up work after this two-agent flow proves useful.
