import demoScript from "./demo/app.js?raw";
import demoStyles from "./demo/styles.css?raw";
import demoHtml from "./demo/index.html?raw";

const inlineScript = demoScript
  .replace("schedule(queueCompactApproval, 6200);", "")
  .replace(/<\/script/gi, "<\\/script");

const landingPresentationStyles = `
  :root {
    --font: "Avenir Next", -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
    --font-mono: "SF Mono", ui-monospace, Menlo, monospace;
    --accent: #35e2c3;
    --accent-dim: rgba(53, 226, 195, 0.14);
    --island-bg: #060806;
    --island-line: rgba(248, 248, 244, 0.1);
  }

  html[data-theme="dark"] {
    --desk-a: #0a0d0b;
    --desk-b: #17352f;
    --desk-c: #070807;
    --mb-bg: rgba(7, 8, 7, 0.7);
    --surface: rgba(10, 14, 12, 0.94);
    --surface-2: rgba(248, 248, 244, 0.055);
    --surface-3: rgba(248, 248, 244, 0.08);
    --win-bg: rgba(18, 27, 23, 0.48);
    --win-line: rgba(248, 248, 244, 0.075);
    --ctrl-bg: rgba(7, 8, 7, 0.82);
    --shadow: 0 28px 90px rgba(3, 14, 11, 0.58);
  }

  body {
    background:
      radial-gradient(900px 540px at 50% 18%, rgba(38, 85, 74, 0.72), transparent 64%),
      linear-gradient(155deg, var(--desk-a), var(--desk-c));
  }

  .menubar { border-bottom: 1px solid rgba(248, 248, 244, 0.05); }
  .faux-window { display: none; }
  .controls, .controls-hint { display: none; }

  .island { top: 44px; border-radius: var(--radius-collapsed); }
  .island[data-state="collapsed"][data-activity="visible"] { border-radius: 15px; }
  .settings-pop { top: calc(var(--bar-h) + 54px); }

  .status-pin {
    --pin-color: #6b7280;
    width: 18px;
    height: 18px;
    display: grid;
    place-items: center;
    border: 1px solid color-mix(in srgb, var(--pin-color) 46%, transparent);
    border-radius: 999px;
    color: var(--pin-color);
    background: color-mix(in srgb, var(--pin-color) 10%, #060806);
    font-size: 9px;
  }
  .status-pin[data-summary="running"] { --pin-color: var(--st-run); animation: none; }
  .status-pin[data-summary="complete"] { --pin-color: #34d399; }
  .status-pin[data-summary="approval"] { --pin-color: var(--st-wait); animation: none; }
  .status-pin[data-summary="input"] { --pin-color: var(--st-input); animation: none; }
  .status-pin[data-summary="failed"] { --pin-color: var(--st-fail); }
  .status-pin[data-summary="idle"] { --pin-color: var(--st-idle); }
  .status-pin:hover { transform: translateY(-1px); filter: brightness(1.12); }

  .island[data-state="expanded"] { border-radius: 0 0 28px 28px; }
  .workspace { background: rgba(9, 12, 10, 0.94); }
  .thread-switcher, .composer, .thread-menu { border-color: rgba(248, 248, 244, 0.1); }
  .settings-pop { border-radius: 18px; }
`;

const landingBridgeScript = `
  window.addEventListener("message", (event) => {
    if (event.data?.source !== "conn-landing") return;
    if (event.data.mode === "approval") {
      setIslandState("collapsed");
      compactApproval = approvalRequest;
      displayCompactApproval();
      return;
    }
    if (["collapsed", "expanded"].includes(event.data.mode)) {
      compactApproval = null;
      hideCompactActivity();
      setIslandState(event.data.mode);
      if (event.data.mode === "collapsed") hideCompactActivity();
    }
  });
`;

export const demoDocument = demoHtml
  .replace('<link rel="stylesheet" href="styles.css?v=16">', `<style>${demoStyles}\n${landingPresentationStyles}</style>`)
  .replace('<script src="app.js?v=16"></script>', `<script>${inlineScript}<\/script><script>${landingBridgeScript}<\/script>`);
