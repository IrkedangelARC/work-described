import { InstanceBase, combineRgb } from '@companion-module/base'
import { getActions } from './actions.js'
import { getFeedbacks } from './feedbacks.js'
import { getPresets } from './presets.js'

class ArcSwitcherInstance extends InstanceBase {
	// Switcher state from polling
	switcherState = {
		activeSource: null,
		isBlack: false,
		sources: [],
		serverPort: 9090,
	}

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
				label: 'Switcher Host IP',
				width: 8,
				default: '127.0.0.1',
				required: true,
			},
			{
				type: 'number',
				id: 'port',
				label: 'Port',
				width: 4,
				default: 9090,
				min: 1,
				max: 65535,
			},
			{
				type: 'number',
				id: 'pollInterval',
				label: 'Poll Interval (ms)',
				width: 4,
				default: 500,
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
		const port = this.config?.port || 9090
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
		const interval = this.config?.pollInterval || 500
		this.pollTimer = setInterval(() => this.poll(), interval)
		this.poll()
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

	processState(json) {
		if (!json?.ok) return

		const prev = this.switcherState
		const sources = json.sources || []

		const changed =
			prev.activeSource !== json.activeSource ||
			prev.isBlack !== json.isBlack ||
			prev.sources.length !== sources.length ||
			sources.some((s, i) => {
				const p = prev.sources[i]
				return !p || p.id !== s.id || p.available !== s.available || p.isActive !== s.isActive
			})

		this.switcherState = {
			activeSource: json.activeSource || null,
			isBlack: json.isBlack || false,
			sources: sources,
			serverPort: json.serverPort || 9090,
		}

		// Active source info
		const active = sources.find((s) => s.isActive)
		const activeIndex = active ? sources.indexOf(active) + 1 : 0

		const vars = {
			active_source_name: active?.name || 'NONE',
			active_source_index: activeIndex,
			source_count: sources.length,
			is_black: this.switcherState.isBlack ? 'BLACK' : '',
		}

		// Per-source variables (up to 8)
		for (let i = 0; i < 8; i++) {
			const src = sources[i]
			vars[`source_${i + 1}_name`] = src?.name || ''
			vars[`source_${i + 1}_available`] = src?.available ? 'ON' : 'OFF'
			vars[`source_${i + 1}_active`] = src?.isActive ? 'LIVE' : ''
		}

		this.setVariableValues(vars)

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
			{ variableId: 'active_source_name', name: 'Active Source Name' },
			{ variableId: 'active_source_index', name: 'Active Source Index (1-based)' },
			{ variableId: 'source_count', name: 'Total Source Count' },
			{ variableId: 'is_black', name: 'Black Overlay State' },
		]

		for (let i = 1; i <= 8; i++) {
			vars.push({ variableId: `source_${i}_name`, name: `Source ${i} Name` })
			vars.push({ variableId: `source_${i}_available`, name: `Source ${i} Available` })
			vars.push({ variableId: `source_${i}_active`, name: `Source ${i} Active` })
		}

		this.setVariableDefinitions(vars)
	}
}

export default ArcSwitcherInstance
