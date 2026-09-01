# Deploy Cloud Digital Twin Lab on Vercel

This package is prepared for Vercel's Python/FastAPI runtime.

## Important
Use a CLEAN GitHub repository for this package so the older Render-specific
`app/main.py` deployment does not compete with the Vercel `api/index.py` entrypoint.

Recommended repository name:

`cloud-digital-twin-lab-vercel`

## Repository structure

- `index.html` — browser UI
- `app.js` — browser state + API calls
- `styles.css` — UI styling
- `api/index.py` — Vercel FastAPI entrypoint
- `twin/schemas.py` — common data model
- `twin/virtual_engine.py` — corrected virtual signal/DUT engine
- `requirements.txt`
- `.python-version`
- `vercel.json`
- `tests/`

## Why this edition is stateless

Serverless functions may restart or scale. Therefore, Phase-1 lab settings are
kept in the browser and sent with each trace/verify request. This avoids relying
on process memory. Persistent users/results will be implemented later with a database.

## Deploy from GitHub

1. Create a new GitHub repository: `cloud-digital-twin-lab-vercel`.
2. Upload ALL files/folders from this package root.
3. Go to Vercel and sign in with GitHub.
4. Add New Project / Import Git Repository.
5. Select `cloud-digital-twin-lab-vercel`.
6. Framework Preset: Other (or let Vercel auto-detect).
7. Root Directory: repository root.
8. Do not set a custom Build Command unless Vercel asks for one.
9. Deploy.
10. Test:
   - `/`
   - `/api/health`
   - `/docs`

## Expected health response

```json
{
  "status": "ok",
  "mode": "Virtual Twin Lab",
  "phase": 1,
  "deployment": "Vercel stateless API"
}
```

## Phase-1 limitation

The login is a demo identity check, not persistent authentication.
No student records/grades are stored yet. PostgreSQL/authentication are next.


## V2 root-page fix

This edition serves the browser frontend directly from FastAPI:

- `/` -> `api/static/index.html`
- `/static/app.js`
- `/static/styles.css`
- `/api/health`
- `/docs`

If an earlier deployment showed `{"detail":"Not Found"}` at `/`, upload this V2
package to the same GitHub repository. Vercel should automatically redeploy.
