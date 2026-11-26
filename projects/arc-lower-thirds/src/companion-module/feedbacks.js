import { combineRgb } from '@companion-module/base'

// ARC brand colors
const COLOR = {
	green: combineRgb(0, 200, 83),
	yellow: combineRgb(255, 214, 0),
	red: combineRgb(255, 23, 68),
	liveRed: combineRgb(220, 20, 20),
	blue: combineRgb(41, 121, 255),
	white: combineRgb(255, 255, 255),
	black: combineRgb(0, 0, 0),
	darkGray: combineRgb(30, 30, 30),
	midGray: combineRgb(80, 80, 80),
	accent: combineRgb(0, 176, 255),
	darkRed: combineRgb(40, 0, 0),
	darkGreen: combineRgb(0, 30, 0),
}

export function getFeedbacks(instance) {
	return {
		// MARK: - On Air State

		isOnAir: {
			type: 'boolean',
			name: 'Lower Third On Air',
			description: 'True when a lower third graphic is currently on output',
			defaultStyle: {
				bgcolor: COLOR.liveRed,
				color: COLOR.white,
			},
			options: [],
			callback: () => instance.graphicsState.isOnAir,
		},

		anyLayerOnAir: {
			type: 'boolean',
			name: 'Any Layer On Air',
			description: 'True when any compositing layer has a graphic on air',
			defaultStyle: {
				bgcolor: COLOR.liveRed,
				color: COLOR.white,
			},
			options: [],
			callback: () => instance.graphicsState.anyLayerOnAir,
		},

		allClear: {
			type: 'boolean',
			name: 'All Clear (Nothing On Air)',
			description: 'True when no layers are on air — output is black',
			defaultStyle: {
				bgcolor: COLOR.darkGreen,
				color: COLOR.green,
			},
			options: [],
			callback: () => !instance.graphicsState.anyLayerOnAir,
		},

		// MARK: - Engine State

		stateIdle: {
			type: 'boolean',
			name: 'State: Idle',
			description: 'No show loaded',
			defaultStyle: {
				bgcolor: COLOR.midGray,
				color: COLOR.white,
			},
			options: [],
			callback: () => instance.graphicsState.state === 'idle',
		},

		stateReady: {
			type: 'boolean',
			name: 'State: Ready',
			description: 'Show loaded, standing by',
			defaultStyle: {
				bgcolor: COLOR.darkGreen,
				color: COLOR.green,
			},
			options: [],
			callback: () =>
				instance.graphicsState.state === 'ready' ||
				instance.graphicsState.state === 'preview',
		},

		stateLive: {
			type: 'boolean',
			name: 'State: Live',
			description: 'A graphic is on air',
			defaultStyle: {
				bgcolor: COLOR.liveRed,
				color: COLOR.white,
			},
			options: [],
			callback: () => instance.graphicsState.state === 'live',
		},

		stateClearing: {
			type: 'boolean',
			name: 'State: Clearing',
			description: 'Graphic is animating out',
			defaultStyle: {
				bgcolor: COLOR.yellow,
				color: COLOR.black,
			},
			options: [],
			callback: () => instance.graphicsState.state === 'clearing',
		},

		// MARK: - Layer-Specific Feedbacks

		layerOnAir: {
			type: 'boolean',
			name: 'Specific Layer On Air',
			description: 'Check if a specific compositing layer is on air',
			defaultStyle: {
				bgcolor: COLOR.liveRed,
				color: COLOR.white,
			},
			options: [
				{
					id: 'layer',
					type: 'dropdown',
					label: 'Layer',
					default: 'lowerThird',
					choices: [
						{ id: 'lowerThird', label: 'Lower Third' },
						{ id: 'ticker', label: 'Ticker' },
						{ id: 'logoBug', label: 'Logo Bug' },
						{ id: 'fullTitle', label: 'Full Title' },
						{ id: 'clock', label: 'Clock' },
					],
				},
			],
			callback: (feedback) => {
				const layer = feedback.options.layer
				return layer in instance.graphicsState.activeLayers
			},
		},

		// MARK: - Navigation

		hasNext: {
			type: 'boolean',
			name: 'Has Next Graphic',
			defaultStyle: {
				bgcolor: COLOR.green,
				color: COLOR.black,
			},
			options: [],
			callback: () => instance.graphicsState.hasNext,
		},

		hasPrevious: {
			type: 'boolean',
			name: 'Has Previous Graphic',
			defaultStyle: {
				bgcolor: COLOR.yellow,
				color: COLOR.black,
			},
			options: [],
			callback: () => instance.graphicsState.hasPrevious,
		},

		// MARK: - Graphic Selection

		graphicSelected: {
			type: 'boolean',
			name: 'Specific Graphic Selected',
			description: 'True when a specific graphic number is the current selection',
			defaultStyle: {
				bgcolor: COLOR.accent,
				color: COLOR.black,
			},
			options: [
				{
					id: 'index',
					type: 'number',
					label: 'Graphic Number (1-based)',
					default: 1,
					min: 1,
					max: 100,
				},
			],
			callback: (feedback) => {
				return instance.graphicsState.graphicIndex === (feedback.options.index - 1)
			},
		},
	}
}
