/**
 * Proof of Claw — Shared Navigation Shell  v2
 * ─────────────────────────────────────────────
 * Single source of truth for sidebar + topbar across every app page.
 * Drop-in: no build step. Just add one script tag:
 *   <script src="nav.js"></script>  (after wallet.js)
 *
 * Auto-detects current page from window.location.pathname.
 * Override by setting  window.POC_PAGE = 'agents'  before this loads.
 */
(function () {
  'use strict';

  // ─── Nav item definitions ───────────────────────────────────────────────────
  const NAV_ITEMS = [
    { id: 'agents',        href: 'agents.html',       icon: '✦',  label: 'Agents'        },
    { id: 'dashboard',     href: 'dashboard.html',    icon: '▣',  label: 'Dashboard'     },
    { id: 'auth-modules',  href: 'auth-modules.html', icon: '🔒', label: 'Auth Modules'  },
    { id: 'messages',      href: 'messages.html',     icon: '✉',  label: 'Messages'      },
    { id: 'proofs',        href: 'proofs.html',       icon: '✱',  label: 'Proofs'        },
    { id: 'kanban',        href: 'kanban.html',       icon: '▪',  label: 'Kanban'        },
    { id: 'soul-vault',    href: 'soul-vault.html',   icon: '⬡',  label: 'Soul Vault'    },
    { id: 'approve',       href: 'approve.html',      icon: '✔',  label: 'Approve'       },
  ];

  // ─── Detect current page ────────────────────────────────────────────────────
  function currentPageId() {
    if (window.POC_PAGE) return window.POC_PAGE;
    const name = window.location.pathname.split('/').pop().replace('.html', '');
    return NAV_ITEMS.some(n => n.id === name) ? name : '';
  }

  // ─── Build canonical sidebar nav ────────────────────────────────────────────
  function buildNav(pageId) {
    const nav = document.createElement('nav');
    nav.className = 'sidebar-nav';
    nav.setAttribute('aria-label', 'App navigation');
    NAV_ITEMS.forEach(item => {
      const a = document.createElement('a');
      a.href = item.href;
      if (item.id === pageId) {
        a.className = 'active';
        a.setAttribute('aria-current', 'page');
      }
      a.innerHTML = `<span class="nav-icon">${item.icon}</span> ${item.label}`;
      nav.appendChild(a);
    });
    return nav;
  }

  // ─── Build canonical sidebar-bottom ─────────────────────────────────────────
  function buildBottom(pageId) {
    const div = document.createElement('div');
    div.className = 'sidebar-bottom';
    div.innerHTML = `
      <div id="poc-connection-slot"></div>
      <a href="${pageId === 'agents' ? '#' : 'agents.html'}"
         id="sidebar-new-agent-btn"
         class="btn-new-agent">+ New Agent</a>
      <a href="index.html" class="btn-home">&#x2190; Back to Home</a>
    `.trim();
    return div;
  }

  // ─── Build topbar wallet widget ─────────────────────────────────────────────
  // Returns an HTML string ready to inject into .topbar-right
  function walletHTML() {
    return `
      <button id="wallet-connect-btn"
        style="background:transparent;border:1px solid var(--border-cyan);color:var(--cyan);padding:5px 14px;border-radius:6px;font-family:var(--font-mono);font-size:12px;font-weight:600;letter-spacing:0.04em;cursor:pointer;transition:all 0.2s;white-space:nowrap;"
        onclick="connectWalletUI()"
        aria-label="Connect wallet">
        Connect Wallet
      </button>
      <div id="wallet-display" style="display:none;align-items:center;gap:8px;">
        <span id="wallet-address"
          style="font-family:var(--font-mono);font-size:12px;color:var(--cyan);"></span>
        <span class="status-dot online" style="display:inline-block;" aria-hidden="true"></span>
      </div>
    `.trim();
  }

  // ─── Inject sidebar ──────────────────────────────────────────────────────────
  function injectSidebar(pageId) {
    const sidebar = document.querySelector('aside.sidebar, .sidebar');
    if (!sidebar) return;

    // Replace nav
    const oldNav = sidebar.querySelector('.sidebar-nav');
    const newNav = buildNav(pageId);
    if (oldNav) {
      oldNav.replaceWith(newNav);
    } else {
      const logo = sidebar.querySelector('.sidebar-logo');
      logo ? logo.after(newNav) : sidebar.prepend(newNav);
    }

    // Replace bottom
    const oldBottom = sidebar.querySelector('.sidebar-bottom');
    const newBottom = buildBottom(pageId);
    if (oldBottom) {
      oldBottom.replaceWith(newBottom);
    } else {
      sidebar.appendChild(newBottom);
    }

    // Wire up "New Agent" on agents page to the wizard
    if (pageId === 'agents') {
      const btn = document.getElementById('sidebar-new-agent-btn');
      if (btn) {
        btn.onclick = (e) => {
          e.preventDefault();
          if (typeof openWizard === 'function') openWizard();
        };
      }
    }

    // Re-render PocAPI connection badge if already loaded
    const slot = document.getElementById('poc-connection-slot');
    if (slot && typeof PocAPI !== 'undefined' && PocAPI.renderConnectionBadge) {
      PocAPI.renderConnectionBadge(slot);
    }
  }

  // ─── Inject/standardize topbar wallet ───────────────────────────────────────
  function injectTopbarWallet(pageId) {
    // Approve has its own Ledger-specific topbar-right — skip wallet injection
    if (pageId === 'approve') return;

    // Messages has no topbar-right at all — create one and append to header
    let topbarRight = document.querySelector('.topbar-right, .top-bar-right');
    if (!topbarRight) {
      const header = document.querySelector('header.topbar, header.top-bar');
      if (!header) return;
      topbarRight = document.createElement('div');
      topbarRight.className = 'topbar-right';
      header.appendChild(topbarRight);
    }

    // Already has a wallet widget — just standardize styling
    const existingBtn = topbarRight.querySelector('#wallet-connect-btn');
    if (existingBtn) {
      // Normalize button appearance
      existingBtn.style.background    = 'transparent';
      existingBtn.style.border        = '1px solid var(--border-cyan)';
      existingBtn.style.color         = 'var(--cyan)';
      existingBtn.style.padding       = '5px 14px';
      existingBtn.style.borderRadius  = '6px';
      existingBtn.style.fontFamily    = 'var(--font-mono)';
      existingBtn.style.fontSize      = '12px';
      existingBtn.style.fontWeight    = '600';
      existingBtn.style.letterSpacing = '0.04em';
      existingBtn.style.cursor        = 'pointer';
      existingBtn.style.whiteSpace    = 'nowrap';
      existingBtn.style.transition    = 'all 0.2s';
      existingBtn.removeAttribute('class'); // strip stale .eth-badge / .btn-wizard classes

      // Fix address text color
      const addr = topbarRight.querySelector('#wallet-address');
      if (addr) addr.style.color = 'var(--cyan)';

      // Ensure status dot
      const display = topbarRight.querySelector('#wallet-display');
      if (display && !display.querySelector('.status-dot')) {
        const dot = document.createElement('span');
        dot.className = 'status-dot online';
        dot.style.display = 'inline-block';
        dot.setAttribute('aria-hidden', 'true');
        display.appendChild(dot);
      }
      return;
    }

    // Inject fresh wallet widget
    topbarRight.insertAdjacentHTML('beforeend', walletHTML());
  }

  // ─── Main ────────────────────────────────────────────────────────────────────
  function run() {
    const pageId = currentPageId();
    injectSidebar(pageId);
    injectTopbarWallet(pageId);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', run);
  } else {
    run();
  }
})();
