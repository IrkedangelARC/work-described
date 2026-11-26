import { combineRgb } from '@companion-module/base'

const BLACK = combineRgb(0, 0, 0)
const WHITE = combineRgb(255, 255, 255)
const GREEN = combineRgb(0, 200, 83)
const RED = combineRgb(255, 23, 68)
const ACCENT = combineRgb(0, 176, 255)
const DARK = combineRgb(30, 30, 30)
const DARK_RED = combineRgb(40, 0, 0)
const DARK_GREEN = combineRgb(0, 30, 0)
const YELLOW = combineRgb(255, 214, 0)
const ORANGE = combineRgb(255, 111, 0)

export function getPresets(instance) {
	const presets = {
		// === SOURCE SWITCHING (1-8) ===
	}

	for (let i = 1; i <= 8; i++) {
		presets[`source${i}`] = {
			type: 'button',
			category: 'Sources',
			name: `Source ${i}`,
			style: {
				text: `${i}\\n$(arc-switcher:source_${i}_name)`,
				size: '14',
				color: WHITE,
				bgcolor: DARK,
			},
			steps: [{ down: [{ actionId: `switch${i}` }], up: [] }],
			feedbacks: [
				{ feedbackId: `source${i}Active`, style: { bgcolor: RED, color: WHITE } },
				{ feedbackId: `source${i}Unavailable`, style: { bgcolor: DARK_RED, color: combineRgb(100, 100, 100) } },
			],
		}
	}

	// === BLACK ===
	presets.black = {
		type: 'button',
		category: 'Control',
		name: 'Cut to Black',
		style: { text: 'BLACK', size: '18', color: WHITE, bgcolor: DARK },
		steps: [{ down: [{ actionId: 'toggleBlack' }], up: [] }],
		feedbacks: [
			{ feedbackId: 'isBlack', style: { bgcolor: RED, color: WHITE, text: 'BLACK\\nLIVE' } },
		],
	}

	// === SLIDE NAVIGATION ===
	presets.nextSlide = {
		type: 'button',
		category: 'Slides',
		name: 'Next Slide',
		style: { text: 'NEXT\\n\\u25B6', size: '18', color: GREEN, bgcolor: DARK },
		steps: [{ down: [{ actionId: 'nextSlide' }], up: [] }],
		feedbacks: [],
	}

	presets.prevSlide = {
		type: 'button',
		category: 'Slides',
		name: 'Previous Slide',
		style: { text: 'PREV\\n\\u25C0', size: '18', color: YELLOW, bgcolor: DARK },
		steps: [{ down: [{ actionId: 'previousSlide' }], up: [] }],
		feedbacks: [],
	}

	// === PRESENTATION MODE ===
	presets.startPres = {
		type: 'button',
		category: 'Slides',
		name: 'Start Presentation',
		style: { text: 'START\\nPRES', size: '14', color: GREEN, bgcolor: DARK },
		steps: [{ down: [{ actionId: 'startPresentation' }], up: [] }],
		feedbacks: [],
	}

	presets.stopPres = {
		type: 'button',
		category: 'Slides',
		name: 'Stop Presentation',
		style: { text: 'STOP\\nPRES', size: '14', color: RED, bgcolor: DARK },
		steps: [{ down: [{ actionId: 'stopPresentation' }], up: [] }],
		feedbacks: [],
	}

	// === TRANSPORT ===
	presets.play = {
		type: 'button',
		category: 'Transport',
		name: 'Play',
		style: { text: '\\u25B6 PLAY', size: '18', color: GREEN, bgcolor: DARK },
		steps: [{ down: [{ actionId: 'play' }], up: [] }],
		feedbacks: [],
	}

	presets.pause = {
		type: 'button',
		category: 'Transport',
		name: 'Pause',
		style: { text: '|| PAUSE', size: '18', color: YELLOW, bgcolor: DARK },
		steps: [{ down: [{ actionId: 'pause' }], up: [] }],
		feedbacks: [],
	}

	presets.stop = {
		type: 'button',
		category: 'Transport',
		name: 'Stop',
		style: { text: '\\u25A0 STOP', size: '18', color: RED, bgcolor: DARK },
		steps: [{ down: [{ actionId: 'stop' }], up: [] }],
		feedbacks: [],
	}

	// === VOLUME ===
	presets.volumeUp = {
		type: 'button',
		category: 'Volume',
		name: 'Volume Up',
		style: { text: 'VOL\\n+', size: '18', color: ACCENT, bgcolor: DARK },
		steps: [{ down: [{ actionId: 'volumeUp' }], up: [] }],
		feedbacks: [],
	}

	presets.volumeDown = {
		type: 'button',
		category: 'Volume',
		name: 'Volume Down',
		style: { text: 'VOL\\n-', size: '18', color: ACCENT, bgcolor: DARK },
		steps: [{ down: [{ actionId: 'volumeDown' }], up: [] }],
		feedbacks: [],
	}

	presets.mute = {
		type: 'button',
		category: 'Volume',
		name: 'Mute',
		style: { text: 'MUTE', size: '18', color: ORANGE, bgcolor: DARK },
		steps: [{ down: [{ actionId: 'mute' }], up: [] }],
		feedbacks: [],
	}

	// === STATUS ===
	presets.activeSource = {
		type: 'button',
		category: 'Status',
		name: 'Active Source',
		style: {
			text: '$(arc-switcher:active_source_name)',
			size: '14',
			color: WHITE,
			bgcolor: BLACK,
		},
		steps: [],
		feedbacks: [
			{ feedbackId: 'hasActiveSource', style: { bgcolor: DARK_GREEN, color: GREEN } },
			{ feedbackId: 'noActiveSource', style: { color: combineRgb(100, 100, 100) } },
		],
	}

	presets.blackStatus = {
		type: 'button',
		category: 'Status',
		name: 'Black Status',
		style: {
			text: '$(arc-switcher:is_black)',
			size: '18',
			color: RED,
			bgcolor: BLACK,
		},
		steps: [],
		feedbacks: [
			{ feedbackId: 'isBlack', style: { bgcolor: DARK_RED, color: RED } },
		],
	}

	return presets
}
