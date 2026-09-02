from uuid import uuid4
from pathlib import Path
from datetime import datetime, timezone
from typing import Literal, Optional
import os
import json
import httpx

from fastapi import FastAPI, HTTPException, Header
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from twin.schemas import LabState, TraceResponse, VerifyResponse
from twin.virtual_engine import make_trace, verify_virtual

app = FastAPI(
    title="Cloud Digital Twin Lab API",
    version="0.3.0",
    description="Virtual + verified-hardware digital twin for GW Instek AFG-2225 and GDS-1102B",
)

STATIC_DIR = Path(__file__).resolve().parent / "static"
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")

@app.get("/", include_in_schema=False)
def frontend():
    return FileResponse(STATIC_DIR / "index.html")


class LoginRequest(BaseModel):
    student_id: str = Field(min_length=1, max_length=64)
    name: str = Field(min_length=1, max_length=120)

class LoginResponse(BaseModel):
    session_id: str
    student_id: str
    name: str

class HardwareJobCreate(BaseModel):
    student_id: str = Field(min_length=1, max_length=64)
    student_name: str = Field(min_length=1, max_length=120)
    session_id: Optional[str] = None
    channel: Literal[1, 2]
    state: LabState
    action: Literal["apply_and_measure", "apply_state", "output_off"] = "apply_and_measure"

class GatewayHeartbeat(BaseModel):
    gateway_id: str = Field(min_length=1, max_length=80)
    status: str = "online"
    afg_idn: Optional[str] = None
    gds_idn: Optional[str] = None
    afg_port: Optional[str] = None
    gds_port: Optional[str] = None
    version: str = "phase2-1.0"
    # Live physical AFG state, supplied by MATLAB heartbeat.
    # These are intentionally simple dictionaries so the gateway can evolve
    # without breaking the cloud API.
    afg_ch1: Optional[dict] = None
    afg_ch2: Optional[dict] = None

class GatewayJobResult(BaseModel):
    gateway_id: str = Field(min_length=1, max_length=80)
    status: Literal["done", "failed"]
    hardware_connected: bool = False
    afg_idn: Optional[str] = None
    gds_idn: Optional[str] = None
    afg_port: Optional[str] = None
    gds_port: Optional[str] = None
    configured_frequency_hz: Optional[float] = None
    configured_vpp_v: Optional[float] = None
    expected_hardware_vpp_v: Optional[float] = None
    measured_frequency_hz: Optional[float] = None
    measured_vpp_v: Optional[float] = None
    frequency_error_pct: Optional[float] = None
    amplitude_error_pct: Optional[float] = None
    load_text: Optional[str] = None
    frequency_method: Optional[str] = None
    trace_time_s: Optional[list[float]] = None
    trace_volts: Optional[list[float]] = None
    error_message: Optional[str] = None


JOB_TTL_SECONDS = 24 * 60 * 60
GATEWAY_TTL_SECONDS = 90
PENDING_QUEUE_KEY = "dt:hardware:pending"
LAST_GATEWAY_KEY = "dt:hardware:last_gateway"


def _redis_config():
    # Native Upstash names are preferred. KV_* is also accepted because
    # some Vercel marketplace integrations still expose those names.
    url = (
        os.getenv("UPSTASH_REDIS_REST_URL", "")
        or os.getenv("KV_REST_API_URL", "")
    ).rstrip("/")
    token = (
        os.getenv("UPSTASH_REDIS_REST_TOKEN", "")
        or os.getenv("KV_REST_API_TOKEN", "")
    )
    if not url or not token:
        raise HTTPException(
            status_code=503,
            detail=(
                "Verified Hardware queue is not configured. Connect an Upstash Redis "
                "database to Vercel or set UPSTASH_REDIS_REST_URL and "
                "UPSTASH_REDIS_REST_TOKEN."
            ),
        )
    return url, token


def _redis_command(*command):
    url, token = _redis_config()
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    try:
        r = httpx.post(
            url,
            headers=headers,
            json=list(command),
            timeout=12.0,
        )
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Upstash request failed: {exc}") from exc
    if r.status_code >= 400:
        raise HTTPException(status_code=502, detail=f"Upstash error {r.status_code}: {r.text[:500]}")
    try:
        payload = r.json()
    except ValueError as exc:
        raise HTTPException(status_code=502, detail="Upstash returned invalid JSON.") from exc
    if payload.get("error"):
        raise HTTPException(status_code=502, detail=f"Upstash command error: {payload['error']}")
    return payload.get("result")


def _redis_pipeline(commands):
    url, token = _redis_config()
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    try:
        r = httpx.post(
            f"{url}/pipeline",
            headers=headers,
            json=commands,
            timeout=12.0,
        )
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Upstash pipeline failed: {exc}") from exc
    if r.status_code >= 400:
        raise HTTPException(status_code=502, detail=f"Upstash error {r.status_code}: {r.text[:500]}")
    try:
        payload = r.json()
    except ValueError as exc:
        raise HTTPException(status_code=502, detail="Upstash returned invalid pipeline JSON.") from exc
    for item in payload:
        if item.get("error"):
            raise HTTPException(status_code=502, detail=f"Upstash pipeline error: {item['error']}")
    return [item.get("result") for item in payload]


def _job_key(job_id: str) -> str:
    return f"dt:hardware:job:{job_id}"


def _gateway_key(gateway_id: str) -> str:
    return f"dt:hardware:gateway:{gateway_id}"


def _json_store(value) -> str:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def _json_load(value, *, what="record"):
    if value is None:
        return None
    if isinstance(value, (dict, list)):
        return value
    try:
        return json.loads(value)
    except (TypeError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=502, detail=f"Stored Upstash {what} is invalid JSON.") from exc


def _get_job(job_id: str):
    return _json_load(_redis_command("GET", _job_key(job_id)), what="job")


def _save_job(job: dict):
    _redis_command("SET", _job_key(job["id"]), _json_store(job), "EX", JOB_TTL_SECONDS)
    return job


def _require_gateway(x_gateway_key: Optional[str]):
    expected = os.getenv("GATEWAY_SHARED_KEY", "")
    if not expected:
        raise HTTPException(status_code=503, detail="GATEWAY_SHARED_KEY is not configured in Vercel.")
    if not x_gateway_key or x_gateway_key != expected:
        raise HTTPException(status_code=401, detail="Invalid gateway key.")


def _record_or_404(record, what="job"):
    if not record:
        raise HTTPException(status_code=404, detail=f"Hardware {what} not found.")
    return record


@app.get("/api/health")
def health():
    return {
        "status": "ok",
        "mode": "Virtual + Verified Digital Twin Lab",
        "phase": 2,
        "deployment": "Vercel stateless API + Upstash Redis hardware queue",
    }

@app.post("/api/login", response_model=LoginResponse)
def login(req: LoginRequest):
    return LoginResponse(
        session_id=uuid4().hex,
        student_id=req.student_id.strip(),
        name=req.name.strip(),
    )

@app.post("/api/scope/{channel}/trace", response_model=TraceResponse)
def get_trace(channel: int, state: LabState, samples: int = 2500):
    if channel not in (1, 2):
        raise HTTPException(status_code=400, detail="Channel must be 1 or 2")
    selected = state.selected_afg_channel
    afg = state.afg_ch1 if selected == 1 else state.afg_ch2
    scope_ch = state.scope.ch1 if channel == 1 else state.scope.ch2
    data = make_trace(
        afg_settings=afg,
        dut=state.dut,
        scope_ch=scope_ch,
        time_div_s=state.scope.time_div_s,
        selected_afg_channel=selected,
        requested_scope_channel=channel,
        samples=samples,
    )
    return TraceResponse(channel=channel, **data)

@app.post("/api/verify/{channel}", response_model=VerifyResponse)
def verify(channel: int, state: LabState):
    if channel not in (1, 2):
        raise HTTPException(status_code=400, detail="Channel must be 1 or 2")
    selected = state.selected_afg_channel
    afg = state.afg_ch1 if selected == 1 else state.afg_ch2
    scope_ch = state.scope.ch1 if channel == 1 else state.scope.ch2
    result = verify_virtual(
        afg_settings=afg,
        dut=state.dut,
        scope_ch=scope_ch,
        time_div_s=state.scope.time_div_s,
        selected_afg_channel=selected,
        channel=channel,
    )
    return VerifyResponse(channel=channel, **result)


# ---------------- Phase 2: verified hardware queue ----------------

@app.post("/api/hardware/jobs")
def create_hardware_job(req: HardwareJobCreate):
    # Initial Phase-2 physical fixture is direct AFG BNC -> matching GDS input.
    # RC experiments remain virtual until an actual RC fixture is installed in the lab.
    if req.state.dut.type != "Loopback" and req.action == "apply_and_measure":
        raise HTTPException(
            status_code=400,
            detail="Verified hardware currently supports Experiment 1 (Direct AFG -> GDS) only. RC hardware fixture is not yet enabled.",
        )
    if req.state.selected_afg_channel != req.channel:
        raise HTTPException(status_code=400, detail="Selected AFG channel must match the requested hardware channel.")

    selected = req.state.selected_afg_channel
    afg = req.state.afg_ch1 if selected == 1 else req.state.afg_ch2
    scope_ch = req.state.scope.ch1 if req.channel == 1 else req.state.scope.ch2
    virtual = verify_virtual(
        afg_settings=afg,
        dut=req.state.dut,
        scope_ch=scope_ch,
        time_div_s=req.state.scope.time_div_s,
        selected_afg_channel=selected,
        channel=req.channel,
    )

    now = datetime.now(timezone.utc).isoformat()
    job_id = uuid4().hex
    job = {
        "id": job_id,
        "created_at": now,
        "student_id": req.student_id.strip(),
        "student_name": req.student_name.strip(),
        "session_id": req.session_id,
        "channel": req.channel,
        "action": req.action,
        "status": "pending",
        "state": req.state.model_dump(),
        "virtual_expected_frequency_hz": virtual["expected_frequency_hz"],
        "virtual_expected_vpp_v": virtual["expected_vpp_v"],
        "gateway_id": None,
        "claimed_at": None,
        "completed_at": None,
        "result": None,
        "error_message": None,
    }

    # RPUSH + LPOP implements FIFO. LPOP is atomic, so two gateways cannot
    # claim the same queued job.
    _redis_pipeline([
        ["SET", _job_key(job_id), _json_store(job), "EX", JOB_TTL_SECONDS],
        ["RPUSH", PENDING_QUEUE_KEY, job_id],
    ])
    return job


@app.get("/api/hardware/jobs/{job_id}")
def get_hardware_job(job_id: str):
    job = _record_or_404(_get_job(job_id))
    # The browser does not need the full LabState after submission.
    return {
        "id": job["id"],
        "created_at": job.get("created_at"),
        "channel": job.get("channel"),
        "action": job.get("action"),
        "status": job.get("status"),
        "virtual_expected_frequency_hz": job.get("virtual_expected_frequency_hz"),
        "virtual_expected_vpp_v": job.get("virtual_expected_vpp_v"),
        "gateway_id": job.get("gateway_id"),
        "claimed_at": job.get("claimed_at"),
        "completed_at": job.get("completed_at"),
        "result": job.get("result"),
        "error_message": job.get("error_message"),
    }


@app.get("/api/hardware/status")
def hardware_status():
    gateway_id = _redis_command("GET", LAST_GATEWAY_KEY)
    if not gateway_id:
        return {"online": False, "status": "no_gateway"}

    gateway = _json_load(
        _redis_command("GET", _gateway_key(str(gateway_id))),
        what="gateway",
    )
    if not gateway:
        return {"online": False, "status": "offline", "gateway_id": gateway_id}

    online = False
    try:
        last_seen = datetime.fromisoformat(str(gateway["last_seen"]).replace("Z", "+00:00"))
        online = (datetime.now(timezone.utc) - last_seen).total_seconds() <= 45
    except Exception:
        online = False
    return {"online": online, **gateway}


@app.post("/api/gateway/heartbeat")
def gateway_heartbeat(req: GatewayHeartbeat, x_gateway_key: Optional[str] = Header(default=None)):
    _require_gateway(x_gateway_key)
    gateway = {
        "gateway_id": req.gateway_id,
        "last_seen": datetime.now(timezone.utc).isoformat(),
        "status": req.status,
        "afg_idn": req.afg_idn,
        "gds_idn": req.gds_idn,
        "afg_port": req.afg_port,
        "gds_port": req.gds_port,
        "version": req.version,
        "afg_ch1": req.afg_ch1,
        "afg_ch2": req.afg_ch2,
    }
    _redis_pipeline([
        ["SET", _gateway_key(req.gateway_id), _json_store(gateway), "EX", GATEWAY_TTL_SECONDS],
        ["SET", LAST_GATEWAY_KEY, req.gateway_id, "EX", GATEWAY_TTL_SECONDS],
    ])
    return gateway


@app.get("/api/gateway/jobs/next")
def gateway_next_job(gateway_id: str, x_gateway_key: Optional[str] = Header(default=None)):
    _require_gateway(x_gateway_key)

    # Expired/cancelled job IDs can remain in the list until a gateway sees
    # them. Skip a few stale entries in one poll.
    for _ in range(8):
        job_id = _redis_command("LPOP", PENDING_QUEUE_KEY)
        if not job_id:
            return {"job": None}

        job = _get_job(str(job_id))
        if not job or job.get("status") != "pending":
            continue

        job["status"] = "claimed"
        job["gateway_id"] = gateway_id
        job["claimed_at"] = datetime.now(timezone.utc).isoformat()
        _save_job(job)
        return {"job": job}

    return {"job": None}


@app.post("/api/gateway/jobs/{job_id}/result")
def gateway_submit_result(job_id: str, req: GatewayJobResult, x_gateway_key: Optional[str] = Header(default=None)):
    _require_gateway(x_gateway_key)
    job = _record_or_404(_get_job(job_id))

    if job.get("gateway_id") != req.gateway_id:
        raise HTTPException(status_code=409, detail="This hardware job was not claimed by the submitting gateway.")

    result_dict = req.model_dump(exclude={"gateway_id", "status", "error_message"})
    job["status"] = req.status
    job["completed_at"] = datetime.now(timezone.utc).isoformat()
    job["result"] = result_dict
    job["error_message"] = req.error_message
    _save_job(job)
    return job
