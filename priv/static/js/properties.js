// Properties panel
import { state, markNodeModified, setModified, getNodeType } from './state.js';
import { API_BASE } from './config.js';
import { updateNodeOutputCount, updateNodeInputCount } from './nodes.js';
import { updateConnections } from './connections.js';
import { showToast } from './ui-utils.js';

const JSON_BUILDER_TEMPLATES_API = `${API_BASE}/templates/json-builder`;

// Helper function to check if property should be shown
function shouldShowProperty(showIf, config) {
    for (const [key, value] of Object.entries(showIf)) {
        const configValue = config[key];
        
        if (Array.isArray(value)) {
            // Check if config value is in the array
            if (!value.includes(configValue)) {
                return false;
            }
        } else {
            // Check if config value matches
            if (configValue !== value) {
                return false;
            }
        }
    }
    return true;
}

function migratePlcConfig(nodeData) {
    if (nodeData.type !== 'PLCNode' || !nodeData.config.connection || nodeData.config.base_url !== undefined) return;

    let point;
    try {
        point = JSON.parse(nodeData.config.address);
    } catch {
        return;
    }

    const connection = nodeData.config.connection;
    const pointTypes = ['bool', 'int16', 'uint16', 'int32', 'uint32', 'float32', 'string', 'bytes'];
    if (!point || typeof point !== 'object' || Array.isArray(point) ||
        !Object.keys(point).every(key => ['db', 'offset', 'type', 'bit', 'size'].includes(key)) ||
        !Object.keys(connection).every(key => ['base_url', 'device_id', 'token'].includes(key)) ||
        !connection.base_url || !connection.device_id || !Number.isInteger(point.db) || point.db < 0 ||
        !Number.isInteger(point.offset) || point.offset < 0 || !pointTypes.includes(point.type) ||
        (point.type === 'bool' && point.bit === undefined) ||
        (['string', 'bytes'].includes(point.type) && point.size === undefined) ||
        (point.bit !== undefined && point.type !== 'bool') ||
        (point.size !== undefined && !['string', 'bytes'].includes(point.type)) ||
        (point.bit !== undefined && (!Number.isInteger(point.bit) || point.bit < 0 || point.bit > 7)) ||
        (point.size !== undefined && (!Number.isInteger(point.size) || point.size < 1 || point.size > 65535))) return;

    Object.assign(nodeData.config, {
        base_url: connection.base_url,
        device_id: connection.device_id,
        token: connection.token || '',
        db: point.db,
        offset: point.offset,
        point_type: point.type,
        bit: point.bit ?? 0,
        size: point.size ?? 1
    });
    markNodeModified(nodeData.id);
    setModified(true);
}

export function renderProperties(nodeData) {
    nodeData.config ||= {};
    migratePlcConfig(nodeData);
    const panel = document.getElementById('properties-panel');
    const panelContainer = document.getElementById('properties-panel-container');
    if (panelContainer) {
        panelContainer.classList.remove('hidden');
    }
    
    const isEnabled = nodeData.enabled !== undefined ? nodeData.enabled : true;
    
    let html = `
        <div class="property-group">
            <label class="property-label">Name</label>
            <input type="text" class="property-input" value="${nodeData.name}" 
                   onchange="window.updateNodeProperty('${nodeData.id}', 'name', this.value)">
        </div>
        <div class="property-group property-enabled-row">
            <span class="property-label">Enabled</span>
            <label class="gate-switch">
                <input type="checkbox" ${isEnabled ? 'checked' : ''} 
                       onchange="window.toggleNodeEnabled('${nodeData.id}', this.checked)">
                <span class="gate-slider"></span>
            </label>
        </div>
    `;
    
    const nodeType = getNodeType(nodeData.type);
    if (nodeType && nodeType.properties) {
        const legacyPlc = nodeData.type === 'PLCNode' && nodeData.config.connection &&
            nodeData.config.base_url === undefined;
        const properties = legacyPlc ? [
            nodeType.properties[0],
            { name: 'connection', label: '旧版连接配置（JSON）', type: 'json', default: {} },
            { name: 'address', label: '旧版 PLC 地址', type: 'text', default: '' },
            nodeType.properties[nodeType.properties.length - 1]
        ] : nodeType.properties;
        properties.forEach(prop => {
            // Add property group with conditional visibility
            const shouldShow = !prop.showIf || shouldShowProperty(prop.showIf, nodeData.config);
            
            html += '<div class="property-group"';
            // Add data attribute for dynamic visibility
            if (prop.showIf) {
                html += ` data-show-if='${JSON.stringify(prop.showIf)}'`;
            }
            // Hide initially if condition not met
            if (!shouldShow) {
                html += ' style="display: none;"';
            }
            html += '>';
            
            if (prop.type === 'text') {
                const value = nodeData.config[prop.name] !== undefined ? nodeData.config[prop.name] : (prop.default || '');
                const placeholder = prop.placeholder || prop.default || '';
                html += `
                    <label class="property-label">${prop.label}</label>
                    <input type="text" class="property-input" 
                           value="${value}"
                           placeholder="${placeholder}"
                           onchange="window.updateNodeConfig('${nodeData.id}', '${prop.name}', this.value)">
                `;
            } else if (prop.type === 'password') {
                const value = nodeData.config[prop.name] !== undefined ? nodeData.config[prop.name] : (prop.default || '');
                html += `
                    <label class="property-label">${prop.label}</label>
                    <input type="password" class="property-input"
                           value="${value}"
                           autocomplete="new-password"
                           onchange="window.updateNodeConfig('${nodeData.id}', '${prop.name}', this.value)">
                `;
            } else if (prop.type === 'link-channel') {
                const value = nodeData.config[prop.name] !== undefined ? nodeData.config[prop.name] : (prop.default || '');
                const placeholder = prop.placeholder || prop.default || '';
                const listId = `link-channel-list-${nodeData.id}-${prop.name}`;
                html += `
                    <label class="property-label">${prop.label}</label>
                    <input type="text" class="property-input"
                           value="${value}"
                           placeholder="${placeholder}"
                           list="${listId}"
                           onchange="window.updateNodeConfig('${nodeData.id}', '${prop.name}', this.value)">
                    <datalist id="${listId}"></datalist>
                `;
            } else if (prop.type === 'number') {
                const value = nodeData.config[prop.name] !== undefined ? nodeData.config[prop.name] : (prop.default || 0);
                html += `
                    <label class="property-label">${prop.label}</label>
                    <input type="number" class="property-input" 
                           value="${value}"
                           onchange="window.updateNodeConfig('${nodeData.id}', '${prop.name}', parseFloat(this.value))">
                `;
            } else if (prop.type === 'checkbox') {
                const checked = nodeData.config[prop.name] !== undefined ? nodeData.config[prop.name] : (prop.default || false);
                html += `
                    <label class="property-label">
                        <input type="checkbox" class="property-checkbox" 
                               ${checked ? 'checked' : ''}
                               onchange="window.updateNodeConfig('${nodeData.id}', '${prop.name}', this.checked)">
                        ${prop.label}
                    </label>
                `;
            } else if (prop.type === 'textarea') {
                const value = nodeData.config[prop.name] !== undefined ? nodeData.config[prop.name] : (prop.default || '');
                const placeholder = prop.placeholder || prop.default || '';
                html += `
                    <label class="property-label">${prop.label}</label>
                    <textarea class="property-input property-textarea" 
                              placeholder="${placeholder}"
                              onchange="window.updateNodeConfig('${nodeData.id}', '${prop.name}', this.value)">${value}</textarea>
                `;
            } else if (prop.type === 'json') {
                const value = nodeData.config[prop.name] ?? prop.default ?? {};
                html += `
                    <label class="property-label">${prop.label}</label>
                    <textarea class="property-input property-textarea"
                              onchange="window.updateNodeJsonConfig('${nodeData.id}', '${prop.name}', this)">${escapeHtml(JSON.stringify(value, null, 2))}</textarea>
                `;
            } else if (prop.type === 'select') {
                const selectedValue = nodeData.config[prop.name] !== undefined
                    ? nodeData.config[prop.name]
                    : prop.default;
                html += `
                    <label class="property-label">${prop.label}</label>
                    <select class="property-select" 
                            onchange="window.updateNodeConfig('${nodeData.id}', '${prop.name}', this.value); window.updatePropertyVisibility('${nodeData.id}')">
                `;
                prop.options.forEach(option => {
                    const selected = selectedValue === option.value ? 'selected' : '';
                    html += `<option value="${option.value}" ${selected}>${option.label}</option>`;
                });
                html += '</select>';
            } else if (prop.type === 'button') {
                html += `
                    <button class="btn btn-primary" onclick="window.triggerNodeAction('${nodeData.id}', '${prop.action}')">${prop.label}</button>
                `;
            } else if (prop.type === 'toggle') {
                // Toggle switch with action - syncs with node's uiComponent toggle
                const stateField = prop.stateField || 'drawingEnabled';  // Default for backward compat
                const isChecked = nodeData[stateField] !== false;  // Default to true if undefined
                html += `
                    <div class="property-toggle-row">
                        <span class="property-label">${prop.label}</span>
                        <label class="gate-switch">
                            <input type="checkbox" 
                                   id="prop-toggle-${nodeData.id}-${prop.name}"
                                   data-state-field="${stateField}"
                                   ${isChecked ? 'checked' : ''}
                                   onchange="window.triggerToggleAction('${nodeData.id}', '${prop.action}', '${stateField}', this.checked)">
                            <span class="gate-slider"></span>
                        </label>
                    </div>
                `;
            } else if (prop.type === 'file') {
                const value = nodeData.config[prop.name] !== undefined ? nodeData.config[prop.name] : (prop.default || '');
                const accept = prop.accept || '';
                const uploadRoute = prop.uploadRoute || '';
                const placeholder = prop.placeholder || 'Select or enter file path...';
                const fileId = `file-${nodeData.id}-${prop.name}`;
                html += `
                    <label class="property-label">${prop.label}</label>
                    <div class="property-file-container">
                        <input type="text" class="property-input property-file-path" 
                               value="${value}"
                               placeholder="${placeholder}"
                               onchange="window.updateNodeConfig('${nodeData.id}', '${prop.name}', this.value)">
                        <button class="btn btn-secondary property-file-btn" onclick="window.selectFile('${nodeData.id}', '${prop.name}', '${accept}', '${uploadRoute}')">
                            <i class="fas fa-folder-open"></i>
                        </button>
                    </div>
                    <div class="upload-progress-container" id="${fileId}-progress" style="display:none;">
                        <div class="upload-progress-bar">
                            <div class="upload-progress-fill" id="${fileId}-fill"></div>
                        </div>
                        <span class="upload-progress-text" id="${fileId}-text">0%</span>
                    </div>
                `;
            } else if (prop.type === 'mqtt-service') {
                // MQTT Service selector - like Node-RED config nodes
                const currentServiceId = nodeData.config[prop.name] || '';
                html += `
                    <label class="property-label">${prop.label}</label>
                    <div class="property-service-container">
                        <select class="property-select property-service-select" 
                                id="mqtt-service-${nodeData.id}"
                                data-node-id="${nodeData.id}"
                                data-prop-name="${prop.name}"
                                onchange="window.onMqttServiceSelect('${nodeData.id}', '${prop.name}', this.value)">
                            <option value="">-- Select broker --</option>
                        </select>
                        <button class="btn btn-secondary property-service-btn" 
                                onclick="window.openMqttServiceEditor('${nodeData.id}', '${prop.name}')"
                                title="Edit broker settings">
                            ✏️
                        </button>
                        <button class="btn btn-primary property-service-btn" 
                                onclick="window.openMqttServiceEditor('${nodeData.id}', '${prop.name}', true)"
                                title="Add new broker">
                            +
                        </button>
                    </div>
                `;
                // Load services after rendering
                setTimeout(() => window.loadMqttServices(nodeData.id, prop.name, currentServiceId), 0);
            } else if (prop.type === 'rules') {
                html += renderRulesEditor(nodeData.id, prop.name, nodeData.config[prop.name] || [], prop.operators, prop.valueTypes);
            } else if (prop.type === 'injectProps') {
                html += renderInjectPropsEditor(nodeData.id, prop.name, nodeData.config[prop.name] || []);
            } else if (prop.type === 'changeRules') {
                html += renderChangeRulesEditor(nodeData.id, prop.name, nodeData.config[prop.name] || [], prop.operations, prop.valueTypes);
            } else if (prop.type === 'inputRules') {
                html += renderInputRulesEditor(nodeData.id, prop.name, nodeData.config[prop.name] || []);
            } else if (prop.type === 'jsonBuilderMappings') {
                html += renderJsonBuilderMappingsEditor(nodeData.id, prop.name, nodeData.config[prop.name] || []);
            } else if (prop.type === 'jsonBuilderTemplate') {
                const value = nodeData.config[prop.name] !== undefined ? nodeData.config[prop.name] : (prop.default || '');
                html += renderJsonBuilderTemplateEditor(nodeData.id, prop.name, value);
            } else if (prop.type === 'streamUrl') {
                // Read-only stream URL that opens in new tab
                const streamUrl = `${window.location.origin}/api/nodes/${nodeData.id}/stream`;
                html += `
                    <label class="property-label">${prop.label}</label>
                    <div class="property-stream-url-container">
                        <input type="text" class="property-input property-stream-url" 
                               value="${streamUrl}" readonly
                               onclick="this.select()">
                        <button class="btn btn-secondary property-stream-btn" 
                                onclick="window.open('${streamUrl}', '_blank')"
                                title="Open stream in new tab">
                            ↗️
                        </button>
                        <button class="btn btn-secondary property-stream-btn" 
                                onclick="navigator.clipboard.writeText('${streamUrl}'); window.showToast && window.showToast('URL copied!')"
                                title="Copy URL">
                            🗐
                        </button>
                    </div>
                `;
            } else if (prop.type === 'multiselect') {
                // Multiselect - allows selecting multiple options with checkboxes
                const selectedValues = nodeData.config[prop.name] || prop.default || [];
                html += `<label class="property-label">${prop.label}</label>`;
                html += `<div class="property-multiselect" data-prop="${prop.name}">`;
                
                prop.options.forEach(option => {
                    const optValue = typeof option === 'object' ? option.value : option;
                    const optLabel = typeof option === 'object' ? option.label : option;
                    const isChecked = Array.isArray(selectedValues) ? selectedValues.includes(optValue) : selectedValues === optValue;
                    
                    html += `
                        <label class="multiselect-option">
                            <input type="checkbox" 
                                   value="${optValue}"
                                   ${isChecked ? 'checked' : ''}
                                   onchange="window.updateMultiselectConfig('${nodeData.id}', '${prop.name}', this)">
                            <span>${optLabel}</span>
                        </label>
                    `;
                });
                
                html += '</div>';
            }
            
            if (prop.help) {
                html += `<small class="property-help">${prop.help}</small>`;
            }
            
            html += '</div>';
        });
    }
    
    panel.innerHTML = html;
    
    // Update property visibility based on current config
    window.updatePropertyVisibility(nodeData.id);
    populateLinkChannelDatalists(nodeData);
}

export function updateNodeProperty(nodeId, property, value) {
    const nodeData = state.nodes.get(nodeId);
    nodeData[property] = value;
    
    const nodeEl = document.getElementById(`node-${nodeId}`);
    nodeEl.querySelector('.node-title').textContent = value;
    
    markNodeModified(nodeId);
    setModified(true);
}

export function updateNodeConfig(nodeId, key, value) {
    const nodeData = state.nodes.get(nodeId);
    nodeData.config[key] = value;
    
    // If outputs property changed, update the node's output ports
    if (key === 'outputs') {
        updateNodeOutputCount(nodeId, parseInt(value, 10));
    }
    
    // If input_count/reset input changed, update the node's input ports.
    // LogicGateNode keeps config.input_count as logical inputs; reset input is
    // a separate control port appended after the logical inputs.
    if (key === 'input_count' || key === 'reset_input_enabled') {
        const logicalInputCount = parseInt(nodeData.config.input_count ?? nodeData.inputCount ?? 1, 10);
        const resetInputEnabled = nodeData.config.reset_input_enabled === true ||
            nodeData.config.reset_input_enabled === 'true';
        updateNodeInputCount(nodeId, logicalInputCount + (resetInputEnabled ? 1 : 0));
    }

    const nodeEl = document.getElementById(`node-${nodeId}`);
    const badge = nodeEl && nodeEl.querySelector('.node-config-badge');
    if (badge && badge.dataset.key === key) {
        badge.textContent = value
            ? `${badge.dataset.prefix || ''}${value}`
            : (badge.dataset.placeholder || '');
    }
    if (nodeData.type === 'ModeControllerNode' && (key === 'mode_a_name' || key === 'mode_b_name')) {
        const modeDisplay = nodeEl && nodeEl.querySelector('.mode-display');
        if (modeDisplay) {
            const activeModeA = nodeData.modeA !== false;
            modeDisplay.textContent = activeModeA
                ? (nodeData.config.mode_a_name || '模式 A')
                : (nodeData.config.mode_b_name || '模式 B');
        }
    }
    // Live-refresh an on-card control slider when its range/value/label is
    // edited in the properties panel, so the card reflects it without a full
    // re-render (which would drop a slider mid-interaction).
    const slider = nodeEl && nodeEl.querySelector('.control-slider');
    if (slider) {
        if (key === 'value') {
            slider.value = value;
            const valEl = document.getElementById(`slider-val-${nodeId}`);
            if (valEl) valEl.textContent = value;
        } else if (key === 'min' || key === 'max' || key === 'step') {
            slider.setAttribute(key, value);
        } else if (key === 'label') {
            const labelEl = document.getElementById(`slider-label-${nodeId}`);
            if (labelEl) labelEl.textContent = value;
        }
    }

    // Update property visibility since config changed
    window.updatePropertyVisibility(nodeId);
    
    markNodeModified(nodeId);
    setModified(true);
}

export function updateNodeJsonConfig(nodeId, key, input) {
    try {
        const value = JSON.parse(input.value);
        if (!value || Array.isArray(value) || typeof value !== 'object') throw new Error('Expected object');
        input.setCustomValidity('');
        updateNodeConfig(nodeId, key, value);
    } catch (error) {
        input.setCustomValidity('请输入 JSON 对象');
        input.reportValidity();
    }
}

async function populateLinkChannelDatalists(nodeData) {
    const nodeType = getNodeType(nodeData.type);
    if (!nodeType || !nodeType.properties) return;

    const linkChannelProps = nodeType.properties.filter(prop => prop.type === 'link-channel');
    if (linkChannelProps.length === 0) return;

    const clientChannels = new Set();
    state.nodes.forEach(node => {
        if (node.type === 'LinkInNode' || node.type === 'LinkOutNode') {
            const channel = (node.config && node.config.channel != null ? String(node.config.channel) : '').trim();
            if (channel) clientChannels.add(channel);
        }
    });

    let serverChannels = [];
    try {
        const response = await fetch(`${API_BASE}/link-channels`);
        const data = await response.json();
        if (data && data.success && Array.isArray(data.channels)) {
            serverChannels = data.channels;
        }
    } catch (error) {
        console.error('Failed to load link channels:', error);
    }

    const merged = Array.from(new Set([...serverChannels, ...clientChannels]))
        .filter(Boolean)
        .sort();
    const optionsHtml = merged
        .map(channel => `<option value="${escapeHtml(channel)}"></option>`)
        .join('');

    linkChannelProps.forEach(prop => {
        const datalist = document.getElementById(`link-channel-list-${nodeData.id}-${prop.name}`);
        if (datalist) datalist.innerHTML = optionsHtml;
    });
}

/**
 * Update multiselect config - collects all checked values into an array
 */
export function updateMultiselectConfig(nodeId, propName, checkbox) {
    const nodeData = state.nodes.get(nodeId);
    if (!nodeData) return;
    
    // Get the parent multiselect container
    const container = checkbox.closest('.property-multiselect');
    if (!container) return;
    
    // Collect all checked values
    const checkedValues = [];
    container.querySelectorAll('input[type="checkbox"]:checked').forEach(cb => {
        checkedValues.push(cb.value);
    });
    
    nodeData.config[propName] = checkedValues;
    
    // Update property visibility since config changed
    window.updatePropertyVisibility(nodeId);
    
    markNodeModified(nodeId);
    setModified(true);
}

// Make it available globally
window.updateMultiselectConfig = updateMultiselectConfig;

export async function triggerNodeAction(nodeId, action) {
    try {
        await fetch(`${API_BASE}/nodes/${nodeId}/${action}`, { method: 'POST' });
    } catch (error) {
        console.error(`Failed to trigger ${action} on node:`, error);
    }
}

/**
 * Trigger a toggle action and sync state between properties panel and node UI.
 * @param {string} nodeId - The node ID
 * @param {string} action - The action to call (e.g., 'toggle_drawing')
 * @param {string} stateField - The field in nodeData to update (e.g., 'drawingEnabled')
 * @param {boolean} checked - The new toggle state
 */
export async function triggerToggleAction(nodeId, action, stateField, checked) {
    try {
        // Call the action endpoint
        const response = await fetch(`${API_BASE}/nodes/${nodeId}/${action}`, { method: 'POST' });
        
        if (response.ok) {
            // Update nodeData state
            const nodeData = state.nodes.get(nodeId);
            if (nodeData) {
                nodeData[stateField] = checked;
            }
            
            // Sync the toggle on the node itself (if it has one)
            const nodeToggle = document.getElementById(`toggle-${nodeId}`);
            if (nodeToggle && nodeToggle.checked !== checked) {
                nodeToggle.checked = checked;
            }
        }
    } catch (error) {
        console.error(`Failed to trigger ${action} on node:`, error);
    }
}

/**
 * Generic function to toggle node enabled state.
 * Consolidates toggleGate, toggleDebug, and toggleNodeEnabled into one function.
 * @param {string} nodeId - The node ID
 * @param {boolean} enabled - The new enabled state
 * @param {Object} options - Optional configuration
 * @param {string} options.checkboxSelector - CSS selector for checkbox to sync (e.g., '#gate-{nodeId}')
 */
export async function toggleNodeState(nodeId, enabled, options = {}) {
    try {
        const response = await fetch(`${API_BASE}/nodes/${nodeId}/enabled`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ enabled: enabled })
        });
        
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}`);
        }
        
        const nodeData = state.nodes.get(nodeId);
        if (nodeData) {
            nodeData.enabled = enabled;
            
            // Update node visual state
            const nodeEl = document.getElementById(`node-${nodeId}`);
            if (nodeEl) {
                nodeEl.classList.toggle('disabled', !enabled);
            }
            
            // Update connections (dashed when disabled)
            updateConnections();
            
            // Update any visual toggle switches on the node (DebugNode, GateNode)
            const gateCheckbox = document.getElementById(`gate-${nodeId}`);
            const debugCheckbox = document.getElementById(`debug-${nodeId}`);
            if (gateCheckbox) gateCheckbox.checked = enabled;
            if (debugCheckbox) debugCheckbox.checked = enabled;
            
            // Sync properties panel if this node is selected
            if (state.selectedNode === nodeId) {
                const propsToggle = document.querySelector('#properties-panel .gate-switch input');
                if (propsToggle) propsToggle.checked = enabled;
            }
        }
    } catch (error) {
        console.error('Failed to toggle node state:', error);
    }
}

// Backwards compatibility aliases
export const toggleGate = toggleNodeState;
export const toggleNodeEnabled = toggleNodeState;

/**
 * Opens a file dialog to select a file and updates the node config.
 * Uses XMLHttpRequest for upload progress tracking.
 * @param {string} nodeId - The node ID
 * @param {string} propName - The property name to update
 * @param {string} accept - Comma-separated list of accepted file extensions
 * @param {string} uploadRoute - Optional node-specific upload route (e.g. 'upload_video')
 */
export function selectFile(nodeId, propName, accept, uploadRoute) {
    const input = document.createElement('input');
    input.type = 'file';
    if (accept) {
        input.accept = accept;
    }
    
    input.onchange = (e) => {
        const file = e.target.files[0];
        if (!file) return;
        
        const formData = new FormData();
        formData.append('file', file);
        
        let url;
        if (uploadRoute) {
            url = `${API_BASE}/nodes/${nodeId}/${uploadRoute}`;
        } else {
            formData.append('nodeId', nodeId);
            url = `${API_BASE}/upload/file`;
        }
        
        // Progress bar elements
        const fileId = `file-${nodeId}-${propName}`;
        const progressContainer = document.getElementById(`${fileId}-progress`);
        const progressFill = document.getElementById(`${fileId}-fill`);
        const progressText = document.getElementById(`${fileId}-text`);
        
        const xhr = new XMLHttpRequest();
        
        xhr.upload.addEventListener('progress', (evt) => {
            if (evt.lengthComputable && progressContainer) {
                const pct = Math.round((evt.loaded / evt.total) * 100);
                progressContainer.style.display = '';
                progressFill.style.width = `${pct}%`;
                progressText.textContent = `${pct}%`;
            }
        });
        
        xhr.addEventListener('load', () => {
            // Hide progress bar
            if (progressContainer) progressContainer.style.display = 'none';
            
            if (xhr.status >= 200 && xhr.status < 300) {
                try {
                    const result = JSON.parse(xhr.responseText);
                    if (result.success) {
                        const filePath = result.file_path || result.model_path;
                        updateNodeConfig(nodeId, propName, filePath);
                        
                        const nodeData = state.nodes.get(nodeId);
                        renderProperties(nodeData);
                        
                        showToast(`Uploaded: ${file.name}`);
                    } else {
                        showToast(`Upload failed: ${result.error}`, 'error');
                    }
                } catch (parseErr) {
                    showToast(`Upload failed: invalid server response`, 'error');
                }
            } else {
                let errorMsg = `Upload failed (${xhr.status})`;
                try {
                    const errResult = JSON.parse(xhr.responseText);
                    errorMsg = errResult.error || errResult.message || errorMsg;
                } catch (_) { /* use default */ }
                showToast(errorMsg, 'error');
            }
        });
        
        xhr.addEventListener('error', () => {
            if (progressContainer) progressContainer.style.display = 'none';
            showToast('Upload failed: network error', 'error');
        });
        
        xhr.addEventListener('abort', () => {
            if (progressContainer) progressContainer.style.display = 'none';
        });
        
        xhr.open('POST', url);
        xhr.send(formData);
    };
    
    input.click();
}

// Rules editor for switch node
function renderRulesEditor(nodeId, propName, rules, operators, valueTypes) {
    let html = '<div class="rules-editor">';
    
    rules.forEach((rule, index) => {
        html += `
            <div class="rule-item" data-rule-index="${index}">
                <div class="rule-header">
                    <span class="rule-label">Rule ${index + 1} → Output ${index + 1}</span>
                    <button class="btn-icon" onclick="window.removeRule('${nodeId}', '${propName}', ${index})" title="Delete rule">✕</button>
                </div>
                <div class="rule-config">
                    <select class="rule-operator" onchange="window.updateRule('${nodeId}', '${propName}', ${index}, 'operator', this.value)">
                        ${getOperatorOptions(rule.operator || 'eq', operators)}
                    </select>
                    <input type="text" class="rule-value" placeholder="Value" 
                           value="${rule.value || ''}"
                           onchange="window.updateRule('${nodeId}', '${propName}', ${index}, 'value', this.value)">
                    <select class="rule-type" onchange="window.updateRule('${nodeId}', '${propName}', ${index}, 'valueType', this.value)">
                        ${getValueTypeOptions(rule.valueType || 'str', valueTypes)}
                    </select>
                </div>
            </div>
        `;
    });
    
    html += `
        <button class="btn btn-secondary btn-sm" onclick="window.addRule('${nodeId}', '${propName}')">+ Add Rule</button>
    </div>`;
    
    return html;
}

function getOperatorOptions(selected, allowed) {
    const operators = [
        { value: 'eq', label: '==' },
        { value: 'neq', label: '!=' },
        { value: 'lt', label: '<' },
        { value: 'lte', label: '<=' },
        { value: 'gt', label: '>' },
        { value: 'gte', label: '>=' },
        { value: 'between', label: 'between' },
        { value: 'contains', label: 'contains' },
        { value: 'matches', label: 'matches regex' },
        { value: 'true', label: 'is true' },
        { value: 'false', label: 'is false' },
        { value: 'null', label: 'is null' },
        { value: 'nnull', label: 'is not null' },
        { value: 'empty', label: 'is empty' },
        { value: 'nempty', label: 'is not empty' },
        { value: 'haskey', label: 'has key' },
        { value: 'else', label: 'otherwise' }
    ];
    
    return operators.filter(op => !allowed || allowed.includes(op.value) || op.value === selected).map(op => 
        `<option value="${op.value}" ${op.value === selected ? 'selected' : ''}>${op.label}</option>`
    ).join('');
}

function getValueTypeOptions(selected, allowed) {
    const types = [
        { value: 'str', label: 'string' },
        { value: 'num', label: 'number' },
        { value: 'bool', label: 'boolean' },
        { value: 'json', label: 'JSON' }
    ];
    
    return types.filter(type => !allowed || allowed.includes(type.value) || type.value === selected).map(type => 
        `<option value="${type.value}" ${type.value === selected ? 'selected' : ''}>${type.label}</option>`
    ).join('');
}

export function addRule(nodeId, propName) {
    const nodeData = state.nodes.get(nodeId);
    const rules = nodeData.config[propName] || [];
    
    rules.push({
        operator: 'eq',
        value: '',
        valueType: 'str'
    });
    
    nodeData.config[propName] = rules;
    
    // Update output count to match rules
    updateNodeOutputCount(nodeId, rules.length);
    
    markNodeModified(nodeId);
    setModified(true);
    renderProperties(nodeData);
}

export function removeRule(nodeId, propName, ruleIndex) {
    const nodeData = state.nodes.get(nodeId);
    const rules = nodeData.config[propName] || [];
    
    if (rules.length > 1) {
        rules.splice(ruleIndex, 1);
        nodeData.config[propName] = rules;
        
        // Update output count to match rules
        updateNodeOutputCount(nodeId, rules.length);
        
        markNodeModified(nodeId);
        setModified(true);
        renderProperties(nodeData);
    }
}

export function updateRule(nodeId, propName, ruleIndex, field, value) {
    const nodeData = state.nodes.get(nodeId);
    const rules = nodeData.config[propName] || [];
    
    if (rules[ruleIndex]) {
        rules[ruleIndex][field] = value;
        nodeData.config[propName] = rules;
        
        markNodeModified(nodeId);
        setModified(true);
    }
}

// Per-input rule editor for LogicGateNode.
function renderInputRulesEditor(nodeId, propName, rules) {
    let html = '<div class="rules-editor input-rules-editor">';

    rules.forEach((rule, index) => {
        const inputIndex = rule.input_index !== undefined ? rule.input_index : index;
        const valuePath = rule.value_path || 'payload';
        const truthMode = rule.truth_mode || 'boolean';
        const expectedValue = rule.expected_value !== undefined ? rule.expected_value : 'true';
        const expectedValueType = rule.expected_value_type || 'bool';
        const threshold = rule.threshold !== undefined ? rule.threshold : 0;

        html += `
            <div class="rule-item input-rule-item" data-rule-index="${index}">
                <div class="rule-header">
                    <span class="rule-label">输入规则 ${index + 1}</span>
                    <button class="btn-icon" onclick="window.removeInputRule('${nodeId}', '${propName}', ${index})" title="删除规则">✕</button>
                </div>
                <div class="rule-config">
                    <input type="number" class="rule-input-index" min="0" title="输入序号"
                           value="${inputIndex}"
                           onchange="window.updateInputRule('${nodeId}', '${propName}', ${index}, 'input_index', parseInt(this.value, 10))">
                    <input type="text" class="rule-value" placeholder="payload.ok"
                           value="${valuePath}"
                           onchange="window.updateInputRule('${nodeId}', '${propName}', ${index}, 'value_path', this.value)">
                    <select class="rule-operator" onchange="window.updateInputRule('${nodeId}', '${propName}', ${index}, 'truth_mode', this.value)">
                        ${getLogicTruthModeOptions(truthMode)}
                    </select>
                    ${renderLogicRuleCompareValue(nodeId, propName, index, truthMode, expectedValue, expectedValueType, threshold)}
                </div>
            </div>
        `;
    });

    html += `
        <button class="btn btn-secondary btn-sm" onclick="window.addInputRule('${nodeId}', '${propName}')">+ 添加输入规则</button>
    </div>`;

    return html;
}

function getLogicTruthModeOptions(selected) {
    const modes = [
        { value: 'boolean', label: '布尔' },
        { value: 'equals', label: '==' },
        { value: 'not_equals', label: '!=' },
        { value: 'gt', label: '>' },
        { value: 'gte', label: '>=' },
        { value: 'lt', label: '<' },
        { value: 'lte', label: '<=' },
        { value: 'exists', label: '存在' },
        { value: 'not_exists', label: '不存在' },
        { value: 'is_empty', label: '为空' },
        { value: 'is_not_empty', label: '非空' },
    ];

    return modes.map(mode =>
        `<option value="${mode.value}" ${mode.value === selected ? 'selected' : ''}>${mode.label}</option>`
    ).join('');
}

function renderLogicRuleCompareValue(nodeId, propName, index, truthMode, expectedValue, expectedValueType, threshold) {
    if (['gt', 'gte', 'lt', 'lte'].includes(truthMode)) {
        return `
            <input type="number" class="rule-value" placeholder="阈值"
                   value="${threshold}"
                   onchange="window.updateInputRule('${nodeId}', '${propName}', ${index}, 'threshold', parseFloat(this.value))">
        `;
    }

    if (truthMode === 'equals' || truthMode === 'not_equals') {
        return `
            <input type="text" class="rule-value" placeholder="期望值"
                   value="${expectedValue}"
                   onchange="window.updateInputRule('${nodeId}', '${propName}', ${index}, 'expected_value', this.value)">
            <select class="rule-type" onchange="window.updateInputRule('${nodeId}', '${propName}', ${index}, 'expected_value_type', this.value)">
                ${getValueTypeOptions(expectedValueType)}
            </select>
        `;
    }

    if (['exists', 'not_exists', 'is_empty', 'is_not_empty'].includes(truthMode)) {
        return '<span class="property-help">只判断字段状态</span>';
    }

    return '<span class="property-help">按布尔值转换</span>';
}

export function addInputRule(nodeId, propName) {
    const nodeData = state.nodes.get(nodeId);
    const rules = nodeData.config[propName] || [];

    rules.push({
        input_index: rules.length,
        value_path: 'payload',
        truth_mode: 'boolean',
        expected_value: 'true',
        expected_value_type: 'bool',
        threshold: 0
    });

    nodeData.config[propName] = rules;
    markNodeModified(nodeId);
    setModified(true);
    renderProperties(nodeData);
}

export function removeInputRule(nodeId, propName, ruleIndex) {
    const nodeData = state.nodes.get(nodeId);
    const rules = nodeData.config[propName] || [];

    rules.splice(ruleIndex, 1);
    nodeData.config[propName] = rules;

    markNodeModified(nodeId);
    setModified(true);
    renderProperties(nodeData);
}

export function updateInputRule(nodeId, propName, ruleIndex, field, value) {
    const nodeData = state.nodes.get(nodeId);
    const rules = nodeData.config[propName] || [];

    if (rules[ruleIndex]) {
        rules[ruleIndex][field] = value;
        nodeData.config[propName] = rules;

        if (field === 'truth_mode') {
            renderProperties(nodeData);
        }

        markNodeModified(nodeId);
        setModified(true);
    }
}

function renderJsonBuilderMappingsEditor(nodeId, propName, mappings) {
    let html = '<div class="rules-editor json-builder-mappings-editor">';

    mappings.forEach((mapping, index) => {
        html += renderJsonBuilderMappingItem(nodeId, propName, mapping, index);
    });

    html += `
        <button class="btn btn-secondary btn-sm" onclick="window.addJsonBuilderMapping('${nodeId}', '${propName}')">+ 添加字段映射</button>
        ${renderJsonBuilderPreview(nodeId, mappings)}
    </div>`;

    return html;
}

function renderJsonBuilderTemplateEditor(nodeId, propName, templateText) {
    const value = String(templateText || '');
    const nodeData = state.nodes.get(nodeId);
    const outputMode = nodeData?.config?.output_mode || 'replace_payload';
    const result = buildJsonBuilderTemplatePreview(value, outputMode);
    const preview = JSON.stringify(result.preview, null, 2);
    const errors = result.errors.length ? `
        <div class="json-builder-preview-errors">
            ${result.errors.map(error => `<div>${escapeHtml(error)}</div>`).join('')}
        </div>
    ` : '';

    return `
        <div class="json-builder-template-editor">
            <textarea class="property-input property-textarea json-builder-template-textarea"
                      placeholder='{"barcode":"{{payload.code_reader.code}}","camera":{"id":"{{payload.frame_source.camera_id}}"}}'
                      onchange="window.updateJsonBuilderTemplate('${nodeId}', '${propName}', this.value)">${escapeHtml(value)}</textarea>
            <div class="json-builder-template-actions">
                <button class="btn btn-secondary btn-sm" onclick="window.openJsonBuilderTemplateLibrary('${nodeId}', '${propName}')">加载模板</button>
                <button class="btn btn-secondary btn-sm" onclick="window.saveCurrentJsonBuilderTemplate('${nodeId}', '${propName}')">保存为模板</button>
                <button class="btn btn-secondary btn-sm" onclick="window.openJsonBuilderTemplateLibrary('${nodeId}', '${propName}')">管理模板</button>
            </div>
            <div class="property-help">
                使用 {{payload.xxx}} 引用上游字段；占位符单独作为字符串值时会保留原始类型。
            </div>
            <div class="json-builder-preview">
                <div class="json-builder-preview-header">
                    <span>${getJsonBuilderPreviewTitle(outputMode)}</span>
                    <span class="json-builder-preview-hint">保存格式不变，仅预览模板结构</span>
                </div>
                <pre>${escapeHtml(preview)}</pre>
                ${errors}
            </div>
        </div>
    `;
}

function renderJsonBuilderMappingItem(nodeId, propName, mapping, index) {
    const target = mapping.target || '';
    const sourceType = mapping.source_type || 'path';
    const source = mapping.source || '';
    const value = mapping.value !== undefined ? mapping.value : '';
    const valueType = mapping.value_type || 'str';
    const defaultValue = mapping.default_value !== undefined ? mapping.default_value : '';
    const defaultValueType = mapping.default_value_type || 'str';
    const missingPolicy = mapping.missing_policy || '';

    return `
        <div class="rule-item json-builder-mapping-item" data-rule-index="${index}">
            <div class="rule-header">
                <span class="rule-label">映射 ${index + 1}</span>
                <button class="btn-icon" onclick="window.removeJsonBuilderMapping('${nodeId}', '${propName}', ${index})" title="删除映射">✕</button>
            </div>
            <div class="rule-config">
                <input type="text" class="rule-value" placeholder="目标路径，如 barcode"
                       value="${escapeHtml(target)}"
                       onchange="window.updateJsonBuilderMapping('${nodeId}', '${propName}', ${index}, 'target', this.value)">
                <select class="rule-operator" onchange="window.updateJsonBuilderMapping('${nodeId}', '${propName}', ${index}, 'source_type', this.value)">
                    ${getJsonBuilderSourceTypeOptions(sourceType)}
                </select>
                ${renderJsonBuilderSourceInput(nodeId, propName, index, sourceType, source, value, valueType)}
            </div>
            ${renderJsonBuilderMissingPolicy(nodeId, propName, index, sourceType, missingPolicy, defaultValue, defaultValueType)}
        </div>
    `;
}

function getJsonBuilderSourceTypeOptions(selected) {
    const types = [
        { value: 'path', label: '消息字段' },
        { value: 'const', label: '固定值' },
        { value: 'timestamp', label: '时间戳' },
        { value: 'uuid', label: 'UUID' },
        { value: 'null', label: '空值' },
        { value: 'msg', label: '原始消息' },
    ];

    return types.map(type =>
        `<option value="${type.value}" ${type.value === selected ? 'selected' : ''}>${type.label}</option>`
    ).join('');
}

function renderJsonBuilderSourceInput(nodeId, propName, index, sourceType, source, value, valueType) {
    if (sourceType === 'path') {
        const options = getJsonBuilderSourcePathOptions(nodeId, source);
        return `
            <div class="json-builder-source-picker">
                <select class="rule-value"
                        onchange="this.value && window.updateJsonBuilderMapping('${nodeId}', '${propName}', ${index}, 'source', this.value)">
                    ${options}
                </select>
                <input type="text" class="rule-value" placeholder="自定义路径"
                       value="${escapeHtml(source)}"
                       onchange="window.updateJsonBuilderMapping('${nodeId}', '${propName}', ${index}, 'source', this.value)">
            </div>
        `;
    }

    if (sourceType === 'const') {
        return `
            <input type="text" class="rule-value" placeholder="固定值"
                   value="${escapeHtml(value)}"
                   onchange="window.updateJsonBuilderMapping('${nodeId}', '${propName}', ${index}, 'value', this.value)">
            <select class="rule-type" onchange="window.updateJsonBuilderMapping('${nodeId}', '${propName}', ${index}, 'value_type', this.value)">
                ${getValueTypeOptions(valueType)}
            </select>
        `;
    }

    return '<span class="property-help">自动生成</span>';
}

function getJsonBuilderSourcePathOptions(nodeId, selected) {
    const groups = buildJsonBuilderSourcePathGroups(nodeId);
    const knownValues = new Set(groups.flatMap(group => group.options.map(option => option.value)));
    const selectedValue = String(selected || '').trim();

    let html = `<option value="" ${selectedValue ? '' : 'selected'}>选择来源字段</option>`;
    if (selectedValue && !knownValues.has(selectedValue)) {
        html += `<option value="${escapeHtml(selectedValue)}" selected>当前: ${escapeHtml(selectedValue)}</option>`;
    }

    groups.forEach(group => {
        html += `<optgroup label="${escapeHtml(group.label)}">`;
        group.options.forEach(option => {
            const isSelected = option.value === selectedValue ? 'selected' : '';
            html += `<option value="${escapeHtml(option.value)}" ${isSelected}>${escapeHtml(option.label)}</option>`;
        });
        html += '</optgroup>';
    });

    return html;
}

function buildJsonBuilderSourcePathGroups(nodeId) {
    const groups = [
        {
            label: '常用消息字段',
            options: [
                { value: 'payload', label: 'payload' },
                { value: 'topic', label: 'topic' },
                { value: '_msgid', label: '_msgid' },
                { value: '_timestamp', label: '_timestamp' },
            ]
        },
        {
            label: '常用业务字段',
            options: [
                { value: 'payload.value', label: 'payload.value' },
                { value: 'payload.result', label: 'payload.result' },
                { value: 'payload.ok', label: 'payload.ok' },
                { value: 'payload.error', label: 'payload.error' },
                { value: 'payload.code', label: 'payload.code' },
            ]
        },
        {
            label: '图像 / AI 字段',
            options: [
                { value: 'payload.image', label: 'payload.image' },
                { value: 'payload.image.width', label: 'payload.image.width' },
                { value: 'payload.image.height', label: 'payload.image.height' },
                { value: 'payload.ai.success', label: 'payload.ai.success' },
                { value: 'payload.ai.engine', label: 'payload.ai.engine' },
                { value: 'payload.ai.detections', label: 'payload.ai.detections' },
                { value: 'payload.ai.prediction_count', label: 'payload.ai.prediction_count' },
                { value: 'payload.detections', label: 'payload.detections' },
                { value: 'payload.detection_count', label: 'payload.detection_count' },
            ]
        }
    ];

    const upstreamOptions = getJsonBuilderUpstreamSourceOptions(nodeId);
    if (upstreamOptions.length) {
        groups.unshift({
            label: '来自上游节点',
            options: upstreamOptions
        });
    }

    return groups;
}

function getJsonBuilderUpstreamSourceOptions(nodeId) {
    const incoming = state.connections.filter(connection => connection.target === nodeId);
    const seen = new Set();
    const options = [];

    incoming.forEach(connection => {
        const sourceNode = state.nodes.get(connection.source);
        if (!sourceNode) return;

        const paths = getJsonBuilderNodeSchemaPathsForNode(sourceNode.id);
        paths.forEach(path => {
            const key = `${sourceNode.id}:${path}`;
            if (seen.has(key)) return;
            seen.add(key);
            options.push({
                value: path,
                label: `${sourceNode.name || sourceNode.type}: ${path}`
            });
        });
    });

    return options;
}

function getJsonBuilderNodeSchemaPathsForNode(nodeId, visited = new Set()) {
    if (visited.has(nodeId)) return [];
    visited.add(nodeId);

    const node = state.nodes.get(nodeId);
    if (!node) return [];

    const typeMeta = getNodeType(node.type);
    const schema = typeMeta?.outputSchema;
    const paths = flattenJsonBuilderSchemaPaths(schema);

    if (schema?.__passthrough_payload === true) {
        state.connections
            .filter(connection => connection.target === nodeId)
            .forEach(connection => {
                getJsonBuilderNodeSchemaPathsForNode(connection.source, visited)
                    .forEach(path => {
                        if (path === 'payload' || path.startsWith('payload.')) {
                            paths.push(path);
                        }
                    });
            });
    }

    return [...new Set(paths)];
}

function getJsonBuilderNodeTypeSchemaPaths(nodeType) {
    const typeMeta = getNodeType(nodeType);
    const schemaPaths = flattenJsonBuilderSchemaPaths(typeMeta?.outputSchema);
    if (schemaPaths.length) return schemaPaths;

    return [
        'payload',
        'payload.value',
        'payload.result',
        'topic'
    ];
}

function flattenJsonBuilderSchemaPaths(schema, prefix = '') {
    if (!schema || typeof schema !== 'object' || Array.isArray(schema)) {
        return prefix ? [prefix] : [];
    }

    const paths = [];
    Object.entries(schema).forEach(([key, value]) => {
        if (key.startsWith('__')) return;
        const path = prefix ? `${prefix}.${key}` : key;
        paths.push(path);
        if (value && typeof value === 'object' && !Array.isArray(value)) {
            paths.push(...flattenJsonBuilderSchemaPaths(value, path));
        }
    });

    return [...new Set(paths)];
}

function renderJsonBuilderMissingPolicy(nodeId, propName, index, sourceType, missingPolicy, defaultValue, defaultValueType) {
    if (sourceType !== 'path') {
        return '';
    }

    return `
        <div class="rule-config">
            <span class="property-help">缺失</span>
            <select class="rule-operator" onchange="window.updateJsonBuilderMapping('${nodeId}', '${propName}', ${index}, 'missing_policy', this.value)">
                <option value="" ${missingPolicy === '' ? 'selected' : ''}>使用全局策略</option>
                <option value="skip" ${missingPolicy === 'skip' ? 'selected' : ''}>跳过</option>
                <option value="null" ${missingPolicy === 'null' ? 'selected' : ''}>写 null</option>
                <option value="default" ${missingPolicy === 'default' ? 'selected' : ''}>默认值</option>
                <option value="error" ${missingPolicy === 'error' ? 'selected' : ''}>报错</option>
            </select>
            ${missingPolicy === 'default' ? `
                <input type="text" class="rule-value" placeholder="默认值"
                       value="${escapeHtml(defaultValue)}"
                       onchange="window.updateJsonBuilderMapping('${nodeId}', '${propName}', ${index}, 'default_value', this.value)">
                <select class="rule-type" onchange="window.updateJsonBuilderMapping('${nodeId}', '${propName}', ${index}, 'default_value_type', this.value)">
                    ${getValueTypeOptions(defaultValueType)}
                </select>
            ` : ''}
        </div>
    `;
}

function renderJsonBuilderPreview(nodeId, mappings) {
    const nodeData = state.nodes.get(nodeId);
    const outputMode = nodeData?.config?.output_mode || 'replace_payload';
    const result = buildJsonBuilderPreview(mappings, outputMode);
    const preview = JSON.stringify(result.preview, null, 2);
    const title = getJsonBuilderPreviewTitle(outputMode);
    const errors = result.errors.length ? `
        <div class="json-builder-preview-errors">
            ${result.errors.map(error => `<div>${escapeHtml(error)}</div>`).join('')}
        </div>
    ` : '';

    return `
        <div class="json-builder-preview">
            <div class="json-builder-preview-header">
                <span>${title}</span>
                <span class="json-builder-preview-hint">保存格式不变，仅预览映射结构</span>
            </div>
            <pre>${escapeHtml(preview)}</pre>
            ${errors}
        </div>
    `;
}

function getJsonBuilderPreviewTitle(outputMode) {
    const titles = {
        replace_payload: '输出 payload 预览',
        merge_payload: '合并 payload 预览',
        replace_msg: '整条消息预览',
        merge_msg: '合并消息预览'
    };
    return titles[outputMode] || '输出预览';
}

function buildJsonBuilderPreview(mappings, outputMode) {
    const built = {};
    const errors = [];
    const stripPayloadPrefix = outputMode === 'replace_payload' || outputMode === 'merge_payload';

    (Array.isArray(mappings) ? mappings : []).forEach((mapping, index) => {
        if (!mapping || typeof mapping !== 'object') return;

        const rawTarget = String(mapping.target || '').trim();
        if (!rawTarget) return;

        const targetPath = normalizeJsonBuilderTargetPath(rawTarget, stripPayloadPrefix, errors, index);
        if (!targetPath) return;

        setJsonBuilderPreviewPath(built, targetPath, getJsonBuilderPreviewValue(mapping));
    });

    return {
        preview: wrapJsonBuilderPreviewOutput(built, outputMode),
        errors
    };
}

function normalizeJsonBuilderTargetPath(path, stripPayloadPrefix, errors, index) {
    let target = path.startsWith('msg.') ? path.slice(4) : path;

    if (stripPayloadPrefix && target === 'payload') {
        errors.push(`映射 ${index + 1}: 当前输出模式下目标不能只写 payload`);
        return '';
    }
    if (stripPayloadPrefix && target.startsWith('payload.')) {
        target = target.slice(8);
    }

    return target;
}

function getJsonBuilderPreviewValue(mapping) {
    const sourceType = mapping.source_type || 'path';

    if (sourceType === 'path') {
        const source = String(mapping.source || '').trim();
        if (source) {
            return `{{${source.startsWith('msg.') ? source.slice(4) : source}}}`;
        }
        if (mapping.missing_policy === 'default') {
            return parseJsonBuilderTypedValue(mapping.default_value, mapping.default_value_type || 'str');
        }
        return '{{选择来源字段}}';
    }
    if (sourceType === 'const') {
        return parseJsonBuilderTypedValue(mapping.value, mapping.value_type || 'str');
    }
    if (sourceType === 'timestamp') return '{{当前时间戳}}';
    if (sourceType === 'uuid') return '{{UUID}}';
    if (sourceType === 'null') return null;
    if (sourceType === 'msg') return '{{原始消息}}';

    return mapping.value ?? '';
}

function parseJsonBuilderTypedValue(value, valueType) {
    if (valueType === 'num') {
        const number = Number(value);
        return Number.isFinite(number) ? number : 0;
    }
    if (valueType === 'bool') {
        if (typeof value === 'boolean') return value;
        return ['true', '1', 'yes', 'on'].includes(String(value).toLowerCase());
    }
    if (valueType === 'json') {
        try {
            return typeof value === 'string' ? JSON.parse(value) : value;
        } catch {
            return value ?? '';
        }
    }
    if (valueType === 'null') return null;
    return value === null || value === undefined ? '' : String(value);
}

function setJsonBuilderPreviewPath(obj, path, value) {
    const parts = path.split('.').filter(Boolean);
    if (!parts.length) return;

    let current = obj;
    parts.slice(0, -1).forEach(part => {
        const arrayMatch = part.match(/^(\w+)\[(\d+)\]$/);
        if (arrayMatch) {
            const [, key, indexText] = arrayMatch;
            const index = Number(indexText);
            if (!Array.isArray(current[key])) current[key] = [];
            while (current[key].length <= index) current[key].push({});
            if (!current[key][index] || typeof current[key][index] !== 'object') {
                current[key][index] = {};
            }
            current = current[key][index];
            return;
        }

        if (!current[part] || typeof current[part] !== 'object' || Array.isArray(current[part])) {
            current[part] = {};
        }
        current = current[part];
    });

    const finalPart = parts[parts.length - 1];
    const finalArrayMatch = finalPart.match(/^(\w+)\[(\d+)\]$/);
    if (finalArrayMatch) {
        const [, key, indexText] = finalArrayMatch;
        const index = Number(indexText);
        if (!Array.isArray(current[key])) current[key] = [];
        while (current[key].length <= index) current[key].push(null);
        current[key][index] = value;
        return;
    }

    current[finalPart] = value;
}

function wrapJsonBuilderPreviewOutput(built, outputMode) {
    if (outputMode === 'replace_msg') return built;
    if (outputMode === 'merge_msg') {
        return {
            '...现有 msg': '保留',
            ...built
        };
    }
    if (outputMode === 'merge_payload') {
        return {
            payload: {
                '...现有 payload': '保留',
                ...built
            }
        };
    }
    return { payload: built };
}

function buildJsonBuilderTemplatePreview(templateText, outputMode) {
    const errors = [];
    let built = {};
    const text = String(templateText || '').trim();

    if (text) {
        try {
            built = resolveJsonBuilderTemplatePreviewValue(JSON.parse(text));
        } catch (error) {
            errors.push(`模板 JSON 格式错误: ${error.message}`);
        }
    }

    return {
        preview: wrapJsonBuilderPreviewOutput(built, outputMode),
        errors
    };
}

function resolveJsonBuilderTemplatePreviewValue(value) {
    if (Array.isArray(value)) {
        return value.map(item => resolveJsonBuilderTemplatePreviewValue(item));
    }
    if (value && typeof value === 'object') {
        return Object.fromEntries(
            Object.entries(value).map(([key, item]) => [key, resolveJsonBuilderTemplatePreviewValue(item)])
        );
    }
    if (typeof value !== 'string') {
        return value;
    }

    const fullMatch = value.match(/^\s*\{\{\s*([^{}]+?)\s*\}\}\s*$/);
    if (fullMatch) {
        return `{{${fullMatch[1].trim()}}}`;
    }
    return value.replace(/\{\{\s*([^{}]+?)\s*\}\}/g, (_, path) => `{{${path.trim()}}}`);
}

export function addJsonBuilderMapping(nodeId, propName) {
    const nodeData = state.nodes.get(nodeId);
    const mappings = nodeData.config[propName] || [];

    mappings.push({
        target: '',
        source_type: 'path',
        source: '',
        value: '',
        value_type: 'str',
        missing_policy: ''
    });

    nodeData.config[propName] = mappings;
    markNodeModified(nodeId);
    setModified(true);
    renderProperties(nodeData);
}

export function removeJsonBuilderMapping(nodeId, propName, mappingIndex) {
    const nodeData = state.nodes.get(nodeId);
    const mappings = nodeData.config[propName] || [];

    mappings.splice(mappingIndex, 1);
    nodeData.config[propName] = mappings;

    markNodeModified(nodeId);
    setModified(true);
    renderProperties(nodeData);
}

export function updateJsonBuilderMapping(nodeId, propName, mappingIndex, field, value) {
    const nodeData = state.nodes.get(nodeId);
    const mappings = nodeData.config[propName] || [];

    if (mappings[mappingIndex]) {
        mappings[mappingIndex][field] = value;
        nodeData.config[propName] = mappings;

        if (['target', 'source', 'source_type', 'value', 'value_type', 'missing_policy', 'default_value', 'default_value_type'].includes(field)) {
            renderProperties(nodeData);
        }

        markNodeModified(nodeId);
        setModified(true);
    }
}

export function updateJsonBuilderTemplate(nodeId, propName, value) {
    const nodeData = state.nodes.get(nodeId);
    nodeData.config[propName] = value;

    markNodeModified(nodeId);
    setModified(true);
    renderProperties(nodeData);
}

function getCurrentJsonBuilderTemplateText(nodeId, propName) {
    const textarea = document.querySelector('.json-builder-template-textarea');
    if (textarea) return textarea.value;

    const nodeData = state.nodes.get(nodeId);
    return String(nodeData?.config?.[propName] || '');
}

function validateJsonBuilderTemplateText(templateText) {
    const text = String(templateText || '').trim();
    if (!text) return true;
    try {
        JSON.parse(text);
        return true;
    } catch (error) {
        showToast(`模板 JSON 格式错误: ${error.message}`, 'error');
        return false;
    }
}

async function requestJsonBuilderTemplates(path = '', options = {}) {
    const response = await fetch(`${JSON_BUILDER_TEMPLATES_API}${path}`, {
        ...options,
        headers: { 'Content-Type': 'application/json', ...(options.headers || {}) }
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok || data.success === false) {
        throw new Error(data.error || `请求失败 (${response.status})`);
    }
    return data;
}

async function loadJsonBuilderTemplateList() {
    const data = await requestJsonBuilderTemplates();
    return Array.isArray(data.templates) ? data.templates : [];
}

function getJsonBuilderTemplateLibraryState() {
    const modal = document.getElementById('json-builder-template-modal');
    if (!modal) return null;
    return {
        modal,
        nodeId: modal.dataset.nodeId,
        propName: modal.dataset.propName,
        selectedId: modal.dataset.selectedId || ''
    };
}

function setJsonBuilderTemplateEditor(template) {
    const nameEl = document.getElementById('json-builder-template-name');
    const descEl = document.getElementById('json-builder-template-description');
    const textEl = document.getElementById('json-builder-template-json');
    const idEl = document.getElementById('json-builder-template-id');
    if (!nameEl || !descEl || !textEl || !idEl) return;

    idEl.value = template?.id || '';
    nameEl.value = template?.name || '';
    descEl.value = template?.description || '';
    textEl.value = template?.template_json || '';
    setJsonBuilderTemplateReadonlyState(Boolean(template?.read_only));
}

function setJsonBuilderTemplateReadonlyState(readOnly) {
    const updateBtn = document.getElementById('json-builder-template-update-btn');
    const deleteBtn = document.getElementById('json-builder-template-delete-btn');
    if (updateBtn) {
        updateBtn.disabled = readOnly;
        updateBtn.title = readOnly ? '系统内置模板不能覆盖，可另存为新模板' : '';
    }
    if (deleteBtn) {
        deleteBtn.disabled = readOnly;
        deleteBtn.title = readOnly ? '系统内置模板不能删除' : '';
    }
}

function renderJsonBuilderTemplateList(templates, selectedId = '') {
    const listEl = document.getElementById('json-builder-template-list');
    if (!listEl) return;

    if (!templates.length) {
        listEl.innerHTML = '<div class="json-builder-template-empty">暂无模板</div>';
        return;
    }

    listEl.innerHTML = templates.map(template => `
        <button class="json-builder-template-list-item ${template.id === selectedId ? 'active' : ''}"
                onclick="window.selectJsonBuilderTemplate('${escapeHtml(template.id)}')">
            <span>
                ${escapeHtml(template.name || '未命名模板')}
                ${template.source === 'builtin' ? '<em class="json-builder-template-badge">系统</em>' : ''}
            </span>
            <small>${escapeHtml(template.description || '无说明')}</small>
        </button>
    `).join('');
}

async function refreshJsonBuilderTemplateLibrary(selectedId = '') {
    const stateInfo = getJsonBuilderTemplateLibraryState();
    if (!stateInfo) return;

    const templates = await loadJsonBuilderTemplateList();
    stateInfo.modal._templates = templates;
    stateInfo.modal.dataset.selectedId = selectedId;
    renderJsonBuilderTemplateList(templates, selectedId);

    const selected = templates.find(template => template.id === selectedId);
    if (selected) {
        setJsonBuilderTemplateEditor(selected);
    } else if (selectedId) {
        setJsonBuilderTemplateEditor(null);
    }
}

window.openJsonBuilderTemplateLibrary = async function(nodeId, propName) {
    window.closeJsonBuilderTemplateLibrary();

    const currentTemplate = getCurrentJsonBuilderTemplateText(nodeId, propName);
    const modalHtml = `
        <div class="mqtt-service-modal" id="json-builder-template-modal" data-node-id="${escapeHtml(nodeId)}" data-prop-name="${escapeHtml(propName)}">
            <div class="mqtt-service-modal-content json-builder-template-modal-content">
                <div class="mqtt-service-modal-header">
                    <h3>JSON 构建器模板库</h3>
                    <button class="mqtt-service-modal-close" onclick="window.closeJsonBuilderTemplateLibrary()">&times;</button>
                </div>
                <div class="mqtt-service-modal-body json-builder-template-modal-body">
                    <div class="json-builder-template-library">
                        <div class="json-builder-template-list" id="json-builder-template-list">
                            <div class="json-builder-template-empty">加载中...</div>
                        </div>
                        <div class="json-builder-template-form">
                            <input type="hidden" id="json-builder-template-id" value="">
                            <div class="property-group">
                                <label class="property-label">模板名称</label>
                                <input type="text" class="property-input" id="json-builder-template-name" placeholder="如：扫码结果上报">
                            </div>
                            <div class="property-group">
                                <label class="property-label">说明</label>
                                <input type="text" class="property-input" id="json-builder-template-description" placeholder="可选">
                            </div>
                            <div class="property-group">
                                <label class="property-label">模板 JSON</label>
                                <textarea class="property-input property-textarea json-builder-template-library-textarea"
                                          id="json-builder-template-json"
                                          placeholder='{"barcode":"{{payload.code_reader.code}}"}'>${escapeHtml(currentTemplate)}</textarea>
                            </div>
                        </div>
                    </div>
                </div>
                <div class="mqtt-service-modal-footer">
                    <button class="btn btn-secondary" onclick="window.resetJsonBuilderTemplateEditor()">使用当前节点内容</button>
                    <div class="mqtt-service-modal-actions">
                        <button class="btn btn-danger" id="json-builder-template-delete-btn" onclick="window.deleteSelectedJsonBuilderTemplate()">删除</button>
                        <button class="btn btn-secondary" onclick="window.applySelectedJsonBuilderTemplate()">应用到节点</button>
                        <button class="btn btn-secondary" id="json-builder-template-update-btn" onclick="window.updateSelectedJsonBuilderTemplate()">覆盖模板</button>
                        <button class="btn btn-primary" onclick="window.createJsonBuilderTemplateFromLibrary()">保存为新模板</button>
                    </div>
                </div>
            </div>
        </div>
    `;

    document.body.insertAdjacentHTML('beforeend', modalHtml);

    try {
        await refreshJsonBuilderTemplateLibrary();
    } catch (error) {
        showToast(`加载模板失败: ${error.message}`, 'error');
    }
};

window.closeJsonBuilderTemplateLibrary = function() {
    const modal = document.getElementById('json-builder-template-modal');
    if (modal) modal.remove();
};

window.selectJsonBuilderTemplate = function(templateId) {
    const stateInfo = getJsonBuilderTemplateLibraryState();
    if (!stateInfo) return;

    const templates = stateInfo.modal._templates || [];
    const selected = templates.find(template => template.id === templateId);
    stateInfo.modal.dataset.selectedId = templateId;
    renderJsonBuilderTemplateList(templates, templateId);
    setJsonBuilderTemplateEditor(selected || null);
};

window.resetJsonBuilderTemplateEditor = function() {
    const stateInfo = getJsonBuilderTemplateLibraryState();
    if (!stateInfo) return;
    stateInfo.modal.dataset.selectedId = '';
    renderJsonBuilderTemplateList(stateInfo.modal._templates || [], '');
    setJsonBuilderTemplateEditor({
        template_json: getCurrentJsonBuilderTemplateText(stateInfo.nodeId, stateInfo.propName)
    });
};

window.saveCurrentJsonBuilderTemplate = async function(nodeId, propName) {
    const templateText = getCurrentJsonBuilderTemplateText(nodeId, propName);
    if (!validateJsonBuilderTemplateText(templateText)) return;

    const name = prompt('模板名称');
    if (!name || !name.trim()) return;

    try {
        await requestJsonBuilderTemplates('', {
            method: 'POST',
            body: JSON.stringify({
                name: name.trim(),
                description: '',
                template_json: templateText
            })
        });
        showToast('模板已保存');
    } catch (error) {
        showToast(`保存模板失败: ${error.message}`, 'error');
    }
};

function readJsonBuilderTemplateForm() {
    const id = document.getElementById('json-builder-template-id')?.value || '';
    const name = document.getElementById('json-builder-template-name')?.value.trim() || '';
    const description = document.getElementById('json-builder-template-description')?.value.trim() || '';
    const templateJson = document.getElementById('json-builder-template-json')?.value || '';
    return { id, name, description, template_json: templateJson };
}

window.createJsonBuilderTemplateFromLibrary = async function() {
    const payload = readJsonBuilderTemplateForm();
    if (!payload.name) {
        showToast('请填写模板名称', 'error');
        return;
    }
    if (!validateJsonBuilderTemplateText(payload.template_json)) return;

    try {
        const data = await requestJsonBuilderTemplates('', {
            method: 'POST',
            body: JSON.stringify(payload)
        });
        showToast('模板已保存');
        await refreshJsonBuilderTemplateLibrary(data.template.id);
    } catch (error) {
        showToast(`保存模板失败: ${error.message}`, 'error');
    }
};

window.updateSelectedJsonBuilderTemplate = async function() {
    const payload = readJsonBuilderTemplateForm();
    const stateInfo = getJsonBuilderTemplateLibraryState();
    const selected = (stateInfo?.modal?._templates || []).find(template => template.id === payload.id);
    if (!payload.id) {
        showToast('请先选择要覆盖的模板', 'error');
        return;
    }
    if (selected?.read_only) {
        showToast('系统内置模板不能覆盖，可保存为新模板', 'error');
        return;
    }
    if (!payload.name) {
        showToast('请填写模板名称', 'error');
        return;
    }
    if (!validateJsonBuilderTemplateText(payload.template_json)) return;

    try {
        await requestJsonBuilderTemplates(`/${encodeURIComponent(payload.id)}`, {
            method: 'PUT',
            body: JSON.stringify(payload)
        });
        showToast('模板已更新');
        await refreshJsonBuilderTemplateLibrary(payload.id);
    } catch (error) {
        showToast(`更新模板失败: ${error.message}`, 'error');
    }
};

window.deleteSelectedJsonBuilderTemplate = async function() {
    const payload = readJsonBuilderTemplateForm();
    const stateInfo = getJsonBuilderTemplateLibraryState();
    const selected = (stateInfo?.modal?._templates || []).find(template => template.id === payload.id);
    if (!payload.id) {
        showToast('请先选择要删除的模板', 'error');
        return;
    }
    if (selected?.read_only) {
        showToast('系统内置模板不能删除', 'error');
        return;
    }
    if (!confirm(`确认删除模板“${payload.name || payload.id}”？`)) return;

    try {
        await requestJsonBuilderTemplates(`/${encodeURIComponent(payload.id)}`, {
            method: 'DELETE'
        });
        showToast('模板已删除');
        setJsonBuilderTemplateEditor(null);
        await refreshJsonBuilderTemplateLibrary();
    } catch (error) {
        showToast(`删除模板失败: ${error.message}`, 'error');
    }
};

window.applySelectedJsonBuilderTemplate = function() {
    const stateInfo = getJsonBuilderTemplateLibraryState();
    const payload = readJsonBuilderTemplateForm();
    if (!stateInfo) return;
    if (!validateJsonBuilderTemplateText(payload.template_json)) return;

    updateJsonBuilderTemplate(stateInfo.nodeId, stateInfo.propName, payload.template_json);
    window.closeJsonBuilderTemplateLibrary();
    showToast('模板已应用到当前节点');
};

// Inject properties editor for inject node
function renderInjectPropsEditor(nodeId, propName, props) {
    let html = '<div class="inject-props-editor">';
    
    props.forEach((prop, index) => {
        html += `
            <div class="inject-prop-row" data-prop-index="${index}">
                <span class="inject-prop-prefix">msg.</span>
                <input type="text" class="inject-prop-key" placeholder="payload" 
                       value="${prop.property || ''}"
                       onchange="window.updateInjectProp('${nodeId}', '${propName}', ${index}, 'property', this.value)">
                <span class="inject-prop-eq">=</span>
                <select class="inject-prop-type" onchange="window.updateInjectProp('${nodeId}', '${propName}', ${index}, 'valueType', this.value)">
                    ${getInjectValueTypeOptions(prop.valueType || 'str')}
                </select>
                ${renderInjectValueInput(nodeId, propName, index, prop)}
                <button class="btn-icon-sm" onclick="window.removeInjectProp('${nodeId}', '${propName}', ${index})" title="Delete">✕</button>
            </div>
        `;
    });
    
    html += `
        <button class="btn btn-secondary btn-sm" onclick="window.addInjectProp('${nodeId}', '${propName}')">+ Add</button>
    </div>`;
    
    return html;
}

function getInjectValueTypeOptions(selected) {
    const types = [
        { value: 'str', icon: 'az', label: 'string' },
        { value: 'num', icon: '123', label: 'number' },
        { value: 'bool', icon: 't/f', label: 'boolean' },
        { value: 'json', icon: '{ }', label: 'JSON' },
        { value: 'date', icon: '⏱', label: 'timestamp' },
        { value: 'env', icon: 'env', label: 'env variable' }
    ];
    
    return types.map(type => 
        `<option value="${type.value}" ${type.value === selected ? 'selected' : ''} data-icon="${type.icon}">${type.value === selected ? type.icon : type.label}</option>`
    ).join('');
}

function renderInjectValueInput(nodeId, propName, index, prop) {
    const valueType = prop.valueType || 'str';
    const value = prop.value !== undefined ? prop.value : '';
    
    if (valueType === 'date') {
        return '<input type="text" class="inject-prop-value" disabled placeholder="timestamp">';
    } else if (valueType === 'bool') {
        return `<select class="inject-prop-value" onchange="window.updateInjectProp('${nodeId}', '${propName}', ${index}, 'value', this.value)"><option value="true" ${value === 'true' || value === true ? 'selected' : ''}>true</option><option value="false" ${value === 'false' || value === false ? 'selected' : ''}>false</option></select>`;
    } else if (valueType === 'json') {
        const escaped = String(value).replace(/"/g, '&quot;');
        return `<input type="text" class="inject-prop-value inject-prop-json" placeholder='{"key":"value"}' value="${escaped}" onchange="window.updateInjectProp('${nodeId}', '${propName}', ${index}, 'value', this.value)">`;
    } else {
        const placeholder = valueType === 'num' ? '0' : valueType === 'env' ? 'ENV_VAR' : '';
        return `<input type="text" class="inject-prop-value" placeholder="${placeholder}" value="${value}" onchange="window.updateInjectProp('${nodeId}', '${propName}', ${index}, 'value', this.value)">`;
    }
}

export function addInjectProp(nodeId, propName) {
    const nodeData = state.nodes.get(nodeId);
    const props = nodeData.config[propName] || [];
    
    props.push({
        property: 'payload',
        valueType: 'date',
        value: ''
    });
    
    nodeData.config[propName] = props;
    
    markNodeModified(nodeId);
    setModified(true);
    renderProperties(nodeData);
}

export function removeInjectProp(nodeId, propName, propIndex) {
    const nodeData = state.nodes.get(nodeId);
    const props = nodeData.config[propName] || [];
    
    if (props.length > 0) {
        props.splice(propIndex, 1);
        nodeData.config[propName] = props;
        
        markNodeModified(nodeId);
        setModified(true);
        renderProperties(nodeData);
    }
}

export function updateInjectProp(nodeId, propName, propIndex, field, value) {
    const nodeData = state.nodes.get(nodeId);
    const props = nodeData.config[propName] || [];
    
    if (props[propIndex]) {
        props[propIndex][field] = value;
        nodeData.config[propName] = props;
        
        // Re-render if type changed to update value input
        if (field === 'valueType') {
            renderProperties(nodeData);
        }
        
        markNodeModified(nodeId);
        setModified(true);
    }
}

// Change rules editor for change node (Node-RED style)
function renderChangeRulesEditor(nodeId, propName, rules, operations, valueTypes) {
    let html = '<div class="change-rules-editor">';
    
    rules.forEach((rule, index) => {
        html += renderChangeRuleItem(nodeId, propName, rule, index, operations, valueTypes);
    });
    
    html += `
        <button class="btn btn-secondary btn-sm" onclick="window.addChangeRule('${nodeId}', '${propName}')">+ Add Rule</button>
    </div>`;
    
    return html;
}

function renderChangeRuleItem(nodeId, propName, rule, index, operations, valueTypes) {
    const ruleType = rule.type || 'set';
    const path = rule.path || 'msg.payload';
    const value = rule.value !== undefined ? rule.value : '';
    const valueType = rule.valueType || 'str';
    const search = rule.search || '';
    const replace = rule.replace || '';
    const searchType = rule.searchType || 'str';
    const replaceType = rule.replaceType || 'str';
    
    let html = `
        <div class="change-rule-item" data-rule-index="${index}">
            <div class="change-rule-header">
                <select class="change-rule-type" onchange="window.updateChangeRule('${nodeId}', '${propName}', ${index}, 'type', this.value)">
                    ${getChangeRuleTypeOptions(ruleType, operations)}
                </select>
                <button class="btn-icon-sm" onclick="window.removeChangeRule('${nodeId}', '${propName}', ${index})" title="Delete rule">✕</button>
            </div>
            <div class="change-rule-config">
    `;
    
    if (ruleType === 'set') {
        html += `
            <div class="change-rule-row">
                <input type="text" class="change-rule-path" placeholder="msg.payload" 
                       value="${path}"
                       onchange="window.updateChangeRule('${nodeId}', '${propName}', ${index}, 'path', this.value)">
                <span class="change-rule-to">to</span>
                <select class="change-rule-value-type" onchange="window.updateChangeRule('${nodeId}', '${propName}', ${index}, 'valueType', this.value)">
                    ${getChangeValueTypeOptions(valueType, valueTypes)}
                </select>
                ${renderChangeValueInput(nodeId, propName, index, value, valueType)}
            </div>
        `;
    } else if (ruleType === 'change') {
        html += `
            <div class="change-rule-row">
                <span class="change-rule-label">in</span>
                <input type="text" class="change-rule-path" placeholder="msg.payload" 
                       value="${path}"
                       onchange="window.updateChangeRule('${nodeId}', '${propName}', ${index}, 'path', this.value)">
            </div>
            <div class="change-rule-row">
                <span class="change-rule-label">search</span>
                <select class="change-rule-search-type" onchange="window.updateChangeRule('${nodeId}', '${propName}', ${index}, 'searchType', this.value)">
                    ${getChangeSearchTypeOptions(searchType)}
                </select>
                <input type="text" class="change-rule-search" placeholder="search" 
                       value="${escapeHtml(search)}"
                       onchange="window.updateChangeRule('${nodeId}', '${propName}', ${index}, 'search', this.value)">
            </div>
            <div class="change-rule-row">
                <span class="change-rule-label">replace</span>
                <select class="change-rule-replace-type" onchange="window.updateChangeRule('${nodeId}', '${propName}', ${index}, 'replaceType', this.value)">
                    ${getChangeReplaceTypeOptions(replaceType)}
                </select>
                <input type="text" class="change-rule-replace" placeholder="replace" 
                       value="${escapeHtml(replace)}"
                       onchange="window.updateChangeRule('${nodeId}', '${propName}', ${index}, 'replace', this.value)">
            </div>
        `;
    } else if (ruleType === 'delete') {
        html += `
            <div class="change-rule-row">
                <input type="text" class="change-rule-path" placeholder="msg.payload" 
                       value="${path}"
                       onchange="window.updateChangeRule('${nodeId}', '${propName}', ${index}, 'path', this.value)">
            </div>
        `;
    } else if (ruleType === 'move') {
        const toPath = rule.toPath || '';
        html += `
            <div class="change-rule-row">
                <input type="text" class="change-rule-path" placeholder="msg.payload" 
                       value="${path}"
                       onchange="window.updateChangeRule('${nodeId}', '${propName}', ${index}, 'path', this.value)">
                <span class="change-rule-to">to</span>
                <input type="text" class="change-rule-to-path" placeholder="msg.newPayload" 
                       value="${toPath}"
                       onchange="window.updateChangeRule('${nodeId}', '${propName}', ${index}, 'toPath', this.value)">
            </div>
        `;
    }
    
    html += `
            </div>
        </div>
    `;
    
    return html;
}

function escapeHtml(str) {
    if (str === null || str === undefined) return '';
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
}

function getChangeRuleTypeOptions(selected, allowed) {
    const types = [
        { value: 'set', label: 'Set' },
        { value: 'change', label: 'Change' },
        { value: 'delete', label: 'Delete' },
        { value: 'move', label: 'Move' }
    ];
    
    return types.filter(type => !allowed || allowed.includes(type.value) || type.value === selected).map(type => 
        `<option value="${type.value}" ${type.value === selected ? 'selected' : ''}>${type.label}</option>`
    ).join('');
}

function getChangeValueTypeOptions(selected, allowed) {
    const types = [
        { value: 'str', label: 'string' },
        { value: 'num', label: 'number' },
        { value: 'bool', label: 'boolean' },
        { value: 'json', label: 'JSON' },
        { value: 'path', label: 'msg. path' },
        { value: 'date', label: 'timestamp' },
        { value: 'env', label: 'env var' }
    ];
    
    return types.filter(type => !allowed || allowed.includes(type.value) || type.value === selected).map(type => 
        `<option value="${type.value}" ${type.value === selected ? 'selected' : ''}>${type.label}</option>`
    ).join('');
}

function getChangeSearchTypeOptions(selected) {
    const types = [
        { value: 'str', label: 'string' },
        { value: 'regex', label: 'regex' }
    ];
    
    return types.map(type => 
        `<option value="${type.value}" ${type.value === selected ? 'selected' : ''}>${type.label}</option>`
    ).join('');
}

function getChangeReplaceTypeOptions(selected) {
    const types = [
        { value: 'str', label: 'string' },
        { value: 'path', label: 'msg. path' }
    ];
    
    return types.map(type => 
        `<option value="${type.value}" ${type.value === selected ? 'selected' : ''}>${type.label}</option>`
    ).join('');
}

function renderChangeValueInput(nodeId, propName, index, value, valueType) {
    const escaped = escapeHtml(value);
    
    if (valueType === 'bool') {
        const boolVal = value === true || value === 'true';
        return `<select class="change-rule-value" onchange="window.updateChangeRule('${nodeId}', '${propName}', ${index}, 'value', this.value === 'true')">
            <option value="true" ${boolVal ? 'selected' : ''}>true</option>
            <option value="false" ${!boolVal ? 'selected' : ''}>false</option>
        </select>`;
    } else if (valueType === 'date') {
        return '<input type="text" class="change-rule-value" disabled placeholder="timestamp">';
    } else if (valueType === 'json') {
        return `<input type="text" class="change-rule-value change-rule-json" placeholder='{"key":"value"}' value="${escaped}" onchange="window.updateChangeRule('${nodeId}', '${propName}', ${index}, 'value', this.value)">`;
    } else if (valueType === 'path') {
        return `<input type="text" class="change-rule-value" placeholder="payload.data" value="${escaped}" onchange="window.updateChangeRule('${nodeId}', '${propName}', ${index}, 'value', this.value)">`;
    } else {
        const placeholder = valueType === 'num' ? '0' : valueType === 'env' ? 'ENV_VAR' : '';
        return `<input type="text" class="change-rule-value" placeholder="${placeholder}" value="${escaped}" onchange="window.updateChangeRule('${nodeId}', '${propName}', ${index}, 'value', this.value)">`;
    }
}

export function addChangeRule(nodeId, propName) {
    const nodeData = state.nodes.get(nodeId);
    const rules = nodeData.config[propName] || [];
    
    rules.push({
        type: 'set',
        path: 'msg.payload',
        value: '',
        valueType: 'str'
    });
    
    nodeData.config[propName] = rules;
    
    markNodeModified(nodeId);
    setModified(true);
    renderProperties(nodeData);
}

export function removeChangeRule(nodeId, propName, ruleIndex) {
    const nodeData = state.nodes.get(nodeId);
    const rules = nodeData.config[propName] || [];
    
    if (rules.length > 0) {
        rules.splice(ruleIndex, 1);
        nodeData.config[propName] = rules;
        
        markNodeModified(nodeId);
        setModified(true);
        renderProperties(nodeData);
    }
}

export function updateChangeRule(nodeId, propName, ruleIndex, field, value) {
    const nodeData = state.nodes.get(nodeId);
    const rules = nodeData.config[propName] || [];
    
    if (rules[ruleIndex]) {
        rules[ruleIndex][field] = value;
        nodeData.config[propName] = rules;
        
        // Re-render if type changed to update inputs
        if (field === 'type' || field === 'valueType') {
            renderProperties(nodeData);
        }
        
        markNodeModified(nodeId);
        setModified(true);
    }
}

// Update property visibility based on current config values
window.updatePropertyVisibility = function(nodeId) {
    const nodeData = state.nodes.get(nodeId);
    if (!nodeData) return;
    
    const nodeType = getNodeType(nodeData.type);
    if (!nodeType || !nodeType.properties) return;
    
    // Get all property groups
    const propertyGroups = document.querySelectorAll('.property-group[data-show-if]');
    
    propertyGroups.forEach(group => {
        const showIfStr = group.getAttribute('data-show-if');
        if (!showIfStr) return;
        
        try {
            const showIf = JSON.parse(showIfStr);
            const shouldShow = shouldShowProperty(showIf, nodeData.config);
            
            if (shouldShow) {
                group.style.display = '';
            } else {
                group.style.display = 'none';
            }
        } catch (e) {
            console.error('Error parsing showIf condition:', e);
        }
    });
};

// ==============================================================================
// MQTT Service Management Functions
// ==============================================================================

// Load available MQTT services into a select dropdown
window.loadMqttServices = async function(nodeId, propName, currentServiceId) {
    try {
        const response = await fetch(`${API_BASE}/services/mqtt`);
        const data = await response.json();
        
        if (!data.success) {
            console.error('Failed to load MQTT services:', data.error);
            return;
        }
        
        const select = document.getElementById(`mqtt-service-${nodeId}`);
        if (!select) return;
        
        // Clear existing options except the first placeholder
        select.innerHTML = '<option value="">-- Select broker --</option>';
        
        // Add service options
        data.services.forEach(service => {
            const option = document.createElement('option');
            option.value = service.id;
            option.textContent = `${service.name} (${service.broker}:${service.port})`;
            if (service.id === currentServiceId) {
                option.selected = true;
            }
            select.appendChild(option);
        });
    } catch (error) {
        console.error('Error loading MQTT services:', error);
    }
};

// Handle MQTT service selection change
window.onMqttServiceSelect = function(nodeId, propName, serviceId) {
    const nodeData = state.nodes.get(nodeId);
    if (!nodeData) return;
    
    nodeData.config[propName] = serviceId;
    markNodeModified(nodeId);
    setModified(true);
};

// Open MQTT service editor modal
window.openMqttServiceEditor = function(nodeId, propName, isNew = false) {
    const nodeData = state.nodes.get(nodeId);
    const currentServiceId = isNew ? null : (nodeData?.config[propName] || null);
    
    // Create modal HTML
    const modalHtml = `
        <div class="mqtt-service-modal" id="mqtt-service-modal">
            <div class="mqtt-service-modal-content">
                <div class="mqtt-service-modal-header">
                    <h3>${isNew ? 'Add New MQTT Broker' : 'Edit MQTT Broker'}</h3>
                    <button class="mqtt-service-modal-close" onclick="window.closeMqttServiceModal()">&times;</button>
                </div>
                <div class="mqtt-service-modal-body">
                    <input type="hidden" id="mqtt-service-id" value="${currentServiceId || ''}">
                    <div class="property-group">
                        <label class="property-label">Name</label>
                        <input type="text" class="property-input" id="mqtt-service-name" placeholder="My MQTT Broker">
                    </div>
                    <div class="property-group">
                        <label class="property-label">Broker Address</label>
                        <input type="text" class="property-input" id="mqtt-service-broker" placeholder="localhost" value="localhost">
                    </div>
                    <div class="property-group">
                        <label class="property-label">Port</label>
                        <input type="number" class="property-input" id="mqtt-service-port" placeholder="1883" value="1883">
                    </div>
                    <div class="property-group">
                        <label class="property-label">Client ID (optional)</label>
                        <input type="text" class="property-input" id="mqtt-service-clientId" placeholder="Auto-generated if empty">
                    </div>
                    <div class="property-group">
                        <label class="property-label">Username (optional)</label>
                        <input type="text" class="property-input" id="mqtt-service-username">
                    </div>
                    <div class="property-group">
                        <label class="property-label">Password (optional)</label>
                        <input type="password" class="property-input" id="mqtt-service-password">
                    </div>
                </div>
                <div class="mqtt-service-modal-footer">
                    <button class="btn btn-secondary" onclick="window.testMqttService()">Test Connection</button>
                    <div class="mqtt-service-modal-actions">
                        ${!isNew ? '<button class="btn btn-danger" onclick="window.deleteMqttService(\'' + nodeId + '\', \'' + propName + '\')">Delete</button>' : ''}
                        <button class="btn btn-secondary" onclick="window.closeMqttServiceModal()">Cancel</button>
                        <button class="btn btn-primary" onclick="window.saveMqttService('${nodeId}', '${propName}', ${isNew})">Save</button>
                    </div>
                </div>
            </div>
        </div>
    `;
    
    // Add modal to page
    document.body.insertAdjacentHTML('beforeend', modalHtml);
    
    // If editing, load existing service data
    if (!isNew && currentServiceId) {
        window.loadMqttServiceData(currentServiceId);
    }
};

// Load existing service data into the editor
window.loadMqttServiceData = async function(serviceId) {
    try {
        const response = await fetch(`${API_BASE}/services/mqtt/${serviceId}`);
        const data = await response.json();
        
        if (data.success && data.service) {
            document.getElementById('mqtt-service-name').value = data.service.name || '';
            document.getElementById('mqtt-service-broker').value = data.service.broker || 'localhost';
            document.getElementById('mqtt-service-port').value = data.service.port || 1883;
            document.getElementById('mqtt-service-clientId').value = data.service.clientId || '';
            document.getElementById('mqtt-service-username').value = data.service.username || '';
            document.getElementById('mqtt-service-password').value = data.service.password || '';
        }
    } catch (error) {
        console.error('Error loading MQTT service:', error);
    }
};

// Close the MQTT service modal
window.closeMqttServiceModal = function() {
    const modal = document.getElementById('mqtt-service-modal');
    if (modal) {
        modal.remove();
    }
};

// Save MQTT service (create or update)
window.saveMqttService = async function(nodeId, propName, isNew) {
    const serviceId = document.getElementById('mqtt-service-id').value;
    const serviceData = {
        name: document.getElementById('mqtt-service-name').value,
        broker: document.getElementById('mqtt-service-broker').value,
        port: parseInt(document.getElementById('mqtt-service-port').value) || 1883,
        clientId: document.getElementById('mqtt-service-clientId').value,
        username: document.getElementById('mqtt-service-username').value,
        password: document.getElementById('mqtt-service-password').value
    };
    
    // Validate
    if (!serviceData.name) {
        alert('Please enter a name for the broker');
        return;
    }
    if (!serviceData.broker) {
        alert('Please enter a broker address');
        return;
    }
    
    try {
        let response;
        if (isNew || !serviceId) {
            // Create new service
            response = await fetch(`${API_BASE}/services/mqtt`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(serviceData)
            });
        } else {
            // Update existing service
            response = await fetch(`${API_BASE}/services/mqtt/${serviceId}`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(serviceData)
            });
        }
        
        const data = await response.json();
        
        if (data.success) {
            // Update node config with new/updated service ID
            const nodeData = state.nodes.get(nodeId);
            if (nodeData) {
                nodeData.config[propName] = data.service.id;
                markNodeModified(nodeId);
                setModified(true);
            }
            
            // Reload services dropdown
            await window.loadMqttServices(nodeId, propName, data.service.id);
            
            // Close modal
            window.closeMqttServiceModal();
        } else {
            alert('Failed to save: ' + (data.error || 'Unknown error'));
        }
    } catch (error) {
        console.error('Error saving MQTT service:', error);
        alert('Error saving MQTT service');
    }
};

// Test MQTT service connection
window.testMqttService = async function() {
    const serviceId = document.getElementById('mqtt-service-id').value;
    
    if (!serviceId) {
        // For new services, we need to save first
        alert('Please save the broker configuration first, then test the connection.');
        return;
    }
    
    try {
        const response = await fetch(`${API_BASE}/services/mqtt/${serviceId}/test`, {
            method: 'POST'
        });
        const data = await response.json();
        
        if (data.success) {
            if (data.connected) {
                alert('✓ Connection successful!');
            } else {
                alert('✗ Connection failed. Please check your settings.');
            }
        } else {
            alert('Test failed: ' + (data.error || 'Unknown error'));
        }
    } catch (error) {
        console.error('Error testing MQTT service:', error);
        alert('Error testing connection');
    }
};

// Delete MQTT service
window.deleteMqttService = async function(nodeId, propName) {
    const serviceId = document.getElementById('mqtt-service-id').value;
    
    if (!serviceId) return;
    
    if (!confirm('Are you sure you want to delete this broker configuration?')) {
        return;
    }
    
    try {
        const response = await fetch(`${API_BASE}/services/mqtt/${serviceId}`, {
            method: 'DELETE'
        });
        const data = await response.json();
        
        if (data.success) {
            // Clear node config
            const nodeData = state.nodes.get(nodeId);
            if (nodeData) {
                nodeData.config[propName] = '';
                markNodeModified(nodeId);
                setModified(true);
            }
            
            // Reload services dropdown
            await window.loadMqttServices(nodeId, propName, '');
            
            // Close modal
            window.closeMqttServiceModal();
        } else {
            alert('Failed to delete: ' + (data.error || 'Service may still be in use'));
        }
    } catch (error) {
        console.error('Error deleting MQTT service:', error);
        alert('Error deleting MQTT service');
    }
};
