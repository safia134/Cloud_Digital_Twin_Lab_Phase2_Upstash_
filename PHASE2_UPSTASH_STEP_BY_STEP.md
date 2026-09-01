# Phase 2 Upstash — Step by Step

## 1. Update GitHub/Vercel code
Upload this package to the existing `cloud-digital-twin-lab-vercel` repository
and commit to `main`. Vercel will redeploy.

## 2. Create/connect Upstash Redis from Vercel
In the Vercel project:
- Storage / Integrations / Marketplace
- Find **Upstash Redis**
- Create or connect a Redis database
- Link it to `cloud-digital-twin-lab-vercel`
- Free plan is enough for the research prototype

The integration should create Redis REST credentials in the project.

## 3. Confirm environment variables
Vercel Project → Settings → Environment Variables.

Use either:
- `UPSTASH_REDIS_REST_URL`
- `UPSTASH_REDIS_REST_TOKEN`

or the integration aliases:
- `KV_REST_API_URL`
- `KV_REST_API_TOKEN`

Also add:
- `GATEWAY_SHARED_KEY`

Generate that key locally:
`python -c "import secrets; print(secrets.token_urlsafe(32))"`

Save the exact gateway key locally. Do not commit it to GitHub.

## 4. Redeploy
Environment variable changes require a new deployment.

## 5. Test cloud queue
Open:
- `/api/health`
- the Virtual Lab UI

Virtual Lab must work even before MATLAB Gateway is online.
Hardware status should show gateway offline until MATLAB starts.

## 6. Start MATLAB Gateway on the lab PC
Use the included `matlab_gateway/MATLAB_Hardware_Gateway.m`.

Example:
`MATLAB_Hardware_Gateway("https://cloud-digital-twin-lab-vercel.vercel.app", "quest-lab-01", "YOUR_GATEWAY_SHARED_KEY")`

The same `GATEWAY_SHARED_KEY` value must exist in Vercel.

## 7. Hardware wiring
- Lab PC USB/serial → AFG-2225
- AFG CH1/CH2 BNC → matching GDS-1102B input
- GDS USB/serial → Lab PC

## 8. First verified test
Use Experiment 1 (Direct AFG → GDS):
- CH1
- Sine
- 1000 Hz
- 2 Vpp
- 0 V offset

Press `VERIFY ON REAL HARDWARE`.

The job should move:
pending → claimed → done

and the browser should display real GDS frequency/Vpp and error percentages.

## Safety
The gateway uses outbound HTTPS only. The lab PC is not exposed to the Internet.
Browser clients never receive Redis credentials or raw SCPI access.
On gateway/job failure the MATLAB code switches AFG outputs OFF and restores LOCAL.
