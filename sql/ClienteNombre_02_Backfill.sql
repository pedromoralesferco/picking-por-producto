-- ============================================================
-- Backfill único de ClienteNombre para los pedidos ya existentes (donde esté NULL).
-- OV -> OCRD.CardName; TR/RESURTIDO -> OWHS.WhsName (destino). RMA se deja NULL.
-- Correr una vez en Picking_Management. Set-based por país. NO escribe a SAP.
-- ============================================================

-- GT (sboferco)
UPDATE opm SET opm.ClienteNombre = LEFT(c.CardName, 150)
FROM dbo.OrderPickingManagement opm
JOIN [server-sql].sboferco.dbo.ORDR o WITH (NOLOCK) ON o.DocNum = TRY_CAST(opm.OV_Number AS INT)
JOIN [server-sql].sboferco.dbo.OCRD c WITH (NOLOCK) ON c.CardCode = o.CardCode
WHERE opm.Pais = 'GT' AND opm.DocType = 'OV' AND opm.ClienteNombre IS NULL;
PRINT 'GT OV: ' + CAST(@@ROWCOUNT AS VARCHAR(10));

UPDATE opm SET opm.ClienteNombre = LEFT(ISNULL(w.WhsName, q.ToWhsCode), 150)
FROM dbo.OrderPickingManagement opm
JOIN [server-sql].sboferco.dbo.OWTQ q WITH (NOLOCK) ON q.DocNum = TRY_CAST(opm.OV_Number AS INT)
LEFT JOIN [server-sql].sboferco.dbo.OWHS w WITH (NOLOCK) ON w.WhsCode = q.ToWhsCode
WHERE opm.Pais = 'GT' AND opm.DocType IN ('TR','RESURTIDO') AND opm.ClienteNombre IS NULL;
PRINT 'GT TR: ' + CAST(@@ROWCOUNT AS VARCHAR(10));

-- SV (sbointergres)
UPDATE opm SET opm.ClienteNombre = LEFT(c.CardName, 150)
FROM dbo.OrderPickingManagement opm
JOIN [server-sql].sbointergres.dbo.ORDR o WITH (NOLOCK) ON o.DocNum = TRY_CAST(opm.OV_Number AS INT)
JOIN [server-sql].sbointergres.dbo.OCRD c WITH (NOLOCK) ON c.CardCode = o.CardCode
WHERE opm.Pais = 'SV' AND opm.DocType = 'OV' AND opm.ClienteNombre IS NULL;
PRINT 'SV OV: ' + CAST(@@ROWCOUNT AS VARCHAR(10));

UPDATE opm SET opm.ClienteNombre = LEFT(ISNULL(w.WhsName, q.ToWhsCode), 150)
FROM dbo.OrderPickingManagement opm
JOIN [server-sql].sbointergres.dbo.OWTQ q WITH (NOLOCK) ON q.DocNum = TRY_CAST(opm.OV_Number AS INT)
LEFT JOIN [server-sql].sbointergres.dbo.OWHS w WITH (NOLOCK) ON w.WhsCode = q.ToWhsCode
WHERE opm.Pais = 'SV' AND opm.DocType IN ('TR','RESURTIDO') AND opm.ClienteNombre IS NULL;
PRINT 'SV TR: ' + CAST(@@ROWCOUNT AS VARCHAR(10));

-- HN (sbopym)
UPDATE opm SET opm.ClienteNombre = LEFT(c.CardName, 150)
FROM dbo.OrderPickingManagement opm
JOIN [server-sql].sbopym.dbo.ORDR o WITH (NOLOCK) ON o.DocNum = TRY_CAST(opm.OV_Number AS INT)
JOIN [server-sql].sbopym.dbo.OCRD c WITH (NOLOCK) ON c.CardCode = o.CardCode
WHERE opm.Pais = 'HN' AND opm.DocType = 'OV' AND opm.ClienteNombre IS NULL;
PRINT 'HN OV: ' + CAST(@@ROWCOUNT AS VARCHAR(10));

UPDATE opm SET opm.ClienteNombre = LEFT(ISNULL(w.WhsName, q.ToWhsCode), 150)
FROM dbo.OrderPickingManagement opm
JOIN [server-sql].sbopym.dbo.OWTQ q WITH (NOLOCK) ON q.DocNum = TRY_CAST(opm.OV_Number AS INT)
LEFT JOIN [server-sql].sbopym.dbo.OWHS w WITH (NOLOCK) ON w.WhsCode = q.ToWhsCode
WHERE opm.Pais = 'HN' AND opm.DocType IN ('TR','RESURTIDO') AND opm.ClienteNombre IS NULL;
PRINT 'HN TR: ' + CAST(@@ROWCOUNT AS VARCHAR(10));
