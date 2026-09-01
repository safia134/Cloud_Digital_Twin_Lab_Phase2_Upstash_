from fastapi.testclient import TestClient
from api.index import app

client = TestClient(app)

BASE_STATE = {
    "selected_afg_channel": 1,
    "afg_ch1": {
        "waveform": "Sine",
        "frequency_hz": 1000,
        "amplitude_vpp": 2,
        "offset_v": 0,
        "phase_deg": 0,
        "duty_pct": 50,
        "output_on": True
    },
    "afg_ch2": {
        "waveform": "Sine",
        "frequency_hz": 1000,
        "amplitude_vpp": 1,
        "offset_v": 0,
        "phase_deg": 0,
        "duty_pct": 50,
        "output_on": True
    },
    "scope": {
        "time_div_s": 0.0004,
        "trigger_level_v": 0,
        "trigger_edge": "Rising",
        "ch1": {"enabled": True, "volts_div": 0.4, "position_div": 1, "coupling": "DC", "probe_x": 1},
        "ch2": {"enabled": False, "volts_div": 1, "position_div": -1, "coupling": "DC", "probe_x": 1}
    },
    "dut": {
        "type": "RC Low-pass",
        "resistance_ohm": 1000,
        "capacitance_f": 1e-6
    }
}

def test_health():
    r = client.get("/api/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"

def test_login():
    r = client.post("/api/login", json={"student_id": "23TC-01", "name": "Test Student"})
    assert r.status_code == 200
    assert r.json()["student_id"] == "23TC-01"

def test_rc_trace():
    r = client.post("/api/scope/1/trace?samples=4000", json=BASE_STATE)
    assert r.status_code == 200
    data = r.json()
    assert abs(data["frequency_hz"] - 1000) < 1e-9
    assert abs(data["vpp_v"] - 0.3143) < 0.01

def test_verify():
    r = client.post("/api/verify/1", json=BASE_STATE)
    assert r.status_code == 200
    data = r.json()
    assert data["passed"] is True
    assert data["amplitude_error_pct"] < 1.0
