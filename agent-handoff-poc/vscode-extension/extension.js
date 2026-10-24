const vscode = require("vscode");
const fs = require("fs/promises");
const path = require("path");

const MEMORY_TEMPLATE = `# Project memory\n\nStable architecture, conventions, and decisions shared by every agent. Keep it short, cite file paths, and remove stale notes.\n\n## Architecture\n\n## Conventions\n\n## Decisions\n`;
const HANDOFF_TEMPLATE = `# Current handoff\n\nDescribe active work, files changed, decisions, and the next concrete step. The selected agent will read and update this file.\n`;

function quoteForShell(value) {
  // VS Code's default shells on supported desktop platforms accept POSIX quoting.
  return "'" + String(value).replace(/'/g, "'\\''") + "'";
}

function activate(context) {
  const provider = new WorkbenchView(context.extensionUri);
  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider("agentWorkbench.workspace", provider),
    vscode.commands.registerCommand("agentWorkbench.open", async () => {
      await vscode.commands.executeCommand("workbench.view.extension.agentWorkbench");
    })
  );
}

class WorkbenchView {
  constructor(extensionUri) {
    this.extensionUri = extensionUri;
    this.view = undefined;
    this.root = undefined;
    this.stateDir = undefined;
  }

  async resolveWebviewView(view) {
    this.view = view;
    view.webview.options = { enableScripts: true };
    view.webview.html = this.html(view.webview);
    view.webview.onDidReceiveMessage((message) => this.handle(message));
    await this.refresh();
  }

  async paths() {
    const folder = vscode.workspace.workspaceFolders?.[0];
    if (!folder) throw new Error("Open a project folder first.");
    this.root = folder.uri.fsPath;
    this.stateDir = path.join(this.root, "agent-handoff-poc", "state");
    return this.stateDir;
  }

  async refresh() {
    try {
      const dir = await this.paths();
      const [memory, handoff] = await Promise.all([
        fs.readFile(path.join(dir, "PROJECT_MEMORY.md"), "utf8").catch(() => MEMORY_TEMPLATE),
        fs.readFile(path.join(dir, "HANDOFF.md"), "utf8").catch(() => HANDOFF_TEMPLATE)
      ]);
      this.view?.webview.postMessage({
        type: "workspace",
        root: this.root,
        memory,
        handoff,
        agents: ["Claude Code", "Codex"]
      });
    } catch (error) {
      this.view?.webview.postMessage({ type: "error", message: error.message });
    }
  }

  async handle(message) {
    try {
      if (message.type === "refresh") return await this.refresh();
      if (message.type === "save") {
        const dir = await this.paths();
        await fs.mkdir(dir, { recursive: true });
        await Promise.all([
          fs.writeFile(path.join(dir, "PROJECT_MEMORY.md"), message.memory, "utf8"),
          fs.writeFile(path.join(dir, "HANDOFF.md"), message.handoff, "utf8")
        ]);
        this.view.webview.postMessage({ type: "saved" });
        return;
      }
      if (message.type === "start") return await this.startAgent(message);
    } catch (error) {
      this.view?.webview.postMessage({ type: "error", message: error.message });
    }
  }

  async startAgent(message) {
    const dir = await this.paths();
    await fs.mkdir(dir, { recursive: true });
    const memoryPath = path.join(dir, "PROJECT_MEMORY.md");
    const handoffPath = path.join(dir, "HANDOFF.md");
    await Promise.all([
      fs.writeFile(memoryPath, message.memory, "utf8"),
      fs.writeFile(handoffPath, message.handoff, "utf8")
    ]);
    const task = String(message.task || "").trim();
    if (!task) throw new Error("Write the task before starting an agent.");
    const sharedInstructions = [
      `Project: ${this.root}`,
      "Read the shared project memory and current handoff before acting.",
      `Memory file: ${memoryPath}`,
      `Handoff file: ${handoffPath}`,
      "These files are shared by all agents. Before finishing, update the handoff with files changed, decisions, and the next useful step. Add only durable architecture or conventions to project memory. Do not copy source code into memory.",
      "Keep all work in the opened project folder and follow the project's normal approval and permission rules."
    ].join("\\n");
    const prompt = `${sharedInstructions}\n\nUser task:\n${task}`;
    const adapters = {
      "Claude Code": { command: "claude", supported: true },
      "Codex": { command: "codex", supported: true }
    };
    const adapter = adapters[message.agent];
    if (!adapter) throw new Error(`${message.agent} adapter is not connected in this build yet.`);
    const modelArg = message.model ? `--model ${quoteForShell(message.model)}` : "";
    const command = message.agent === "Claude Code"
      ? `claude ${modelArg} --append-system-prompt ${quoteForShell(sharedInstructions)} ${quoteForShell(task)}`
      : `codex ${modelArg} ${quoteForShell(prompt)}`;
    const terminal = vscode.window.createTerminal({
      name: `${message.agent}${message.model ? ` · ${message.model}` : ""} · ${path.basename(this.root)}`,
      cwd: this.root
    });
    terminal.show(true);
    // Native CLIs keep their own sign-in, model settings, and approval flow.
    terminal.sendText(command, true);
    this.view.webview.postMessage({ type: "started", agent: message.agent, model: message.model || "provider default" });
  }

  html(webview) {
    const nonce = [...Array(24)].map(() => Math.random().toString(36)[2]).join("");
    return `<!doctype html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';">
<style>
:root{color-scheme:dark;--bg:#101215;--panel:#171a1f;--line:#282d35;--muted:#9199a7;--text:#edf0f4;--accent:#9caeff;--green:#94dfc0}*{box-sizing:border-box}body{margin:0;padding:14px;background:var(--bg);color:var(--text);font:13px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}.brand{display:flex;align-items:center;justify-content:space-between;margin-bottom:14px}.brand strong{font-size:15px;letter-spacing:.02em}.live{font-size:10px;color:var(--green);border:1px solid #355c4e;border-radius:99px;padding:3px 8px}.project{padding:11px 12px;background:var(--panel);border:1px solid var(--line);border-radius:10px;margin-bottom:14px}.eyebrow{font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:.11em}.path{margin-top:4px;overflow-wrap:anywhere;color:#c8ced8;font-size:11px}.label{font-size:11px;color:#bac1cc;margin:0 0 7px}.agents{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:14px}.agent{height:64px;border:1px solid var(--line);border-radius:10px;background:var(--panel);color:var(--text);text-align:left;padding:10px;cursor:pointer}.agent span{display:block;font-weight:600}.agent small{color:var(--muted);font-size:10px}.agent.active{border-color:#788be0;background:#202533;box-shadow:inset 0 0 0 1px #788be0}.agent:disabled{opacity:.35;cursor:default}.agent.future{opacity:.63;border-style:dashed}.agent.future:hover{border-color:#515a68}select{width:100%;background:#0b0d10;color:var(--text);border:1px solid var(--line);border-radius:8px;padding:9px;margin:0 0 5px}select:focus{outline:1px solid #788be0}textarea{width:100%;resize:vertical;min-height:85px;background:#0b0d10;color:var(--text);border:1px solid var(--line);border-radius:8px;padding:9px;font:12px/1.5 ui-monospace,SFMono-Regular,monospace;outline:none}textarea:focus{border-color:#788be0}#task{min-height:88px}.task-label{margin-top:14px}.row{display:flex;align-items:center;justify-content:space-between;margin:14px 0 8px}.button{border:1px solid #586bb7;background:#586bb7;color:white;font-weight:600;border-radius:8px;padding:9px 12px;cursor:pointer}.button.secondary{background:transparent;border-color:var(--line);color:#d5dae2;padding:6px 10px}.runrow{display:flex;align-items:center;justify-content:space-between;margin-top:10px}.hint{font-size:10px;color:var(--muted);max-width:55%}.memory{margin-top:14px;border-top:1px solid var(--line);padding-top:12px}details{margin-top:8px;background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:9px}summary{cursor:pointer;color:#d8dde6;font-weight:600}.memory textarea{margin-top:9px;min-height:108px}.status{min-height:22px;padding-top:6px;color:var(--muted);font-size:11px}.status.ok{color:var(--green)}.tiny{color:var(--muted);font-size:10px;margin-top:13px}.tiny code{color:#c8ced8}
</style>
</head>
<body>
<div class="brand"><strong>Agent Workbench</strong><span class="live">LOCAL · PRIVATE</span></div>
<div class="project"><div class="eyebrow">Active project</div><div class="path" id="root">Opening workspace…</div></div>
<div class="label">Provider</div>
<div class="agents">
<button class="agent active" data-agent="Codex"><span>Codex</span><small>Connected · native sign-in</small></button>
<button class="agent" data-agent="Claude Code"><span>Claude Code</span><small>Connected · native sign-in</small></button>
<button class="agent future" data-agent="Antigravity"><span>Antigravity</span><small>Adapter next</small></button>
<button class="agent future" data-agent="Cursor"><span>Cursor</span><small>Adapter next</small></button>
</div>
<label class="label" for="model">Model</label>
<select id="model" aria-label="Choose a model"></select>
<div class="label task-label">What should it do?</div>
<textarea id="task" placeholder="Describe the task for the selected agent…"></textarea>
<div class="runrow"><span class="hint">Opens an agent terminal in this project. Its normal approval controls stay on.</span><button class="button" id="start">Start agent ↗</button></div>
<div class="memory">
<div class="row"><div class="label" style="margin:0">Shared project memory</div><button class="button secondary" id="save">Save</button></div>
<details open><summary>Memory · durable project facts</summary><textarea id="memory" spellcheck="false"></textarea></details>
<details><summary>Handoff · current work and next step</summary><textarea id="handoff" spellcheck="false"></textarea></details>
<div class="status" id="status">Memory is saved locally inside this project.</div>
</div>
<div class="tiny">Select a provider, then choose from its models. The same project and memory follow the switch. Antigravity and Cursor are shown as next adapters.</div>
<script nonce="${nonce}">
const vscode=acquireVsCodeApi();let selected='Codex';let memory='';let handoff='';
const models={
  'Codex':[{label:'Provider default',id:''},{label:'GPT-6 Luna',id:'gpt-6-luna'},{label:'GPT-6 Sol',id:'gpt-6-sol'},{label:'GPT-6 Astra',id:'gpt-6-astra'}],
  'Claude Code':[{label:'Provider default',id:''},{label:'Sonnet 5',id:'sonnet'},{label:'Opus 5.5',id:'opus'}],
  'Antigravity':[], 'Cursor':[]
};
const root=document.getElementById('root'),memoryBox=document.getElementById('memory'),handoffBox=document.getElementById('handoff'),taskBox=document.getElementById('task'),status=document.getElementById('status'),modelBox=document.getElementById('model');
function updateModels(){modelBox.replaceChildren();for(const model of (models[selected]||[])){const option=document.createElement('option');option.value=model.id;option.textContent=model.label;modelBox.append(option);}if(!modelBox.options.length){const option=document.createElement('option');option.textContent='Adapter coming soon';modelBox.append(option);modelBox.disabled=true;}else modelBox.disabled=false;}
document.querySelectorAll('.agent').forEach(button=>button.addEventListener('click',()=>{if(button.classList.contains('future')){status.textContent=button.dataset.agent+' integration is planned; Codex and Claude Code are connected in this POC.';status.className='status';return;}selected=button.dataset.agent;document.querySelectorAll('.agent').forEach(item=>item.classList.toggle('active',item===button));updateModels();}));
updateModels();
document.getElementById('save').addEventListener('click',()=>{memory=memoryBox.value;handoff=handoffBox.value;vscode.postMessage({type:'save',memory,handoff});});
document.getElementById('start').addEventListener('click',()=>{memory=memoryBox.value;handoff=handoffBox.value;vscode.postMessage({type:'start',agent:selected,model:modelBox.value,memory,handoff,task:taskBox.value});});
window.addEventListener('message',event=>{const message=event.data;if(message.type==='workspace'){root.textContent=message.root;memory=message.memory;handoff=message.handoff;memoryBox.value=memory;handoffBox.value=handoff;status.textContent='Memory is saved locally inside this project.';status.className='status';}else if(message.type==='saved'){status.textContent='Saved. Shared memory is ready for the next provider.';status.className='status ok';}else if(message.type==='started'){status.textContent=message.agent+' · '+message.model+' opened in the integrated terminal.';status.className='status ok';}else if(message.type==='error'){status.textContent=message.message;status.className='status';}});
vscode.postMessage({type:'refresh'});
</script>
</body>
</html>`;
  }
}

function deactivate() {}
module.exports = { activate, deactivate };
