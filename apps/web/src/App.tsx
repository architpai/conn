"use client";

import { useEffect, useRef, useState } from "react";
import "./globals.css";
import { demoDocument } from "./demoDocument";

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

function ProductSurface({ compact = false }: { compact?: boolean }) {
  const [view, setView] = useState<"glance" | "workspace" | "approval">(compact ? "glance" : "workspace");
  const expanded = view === "workspace";
  const approval = view === "approval";

  return (
    <div className={`product-stage ${expanded ? "is-expanded" : "is-collapsed"} ${approval ? "is-approval" : ""}`}>
      <button
        className="notch-bar"
        type="button"
        onClick={() => setView((value) => value === "workspace" ? "glance" : "workspace")}
        aria-expanded={expanded}
        aria-label={expanded ? "Collapse Conn demo" : "Expand Conn demo"}
      >
        <span className="notch-wing brand-wing"><ConnMark small /><b>conn</b></span>
        <span className="camera" />
        <span className="notch-wing status-wing">
          <i className="status-dot running" /><i className="status-dot waiting" /><i className="status-dot failed" />
        </span>
      </button>

      <div className="activity-shelf" aria-hidden={expanded}>
        <span className="wave"><i /><i /><i /><i /><i /></span>
        <span className="activity-copy"><b>{approval ? "Approval needed" : "Reading"}</b><span>{approval ? "Run release checks" : "AppServerAdapter.swift"}</span></span>
        {approval ? (
          <span className="activity-actions"><button type="button">Reject</button><button type="button" className="accept">Accept</button></span>
        ) : <span className="progress-ring" />}
      </div>

      <div className="workspace-demo" aria-hidden={!expanded}>
        <div className="demo-head">
          <span className="thread-name"><i className="status-dot running" /> conn / launch</span>
          <span className="live-label">LIVE</span>
        </div>
        <div className="demo-body">
          <div className="timeline">
            <span className="timeline-label">CODEX</span>
            <p>I’ve finished the landing page structure and I’m running the responsive checks now.</p>
            <div className="tool-row"><span>⌁</span><b>Building production bundle</b><em>running</em></div>
          </div>
          <div className="composer-demo"><span>Steer this thread</span><b>↑</b></div>
        </div>
      </div>

      <div className="demo-controls" role="group" aria-label="Demo state">
        <button type="button" className={view === "glance" ? "active" : ""} onClick={() => setView("glance")}>Glance</button>
        <button type="button" className={view === "workspace" ? "active" : ""} onClick={() => setView("workspace")}>Workspace</button>
        <button type="button" className={view === "approval" ? "active" : ""} onClick={() => setView("approval")}>Approval</button>
      </div>
    </div>
  );
}

export default function Home() {
  const mockFrameRef = useRef<HTMLIFrameElement>(null);
  const [demoMode, setDemoMode] = useState<"collapsed" | "expanded" | "approval">("collapsed");

  const changeDemoMode = (mode: "collapsed" | "expanded" | "approval") => {
    setDemoMode(mode);
    mockFrameRef.current?.contentWindow?.postMessage({ source: "conn-landing", mode }, "*");
  };

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
          <h1 className="enter" style={{ "--delay": "160ms" } as React.CSSProperties}>Leave the work.<br /><em>Keep the conn.</em></h1>
          <p className="hero-sub enter" style={{ "--delay": "280ms" } as React.CSSProperties}>A notch-native Mac companion that keeps your Codex threads visible, actionable, and out of your way.</p>
        </div>
        <div className="hero-product enter" style={{ "--delay": "260ms" } as React.CSSProperties}>
          <ProductSurface compact />
        </div>
        <a className="primary-cta hero-cta pressure enter" style={{ "--delay": "380ms" } as React.CSSProperties} href="#experience"><span>Meet Conn</span><b>↓</b></a>
      </section>

      <section className="statement" data-reveal>
        <p className="section-index">01 / THE FRICTION</p>
        <p className="statement-lead">The best agents can work for a long time.</p>
        <h2>You should not have to watch them do it.</h2>
        <p className="statement-body">Conn turns unused screen space into a calm supervision layer. Leave Codex running, notice only what matters, and return at exactly the right moment.</p>
      </section>

      <section className="experience" id="experience">
        <div className="section-heading" data-reveal>
          <p className="section-index">02 / THE EXPERIENCE</p>
          <h2>From signal<br />to full context.</h2>
          <p>Try a representative interactive demo of the native experience.</p>
        </div>
        <div className="demo-wrap" data-reveal>
          <div className="demo-shell">
            <div className="demo-toolbar">
              <span>Interactive native surface</span>
              <div className="demo-modes" role="group" aria-label="Conn demo view">
                <button type="button" className={demoMode === "collapsed" ? "active" : ""} aria-pressed={demoMode === "collapsed"} onClick={() => changeDemoMode("collapsed")}>Glance</button>
                <button type="button" className={demoMode === "expanded" ? "active" : ""} aria-pressed={demoMode === "expanded"} onClick={() => changeDemoMode("expanded")}>Workspace</button>
                <button type="button" className={demoMode === "approval" ? "active" : ""} aria-pressed={demoMode === "approval"} onClick={() => changeDemoMode("approval")}>Approval</button>
              </div>
            </div>
            <div className="mac-frame">
              <iframe ref={mockFrameRef} className="mock-embed" srcDoc={demoDocument} title="Interactive Conn product demo" onLoad={() => changeDemoMode(demoMode)} />
            </div>
          </div>
        </div>
      </section>

      <section className="feature-grid">
        <article className="feature" data-reveal>
          <div><span className="feature-number">01</span><h3>Glance, don’t poll.</h3><p>Running, waiting, failed, done. The notch keeps the important state at the edge of your vision.</p></div>
          <div className="signal-visual"><span className="mini-island"><ConnMark small /><i /><i /><i /></span></div>
        </article>
        <article className="feature" data-reveal>
          <span className="feature-number">02</span><h3>Act in place.</h3><p>Approve a safe request, answer a question, or send a quick steer without reopening your entire work context.</p>
          <div className="mini-approval">
            <div className="mini-approval-bar"><span><ConnMark small /><b>conn</b></span><i className="status-dot waiting" /></div>
            <div className="mini-approval-shelf"><span><small>APPROVAL NEEDED</small><b>Run verification?</b></span><div><button type="button">Reject</button><button type="button">Accept</button></div></div>
          </div>
        </article>
      </section>

      <section className="principles" id="principles">
        <div className="principles-copy" data-reveal>
          <p className="section-index">03 / THE PRINCIPLE</p>
          <h2>Codex owns the work.<br />Conn holds the view.</h2>
        </div>
        <div className="principle-list" data-reveal>
          <div><span>01</span><h3>Open source.</h3><p>Inspect it, adapt it, and help shape what Conn becomes.</p></div>
          <div><span>02</span><h3>No telemetry.</h3><p>Your supervision stays local. Conn does not report how you work.</p></div>
          <div><span>03</span><h3>Not another harness.</h3><p>Codex owns the threads and runtime. Conn stays a focused companion.</p></div>
        </div>
      </section>

      <section className="closing" data-reveal>
        <div className="closing-orbit"><ConnMark /></div>
        <h2>Give Codex the task.<br /><em>You have the conn.</em></h2>
        <a className="primary-cta pressure" href="https://github.com/architpai/conn"><GithubIcon /><span>View on GitHub</span></a>
      </section>

      <footer><a className="logo" href="#top"><ConnMark small /><span>conn</span></a><p>A native supervision surface for Codex.</p><span>© 2026</span></footer>
    </main>
  );
}
