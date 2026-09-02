# Full Two-Way Sync v4

Fixes:
- Verification no longer automatically turns the AFG output OFF.
- Browser OUTPUT ON/OFF controls the real AFG in Verified Hardware mode.
- Browser waveform/frequency/amplitude/offset/phase/duty changes are sent to
  the real AFG immediately in Verified Hardware mode.
- Physical AFG state continues to flow back to the browser through heartbeat.
- AFG is restored to LOCAL after command/query transactions.
- Ctrl+C gateway shutdown remains fail-safe: CH1/CH2 are turned OFF.

Run exactly:
MATLAB_Hardware_Gateway("https://cloud-digital-twin-lab-phase2-upsta.vercel.app",
                        "quest-lab-01",
                        "YOUR_CURRENT_GATEWAY_SHARED_KEY")
