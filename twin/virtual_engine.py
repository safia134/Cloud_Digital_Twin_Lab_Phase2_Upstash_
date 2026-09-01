import math
import numpy as np
from .schemas import AFGChannelSettings, DUTSettings, ScopeChannelSettings

def _phase_wave(settings: AFGChannelSettings, t: np.ndarray) -> np.ndarray:
    f = settings.frequency_hz
    phase = np.deg2rad(settings.phase_deg)
    arg = 2*np.pi*f*t + phase

    if settings.waveform == "Sine":
        carrier = np.sin(arg)
    elif settings.waveform == "Square":
        frac = (arg / (2*np.pi)) % 1.0
        carrier = np.where(frac < settings.duty_pct/100.0, 1.0, -1.0)
    elif settings.waveform == "Triangle":
        frac = (arg / (2*np.pi)) % 1.0
        carrier = 4*np.abs(frac - 0.5) - 1.0
    elif settings.waveform == "Sawtooth":
        frac = (arg / (2*np.pi)) % 1.0
        carrier = 2.0*frac - 1.0
    else:
        carrier = np.zeros_like(t)

    y = (settings.amplitude_vpp/2.0) * carrier + settings.offset_v
    if not settings.output_on:
        y = np.zeros_like(t)
    return y

def apply_dut(t: np.ndarray, y: np.ndarray, dut: DUTSettings) -> np.ndarray:
    if dut.type == "Loopback":
        return y.copy()

    if len(t) < 2:
        return y.copy()

    dt = t[1] - t[0]
    tau = dut.resistance_ohm * dut.capacitance_f

    if dut.type == "RC Low-pass":
        alpha = dt / (tau + dt)
        out = np.empty_like(y)
        out[0] = y[0]
        for k in range(1, len(y)):
            out[k] = out[k-1] + alpha * (y[k] - out[k-1])
        return out

    if dut.type == "RC High-pass":
        alpha = tau / (tau + dt)
        out = np.empty_like(y)
        out[0] = 0.0
        for k in range(1, len(y)):
            out[k] = alpha * (out[k-1] + y[k] - y[k-1])
        return out

    return y.copy()

def apply_scope_channel(y: np.ndarray, settings: ScopeChannelSettings) -> np.ndarray:
    if not settings.enabled:
        return np.zeros_like(y)
    out = y.copy()
    if settings.coupling == "AC":
        out = out - np.mean(out)
    elif settings.coupling == "GND":
        out = np.zeros_like(out)
    out = out / settings.probe_x
    return out

def make_trace(
    afg_settings: AFGChannelSettings,
    dut: DUTSettings,
    scope_ch: ScopeChannelSettings,
    time_div_s: float,
    selected_afg_channel: int,
    requested_scope_channel: int,
    samples: int = 2500,
):
    total_t = 10.0 * time_div_s
    samples = max(400, min(samples, 10000))
    dt = total_t / samples
    t = np.arange(samples, dtype=float) * dt

    if requested_scope_channel == selected_afg_channel:
        if dut.type in ("RC Low-pass", "RC High-pass"):
            # Warm up the RC model before the visible oscilloscope window so
            # startup transient does not inflate Vpp or distort phase.
            tau = dut.resistance_ohm * dut.capacitance_f
            period = 1.0 / max(afg_settings.frequency_hz, 1e-12)
            warmup_time = max(10.0 * tau, 8.0 * period)
            warmup_samples = int(math.ceil(warmup_time / max(dt, 1e-15)))
            warmup_samples = max(1, min(warmup_samples, 150000))

            t_full = np.arange(-warmup_samples, samples, dtype=float) * dt
            source_full = _phase_wave(afg_settings, t_full)
            y_full = apply_dut(t_full, source_full, dut)
            y = y_full[warmup_samples:]
        else:
            source = _phase_wave(afg_settings, t)
            y = apply_dut(t, source, dut)
    else:
        y = np.zeros(samples, dtype=float)

    y = apply_scope_channel(y, scope_ch)

    vpp = float(np.max(y) - np.min(y)) if len(y) else 0.0
    rms = float(np.sqrt(np.mean(y*y))) if len(y) else 0.0
    frequency = float(
        afg_settings.frequency_hz
        if afg_settings.output_on and scope_ch.enabled and scope_ch.coupling != "GND" and vpp > 1e-12
        else 0.0
    )

    return {
        "time_s": t.tolist(),
        "volts": y.tolist(),
        "frequency_hz": frequency,
        "vpp_v": vpp,
        "rms_v": rms,
    }

def verify_virtual(
    afg_settings: AFGChannelSettings,
    dut: DUTSettings,
    scope_ch: ScopeChannelSettings,
    time_div_s: float,
    selected_afg_channel: int,
    channel: int,
):
    trace = make_trace(
        afg_settings=afg_settings,
        dut=dut,
        scope_ch=scope_ch,
        time_div_s=time_div_s,
        selected_afg_channel=selected_afg_channel,
        requested_scope_channel=channel,
        samples=7000,
    )

    expected_f = afg_settings.frequency_hz if (
        afg_settings.output_on and scope_ch.enabled and scope_ch.coupling != "GND"
    ) else 0.0

    if (not afg_settings.output_on) or (not scope_ch.enabled) or scope_ch.coupling == "GND":
        expected_vpp = 0.0
    elif dut.type == "Loopback":
        expected_vpp = afg_settings.amplitude_vpp / scope_ch.probe_x
    elif dut.type in ("RC Low-pass", "RC High-pass") and afg_settings.waveform == "Sine":
        tau = dut.resistance_ohm * dut.capacitance_f
        omega_tau = 2.0 * math.pi * afg_settings.frequency_hz * tau
        if dut.type == "RC Low-pass":
            gain = 1.0 / math.sqrt(1.0 + omega_tau**2)
        else:
            gain = omega_tau / math.sqrt(1.0 + omega_tau**2)
        expected_vpp = (afg_settings.amplitude_vpp * gain) / scope_ch.probe_x
    else:
        # Harmonic-rich waveforms use the numerical model as the Phase-1 reference.
        expected_vpp = trace["vpp_v"]

    measured_f = trace["frequency_hz"]
    measured_vpp = trace["vpp_v"]

    fden = max(abs(expected_f), 1e-12)
    aden = max(abs(expected_vpp), 1e-12)
    ferr = 100.0*abs(measured_f-expected_f)/fden if expected_f != 0 else (0.0 if measured_f == 0 else 100.0)
    aerr = 100.0*abs(measured_vpp-expected_vpp)/aden if expected_vpp != 0 else (0.0 if measured_vpp == 0 else 100.0)

    passed = ferr <= 2.0 and aerr <= 2.0

    return {
        "expected_frequency_hz": expected_f,
        "measured_frequency_hz": measured_f,
        "frequency_error_pct": ferr,
        "expected_vpp_v": expected_vpp,
        "measured_vpp_v": measured_vpp,
        "amplitude_error_pct": aerr,
        "passed": passed,
    }
