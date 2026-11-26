import { combineRgb } from '@companion-module/base'

const COLOR = {
	red: combineRgb(255, 23, 68),
	green: combineRgb(0, 200, 83),
	yellow: combineRgb(255, 214, 0),
	white: combineRgb(255, 255, 255),
	black: combineRgb(0, 0, 0),
	darkGray: combineRgb(30, 30, 30),
	midGray: combineRgb(80, 80, 80),
	accent: combineRgb(0, 176, 255),
	darkRed: combineRgb(40, 0, 0),
	darkGreen: combineRgb(0, 30, 0),
}

export function getFeedbacks(instance) {
	const feedbacks = {
		// MARK: - Black State

		isBlack: {
			type: 'boolean',
			name: 'Black Overlay Active',
			description: 'True when black overlay is showing on output',
			defaultStyle: {
				bgcolor: COLOR.red,
				color: COLOR.white,
			},
			options: [],
			callback: () => instance.switcherState.isBlack,
		},

		notBlack: {
			type: 'boolean',
			name: 'Black Overlay Inactive',
			description: 'True when output is live (not blacked out)',
			defaultStyle: {
				bgcolor: COLOR.green,
				color: COLOR.black,
			},
			options: [],
			callback: () => !instance.switcherState.isBlack,
		},

		// MARK: - Active Source

		hasActiveSource: {
			type: 'boolean',
			name: 'Has Active Source',
			description: 'True when any source is currently live',
			defaultStyle: {
				bgcolor: COLOR.green,
				color: COLOR.black,
			},
			options: [],
			callback: () => instance.switcherState.activeSource !== null,
		},

		noActiveSource: {
			type: 'boolean',
			name: 'No Active Source',
			description: 'True when no source is live',
			defaultStyle: {
				bgcolor: COLOR.midGray,
				color: COLOR.white,
			},
			options: [],
			callback: () => instance.switcherState.activeSource === null,
		},
	}

	// Per-source feedbacks (1-8)
	for (let i = 1; i <= 8; i++) {
		feedbacks[`source${i}Active`] = {
			type: 'boolean',
			name: `Source ${i} is Live`,
			description: `True when source ${i} is the active/live source`,
			defaultStyle: {
				bgcolor: COLOR.red,
				color: COLOR.white,
			},
			options: [],
			callback: () => {
				const src = instance.switcherState.sources[i - 1]
				return src?.isActive || false
			},
		}

		feedbacks[`source${i}Available`] = {
			type: 'boolean',
			name: `Source ${i} Available`,
			description: `True when source ${i} app is running and available`,
			defaultStyle: {
				bgcolor: COLOR.darkGreen,
				color: COLOR.green,
			},
			options: [],
			callback: () => {
				const src = instance.switcherState.sources[i - 1]
				return src?.available || false
			},
		}

		feedbacks[`source${i}Unavailable`] = {
			type: 'boolean',
			name: `Source ${i} Unavailable`,
			description: `True when source ${i} app is not running`,
			defaultStyle: {
				bgcolor: COLOR.darkRed,
				color: COLOR.red,
			},
			options: [],
			callback: () => {
				const src = instance.switcherState.sources[i - 1]
				return src ? !src.available : false
			},
		}
	}

	return feedbacks
}
