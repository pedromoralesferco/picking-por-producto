#!/usr/bin/env python3
"""Dispara el robot de UiPath 'Planificacion_SAP Z5 Locales' (importacion de rutas:
staging Supabase -> cuadros SAP). Lee las credenciales UIPATH_* del .env de esta carpeta.
Correr local:  python3 start_import_rutas.py
"""
import json, os, sys, urllib.request, urllib.parse, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
ENV = os.path.join(HERE, ".env")

# --- parse .env seguro (split en el primer '=', sin expansion de shell) ---
cfg = {}
with open(ENV, encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        cfg[k.strip()] = v.strip()

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")

def post(url, data, headers, form=False):
    body = urllib.parse.urlencode(data).encode() if form else json.dumps(data).encode()
    headers = {**headers, "User-Agent": UA, "Accept": "application/json"}
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=40) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")

# 1) token
st, body = post(cfg["UIPATH_TOKEN_URL"], {
    "grant_type": "client_credentials",
    "client_id": cfg["UIPATH_CLIENT_ID"],
    "client_secret": cfg["UIPATH_CLIENT_SECRET"],
    "scope": "OR.Jobs",
}, {"Content-Type": "application/x-www-form-urlencoded"}, form=True)
if st != 200:
    sys.exit(f"TOKEN FAIL HTTP {st}: {body[:400]}")
tok = json.loads(body)
print(f"Token OK (expira en {tok.get('expires_in')}s, scopes: {tok.get('scope')})")

# 2) arrancar el job via StartJobs (como el flujo de Power Automate)
start_info = {"startInfo": {
    "ReleaseKey": cfg["UIPATH_RELEASE_KEY"],
    "Strategy": "ModernJobsCount",
    "JobsCount": 1,
    "InputArguments": "{}",
}}
st, body = post(cfg["UIPATH_STARTJOBS_URL"], start_info,
                {"Authorization": "Bearer " + tok["access_token"],
                 "Content-Type": "application/json",
                 "X-UIPATH-OrganizationUnitId": cfg["UIPATH_ORG_UNIT"]})
print(f"STARTJOBS HTTP {st}")
print(body if body else "(sin cuerpo)")
if st in (200, 201):
    print(">> Job encolado OK")
