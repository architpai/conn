/* ============================================================
   Conn notch mock
   Data shapes mirror the codex app-server v2 protocol proven in
   Phase 5: Thread{status: idle|active(+activeFlags)|systemError},
   Turn{inProgress|completed|interrupted|failed}, ThreadItems,
   TurnPlanSteps, ThreadTokenUsage, serverRequest approvals.
   All values below are sample data for the mock.
   ============================================================ */

const $ = (id) => document.getElementById(id);

/* ---------- model ---------- */

const threads = [
  {
    id: "t1",
    name: "adapter proxy transport",
    cwd: "~/dev/conn",
    branch: "feat/proxy-transport",
    status: { type: "active", activeFlags: [] },
    turn: { status: "inProgress", startedAt: 0 },
    completionUnreviewed: false,
    headline: "Starting turn",
    tokens: { used: 42_300, window: 128_000 },
    plan: null, // set by sim
  },
  {
    id: "t2",
    name: "schema pinning 0.144.6",
    cwd: "~/dev/conn",
    branch: "chore/schema-bundle",
    status: { type: "active", activeFlags: ["waitingOnApproval"] },
    turn: { status: "inProgress" },
    completionUnreviewed: false,
    headline: "Awaiting approval · generate-schemas.sh verify",
    tokens: { used: 18_900, window: 128_000 },
  },
  {
    id: "t3",
    name: "notch ui spike",
    cwd: "~/dev/conn-ui",
    branch: "main",
    status: { type: "idle" },
    turn: { status: "completed" },
    completionUnreviewed: true,
    headline: "Completed · unreviewed outcome from 2m ago",
    tokens: { used: 9_400, window: 128_000 },
  },
  {
    id: "t4",
    name: "fixture sanitizer",
    cwd: "~/dev/conn",
    branch: "fix/fixture-pipeline",
    status: { type: "systemError" },
    turn: { status: "failed", error: "usageLimitExceeded" },
    completionUnreviewed: false,
    headline: "Turn failed · usage limit exceeded",
    tokens: { used: 109_400, window: 128_000 },
  },
];

const stateOf = (t) => {
  if (t.status.type === "systemError" || t.turn.status === "failed") return "fail";
  if (t.status.type === "active") {
    if (t.status.activeFlags.includes("waitingOnApproval")) return "wait";
    if (t.status.activeFlags.includes("waitingOnUserInput")) return "input";
    return "run";
  }
  return "idle";
};

const stateLabel = { run: "running", wait: "needs approval", input: "needs input", idle: "idle", fail: "failed" };
const statePriority = { wait: 0, input: 1, run: 2, fail: 3, idle: 4 };
const summaryUrgencyOrder = ["approval", "input", "running", "failed", "complete", "idle"];
const summaryLabel = {
  approval: "needs approval",
  input: "needs input",
  running: "running",
  failed: "failed",
  complete: "completed, not reviewed",
  idle: "idle",
};

const summaryStateOf = (t) => {
  const state = stateOf(t);
  if (state === "wait") return "approval";
  if (state === "input") return "input";
  if (state === "run") return "running";
  if (state === "fail") return "failed";
  if (t.turn.status === "completed" && t.completionUnreviewed) return "complete";
  return "idle";
};

/* ---------- ui state ---------- */

let islandState = "collapsed"; // collapsed | expanded
let selectedId = "t1";
let compactActivityReady = false;
let compactActivityTimer = null;
let compactCountdownTimer = null;
let compactActivityDeadline = 0;
let compactApproval = null;
let approvalCard = null;
let ephemeralSequence = 0;
let defaultWorkspace = "~/dev/conn";
let newChatMode = false;
let threadGrouping = "threads";
const approvalRequest = {
  threadId: "t2",
  detail: "generate-schemas.sh verify",
  choices: ["approveOnce", "deny"],
};

const island = $("island");

function hideCompactActivity() {
  clearTimeout(compactActivityTimer);
  clearInterval(compactCountdownTimer);
  compactActivityTimer = null;
  compactCountdownTimer = null;
  $("compact-activity").setAttribute("aria-hidden", "true");
  delete island.dataset.activity;
}

function updateCompactCountdown() {
  const remaining = Math.max(0, compactActivityDeadline - Date.now());
  const progress = Math.min(1, 1 - remaining / 2400);
  $("activity-progress").style.setProperty("--activity-progress", progress);
}

function showCompactActivity({ verb, detail, kind = "work" }) {
  if (!compactActivityReady || islandState !== "collapsed" || compactApproval) return;
  $("activity-verb").textContent = verb;
  $("activity-detail").textContent = detail;
  $("compact-activity").dataset.kind = kind;
  $("compact-activity").dataset.mode = "event";
  $("activity-actions").hidden = true;
  $("activity-progress").hidden = false;
  $("compact-activity").setAttribute("aria-hidden", "false");
  island.dataset.activity = "visible";
  clearTimeout(compactActivityTimer);
  clearInterval(compactCountdownTimer);
  compactActivityDeadline = Date.now() + 2400;
  updateCompactCountdown();
  compactCountdownTimer = setInterval(updateCompactCountdown, 40);
  compactActivityTimer = setTimeout(hideCompactActivity, 2400);
}

function displayCompactApproval() {
  if (!compactApproval || islandState !== "collapsed") return;
  hideCompactActivity();
  $("activity-verb").textContent = "Approval needed";
  $("activity-detail").textContent = compactApproval.detail;
  $("compact-activity").dataset.mode = "approval";
  $("activity-actions").hidden = false;
  $("activity-progress").hidden = true;
  $("compact-activity").setAttribute("aria-hidden", "false");
  island.dataset.activity = "visible";
}

function queueCompactApproval() {
  if (!approvalCard?.querySelector(".appr-actions")) return;
  const exactCompactChoices = approvalRequest.choices.includes("approveOnce")
    && approvalRequest.choices.includes("deny");
  if (!exactCompactChoices) {
    selectThread(approvalRequest.threadId);
    setIslandState("expanded");
    toast("This request needs the full approval card");
    return;
  }
  compactApproval = approvalRequest;
  displayCompactApproval();
}

function setThreadMenuOpen(open) {
  if (open) setSettingsOpen(false);
  $("thread-menu").hidden = !open;
  $("thread-switcher").setAttribute("aria-expanded", String(open));
}

const threadMenuOpen = () => !$("thread-menu").hidden;

function setIslandState(next) {
  if (!["collapsed", "expanded"].includes(next)) return;
  if (next === islandState) return;
  islandState = next;
  island.dataset.state = next;
  document.querySelectorAll("[data-set-state]").forEach((b) =>
    b.classList.toggle("on", b.dataset.setState === next)
  );
  if (next === "collapsed") {
    setSettingsOpen(false);
    setThreadMenuOpen(false);
    displayCompactApproval();
  } else {
    hideCompactActivity();
  }
  if (next !== "collapsed") renderAll();
  if (next === "expanded") {
    setTimeout(() => $("composer-input").focus({ preventScroll: true }), 300);
  }
}

function selectThread(id) {
  newChatMode = false;
  selectedId = id;
  setThreadMenuOpen(false);
  document.querySelectorAll(".thread-log").forEach((el) =>
    el.classList.toggle("active", el.dataset.thread === id)
  );
  renderAll();
  scrollLog(id);
}

/* ---------- renderers ---------- */

function renderDots() {
  const counts = {};
  for (const t of threads) {
    const summary = summaryStateOf(t);
    if (summary) counts[summary] = (counts[summary] || 0) + 1;
  }
  const visible = summaryUrgencyOrder.filter((summary) => counts[summary]).slice(0, 3).reverse();
  $("bar-dots").innerHTML = visible
    .map((summary) => {
      const count = counts[summary] || 0;
      const noun = count === 1 ? "thread" : "threads";
      const label = `${count} ${noun}, ${summaryLabel[summary]}`;
      return `<button class="status-pin" data-summary="${summary}" title="${label}" aria-label="${label}">${count}</button>`;
    })
    .join("");
}

function threadOptionHtml(t) {
  const selected = t.id === selectedId;
  return `
    <button class="thread-option${selected ? " selected" : ""}" data-open="${t.id}"
            role="option" aria-selected="${selected}">
      <span class="dot" data-st="${stateOf(t)}"></span>
      <span class="thread-option-copy">
        <span class="thread-option-name">${t.name}</span>
        <span class="thread-option-line"><span>${stateLabel[stateOf(t)]}${t.completionUnreviewed ? " · not reviewed" : ""}</span><span>${t.cwd.split("/").filter(Boolean).pop() || "Conn"}</span></span>
      </span>
    </button>`;
}

function renderThreadMenu() {
  const query = $("thread-search").value.trim().toLowerCase();
  const matching = threads.filter((t) =>
    [t.name, t.cwd, t.branch, t.headline].some((value) => value.toLowerCase().includes(query))
  );
  if (threadGrouping === "projects") {
    const groups = matching.reduce((result, thread) => {
      const project = thread.cwd.split("/").filter(Boolean).pop() || "Other";
      (result[project] ||= []).push(thread);
      return result;
    }, {});
    $("thread-menu-list").innerHTML = Object.entries(groups).map(([project, rows]) =>
      `<div class="thread-project-label">${esc(project)}</div>${rows.map(threadOptionHtml).join("")}`
    ).join("") || `<div class="thread-menu-empty">No matching threads</div>`;
  } else {
    $("thread-menu-list").innerHTML = matching.map(threadOptionHtml).join("")
      || `<div class="thread-menu-empty">No matching threads</div>`;
  }
}

function renderHeader() {
  const t = threads.find((x) => x.id === selectedId);
  const st = stateOf(t);
  $("ws-title").textContent = newChatMode ? "New chat" : t.name;
  $("ws-dot").dataset.st = st;
  $("ws-dot").title = stateLabel[st];
  $("thread-switcher").title = newChatMode
    ? `New chat · ${defaultWorkspace}`
    : `${t.cwd} · ${t.branch} · ${stateLabel[st]}`;
  $("thread-switcher").setAttribute(
    "aria-label",
    newChatMode ? "Thread: New chat" : `Thread: ${t.name}, ${stateLabel[st]}`
  );
  const pct = Math.min(100, Math.round((t.tokens.used / t.tokens.window) * 100));
  const ctx = $("ctx");
  $("ctx-pct").textContent = pct + "%";
  $("ctx-arc").style.strokeDashoffset = (75.4 * (1 - pct / 100)).toFixed(2);
  ctx.title = `${(t.tokens.used / 1000).toFixed(1)}k of ${Math.round(t.tokens.window / 1000)}k context used`;
  ctx.classList.toggle("warn", pct >= 80);
  const action = $("composer-action");
  $("review-outcome").hidden = newChatMode || !t.completionUnreviewed;
  const isRunning = !newChatMode && st === "run";
  action.dataset.action = isRunning ? "stop" : "send";
  action.type = isRunning ? "button" : "submit";
  action.setAttribute("aria-label", isRunning ? "stop turn" : "send");
  action.title = isRunning ? "Stop turn" : "Send message";
  action.innerHTML = isRunning
    ? `<svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><rect x="4.5" y="4.5" width="7" height="7" rx="1.4" fill="currentColor"/></svg>`
    : `<svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><path d="M8 13V3M4 7l4-4 4 4" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
  const blocked = !newChatMode && ["wait", "input", "fail"].includes(st);
  action.disabled = blocked;
  $("model-picker").disabled = !newChatMode && st === "run";
  $("composer-input").placeholder = newChatMode
    ? "Message your new chat…"
    : st === "run"
    ? "Steer the running turn"
    : st === "wait" ? "Resolve approval to continue"
    : "Message this thread";
  $("transcript").hidden = newChatMode;
  $("new-chat-panel").hidden = !newChatMode;
  $("new-chat-workspace").textContent = defaultWorkspace;
  $("ctx").hidden = newChatMode;
  $("model-picker").setAttribute("aria-label", newChatMode ? "Model for new chat" : "Model for next message");
}

function renderAll() {
  renderDots();
  renderThreadMenu();
  renderHeader();
}

/* ---------- transcript building ---------- */

function log(id) {
  return document.querySelector(`.thread-log[data-thread="${id}"]`);
}
function scrollLog(id) {
  const el = log(id);
  if (el) el.scrollTop = el.scrollHeight;
}
function addItem(id, html) {
  const wrap = document.createElement("div");
  wrap.className = "item";
  wrap.innerHTML = html;
  log(id).appendChild(wrap);
  // cap scrollback
  const items = log(id).children;
  if (items.length > 40) items[0].remove();
  scrollLog(id);
  return wrap;
}

const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");

function userMsg(id, text) { addItem(id, `<div class="item-user">${esc(text)}</div>`); }
function reasoningMsg(id, text) {
  const el = addItem(id, `<div class="item-reasoning">${esc(text)}</div>`);
  return el;
}
function fileChange(id, file, plus, minus) {
  addItem(id, `<div class="item-file"><span>${esc(file)}</span><span class="plus">+${plus}</span><span class="minus">-${minus}</span></div>`);
}

function agentMsg(id, text, { stream = true, cps = 28 } = {}) {
  const el = addItem(id, `<div class="item-agent"></div>`);
  const body = el.firstElementChild;
  if (!stream || reducedMotion) { body.textContent = text; return Promise.resolve(el); }
  body.classList.add("streaming");
  return new Promise((resolve) => {
    let i = 0;
    const iv = setInterval(() => {
      i += 2;
      body.textContent = text.slice(0, i);
      if (i % 24 === 0) scrollLog(id);
      if (i >= text.length) {
        clearInterval(iv);
        body.classList.remove("streaming");
        scrollLog(id);
        resolve(el);
      }
    }, 1000 / cps * 2);
    timers.push(iv);
  });
}

function cmdItem(id, command) {
  const el = addItem(
    id,
    `<div class="item-cmd">
       <div class="cmd-head">
         <span class="cmd-line"><b>$</b> ${esc(command)}</span>
         <span class="cmd-chip" data-st="run">running</span>
       </div>
       <div class="cmd-out"></div>
     </div>`
  );
  const out = el.querySelector(".cmd-out");
  const chip = el.querySelector(".cmd-chip");
  return {
    el,
    line(text) {
      const d = document.createElement("div");
      d.textContent = text;
      out.appendChild(d);
      out.scrollTop = out.scrollHeight;
      scrollLog(id);
    },
    done(label = "exit 0", st = "ok") {
      chip.textContent = label;
      chip.dataset.st = st;
    },
  };
}

function planItem(id, steps) {
  const el = addItem(
    id,
    `<div class="item-plan">
       <div class="plan-title">Turn plan</div>
       ${steps.map((s) => `
         <div class="plan-step" data-st="${s.status}">
           <span class="pmark"></span><span>${esc(s.step)}</span>
         </div>`).join("")}
     </div>`
  );
  return {
    el,
    set(index, status) {
      const rows = el.querySelectorAll(".plan-step");
      if (rows[index]) rows[index].dataset.st = status;
    },
  };
}

/* ---------- static transcripts (t2, t3, t4) ---------- */

function buildTranscripts() {
  const host = $("transcript");
  host.innerHTML = threads
    .map((t) => `<div class="thread-log ${t.id === selectedId ? "active" : ""}" data-thread="${t.id}"></div>`)
    .join("");

  // t2: waiting on approval
  userMsg("t2", "Re-verify the pinned 0.144.5 schema bundle before we branch for 0.144.6.");
  agentMsg("t2", "Manifest hashes match the committed checkpoint. I need to run the generator in verify mode to confirm a clean diff against the pinned bundle.", { stream: false });
  approvalCard = addItem(
    "t2",
    `<div class="item-approval" id="approval-card">
       <div class="appr-title">Command approval requested</div>
       <div class="appr-cmd">./scripts/generate-codex-app-server-schemas.sh verify</div>
       <div class="appr-cwd">in ~/dev/conn · workspace-write</div>
       <div class="appr-actions">
         <button class="btn btn-approve" id="btn-approve">Approve once</button>
         <button class="btn btn-deny" id="btn-deny">Deny</button>
       </div>
     </div>`
  );
  approvalCard.querySelector("#btn-approve").addEventListener("click", () => resolveApproval(approvalCard, true));
  approvalCard.querySelector("#btn-deny").addEventListener("click", () => resolveApproval(approvalCard, false));

  // t3: idle, finished work
  userMsg("t3", "Simplify the island to collapsed and expanded states so the interaction feels more direct.");
  fileChange("t3", "ConnSurfaceView.swift", 118, 12);
  fileChange("t3", "IslandGeometry.swift", 41, 6);
  agentMsg("t3", "The island now moves directly between its compact status bar and the full workspace. Hover no longer changes its size, so expansion is always intentional.", { stream: false });

  // t4: failed turn
  userMsg("t4", "Extend the sanitizer to cover the new evidence labels.");
  agentMsg("t4", "Started extending the allowlist validation, then the provider rejected the request.", { stream: false });
  addItem(
    "t4",
    `<div class="item-error"><b>Turn failed · usageLimitExceeded</b><br>
     The provider reported a usage limit. Retry the turn once the limit window resets, or switch accounts in Codex.</div>`
  );
}

function resolveApproval(card, approved) {
  const actions = card.querySelector(".appr-actions");
  if (!actions) return;
  const t = threads.find((x) => x.id === "t2");
  compactApproval = null;
  hideCompactActivity();
  actions.remove();
  const note = document.createElement("div");
  note.className = "appr-resolved";
  note.textContent = approved ? "Approved · serverRequest resolved on this connection" : "Denied · serverRequest resolved";
  card.querySelector(".item-approval").appendChild(note);

  if (approved) {
    t.status = { type: "active", activeFlags: [] };
    t.headline = "Running generate-schemas.sh verify";
    renderAll();
    const c = cmdItem("t2", "./scripts/generate-codex-app-server-schemas.sh verify");
    const lines = [
      "regenerating stable schemas (267 files)",
      "regenerating experimental schemas (337 files)",
      "normalizing output",
      "comparing against pinned manifest",
      "verify: no diff",
    ];
    lines.forEach((l, i) => schedule(() => c.line(l), 700 + i * 650));
    schedule(async () => {
      c.done();
      await agentMsg("t2", "Verify passed with no diff. The 0.144.5 baseline is intact, so the 0.144.6 comparison can branch from it safely.");
      t.status = { type: "idle" };
      t.turn.status = "completed";
      t.completionUnreviewed = true;
      t.headline = "Idle · verify passed, no diff";
      renderAll();
    }, 700 + lines.length * 650 + 400);
  } else {
    t.status = { type: "idle" };
    t.turn.status = "completed";
    t.completionUnreviewed = true;
    t.headline = "Idle · approval denied";
    agentMsg("t2", "Understood. Leaving the pinned bundle untouched; nothing was executed.", { stream: false });
    renderAll();
  }
}

/* ---------- t1 live simulation ---------- */

const timers = [];
function schedule(fn, ms) {
  const id = setTimeout(fn, ms);
  timers.push(id);
  return id;
}
function clearSim() {
  timers.forEach((t) => { clearTimeout(t); clearInterval(t); });
  timers.length = 0;
  hideCompactActivity();
}

const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

let t1Plan = null;
let t1Cycle = 0;
let t1Interrupted = false;

const cycles = [
  {
    cmd: "swift test --filter AdapterQueueBounds",
    activity: { verb: "Running", detail: "AdapterQueueBounds tests", kind: "command" },
    activityUpdates: [
      { delay: 1200, verb: "Reading", detail: "ProxyStdioTransport.swift", kind: "read" },
      { delay: 2600, verb: "Writing", detail: "ControlTransportObservation.swift", kind: "write" },
    ],
    out: [
      "Building for debugging...",
      "Build complete (4.2s)",
      "Suite AdapterQueueBounds started",
      "pass testByteBoundShedding (0.31s)",
      "pass testMessageCountBound (0.18s)",
      "pass testPresentationDeltaShedOnly (0.22s)",
    ],
    reasoning: "Checking whether shed counters belong on the adapter or the probe side.",
    msg: "Queue bounds hold under the forced slow consumer. Shedding only ever drops presentation deltas, so approvals and turn lifecycle events always get through. Moving to the reconnect path next.",
    headline: "Running swift test · queue bounds",
    planStep: 2,
    tokens: 6_800,
  },
  {
    cmd: "swift test --filter ReconnectRehydration",
    activity: { verb: "Reading", detail: "thread/read response", kind: "read" },
    activityUpdates: [
      { delay: 1700, verb: "Searching the web", detail: "App Server reconnect behavior", kind: "web" },
    ],
    out: [
      "Suite ReconnectRehydration started",
      "pass testDurableThreadRead (0.41s)",
      "pass testTerminalTurnStatusAfterReconnect (0.29s)",
      "pass testItemRehydration (0.37s)",
    ],
    reasoning: "A reconnecting client may miss turn/completed, so the terminal check must go through thread/read.",
    msg: "Rehydration is solid: a fresh connection reads the durable thread, confirms terminal turn status through thread/read, and rebuilds items without replaying the socket. Docs are the last step.",
    headline: "Running swift test · reconnect",
    planStep: 3,
    tokens: 7_600,
  },
  {
    cmd: "git diff --stat docs/transport.md",
    activity: { verb: "Writing", detail: "docs/transport.md", kind: "write" },
    activityUpdates: [],
    out: [
      "docs/transport.md | 64 +++++++++-----",
      "1 file changed, 46 insertions(+), 18 deletions(-)",
    ],
    reasoning: null,
    msg: "Transport doc now records the proxy stdio relay as the single production path and the reconnect contract. That closes out this turn's plan.",
    headline: "Updating transport docs",
    planStep: 4,
    tokens: 3_100,
  },
];

function startT1Turn(first) {
  const t = threads.find((x) => x.id === "t1");
  t1Interrupted = false;
  t.status = { type: "active", activeFlags: [] };
  t.turn.status = "inProgress";
  t.completionUnreviewed = false;

  if (first) {
    userMsg("t1", "Wire the proxy transport into the adapter and get the queue-bound tests green.");
    t1Plan = planItem("t1", [
      { step: "Audit adapter queue bounds", status: "completed" },
      { step: "Wire proxy stdio relay", status: "completed" },
      { step: "Run focused adapter tests", status: "inProgress" },
      { step: "Verify reconnect rehydration", status: "pending" },
      { step: "Update transport docs", status: "pending" },
    ]);
  }
  runT1Cycle();
}

function runT1Cycle() {
  const t = threads.find((x) => x.id === "t1");
  const c = cycles[t1Cycle % cycles.length];
  t.headline = c.headline;
  renderAll();
  showCompactActivity(c.activity);
  c.activityUpdates.forEach((activity) =>
    schedule(() => { if (!t1Interrupted) showCompactActivity(activity); }, activity.delay)
  );

  const cmd = cmdItem("t1", c.cmd);
  c.out.forEach((l, i) => schedule(() => { if (!t1Interrupted) cmd.line(l); }, 800 + i * 750));
  const afterCmd = 800 + c.out.length * 750 + 300;

  schedule(() => {
    if (t1Interrupted) return;
    cmd.done();
    t1Plan.set(c.planStep, "completed");
    if (c.planStep + 1 < 5) t1Plan.set(c.planStep + 1, "inProgress");
    t.tokens.used += c.tokens;
    renderHeader();
  }, afterCmd);

  schedule(async () => {
    if (t1Interrupted) return;
    if (c.reasoning) {
      reasoningMsg("t1", c.reasoning);
      await new Promise((r) => schedule(r, 1500));
    }
    if (t1Interrupted) return;
    t.headline = "Responding";
    renderAll();
    await agentMsg("t1", c.msg);
    if (t1Interrupted) return;

    // turn/completed
    t1Cycle += 1;
    const finished = t1Cycle % cycles.length === 0;
    t.status = { type: "idle" };
    t.turn.status = "completed";
    t.completionUnreviewed = true;
    t.headline = finished ? "Idle · plan complete, turn finished" : "Idle · turn finished just now";
    renderAll();

    const continueAfterReview = () => {
      if (t.completionUnreviewed) {
        schedule(continueAfterReview, 1000);
        return;
      }
      if (finished) {
        userMsg("t1", "Great. Run the whole loop again against the 0.144.6 daemon.");
        t1Plan = planItem("t1", [
          { step: "Point probe at 0.144.6 daemon", status: "completed" },
          { step: "Re-run queue bound suite", status: "inProgress" },
          { step: "Re-run reconnect suite", status: "pending" },
          { step: "Compare schema surfaces", status: "pending" },
          { step: "Record compatibility notes", status: "pending" },
        ]);
      }
      startT1Turn(false);
    };
    schedule(continueAfterReview, 5200);
  }, afterCmd + 400);
}

function interruptT1() {
  const t = threads.find((x) => x.id === "t1");
  if (stateOf(t) !== "run") return;
  t1Interrupted = true;
  clearSim();
  t.status = { type: "idle" };
  t.turn.status = "interrupted";
  t.completionUnreviewed = false;
  t.headline = "Idle · turn interrupted";
  addItem("t1", `<div class="item-error" style="border-color:rgba(251,191,36,.35);border-left-color:var(--st-wait)"><b style="color:var(--st-wait)">Turn interrupted</b><br>turn/interrupt acknowledged; terminal state confirmed through thread/read.</div>`);
  renderAll();
  schedule(() => startT1Turn(false), 9000);
}

function interruptSelectedThread() {
  if (selectedId === "t1") {
    interruptT1();
    return;
  }
  const t = threads.find((x) => x.id === selectedId);
  if (!t || stateOf(t) !== "run") return;
  t.status = { type: "idle" };
  t.turn.status = "interrupted";
  t.completionUnreviewed = false;
  t.headline = "Idle · turn interrupted";
  addItem(selectedId, `<div class="item-error" style="border-color:rgba(251,191,36,.35);border-left-color:var(--st-wait)"><b style="color:var(--st-wait)">Turn interrupted</b><br>turn/interrupt acknowledged.</div>`);
  renderAll();
}

/* ---------- interactions ---------- */

function setSettingsOpen(open) {
  if (open) setThreadMenuOpen(false);
  $("settings-pop").classList.toggle("show", open);
  document.querySelector(".bar-gear").classList.toggle("open", open);
}
const settingsOpen = () => $("settings-pop").classList.contains("show");

function restoreMockSettings() {
  try {
    defaultWorkspace = localStorage.getItem("conn-mock-default-workspace") || defaultWorkspace;
  } catch (_) {
    // The mock still works when local storage is unavailable.
  }
  $("default-workspace").value = defaultWorkspace;
}

function showNewChatComposer() {
  newChatMode = true;
  setThreadMenuOpen(false);
  setSettingsOpen(false);
  setIslandState("expanded");
  renderAll();
  setTimeout(() => $("composer-input").focus({ preventScroll: true }), 80);
}

function createEphemeralChat(initialPrompt) {
  ephemeralSequence += 1;
  const id = `ephemeral-${Date.now()}-${ephemeralSequence}`;
  const thread = {
    id,
    name: ephemeralSequence === 1 ? "new ephemeral chat" : `new ephemeral chat ${ephemeralSequence}`,
    cwd: defaultWorkspace,
    branch: "ephemeral",
    ephemeral: true,
    model: $("model-picker").value,
    status: { type: "active", activeFlags: [] },
    turn: { status: "inProgress" },
    completionUnreviewed: false,
    headline: `Starting · ${defaultWorkspace} · ${$("model-picker").value}`,
    tokens: { used: 0, window: 128_000 },
  };
  threads.unshift(thread);
  const threadLog = document.createElement("div");
  threadLog.className = "thread-log";
  threadLog.dataset.thread = id;
  threadLog.innerHTML = "";
  $("transcript").prepend(threadLog);
  selectThread(id);
  userMsg(id, initialPrompt);
  setIslandState("expanded");
  renderAll();
  schedule(async () => {
    await agentMsg(id, "Picking that up now. I’ll report back here as the work progresses.");
    thread.status = { type: "idle" };
    thread.turn.status = "completed";
    thread.completionUnreviewed = true;
    thread.headline = "Completed · just now";
    renderAll();
  }, 650);
  setTimeout(() => $("composer-input").focus({ preventScroll: true }), 80);
}

document.addEventListener("click", (e) => {
  const gear = e.target.closest("[data-settings]");
  if (gear) { setSettingsOpen(!settingsOpen()); return; }
  if (!e.target.closest(".settings-pop") && settingsOpen()) {
    setSettingsOpen(false);
  }
  const newChat = e.target.closest("#new-chat");
  if (newChat) { showNewChatComposer(); return; }
  if (e.target.closest("#cancel-new-chat")) {
    newChatMode = false;
    renderAll();
    setTimeout(() => $("composer-input").focus({ preventScroll: true }), 50);
    return;
  }
  const reviewOutcome = e.target.closest("#review-outcome");
  if (reviewOutcome) {
    const thread = threads.find((candidate) => candidate.id === selectedId);
    if (thread?.completionUnreviewed) {
      thread.completionUnreviewed = false;
      renderAll();
      toast("Completed outcome marked reviewed");
    }
    return;
  }
  const settingAction = e.target.closest("[data-setting-action]");
  if (settingAction) {
    const messages = {
      sync: "Mock: thread inventory refreshed",
      projects: "Mock: grouped projects view opened",
      labs: "Mock: Shared Desktop Labs setup opened",
      pause: "Mock: Conn paused",
      hide: "Mock: Conn hidden",
    };
    toast(messages[settingAction.dataset.settingAction]);
    return;
  }
  const codex = e.target.closest("[data-codex]");
  if (codex) {
    toast("Opening Codex without targeting a thread");
    return;
  }
  const switcher = e.target.closest("#thread-switcher");
  if (switcher) {
    setThreadMenuOpen(!threadMenuOpen());
    return;
  }
  const recency = e.target.closest("[data-recency]");
  if (recency) {
    document.querySelectorAll("[data-recency]").forEach((option) => {
      const selected = option === recency;
      option.classList.toggle("selected", selected);
      option.querySelector("span").textContent = selected ? "✓" : "";
    });
    $("thread-recency-label").textContent = recency.dataset.recency;
    return;
  }
  const grouping = e.target.closest("[data-group]");
  if (grouping) {
    threadGrouping = grouping.dataset.group;
    document.querySelectorAll("[data-group]").forEach((option) => option.classList.toggle("active", option === grouping));
    renderThreadMenu();
    return;
  }
  const pill = e.target.closest(".status-pin");
  if (pill) {
    if (pill.dataset.summary === "approval" && approvalCard?.querySelector(".appr-actions")) {
      selectThread("t2");
      queueCompactApproval();
      return;
    }
    const t = [...threads]
      .sort((a, b) => statePriority[stateOf(a)] - statePriority[stateOf(b)])
      .find((x) => summaryStateOf(x) === pill.dataset.summary);
    if (t) {
      selectThread(t.id);
      setIslandState("expanded");
    }
    return;
  }
  const open = e.target.closest("[data-open]");
  if (open) {
    selectThread(open.dataset.open);
    setIslandState("expanded");
    return;
  }
  const seg = e.target.closest("[data-set-state]");
  if (seg) { setIslandState(seg.dataset.setState); return; }
  if (threadMenuOpen() && !e.target.closest(".thread-switcher-wrap")) setThreadMenuOpen(false);
  if (!island.contains(e.target) && !e.target.closest(".controls") && !e.target.closest(".settings-pop")) {
    setIslandState("collapsed");
  }
});

/* tapping the bar: expand when collapsed, minimize otherwise.
   dot pills and the Codex button handle their own clicks above. */
$("island-bar").addEventListener("click", (e) => {
  if (e.target.closest(".status-pin") || e.target.closest("[data-codex]") || e.target.closest("[data-settings]")) return;
  setIslandState(islandState === "collapsed" ? "expanded" : "collapsed");
});

/* transient toast for actions the mock cannot really perform */
let toastEl = null;
let toastTimer = null;
function toast(msg) {
  if (!toastEl) {
    toastEl = document.createElement("div");
    toastEl.className = "toast";
    document.body.appendChild(toastEl);
  }
  toastEl.textContent = msg;
  requestAnimationFrame(() => toastEl.classList.add("show"));
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toastEl.classList.remove("show"), 1900);
}

document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    if (settingsOpen()) { setSettingsOpen(false); return; }
    if (threadMenuOpen()) { setThreadMenuOpen(false); return; }
    setIslandState("collapsed");
  }
});

$("composer-action").addEventListener("click", () => {
  if ($("composer-action").dataset.action === "stop") interruptSelectedThread();
});

$("compact-accept").addEventListener("click", () => {
  if (approvalCard && compactApproval?.choices.includes("approveOnce")) resolveApproval(approvalCard, true);
});
$("compact-reject").addEventListener("click", () => {
  if (approvalCard && compactApproval?.choices.includes("deny")) resolveApproval(approvalCard, false);
});

$("default-workspace").addEventListener("change", (e) => {
  const next = e.currentTarget.value.trim();
  if (!next) {
    e.currentTarget.value = defaultWorkspace;
    toast("Choose a workspace before starting a new chat");
    return;
  }
  defaultWorkspace = next;
  try {
    localStorage.setItem("conn-mock-default-workspace", defaultWorkspace);
  } catch (_) {
    // This preference is best-effort in the standalone mock.
  }
  $("new-chat-workspace").textContent = defaultWorkspace;
  toast(`Default workspace set to ${defaultWorkspace}`);
});

$("thread-search").addEventListener("input", renderThreadMenu);

$("composer").addEventListener("submit", (e) => {
  e.preventDefault();
  const input = $("composer-input");
  const text = input.value.trim();
  if (!text) return;
  input.value = "";
  if (newChatMode) {
    createEphemeralChat(text);
    return;
  }
  const t = threads.find((x) => x.id === selectedId);
  log(selectedId)?.querySelector(".empty-chat")?.remove();
  userMsg(selectedId, text);
  const st = stateOf(t);
  if (st === "run") {
    reasoningMsg(selectedId, "Steering note received; folding it into the active turn.");
  } else if (st === "idle") {
    t.status = { type: "active", activeFlags: [] };
    t.turn.status = "inProgress";
    t.completionUnreviewed = false;
    t.headline = "Starting turn";
    renderAll();
    schedule(async () => {
      await agentMsg(selectedId, "Picking that up now. I will report back on this thread as items complete.");
      t.status = { type: "idle" };
      t.turn.status = "completed";
      t.completionUnreviewed = true;
      t.headline = "Idle · turn finished just now";
      renderAll();
    }, 700);
  }
});

/* menu bar clock */
function tickClock() {
  const now = new Date();
  const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  let h = now.getHours();
  const ampm = h >= 12 ? "PM" : "AM";
  h = h % 12 || 12;
  $("mb-clock").textContent =
    `${days[now.getDay()]} ${months[now.getMonth()]} ${now.getDate()} ${h}:${String(now.getMinutes()).padStart(2, "0")} ${ampm}`;
}
setInterval(tickClock, 15_000);
tickClock();

/* ---------- boot ---------- */

buildTranscripts();
restoreMockSettings();
renderAll();
document.querySelector('[data-set-state="collapsed"]').classList.add("on");
compactActivityReady = true;
startT1Turn(true);
schedule(queueCompactApproval, 6200);

/* deep link for demos/screenshots: #expanded */
const hashTokens = location.hash.replace("#", "").split("-").filter(Boolean);
const hashState = hashTokens.find((t) => t === "expanded");
if (hashState) {
  document.documentElement.classList.add("no-anim");
  setIslandState(hashState);
  schedule(() => document.documentElement.classList.remove("no-anim"), 600);
}
