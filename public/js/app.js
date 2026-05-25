let selectedRuta = null;
let rutasCache = [];
let pickersCache = [];
let assigningProduct = null;
let refreshInterval = null;
let pendingIniciarRuta = null;

async function init() {
    await loadRutas();
    refreshInterval = setInterval(refreshData, 30000);
}

async function loadRutas() {
    try {
        const res = await fetch('/api/rutas');
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

    list.innerHTML = rutas.map(r => {
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
    }).join('');
}

async function selectRuta(routeNumber) {
    try {
        selectedRuta = routeNumber;
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
                    <label>Planificación</label>
                    <div class="value">${formatDate(ruta.FechaPlanificacion)}</div>
                </div>
                <div class="resumen-field">
                    <label>Almacén</label>
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
                <div class="kpi-label">Artículos</div>
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
                    <div class="pedido-meta">${p.TotalArticulo || 0} artículos | ${formatNumber(p.PesoTotal || 0)} kg</div>
                    ${pickerHtml}
                </div>
                <div class="pedido-actions">${buttonsHtml}</div>
            </div>
        </div>
    `;
}

async function iniciarRuta(routeNumber) {
    pendingIniciarRuta = routeNumber;
    const ruta = rutasCache.find(r => r.RouteNumber === routeNumber);

    // Try to load carriles for this route's centro
    try {
        let url = '/api/carriles';
        if (ruta && ruta.AlmacenOrigen) {
            // Try to find centro by almacen - fetch all carriles
            url = '/api/carriles';
        }
        const res = await fetch(url);
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

    // No carriles available, start without
    await doIniciarRuta(routeNumber, null);
}

function closeCarrilModal() {
    document.getElementById('carrilModal').style.display = 'none';
    pendingIniciarRuta = null;
}

async function selectCarrilAndStart(idCarril) {
    const rn = pendingIniciarRuta;
    document.getElementById('carrilModal').style.display = 'none';
    pendingIniciarRuta = null;
    await doIniciarRuta(rn, idCarril);
}

async function confirmIniciarSinCarril() {
    const rn = pendingIniciarRuta;
    document.getElementById('carrilModal').style.display = 'none';
    pendingIniciarRuta = null;
    await doIniciarRuta(rn, null);
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

async function finalizarRuta(routeNumber) {
    if (!confirm('¿Finalizar esta ruta completa? Todos los productos y tareas pendientes se marcarán como finalizados.')) return;
    try {
        const res = await fetch(`/api/rutas/${routeNumber}/finalizar`, { method: 'POST' });
        if (!res.ok) { const d = await res.json(); alert(d.error); return; }
        await loadRutas();
        await selectRuta(routeNumber);
    } catch (err) {
        alert('Error al finalizar ruta');
    }
}

async function cerrarProducto(routeNumber, product) {
    if (!confirm('¿Cerrar este producto? Se marcarán todas sus tareas como finalizadas.')) return;
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

// ── Picker modal ──

async function openPickerModal(routeNumber, product, isReassign) {
    assigningProduct = { routeNumber, product };
    document.getElementById('pickerModal').style.display = 'flex';
    document.getElementById('pickerModalSubtitle').textContent = isReassign
        ? 'Selecciona un nuevo operario para reasignar el producto'
        : 'Elige un operario para asignar el producto';

    try {
        const res = await fetch('/api/pickers');
        pickersCache = await res.json();
        renderPickers(pickersCache);
    } catch (err) {
        console.error('Error loading pickers:', err);
    }
}

function closePickerModal() {
    document.getElementById('pickerModal').style.display = 'none';
    assigningProduct = null;
}

function filterPickers(query) {
    const filtered = pickersCache.filter(p =>
        p.Nombre.toLowerCase().includes(query.toLowerCase())
    );
    renderPickers(filtered);
}

function renderPickers(pickers) {
    document.getElementById('pickerList').innerHTML = pickers.map(p => `
        <div class="picker-item" onclick="assignPicker(${p.ID_Picker})">
            <div class="picker-name"><i class="bi bi-person-circle"></i> ${p.Nombre}</div>
            <div class="picker-stats">
                ${p.CentroNombre || ''} |
                Asignados: <strong>${p.Asignados}</strong> |
                Completados hoy: <strong>${p.CompletadosHoy}</strong>
            </div>
        </div>
    `).join('');
}

async function assignPicker(pickerId) {
    try {
        const res = await fetch('/api/productos/asignar', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                routeNumber: assigningProduct.routeNumber,
                product: assigningProduct.product,
                pickerId
            })
        });
        if (!res.ok) { const d = await res.json(); alert(d.error); return; }
        const rn = assigningProduct.routeNumber;
        closePickerModal();
        await loadRutas();
        await selectRuta(rn);
    } catch (err) {
        console.error('Error asignando picker:', err);
        alert('Error al asignar picker');
    }
}

// ── Refresh ──

async function refreshData() {
    await loadRutas();
    if (selectedRuta) {
        try {
            const [productosRes, resumenRes] = await Promise.all([
                fetch(`/api/rutas/${selectedRuta}/productos`),
                fetch(`/api/rutas/${selectedRuta}/resumen`)
            ]);
            const productos = await productosRes.json();
            const resumen = await resumenRes.json();
            const productosList = document.getElementById('productosList');
            if (productosList) {
                productosList.innerHTML = productos.map(p => renderProducto(selectedRuta, p)).join('');
            }
        } catch (err) {
            console.error('Error refreshing:', err);
        }
    }
}

// ── Utilidades ──

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
