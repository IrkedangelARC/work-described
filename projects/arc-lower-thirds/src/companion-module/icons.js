// SVG icon templates for StreamDeck buttons (72x72)
// Rendered as base64 PNG-compatible SVG data URIs

function svgToBase64(svg) {
	return Buffer.from(svg).toString('base64')
}

function icon(bgColor, fgColor, symbol, label = '') {
	const labelBlock = label
		? `<text x="36" y="62" text-anchor="middle" font-family="Helvetica,Arial,sans-serif" font-size="9" font-weight="bold" fill="${fgColor}">${label}</text>`
		: ''
	return svgToBase64(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 72 72" width="72" height="72">
<rect width="72" height="72" rx="4" fill="${bgColor}"/>
<text x="36" y="${label ? '38' : '44'}" text-anchor="middle" font-family="Helvetica,Arial,sans-serif" font-size="28" fill="${fgColor}">${symbol}</text>
${labelBlock}
</svg>`)
}

function iconWithBorder(bgColor, borderColor, fgColor, symbol, label = '') {
	const labelBlock = label
		? `<text x="36" y="62" text-anchor="middle" font-family="Helvetica,Arial,sans-serif" font-size="9" font-weight="bold" fill="${fgColor}">${label}</text>`
		: ''
	return svgToBase64(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 72 72" width="72" height="72">
<rect width="72" height="72" rx="4" fill="${bgColor}"/>
<rect x="2" y="2" width="68" height="68" rx="3" fill="none" stroke="${borderColor}" stroke-width="3"/>
<text x="36" y="${label ? '38' : '44'}" text-anchor="middle" font-family="Helvetica,Arial,sans-serif" font-size="28" fill="${fgColor}">${symbol}</text>
${labelBlock}
</svg>`)
}

function liveIcon(symbol, label) {
	return svgToBase64(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 72 72" width="72" height="72">
<rect width="72" height="72" rx="4" fill="#DC1414"/>
<circle cx="12" cy="8" r="4" fill="#FF4444"/>
<text x="36" y="${label ? '38' : '44'}" text-anchor="middle" font-family="Helvetica,Arial,sans-serif" font-size="24" font-weight="bold" fill="#FFF">${symbol}</text>
${label ? `<text x="36" y="62" text-anchor="middle" font-family="Helvetica,Arial,sans-serif" font-size="9" font-weight="bold" fill="#FFF">${label}</text>` : ''}
</svg>`)
}

// Exported icon set
export const ICONS = {
	// Fire / Clear
	fire: icon('#0A5C0A', '#00E676', '\u25B6', 'FIRE'),
	fireActive: liveIcon('\u25B6', 'ON AIR'),
	clear: icon('#5C0A0A', '#FF8A80', '\u25A0', 'CLEAR'),
	clearAll: icon('#B71C1C', '#FFF', '\u2716', 'CLEAR ALL'),
	cut: icon('#B71C1C', '#FF8A80', '\u2588', 'CUT'),

	// Navigation
	next: icon('#1E1E1E', '#00E676', '\u25B6\u25B6', 'NEXT'),
	prev: icon('#1E1E1E', '#FFD600', '\u25C0\u25C0', 'PREV'),
	fireNext: icon('#0A5C0A', '#00E5FF', '\u25B6+', 'FIRE+ADV'),

	// Layer control
	layerLT: iconWithBorder('#1E1E1E', '#00B0FF', '#00B0FF', 'LT', 'LOWER 3RD'),
	layerTicker: iconWithBorder('#1E1E1E', '#FF6F00', '#FF6F00', 'TK', 'TICKER'),
	layerBug: iconWithBorder('#1E1E1E', '#B388FF', '#B388FF', 'BG', 'LOGO BUG'),
	layerFull: iconWithBorder('#1E1E1E', '#FFD600', '#FFD600', 'FT', 'FULL TITLE'),
	layerClock: iconWithBorder('#1E1E1E', '#00E5FF', '#00E5FF', 'CK', 'CLOCK'),

	// Status
	onAir: liveIcon('', 'ON AIR'),
	standby: icon('#0D3B0D', '#00E676', '', 'STANDBY'),
}
