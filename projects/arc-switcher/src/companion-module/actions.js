export function getActions(instance) {
	return {
		// MARK: - Source Switching

		switchByIndex: {
			name: 'Switch Source by Index',
			description: 'Switch to a source by its position (1-based)',
			options: [
				{
					id: 'index',
					type: 'number',
					label: 'Source Index',
					default: 1,
					min: 1,
					max: 8,
				},
			],
			callback: async (action) => {
				await instance.sendCommand('/api/switch', { index: action.options.index })
			},
		},

		switch1: {
			name: 'Switch to Source 1',
			description: 'Instant cut to source 1',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/switch', { index: 1 })
			},
		},

		switch2: {
			name: 'Switch to Source 2',
			description: 'Instant cut to source 2',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/switch', { index: 2 })
			},
		},

		switch3: {
			name: 'Switch to Source 3',
			description: 'Instant cut to source 3',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/switch', { index: 3 })
			},
		},

		switch4: {
			name: 'Switch to Source 4',
			description: 'Instant cut to source 4',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/switch', { index: 4 })
			},
		},

		switch5: {
			name: 'Switch to Source 5',
			description: 'Instant cut to source 5',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/switch', { index: 5 })
			},
		},

		switch6: {
			name: 'Switch to Source 6',
			description: 'Instant cut to source 6',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/switch', { index: 6 })
			},
		},

		switch7: {
			name: 'Switch to Source 7',
			description: 'Instant cut to source 7',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/switch', { index: 7 })
			},
		},

		switch8: {
			name: 'Switch to Source 8',
			description: 'Instant cut to source 8',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/switch', { index: 8 })
			},
		},

		// MARK: - Black Overlay

		black: {
			name: 'Cut to Black',
			description: 'Show black overlay on output display',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/black')
			},
		},

		unblack: {
			name: 'Cut from Black',
			description: 'Remove black overlay',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/unblack')
			},
		},

		toggleBlack: {
			name: 'Toggle Black',
			description: 'Toggle black overlay on/off',
			options: [],
			callback: async () => {
				if (instance.switcherState.isBlack) {
					await instance.sendCommand('/api/unblack')
				} else {
					await instance.sendCommand('/api/black')
				}
			},
		},

		// MARK: - Slide Navigation

		nextSlide: {
			name: 'Next Slide',
			description: 'Advance to next slide on active source',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/next')
			},
		},

		previousSlide: {
			name: 'Previous Slide',
			description: 'Go to previous slide on active source',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/previous')
			},
		},

		// MARK: - Presentation Mode

		startPresentation: {
			name: 'Start Presentation',
			description: 'Enter presentation/fullscreen mode',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/startpresentation')
			},
		},

		stopPresentation: {
			name: 'Stop Presentation',
			description: 'Exit presentation/fullscreen mode',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/stoppresentation')
			},
		},

		// MARK: - Transport

		play: {
			name: 'Play',
			description: 'Play on active source',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/play')
			},
		},

		pause: {
			name: 'Pause',
			description: 'Pause on active source',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/pause')
			},
		},

		stop: {
			name: 'Stop',
			description: 'Stop on active source',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/stop')
			},
		},

		// MARK: - Volume

		volumeUp: {
			name: 'Volume Up',
			description: 'Increase volume on active source',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/volumeup')
			},
		},

		volumeDown: {
			name: 'Volume Down',
			description: 'Decrease volume on active source',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/volumedown')
			},
		},

		mute: {
			name: 'Mute',
			description: 'Mute active source',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/mute')
			},
		},

		// MARK: - Generic Command

		command: {
			name: 'Send Command',
			description: 'Send an arbitrary command to a source',
			options: [
				{
					id: 'action',
					type: 'dropdown',
					label: 'Command',
					default: 'nextSlide',
					choices: [
						{ id: 'nextSlide', label: 'Next Slide' },
						{ id: 'previousSlide', label: 'Previous Slide' },
						{ id: 'startPresentation', label: 'Start Presentation' },
						{ id: 'stopPresentation', label: 'Stop Presentation' },
						{ id: 'play', label: 'Play' },
						{ id: 'pause', label: 'Pause' },
						{ id: 'stop', label: 'Stop' },
						{ id: 'volumeUp', label: 'Volume Up' },
						{ id: 'volumeDown', label: 'Volume Down' },
						{ id: 'mute', label: 'Mute' },
					],
				},
				{
					id: 'sourceIndex',
					type: 'number',
					label: 'Source Index (0 = active)',
					default: 0,
					min: 0,
					max: 8,
				},
			],
			callback: async (action) => {
				const query = { action: action.options.action }
				if (action.options.sourceIndex > 0) {
					const src = instance.switcherState.sources[action.options.sourceIndex - 1]
					if (src) query.source = src.id
				}
				await instance.sendCommand('/api/command', query)
			},
		},
	}
}
