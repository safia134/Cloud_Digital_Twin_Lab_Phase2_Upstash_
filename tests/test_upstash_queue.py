import json
from fastapi.testclient import TestClient
import api.index as api_index

client = TestClient(api_index.app)

BASE_STATE = {
    "selected_afg_channel": 1,
    "afg_ch1": {
        "waveform": "Sine", "frequency_hz": 1000, "amplitude_vpp": 2,
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
    "dut": {"type": "Loopback", "resistance_ohm": 1000, "capacitance_f": 1e-6}
}

def test_job_lifecycle(monkeypatch):
    store = {}
    lists = {}

    def cmd(*args):
        op = str(args[0]).upper()
        if op == "GET":
            return store.get(str(args[1]))
        if op == "SET":
            store[str(args[1])] = args[2]
            return "OK"
        if op == "RPUSH":
            lists.setdefault(str(args[1]), []).append(str(args[2]))
            return len(lists[str(args[1])])
        if op == "LPOP":
            q = lists.setdefault(str(args[1]), [])
            return q.pop(0) if q else None
        raise AssertionError(args)

    def pipe(commands):
        return [cmd(*c) for c in commands]

    monkeypatch.setattr(api_index, "_redis_command", cmd)
    monkeypatch.setattr(api_index, "_redis_pipeline", pipe)
    monkeypatch.setenv("GATEWAY_SHARED_KEY", "test-gateway-secret")

    create = client.post("/api/hardware/jobs", json={
        "student_id": "23TC-01",
        "student_name": "Test Student",
        "session_id": "abc",
        "channel": 1,
        "state": BASE_STATE,
        "action": "apply_and_measure"
    })
    assert create.status_code == 200
    job_id = create.json()["id"]
    assert create.json()["status"] == "pending"

    claim = client.get(
        "/api/gateway/jobs/next?gateway_id=quest-lab-01",
        headers={"X-Gateway-Key": "test-gateway-secret"},
    )
    assert claim.status_code == 200
    assert claim.json()["job"]["id"] == job_id
    assert claim.json()["job"]["status"] == "claimed"

    result = client.post(
        f"/api/gateway/jobs/{job_id}/result",
        headers={"X-Gateway-Key": "test-gateway-secret"},
        json={
            "gateway_id": "quest-lab-01",
            "status": "done",
            "hardware_connected": True,
            "measured_frequency_hz": 999.8,
            "measured_vpp_v": 1.98,
            "frequency_error_pct": 0.02,
            "amplitude_error_pct": 1.0
        },
    )
    assert result.status_code == 200
    assert result.json()["status"] == "done"

    readback = client.get(f"/api/hardware/jobs/{job_id}")
    assert readback.status_code == 200
    assert readback.json()["result"]["measured_frequency_hz"] == 999.8
