// ARC Field Tools — App Shell
// Tab routing + shared utilities

const App = {
  currentTab: 'color-temp',

  init() {
    this.bindTabs();
    this.registerSW();
    this.monitorOnline();

    // Initialize all tools
    if (typeof ColorTemp !== 'undefined') ColorTemp.init();
    if (typeof CableRef !== 'undefined') CableRef.init();
    if (typeof PowerCalc !== 'undefined') PowerCalc.init();
    if (typeof RFCoordinator !== 'undefined') RFCoordinator.init();

    // Restore last tab from URL hash or localStorage
    const hash = window.location.hash.slice(1);
    if (hash && document.getElementById('panel-' + hash)) {
      this.switchTab(hash);
    } else {
      const saved = localStorage.getItem('arc-tools-tab');
      if (saved && document.getElementById('panel-' + saved)) {
        this.switchTab(saved);
      }
    }
  },

  bindTabs() {
    document.querySelectorAll('.tab-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        this.switchTab(btn.dataset.tab);
      });
    });
  },

  switchTab(tabId) {
    this.currentTab = tabId;
    window.location.hash = tabId;
    localStorage.setItem('arc-tools-tab', tabId);

    document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
    document.querySelectorAll('.tool-panel').forEach(p => p.classList.remove('active'));

    const btn = document.querySelector(`.tab-btn[data-tab="${tabId}"]`);
    const panel = document.getElementById('panel-' + tabId);
    if (btn) btn.classList.add('active');
    if (panel) panel.classList.add('active');
  },

  async registerSW() {
    if ('serviceWorker' in navigator) {
      try {
        await navigator.serviceWorker.register('/sw.js');
      } catch (e) {
        console.warn('SW registration failed:', e);
      }
    }
  },

  monitorOnline() {
    const badge = document.getElementById('offline-badge');
    const update = () => {
      if (badge) {
        badge.classList.toggle('visible', !navigator.onLine);
      }
    };
    window.addEventListener('online', update);
    window.addEventListener('offline', update);
    update();
  }
};

// Shared utilities
const Util = {
  clamp(val, min, max) {
    return Math.max(min, Math.min(max, val));
  },

  formatNum(n, decimals = 1) {
    return Number(n).toFixed(decimals);
  },

  $(sel, ctx = document) {
    return ctx.querySelector(sel);
  },

  $$(sel, ctx = document) {
    return [...ctx.querySelectorAll(sel)];
  },

  el(tag, attrs = {}, children = []) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
      if (k === 'text') e.textContent = v;
      else if (k === 'html') e.innerHTML = v;
      else if (k === 'class') e.className = v;
      else if (k === 'style' && typeof v === 'object') Object.assign(e.style, v);
      else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
      else e.setAttribute(k, v);
    }
    children.forEach(c => {
      if (typeof c === 'string') e.appendChild(document.createTextNode(c));
      else if (c) e.appendChild(c);
    });
    return e;
  }
};

document.addEventListener('DOMContentLoaded', () => App.init());
