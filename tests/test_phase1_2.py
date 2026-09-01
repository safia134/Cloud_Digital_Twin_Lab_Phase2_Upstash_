from fastapi.testclient import TestClient
from api.index import app

client = TestClient(app)

def make_state(dut_type, f=1000, vpp=2):
    return {
        "selected_afg_channel": 1,
        "afg_ch1": {
            "waveform": "Sine", "frequency_hz": f, "amplitude_vpp": vpp,
            "offset_v": 0, "phase_deg": 0, "duty_pct": 50, "output_on": True
        },
        "afg_ch2": {
            "waveform": "Sine", "frequency_hz": 1000, "amplitude_vpp": 1,
            "offset_v": 0, "phase_deg": 0, "duty_pct": 50, "output_on": True
        },
        "scope": {
            "time_div_s": 0.0004, "trigger_level_v": 0, "trigger_edge": "Rising",
            "ch1": {"enabled": True, "volts_div": .4, "position_div": 1, "coupling": "DC", "probe_x": 1},
            "ch2": {"enabled": False, "volts_div": 1, "position_div": -1, "coupling": "DC", "probe_x": 1}
        },
        "dut": {"type": dut_type, "resistance_ohm": 1000, "capacitance_f": 1e-6}
    }

def test_root_has_experiments():
    r = client.get("/")
    assert r.status_code == 200
    assert "experimentSelect" in r.text
    assert "RC High-pass" in r.text

def test_lowpass():
    r = client.post("/api/verify/1", json=make_state("RC Low-pass"))
    assert r.status_code == 200
    d = r.json()
    assert d["passed"] is True
    assert abs(d["expected_vpp_v"] - 0.31435) < 0.01

def test_highpass():
    r = client.post("/api/verify/1", json=make_state("RC High-pass"))
    assert r.status_code == 200
    d = r.json()
    assert d["passed"] is True
    assert 1.9 < d["expected_vpp_v"] < 2.01
