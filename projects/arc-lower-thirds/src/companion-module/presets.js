import { combineRgb } from '@companion-module/base'
import { ICONS } from './icons.js'

const BLACK = combineRgb(0, 0, 0)
const WHITE = combineRgb(255, 255, 255)
const GREEN = combineRgb(0, 200, 83)
const YELLOW = combineRgb(255, 214, 0)
const RED = combineRgb(255, 23, 68)
const LIVE_RED = combineRgb(220, 20, 20)
const ACCENT = combineRgb(0, 176, 255)
const DARK = combineRgb(30, 30, 30)
const DARK_RED = combineRgb(40, 0, 0)
const DARK_GREEN = combineRgb(0, 30, 0)
const ORANGE = combineRgb(255, 111, 0)

export function getPresets(instance) {
	const presets = {
		// === FIRE / CLEAR ===
		fire: {
			type: 'button',
			category: 'Fire / Clear',
			name: 'FIRE',
			style: { text: 'FIRE', size: '24', color: WHITE, bgcolor: combineRgb(10, 92, 10), png64: ICONS.fire },
			steps: [{ down: [{ actionId: 'fire' }], up: [] }],
			feedbacks: [
				{ feedbackId: 'isOnAir', style: { bgcolor: LIVE_RED, text: 'ON AIR', png64: ICONS.fireActive } },
			],
		},

		clear: {
			type: 'button',
			category: 'Fire / Clear',
			name: 'CLEAR',
			style: { text: 'CLEAR', size: '24', color: WHITE, bgcolor: combineRgb(92, 10, 10), png64: ICONS.clear },
			steps: [{ down: [{ actionId: 'clear' }], up: [] }],
			feedbacks: [
				{ feedbackId: 'allClear', style: { bgcolor: DARK, color: combineRgb(100, 100, 100) } },
			],
		},

		fireNext: {
			type: 'button',
			category: 'Fire / Clear',
			name: 'Fire + Advance',
			style: { text: 'FIRE\\n+ ADV', size: '14', color: WHITE, bgcolor: combineRgb(10, 92, 10), png64: ICONS.fireNext },
			steps: [{ down: [{ actionId: 'fireNext' }], up: [] }],
			feedbacks: [],
		},

		clearAll: {
			type: 'button',
			category: 'Fire / Clear',
			name: 'Clear All Layers',
			style: { text: 'CLEAR\\nALL', size: '18', color: WHITE, bgcolor: combineRgb(120, 10, 10), png64: ICONS.clearAll },
			steps: [{ down: [{ actionId: 'clearAll' }], up: [] }],
			feedbacks: [
				{ feedbackId: 'anyLayerOnAir', style: { bgcolor: LIVE_RED } },
			],
		},

		cut: {
			type: 'button',
			category: 'Fire / Clear',
			name: 'Cut to Black',
			style: { text: 'CUT', size: '18', color: WHITE, bgcolor: combineRgb(120, 10, 10), png64: ICONS.cut },
			steps: [{ down: [{ actionId: 'cut' }], up: [] }],
			feedbacks: [],
		},

		// === NAVIGATION ===
		next: {
			type: 'button',
			category: 'Navigation',
			name: 'Next Graphic',
			style: { text: 'NEXT\\n\\u25B6\\u25B6', size: '18', color: GREEN, bgcolor: DARK, png64: ICONS.next },
			steps: [{ down: [{ actionId: 'next' }], up: [] }],
			feedbacks: [],
		},

		prev: {
			type: 'button',
			category: 'Navigation',
			name: 'Previous Graphic',
			style: { text: 'PREV\\n\\u25C0\\u25C0', size: '18', color: YELLOW, bgcolor: DARK, png64: ICONS.prev },
			steps: [{ down: [{ actionId: 'previous' }], up: [] }],
			feedbacks: [],
		},

		// === LAYER CONTROL ===
		clearLowerThird: {
			type: 'button',
			category: 'Layer Control',
			name: 'Clear Lower Third',
			style: { text: 'CLR\\nLT', size: '14', color: ACCENT, bgcolor: DARK, png64: ICONS.layerLT },
			steps: [{ down: [{ actionId: 'clearLayer', options: { layer: 'lowerThird' } }], up: [] }],
			feedbacks: [
				{ feedbackId: 'layerOnAir', options: { layer: 'lowerThird' }, style: { bgcolor: LIVE_RED, color: WHITE } },
			],
		},

		clearTicker: {
			type: 'button',
			category: 'Layer Control',
			name: 'Clear Ticker',
			style: { text: 'CLR\\nTICK', size: '14', color: ORANGE, bgcolor: DARK, png64: ICONS.layerTicker },
			steps: [{ down: [{ actionId: 'clearLayer', options: { layer: 'ticker' } }], up: [] }],
			feedbacks: [
				{ feedbackId: 'layerOnAir', options: { layer: 'ticker' }, style: { bgcolor: LIVE_RED, color: WHITE } },
			],
		},

		clearBug: {
			type: 'button',
			category: 'Layer Control',
			name: 'Clear Logo Bug',
			style: { text: 'CLR\\nBUG', size: '14', color: combineRgb(179, 136, 255), bgcolor: DARK, png64: ICONS.layerBug },
			steps: [{ down: [{ actionId: 'clearLayer', options: { layer: 'logoBug' } }], up: [] }],
			feedbacks: [
				{ feedbackId: 'layerOnAir', options: { layer: 'logoBug' }, style: { bgcolor: LIVE_RED, color: WHITE } },
			],
		},

		clearFullTitle: {
			type: 'button',
			category: 'Layer Control',
			name: 'Clear Full Title',
			style: { text: 'CLR\\nFULL', size: '14', color: YELLOW, bgcolor: DARK, png64: ICONS.layerFull },
			steps: [{ down: [{ actionId: 'clearLayer', options: { layer: 'fullTitle' } }], up: [] }],
			feedbacks: [
				{ feedbackId: 'layerOnAir', options: { layer: 'fullTitle' }, style: { bgcolor: LIVE_RED, color: WHITE } },
			],
		},

		clearClock: {
			type: 'button',
			category: 'Layer Control',
			name: 'Clear Clock',
			style: { text: 'CLR\\nCLK', size: '14', color: combineRgb(0, 229, 255), bgcolor: DARK, png64: ICONS.layerClock },
			steps: [{ down: [{ actionId: 'clearLayer', options: { layer: 'clock' } }], up: [] }],
			feedbacks: [
				{ feedbackId: 'layerOnAir', options: { layer: 'clock' }, style: { bgcolor: LIVE_RED, color: WHITE } },
			],
		},

		// === STATUS DISPLAYS (dynamic text via variables) ===
		nameDisplay: {
			type: 'button',
			category: 'Status',
			name: 'Name Display',
			style: {
				text: '$(arc-lower-thirds:line1)\\n$(arc-lower-thirds:line2)',
				size: '14',
				color: WHITE,
				bgcolor: BLACK,
			},
			steps: [],
			feedbacks: [
				{ feedbackId: 'isOnAir', style: { bgcolor: DARK_RED } },
			],
		},

		positionDisplay: {
			type: 'button',
			category: 'Status',
			name: 'Position Display',
			style: {
				text: '$(arc-lower-thirds:graphic_position)',
				size: '24',
				color: WHITE,
				bgcolor: BLACK,
			},
			steps: [],
			feedbacks: [],
		},

		onAirIndicator: {
			type: 'button',
			category: 'Status',
			name: 'On Air Indicator',
			style: {
				text: 'STANDBY',
				size: '14',
				color: GREEN,
				bgcolor: DARK_GREEN,
				png64: ICONS.standby,
			},
			steps: [],
			feedbacks: [
				{ feedbackId: 'isOnAir', style: { text: 'ON AIR', color: WHITE, bgcolor: LIVE_RED, png64: ICONS.onAir } },
			],
		},

		activeLayersDisplay: {
			type: 'button',
			category: 'Status',
			name: 'Active Layers',
			style: {
				text: '$(arc-lower-thirds:active_layers)',
				size: '14',
				color: combineRgb(150, 150, 150),
				bgcolor: BLACK,
			},
			steps: [],
			feedbacks: [
				{ feedbackId: 'anyLayerOnAir', style: { color: RED, bgcolor: DARK_RED } },
			],
		},

		showNameDisplay: {
			type: 'button',
			category: 'Status',
			name: 'Show Name',
			style: {
				text: '$(arc-lower-thirds:show_name)',
				size: '14',
				color: ACCENT,
				bgcolor: BLACK,
			},
			steps: [],
			feedbacks: [],
		},
	}

	// === GRAPHIC BANK: direct fire buttons 1-32 (for Stream Deck XL) ===
	for (let i = 1; i <= 32; i++) {
		presets[`fireGraphic${i}`] = {
			type: 'button',
			category: 'Graphic Bank',
			name: `Fire Graphic ${i}`,
			style: {
				text: `${i}\\n$(arc-lower-thirds:graphic_${i}_name)`,
				size: '14',
				color: WHITE,
				bgcolor: DARK,
			},
			steps: [{ down: [{ actionId: 'fireAtIndex', options: { index: i } }], up: [] }],
			feedbacks: [
				{ feedbackId: 'graphicSelected', options: { index: i }, style: { bgcolor: combineRgb(0, 60, 80) } },
			],
		}
	}

	return presets
}
