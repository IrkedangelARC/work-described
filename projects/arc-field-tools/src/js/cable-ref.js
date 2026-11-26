// Tool 3: Cable & Connector Reference
// Searchable card UI for all signal types

const CableRef = {
  currentFilter: '',
  currentCategory: 'all',

  init() {
    this.searchInput = Util.$('#cable-search');
    this.container = Util.$('#cable-cards');

    if (!this.searchInput || !this.container) return;

    this.searchInput.addEventListener('input', () => {
      this.currentFilter = this.searchInput.value.toLowerCase();
      this.render();
    });

    Util.$$('.cable-cat-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        this.currentCategory = btn.dataset.category;
        Util.$$('.cable-cat-btn').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        this.render();
      });
    });

    this.render();
  },

  getAllSignals() {
    const all = [];
    for (const [cat, items] of Object.entries(SIGNALS)) {
      items.forEach(s => all.push({ ...s, category: cat }));
    }
    return all;
  },

  filterSignals() {
    return this.getAllSignals().filter(s => {
      const catMatch = this.currentCategory === 'all' || s.category === this.currentCategory;
      if (!catMatch) return false;
      if (!this.currentFilter) return true;

      const searchable = [s.name, s.connector, s.cable, s.notes, s.maxLength,
        s.bandwidth, s.resolution, s.voltage, s.level]
        .filter(Boolean).join(' ').toLowerCase();
      return searchable.includes(this.currentFilter);
    });
  },

  render() {
    const signals = this.filterSignals();
    if (!this.container) return;

    if (signals.length === 0) {
      this.container.innerHTML = '<div class="text-dim text-center mt-16">No matches found</div>';
      return;
    }

    // Group by category
    const groups = {};
    signals.forEach(s => {
      if (!groups[s.category]) groups[s.category] = [];
      groups[s.category].push(s);
    });

    let html = '';
    const catLabels = { video: 'Video Signals', audio: 'Audio Signals', data: 'Data / Control', power: 'Power Connectors' };

    for (const [cat, items] of Object.entries(groups)) {
      html += `<div class="section-label">${catLabels[cat] || cat}</div>`;
      items.forEach((s, i) => {
        const id = `sig-${cat}-${i}`;
        html += this.renderCard(s, id);
      });
    }

    this.container.innerHTML = html;

    // Bind expand/collapse
    this.container.querySelectorAll('.signal-card-header').forEach(h => {
      h.addEventListener('click', () => {
        h.parentElement.classList.toggle('expanded');
      });
    });
  },

  renderCard(signal, id) {
    const tagClass = `tag-${signal.category}`;
    const meta = [];
    if (signal.connector) meta.push(signal.connector);
    if (signal.maxLength) meta.push(signal.maxLength);
    if (signal.bandwidth) meta.push(signal.bandwidth);
    if (signal.voltage) meta.push(`${signal.voltage} / ${signal.maxAmps}`);

    let body = '<div class="signal-card-body">';

    // Main specs table
    body += '<table class="data-table">';
    if (signal.connector) body += `<tr><td class="text-dim" style="width:100px">Connector</td><td>${signal.connector}</td></tr>`;
    if (signal.cable) body += `<tr><td class="text-dim">Cable</td><td>${signal.cable}</td></tr>`;
    if (signal.maxLength) body += `<tr><td class="text-dim">Max Length</td><td>${signal.maxLength}</td></tr>`;
    if (signal.bandwidth) body += `<tr><td class="text-dim">Bandwidth</td><td>${signal.bandwidth}</td></tr>`;
    if (signal.resolution) body += `<tr><td class="text-dim">Resolution</td><td>${signal.resolution}</td></tr>`;
    if (signal.level) body += `<tr><td class="text-dim">Level</td><td>${signal.level}</td></tr>`;
    if (signal.voltage) body += `<tr><td class="text-dim">Voltage</td><td>${signal.voltage}</td></tr>`;
    if (signal.maxAmps) body += `<tr><td class="text-dim">Max Amps</td><td>${signal.maxAmps}</td></tr>`;
    if (signal.locking) body += `<tr><td class="text-dim">Locking</td><td>${signal.locking}</td></tr>`;
    body += '</table>';

    if (signal.notes) {
      body += `<div class="mt-8" style="font-size:0.7rem;color:var(--text-dim)">${signal.notes}</div>`;
    }

    // Pin-out diagram
    if (signal.pinout) {
      body += '<div class="pin-out">';
      if (signal.pairNote) body += `<div class="mb-8" style="font-size:0.65rem;color:var(--accent)">${signal.pairNote}</div>`;
      for (const [pin, label] of Object.entries(signal.pinout)) {
        body += `<span class="pin-num">Pin ${pin}</span> <span class="pin-label">${label}</span><br>`;
      }
      body += '</div>';
    }

    body += '</div>';

    return `<div class="signal-card" id="${id}">
      <div class="signal-card-header">
        <div>
          <span class="signal-card-name">${signal.name}</span>
          <span class="tag ${tagClass}" style="margin-left:8px">${signal.category}</span>
        </div>
        <div class="signal-card-meta">
          ${meta.slice(0, 2).map(m => `<span>${m}</span>`).join('')}
          <span class="signal-card-chevron">&#9660;</span>
        </div>
      </div>
      ${body}
    </div>`;
  }
};
