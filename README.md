# Cloud-Based Digital Twin Lab — Vercel Phase 1

Browser-based virtual GW Instek AFG-2225 + GDS-1102B laboratory.

Features:
- CH1 / CH2
- Sine / Square / Triangle / Sawtooth
- Frequency / Vpp / Offset / Phase / Duty
- Virtual GDS controls
- Loopback DUT
- RC low-pass DUT
- Vpp / RMS / Frequency measurements
- Autoset
- Theory-vs-virtual CHECK SIGNAL
- Stateless FastAPI API suitable for Vercel serverless deployment

See `DEPLOY_VERCEL.md`.


## Phase 2 storage
Verified Hardware mode now uses Upstash Redis instead of Supabase. See `README_PHASE2_UPSTASH.md`.
