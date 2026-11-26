import { InstanceBase, combineRgb } from '@companion-module/base'
import { getActions } from './actions.js'
import { getFeedbacks } from './feedbacks.js'
import { getPresets } from './presets.js'

class ArcStageTimerInstance extends InstanceBase {
	// Timer state from polling
	timerState = {
		state: 'idle',
		cueIndex: 0,
		cueTitle: '',
		cueSubtitle: '',
		cueSpeakers: '',
		displayTime: '00:00',
		remainingSeconds: 0,
		elapsedSeconds: 0,
		durationSeconds: 0,
		isOvertime: false,
		progress: 0,
		colorState: 'idle',
		hasNext: false,
		hasPrevious: false,
		cueCount: 0,
		stageMode: 'timer',
		nextCueTitle: '',
		canUndo: false,
		showOffsetDisplay: 'ON TIME',
		offsetStatus: 'onTime',
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
				label: 'Timer Host IP',
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

		const changed =
			this.timerState.state !== json.state ||
			this.timerState.displayTime !== json.displayTime ||
			this.timerState.cueIndex !== json.cueIndex ||
			this.timerState.colorState !== json.colorState ||
			this.timerState.stageMode !== json.stageMode ||
			this.timerState.isOvertime !== json.isOvertime

		this.timerState = {
			state: json.state || 'idle',
			cueIndex: json.cueIndex || 0,
			cueTitle: json.cueTitle || '',
			cueSubtitle: json.cueSubtitle || '',
			cueSpeakers: json.cueSpeakers || '',
			displayTime: json.displayTime || '00:00',
			remainingSeconds: json.remainingSeconds || 0,
			elapsedSeconds: json.elapsedSeconds || 0,
			durationSeconds: json.durationSeconds || 0,
			isOvertime: json.isOvertime || false,
			progress: json.progress || 0,
			colorState: json.colorState || 'idle',
			hasNext: json.hasNext || false,
			hasPrevious: json.hasPrevious || false,
			cueCount: json.cueCount || 0,
			stageMode: json.stageMode || 'timer',
			nextCueTitle: json.nextCueTitle || '',
			canUndo: json.canUndo || false,
			showOffsetDisplay: json.showOffsetDisplay || 'ON TIME',
			offsetStatus: json.offsetStatus || 'onTime',
		}

		// Format progress as percentage
		const progressPct = Math.round(this.timerState.progress * 100)

		// Format duration as MM:SS
		const durMin = Math.floor(this.timerState.durationSeconds / 60)
		const durSec = this.timerState.durationSeconds % 60
		const durationDisplay = `${durMin}:${String(durSec).padStart(2, '0')}`

		this.setVariableValues({
			display_time: this.timerState.displayTime,
			cue_title: this.timerState.cueTitle,
			cue_subtitle: this.timerState.cueSubtitle,
			cue_speakers: this.timerState.cueSpeakers,
			cue_index: this.timerState.cueIndex + 1,
			cue_count: this.timerState.cueCount,
			cue_position: `${this.timerState.cueIndex + 1}/${this.timerState.cueCount}`,
			next_cue: this.timerState.nextCueTitle,
			timer_state: this.timerState.state,
			color_state: this.timerState.colorState,
			stage_mode: this.timerState.stageMode,
			is_overtime: this.timerState.isOvertime ? 'OVERTIME' : '',
			remaining_seconds: this.timerState.remainingSeconds,
			elapsed_seconds: this.timerState.elapsedSeconds,
			duration_seconds: this.timerState.durationSeconds,
			duration_display: durationDisplay,
			progress: progressPct,
			offset_display: this.timerState.showOffsetDisplay,
			offset_status: this.timerState.offsetStatus,
		})

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
		this.setVariableDefinitions([
			{ variableId: 'display_time', name: 'Display Time (countdown)' },
			{ variableId: 'cue_title', name: 'Current Cue Title' },
			{ variableId: 'cue_subtitle', name: 'Current Cue Subtitle' },
			{ variableId: 'cue_speakers', name: 'Current Cue Speakers' },
			{ variableId: 'cue_index', name: 'Current Cue # (1-based)' },
			{ variableId: 'cue_count', name: 'Total Cue Count' },
			{ variableId: 'cue_position', name: 'Cue Position (N/M)' },
			{ variableId: 'next_cue', name: 'Next Cue Title' },
			{ variableId: 'timer_state', name: 'Timer State' },
			{ variableId: 'color_state', name: 'Color State' },
			{ variableId: 'stage_mode', name: 'Stage Mode' },
			{ variableId: 'is_overtime', name: 'Overtime Indicator' },
			{ variableId: 'remaining_seconds', name: 'Remaining Seconds' },
			{ variableId: 'elapsed_seconds', name: 'Elapsed Seconds' },
			{ variableId: 'duration_seconds', name: 'Cue Duration (seconds)' },
			{ variableId: 'duration_display', name: 'Cue Duration (MM:SS)' },
			{ variableId: 'progress', name: 'Progress (0-100%)' },
			{ variableId: 'offset_display', name: 'Schedule Offset' },
			{ variableId: 'offset_status', name: 'Offset Status' },
		])
	}
}

export default ArcStageTimerInstance
