// State management module
import { captureView, restoreView } from './viewport.js';

export const state = {
    nodes: new Map(),
    connections: [],
    selectedNode: null,
    selectedNodes: new Set(),
    selectedConnection: null,
    selectedConnections: new Set(),  // For multi-connection selection (path selection)
    draggingNode: null,
    drawingConnection: null,
    nodeTypes: [],
    nodeTypesMap: new Map(), // Fast lookup by type name
    selectionBox: null,
    selectionStart: null,
    isModified: false,
    workflowStopped: false, // Transient stop via deploy menu (Deploy resumes)
    nextNodeId: 1,
    // Track changes for incremental deployment
    modifiedNodes: new Set(),
    addedNodes: new Set(),
    deletedNodes: new Set(),
    addedConnections: [],
    deletedConnections: [],
    // Multi-workflow state
    workflows: new Map(), // workflow_id -> { name, enabled, nodeCount }
    activeWorkflowId: null,
    workflowCache: new Map() // workflow_id -> { nodes, connections, changes }
};

// Set node types and build lookup map
export function setNodeTypes(types) {
    state.nodeTypes = types;
    state.nodeTypesMap.clear();
    types.forEach(nt => state.nodeTypesMap.set(nt.type, nt));
}

// Get node type by name (O(1) lookup)
export function getNodeType(typeName) {
    return state.nodeTypesMap.get(typeName);
}

export function normalizeConnection(connection) {
    return {
        source: connection.source,
        target: connection.target,
        sourceOutput: Number(connection.sourceOutput ?? 0),
        targetInput: Number(connection.targetInput ?? 0)
    };
}

export function connectionKey(connection) {
    const conn = normalizeConnection(connection);
    return `${conn.source}->${conn.target}:${conn.sourceOutput}:${conn.targetInput}`;
}

export function dedupeConnections(connections) {
    const seen = new Set();
    const result = [];

    (connections || []).forEach(connection => {
        if (!connection || !connection.source || !connection.target) return;
        const normalized = normalizeConnection(connection);
        const key = connectionKey(normalized);
        if (seen.has(key)) return;
        seen.add(key);
        result.push(normalized);
    });

    return result;
}

// Generate a client-side node ID
export function generateNodeId() {
    return `node_${Date.now()}_${state.nextNodeId++}`;
}

// Set modified state and update deploy button
export function setModified(modified) {
    state.isModified = modified;
    updateDeployButtonState();
    // Note: deploy-dropdown-btn stays enabled so user can change mode anytime
}

// Set the transient "processing stopped" state (Stop in the deploy menu).
// While stopped, the Deploy button stays enabled (even with no edits) and is
// highlighted so the user can see the flow is stopped and resume it.
export function setWorkflowStopped(stopped) {
    state.workflowStopped = stopped;
    updateDeployButtonState();
}

function updateDeployButtonState() {
    const deployBtn = document.getElementById('deploy-btn');
    if (!deployBtn) return;
    // Deploy is clickable when there are changes OR when processing is
    // stopped (deploying resumes processing).
    deployBtn.disabled = !state.isModified && !state.workflowStopped;
    deployBtn.classList.toggle('deploy-stopped', state.workflowStopped);
    deployBtn.title = state.workflowStopped
        ? 'Processing stopped - Deploy to start again'
        : '';
}

// Mark a node as modified
export function markNodeModified(nodeId) {
    const nodeEl = document.getElementById(`node-${nodeId}`);
    if (nodeEl) {
        nodeEl.classList.add('modified');
    }
    // Track modified node for incremental deploy
    if (!state.addedNodes.has(nodeId)) {
        state.modifiedNodes.add(nodeId);
    }
}

// Mark a node as newly added
export function markNodeAdded(nodeId) {
    state.addedNodes.add(nodeId);
}

// Mark a node as deleted
export function markNodeDeleted(nodeId) {
    // If it was added in this session, just remove from added
    if (state.addedNodes.has(nodeId)) {
        state.addedNodes.delete(nodeId);
    } else {
        state.deletedNodes.add(nodeId);
    }
    state.modifiedNodes.delete(nodeId);
}

// Track added connection
export function markConnectionAdded(connection) {
    const normalized = normalizeConnection(connection);
    const key = connectionKey(normalized);
    if (!state.addedConnections.some(c => connectionKey(c) === key)) {
        state.addedConnections.push(normalized);
    }
}

// Track deleted connection
export function markConnectionDeleted(connection) {
    const normalized = normalizeConnection(connection);
    const key = connectionKey(normalized);
    // Check if it was added in this session
    const addedIdx = state.addedConnections.findIndex(c => 
        connectionKey(c) === key
    );
    if (addedIdx >= 0) {
        state.addedConnections.splice(addedIdx, 1);
    } else if (!state.deletedConnections.some(c => connectionKey(c) === key)) {
        state.deletedConnections.push(normalized);
    }
}

// Clear all change tracking after deploy
export function clearChangeTracking() {
    state.modifiedNodes.clear();
    state.addedNodes.clear();
    state.deletedNodes.clear();
    state.addedConnections = [];
    state.deletedConnections = [];
}

// Check if there are any changes to deploy
export function hasChanges() {
    return state.modifiedNodes.size > 0 || 
           state.addedNodes.size > 0 || 
           state.deletedNodes.size > 0 ||
           state.addedConnections.length > 0 ||
           state.deletedConnections.length > 0;
}

// Clear all node modified indicators
export function clearAllNodeModifiedIndicators() {
    document.querySelectorAll('.node.modified').forEach(nodeEl => {
        nodeEl.classList.remove('modified');
    });
}

/**
 * Check if a connection is selected (either single or as part of path)
 */
export function isConnectionSelected(connection) {
    const connKey = connectionKey(connection);
    
    // Check multi-selection first
    if (state.selectedConnections.has(connKey)) {
        return true;
    }
    
    // Check single selection
    if (state.selectedConnection && 
        state.selectedConnection.source === connection.source &&
        state.selectedConnection.target === connection.target &&
        (state.selectedConnection.sourceOutput || 0) === (connection.sourceOutput || 0) &&
        (state.selectedConnection.targetInput || 0) === (connection.targetInput || 0)) {
        return true;
    }
    
    return false;
}

/**
 * Save current canvas state into workflow cache for tab switching.
 */
export function saveActiveWorkflowToCache() {
    if (!state.activeWorkflowId) return;
    state.workflowCache.set(state.activeWorkflowId, {
        nodes: new Map(state.nodes),
        connections: dedupeConnections(state.connections),
        modifiedNodes: new Set(state.modifiedNodes),
        addedNodes: new Set(state.addedNodes),
        deletedNodes: new Set(state.deletedNodes),
        addedConnections: [...state.addedConnections],
        deletedConnections: [...state.deletedConnections],
        isModified: state.isModified,
        nextNodeId: state.nextNodeId,
        // Per-tab canvas view: zoom + scroll, restored on tab switch
        view: captureView()
    });
}

/**
 * Restore canvas state from workflow cache.
 * Returns true if cache was found and restored.
 */
export function restoreWorkflowFromCache(workflowId) {
    const cached = state.workflowCache.get(workflowId);
    if (!cached) return false;
    
    state.nodes = new Map(cached.nodes);
    state.connections = dedupeConnections(cached.connections);
    state.modifiedNodes = new Set(cached.modifiedNodes);
    state.addedNodes = new Set(cached.addedNodes);
    state.deletedNodes = new Set(cached.deletedNodes);
    state.addedConnections = [...cached.addedConnections];
    state.deletedConnections = [...cached.deletedConnections];
    state.isModified = cached.isModified;
    state.nextNodeId = cached.nextNodeId;
    // Restore this tab's zoom + scroll (no-op if the cache predates views)
    restoreView(cached.view);
    return true;
}
