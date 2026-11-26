export function getActions(instance) {
	return {
		// MARK: - Fire / Clear Controls

		fire: {
			name: 'Fire',
			description: 'Send currently selected graphic to air (with animation)',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/fire')
			},
		},

		fireAtIndex: {
			name: 'Fire Graphic by Number',
			description: 'Fire a specific graphic by its number',
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
			callback: async (action) => {
				await instance.sendCommand('/api/fire', { index: action.options.index - 1 })
			},
		},

		fireNext: {
			name: 'Fire + Advance',
			description: 'Fire current graphic and advance selection to next',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/fire-next')
			},
		},

		clear: {
			name: 'Clear',
			description: 'Clear the selected graphic\u2019s layer (animate out)',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/clear')
			},
		},

		clearLayer: {
			name: 'Clear Layer',
			description: 'Clear a specific compositing layer',
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
			callback: async (action) => {
				await instance.sendCommand('/api/clear', { layer: action.options.layer })
			},
		},

		clearAll: {
			name: 'Clear All',
			description: 'Instant cut all layers to black',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/clear-all')
			},
		},

		cut: {
			name: 'Cut to Black',
			description: 'Instant cut lower-third layer (no animation)',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/cut')
			},
		},

		// MARK: - Navigation

		next: {
			name: 'Next Graphic',
			description: 'Select next graphic in list',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/next')
			},
		},

		previous: {
			name: 'Previous Graphic',
			description: 'Select previous graphic in list',
			options: [],
			callback: async () => {
				await instance.sendCommand('/api/previous')
			},
		},

		goto: {
			name: 'Go To Graphic',
			description: 'Select a specific graphic by number',
			options: [
				{
					id: 'graphic',
					type: 'number',
					label: 'Graphic Number (1-based)',
					default: 1,
					min: 1,
					max: 100,
				},
			],
			callback: async (action) => {
				await instance.sendCommand('/api/goto', { graphic: action.options.graphic - 1 })
			},
		},

		select: {
			name: 'Select (Preview Only)',
			description: 'Select graphic for preview without firing',
			options: [
				{
					id: 'graphic',
					type: 'number',
					label: 'Graphic Number (1-based)',
					default: 1,
					min: 1,
					max: 100,
				},
			],
			callback: async (action) => {
				await instance.sendCommand('/api/select', { graphic: action.options.graphic - 1 })
			},
		},

		// MARK: - Fire on Layer

		fireOnLayer: {
			name: 'Fire on Layer',
			description: 'Fire a specific graphic on a specific layer',
			options: [
				{
					id: 'index',
					type: 'number',
					label: 'Graphic Number (1-based)',
					default: 1,
					min: 1,
					max: 100,
				},
				{
					id: 'layer',
					type: 'dropdown',
					label: 'Target Layer',
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
			callback: async (action) => {
				await instance.sendCommand('/api/fire', {
					index: action.options.index - 1,
					layer: action.options.layer,
				})
			},
		},

		// MARK: - Encoder Actions (Stream Deck+ rotary encoders)

		encoderNavigate: {
			name: 'Encoder: Navigate Graphics',
			description: 'Rotate to browse graphics, press to fire (Stream Deck+ encoder)',
			options: [],
			callback: async () => {
				// Press action: fire current graphic
				await instance.sendCommand('/api/fire')
			},
		},

		encoderFireClear: {
			name: 'Encoder: Fire/Clear',
			description: 'Rotate to navigate, press to toggle fire/clear (Stream Deck+ encoder)',
			options: [],
			callback: async () => {
				// Press: toggle — if on air, clear; otherwise fire
				if (instance.graphicsState.isOnAir) {
					await instance.sendCommand('/api/clear')
				} else {
					await instance.sendCommand('/api/fire')
				}
			},
		},
	}
}
