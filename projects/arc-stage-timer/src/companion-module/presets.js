import { combineRgb } from '@companion-module/base'
import { ICONS } from './icons.js'

const BLACK = combineRgb(0, 0, 0)
const WHITE = combineRgb(255, 255, 255)
const GREEN = combineRgb(0, 200, 83)
const YELLOW = combineRgb(255, 214, 0)
const RED = combineRgb(255, 23, 68)
const ACCENT = combineRgb(0, 176, 255)
const DARK = combineRgb(30, 30, 30)
const DARK_RED = combineRgb(40, 0, 0)
const DARK_GREEN = combineRgb(0, 30, 0)
const DARK_YELLOW = combineRgb(40, 35, 0)
const CYAN = combineRgb(0, 229, 255)
const CYAN_BG = combineRgb(0, 50, 50)
const PURPLE = combineRgb(179, 136, 255)
const PURPLE_BG = combineRgb(30, 15, 60)
const ORANGE = combineRgb(255, 111, 0)

export function getPresets(instance) {
	const presets = {
		// === TRANSPORT ===
		playPause: {
			type: 'button',
			category: 'Transport',
			name: 'Play / Pause',
			style: { text: 'PLAY\\nPAUSE', size: '18', color: WHITE, bgcolor: DARK, png64: ICONS.playPause },
			steps: [{ down: [{ actionId: 'toggle' }], up: [] }],
			feedbacks: [
				{ feedbackId: 'timerRunning', style: { bgcolor: GREEN, color: BLACK, text: '\\u25B6 PLAY', png64: ICONS.play } },
				{ feedbackId: 'timerPaused', style: { bgcolor: YELLOW, color: BLACK, text: '|| PAUSE', png64: ICONS.pause } },
			],
		},
		stop: {
			type: 'button',
			category: 'Transport',
			name: 'Stop / Reset',
			style: { text: 'STOP', size: '18', color: WHITE, bgcolor: combineRgb(80, 0, 0), png64: ICONS.stop },
			steps: [{ down: [{ actionId: 'stop' }], up: [] }],
			feedbacks: [],
		},
		reset: {
			type: 'button',
			category: 'Transport',
			name: 'Reset Cue',
			style: { text: 'RESET', size: '18', color: WHITE, bgcolor: DARK, png64: ICONS.reset },
			steps: [{ down: [{ actionId: 'reset' }], up: [] }],
			feedbacks: [],
		},

		// === NAVIGATION ===
		next: {
			type: 'button',
			category: 'Navigation',
			name: 'Next Cue',
			style: { text: 'NEXT\\n\\u25B6\\u25B6', size: '18', color: GREEN, bgcolor: DARK, png64: ICONS.next },
			steps: [{ down: [{ actionId: 'next' }], up: [] }],
			feedbacks: [],
		},
		prev: {
			type: 'button',
			category: 'Navigation',
			name: 'Previous Cue',
			style: { text: 'PREV\\n\\u25C0\\u25C0', size: '18', color: YELLOW, bgcolor: DARK, png64: ICONS.prev },
			steps: [{ down: [{ actionId: 'previous' }], up: [] }],
			feedbacks: [],
		},

		// === FLASH SIGNALS ===
		flashRed: {
			type: 'button',
			category: 'Flash Signals',
			name: 'Flash Red (STOP)',
			style: { text: 'STOP', size: '18', color: BLACK, bgcolor: RED, png64: ICONS.flashRed },
			steps: [{ down: [{ actionId: 'flashRed' }], up: [] }],
			feedbacks: [],
		},
		flashYellow: {
			type: 'button',
			category: 'Flash Signals',
			name: 'Flash Yellow (WARNING)',
			style: { text: 'WARN', size: '18', color: BLACK, bgcolor: YELLOW, png64: ICONS.flashYellow },
			steps: [{ down: [{ actionId: 'flashYellow' }], up: [] }],
			feedbacks: [],
		},
		flashGreen: {
			type: 'button',
			category: 'Flash Signals',
			name: 'Flash Green (GO)',
			style: { text: 'GO', size: '18', color: BLACK, bgcolor: GREEN, png64: ICONS.flashGreen },
			steps: [{ down: [{ actionId: 'flashGreen' }], up: [] }],
			feedbacks: [],
		},

		// === MESSAGES ===
		wrapUp: {
			type: 'button',
			category: 'Messages',
			name: 'WRAP UP',
			style: { text: 'WRAP\\nUP', size: '18', color: WHITE, bgcolor: RED, png64: ICONS.wrapUp },
			steps: [{ down: [{ actionId: 'messageWrapUp' }], up: [] }],
			feedbacks: [],
		},
		standBy: {
			type: 'button',
			category: 'Messages',
			name: 'STAND BY',
			style: { text: 'STAND\\nBY', size: '18', color: WHITE, bgcolor: ORANGE, png64: ICONS.standBy },
			steps: [{ down: [{ actionId: 'messageStandBy' }], up: [] }],
			feedbacks: [],
		},
		thankYou: {
			type: 'button',
			category: 'Messages',
			name: 'THANK YOU',
			style: { text: 'THANK\\nYOU', size: '18', color: BLACK, bgcolor: GREEN, png64: ICONS.message },
			steps: [{ down: [{ actionId: 'messageThankYou' }], up: [] }],
			feedbacks: [],
		},

		// === STAGE MODE ===
		modeTimer: {
			type: 'button',
			category: 'Stage Mode',
			name: 'Timer Mode',
			style: { text: 'TIMER', size: '14', color: WHITE, bgcolor: DARK, png64: ICONS.modeTimer },
			steps: [{ down: [{ actionId: 'modeTimer' }], up: [] }],
			feedbacks: [{ feedbackId: 'modeTimer', style: { bgcolor: ACCENT, color: BLACK } }],
		},
		modeClock: {
			type: 'button',
			category: 'Stage Mode',
			name: 'Clock Mode',
			style: { text: 'CLOCK', size: '14', color: WHITE, bgcolor: DARK, png64: ICONS.modeClock },
			steps: [{ down: [{ actionId: 'modeClock' }], up: [] }],
			feedbacks: [{ feedbackId: 'modeClock', style: { bgcolor: ACCENT, color: BLACK } }],
		},
		modeHold: {
			type: 'button',
			category: 'Stage Mode',
			name: 'Hold Mode',
			style: { text: 'HOLD', size: '14', color: WHITE, bgcolor: DARK, png64: ICONS.modeHold },
			steps: [{ down: [{ actionId: 'modeHold' }], up: [] }],
			feedbacks: [{ feedbackId: 'modeHold', style: { bgcolor: ACCENT, color: BLACK } }],
		},

		// === TIME ADJUST ===
		add1min: {
			type: 'button',
			category: 'Time Adjust',
			name: 'Add 1 Minute',
			style: { text: '+1\\nMIN', size: '18', color: CYAN, bgcolor: CYAN_BG, png64: ICONS.add1min },
			steps: [{ down: [{ actionId: 'add1min' }], up: [] }],
			feedbacks: [],
		},
		add5min: {
			type: 'button',
			category: 'Time Adjust',
			name: 'Add 5 Minutes',
			style: { text: '+5\\nMIN', size: '18', color: CYAN, bgcolor: CYAN_BG, png64: ICONS.add5min },
			steps: [{ down: [{ actionId: 'add5min' }], up: [] }],
			feedbacks: [],
		},
		sub1min: {
			type: 'button',
			category: 'Time Adjust',
			name: 'Subtract 1 Min',
			style: { text: '-1\\nMIN', size: '18', color: ORANGE, bgcolor: combineRgb(50, 25, 0), png64: ICONS.sub1min },
			steps: [{ down: [{ actionId: 'sub1min' }], up: [] }],
			feedbacks: [],
		},
		sub5min: {
			type: 'button',
			category: 'Time Adjust',
			name: 'Subtract 5 Min',
			style: { text: '-5\\nMIN', size: '18', color: ORANGE, bgcolor: combineRgb(50, 25, 0), png64: ICONS.sub5min },
			steps: [{ down: [{ actionId: 'sub5min' }], up: [] }],
			feedbacks: [],
		},

		// === STATUS DISPLAYS (dynamic text via variables) ===
		countdown: {
			type: 'button',
			category: 'Status',
			name: 'Countdown Display',
			style: { text: '$(arc-stage-timer:display_time)', size: '24', color: GREEN, bgcolor: BLACK },
			steps: [],
			feedbacks: [
				{ feedbackId: 'colorNominal', style: { color: GREEN, bgcolor: DARK_GREEN } },
				{ feedbackId: 'colorWarning', style: { color: YELLOW, bgcolor: DARK_YELLOW } },
				{ feedbackId: 'colorDanger', style: { color: RED, bgcolor: DARK_RED } },
				{ feedbackId: 'colorOvertime', style: { color: RED, bgcolor: DARK_RED } },
			],
		},
		cueInfo: {
			type: 'button',
			category: 'Status',
			name: 'Current Cue',
			style: {
				text: '$(arc-stage-timer:cue_position)\\n$(arc-stage-timer:cue_title)',
				size: '14',
				color: WHITE,
				bgcolor: BLACK,
			},
			steps: [],
			feedbacks: [],
		},
		nextCue: {
			type: 'button',
			category: 'Status',
			name: 'Next Cue',
			style: {
				text: 'NEXT:\\n$(arc-stage-timer:next_cue)',
				size: '14',
				color: combineRgb(150, 150, 150),
				bgcolor: BLACK,
			},
			steps: [],
			feedbacks: [],
		},
		offset: {
			type: 'button',
			category: 'Status',
			name: 'Schedule Offset',
			style: {
				text: '$(arc-stage-timer:offset_display)',
				size: '18',
				color: GREEN,
				bgcolor: BLACK,
			},
			steps: [],
			feedbacks: [
				{ feedbackId: 'scheduleBehind', style: { color: YELLOW, bgcolor: DARK_YELLOW } },
				{ feedbackId: 'scheduleWayBehind', style: { color: RED, bgcolor: DARK_RED } },
			],
		},
		overtimeIndicator: {
			type: 'button',
			category: 'Status',
			name: 'Overtime Indicator',
			style: {
				text: '$(arc-stage-timer:is_overtime)',
				size: '14',
				color: RED,
				bgcolor: BLACK,
			},
			steps: [],
			feedbacks: [
				{ feedbackId: 'timerOvertime', style: { bgcolor: DARK_RED, color: RED } },
			],
		},
		durationDisplay: {
			type: 'button',
			category: 'Status',
			name: 'Cue Duration',
			style: {
				text: 'DUR\\n$(arc-stage-timer:duration_display)',
				size: '14',
				color: combineRgb(150, 150, 150),
				bgcolor: BLACK,
			},
			steps: [],
			feedbacks: [],
		},

		// === SCHEDULE ===
		shift: {
			type: 'button',
			category: 'Schedule',
			name: 'Shift Schedule',
			style: { text: 'SHIFT\\nSCHED', size: '14', color: PURPLE, bgcolor: PURPLE_BG, png64: ICONS.shift },
			steps: [{ down: [{ actionId: 'shiftSchedule' }], up: [] }],
			feedbacks: [],
		},
		compress: {
			type: 'button',
			category: 'Schedule',
			name: 'Compress',
			style: { text: 'COMP\\nRESS', size: '14', color: PURPLE, bgcolor: PURPLE_BG, png64: ICONS.compress },
			steps: [{ down: [{ actionId: 'compress' }], up: [] }],
			feedbacks: [],
		},
		undo: {
			type: 'button',
			category: 'Schedule',
			name: 'Undo',
			style: { text: 'UNDO', size: '14', color: combineRgb(150, 150, 150), bgcolor: DARK, png64: ICONS.undo },
			steps: [{ down: [{ actionId: 'undo' }], up: [] }],
			feedbacks: [
				{ feedbackId: 'canUndo', style: { color: WHITE, bgcolor: combineRgb(60, 60, 60) } },
			],
		},
	}

	// === CUE BANK: Go-To Cue buttons 1-32 (for Stream Deck XL) ===
	for (let i = 1; i <= 32; i++) {
		presets[`gotoCue${i}`] = {
			type: 'button',
			category: 'Cue Bank',
			name: `Go To Cue ${i}`,
			style: {
				text: `${i}`,
				size: '18',
				color: WHITE,
				bgcolor: DARK,
			},
			steps: [{ down: [{ actionId: 'goto', options: { cue: i } }], up: [] }],
			feedbacks: [],
		}
	}

	return presets
}
