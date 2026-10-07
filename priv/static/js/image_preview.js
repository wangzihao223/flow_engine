// Binary ImageViewer preview transport.
import { API_BASE } from './config.js';
import { state } from './state.js';

const previewSockets = new Map(); // key -> { socket, objectUrl, statsTimer }

function getApiKeyQuery() {
    const apiKey = (window.pynodeApiKey && window.pynodeApiKey()) || '';
    return apiKey ? `&api_key=${encodeURIComponent(apiKey)}` : '';
}

function getApiKeyPrefix() {
    const apiKey = (window.pynodeApiKey && window.pynodeApiKey()) || '';
    return apiKey ? `?api_key=${encodeURIComponent(apiKey)}` : '';
}

function buildPreviewKey(workflowId, nodeId) {
    return `${workflowId || 'active'}::${nodeId}`;
}

function buildPreviewUrl(nodeId, workflowId) {
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    return `${protocol}//${window.location.host}${API_BASE}/ws/nodes/${nodeId}/preview` +
        `?workflow=${encodeURIComponent(workflowId)}${getApiKeyQuery()}`;
}

function buildStatsUrl(nodeId) {
    return `${API_BASE}/nodes/${nodeId}/preview_stats${getApiKeyPrefix()}`;
}

function formatStats(stats) {
    const transport = stats.transport === 'websocket' ? 'WS'
        : stats.transport === 'sse' ? 'SSE'
            : 'idle';
    const fps = stats.transport === 'websocket' ? stats.websocketFps
        : stats.transport === 'sse' ? stats.sseFps
            : stats.fps;
    const kbps = stats.transport === 'websocket' ? stats.websocketKbps
        : stats.transport === 'sse' ? stats.sseKbps
            : stats.jpegKbps;
    const bytesPerFrame = stats.transport === 'websocket' ? stats.avgWebsocketBytes
        : stats.transport === 'sse' ? stats.avgSseBytes
            : stats.avgJpegBytes;
    return `${transport} ${fps.toFixed(1)} FPS ${kbps.toFixed(0)} kbps ${(bytesPerFrame / 1024).toFixed(1)} KB/f`;
}

function ensurePreviewEntry(key) {
    if (!previewSockets.has(key)) {
        previewSockets.set(key, { socket: null, objectUrl: null, statsTimer: null });
    }
    return previewSockets.get(key);
}

function startStatsPolling(key, nodeId) {
    const entry = ensurePreviewEntry(key);
    const statsEl = document.getElementById(`viewer-stats-${nodeId}`);
    if (!statsEl || entry.statsTimer) return;

    const updateStats = async () => {
        if (!statsEl.isConnected) {
            cleanupPreview(key);
            return;
        }
        try {
            const response = await fetch(buildStatsUrl(nodeId));
            if (!response.ok) return;
            const stats = await response.json();
            if (stats.success) {
                statsEl.textContent = formatStats(stats);
                statsEl.title = [
                    `transport: ${stats.transport}`,
                    `encoded: ${stats.fps} fps, ${stats.jpegKbps} kbps, ${stats.avgJpegBytes} B/f`,
                    `ws: ${stats.websocketFps} fps, ${stats.websocketKbps} kbps, ${stats.avgWebsocketBytes} B/f`,
                    `sse: ${stats.sseFps} fps, ${stats.sseKbps} kbps, ${stats.avgSseBytes} B/f`
                ].join('\n');
            }
        } catch (_) {
            // Stats are diagnostic only; keep preview rendering independent.
        }
    };

    updateStats();
    entry.statsTimer = window.setInterval(updateStats, 1000);
}

function cleanupPreview(key) {
    const entry = previewSockets.get(key);
    if (!entry) return;

    if (entry.socket) {
        try {
            entry.socket.close();
        } catch (_) {
            // ignore
        }
    }
    if (entry.objectUrl) {
        URL.revokeObjectURL(entry.objectUrl);
    }
    if (entry.statsTimer) {
        window.clearInterval(entry.statsTimer);
    }
    previewSockets.delete(key);
}

export function disconnectImageViewerPreview(nodeId, workflowId = state.activeWorkflowId) {
    const targetKey = buildPreviewKey(workflowId, nodeId);
    cleanupPreview(targetKey);
}

export function disconnectAllImageViewerPreviews() {
    Array.from(previewSockets.keys()).forEach(cleanupPreview);
}

export function reconnectAllImageViewerPreviews(workflowId = state.activeWorkflowId) {
    state.nodes.forEach((nodeData) => {
        if (nodeData.type === 'ImageViewerNode') {
            connectImageViewerPreview(nodeData.id, workflowId);
        }
    });
}

export function connectImageViewerPreview(nodeId, workflowId = state.activeWorkflowId) {
    if (!workflowId) return;

    const imgEl = document.getElementById(`viewer-${nodeId}`);
    if (!imgEl) return;

    const key = buildPreviewKey(workflowId, nodeId);
    cleanupPreview(key);
    startStatsPolling(key, nodeId);

    if (window.pynodeWebSocketPreview === false) return;

    const socket = new WebSocket(buildPreviewUrl(nodeId, workflowId));
    socket.binaryType = 'blob';

    const previewEntry = ensurePreviewEntry(key);
    previewEntry.socket = socket;

    socket.onmessage = (event) => {
        const entry = previewSockets.get(key);
        if (!entry || entry.socket !== socket || !imgEl.isConnected) {
            return;
        }

        const blob = event.data instanceof Blob
            ? event.data
            : new Blob([event.data], { type: 'image/jpeg' });
        if (entry.objectUrl) {
            URL.revokeObjectURL(entry.objectUrl);
        }
        entry.objectUrl = URL.createObjectURL(blob);
        imgEl.src = entry.objectUrl;
    };

    socket.onclose = () => {
        const entry = previewSockets.get(key);
        if (!entry || entry.socket !== socket) {
            return;
        }
        if (entry.objectUrl) {
            URL.revokeObjectURL(entry.objectUrl);
        }
        entry.socket = null;
    };

    socket.onerror = () => {
        // Fall back to the legacy SSE path if websocket preview is unavailable.
        const entry = previewSockets.get(key);
        if (entry && entry.socket === socket) {
            cleanupPreview(key);
        }
    };
}

window.addEventListener('beforeunload', disconnectAllImageViewerPreviews);
