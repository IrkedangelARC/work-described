import { InstanceBase, combineRgb } from '@companion-module/base'
import { getActions } from './actions.js'
import { getFeedbacks } from './feedbacks.js'
import { getPresets } from './presets.js'

class ArcLowerThirdsInstance extends InstanceBase {
	// Graphics state from polling
	graphicsState = {
		state: 'idle',
		graphicIndex: 0,
		line1: '',
		line2: '',
		line3: '',
		graphicCount: 0,
		isOnAir: false,
		anyLayerOnAir: false,
		hasNext: false,
		hasPrevious: false,
		graphicType: 'lowerThird',
		accentColor: '#33D9F5',
		animation: 'slideFromLeft',
		activeLayers: {},
	}

	// Full graphics list (fetched once + on count change)
	graphicsList = []

	pollTimer = null

	async init(config) {
		this.config = config
		this.updateStatus('connecting')
		this.setupActions()
		this.setupFeedbacks()
		this.setupPresets()
		this.setupVariables()
		this.startPolling()
	}

	async destroy() {
		this.stopPolling()
	}

	getConfigFields() {
		return [
			{
				type: 'textinput',
				id: 'host',
				label: 'Lower Thirds Host IP',
				width: 8,
				default: '127.0.0.1',
				required: true,
			},
			{
				type: 'number',
				id: 'port',
				label: 'Port',
				width: 4,
				default: 8080,
				min: 1,
				max: 65535,
			},
			{
				type: 'number',
				id: 'pollInterval',
				label: 'Poll Interval (ms)',
				width: 4,
				default: 250,
				min: 100,
				max: 5000,
			},
		]
	}

	async configUpdated(config) {
		this.config = config
		this.stopPolling()
		this.startPolling()
	}

	// MARK: - HTTP Helpers

	baseUrl() {
		const host = this.config?.host || '127.0.0.1'
		const port = this.config?.port || 8080
		return `http://${host}:${port}`
	}

	async sendCommand(path, query = {}) {
		let url = `${this.baseUrl()}${path}`
		const params = Object.entries(query)
			.map(([k, v]) => `${k}=${encodeURIComponent(v)}`)
			.join('&')
		if (params) url += `?${params}`

		try {
			const controller = new AbortController()
			const timeout = setTimeout(() => controller.abort(), 3000)
			const res = await fetch(url, { signal: controller.signal })
			clearTimeout(timeout)
			const json = await res.json()
			this.processState(json)
			return json
		} catch (e) {
			this.updateStatus('connection_failure')
			return null
		}
	}

	// MARK: - Polling

	startPolling() {
		const interval = this.config?.pollInterval || 250
		this.pollTimer = setInterval(() => this.poll(), interval)
		this.poll()
		this.fetchGraphicsList()
	}

	stopPolling() {
		if (this.pollTimer) {
			clearInterval(this.pollTimer)
			this.pollTimer = null
		}
	}

	async poll() {
		const result = await this.sendCommand('/api/status')
		if (result?.ok) {
			this.updateStatus('ok')
		}
	}

	async fetchGraphicsList() {
		try {
			const controller = new AbortController()
			const timeout = setTimeout(() => controller.abort(), 3000)
			const res = await fetch(`${this.baseUrl()}/api/show`, { signal: controller.signal })
			clearTimeout(timeout)
			const json = await res.json()
			if (json?.ok && json.graphics) {
				this.graphicsList = json.graphics
				// Update per-graphic variables
				const vars = {}
				for (let i = 0; i < Math.min(json.graphics.length, 32); i++) {
					vars[`graphic_${i + 1}_name`] = json.graphics[i].line1 || ''
				}
				vars['show_name'] = json.showName || ''
				this.setVariableValues(vars)
			}
		} catch (e) {
			// Non-critical — status polling handles connection state
		}
	}

	processState(json) {
		if (!json?.ok) return

		const prevCount = this.graphicsState.graphicCount

		const changed =
			this.graphicsState.state !== json.state ||
			this.graphicsState.graphicIndex !== json.graphicIndex ||
			this.graphicsState.isOnAir !== json.isOnAir ||
			this.graphicsState.anyLayerOnAir !== json.anyLayerOnAir

		this.graphicsState = {
			state: json.state || 'idle',
			graphicIndex: json.graphicIndex || 0,
			line1: json.line1 || '',
			line2: json.line2 || '',
			line3: json.line3 || '',
			graphicCount: json.graphicCount || 0,
			isOnAir: json.isOnAir || false,
			anyLayerOnAir: json.anyLayerOnAir || false,
			hasNext: json.hasNext || false,
			hasPrevious: json.hasPrevious || false,
			graphicType: json.graphicType || 'lowerThird',
			accentColor: json.accentColor || '#33D9F5',
			animation: json.animation || 'slideFromLeft',
			activeLayers: json.activeLayers || {},
		}

		// Build active layers display string
		const activeLayerNames = Object.keys(this.graphicsState.activeLayers)
		const layersDisplay = activeLayerNames.length > 0
			? activeLayerNames.map(l => l.toUpperCase()).join(' | ')
			: 'CLEAR'

		this.setVariableValues({
			state: this.graphicsState.state,
			graphic_index: this.graphicsState.graphicIndex + 1,
			graphic_count: this.graphicsState.graphicCount,
			graphic_position: `${this.graphicsState.graphicIndex + 1}/${this.graphicsState.graphicCount}`,
			line1: this.graphicsState.line1,
			line2: this.graphicsState.line2,
			line3: this.graphicsState.line3,
			is_on_air: this.graphicsState.isOnAir ? 'ON AIR' : '',
			any_on_air: this.graphicsState.anyLayerOnAir ? 'ON AIR' : 'CLEAR',
			active_layers: layersDisplay,
			graphic_type: this.graphicsState.graphicType,
			accent_color: this.graphicsState.accentColor,
		})

		// Refresh graphics list when count changes
		if (json.graphicCount !== prevCount) {
			this.fetchGraphicsList()
		}

		if (changed) {
			this.checkFeedbacks()
		}
	}

	// MARK: - Setup

	setupActions() {
		this.setActionDefinitions(getActions(this))
	}

	setupFeedbacks() {
		this.setFeedbackDefinitions(getFeedbacks(this))
	}

	setupPresets() {
		this.setPresetDefinitions(getPresets(this))
	}

	setupVariables() {
		const vars = [
			{ variableId: 'state', name: 'Engine State' },
			{ variableId: 'graphic_index', name: 'Current Graphic # (1-based)' },
			{ variableId: 'graphic_count', name: 'Total Graphic Count' },
			{ variableId: 'graphic_position', name: 'Position (N/M)' },
			{ variableId: 'line1', name: 'Current Line 1 (Name)' },
			{ variableId: 'line2', name: 'Current Line 2 (Title)' },
			{ variableId: 'line3', name: 'Current Line 3 (Org)' },
			{ variableId: 'is_on_air', name: 'Lower Third On Air' },
			{ variableId: 'any_on_air', name: 'Any Layer On Air' },
			{ variableId: 'active_layers', name: 'Active Layers' },
			{ variableId: 'graphic_type', name: 'Graphic Type' },
			{ variableId: 'accent_color', name: 'Accent Color (hex)' },
			{ variableId: 'show_name', name: 'Show Name' },
		]

		// Per-graphic name variables (1-32 for XL cue bank)
		for (let i = 1; i <= 32; i++) {
			vars.push({ variableId: `graphic_${i}_name`, name: `Graphic ${i} Name` })
		}

		this.setVariableDefinitions(vars)
	}
}

export default ArcLowerThirdsInstance
