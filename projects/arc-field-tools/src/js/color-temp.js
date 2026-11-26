// Tool 1: Color Temperature Matcher
// Ported from arc-playground/lighting/dmx.py:224-243 (Tanner Helland algorithm)

const ColorTemp = {
  currentKelvin: 3200,

  init() {
    this.slider = Util.$('#kelvin-slider');
    this.valueDisplay = Util.$('#kelvin-value');
    this.swatch = Util.$('#color-swatch');
    this.tableBody = Util.$('#fixture-dmx-body');

    if (!this.slider) return;

    this.slider.addEventListener('input', () => this.update(parseInt(this.slider.value)));

    Util.$$('.kelvin-preset').forEach(btn => {
      btn.addEventListener('click', () => {
        const k = parseInt(btn.dataset.kelvin);
        this.slider.value = k;
        this.update(k);
        Util.$$('.kelvin-preset').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
      });
    });

    this.update(3200);
  },

  // Tanner Helland algorithm — ported from dmx.py set_color_temp()
  kelvinToRGB(kelvin) {
    const temp = Util.clamp(kelvin, 1000, 10000) / 100;
    let r, g, b;

    if (temp <= 66) {
      r = 255;
      g = temp > 0 ? 99.4708 * Math.log(temp) - 161.1196 : 0;
      b = temp > 19 ? 138.5177 * Math.log(temp - 10) - 305.0448 : 0;
    } else {
      r = 329.698727 * Math.pow(temp - 60, -0.1332047);
      g = 288.1221695 * Math.pow(temp - 60, -0.0755148);
      b = 255;
    }

    return [
      Math.round(Util.clamp(r, 0, 255)),
      Math.round(Util.clamp(g, 0, 255)),
      Math.round(Util.clamp(b, 0, 255))
    ];
  },

  update(kelvin) {
    this.currentKelvin = kelvin;
    const rgb = this.kelvinToRGB(kelvin);

    // Update display
    if (this.valueDisplay) this.valueDisplay.innerHTML = `${kelvin}<span>K</span>`;
    if (this.swatch) this.swatch.style.backgroundColor = `rgb(${rgb[0]}, ${rgb[1]}, ${rgb[2]})`;
    if (this.slider) this.slider.value = kelvin;

    // Update preset buttons
    Util.$$('.kelvin-preset').forEach(btn => {
      btn.classList.toggle('active', parseInt(btn.dataset.kelvin) === kelvin);
    });

    // Update fixture DMX table
    this.updateFixtureTable(kelvin);
  },

  updateFixtureTable(kelvin) {
    if (!this.tableBody) return;
    let html = '';

    FIXTURES.forEach(fixture => {
      const dmx = fixture.kelvinToDMX(kelvin);
      const dmxStr = Object.entries(dmx)
        .filter(([, v]) => v > 0)
        .map(([ch, v]) => `<span class="text-dim">${ch}:</span> ${v}`)
        .join('  ');

      html += `<tr>
        <td>${fixture.name}</td>
        <td><span class="tag tag-${fixture.colorSystem.includes('RGB') ? 'video' : 'audio'}">${fixture.colorSystem}</span></td>
        <td>${dmxStr || '<span class="text-dim">N/A</span>'}</td>
      </tr>`;
    });

    this.tableBody.innerHTML = html;
  }
};
