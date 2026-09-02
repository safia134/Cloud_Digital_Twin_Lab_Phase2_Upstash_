# Bidirectional AFG <-> Twin Sync

This build adds:

- Twin -> AFG: existing verified-hardware job flow.
- AFG -> Twin: MATLAB heartbeat reads physical CH1/CH2 and the browser applies
  those values while Execution Mode = Verified Hardware.
- Physical AFG is authoritative during Verified Hardware mode.
- Browser refresh interval is 5 seconds (existing status poll interval).
- Offset command is skipped when requested offset is exactly 0 V so the AFG
  OFFSET front-panel parameter is not unnecessarily activated.

## MATLAB start command

```matlab
MATLAB_Hardware_Gateway_Bidirectional_v2( ...
    "https://cloud-digital-twin-lab-phase2-upsta.vercel.app", ...
    "quest-lab-01", ...
    "YOUR_CURRENT_GATEWAY_SHARED_KEY")
```

## Deployment

Replace the Vercel project files with this package and redeploy Production.
Then run the new MATLAB gateway. In Verified Hardware mode, manually changing
AFG frequency/amplitude/waveform/output should update the browser twin after
the next heartbeat/status cycle.


### v2 REM/LOC fix
Heartbeat snapshots now restore `SYSTEM:LOCAL` immediately after reading CH1/CH2, so the AFG front panel does not remain in REMOTE mode.
