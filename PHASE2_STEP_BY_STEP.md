# Phase 2 — Verified Digital Twin: Step by Step

## Goal
A student uses the browser. The cloud creates a validated hardware job. The university lab PC runs MATLAB and polls the cloud. MATLAB applies the same settings to the real GW Instek AFG-2225, measures the signal on the real GDS-1102B, and returns the measurement to the browser.

Physical path:

AFG CH1 BNC -> GDS CH1
AFG CH2 BNC -> GDS CH2

## Step 1 — Update the existing GitHub/Vercel project
Upload all files in this Phase-2 package to the existing `cloud-digital-twin-lab-vercel` repository and commit to `main`.

Vercel will redeploy automatically. Virtual mode will continue to work even before the Phase-2 database is configured.

## Step 2 — Create the persistent hardware queue
Create a Supabase project. Open its SQL editor and run the complete file:

`supabase_phase2.sql`

It creates:
- `hardware_jobs`
- `hardware_gateways`

The browser never accesses these tables directly.

## Step 3 — Add Vercel environment variables
In Vercel Project -> Environment Variables add:

- `SUPABASE_URL`
- `SUPABASE_SECRET_KEY (preferred; sb_secret_...)`
- `GATEWAY_SHARED_KEY`

Use a long random value for `GATEWAY_SHARED_KEY` and keep it private. Do not put the service-role key or gateway key in browser JavaScript or GitHub.

Redeploy Vercel after adding the variables.

## Step 4 — Check the cloud
Open:

`https://<your-project>.vercel.app/api/health`

The response should show Phase 2.

At this point the browser may show the hardware gateway as OFFLINE. That is normal until MATLAB is running on the lab PC.

## Step 5 — Prepare the physical laboratory PC
Connect and power:

- AFG-2225 by USB to the MATLAB PC
- GDS-1102B by USB to the MATLAB PC
- AFG CH1 BNC -> GDS CH1
- AFG CH2 BNC -> GDS CH2

Close the old MATLAB Digital Twin app before starting the gateway so two MATLAB processes do not compete for the same COM ports.

## Step 6 — Start MATLAB gateway
Put `MATLAB_Hardware_Gateway.m` on the MATLAB path and run:

```matlab
MATLAB_Hardware_Gateway( ...
    "https://<your-project>.vercel.app", ...
    "quest-lab-01", ...
    "THE-SAME-GATEWAY_SHARED_KEY")
```

The gateway auto-discovers AFG-2225 and GDS-1102B. It prefers COM3 for AFG and COM4 for GDS but checks all available serial ports.

The browser should then show:

`Hardware gateway: ONLINE`

## Step 7 — First verified experiment
In the browser:

1. Select `1 — Direct AFG -> GDS`.
2. Select `Verified Hardware`.
3. Select CH1.
4. Use Sine, 1000 Hz, 2 Vpp, 0 V offset.
5. Turn OUTPUT ON.
6. Press `VERIFY ON REAL HARDWARE`.

The browser will show the virtual reference and the real GDS measurement, plus frequency and amplitude error.

## Safety behaviour
Initial gateway limits:

- 1..10,000 Hz
- 0.001..10 Vpp
- |offset| <= 5 V
- |offset| + Vpp/2 <= 5 V
- phase -180..180 deg
- duty 1..99%

After each verified measurement the selected AFG output is turned OFF. On gateway shutdown both AFG outputs are turned OFF and the AFG is returned to LOCAL.

## Current Phase-2 limitation
Verified mode initially supports only the direct physical BNC path. RC Low-pass and RC High-pass are still virtual because a physical RC fixture has not yet been inserted between the AFG and GDS.
