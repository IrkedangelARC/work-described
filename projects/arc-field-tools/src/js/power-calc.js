// Tool 2: Power / Circuit Load Calculator

const PowerCalc = {
  circuits: [],
  nextCircuitId: 1,

  init() {
    this.equipList = Util.$('#power-equip-list');
    this.circuitList = Util.$('#power-circuit-list');
    this.addCircuitBtn = Util.$('#add-circuit-btn');

    if (!this.equipList) return;

    this.renderEquipment();

    if (this.addCircuitBtn) {
      this.addCircuitBtn.addEventListener('click', () => this.addCircuit());
    }

    // Start with one default circuit
    this.addCircuit('FOH 20A', 120, 20, true);
  },

  addCircuit(name, volts, amps, derate) {
    name = name || `Circuit ${this.nextCircuitId}`;
    volts = volts || 120;
    amps = amps || 20;
    derate = derate !== undefined ? derate : true;

    this.circuits.push({
      id: this.nextCircuitId++,
      name,
      volts,
      amps,
      derate,
      items: []
    });
    this.renderCircuits();
  },

  removeCircuit(id) {
    this.circuits = this.circuits.filter(c => c.id !== id);
    this.renderCircuits();
  },

  addToCircuit(circuitId, equipName, watts) {
    const circuit = this.circuits.find(c => c.id === circuitId);
    if (!circuit) return;
    circuit.items.push({ name: equipName, watts });
    this.renderCircuits();
  },

  removeFromCircuit(circuitId, index) {
    const circuit = this.circuits.find(c => c.id === circuitId);
    if (!circuit) return;
    circuit.items.splice(index, 1);
    this.renderCircuits();
  },

  calcCircuit(circuit) {
    const maxWatts = circuit.volts * circuit.amps * (circuit.derate ? 0.8 : 1.0);
    const totalWatts = circuit.items.reduce((sum, item) => sum + item.watts, 0);
    const loadPercent = maxWatts > 0 ? (totalWatts / maxWatts) * 100 : 0;
    const totalAmps = circuit.volts > 0 ? totalWatts / circuit.volts : 0;
    let status = 'green';
    if (loadPercent >= 80) status = 'red';
    else if (loadPercent >= 60) status = 'yellow';
    return { maxWatts, totalWatts, loadPercent, totalAmps, status };
  },

  renderEquipment() {
    if (!this.equipList) return;
    let html = '';

    for (const [category, items] of Object.entries(EQUIPMENT_POWER)) {
      const label = category.charAt(0).toUpperCase() + category.slice(1);
      html += `<div class="section-label">${label}</div>`;
      html += '<div class="equip-grid">';
      items.forEach(item => {
        html += `<div class="equip-item" data-name="${item.name}" data-watts="${item.watts}">
          <span>${item.name}</span>
          <span class="watts">${item.watts}W</span>
        </div>`;
      });
      html += '</div>';
    }

    this.equipList.innerHTML = html;

    // Bind click-to-add
    this.equipList.querySelectorAll('.equip-item').forEach(el => {
      el.addEventListener('click', () => {
        const name = el.dataset.name;
        const watts = parseInt(el.dataset.watts);
        // Add to first circuit, or show circuit picker if multiple
        if (this.circuits.length === 0) {
          this.addCircuit();
        }
        if (this.circuits.length === 1) {
          this.addToCircuit(this.circuits[0].id, name, watts);
        } else {
          this.showCircuitPicker(name, watts);
        }
      });
    });
  },

  showCircuitPicker(equipName, watts) {
    // Simple: show a prompt-style picker using the first available circuit
    // For mobile simplicity, show buttons
    const existing = Util.$('#circuit-picker');
    if (existing) existing.remove();

    const picker = Util.el('div', {
      id: 'circuit-picker',
      style: {
        position: 'fixed', bottom: '0', left: '0', right: '0',
        background: 'var(--bg-surface)', borderTop: '1px solid var(--accent)',
        padding: '16px', zIndex: '200', display: 'flex', flexDirection: 'column', gap: '8px'
      }
    });

    picker.appendChild(Util.el('div', {
      text: `Add ${equipName} (${watts}W) to:`,
      style: { fontSize: '0.75rem', color: 'var(--text-dim)' }
    }));

    const btnRow = Util.el('div', { style: { display: 'flex', gap: '8px', flexWrap: 'wrap' } });
    this.circuits.forEach(c => {
      const btn = Util.el('button', {
        text: c.name,
        class: 'btn btn-sm',
        onclick: () => {
          this.addToCircuit(c.id, equipName, watts);
          picker.remove();
        }
      });
      btnRow.appendChild(btn);
    });

    const cancelBtn = Util.el('button', {
      text: 'Cancel', class: 'btn btn-sm',
      onclick: () => picker.remove()
    });
    btnRow.appendChild(cancelBtn);
    picker.appendChild(btnRow);
    document.body.appendChild(picker);
  },

  renderCircuits() {
    if (!this.circuitList) return;

    if (this.circuits.length === 0) {
      this.circuitList.innerHTML = '<div class="text-dim text-center mt-16">No circuits. Tap + to add one.</div>';
      return;
    }

    let html = '';
    this.circuits.forEach(circuit => {
      const calc = this.calcCircuit(circuit);
      const derateLabel = circuit.derate ? '80% NEC' : '100%';

      html += `<div class="circuit-card">
        <div class="circuit-header">
          <div class="circuit-name">${circuit.name}</div>
          <div style="display:flex;gap:8px;align-items:center">
            <button class="btn btn-sm circuit-config-btn" data-id="${circuit.id}">Config</button>
            <button class="btn btn-sm" style="color:var(--red)" onclick="PowerCalc.removeCircuit(${circuit.id})">&#10005;</button>
          </div>
        </div>
        <div class="circuit-stats">
          <span>${circuit.volts}V / ${circuit.amps}A <span class="text-dim">(${derateLabel})</span></span>
          <span><span class="value">${Math.round(calc.totalWatts)}W</span> / ${Math.round(calc.maxWatts)}W</span>
          <span><span class="value">${Util.formatNum(calc.totalAmps)}A</span> draw</span>
          <span class="text-${calc.status}" style="font-weight:700">${Util.formatNum(calc.loadPercent, 0)}%</span>
        </div>
        <div class="load-bar">
          <div class="load-bar-fill ${calc.status}" style="width:${Math.min(100, calc.loadPercent)}%"></div>
        </div>`;

      if (circuit.items.length > 0) {
        html += '<ul class="circuit-items">';
        circuit.items.forEach((item, idx) => {
          html += `<li>
            <span>${item.name}</span>
            <span>
              <span class="text-dim">${item.watts}W</span>
              <span class="remove" style="cursor:pointer;margin-left:8px;color:var(--text-dim)" onclick="PowerCalc.removeFromCircuit(${circuit.id}, ${idx})">&#10005;</span>
            </span>
          </li>`;
        });
        html += '</ul>';
      } else {
        html += '<div class="text-dim" style="font-size:0.65rem;padding:8px 0">Tap equipment to add to this circuit</div>';
      }

      html += '</div>';
    });

    this.circuitList.innerHTML = html;

    // Bind config buttons
    this.circuitList.querySelectorAll('.circuit-config-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        const id = parseInt(btn.dataset.id);
        this.showCircuitConfig(id);
      });
    });
  },

  showCircuitConfig(circuitId) {
    const circuit = this.circuits.find(c => c.id === circuitId);
    if (!circuit) return;

    const existing = Util.$('#circuit-config-modal');
    if (existing) existing.remove();

    const modal = Util.el('div', {
      id: 'circuit-config-modal',
      style: {
        position: 'fixed', top: '0', left: '0', right: '0', bottom: '0',
        background: 'rgba(0,0,0,0.8)', zIndex: '300', display: 'flex',
        alignItems: 'center', justifyContent: 'center', padding: '16px'
      }
    });

    const card = Util.el('div', {
      class: 'card',
      style: { width: '100%', maxWidth: '400px' },
      html: `
        <div class="card-title mb-16">Circuit Config</div>
        <div class="form-group">
          <label class="form-label">Name</label>
          <input type="text" class="form-input" id="cfg-name" value="${circuit.name}">
        </div>
        <div class="grid-3" style="margin-bottom:16px">
          <div>
            <label class="form-label">Voltage</label>
            <select class="form-select" id="cfg-volts">
              <option value="120" ${circuit.volts === 120 ? 'selected' : ''}>120V</option>
              <option value="208" ${circuit.volts === 208 ? 'selected' : ''}>208V</option>
              <option value="240" ${circuit.volts === 240 ? 'selected' : ''}>240V</option>
            </select>
          </div>
          <div>
            <label class="form-label">Amperage</label>
            <select class="form-select" id="cfg-amps">
              <option value="15" ${circuit.amps === 15 ? 'selected' : ''}>15A</option>
              <option value="20" ${circuit.amps === 20 ? 'selected' : ''}>20A</option>
              <option value="30" ${circuit.amps === 30 ? 'selected' : ''}>30A</option>
              <option value="50" ${circuit.amps === 50 ? 'selected' : ''}>50A</option>
            </select>
          </div>
          <div>
            <label class="form-label">Derate</label>
            <select class="form-select" id="cfg-derate">
              <option value="true" ${circuit.derate ? 'selected' : ''}>80% NEC</option>
              <option value="false" ${!circuit.derate ? 'selected' : ''}>100%</option>
            </select>
          </div>
        </div>
        <div style="display:flex;gap:8px;justify-content:flex-end">
          <button class="btn" id="cfg-cancel">Cancel</button>
          <button class="btn btn-accent" id="cfg-save">Save</button>
        </div>
      `
    });

    modal.appendChild(card);
    document.body.appendChild(modal);

    modal.addEventListener('click', e => { if (e.target === modal) modal.remove(); });
    Util.$('#cfg-cancel').addEventListener('click', () => modal.remove());
    Util.$('#cfg-save').addEventListener('click', () => {
      circuit.name = Util.$('#cfg-name').value || circuit.name;
      circuit.volts = parseInt(Util.$('#cfg-volts').value);
      circuit.amps = parseInt(Util.$('#cfg-amps').value);
      circuit.derate = Util.$('#cfg-derate').value === 'true';
      this.renderCircuits();
      modal.remove();
    });
  }
};
