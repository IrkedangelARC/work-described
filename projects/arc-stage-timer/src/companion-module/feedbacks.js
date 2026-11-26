import { combineRgb } from '@companion-module/base'

// ARC brand colors
const COLOR = {
	green: combineRgb(0, 200, 83),
	yellow: combineRgb(255, 214, 0),
	red: combineRgb(255, 23, 68),
	blue: combineRgb(41, 121, 255),
	white: combineRgb(255, 255, 255),
	black: combineRgb(0, 0, 0),
	darkGray: combineRgb(30, 30, 30),
	midGray: combineRgb(80, 80, 80),
	accent: combineRgb(0, 176, 255),
	darkRed: combineRgb(40, 0, 0),
	darkGreen: combineRgb(0, 30, 0),
	darkYellow: combineRgb(40, 35, 0),
	orange: combineRgb(255, 111, 0),
}

export function getFeedbacks(instance) {
	return {
		// MARK: - Timer State Feedbacks

		timerRunning: {
			type: 'boolean',
			name: 'Timer is Running',
			description: 'True when timer is actively counting down',
			defaultStyle: {
				bgcolor: COLOR.green,
				color: COLOR.black,
			},
			options: [],
			callback: () => instance.timerState.state === 'running',
		},

		timerPaused: {
			type: 'boolean',
			name: 'Timer is Paused',
			description: 'True when timer is paused',
			defaultStyle: {
				bgcolor: COLOR.yellow,
				color: COLOR.black,
			},
			options: [],
			callback: () => instance.timerState.state === 'paused',
		},

		timerIdle: {
			type: 'boolean',
			name: 'Timer is Idle',
			description: 'True when timer has not started',
			defaultStyle: {
				bgcolor: COLOR.midGray,
				color: COLOR.white,
			},
			options: [],
			callback: () => instance.timerState.state === 'idle',
		},

		timerOvertime: {
			type: 'boolean',
			name: 'Timer is in Overtime',
			description: 'True when current cue is past its duration',
			defaultStyle: {
				bgcolor: COLOR.red,
				color: COLOR.white,
			},
			options: [],
			callback: () => instance.timerState.isOvertime,
		},

		timerFinished: {
			type: 'boolean',
			name: 'Timer is Finished',
			description: 'True when show has completed all cues',
			defaultStyle: {
				bgcolor: COLOR.midGray,
				color: COLOR.white,
			},
			options: [],
			callback: () => instance.timerState.state === 'finished',
		},

		// MARK: - Color State Feedbacks (use for countdown display)

		colorNominal: {
			type: 'boolean',
			name: 'Color: Nominal (Green)',
			description: 'Plenty of time remaining',
			defaultStyle: {
				bgcolor: COLOR.darkGreen,
				color: COLOR.green,
			},
			options: [],
			callback: () => instance.timerState.colorState === 'nominal',
		},

		colorWarning: {
			type: 'boolean',
			name: 'Color: Warning (Yellow)',
			description: 'Warning threshold reached',
			defaultStyle: {
				bgcolor: COLOR.darkYellow,
				color: COLOR.yellow,
			},
			options: [],
			callback: () => instance.timerState.colorState === 'warning',
		},

		colorDanger: {
			type: 'boolean',
			name: 'Color: Danger (Red)',
			description: 'Danger threshold reached — almost out of time',
			defaultStyle: {
				bgcolor: COLOR.darkRed,
				color: COLOR.red,
			},
			options: [],
			callback: () => instance.timerState.colorState === 'danger',
		},

		colorOvertime: {
			type: 'boolean',
			name: 'Color: Overtime (Red)',
			description: 'Past cue duration',
			defaultStyle: {
				bgcolor: COLOR.darkRed,
				color: COLOR.red,
			},
			options: [],
			callback: () => instance.timerState.colorState === 'overtime',
		},

		// MARK: - Stage Mode Feedbacks

		modeTimer: {
			type: 'boolean',
			name: 'Stage Mode: Timer',
			description: 'Stage display is showing timer',
			defaultStyle: {
				bgcolor: COLOR.accent,
				color: COLOR.black,
			},
			options: [],
			callback: () => instance.timerState.stageMode === 'timer',
		},

		modeClock: {
			type: 'boolean',
			name: 'Stage Mode: Clock',
			description: 'Stage display is showing clock',
			defaultStyle: {
				bgcolor: COLOR.accent,
				color: COLOR.black,
			},
			options: [],
			callback: () => instance.timerState.stageMode === 'clock',
		},

		modeHold: {
			type: 'boolean',
			name: 'Stage Mode: Hold',
			description: 'Stage display is showing hold screen',
			defaultStyle: {
				bgcolor: COLOR.accent,
				color: COLOR.black,
			},
			options: [],
			callback: () => instance.timerState.stageMode === 'hold',
		},

		// MARK: - Schedule Offset

		scheduleOnTime: {
			type: 'boolean',
			name: 'Schedule: On Time',
			defaultStyle: {
				bgcolor: COLOR.darkGreen,
				color: COLOR.green,
			},
			options: [],
			callback: () =>
				instance.timerState.offsetStatus === 'onTime' ||
				instance.timerState.offsetStatus === 'ahead',
		},

		scheduleBehind: {
			type: 'boolean',
			name: 'Schedule: Behind',
			defaultStyle: {
				bgcolor: COLOR.darkYellow,
				color: COLOR.yellow,
			},
			options: [],
			callback: () => instance.timerState.offsetStatus === 'behind',
		},

		scheduleWayBehind: {
			type: 'boolean',
			name: 'Schedule: Way Behind',
			defaultStyle: {
				bgcolor: COLOR.darkRed,
				color: COLOR.red,
			},
			options: [],
			callback: () => instance.timerState.offsetStatus === 'wayBehind',
		},

		// MARK: - Navigation State

		hasNext: {
			type: 'boolean',
			name: 'Has Next Cue',
			description: 'True when there is a next cue available',
			defaultStyle: {
				bgcolor: COLOR.green,
				color: COLOR.black,
			},
			options: [],
			callback: () => instance.timerState.hasNext,
		},

		hasPrevious: {
			type: 'boolean',
			name: 'Has Previous Cue',
			description: 'True when there is a previous cue',
			defaultStyle: {
				bgcolor: COLOR.yellow,
				color: COLOR.black,
			},
			options: [],
			callback: () => instance.timerState.hasPrevious,
		},

		canUndo: {
			type: 'boolean',
			name: 'Can Undo',
			description: 'True when an undo action is available',
			defaultStyle: {
				bgcolor: COLOR.accent,
				color: COLOR.black,
			},
			options: [],
			callback: () => instance.timerState.canUndo,
		},
	}
}
