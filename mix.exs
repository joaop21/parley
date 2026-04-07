defmodule Parley.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/joaop21/parley"

  def project do
    [
      app: :parley,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: dialyzer(),
      name: "Parley",
      description: "A WebSocket client built on gen_statem and Mint.",
      source_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Parley.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  end

  defp package do
    [
      maintainers: ["João Silva"],
      licenses: ["MIT"],
      links: %{"Repository" => @source_url, "Documentation" => "https://hexdocs.pm/parley"},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "Parley",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "LICENSE"],
      groups_for_docs: [
        Connection: &(&1[:kind] == :function),
        Callbacks: &(&1[:kind] == :callback)
      ],
      before_closing_body_tag: &before_closing_body_tag/1
    ]
  end

  defp before_closing_body_tag(:html) do
    """
    <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
    <script>
      document.addEventListener("DOMContentLoaded", function () {
        mermaid.initialize({
          startOnLoad: false,
          theme: document.body.className.includes("dark") ? "dark" : "default"
        });
        let id = 0;
        for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
          const preEl = codeEl.parentElement;
          const graphDefinition = codeEl.textContent;
          const graphEl = document.createElement("div");
          const graphId = "mermaid-graph-" + id++;
          mermaid.render(graphId, graphDefinition).then(({svg, bindFunctions}) => {
            graphEl.innerHTML = svg;
            bindFunctions?.(graphEl);
            preEl.insertAdjacentElement("afterend", graphEl);
            preEl.remove();
          });
        }
      });
    </script>
    #{parley_demo_script()}
    """
  end

  defp before_closing_body_tag(_), do: ""

  defp parley_demo_script do
    """
    <script>
    (function() {
      const root = document.getElementById("parley-demo");
      if (!root) return;

      // ── Styles ──
      const style = document.createElement("style");
      style.textContent = `
        #parley-demo {
          margin: 1.5rem 0;
          padding: 1.5rem;
          border: 1px solid var(--borderColor, #30363d);
          border-radius: 8px;
          background: var(--bgColor, #f6f8fa);
          font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, monospace;
        }
        .dark #parley-demo { background: #161b22; }

        #parley-demo svg { display: block; max-width: 100%; }

        #parley-demo .pd-layout {
          display: flex;
          flex-direction: column;
          gap: 0.8rem;
          margin: 0.8rem 0;
        }
        #parley-demo .pd-controls {
          display: grid;
          grid-template-columns: 1fr 1fr;
          gap: 0.8rem;
        }
        #parley-demo .pd-group { text-align: center; }
        #parley-demo .pd-group-label {
          font-size: 0.65rem; text-transform: uppercase;
          letter-spacing: 0.08em; margin-bottom: 0.3rem;
          color: var(--textNote, #656d76);
        }
        .dark #parley-demo .pd-group-label { color: #8b949e; }
        #parley-demo .pd-buttons { display: flex; flex-direction: column; gap: 0.25rem; }
        #parley-demo button {
          background: var(--bgSecondary, #e8eaed);
          border: 1px solid var(--borderColor, #d0d7de);
          color: var(--textBody, #24292f);
          padding: 0.25rem 0.55rem; border-radius: 5px;
          cursor: pointer; font-size: 0.72rem; font-family: inherit;
          transition: background 0.15s, border-color 0.15s;
        }
        .dark #parley-demo button {
          background: #21262d; border-color: #30363d; color: #c9d1d9;
        }
        #parley-demo button:hover:not(:disabled) {
          border-color: #58a6ff;
        }
        #parley-demo button:disabled { opacity: 0.35; cursor: not-allowed; }
        #parley-demo button.pd-danger { border-color: #f85149; }

        #parley-demo .pd-toggle {
          display: inline-flex; align-items: center; gap: 0.35rem;
          font-size: 0.72rem; cursor: pointer;
          color: var(--textBody, #24292f);
          user-select: none;
        }
        .dark #parley-demo .pd-toggle { color: #c9d1d9; }
        #parley-demo .pd-toggle input { cursor: pointer; }

        #parley-demo .pd-log-header {
          display: flex; justify-content: space-between; align-items: center;
          margin-bottom: 0.3rem;
        }
        #parley-demo .pd-log-title {
          font-size: 0.65rem; text-transform: uppercase;
          letter-spacing: 0.08em;
          color: var(--textNote, #656d76);
        }
        .dark #parley-demo .pd-log-title { color: #8b949e; }
        #parley-demo .pd-clear-btn {
          background: none; border: none; color: var(--textNote, #656d76);
          font-size: 0.65rem; cursor: pointer; padding: 0 0.3rem;
          text-transform: uppercase; letter-spacing: 0.05em;
        }
        .dark #parley-demo .pd-clear-btn { color: #8b949e; }
        #parley-demo .pd-clear-btn:hover { color: #f85149; }

        #parley-demo .pd-log {
          max-height: 140px; overflow-y: auto;
          background: var(--bgSecondary, #e8eaed);
          border: 1px solid var(--borderColor, #d0d7de);
          border-radius: 6px; padding: 0.4rem 0.6rem;
          font-size: 0.7rem; line-height: 1.6;
        }
        .dark #parley-demo .pd-log {
          background: #0d1117; border-color: #30363d;
        }
        #parley-demo .pd-log .cb { color: #8250df; font-weight: 600; }
        #parley-demo .pd-log .arrow { color: #656d76; }
        #parley-demo .pd-log .val { color: #0969da; }
        #parley-demo .pd-log .note { color: #656d76; font-style: italic; }
        #parley-demo .pd-log .auto { color: #1a7f37; }
        .dark #parley-demo .pd-log .cb { color: #d2a8ff; }
        .dark #parley-demo .pd-log .arrow { color: #8b949e; }
        .dark #parley-demo .pd-log .val { color: #a5d6ff; }
        .dark #parley-demo .pd-log .note { color: #8b949e; }
        .dark #parley-demo .pd-log .auto { color: #7ee787; }
        #parley-demo .pd-log-entry { opacity: 0; animation: pdFadeIn 0.3s forwards; }
        @keyframes pdFadeIn { to { opacity: 1; } }

        #parley-demo .pd-legend {
          display: flex; gap: 0.8rem; justify-content: center;
          flex-wrap: wrap; margin-top: 0.3rem;
        }
        #parley-demo .pd-legend-item {
          display: flex; align-items: center; gap: 0.25rem;
          font-size: 0.6rem; color: var(--textNote, #656d76);
        }
        .dark #parley-demo .pd-legend-item { color: #8b949e; }
        #parley-demo .pd-legend-swatch {
          display: inline-block; width: 10px; height: 10px;
          border-radius: 2px; border: 1px solid;
        }

        @keyframes pdPulse {
          0% { opacity: 0; }
          30% { opacity: 0.25; }
          100% { opacity: 0; }
        }
      `;
      document.head.appendChild(style);

      // ── Build DOM ──
      root.innerHTML = `
        <div class="pd-layout">
          <svg id="pd-svg" viewBox="0 0 500 220" xmlns="http://www.w3.org/2000/svg">
            <rect x="10" y="70" width="90" height="55" rx="8" fill="none" stroke="#58a6ff" stroke-width="1.5"/>
            <text x="55" y="95" text-anchor="middle" fill="#58a6ff" font-size="11" font-weight="600">Client</text>
            <text x="55" y="110" text-anchor="middle" fill="#8b949e" font-size="8">use Parley</text>

            <rect x="400" y="70" width="90" height="55" rx="8" fill="none" stroke="#7ee787" stroke-width="1.5"/>
            <text x="445" y="95" text-anchor="middle" fill="#7ee787" font-size="11" font-weight="600">Server</text>
            <text x="445" y="110" text-anchor="middle" fill="#8b949e" font-size="8">WebSocket</text>

            <line id="pd-pipe-top" x1="100" y1="88" x2="400" y2="88" stroke="#30363d" stroke-width="1.5" stroke-dasharray="5,3"/>
            <line id="pd-pipe-bot" x1="100" y1="108" x2="400" y2="108" stroke="#30363d" stroke-width="1.5" stroke-dasharray="5,3"/>
            <rect id="pd-pipe-fill" x="100" y="88" width="300" height="20" rx="2" fill="#58a6ff" opacity="0"/>

            <g transform="translate(250, 20)">
              <text text-anchor="middle" fill="#8b949e" font-size="9" y="-4">state</text>
              <rect id="pd-sm-box" x="-50" y="0" width="100" height="24" rx="5" fill="none" stroke="#30363d" stroke-width="1.2"/>
              <rect id="pd-sm-fill" x="-50" y="0" width="100" height="24" rx="5" fill="#30363d" opacity="0"/>
              <text id="pd-sm-text" x="0" y="16" text-anchor="middle" fill="#8b949e" font-size="10" font-weight="600">disconnected</text>
            </g>

            <g transform="translate(250, 185)">
              <text text-anchor="middle" fill="#8b949e" font-size="9" y="-4">callback</text>
              <rect id="pd-cb-bg" x="-70" y="0" width="140" height="24" rx="5" fill="none" stroke="#30363d" stroke-width="1.2"/>
              <rect id="pd-cb-flash" x="-70" y="0" width="140" height="24" rx="5" fill="#d2a8ff" opacity="0"/>
              <text id="pd-cb-text" x="0" y="16" text-anchor="middle" fill="#8b949e" font-size="10" font-weight="600">—</text>
            </g>

            <!-- Reconnect countdown in SVG -->
            <text id="pd-reconn-text" x="250" y="165" text-anchor="middle" fill="#d29922" font-size="8" opacity="0"></text>

            <!-- Queue label -->
            <text id="pd-queue-label" x="100" y="158" fill="#d29922" font-size="7" opacity="0">queued</text>

            <g id="pd-queue-group"></g>
            <g id="pd-frames-group"></g>
          </svg>
          <div class="pd-legend">
            <span class="pd-legend-item"><span class="pd-legend-swatch" style="background:#58a6ff22;border-color:#58a6ff"></span> text</span>
            <span class="pd-legend-item"><span class="pd-legend-swatch" style="background:#d2a8ff22;border-color:#d2a8ff"></span> binary</span>
            <span class="pd-legend-item"><span class="pd-legend-swatch" style="background:#7ee78722;border-color:#7ee787"></span> ping/pong</span>
            <span class="pd-legend-item"><span class="pd-legend-swatch" style="background:#f8514922;border-color:#f85149"></span> close/error</span>
          </div>
          <div class="pd-controls">
            <div class="pd-group">
              <div class="pd-group-label">Client</div>
              <div class="pd-buttons">
                <button id="pd-btn-connect">start_link</button>
                <button id="pd-btn-send-text" disabled>send_frame(:text)</button>
                <button id="pd-btn-send-bin" disabled>send_frame(:binary)</button>
                <button id="pd-btn-send-info" disabled>send process msg</button>
                <button id="pd-btn-disconnect" disabled class="pd-danger">disconnect</button>
              </div>
            </div>
            <div class="pd-group">
              <div class="pd-group-label">Server</div>
              <div class="pd-buttons">
                <button id="pd-btn-srv-text" disabled>send text</button>
                <button id="pd-btn-srv-bin" disabled>send binary</button>
                <button id="pd-btn-srv-ping" disabled>send ping</button>
                <button id="pd-btn-srv-close" disabled class="pd-danger">close</button>
                <button id="pd-btn-net-err" disabled class="pd-danger">network error</button>
              </div>
            </div>
          </div>
        </div>
        <div style="text-align:center; margin-bottom:0.4rem;">
          <label class="pd-toggle"><input type="checkbox" id="pd-reconnect-toggle"> reconnect: true</label>
        </div>
        <div class="pd-log-header">
          <span class="pd-log-title">Event log</span>
          <button class="pd-clear-btn" id="pd-clear-log">clear</button>
        </div>
        <div class="pd-log" id="pd-log">
          <div class="pd-log-entry"><span class="note">Click "start_link" to begin…</span></div>
        </div>
      `;

      // ── Refs ──
      const el = id => document.getElementById(id);
      const PIPE_L = 110, PIPE_R = 390, PY_T = 93, PY_B = 103, SPEED = 180;
      let state = "disconnected", queue = [], frames = [], aId = 0;

      // ── Reconnect state ──
      const BASE_DELAY = 1000, MAX_DELAY = 8000;
      let reconnectAttempt = 0, reconnectTimer = null, countdownTimer = null;

      // ── State colors ──
      const stateColors = { connected: "#7ee787", connecting: "#d29922", disconnected: "#f85149" };

      function setState(s) {
        state = s;
        const c = stateColors[s];
        el("pd-sm-text").textContent = s;
        el("pd-sm-text").setAttribute("fill", c);
        el("pd-sm-box").setAttribute("stroke", c);
        el("pd-sm-fill").setAttribute("fill", c);
        // pulse the state box fill
        el("pd-sm-fill").setAttribute("opacity", "0.25");
        el("pd-sm-fill").animate([{opacity: 0.25}, {opacity: 0}], {duration: 600, fill: "forwards"});

        // pipe appearance
        if (s === "connected") {
          el("pd-pipe-fill").setAttribute("opacity", "0.12");
          el("pd-pipe-top").setAttribute("stroke", "#58a6ff");
          el("pd-pipe-top").removeAttribute("stroke-dasharray");
          el("pd-pipe-bot").setAttribute("stroke", "#58a6ff");
          el("pd-pipe-bot").removeAttribute("stroke-dasharray");
        } else {
          el("pd-pipe-fill").setAttribute("opacity", "0");
          el("pd-pipe-top").setAttribute("stroke", "#30363d");
          el("pd-pipe-top").setAttribute("stroke-dasharray", "5,3");
          el("pd-pipe-bot").setAttribute("stroke", "#30363d");
          el("pd-pipe-bot").setAttribute("stroke-dasharray", "5,3");
        }
        updBtns();
      }

      function updBtns() {
        const d = state === "disconnected", c = state === "connected", i = state === "connecting";
        el("pd-btn-connect").disabled = !d || reconnectTimer !== null;
        el("pd-btn-send-text").disabled = !(c || i);
        el("pd-btn-send-bin").disabled = !(c || i);
        el("pd-btn-send-info").disabled = d;
        el("pd-btn-disconnect").disabled = d;
        el("pd-btn-srv-text").disabled = !c;
        el("pd-btn-srv-bin").disabled = !c;
        el("pd-btn-srv-ping").disabled = !c;
        el("pd-btn-srv-close").disabled = !c;
        el("pd-btn-net-err").disabled = !(c || i);
      }

      function log(h) {
        const p = el("pd-log"), d = document.createElement("div");
        d.className = "pd-log-entry"; d.innerHTML = h;
        p.appendChild(d); p.scrollTop = p.scrollHeight;
      }

      // ── Clear log ──
      el("pd-clear-log").onclick = function() {
        el("pd-log").innerHTML = "";
      };

      function mkFrame(type) {
        const ns = "http://www.w3.org/2000/svg";
        const g = document.createElementNS(ns, "g");
        const colors = { text:"#58a6ff", binary:"#d2a8ff", ping:"#7ee787", pong:"#7ee787", close:"#f85149", error:"#f85149", info:"#d29922" };
        const labels = { text:"T", binary:"B", ping:"⟳", pong:"⟲", close:"✕", error:"⚡", info:"i" };
        const c = colors[type] || "#8b949e";
        const r = document.createElementNS(ns, "rect");
        r.setAttribute("x",-11); r.setAttribute("y",-8); r.setAttribute("width",22); r.setAttribute("height",16);
        r.setAttribute("rx",3); r.setAttribute("fill",c+"22"); r.setAttribute("stroke",c); r.setAttribute("stroke-width","1.2");
        g.appendChild(r);
        const t = document.createElementNS(ns, "text");
        t.setAttribute("text-anchor","middle"); t.setAttribute("y","4"); t.setAttribute("fill",c);
        t.setAttribute("font-size","9"); t.setAttribute("font-weight","600"); t.textContent = labels[type]||"?";
        g.appendChild(t);
        el("pd-frames-group").appendChild(g);
        return g;
      }

      function animFrame(type, dir, cb) {
        const toR = dir === "right";
        const sx = toR ? PIPE_L : PIPE_R, ex = toR ? PIPE_R : PIPE_L;
        const y = toR ? PY_T : PY_B;
        const f = mkFrame(type), st = performance.now();
        const dur = (Math.abs(ex - sx) / SPEED) * 1000;
        const id = ++aId, entry = {id, el: f};
        frames.push(entry);
        function tick(now) {
          const t = Math.min((now - st) / dur, 1);
          f.setAttribute("transform", "translate(" + (sx + (ex - sx) * t) + "," + y + ")");
          if (t < 1) requestAnimationFrame(tick);
          else { f.remove(); frames = frames.filter(x => x.id !== id); if (cb) cb(); }
        }
        requestAnimationFrame(tick);
      }

      function renderQ() {
        const g = el("pd-queue-group"); g.innerHTML = "";
        const ql = el("pd-queue-label");
        if (!queue.length) { ql.setAttribute("opacity", "0"); return; }
        ql.setAttribute("opacity", "1");
        const ns = "http://www.w3.org/2000/svg";
        queue.forEach((q, i) => {
          const r = document.createElementNS(ns, "rect");
          const x = 105 + i * 20;
          r.setAttribute("x",x); r.setAttribute("y",140); r.setAttribute("width",16); r.setAttribute("height",12);
          r.setAttribute("rx",2); r.setAttribute("fill", q==="text"?"#58a6ff22":"#d2a8ff22");
          r.setAttribute("stroke", q==="text"?"#58a6ff":"#d2a8ff"); r.setAttribute("stroke-width","1");
          g.appendChild(r);
          const t = document.createElementNS(ns, "text");
          t.setAttribute("x",x+8); t.setAttribute("y",150); t.setAttribute("text-anchor","middle");
          t.setAttribute("fill", q==="text"?"#58a6ff":"#d2a8ff"); t.setAttribute("font-size","7"); t.textContent = q==="text"?"T":"B";
          g.appendChild(t);
        });
      }

      function drainQ() {
        if (!queue.length) return;
        log('<span class="auto">↳ draining queued frames…</span>');
        let d = 0;
        queue.forEach(type => {
          setTimeout(() => {
            animFrame(type, "right");
            log('<span class="arrow">→</span> <span class="val">:' + type + '</span> <span class="note">(from queue)</span>');
          }, d);
          d += 300;
        });
        queue = []; renderQ();
      }

      function flashCb(name) {
        const t = el("pd-cb-text");
        t.textContent = name;
        t.setAttribute("fill", "#d2a8ff");
        // pulse the callback box
        const fl = el("pd-cb-flash");
        fl.setAttribute("opacity", "0.3");
        fl.animate([{opacity: 0.3}, {opacity: 0}], {duration: 800, fill: "forwards"});
      }

      function clearAll() {
        queue = []; renderQ();
        frames.forEach(f => f.el.remove()); frames = [];
      }

      function cancelReconnect() {
        if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
        if (countdownTimer) { clearInterval(countdownTimer); countdownTimer = null; }
        el("pd-reconn-text").setAttribute("opacity", "0");
        updBtns();
      }

      function scheduleReconnect() {
        if (!el("pd-reconnect-toggle").checked) return;
        const delay = Math.min(BASE_DELAY * Math.pow(2, reconnectAttempt), MAX_DELAY);
        reconnectAttempt++;
        const rt = el("pd-reconn-text");
        let remaining = delay;
        rt.setAttribute("opacity", "1");
        rt.textContent = "reconnecting in " + remaining + "ms (attempt " + reconnectAttempt + ")";
        countdownTimer = setInterval(() => {
          remaining = Math.max(0, remaining - 100);
          rt.textContent = "reconnecting in " + remaining + "ms (attempt " + reconnectAttempt + ")";
        }, 100);
        log('<span class="note">↳ reconnect scheduled in ' + delay + 'ms (attempt ' + reconnectAttempt + ', backoff: ' + delay + 'ms)</span>');
        updBtns();
        reconnectTimer = setTimeout(() => {
          clearInterval(countdownTimer); countdownTimer = null;
          rt.setAttribute("opacity", "0");
          reconnectTimer = null;
          doAutoReconnect();
        }, delay);
      }

      function doAutoReconnect() {
        if (state !== "disconnected") return;
        setState("connecting");
        log('<span class="note">↳ reconnecting… TCP connect + WS upgrade</span>');
        setTimeout(() => {
          if (state !== "connecting") return;
          reconnectAttempt = 0;
          setState("connected");
          flashCb("handle_connect/1");
          log('<span class="cb">handle_connect/1</span> <span class="arrow">→</span> <span class="val">{:ok, state}</span>');
          setTimeout(() => drainQ(), 200);
        }, 1500);
      }

      // ── Button handlers ──
      el("pd-btn-connect").onclick = function() {
        if (state !== "disconnected") return;
        cancelReconnect();
        reconnectAttempt = 0;
        setState("connecting");
        log('<span class="cb">start_link/3</span> <span class="arrow">→</span> <span class="note">TCP connect + WS upgrade…</span>');
        setTimeout(() => {
          if (state !== "connecting") return;
          setState("connected");
          flashCb("handle_connect/1");
          log('<span class="cb">handle_connect/1</span> <span class="arrow">→</span> <span class="val">{:ok, state}</span>');
          setTimeout(() => drainQ(), 200);
        }, 1500);
      };

      el("pd-btn-send-text").onclick = function() { doSend("text"); };
      el("pd-btn-send-bin").onclick = function() { doSend("binary"); };

      function doSend(type) {
        if (state === "connecting") {
          queue.push(type); renderQ();
          log('<span class="arrow">→</span> send_frame(<span class="val">:' + type + '</span>) <span class="note">— queued (connecting)</span>');
          return;
        }
        if (state !== "connected") return;
        animFrame(type, "right");
        log('<span class="arrow">→</span> send_frame(<span class="val">:' + type + '</span>)');
      }

      // ── handle_info: works in all states ──
      el("pd-btn-send-info").onclick = function() {
        if (state === "disconnected") return;
        flashCb("handle_info/2");
        log('<span class="cb">handle_info/2</span>(<span class="val">:my_message</span>) <span class="arrow">→</span> <span class="val">{:ok, state}</span> <span class="note">— works in all states</span>');
      };

      el("pd-btn-disconnect").onclick = function() {
        if (state === "disconnected") return;
        cancelReconnect();
        reconnectAttempt = 0;
        clearAll();
        animFrame("close", "right", () => {
          setState("disconnected");
          flashCb("handle_disconnect/2");
          log('<span class="cb">handle_disconnect/2</span> <span class="arrow">→</span> <span class="val">{:ok, state}</span>');
        });
        log('<span class="cb">disconnect/1</span> <span class="arrow">→</span> <span class="note">closing…</span>');
      };

      el("pd-btn-srv-text").onclick = function() { doSrv("text"); };
      el("pd-btn-srv-bin").onclick = function() { doSrv("binary"); };

      function doSrv(type) {
        if (state !== "connected") return;
        animFrame(type, "left", () => {
          flashCb("handle_frame/2");
          log('<span class="cb">handle_frame/2</span>(<span class="val">{:' + type + ', data}</span>) <span class="arrow">→</span> <span class="val">{:ok, state}</span>');
        });
        log('<span class="arrow">←</span> server sends <span class="val">:' + type + '</span> frame');
      }

      el("pd-btn-srv-ping").onclick = function() {
        if (state !== "connected") return;
        animFrame("ping", "left", () => {
          log('<span class="auto">↳ auto-pong sent</span>');
          animFrame("pong", "right");
          setTimeout(() => {
            flashCb("handle_ping/2");
            log('<span class="cb">handle_ping/2</span>(<span class="val">payload</span>) <span class="arrow">→</span> <span class="val">{:ok, state}</span>');
          }, 200);
        });
        log('<span class="arrow">←</span> server sends <span class="val">ping</span>');
      };

      el("pd-btn-srv-close").onclick = function() {
        if (state !== "connected") return;
        animFrame("close", "left", () => {
          setState("disconnected");
          flashCb("handle_disconnect/2");
          log('<span class="cb">handle_disconnect/2</span>(<span class="val">:closed</span>) <span class="arrow">→</span> <span class="val">{:ok, state}</span>');
          scheduleReconnect();
        });
        log('<span class="arrow">←</span> server sends <span class="val">close</span>');
      };

      el("pd-btn-net-err").onclick = function() {
        if (state === "disconnected") return;
        clearAll();
        setState("disconnected");
        flashCb("handle_disconnect/2");
        log('<span style="color:#f85149">⚡ network error</span>');
        log('<span class="cb">handle_disconnect/2</span>(<span class="val">:error</span>) <span class="arrow">→</span> <span class="val">{:ok, state}</span>');
        scheduleReconnect();
      };
    })();
    </script>
    """
  end

  defp aliases do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "dialyzer",
        "test"
      ]
    ]
  end

  defp deps do
    [
      {:mint_web_socket, "~> 1.0"},
      {:castore, "~> 1.0"},
      {:bandit, "~> 1.0", only: :test},
      {:websock_adapter, "~> 0.5", only: :test},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
