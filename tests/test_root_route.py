from fastapi.testclient import TestClient
from api.index import app

client = TestClient(app)

def test_root_page():
    r = client.get("/")
    assert r.status_code == 200
    assert "Cloud Digital Twin Lab" in r.text

def test_static_js():
    r = client.get("/static/app.js")
    assert r.status_code == 200

def test_health_v2():
    r = client.get("/api/health")
    assert r.status_code == 200
