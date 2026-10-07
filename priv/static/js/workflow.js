// Workflow import/export and deployment
import { API_BASE } from './config.js';
import { state, setModified, setWorkflowStopped, clearAllNodeModifiedIndicators, clearChangeTracking, hasChanges, getNodeType, markNodeAdded, markConnectionAdded, dedupeConnections } from './state.js';
import { renderNode } from './nodes.js';
import { updateConnections } from './connections.js';
import { showToast } from './ui-utils.js';
import { deselectAllNodes } from './selection.js';
import { disconnectAllImageViewerPreviews, reconnectAllImageViewerPreviews } from './image_preview.js';

// Helper function to enrich node data with type information
export function enrichNodeWithTypeInfo(nodeData) {
    const nodeType = getNodeType(nodeData.type);
    if (nodeType) {
        nodeData.color = nodeType.color;
        nodeData.borderColor = nodeType.borderColor;
        nodeData.textColor = nodeType.textColor;
        nodeData.icon = nodeType.icon;
        nodeData.inputCount = nodeType.inputCount;
        nodeData.outputCount = nodeType.outputCount;
        nodeData.isUnknownNode = false;
        
        // LogicGateNode stores config.input_count as logical inputs. When the
        // optional reset input is enabled, the visible port count has one
        // additional control input and must be reconstructed after refresh.
        if (nodeData.type === 'LogicGateNode' && nodeData.config) {
            const logicalInputCount = parseInt(
                nodeData.config.input_count ?? nodeType.inputCount ?? 2,
                10
            );
            const resetInputEnabled = nodeData.config.reset_input_enabled === true ||
                nodeData.config.reset_input_enabled === 'true';
            const safeLogicalInputCount = Number.isFinite(logicalInputCount)
                ? Math.max(2, Math.min(16, logicalInputCount))
                : 2;
            nodeData.inputCount = safeLogicalInputCount + (resetInputEnabled ? 1 : 0);
        }

        // Handle dynamic output counts (e.g., SwitchNode)
        if (nodeData.type === 'SwitchNode' && nodeData.config && nodeData.config.rules) {
            nodeData.outputCount = Math.max(1, nodeData.config.rules.length);
        }
    } else {
        // Unknown node type - mark as placeholder
        nodeData.isUnknownNode = true;
        nodeData.color = '#3d3d3d';
        nodeData.borderColor = '#ff6b6b';
        nodeData.textColor = '#999';
        nodeData.icon = '❓';
        // Preserve input/output counts if provided in the workflow data
        nodeData.inputCount = nodeData.inputCount || 1;
        nodeData.outputCount = nodeData.outputCount || 1;
        // Force disabled state
        nodeData.enabled = false;
        console.warn(`Unknown node type: ${nodeData.type} - rendering as placeholder`);
    }
    return nodeData;
}

export async function loadWorkflow() {
    try {
        // First load the workflow list to set up tabs
        const { initWorkflowTabs } = await import('./workflows.js');
        await initWorkflowTabs();
        
        // Then load the active workflow data
        if (state.activeWorkflowId) {
            await loadWorkflowData(state.activeWorkflowId);
        }
    } catch (error) {
        console.error('Failed to load workflow:', error);
    }
}

/**
 * Load workflow data for a specific workflow from the server and render it.
 */
export async function loadWorkflowData(workflowId) {
    try {
        const response = await fetch(`${API_BASE}/workflow?workflow=${encodeURIComponent(workflowId)}`);
        if (!response.ok) throw new Error('Failed to load workflow');
        const workflow = await response.json();
        if (!Array.isArray(workflow.nodes) || !Array.isArray(workflow.connections)) {
            throw new Error('Invalid workflow data');
        }
        
        disconnectAllImageViewerPreviews();
        state.nodes.clear();
        state.connections = [];
        document.getElementById('nodes-container').innerHTML = '';
        document.getElementById('connections').innerHTML = '';
        
        // First, process all node data with async operations
        const nodePromises = workflow.nodes.map(async (nodeData) => {
            nodeData.x = nodeData.x !== undefined ? nodeData.x : 100;
            nodeData.y = nodeData.y !== undefined ? nodeData.y : 100;
            
            enrichNodeWithTypeInfo(nodeData);
            
            if (nodeData.type === 'GateNode') {
                try {
                    const enabledResponse = await fetch(`${API_BASE}/nodes/${nodeData.id}/enabled`);
                    const enabledData = await enabledResponse.json();
                    nodeData.enabled = enabledData.enabled;
                } catch (error) {
                    nodeData.enabled = true;
                }
            }
            
            if (nodeData.type === 'DebugNode') {
                try {
                    const enabledResponse = await fetch(`${API_BASE}/nodes/${nodeData.id}/enabled`);
                    const enabledData = await enabledResponse.json();
                    nodeData.enabled = enabledData.enabled;
                } catch (error) {
                    nodeData.enabled = true;
                }
            }
            
            return nodeData;
        });
        
        // Wait for all async operations to complete
        const processedNodes = await Promise.all(nodePromises);
        
        // Now render all nodes synchronously
        processedNodes.forEach(nodeData => {
            state.nodes.set(nodeData.id, nodeData);
            renderNode(nodeData);
        });
        
        // Load connections into state
        state.connections = dedupeConnections(workflow.connections || []);
        
        // Render connections immediately after nodes are in DOM
        updateConnections();
        
        // Clear history after loading workflow
        import('./history.js').then(({ clearHistory }) => {
            clearHistory();
        });
        
        // Clear change tracking since we just loaded from server
        clearChangeTracking();
        setModified(false);
    } catch (error) {
        console.error('Failed to load workflow:', error);
        throw error;
    }
}

export async function deployWorkflow() {
    if (!hasChanges() && state.workflowStopped) {
        try {
            const response = await fetch(`${API_BASE}/workflow/start`, { method: 'POST' });
            if (!response.ok) throw new Error('Failed to resume workflow');
            setWorkflowStopped(false);
            reconnectAllImageViewerPreviews();
            showToast('Workflow processing resumed');
        } catch (error) {
            console.error('Failed to resume workflow:', error);
            showToast('Failed to resume workflow');
        }
        return;
    }

    return deployWorkflowFull();
}

export async function deployWorkflowFull() {
    try {
        if (!state.activeWorkflowId) throw new Error('No active workflow');
        const nodes = [];
        state.nodes.forEach((nodeData) => {
            const nodeExport = {
                id: nodeData.id,
                type: nodeData.type,
                name: nodeData.name,
                config: nodeData.config,
                enabled: nodeData.enabled !== undefined ? nodeData.enabled : true,
                x: nodeData.x,
                y: nodeData.y
            };
            // Include input/output counts for unknown nodes to preserve them
            if (nodeData.isUnknownNode) {
                nodeExport.inputCount = nodeData.inputCount;
                nodeExport.outputCount = nodeData.outputCount;
            }
            nodes.push(nodeExport);
        });
        
        const workflow = {
            nodes: nodes,
            connections: dedupeConnections(state.connections)
        };
        
        const response = await fetch(`${API_BASE}/workflow/save?workflow=${encodeURIComponent(state.activeWorkflowId)}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(workflow)
        });
        
        if (response.ok) {
            state.nodes.forEach((nodeData) => {
                if (nodeData.type === 'ModeControllerNode') {
                    delete nodeData.config.current_password;
                }
            });
            clearAllNodeModifiedIndicators();
            clearChangeTracking();
            setWorkflowStopped(false);
            setModified(false);
            state.workflowCache.delete(state.activeWorkflowId);
            reconnectAllImageViewerPreviews();
            showToast('Full workflow deployed!');
            return true;
        } else {
            const result = await response.json().catch(() => ({}));
            throw new Error(result.error || 'Failed to deploy workflow');
        }
    } catch (error) {
        console.error('Failed to deploy workflow:', error);
        showToast(`Failed to deploy workflow: ${error.message}`);
        return false;
    }
}

export async function restartWorkflow() {
    try {
        const response = await fetch(`${API_BASE}/workflow/restart`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' }
        });
        
        if (response.ok) {
            // Restart starts every enabled workflow again, so any transient
            // stop is over.
            setWorkflowStopped(false);
            reconnectAllImageViewerPreviews();
            showToast('Workflow restarted!');
        } else {
            throw new Error('Failed to restart workflow');
        }
    } catch (error) {
        console.error('Failed to restart workflow:', error);
        showToast('Failed to restart workflow');
    }
}

/**
 * Transiently stop all deployed workflow processing ("Stop" in the deploy
 * menu). Workflows stay enabled and nothing is persisted; selecting Deploy
 * (modified or full) starts processing again.
 */
export async function stopWorkflow() {
    try {
        const response = await fetch(`${API_BASE}/workflow/stop`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' }
        });

        if (response.ok) {
            const result = await response.json();
            setWorkflowStopped(true);
            const count = result.stopped || 0;
            const flows = count === 1 ? '1 flow' : `${count} flows`;
            showToast(`Stopped ${flows} - Deploy to start again`);
        } else {
            throw new Error('Failed to stop workflow');
        }
    } catch (error) {
        console.error('Failed to stop workflow:', error);
        showToast('Failed to stop workflow');
    }
}

export function clearWorkflow() {
    if (!confirm('Clear all nodes and connections?')) return;
    
    disconnectAllImageViewerPreviews();
    state.nodes.clear();
    state.connections = [];
    
    document.getElementById('nodes-container').innerHTML = '';
    document.getElementById('connections').innerHTML = '';
    
    deselectAllNodes();

    // Clear history when clearing workflow
    import('./history.js').then(({ clearHistory }) => {
        clearHistory();
    });

    // Empty canvas -> redraw the minimap
    import('./minimap.js').then(({ refreshMinimap }) => {
        refreshMinimap();
    });

    setModified(true);
}

export function exportWorkflow() {
    try {
        const nodes = [];
        state.nodes.forEach((nodeData) => {
            const nodeExport = {
                id: nodeData.id,
                type: nodeData.type,
                name: nodeData.name,
                config: nodeData.config,
                x: nodeData.x,
                y: nodeData.y
            };
            // Include input/output counts for unknown nodes to preserve them
            if (nodeData.isUnknownNode) {
                nodeExport.inputCount = nodeData.inputCount;
                nodeExport.outputCount = nodeData.outputCount;
            }
            nodes.push(nodeExport);
        });
        
        const workflow = {
            nodes: nodes,
            connections: dedupeConnections(state.connections)
        };
        
        const dataStr = JSON.stringify(workflow, null, 2);
        const dataBlob = new Blob([dataStr], { type: 'application/json' });
        const url = URL.createObjectURL(dataBlob);
        
        const link = document.createElement('a');
        link.href = url;
        link.download = 'workflow.json';
        link.click();
    } catch (error) {
        console.error('Failed to export workflow:', error);
    }
}

export function exportSelected() {
    try {
        const nodes = [];
        // If nothing selected, fallback to exporting full workflow
        if (!state.selectedNodes || state.selectedNodes.size === 0) {
            return exportWorkflow();
        }

        const selectedSet = new Set(Array.from(state.selectedNodes));

        state.nodes.forEach((nodeData) => {
            if (selectedSet.has(nodeData.id)) {
                const nodeExport = {
                    id: nodeData.id,
                    type: nodeData.type,
                    name: nodeData.name,
                    config: nodeData.config,
                    x: nodeData.x,
                    y: nodeData.y
                };
                // Include input/output counts for unknown nodes to preserve them
                if (nodeData.isUnknownNode) {
                    nodeExport.inputCount = nodeData.inputCount;
                    nodeExport.outputCount = nodeData.outputCount;
                }
                nodes.push(nodeExport);
            }
        });

        // Include only connections where both ends are selected
        const connections = dedupeConnections(
            state.connections.filter(conn => selectedSet.has(conn.source) && selectedSet.has(conn.target))
        );

        const workflow = { nodes, connections };

        const dataStr = JSON.stringify(workflow, null, 2);
        const dataBlob = new Blob([dataStr], { type: 'application/json' });
        const url = URL.createObjectURL(dataBlob);

        const link = document.createElement('a');
        link.href = url;
        link.download = 'workflow-selected.json';
        link.click();
    } catch (error) {
        console.error('Failed to export selected nodes:', error);
    }
}

// Load a parsed workflow object into a brand-new workflow tab. Shared by
// file import and example loading so both behave identically.
export async function loadWorkflowObject(workflow, name) {
    if (!workflow || !Array.isArray(workflow.nodes)) {
        throw new Error('Invalid workflow: missing "nodes" array');
    }

    // Import creates a new workflow tab
    const { createNewWorkflow } = await import('./workflows.js');
    const createdWorkflow = await createNewWorkflow(name);
    if (!createdWorkflow) throw new Error('Failed to create workflow for import');

    // Now populate the new (now active) workflow with imported data
    disconnectAllImageViewerPreviews();
    state.nodes.clear();
    state.connections = [];
    document.getElementById('nodes-container').innerHTML = '';
    document.getElementById('connections').innerHTML = '';

    workflow.nodes.forEach(nodeData => {
        enrichNodeWithTypeInfo(nodeData);
        state.nodes.set(nodeData.id, nodeData);
        renderNode(nodeData);
        // Register with change tracking: the default "Deploy modified" mode
        // sends only tracked changes, so without this the backend never
        // learns about the imported nodes and node actions 404.
        markNodeAdded(nodeData.id);
    });

    dedupeConnections(workflow.connections || []).forEach(conn => {
        state.connections.push(conn);
        markConnectionAdded(conn);
    });

    // Render all connections after nodes are in DOM
    updateConnections();

    // Persist the imported workflow immediately so a refresh does not drop it.
    if (!await deployWorkflowFull()) throw new Error('Failed to deploy imported workflow');

    // Clear history after importing workflow
    import('./history.js').then(({ clearHistory }) => {
        clearHistory();
    });
}

export function importWorkflow() {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = 'application/json';

    input.onchange = async (e) => {
        const file = e.target.files[0];
        const text = await file.text();

        try {
            const workflow = JSON.parse(text);
            // Derive name from filename (strip .json)
            const name = file.name.replace(/\.json$/i, '');
            await loadWorkflowObject(workflow, name);
            showToast('Workflow imported and saved.');
        } catch (error) {
            console.error('Failed to import workflow:', error);
            showToast('Failed to import workflow');
        }
    };

    input.click();
}

// Fetch the bundled example manifest (served from static/examples/).
export async function fetchExamples() {
    const response = await fetch('examples/manifest.json', { cache: 'no-cache' });
    if (!response.ok) {
        throw new Error(`Failed to load examples manifest (${response.status})`);
    }
    const data = await response.json();
    return data.examples || [];
}

// Load one bundled example workflow (by manifest entry) into a new tab.
export async function loadExampleWorkflow(example) {
    try {
        const response = await fetch(`examples/${example.file}`, { cache: 'no-cache' });
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}`);
        }
        const workflow = await response.json();
        await loadWorkflowObject(workflow, example.title || example.id);
        showToast(`Loaded example "${example.title || example.id}" and saved.`);
    } catch (error) {
        console.error('Failed to load example workflow:', error);
        showToast('Failed to load example');
    }
}
