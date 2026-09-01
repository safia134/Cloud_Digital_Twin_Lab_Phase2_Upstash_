# Cloud Digital Twin Lab — Phase 2 Verified Mode

This package extends the working Phase 1.2 Vercel Virtual Twin Lab with a
persistent hardware-job queue and a MATLAB gateway for the university lab PC.

## What Phase 2 does

Browser -> Vercel API -> Supabase hardware job -> MATLAB gateway -> AFG-2225 ->
BNC -> GDS-1102B -> MATLAB -> cloud result -> browser.

The browser never sends raw SCPI. The MATLAB gateway validates a common LabState
and applies the instrument commands locally.

## Initial physical scope

Phase 2 verified hardware supports Experiment 1 only:

- AFG CH1 BNC -> GDS CH1
- AFG CH2 BNC -> GDS CH2

RC Low-pass/High-pass remain virtual until a physical RC fixture is inserted and
modelled in the verified path.

## Deploy steps

1. Upload this package to the SAME GitHub repository connected to Vercel.
2. Create a Supabase project and run `supabase_phase2.sql` in its SQL editor.
3. In Vercel Project -> Environment Variables, add:
   - `SUPABASE_URL`
   - `SUPABASE_SECRET_KEY (preferred; sb_secret_...)`
   - `GATEWAY_SHARED_KEY` (a long random secret)
4. Redeploy Vercel.
5. On the university lab PC, run:

```matlab
MATLAB_Hardware_Gateway( ...
  "https://cloud-digital-twin-lab-vercel.vercel.app", ...
  "quest-lab-01", ...
  "THE-SAME-GATEWAY_SHARED_KEY")
```

6. The browser should show `Hardware gateway: ONLINE`.
7. Select Experiment 1, `Verified Hardware`, turn the AFG output ON, then press
   `VERIFY ON REAL HARDWARE`.

## Safety envelope in the gateway

The initial verified-mode worker deliberately limits each requested signal to:

- 1 to 10,000 Hz
- 0.001 to 10 Vpp
- |offset| <= 5 V
- |offset| + Vpp/2 <= 5 V
- phase -180..180 deg
- duty 1..99 %

A verified job turns the selected AFG output OFF after measurement. Gateway
shutdown also turns CH1 and CH2 OFF and restores the AFG front panel to LOCAL.
