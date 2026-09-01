from fastapi.testclient import TestClient
from api.index import app

client = TestClient(app)

def test_phase2_health():
    r = client.get('/api/health')
    assert r.status_code == 200
    assert r.json()['phase'] == 2
    assert 'Upstash' in r.json()['deployment']

def test_root_has_verified_button():
    r = client.get('/')
    assert r.status_code == 200
    assert 'VERIFY ON REAL HARDWARE' in r.text

def test_hardware_status_requires_queue_config_when_not_configured(monkeypatch):
    monkeypatch.delenv('UPSTASH_REDIS_REST_URL', raising=False)
    monkeypatch.delenv('UPSTASH_REDIS_REST_TOKEN', raising=False)
    monkeypatch.delenv('KV_REST_API_URL', raising=False)
    monkeypatch.delenv('KV_REST_API_TOKEN', raising=False)
    r = client.get('/api/hardware/status')
    assert r.status_code == 503
