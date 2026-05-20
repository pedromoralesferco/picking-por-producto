function requireAuth(req, res, next) {
    if (!req.session || !req.session.user) {
        return res.status(401).json({ error: 'No autenticado' });
    }
    next();
}

function requireAdmin(req, res, next) {
    if (!req.session || !req.session.user || req.session.user.rol !== 'Admin') {
        return res.status(403).json({ error: 'Acceso denegado' });
    }
    next();
}

function requirePermiso(modulo) {
    return (req, res, next) => {
        if (!req.session || !req.session.user) {
            return res.status(401).json({ error: 'No autenticado' });
        }
        const user = req.session.user;
        if (user.rol === 'Admin' || (user.permisos && user.permisos.includes(modulo))) {
            return next();
        }
        return res.status(403).json({ error: 'Sin permiso para este módulo' });
    };
}

function requireAuthPage(req, res, next) {
    if (!req.session || !req.session.user) {
        return res.redirect('/login');
    }
    next();
}

function requireAdminPage(req, res, next) {
    if (!req.session || !req.session.user) {
        return res.redirect('/login');
    }
    if (req.session.user.rol !== 'Admin') {
        return res.redirect('/dashboard');
    }
    next();
}

function requirePermisoPage(modulo) {
    return (req, res, next) => {
        if (!req.session || !req.session.user) {
            return res.redirect('/login');
        }
        const user = req.session.user;
        if (user.rol === 'Admin' || (user.permisos && user.permisos.includes(modulo))) {
            return next();
        }
        return res.redirect('/dashboard');
    };
}

module.exports = { requireAuth, requireAdmin, requirePermiso, requireAuthPage, requireAdminPage, requirePermisoPage };
