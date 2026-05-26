// ── Picking Mode: 'product' (GT) or 'order' (SV) ──
let pickingMode = null; // auto-detected
let availableModes = [];
let selectedRuta = null;
let selectedRoutePlanId = null; // for order mode (ID_RoutePlan)
let rutasCache = [];
let pickersCache = [];
let assigningProduct = null;
let assigningPedido = null;
let refreshInterval = null;
let pendingIniciarRuta = null;

async function init() {
    await detectMode();
    await loadRutas();
    refreshInterval = setInterval(refreshData, 30000);
}

// ── Mode Detection ──

async function detectMode() {
    try {
        const res = await fetch('/api/auth/me');
        if (!res.ok) return;
        const user = await res.json();

        // Mode is determined by the selected centro's country
        const pais = user.selectedPais || 'GT';
        pickingMode = (pais === 'SV') ? 'order' : 'product';

        // Show centro name in navbar
        if (user.selectedCentroNombre) {
            const navInfo = document.querySelector('.nav-info');
            if (navInfo) {
                const badge = document.createElement('span');
                badge.className = 'centro-badge';
                badge.innerHTML = `<i class="bi bi-building"></i> ${user.selectedCentroNombre} <a href="/select-centro" style="color:var(--primary);margin-left:0.3rem;font-size:0.7rem" title="Cambiar centro"><i class="bi bi-arrow-repeat"></i></a>`;
                navInfo.insertBefore(badge, navInfo.firstChild);
            }
        }

        updateUIForMode();
    } catch (err) {
        console.error('Error detecting mode:', err);
        pickingMode = 'product';
    }
}

function updateUIForMode() {
    const brand = document.querySelector('.brand span');
    if (brand) {
        brand.textContent = pickingMode === 'product' ? 'Picking por Producto' : 'Picking por Pedido';
    }
}

// ══════════════════════════════════════════
// ── Rutas List (shared, mode-aware)
// ══════════════════════════════════════════

async function loadRutas() {
    try {
        const url = pickingMode === 'order' ? '/api/order/rutas' : '/api/rutas';
        const res = await fetch(url);
        rutasCache = await res.json();
        renderRutasList(rutasCache);
    } catch (err) {
        console.error('Error loading rutas:', err);
    }
}

function filterRutas(query) {
    if (!query) { renderRutasList(rutasCache); return; }
    const q = query.toLowerCase();
    const filtered = rutasCache.filter(r =>
        r.RouteNumber.toString().includes(q) ||
        (r.RouteName && r.RouteName.toLowerCase().includes(q))
    );
    renderRutasList(filtered);
}

function renderRutasList(rutas) {
    const list = document.getElementById('rutasList');
    document.getElementById('rutasCount').textContent = rutasCache.length;

    if (pickingMode === 'order') {
        list.innerHTML = rutas.map(r => renderRutaCardOrder(r)).join('');
    } else {
        list.innerHTML = rutas.map(r => renderRutaCardProduct(r)).join('');
    }
}

function renderRutaCardProduct(r) {
    const pct = r.TotalProductos > 0
        ? Math.round((r.ProductosFinalizados / r.TotalProductos) * 100) : 0;
    const estado = r.Estado || 'Pendiente';
    const estadoCss = estado.replace(' ', '');
    return `
    <div class="ruta-card estado-${estadoCss} ${selectedRuta === r.RouteNumber ? 'active' : ''}"
         onclick="selectRuta(${r.RouteNumber})">
        <div class="ruta-date">${formatDate(r.FechaPlanificacion)}</div>
        <div class="ruta-number"><i class="bi bi-signpost-split"></i> #${r.RouteNumber}</div>
        <div class="ruta-name">${r.RouteName || ''}</div>
        <div style="display:flex;justify-content:space-between;align-items:center;margin-top:0.4rem">
            <span class="estado estado-${estadoCss}">${estado}</span>
            <span style="font-size:0.75rem;color:#888">${r.TotalProductos > 0 ? r.ProductosFinalizados + '/' + r.TotalProductos + ' prod. — ' + pct + '%' : 'Sin productos'}</span>
        </div>
        ${r.TotalProductos > 0 ? `<div class="progress-bar-custom" style="margin-top:0.3rem">
            <div class="fill" style="width:${pct}%"></div>
        </div>` : ''}
    </div>`;
}

function renderRutaCardOrder(r) {
    const pct = r.TotalPedidos > 0
        ? Math.round((r.PedidosFinalizados / r.TotalPedidos) * 100) : 0;
    const estado = r.Estado || 'Pendiente';
    const estadoCss = estado.replace(' ', '');
    return `
    <div class="ruta-card estado-${estadoCss} ${selectedRoutePlanId === r.ID_RoutePlan ? 'active' : ''}"
         onclick="selectRutaOrder(${r.ID_RoutePlan}, ${r.RouteNumber})">
        <div class="ruta-date">${formatDate(r.FechaPlanificacion)}</div>
        <div class="ruta-number"><i class="bi bi-signpost-split"></i> #${r.RouteNumber}</div>
        <div class="ruta-name">${r.RouteName || ''}</div>
        ${r.Pais ? `<span style="font-size:0.65rem;background:rgba(212,168,38,0.2);color:#b8941f;padding:0.1rem 0.4rem;border-radius:3px;font-weight:600">${r.Pais}</span>` : ''}
        <div style="display:flex;justify-content:space-between;align-items:center;margin-top:0.4rem">
            <span class="estado estado-${estadoCss}">${estado}</span>
            <span style="font-size:0.75rem;color:#888">${r.TotalPedidos > 0 ? r.PedidosFinalizados + '/' + r.TotalPedidos + ' pedidos — ' + pct + '%' : 'Sin pedidos'}</span>
        </div>
        ${r.TotalPedidos > 0 ? `<div class="progress-bar-custom" style="margin-top:0.3rem">
            <div class="fill" style="width:${pct}%"></div>
        </div>` : ''}
    </div>`;
}

// ══════════════════════════════════════════
// ── Product Mode (GT) - existing logic
// ══════════════════════════════════════════

async function selectRuta(routeNumber) {
    if (pickingMode === 'order') return; // should not happen
    try {
        selectedRuta = routeNumber;
        selectedRoutePlanId = null;
        const [productosRes, resumenRes] = await Promise.all([
            fetch(`/api/rutas/${routeNumber}/productos`),
            fetch(`/api/rutas/${routeNumber}/resumen`)
        ]);
        const productos = await productosRes.json();
        const resumen = await resumenRes.json();
        const ruta = rutasCache.find(r => r.RouteNumber === routeNumber) || {};

        renderRutasList(
            document.getElementById('searchRutas').value
                ? rutasCache.filter(r => r.RouteNumber.toString().includes(document.getElementById('searchRutas').value))
                : rutasCache
        );
        renderDetalle(routeNumber, ruta, productos, resumen);
    } catch (err) {
        console.error('Error selecting ruta:', err);
    }
}

function renderDetalle(routeNumber, ruta, productos, resumen) {
    const panel = document.getElementById('panelDetalle');
    const completados = resumen.ProductosFinalizados || 0;
    const total = resumen.TotalProductos || 0;
    const pct = total > 0 ? Math.round((completados / total) * 100) : 0;
    const estado = ruta.Estado || 'Pendiente';
    const estadoCss = estado.replace(' ', '');

    let actionBtn = '';
    if (estado === 'Pendiente') {
        actionBtn = `<button class="btn-iniciar" onclick="iniciarRuta(${routeNumber})">
            <i class="bi bi-play-circle"></i> Iniciar Ruta</button>`;
    } else if (estado === 'Iniciado') {
        actionBtn = `<button class="btn-finalizar" onclick="finalizarRuta(${routeNumber})">
            <i class="bi bi-check-circle"></i> Finalizar Ruta</button>`;
    }

    panel.innerHTML = `
        <div class="resumen-card">
            <div class="resumen-header">
                <h5><i class="bi bi-info-circle"></i> Ruta #${routeNumber}</h5>
                ${actionBtn}
            </div>
            <div class="resumen-grid">
                <div class="resumen-field">
                    <label>Nombre</label>
                    <div class="value">${ruta.RouteName || '-'}</div>
                </div>
                <div class="resumen-field">
                    <label>Estado</label>
                    <div><span class="estado estado-${estadoCss}">${estado}</span></div>
                </div>
                <div class="resumen-field">
                    <label>Planificacion</label>
                    <div class="value">${formatDate(ruta.FechaPlanificacion)}</div>
                </div>
                <div class="resumen-field">
                    <label>Almacen</label>
                    <div class="value">${ruta.AlmacenOrigen || '-'}</div>
                </div>
                ${ruta.CarrilNombre ? `<div class="resumen-field">
                    <label>Carril</label>
                    <div class="value" style="color:#1565c0;font-weight:600"><i class="bi bi-signpost-2"></i> ${ruta.CarrilNombre}</div>
                </div>` : ''}
            </div>
            ${total > 0 ? `
            <div class="progress-bar-custom" style="margin-top:1rem">
                <div class="fill" style="width:${pct}%"></div>
            </div>
            <div style="text-align:right;font-size:0.8rem;color:#888;margin-top:0.3rem">${completados}/${total} productos — ${pct}%</div>` : ''}
        </div>

        <div class="kpi-row">
            <div class="kpi-card">
                <div class="kpi-value">${resumen.TotalProductos || 0}</div>
                <div class="kpi-label">Productos</div>
            </div>
            <div class="kpi-card">
                <div class="kpi-value">${resumen.TotalArticulos || 0}</div>
                <div class="kpi-label">Articulos</div>
            </div>
            <div class="kpi-card">
                <div class="kpi-value" style="color:var(--success)">${formatNumber(resumen.PesoTotal || 0)}</div>
                <div class="kpi-label">Kg Totales</div>
            </div>
        </div>

        <div class="pedidos-header">
            <i class="bi bi-box-seam"></i>
            <h6>Productos</h6>
            <span class="badge-count">${total}</span>
        </div>

        <div id="productosList">
            ${productos.map(p => renderProducto(routeNumber, p)).join('')}
        </div>
    `;
}

function renderProducto(routeNumber, p) {
    const estadoClean = (p.Estado || 'Pendiente').replace(' ', '');
    const isFinalizado = p.Estado === 'Finalizado';

    const pickerHtml = p.PickerNombre
        ? `<div class="pedido-picker asignado"><i class="bi bi-check"></i> ${p.PickerNombre}</div>`
        : `<div class="pedido-picker sin-asignar"><i class="bi bi-exclamation-triangle"></i> Sin asignar</div>`;

    let buttonsHtml = '';
    if (!isFinalizado && !p.PickerNombre) {
        buttonsHtml = `
            <button class="btn-action btn-asignar" onclick="openPickerModal(${routeNumber}, '${esc(p.Product)}')" title="Asignar operario">
                <i class="bi bi-person-plus"></i></button>`;
    } else if (!isFinalizado) {
        buttonsHtml = `
            <button class="btn-action btn-reasignar" onclick="openPickerModal(${routeNumber}, '${esc(p.Product)}', true)" title="Reasignar">
                <i class="bi bi-person-gear"></i></button>
            <button class="btn-action btn-cerrar-pedido" onclick="cerrarProducto(${routeNumber}, '${esc(p.Product)}')" title="Cerrar producto">
                <i class="bi bi-x-circle"></i></button>`;
    }

    return `
        <div class="pedido-card estado-${estadoClean}">
            <div class="pedido-header">
                <div class="pedido-info">
                    <div class="pedido-doc">${p.Product} <span class="estado estado-${estadoClean}" style="font-size:0.7rem">${p.Estado || 'Pendiente'}</span></div>
                    <div class="pedido-meta" style="font-weight:600">${p.ProductName || ''}</div>
                    <div class="pedido-meta">${p.TotalArticulo || 0} articulos | ${formatNumber(p.PesoTotal || 0)} kg</div>
                    ${pickerHtml}
                </div>
                <div class="pedido-actions">${buttonsHtml}</div>
            </div>
        </div>
    `;
}

async function iniciarRuta(routeNumber) {
    pendingIniciarRuta = { routeNumber, mode: 'product' };
    try {
        const res = await fetch('/api/carriles');
        const carriles = await res.json();
        if (carriles.length > 0) {
            document.getElementById('carrilModal').style.display = 'flex';
            document.getElementById('carrilList').innerHTML = carriles.map(c => `
                <div class="picker-item" onclick="selectCarrilAndStart(${c.ID_Carril})" style="cursor:pointer;padding:0.8rem 1rem;border:1px solid #e0e0e0;border-left:4px solid #d4a826;border-radius:8px;margin-bottom:0.5rem;transition:background 0.15s">
                    <div style="font-weight:700"><i class="bi bi-signpost-2"></i> ${c.Nombre}</div>
                </div>
            `).join('');
            return;
        }
    } catch (err) {
        console.error('Error loading carriles:', err);
    }
    await doIniciarRuta(routeNumber, null);
}

async function finalizarRuta(routeNumber) {
    if (!confirm('Finalizar esta ruta completa? Todos los productos y tareas pendientes se marcaran como finalizados.')) return;
    try {
        const res = await fetch(`/api/rutas/${routeNumber}/finalizar`, { method: 'POST' });
        if (!res.ok) { const d = await res.json(); alert(d.error); return; }
        await loadRutas();
        await selectRuta(routeNumber);
    } catch (err) {
        alert('Error al finalizar ruta');
    }
}

async function doIniciarRuta(routeNumber, idCarril) {
    try {
        const body = idCarril ? { idCarril } : {};
        const res = await fetch(`/api/rutas/${routeNumber}/iniciar`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        });
        if (!res.ok) { const d = await res.json(); alert(d.error); return; }
        await loadRutas();
        await selectRuta(routeNumber);
    } catch (err) {
        alert('Error al iniciar ruta');
    }
}

async function cerrarProducto(routeNumber, product) {
    if (!confirm('Cerrar este producto? Se marcaran todas sus tareas como finalizadas.')) return;
    try {
        const res = await fetch('/api/productos/cerrar', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ routeNumber: routeNumber.toString(), product })
        });
        if (!res.ok) { const d = await res.json(); alert(d.error); return; }
        await loadRutas();
        await selectRuta(routeNumber);
    } catch (err) {
        alert('Error al cerrar producto');
    }
}

// ══════════════════════════════════════════
// ── Order Mode (SV) - picking by pedido
// ══════════════════════════════════════════

async function selectRutaOrder(idRoutePlan, routeNumber) {
    try {
        selectedRoutePlanId = idRoutePlan;
        selectedRuta = null;
        const [pedidosRes, resumenRes] = await Promise.all([
            fetch(`/api/order/rutas/${idRoutePlan}/pedidos`),
            fetch(`/api/order/rutas/${idRoutePlan}/resumen`)
        ]);
        const pedidos = await pedidosRes.json();
        const resumen = await resumenRes.json();
        const ruta = rutasCache.find(r => r.ID_RoutePlan === idRoutePlan) || {};

        renderRutasList(
            document.getElementById('searchRutas').value
                ? rutasCache.filter(r => r.RouteNumber.toString().includes(document.getElementById('searchRutas').value))
                : rutasCache
        );
        renderDetalleOrder(idRoutePlan, routeNumber, ruta, pedidos, resumen);
    } catch (err) {
        console.error('Error selecting order ruta:', err);
    }
}

function renderDetalleOrder(idRoutePlan, routeNumber, ruta, pedidos, resumen) {
    const panel = document.getElementById('panelDetalle');
    const completados = resumen.PedidosFinalizados || 0;
    const total = resumen.TotalPedidos || 0;
    const pct = total > 0 ? Math.round((completados / total) * 100) : 0;
    const estado = ruta.Estado || 'Pendiente';
    const estadoCss = estado.replace(' ', '');

    let actionBtn = '';
    if (estado === 'Pendiente') {
        actionBtn = `<button class="btn-iniciar" onclick="iniciarRutaOrder(${idRoutePlan})">
            <i class="bi bi-play-circle"></i> Iniciar Ruta</button>`;
    } else if (estado === 'Iniciado') {
        actionBtn = `<button class="btn-finalizar" onclick="finalizarRutaOrder(${idRoutePlan})">
            <i class="bi bi-check-circle"></i> Finalizar Ruta</button>`;
    }

    panel.innerHTML = `
        <div class="resumen-card">
            <div class="resumen-header">
                <h5><i class="bi bi-info-circle"></i> Ruta #${routeNumber} ${ruta.Pais ? `<span style="font-size:0.7rem;background:rgba(212,168,38,0.2);color:#b8941f;padding:0.15rem 0.5rem;border-radius:4px;margin-left:0.5rem">${ruta.Pais}</span>` : ''}</h5>
                ${actionBtn}
            </div>
            <div class="resumen-grid">
                <div class="resumen-field">
                    <label>Nombre</label>
                    <div class="value">${ruta.RouteName || '-'}</div>
                </div>
                <div class="resumen-field">
                    <label>Estado</label>
                    <div><span class="estado estado-${estadoCss}">${estado}</span></div>
                </div>
                <div class="resumen-field">
                    <label>Planificacion</label>
                    <div class="value">${formatDate(ruta.FechaPlanificacion)}</div>
                </div>
                <div class="resumen-field">
                    <label>Centro</label>
                    <div class="value">${ruta.CentroNombre || '-'}</div>
                </div>
                ${ruta.CarrilNombre ? `<div class="resumen-field">
                    <label>Carril</label>
                    <div class="value" style="color:#1565c0;font-weight:600"><i class="bi bi-signpost-2"></i> ${ruta.CarrilNombre}</div>
                </div>` : ''}
            </div>
            ${total > 0 ? `
            <div class="progress-bar-custom" style="margin-top:1rem">
                <div class="fill" style="width:${pct}%"></div>
            </div>
            <div style="text-align:right;font-size:0.8rem;color:#888;margin-top:0.3rem">${completados}/${total} pedidos — ${pct}%</div>` : ''}
        </div>

        <div class="kpi-row">
            <div class="kpi-card">
                <div class="kpi-value">${resumen.TotalPedidos || 0}</div>
                <div class="kpi-label">Pedidos</div>
            </div>
            <div class="kpi-card">
                <div class="kpi-value">${resumen.TotalLineas || 0}</div>
                <div class="kpi-label">Lineas</div>
            </div>
            <div class="kpi-card">
                <div class="kpi-value">${resumen.TotalUnidades || 0}</div>
                <div class="kpi-label">Unidades</div>
            </div>
            <div class="kpi-card">
                <div class="kpi-value" style="color:var(--success)">${formatNumber(resumen.PesoTotal || 0)}</div>
                <div class="kpi-label">Kg Totales</div>
            </div>
        </div>

        <div class="pedidos-header">
            <i class="bi bi-receipt"></i>
            <h6>Pedidos</h6>
            <span class="badge-count">${total}</span>
        </div>

        <div id="pedidosList">
            ${pedidos.map(p => renderPedido(idRoutePlan, p)).join('')}
        </div>
    `;
}

function renderPedido(idRoutePlan, p) {
    const estadoClean = (p.Estado || 'Pendiente').replace(' ', '');
    const isFinalizado = p.Estado === 'Finalizado';

    const operarioHtml = p.OperarioNombre
        ? `<div class="pedido-picker asignado"><i class="bi bi-check"></i> ${p.OperarioNombre}</div>`
        : `<div class="pedido-picker sin-asignar"><i class="bi bi-exclamation-triangle"></i> Sin asignar</div>`;

    const docLabel = p.DocType === 'OV' ? 'OV' : p.DocType;

    let buttonsHtml = '';
    if (!isFinalizado && !p.OperarioNombre) {
        buttonsHtml = `
            <button class="btn-action btn-asignar" onclick="openPickerModalOrder(${p.ID_OrderPicking})" title="Asignar operario">
                <i class="bi bi-person-plus"></i></button>`;
    } else if (!isFinalizado) {
        buttonsHtml = `
            <button class="btn-action btn-reasignar" onclick="openPickerModalOrder(${p.ID_OrderPicking}, true)" title="Reasignar">
                <i class="bi bi-person-gear"></i></button>
            <button class="btn-action btn-cerrar-pedido" onclick="cerrarPedido(${p.ID_OrderPicking})" title="Cerrar pedido">
                <i class="bi bi-x-circle"></i></button>`;
    }

    // Expandable detail button
    const detailBtn = `<button class="btn-action btn-detalle" onclick="togglePedidoDetail(${p.ID_OrderPicking}, this)" title="Ver lineas">
        <i class="bi bi-chevron-down"></i></button>`;

    return `
        <div class="pedido-card estado-${estadoClean}">
            <div class="pedido-header">
                <div class="pedido-info">
                    <div class="pedido-doc">${docLabel} ${p.OV_Number} <span class="estado estado-${estadoClean}" style="font-size:0.7rem">${p.Estado || 'Pendiente'}</span></div>
                    <div class="pedido-meta">${p.TotalLineas || 0} lineas | ${p.TotalUnidades || 0} uds | ${formatNumber(p.PesoTotal || 0)} kg</div>
                    ${operarioHtml}
                </div>
                <div class="pedido-actions">
                    ${detailBtn}
                    ${buttonsHtml}
                </div>
            </div>
            <div class="tareas-container" id="pedido-detail-${p.ID_OrderPicking}" style="display:none"></div>
        </div>
    `;
}

async function togglePedidoDetail(idOrderPicking, btn) {
    const container = document.getElementById(`pedido-detail-${idOrderPicking}`);
    if (!container) return;

    if (container.style.display !== 'none') {
        container.style.display = 'none';
        btn.innerHTML = '<i class="bi bi-chevron-down"></i>';
        return;
    }

    btn.innerHTML = '<i class="bi bi-chevron-up"></i>';
    container.style.display = 'block';
    container.innerHTML = '<div style="text-align:center;color:#999;padding:0.5rem">Cargando...</div>';

    try {
        const res = await fetch(`/api/order/pedidos/${idOrderPicking}/tareas`);
        const tareas = await res.json();

        if (tareas.length === 0) {
            container.innerHTML = '<div style="color:#999;font-size:0.85rem">Sin lineas de detalle</div>';
            return;
        }

        container.innerHTML = tareas.map(t => {
            const done = t.Estado === 'Finalizado' || t.CantidadPendiente === 0;
            return `
                <div class="tarea-item ${done ? 'tarea-done' : ''}">
                    <span class="tarea-product">${t.InternIdProduct} — ${t.Descripcion || ''}</span>
                    <span class="tarea-qty">${t.Cantidad} uds</span>
                    <span class="tarea-status">
                        ${done
                            ? '<i class="bi bi-check-circle-fill" style="color:var(--success)"></i>'
                            : `<span style="color:#d4a826;font-size:0.75rem">${t.CantidadPendiente} pend.</span>`
                        }
                    </span>
                </div>`;
        }).join('');
    } catch (err) {
        container.innerHTML = '<div style="color:var(--danger);font-size:0.85rem">Error al cargar lineas</div>';
    }
}

async function iniciarRutaOrder(idRoutePlan) {
    pendingIniciarRuta = { idRoutePlan, mode: 'order' };
    try {
        const res = await fetch('/api/carriles');
        const carriles = await res.json();
        if (carriles.length > 0) {
            document.getElementById('carrilModal').style.display = 'flex';
            document.getElementById('carrilList').innerHTML = carriles.map(c => `
                <div class="picker-item" onclick="selectCarrilAndStart(${c.ID_Carril})" style="cursor:pointer;padding:0.8rem 1rem;border:1px solid #e0e0e0;border-left:4px solid #d4a826;border-radius:8px;margin-bottom:0.5rem;transition:background 0.15s">
                    <div style="font-weight:700"><i class="bi bi-signpost-2"></i> ${c.Nombre}</div>
                </div>
            `).join('');
            return;
        }
    } catch (err) {
        console.error('Error loading carriles:', err);
    }
    await doIniciarRutaOrder(idRoutePlan, null);
}

async function doIniciarRutaOrder(idRoutePlan, idCarril) {
    try {
        const body = idCarril ? { idCarril } : {};
        const res = await fetch(`/api/order/rutas/${idRoutePlan}/iniciar`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        });
        if (!res.ok) { const d = await res.json(); alert(d.error); return; }
        await loadRutas();
        const ruta = rutasCache.find(r => r.ID_RoutePlan === idRoutePlan);
        if (ruta) await selectRutaOrder(idRoutePlan, ruta.RouteNumber);
    } catch (err) {
        alert('Error al iniciar ruta');
    }
}

async function finalizarRutaOrder(idRoutePlan) {
    if (!confirm('Finalizar esta ruta completa? Todos los pedidos y tareas pendientes se marcaran como finalizados.')) return;
    try {
        const res = await fetch(`/api/order/rutas/${idRoutePlan}/finalizar`, { method: 'POST' });
        if (!res.ok) { const d = await res.json(); alert(d.error); return; }
        await loadRutas();
        const ruta = rutasCache.find(r => r.ID_RoutePlan === idRoutePlan);
        if (ruta) await selectRutaOrder(idRoutePlan, ruta.RouteNumber);
    } catch (err) {
        alert('Error al finalizar ruta');
    }
}

async function cerrarPedido(idOrderPicking) {
    if (!confirm('Cerrar este pedido? Se marcaran todas sus lineas como finalizadas.')) return;
    try {
        const res = await fetch('/api/order/pedidos/cerrar', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ idOrderPicking })
        });
        if (!res.ok) { const d = await res.json(); alert(d.error); return; }
        await loadRutas();
        if (selectedRoutePlanId) {
            const ruta = rutasCache.find(r => r.ID_RoutePlan === selectedRoutePlanId);
            if (ruta) await selectRutaOrder(selectedRoutePlanId, ruta.RouteNumber);
        }
    } catch (err) {
        alert('Error al cerrar pedido');
    }
}

// ══════════════════════════════════════════
// ── Carril Modal (shared)
// ══════════════════════════════════════════

function closeCarrilModal() {
    document.getElementById('carrilModal').style.display = 'none';
    pendingIniciarRuta = null;
}

async function selectCarrilAndStart(idCarril) {
    const pending = pendingIniciarRuta;
    document.getElementById('carrilModal').style.display = 'none';
    pendingIniciarRuta = null;
    if (!pending) return;

    if (pending.mode === 'order') {
        await doIniciarRutaOrder(pending.idRoutePlan, idCarril);
    } else {
        await doIniciarRuta(pending.routeNumber, idCarril);
    }
}

async function confirmIniciarSinCarril() {
    const pending = pendingIniciarRuta;
    document.getElementById('carrilModal').style.display = 'none';
    pendingIniciarRuta = null;
    if (!pending) return;

    if (pending.mode === 'order') {
        await doIniciarRutaOrder(pending.idRoutePlan, null);
    } else {
        await doIniciarRuta(pending.routeNumber, null);
    }
}

// ══════════════════════════════════════════
// ── Picker Modal (shared, mode-aware)
// ══════════════════════════════════════════

async function openPickerModal(routeNumber, product, isReassign) {
    assigningProduct = { routeNumber, product };
    assigningPedido = null;
    document.getElementById('pickerModal').style.display = 'flex';
    document.getElementById('pickerModalSubtitle').textContent = isReassign
        ? 'Selecciona un nuevo operario para reasignar el producto'
        : 'Elige un operario para asignar el producto';

    try {
        const res = await fetch('/api/operarios');
        pickersCache = await res.json();
        renderPickers(pickersCache);
    } catch (err) {
        console.error('Error loading pickers:', err);
    }
}

async function openPickerModalOrder(idOrderPicking, isReassign) {
    assigningPedido = { idOrderPicking };
    assigningProduct = null;
    document.getElementById('pickerModal').style.display = 'flex';
    document.getElementById('pickerModalSubtitle').textContent = isReassign
        ? 'Selecciona un nuevo operario para reasignar el pedido'
        : 'Elige un operario para asignar el pedido completo';

    try {
        const res = await fetch('/api/operarios');
        pickersCache = await res.json();
        renderPickers(pickersCache);
    } catch (err) {
        console.error('Error loading pickers:', err);
    }
}

function closePickerModal() {
    document.getElementById('pickerModal').style.display = 'none';
    assigningProduct = null;
    assigningPedido = null;
}

function filterPickers(query) {
    const filtered = pickersCache.filter(p =>
        p.Nombre.toLowerCase().includes(query.toLowerCase())
    );
    renderPickers(filtered);
}

function renderPickers(pickers) {
    document.getElementById('pickerList').innerHTML = pickers.map(p => `
        <div class="picker-item" onclick="assignPicker(${p.ID_Operario})">
            <div class="picker-name"><i class="bi bi-person-circle"></i> ${p.Nombre}</div>
            <div class="picker-stats">
                ${p.CentroNombre || ''} |
                Asignados: <strong>${p.Asignados}</strong> |
                Completados hoy: <strong>${p.CompletadosHoy}</strong>
            </div>
        </div>
    `).join('');
}

async function assignPicker(operarioId) {
    try {
        if (assigningPedido) {
            // Order mode: assign operario to pedido
            const res = await fetch('/api/order/pedidos/asignar', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    idOrderPicking: assigningPedido.idOrderPicking,
                    operarioId
                })
            });
            if (!res.ok) { const d = await res.json(); alert(d.error); return; }
            const idRP = selectedRoutePlanId;
            closePickerModal();
            await loadRutas();
            if (idRP) {
                const ruta = rutasCache.find(r => r.ID_RoutePlan === idRP);
                if (ruta) await selectRutaOrder(idRP, ruta.RouteNumber);
            }
        } else if (assigningProduct) {
            // Product mode: assign operario to product
            const res = await fetch('/api/productos/asignar', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    routeNumber: assigningProduct.routeNumber,
                    product: assigningProduct.product,
                    operarioId
                })
            });
            if (!res.ok) { const d = await res.json(); alert(d.error); return; }
            const rn = assigningProduct.routeNumber;
            closePickerModal();
            await loadRutas();
            await selectRuta(rn);
        }
    } catch (err) {
        console.error('Error asignando:', err);
        alert('Error al asignar operario');
    }
}

// ══════════════════════════════════════════
// ── Refresh (mode-aware)
// ══════════════════════════════════════════

async function refreshData() {
    await loadRutas();

    if (pickingMode === 'order' && selectedRoutePlanId) {
        try {
            const [pedidosRes, resumenRes] = await Promise.all([
                fetch(`/api/order/rutas/${selectedRoutePlanId}/pedidos`),
                fetch(`/api/order/rutas/${selectedRoutePlanId}/resumen`)
            ]);
            const pedidos = await pedidosRes.json();
            const pedidosList = document.getElementById('pedidosList');
            if (pedidosList) {
                pedidosList.innerHTML = pedidos.map(p => renderPedido(selectedRoutePlanId, p)).join('');
            }
        } catch (err) {
            console.error('Error refreshing order:', err);
        }
    } else if (pickingMode === 'product' && selectedRuta) {
        try {
            const [productosRes, resumenRes] = await Promise.all([
                fetch(`/api/rutas/${selectedRuta}/productos`),
                fetch(`/api/rutas/${selectedRuta}/resumen`)
            ]);
            const productos = await productosRes.json();
            const productosList = document.getElementById('productosList');
            if (productosList) {
                productosList.innerHTML = productos.map(p => renderProducto(selectedRuta, p)).join('');
            }
        } catch (err) {
            console.error('Error refreshing:', err);
        }
    }
}

// ══════════════════════════════════════════
// ── Utilities
// ══════════════════════════════════════════

function formatDate(dateStr) {
    if (!dateStr) return '-';
    const d = new Date(dateStr);
    return `${d.getDate()}/${d.getMonth() + 1}/${d.getFullYear()}`;
}

function formatNumber(n) {
    return parseFloat(n).toLocaleString('es-GT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function esc(s) {
    return String(s).replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/"/g, '&quot;');
}

document.addEventListener('DOMContentLoaded', init);
