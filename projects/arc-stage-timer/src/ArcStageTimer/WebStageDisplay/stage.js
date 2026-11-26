'use strict';

// --- Color map matching Swift's TimerColorState ---
const COLOR_MAP = {
  idle: '#666666',
  nominal: '#00C853',
  warning: '#FFD600',
  danger: '#FF1744',
  overtime: '#FF1744',
};

const FLASH_COLOR_MAP = {
  red: '#FF1744',
  yellow: '#FFD600',
  green: '#00C853',
  white: '#FFFFFF',
  blue: '#2979FF',
};

let currentStageMode = 'timer';
let clockInterval = null;
let lastFlashSequence = 0;
let flashTimeout = null;
let reconnectDelay = 1000;
let sse = null;

// --- SSE Connection ---

function connect() {
  const statusEl = document.getElementById('connection-status');

  if (sse) {
    sse.close();
    sse = null;
  }

  sse = new EventSource('/api/stream');

  sse.addEventListener('state', (e) => {
    try {
      const state = JSON.parse(e.data);
      handleState(state);

      // Connected — hide status after brief flash
      if (statusEl) {
        statusEl.textContent = 'CONNECTED';
        statusEl.className = 'connection-status visible connected';
        setTimeout(() => { statusEl.className = 'connection-status'; }, 2000);
      }
      reconnectDelay = 1000;
    } catch (err) {
      // Ignore parse errors
    }
  });

  sse.onerror = () => {
    if (statusEl) {
      statusEl.textContent = 'RECONNECTING...';
      statusEl.className = 'connection-status visible error';
    }
    sse.close();
    sse = null;
    setTimeout(connect, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 1.5, 10000);
  };

  sse.onopen = () => {
    if (statusEl) {
      statusEl.textContent = 'CONNECTED';
      statusEl.className = 'connection-status visible connected';
      setTimeout(() => { statusEl.className = 'connection-status'; }, 2000);
    }
    reconnectDelay = 1000;
  };
}

// --- State Handler ---

function handleState(state) {
  // Stage mode switching
  const mode = state.stageMode || 'timer';
  if (mode !== currentStageMode) {
    currentStageMode = mode;
    setActiveMode(mode);
  }

  // Update hold event name
  if (mode === 'hold') {
    const holdEvent = document.getElementById('stage-hold-event');
    if (holdEvent) holdEvent.textContent = state.holdEventName || '';
  }

  // Timer rendering
  if (mode === 'timer') {
    renderStageTimer(state);
  }

  // TEXT ALERT and message, from the STATE every tick (the app sends the whole state every 250 ms), so a HOLD
  // message stays, a 10 or 30 s one lasts as long as on the confidence monitor, and CLEAR takes effect at once.
  // It used to fade every message after a fixed 5 s. While an alert is up the message waits under it.
  const alertText = state.alert || '';
  renderAlert(alertText);
  const msgUp = !!state.message && (typeof state.messageOpacity !== 'number' || state.messageOpacity > 0);
  renderMessage(msgUp && !alertText ? state.message : '');

  // Flash — sequence-based detection (mirrors StageDisplayState.update)
  const flashSeq = state.flashSequence;
  if (typeof flashSeq === 'number' && flashSeq !== lastFlashSequence) {
    lastFlashSequence = flashSeq;
    handleFlash(state.flashColor || '');
  }
}

// --- Mode Switching ---

function setActiveMode(mode) {
  document.querySelectorAll('.stage-mode').forEach(el => el.classList.remove('active'));

  if (mode === 'timer') {
    document.getElementById('stage-timer')?.classList.add('active');
    if (clockInterval) { clearInterval(clockInterval); clockInterval = null; }
  } else if (mode === 'clock') {
    document.getElementById('stage-clock')?.classList.add('active');
    updateStageClock();
    if (!clockInterval) clockInterval = setInterval(updateStageClock, 1000);
  } else if (mode === 'hold') {
    document.getElementById('stage-hold')?.classList.add('active');
    if (clockInterval) { clearInterval(clockInterval); clockInterval = null; }
  }
}

// --- Renderers ---

function renderStageTimer(state) {
  const countdown = document.getElementById('stage-countdown');
  const cueTitle = document.getElementById('stage-cue-title');
  const nextUp = document.getElementById('stage-next-up');
  const progressFill = document.getElementById('stage-progress-fill');

  if (countdown) {
    countdown.textContent = state.displayTime || '00:00';
    countdown.style.color = COLOR_MAP[state.colorState] || '#666666';
    countdown.classList.toggle('overtime', !!state.isOvertime);
  }

  if (cueTitle) {
    cueTitle.textContent = state.cueTitle || '';
  }

  if (nextUp) {
    nextUp.textContent = state.nextCueTitle ? `NEXT: ${state.nextCueTitle}` : '';
  }

  if (progressFill) {
    const pct = Math.min(100, (state.progress || 0) * 100);
    progressFill.style.width = `${pct}%`;
    progressFill.style.backgroundColor = COLOR_MAP[state.colorState] || '#666666';
  }

  // Bottom data strip
  const elapsedEl = document.getElementById('stage-elapsed');
  const modeLabel = document.getElementById('stage-mode-label');
  if (elapsedEl) {
    const elapsed = state.elapsedSeconds || 0;
    const m = String(Math.floor(elapsed / 60)).padStart(2, '0');
    const s = String(elapsed % 60).padStart(2, '0');
    elapsedEl.textContent = `ELAPSED ${m}:${s}`;
  }
  if (modeLabel) {
    const engineState = state.state || 'idle';
    modeLabel.textContent = engineState.toUpperCase();
    modeLabel.style.color = COLOR_MAP[state.colorState] || 'rgba(255,255,255,0.25)';
  }
}

function updateStageClock() {
  const timeEl = document.getElementById('stage-clock-time');
  const dateEl = document.getElementById('stage-clock-date');
  if (!timeEl) return;

  const now = new Date();
  const h = now.getHours() % 12 || 12;
  const m = String(now.getMinutes()).padStart(2, '0');
  const s = String(now.getSeconds()).padStart(2, '0');
  const ampm = now.getHours() >= 12 ? 'PM' : 'AM';

  timeEl.textContent = `${h}:${m}:${s} ${ampm}`;

  if (dateEl) {
    dateEl.textContent = now.toLocaleDateString('en-US', {
      weekday: 'long', month: 'long', day: 'numeric', year: 'numeric',
    });
  }
}

// --- Message and TEXT ALERT ---

function renderAlert(text) {
  var banner = document.getElementById('stage-alert-banner');
  var label = document.getElementById('stage-alert-text');
  if (!banner || !label) return;
  if (text) {
    if (label.textContent !== text) label.textContent = text;
    if (banner.className.indexOf('visible') < 0) banner.className = 'stage-alert-banner visible';
    if (document.body.className.indexOf('alert-up') < 0) document.body.className += ' alert-up';
  } else if (banner.className.indexOf('visible') >= 0) {
    banner.className = 'stage-alert-banner';
    document.body.className = document.body.className.replace(/\s*alert-up/g, '');
  }
}

function renderMessage(text) {
  var overlay = document.getElementById('stage-message-overlay');
  if (!overlay) return;
  var cueTitle = document.getElementById('stage-cue-title');
  var nextUp = document.getElementById('stage-next-up');
  if (text) {
    if (overlay.textContent !== text) overlay.textContent = text;
    overlay.style.opacity = '1';
    // The message band takes the cue's place, as on the confidence monitor.
    if (cueTitle) cueTitle.style.opacity = '0';
    if (nextUp) nextUp.style.opacity = '0';
  } else {
    overlay.style.opacity = '0';
    if (cueTitle) cueTitle.style.opacity = '1';
    if (nextUp) nextUp.style.opacity = '1';
  }
}

// --- Flash Handling ---

function handleFlash(colorName) {
  const overlay = document.getElementById('stage-flash-overlay');
  if (!overlay) return;

  if (flashTimeout) { clearTimeout(flashTimeout); flashTimeout = null; }

  if (colorName && FLASH_COLOR_MAP[colorName]) {
    overlay.style.background = FLASH_COLOR_MAP[colorName];
    overlay.style.opacity = '0.8';
    // Fade out over 800ms (matches Swift's 0.8s easeOut)
    flashTimeout = setTimeout(() => {
      overlay.style.opacity = '0';
    }, 50);
  }
}

// --- Fullscreen ---

document.addEventListener('dblclick', () => {
  if (document.fullscreenElement) {
    document.exitFullscreen();
  } else {
    document.documentElement.requestFullscreen().catch(() => {
      // Safari on iPad uses webkitRequestFullscreen
      if (document.documentElement.webkitRequestFullscreen) {
        document.documentElement.webkitRequestFullscreen();
      }
    });
  }
});

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && document.fullscreenElement) {
    document.exitFullscreen();
  }
});

// Show cursor on mouse movement, hide after 3s idle
let cursorTimeout = null;
document.addEventListener('mousemove', () => {
  document.body.style.cursor = 'default';
  if (cursorTimeout) clearTimeout(cursorTimeout);
  cursorTimeout = setTimeout(() => {
    document.body.style.cursor = 'none';
  }, 3000);
});

// --- Start ---
connect();
