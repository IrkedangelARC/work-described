// Tool 4: RF Frequency Coordinator
// Ported + expanded from an earlier Python wireless mic finder

const RFCoordinator = {
  occupied: [],
  results: null,
  settings: {
    bandMin: 470,
    bandMax: 698,
    minSpacing: 0.600,
    imdMargin: 0.250,
    channelStep: 0.025
  },

  init() {
    this.freqInput = Util.$('#rf-freq-input');
    this.addBtn = Util.$('#rf-add-btn');
    this.freqListEl = Util.$('#rf-freq-list');
    this.resultsEl = Util.$('#rf-results');
    this.analyzeBtn = Util.$('#rf-analyze-btn');
    this.clearBtn = Util.$('#rf-clear-btn');
    this.presetSelect = Util.$('#rf-preset-select');
    this.savePresetBtn = Util.$('#rf-save-preset-btn');

    if (!this.freqInput) return;

    this.addBtn.addEventListener('click', () => this.addFrequency());
    this.freqInput.addEventListener('keydown', e => {
      if (e.key === 'Enter') this.addFrequency();
    });
    this.analyzeBtn.addEventListener('click', () => this.analyze());
    this.clearBtn.addEventListener('click', () => this.clearAll());

    if (this.savePresetBtn) {
      this.savePresetBtn.addEventListener('click', () => this.savePreset());
    }
    if (this.presetSelect) {
      this.presetSelect.addEventListener('change', () => this.loadPreset());
      this.populatePresets();
    }
  },

  addFrequency() {
    const val = parseFloat(this.freqInput.value);
    if (isNaN(val) || val < 100 || val > 900) return;

    // Round to nearest 25kHz step
    const rounded = Math.round(val * 1000 / 25) * 25 / 1000;

    if (!this.occupied.includes(rounded)) {
      this.occupied.push(rounded);
      this.occupied.sort((a, b) => a - b);
    }

    this.freqInput.value = '';
    this.freqInput.focus();
    this.renderFreqList();
    this.results = null;
    this.renderResults();
  },

  removeFrequency(freq) {
    this.occupied = this.occupied.filter(f => f !== freq);
    this.renderFreqList();
    this.results = null;
    this.renderResults();
  },

  clearAll() {
    this.occupied = [];
    this.results = null;
    this.renderFreqList();
    this.renderResults();
  },

  renderFreqList() {
    if (!this.freqListEl) return;
    if (this.occupied.length === 0) {
      this.freqListEl.innerHTML = '<span class="text-dim" style="font-size:0.7rem">No frequencies added</span>';
      return;
    }

    this.freqListEl.innerHTML = this.occupied.map(f =>
      `<span class="freq-tag">
        ${f.toFixed(3)} MHz
        <span class="remove" onclick="RFCoordinator.removeFrequency(${f})">&#10005;</span>
      </span>`
    ).join('');
  },

  // Full 3rd-order and 5th-order IMD calculation
  calculateIMD(frequencies) {
    const products = [];

    // 2-transmitter IMD products
    for (let i = 0; i < frequencies.length; i++) {
      for (let j = i + 1; j < frequencies.length; j++) {
        const f1 = frequencies[i];
        const f2 = frequencies[j];

        // 3rd-order
        products.push({ f1, f2, imd: 2 * f1 - f2, order: 3, type: '2A-B' });
        products.push({ f1, f2, imd: 2 * f2 - f1, order: 3, type: '2B-A' });

        // 5th-order
        products.push({ f1, f2, imd: 3 * f1 - 2 * f2, order: 5, type: '3A-2B' });
        products.push({ f1, f2, imd: 3 * f2 - 2 * f1, order: 5, type: '3B-2A' });
      }
    }

    // 3-transmitter IMD: f1 + f2 - f3
    for (let i = 0; i < frequencies.length; i++) {
      for (let j = i + 1; j < frequencies.length; j++) {
        for (let k = j + 1; k < frequencies.length; k++) {
          const [f1, f2, f3] = [frequencies[i], frequencies[j], frequencies[k]];
          products.push({ f1, f2, f3, imd: f1 + f2 - f3, order: 3, type: 'A+B-C' });
          products.push({ f1, f2, f3, imd: f1 + f3 - f2, order: 3, type: 'A+C-B' });
          products.push({ f1, f2, f3, imd: f2 + f3 - f1, order: 3, type: 'B+C-A' });
        }
      }
    }

    // Filter to band range
    return products.filter(p =>
      p.imd >= this.settings.bandMin && p.imd <= this.settings.bandMax
    );
  },

  // Find open frequencies on 25kHz grid
  findOpenFrequencies(occupied, count = 8) {
    if (occupied.length === 0) return [];

    const { bandMin, bandMax, minSpacing, imdMargin, channelStep } = this.settings;
    const imdProducts = this.calculateIMD(occupied);

    // Generate candidates on 25kHz grid within a reasonable range
    const searchMin = Math.max(bandMin, Math.min(...occupied) - 5);
    const searchMax = Math.min(bandMax, Math.max(...occupied) + 5);
    const candidates = [];

    for (let f = searchMin; f <= searchMax; f = Math.round((f + channelStep) * 1000) / 1000) {
      // Check spacing from all occupied frequencies
      const spacingOk = occupied.every(occ => Math.abs(f - occ) >= minSpacing);
      if (!spacingOk) continue;

      // Check against IMD products
      const imdConflicts = imdProducts.filter(p => Math.abs(f - p.imd) < imdMargin);
      const imdSafe = imdConflicts.length === 0;

      // Also check IMD products of this candidate WITH existing occupied
      const testFreqs = [...occupied, f];
      const newIMD = this.calculateIMD(testFreqs);
      const newConflicts = newIMD.filter(p => {
        return testFreqs.some(tf => Math.abs(tf - p.imd) < imdMargin && tf !== p.imd);
      });

      candidates.push({
        freq: f,
        safe: imdSafe && newConflicts.length === 0,
        imdConflicts: [...imdConflicts, ...newConflicts.filter(c =>
          !imdConflicts.some(ic => Math.abs(ic.imd - c.imd) < 0.001)
        )],
        spacing: Math.min(...occupied.map(o => Math.abs(f - o)))
      });
    }

    // Sort: safe first, then by spacing (larger spacing preferred)
    candidates.sort((a, b) => {
      if (a.safe !== b.safe) return a.safe ? -1 : 1;
      return b.spacing - a.spacing;
    });

    return candidates.slice(0, count);
  },

  // Check existing frequencies for IMD conflicts between them
  checkExistingConflicts() {
    const conflicts = [];
    const imdProducts = this.calculateIMD(this.occupied);

    imdProducts.forEach(product => {
      this.occupied.forEach(freq => {
        if (Math.abs(freq - product.imd) < this.settings.imdMargin) {
          conflicts.push({
            freq,
            product,
            delta: Math.abs(freq - product.imd)
          });
        }
      });
    });

    return conflicts;
  },

  analyze() {
    if (this.occupied.length < 2) {
      this.results = { error: 'Add at least 2 frequencies to analyze' };
      this.renderResults();
      return;
    }

    const existingConflicts = this.checkExistingConflicts();
    const openFreqs = this.findOpenFrequencies(this.occupied, 12);
    const allIMD = this.calculateIMD(this.occupied);

    this.results = { existingConflicts, openFreqs, allIMD };
    this.renderResults();
  },

  renderResults() {
    if (!this.resultsEl) return;

    if (!this.results) {
      this.resultsEl.innerHTML = '<div class="text-dim text-center" style="font-size:0.7rem;padding:20px 0">Add frequencies and tap Analyze</div>';
      return;
    }

    if (this.results.error) {
      this.resultsEl.innerHTML = `<div class="text-dim text-center" style="padding:20px 0">${this.results.error}</div>`;
      return;
    }

    const { existingConflicts, openFreqs, allIMD } = this.results;
    let html = '';

    // Existing conflicts
    html += '<div class="section-label">Current Frequency Status</div>';
    if (existingConflicts.length > 0) {
      existingConflicts.forEach(c => {
        const sources = c.product.f3
          ? `${c.product.f1.toFixed(3)} + ${c.product.f2.toFixed(3)} - ${c.product.f3.toFixed(3)}`
          : `${c.product.type}: ${c.product.f1.toFixed(3)}, ${c.product.f2.toFixed(3)}`;
        html += `<div class="freq-result conflict">
          <span>${c.freq.toFixed(3)} MHz — IMD conflict</span>
          <span class="text-dim">${sources} = ${c.product.imd.toFixed(3)}</span>
        </div>`;
      });
    } else {
      html += '<div class="freq-result safe"><span>No IMD conflicts between current frequencies</span></div>';
    }

    // Open frequencies
    html += '<div class="section-label mt-16">Recommended Open Frequencies</div>';
    if (openFreqs.length === 0) {
      html += '<div class="text-dim" style="font-size:0.7rem;padding:8px 0">No clean frequencies found in range</div>';
    } else {
      openFreqs.forEach(c => {
        const status = c.safe ? 'safe' : 'warning';
        const label = c.safe ? 'CLEAN' : `${c.imdConflicts.length} IMD`;
        html += `<div class="freq-result ${status}">
          <span>${c.freq.toFixed(3)} MHz</span>
          <span>${label} — spacing: ${c.spacing.toFixed(3)} MHz</span>
        </div>`;
      });
    }

    // IMD product count
    html += `<div class="mt-16 text-dim" style="font-size:0.65rem">
      ${allIMD.length} IMD products calculated (${allIMD.filter(p => p.order === 3).length} 3rd-order, ${allIMD.filter(p => p.order === 5).length} 5th-order)
    </div>`;

    this.resultsEl.innerHTML = html;
  },

  // Venue preset management
  getPresets() {
    try {
      return JSON.parse(localStorage.getItem('arc-rf-presets') || '{}');
    } catch { return {}; }
  },

  savePreset() {
    if (this.occupied.length === 0) return;
    const name = prompt('Preset name (e.g. "Main Hall"):');
    if (!name) return;

    const presets = this.getPresets();
    presets[name] = this.occupied.slice();
    localStorage.setItem('arc-rf-presets', JSON.stringify(presets));
    this.populatePresets();
  },

  loadPreset() {
    if (!this.presetSelect) return;
    const name = this.presetSelect.value;
    if (!name) return;

    const presets = this.getPresets();
    if (presets[name]) {
      this.occupied = presets[name].slice();
      this.occupied.sort((a, b) => a - b);
      this.results = null;
      this.renderFreqList();
      this.renderResults();
    }
    this.presetSelect.value = '';
  },

  populatePresets() {
    if (!this.presetSelect) return;
    const presets = this.getPresets();
    const names = Object.keys(presets);

    let html = '<option value="">Load Preset...</option>';
    names.forEach(name => {
      html += `<option value="${name}">${name} (${presets[name].length} freq)</option>`;
    });
    this.presetSelect.innerHTML = html;
  }
};
