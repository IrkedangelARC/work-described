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

function flashIcon(color, colorName) {
	return svgToBase64(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 72 72" width="72" height="72">
<rect width="72" height="72" rx="4" fill="${color}"/>
<text x="36" y="36" text-anchor="middle" font-family="Helvetica,Arial,sans-serif" font-size="22" font-weight="bold" fill="#000">&#x26A1;</text>
<text x="36" y="58" text-anchor="middle" font-family="Helvetica,Arial,sans-serif" font-size="10" font-weight="bold" fill="#000">${colorName}</text>
</svg>`)
}

function modeIcon(symbol, label, active = false) {
	const bg = active ? '#00B0FF' : '#1E1E1E'
	const fg = active ? '#000' : '#AAA'
	const border = active ? '#00B0FF' : '#555'
	return iconWithBorder(bg, border, fg, symbol, label)
}

// Exported icon set
export const ICONS = {
	// Transport
	play: icon('#1B5E20', '#00E676', '\u25B6', 'PLAY'),
	pause: icon('#F57F17', '#000', '\u275A\u275A', 'PAUSE'),
	playPause: icon('#0D47A1', '#82B1FF', '\u25B6\u258C', 'PLAY/PAUSE'),
	stop: icon('#B71C1C', '#FF8A80', '\u25A0', 'STOP'),
	reset: icon('#1E1E1E', '#FFF', '\u21BA', 'RESET'),

	// Navigation
	next: icon('#1E1E1E', '#00E676', '\u25B6\u25B6', 'NEXT'),
	prev: icon('#1E1E1E', '#FFD600', '\u25C0\u25C0', 'PREV'),

	// Flash
	flashRed: flashIcon('#FF1744', 'STOP'),
	flashYellow: flashIcon('#FFD600', 'WARN'),
	flashGreen: flashIcon('#00C853', 'GO'),
	flashWhite: flashIcon('#FFFFFF', 'FLASH'),

	// Messages
	wrapUp: icon('#D50000', '#FFF', '!', 'WRAP UP'),
	standBy: icon('#FF6F00', '#FFF', '\u23F3', 'STAND BY'),
	message: icon('#1E1E1E', '#82B1FF', '\u2709', 'MESSAGE'),

	// Stage Mode
	modeTimer: modeIcon('\u23F1', 'TIMER'),
	modeClock: modeIcon('\u23F0', 'CLOCK'),
	modeHold: modeIcon('\u23F8', 'HOLD'),

	// Time Adjustments
	add1min: icon('#004D40', '#00E5FF', '+1', 'MIN'),
	add5min: icon('#004D40', '#00E5FF', '+5', 'MIN'),
	sub1min: icon('#3E2700', '#FF6F00', '-1', 'MIN'),
	sub5min: icon('#3E2700', '#FF6F00', '-5', 'MIN'),

	// Schedule
	shift: icon('#311B92', '#B388FF', '\u21E5', 'SHIFT'),
	compress: icon('#311B92', '#B388FF', '\u2194', 'COMPRESS'),
	undo: icon('#1E1E1E', '#999', '\u21B6', 'UNDO'),

	// Status (dynamic - text buttons)
	countdown: icon('#000', '#00E676', '', 'TIME'),
	cueInfo: icon('#000', '#AAA', '', 'CUE'),
	offset: icon('#000', '#FFD600', '', 'OFFSET'),
}
