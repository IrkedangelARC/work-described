export function getActions(instance) {
	return {
		// MARK: - Transport Controls

		play: {
			name: 'Play',
			description: 'Start the timer',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/play')
			},
		},

		pause: {
			name: 'Pause',
			description: 'Pause the timer',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/pause')
			},
		},

		toggle: {
			name: 'Play / Pause Toggle',
			description: 'Toggle between play and pause',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/toggle')
			},
		},

		stop: {
			name: 'Stop',
			description: 'Stop the show and reset',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/reset')
			},
		},

		// MARK: - Navigation

		next: {
			name: 'Next Cue',
			description: 'Advance to next cue',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/next')
			},
		},

		previous: {
			name: 'Previous Cue',
			description: 'Go to previous cue',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/previous')
			},
		},

		goto: {
			name: 'Go To Cue',
			description: 'Jump to a specific cue by number',
			options: [
				{
					id: 'cue',
					type: 'number',
					label: 'Cue Number (1-based)',
					default: 1,
					min: 1,
					max: 100,
				},
			],
			callback: async (action) => {
				await instance.sendCommand('/api/goto', { cue: action.options.cue - 1 })
			},
		},

		reset: {
			name: 'Reset Cue',
			description: 'Reset elapsed time on current cue',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/reset')
			},
		},

		// MARK: - Time Adjustments

		addTime: {
			name: 'Add Time',
			description: 'Add seconds to current cue duration',
			options: [
				{
					id: 'seconds',
					type: 'number',
					label: 'Seconds to Add',
					default: 60,
					min: 1,
					max: 3600,
				},
			],
			callback: async (action) => {
				await instance.sendCommand('/api/addtime', { seconds: action.options.seconds })
			},
		},

		subtractTime: {
			name: 'Subtract Time',
			description: 'Remove seconds from current cue duration',
			options: [
				{
					id: 'seconds',
					type: 'number',
					label: 'Seconds to Remove',
					default: 60,
					min: 1,
					max: 3600,
				},
			],
			callback: async (action) => {
				await instance.sendCommand('/api/subtracttime', { seconds: action.options.seconds })
			},
		},

		add1min: {
			name: 'Add 1 Minute',
			description: 'Add 60 seconds to current cue',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/addtime', { seconds: 60 })
			},
		},

		add5min: {
			name: 'Add 5 Minutes',
			description: 'Add 5 minutes to current cue',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/addtime', { seconds: 300 })
			},
		},

		sub1min: {
			name: 'Subtract 1 Minute',
			description: 'Remove 60 seconds from current cue',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/subtracttime', { seconds: 60 })
			},
		},

		sub5min: {
			name: 'Subtract 5 Minutes',
			description: 'Remove 5 minutes from current cue',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/subtracttime', { seconds: 300 })
			},
		},

		// MARK: - Stage Display

		flash: {
			name: 'Flash',
			description: 'Flash the stage display with a color',
			options: [
				{
					id: 'color',
					type: 'dropdown',
					label: 'Flash Color',
					default: 'red',
					choices: [
						{ id: 'red', label: 'Red' },
						{ id: 'yellow', label: 'Yellow' },
						{ id: 'green', label: 'Green' },
						{ id: 'white', label: 'White' },
						{ id: 'blue', label: 'Blue' },
					],
				},
			],
			callback: async (action) => {
				await instance.sendCommand('/api/flash', { color: action.options.color })
			},
		},

		flashRed: {
			name: 'Flash Red',
			description: 'Flash stage display red (STOP / WRAP UP)',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/flash', { color: 'red' })
			},
		},

		flashYellow: {
			name: 'Flash Yellow',
			description: 'Flash stage display yellow (WARNING)',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/flash', { color: 'yellow' })
			},
		},

		flashGreen: {
			name: 'Flash Green',
			description: 'Flash stage display green (GO / OK)',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/flash', { color: 'green' })
			},
		},

		message: {
			name: 'Send Message',
			description: 'Display a message on stage display',
			options: [
				{
					id: 'text',
					type: 'textinput',
					label: 'Message Text',
					default: '',
				},
			],
			callback: async (action) => {
				if (action.options.text) {
					await instance.sendCommand('/api/message', { text: action.options.text })
				}
			},
		},

		messageWrapUp: {
			name: 'Message: WRAP UP',
			description: 'Send "WRAP UP" to stage display',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/message', { text: 'WRAP UP' })
			},
		},

		messageStandBy: {
			name: 'Message: STAND BY',
			description: 'Send "STAND BY" to stage display',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/message', { text: 'STAND BY' })
			},
		},

		messageThankYou: {
			name: 'Message: THANK YOU',
			description: 'Send "THANK YOU" to stage display',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/message', { text: 'THANK YOU' })
			},
		},

		// MARK: - Stage Mode

		modeTimer: {
			name: 'Mode: Timer',
			description: 'Switch stage to timer display',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/timer')
			},
		},

		modeClock: {
			name: 'Mode: Clock',
			description: 'Switch stage to clock display',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/clock')
			},
		},

		modeHold: {
			name: 'Mode: Hold',
			description: 'Switch stage to hold screen',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/hold')
			},
		},

		// MARK: - Schedule

		shiftSchedule: {
			name: 'Shift Schedule',
			description: 'Shift remaining schedule to start from now',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/shift')
			},
		},

		compress: {
			name: 'Compress Schedule',
			description: 'Automatically compress remaining cues to recover time',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/compress')
			},
		},

		// MARK: - Undo

		undo: {
			name: 'Undo',
			description: 'Undo last action',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/undo')
			},
		},

		// MARK: - Encoder Actions (Stream Deck+ rotary encoders)

		encoderTimeAdjust: {
			name: 'Encoder: Adjust Time',
			description: 'Rotate to add/subtract time (Stream Deck+ encoder)',
			options: [
				{
					id: 'step',
					type: 'number',
					label: 'Seconds per click',
					default: 15,
					min: 1,
					max: 300,
				},
			],
			callback: async (action) => {
				// Press action: reset cue
				await instance.sendCommand('/api/reset')
			},
		},

		encoderCueNavigate: {
			name: 'Encoder: Navigate Cues',
			description: 'Rotate to navigate between cues (Stream Deck+ encoder)',
			options: [],
			callback: async () => {
				// Press action: toggle play/pause
				await instance.sendCommand('/api/toggle')
			},
		},
	}
}
