#!/usr/bin/env python3
#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""ARC Field Tools — Real-Time Audio Analyzer Server

Captures audio from USB interface, runs FFT analysis via AudioAnalyzer,
streams results to browser clients over WebSocket at ~30fps.

Usage:
    python server.py [--device DEVICE_INDEX] [--port 5050]

Open browser to http://localhost:5050 (or from any device on same LAN).
"""

import sys
import os
import argparse
import json
import threading
import time

import numpy as np
import sounddevice as sd
from flask import Flask, render_template, jsonify
from flask_socketio import SocketIO

# Import AudioAnalyzer from arc-playground
sys.path.insert(0, os.path.expanduser('~/projects/arc-playground'))
try:
    from audio.analyzer import AudioAnalyzer
except ImportError:
    print("ERROR: Cannot import AudioAnalyzer from ~/projects/arc-playground/audio/analyzer.py")
    print("Make sure arc-playground exists with the audio analyzer module.")
    sys.exit(1)

app = Flask(__name__)
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='threading')

# Audio configuration
SAMPLE_RATE = 44100
BUFFER_SIZE = 2048
DOWNSAMPLE_SPECTRUM = 256  # Send 256 bins to browser (bandwidth-friendly)

analyzer = AudioAnalyzer(sample_rate=SAMPLE_RATE, buffer_size=BUFFER_SIZE)
audio_stream = None
stream_active = False


def audio_callback(indata, frames, time_info, status):
    """Called by sounddevice for each audio buffer."""
    if status:
        print(f"Audio status: {status}", file=sys.stderr)

    try:
        features = analyzer.analyze(indata)

        # Downsample spectrum for network efficiency
        spectrum = features.spectrum
        if len(spectrum) > DOWNSAMPLE_SPECTRUM:
            # Average bins to reduce size
            chunk = len(spectrum) // DOWNSAMPLE_SPECTRUM
            spectrum = np.mean(
                spectrum[:chunk * DOWNSAMPLE_SPECTRUM].reshape(-1, chunk), axis=1
            )

        # Normalize spectrum to 0-1 range for visualization
        spec_max = np.max(spectrum) if np.max(spectrum) > 0 else 1
        spectrum_normalized = (spectrum / spec_max).tolist()

        data = {
            'spectrum': spectrum_normalized,
            'bands': [
                float(features.sub_bass),
                float(features.bass),
                float(features.low_mid),
                float(features.mid),
                float(features.high_mid),
                float(features.presence),
                float(features.brilliance)
            ],
            'db': float(features.db),
            'peak': float(features.peak),
            'dominant_freq': float(features.dominant_freq),
            'is_beat': bool(features.is_beat),
            'tempo': float(features.tempo) if hasattr(features, 'tempo') else 0,
        }

        socketio.emit('audio_data', data)
    except Exception as e:
        print(f"Analysis error: {e}", file=sys.stderr)


@app.route('/')
def index():
    return render_template('index.html')


@app.route('/devices')
def list_devices():
    """List available audio input devices."""
    devices = sd.query_devices()
    inputs = []
    for i, d in enumerate(devices):
        if d['max_input_channels'] > 0:
            inputs.append({
                'index': i,
                'name': d['name'],
                'channels': d['max_input_channels'],
                'sample_rate': d['default_samplerate']
            })
    return jsonify(inputs)


@socketio.on('start_stream')
def handle_start(data=None):
    """Start audio capture."""
    global audio_stream, stream_active

    if stream_active:
        return

    device_index = data.get('device') if data else None

    try:
        audio_stream = sd.InputStream(
            device=device_index,
            channels=1,
            samplerate=SAMPLE_RATE,
            blocksize=BUFFER_SIZE,
            callback=audio_callback
        )
        audio_stream.start()
        stream_active = True
        socketio.emit('stream_status', {'active': True})
        print(f"Audio stream started (device: {device_index or 'default'})")
    except Exception as e:
        socketio.emit('stream_status', {'active': False, 'error': str(e)})
        print(f"Failed to start stream: {e}", file=sys.stderr)


@socketio.on('stop_stream')
def handle_stop():
    """Stop audio capture."""
    global audio_stream, stream_active

    if audio_stream:
        audio_stream.stop()
        audio_stream.close()
        audio_stream = None
    stream_active = False
    socketio.emit('stream_status', {'active': False})
    print("Audio stream stopped")


@socketio.on('connect')
def handle_connect():
    socketio.emit('stream_status', {'active': stream_active})


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='ARC Audio Analyzer Server')
    parser.add_argument('--port', type=int, default=5050, help='Server port (default: 5050)')
    parser.add_argument('--device', type=int, default=None, help='Audio device index')
    parser.add_argument('--host', default='0.0.0.0', help='Bind host (default: 0.0.0.0)')
    args = parser.parse_args()

    print(f"\n  ARC Audio Analyzer")
    print(f"  http://localhost:{args.port}")
    print(f"  Available on LAN at http://<your-ip>:{args.port}\n")

    # List devices on startup
    print("  Audio Input Devices:")
    for i, d in enumerate(sd.query_devices()):
        if d['max_input_channels'] > 0:
            marker = " *" if i == (args.device or sd.default.device[0]) else ""
            print(f"    [{i}] {d['name']} ({d['max_input_channels']}ch){marker}")
    print()

    socketio.run(app, host=args.host, port=args.port, debug=False)
