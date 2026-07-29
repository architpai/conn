"use client";

import { useEffect, useState } from "react";
import "./globals.css";

type DemoMode = "collapsed" | "session" | "new-session";

const GithubIcon = () => (
  <svg viewBox="0 0 24 24" aria-hidden="true">
    <path d="M12 2a10 10 0 0 0-3.16 19.49c.5.09.68-.22.68-.48v-1.7c-2.78.6-3.37-1.18-3.37-1.18-.45-1.16-1.11-1.47-1.11-1.47-.91-.62.07-.61.07-.61 1 .07 1.53 1.03 1.53 1.03.9 1.53 2.35 1.09 2.92.83.09-.65.35-1.09.63-1.34-2.22-.25-4.55-1.11-4.55-4.94 0-1.09.39-1.98 1.03-2.68-.1-.25-.45-1.27.1-2.64 0 0 .84-.27 2.75 1.02A9.57 9.57 0 0 1 12 7c.85 0 1.71.11 2.51.33 1.91-1.29 2.75-1.02 2.75-1.02.55 1.37.2 2.39.1 2.64.64.7 1.03 1.59 1.03 2.68 0 3.84-2.34 4.68-4.57 4.93.36.31.68.92.68 1.86V21c0 .27.18.58.69.48A10 10 0 0 0 12 2Z" />
  </svg>
);

const ConnMark = ({ small = false }: { small?: boolean }) => (
  <svg className={small ? "conn-mark small" : "conn-mark"} viewBox="0 0 32 32" aria-hidden="true">
    <circle cx="16" cy="16" r="12" fill="none" stroke="currentColor" strokeWidth="2.2" />
    <g className="orbit-nodes">
      <circle cx="16" cy="9" r="3" fill="currentColor" />
      <circle cx="16" cy="23" r="3" fill="currentColor" />
    </g>
  </svg>
);

const OpenAIMark = ({ compact = false }: { compact?: boolean }) => (
  <span className={compact ? "openai-mark compact" : "openai-mark"} aria-label="Codex">
    <span aria-hidden="true" />
  </span>
);

const StatusPill = ({ tone, count, label }: { tone: string; count: number; label: string }) => (
  <span className={`demo-status ${tone}`} title={`${count} ${label} Sessions`}>
    <b>{count}</b><span>{label}</span>
  </span>
);

const SessionRow = ({
  title,
  project,
  status,
  selected = false,
}: {
  title: string;
  project: string;
  status: string;
  selected?: boolean;
}) => (
  <button type="button" className={`session-row ${selected ? "selected" : ""}`}>
    <OpenAIMark />
    <span className="session-row-copy">
      <b>{title}</b>
      <span>{project}</span>
      <em className={status === "Working" ? "working" : ""}>{status}</em>
    </span>
  </button>
);

function ProductSurface({
  mode,
  onModeChange,
  compact = false,
}: {
  mode: DemoMode;
  onModeChange?: (mode: DemoMode) => void;
  compact?: boolean;
}) {
  const expanded = mode !== "collapsed";
  const toggle = () => onModeChange?.(expanded ? "collapsed" : "session");

  return (
    <div className={`product-stage mode-${mode} ${compact ? "compact-product" : ""}`}>
      <div
        className="conn-chrome"
        onClick={toggle}
        onKeyDown={(event) => {
          if (event.key === "Enter" || event.key === " ") {
            event.preventDefault();
            toggle();
          }
        }}
        role="button"
        tabIndex={0}
        aria-expanded={expanded}
        aria-label={expanded ? "Collapse Conn demo" : "Expand Conn demo"}
      >
        <span className="chrome-brand"><ConnMark small /><b>CONN</b></span>
        {expanded && <span className="integration-live"><i />Live</span>}
        <span className="camera-gap" aria-hidden="true" />
        <span className="chrome-metrics">
          <StatusPill tone="working" count={1} label="Working" />
          <StatusPill tone="idle" count={4} label="Idle" />
          {expanded && (
            <>
              <button
                type="button"
                className="chrome-action"
                aria-label="Create a new Session"
                onClick={(event) => {
                  event.stopPropagation();
                  onModeChange?.("new-session");
                }}
              >+</button>
              <span className="chrome-action" aria-label="Settings">⚙</span>
            </>
          )}
        </span>
      </div>

      {compact && (
        <div className="notification-preview">
          <span className="notification-wave" aria-hidden="true"><i /><i /><i /><i /><i /></span>
          <span><b>Design Conn harness abstraction</b><em>Updating the provider-neutral landing experience.</em></span>
          <i className="countdown-ring" aria-hidden="true" />
        </div>
      )}

      <div className="conn-workspace" aria-hidden={!expanded}>
        <aside className="session-sidebar">
          <header><b>Sessions</b><span aria-label="Filter Sessions">⌾</span></header>
          <div className="session-list">
            <SessionRow title="Design Conn harness abstraction" project="Conn" status="Working" selected={mode === "session"} />
            <SessionRow title="Polish onboarding flow" project="Aurora" status="Idle" />
            <SessionRow title="Review release checklist" project="Beacon" status="Idle" />
          </div>
        </aside>

        <section className="session-detail">
          {mode === "new-session" ? (
            <>
              <header className="session-header">
                <OpenAIMark />
                <span><b>New Session</b><em>~/dev/conn · Codex</em></span>
                <span className="session-state ready">Ready</span>
                <button type="button" className="close-draft" onClick={() => onModeChange?.("session")}>×</button>
              </header>
              <div className="new-session-empty">
                <span className="new-session-symbol">＋</span>
                <b>Start a New Session</b>
                <p>Write your first message below. Conn creates the Harness Session only when you send it.</p>
              </div>
              <Composer placeholder="Message your Harness…" />
            </>
          ) : (
            <>
              <header className="session-header">
                <OpenAIMark />
                <span><b>Design Conn harness abstraction</b><em>Conn · Codex</em></span>
                <span className="session-state working">Working</span>
                <button type="button">Open</button>
              </header>
              <div className="transcript">
                <div className="user-bubble">Update the landing page so it matches the current Conn UI.</div>
                <article className="run-card completed">
                  <header><span>✓</span><b>Completed Run</b><em>27 items</em></header>
                  <p>Added the provider-neutral Integration boundary while keeping Codex as the only shipping harness in v0.2.</p>
                  <small>◷ Worked for 3m 42s</small>
                </article>
                <article className="run-card current">
                  <header><span className="tiny-wave">╿</span><b>Current Run</b><em>6 items</em></header>
                  <div className="agent-bubble"><small>Assistant</small>Refreshing the public product mock and documentation now.</div>
                  <div className="tool-activity"><span>⌁</span><b>Building landing page</b><em>running</em></div>
                </article>
              </div>
              <Composer placeholder="Follow up or steer…" running />
            </>
          )}
        </section>
      </div>
    </div>
  );
}

function Composer({ placeholder, running = false }: { placeholder: string; running?: boolean }) {
  return (
    <div className="demo-composer">
      <button type="button" className="model-control">☷ <span>GPT-5.6-Sol · Medium</span>⌃⌄</button>
      <span className="composer-field">{placeholder}</span>
      <button type="button" className="send-control">{running ? "■" : "↑"}</button>
    </div>
  );
}

function SocialBanner() {
  return (
    <main className="social-banner">
      <div className="banner-copy">
        <span className="banner-brand"><ConnMark /><b>CONN</b></span>
        <h1>Your harness,<br /><em>at a glance.</em></h1>
        <p>A native macOS supervision surface.<br />Codex first. Provider-neutral by design.</p>
        <span className="banner-meta">macOS · Swift · local-first · alpha 0.2</span>
      </div>
      <div className="banner-product">
        <ProductSurface mode="session" />
      </div>
    </main>
  );
}

export default function Home() {
  const [demoMode, setDemoMode] = useState<DemoMode>("session");

  useEffect(() => {
    const items = Array.from(document.querySelectorAll<HTMLElement>("[data-reveal]"));
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      items.forEach((item) => item.classList.add("revealed"));
      return;
    }
    const observer = new IntersectionObserver(
      (entries) => entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add("revealed");
          observer.unobserve(entry.target);
        }
      }),
      { threshold: 0.15, rootMargin: "0px 0px -8%" },
    );
    items.forEach((item) => observer.observe(item));
    return () => observer.disconnect();
  }, []);

  if (new URLSearchParams(window.location.search).has("banner")) {
    return <SocialBanner />;
  }

  return (
    <main>
      <nav className="nav-shell enter" style={{ "--delay": "0ms" } as React.CSSProperties}>
        <a className="logo" href="#top" aria-label="Conn home"><ConnMark small /><span>conn</span></a>
        <div className="nav-links">
          <a href="#experience">Experience</a>
          <a href="#principles">Principles</a>
        </div>
        <a className="github-button pressure" href="https://github.com/architpai/conn" aria-label="View Conn on GitHub"><GithubIcon /><span>GitHub</span></a>
      </nav>

      <section className="hero" id="top">
        <div className="hero-glow" />
        <div className="hero-copy">
          <p className="hero-kicker enter" style={{ "--delay": "100ms" } as React.CSSProperties}>Codex first · more harnesses later</p>
          <h1 className="enter" style={{ "--delay": "160ms" } as React.CSSProperties}>Leave the work.<br /><em>Keep the conn.</em></h1>
          <p className="hero-sub enter" style={{ "--delay": "280ms" } as React.CSSProperties}>A notch-native Mac companion for supervising AI harness Sessions. Codex is the first built-in Integration in alpha 0.2.</p>
        </div>
        <div className="hero-product enter" style={{ "--delay": "260ms" } as React.CSSProperties}>
          <ProductSurface mode="collapsed" compact />
        </div>
        <a className="primary-cta hero-cta pressure enter" style={{ "--delay": "380ms" } as React.CSSProperties} href="#experience"><span>Meet Conn</span><b>↓</b></a>
      </section>

      <section className="statement" data-reveal>
        <p className="section-index">01 / THE FRICTION</p>
        <p className="statement-lead">The best harnesses can work for a long time.</p>
        <h2>You should not have to watch them do it.</h2>
        <p className="statement-body">Conn turns unused screen space into a calm supervision layer. Leave the harness running, notice only what matters, and return at exactly the right moment.</p>
      </section>

      <section className="experience" id="experience">
        <div className="section-heading" data-reveal>
          <p className="section-index">02 / THE EXPERIENCE</p>
          <h2>From signal<br />to full context.</h2>
          <p>The current alpha UI, rebuilt as an interactive product mock.</p>
        </div>
        <div className="demo-wrap" data-reveal>
          <div className="demo-shell">
            <div className="demo-toolbar">
              <span>Interactive v0.2 surface</span>
              <div className="demo-modes" role="group" aria-label="Conn demo view">
                <button type="button" className={demoMode === "collapsed" ? "active" : ""} aria-pressed={demoMode === "collapsed"} onClick={() => setDemoMode("collapsed")}>Collapsed</button>
                <button type="button" className={demoMode === "session" ? "active" : ""} aria-pressed={demoMode === "session"} onClick={() => setDemoMode("session")}>Session</button>
                <button type="button" className={demoMode === "new-session" ? "active" : ""} aria-pressed={demoMode === "new-session"} onClick={() => setDemoMode("new-session")}>New Session</button>
              </div>
            </div>
            <div className="mac-frame">
              <div className="desktop-menubar"><span>●</span><span>Conn</span><span>File</span><span>Edit</span><time>9:41 AM</time></div>
              <ProductSurface mode={demoMode} onModeChange={setDemoMode} />
            </div>
          </div>
        </div>
      </section>

      <section className="feature-grid">
        <article className="feature" data-reveal>
          <div><span className="feature-number">01</span><h3>Glance, don’t poll.</h3><p>The compact bar counts only the Sessions in your current active and 24-hour view, so every status number means something.</p></div>
          <div className="signal-visual">
            <span className="mini-island"><ConnMark small /><b>CONN</b><span className="mini-live">● Live</span><i>1</i><i>4</i></span>
          </div>
        </article>
        <article className="feature" data-reveal>
          <span className="feature-number">02</span><h3>Know the harness.</h3><p>Every Session carries its harness identity. v0.2 ships Codex through OpenAI’s mark while the Integration boundary stays ready for future adapters.</p>
          <div className="harness-visual"><OpenAIMark /><span><b>Design Conn harness abstraction</b><em>Conn · Codex</em></span></div>
        </article>
        <article className="feature wide" data-reveal>
          <span className="feature-number">03</span><h3>Start with the message.</h3><p>Choose a default Workspace once. New Session opens as a draft, lets you choose model and reasoning together, and creates nothing until you send.</p>
          <div className="draft-visual"><span>GPT-5.6-Sol · Medium</span><em>Message your Harness…</em><b>↑</b></div>
        </article>
      </section>

      <section className="principles" id="principles">
        <div className="principles-copy" data-reveal>
          <p className="section-index">03 / THE PRINCIPLE</p>
          <h2>The harness owns the work.<br />Conn holds the view.</h2>
        </div>
        <div className="principle-list" data-reveal>
          <div><span>01</span><h3>Open source.</h3><p>Inspect it, adapt it, and help shape the next Integration.</p></div>
          <div><span>02</span><h3>Local by default.</h3><p>Your supervision stays on your Mac. Conn adds no analytics or remote account.</p></div>
          <div><span>03</span><h3>Not another harness.</h3><p>Codex owns today’s Sessions and runtime. Future adapters keep that same boundary.</p></div>
        </div>
      </section>

      <section className="closing" data-reveal>
        <div className="closing-orbit"><ConnMark /></div>
        <h2>Give the harness the task.<br /><em>You have the conn.</em></h2>
        <a className="primary-cta pressure" href="https://github.com/architpai/conn"><GithubIcon /><span>View on GitHub</span></a>
      </section>

      <footer><a className="logo" href="#top"><ConnMark small /><span>conn</span></a><p>A native supervision surface for AI harnesses.</p><span>© 2026</span></footer>
    </main>
  );
}
