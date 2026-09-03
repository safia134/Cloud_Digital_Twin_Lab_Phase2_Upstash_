let studentName = "";
let studentId = "";
let sessionId = "";
let gatewayOnline = false;
let selectedChannel = 1;
let outputOn = true;

const $ = (id) => document.getElementById(id);

const state = {
  selected_afg_channel: 1,
  afg_ch1: {
    waveform: "Sine",
    frequency_hz: 1000,
    amplitude_vpp: 2,
    offset_v: 0,
    phase_deg: 0,
    duty_pct: 50,
    output_on: true
  },
  afg_ch2: {
    waveform: "Sine",
    frequency_hz: 1000,
    amplitude_vpp: 1,
    offset_v: 0,
    phase_deg: 0,
    duty_pct: 50,
    output_on: true
  },
  scope: {
    time_div_s: 0.0005,
    trigger_level_v: 0,
    trigger_edge: "Rising",
    ch1: { enabled: true, volts_div: 1, position_div: 1, coupling: "DC", probe_x: 1 },
    ch2: { enabled: true, volts_div: 1, position_div: -1, coupling: "DC", probe_x: 1 }
  },
  dut: {
    type: "Loopback",
    resistance_ohm: 1000,
    capacitance_f: 0.000001
  }
};

const EXPERIMENTS = {
  "loopback": {
    objective: "Observe the direct virtual AFG output on the virtual GDS and verify frequency and Vpp.",
    dut: "Loopback"
  },
  "rc-lowpass": {
    objective: "Study attenuation above the RC cutoff frequency and compare theory with the virtual GDS measurement.",
    dut: "RC Low-pass"
  },
  "rc-highpass": {
    objective: "Study attenuation below the RC cutoff frequency and compare theory with the virtual GDS measurement.",
    dut: "RC High-pass"
  }
};

function theoreticalSummary() {
  const a = selectedAfgState();
  const R = Math.max(state.dut.resistance_ohm, 1e-12);
  const C = Math.max(state.dut.capacitance_f, 1e-18);
  const f = Math.max(a.frequency_hz, 0);
  const vin = Math.max(a.amplitude_vpp, 0);
  const probe = selectedChannel === 1 ? state.scope.ch1.probe_x : state.scope.ch2.probe_x;

  if (!a.output_on) {
    return `Output is OFF\nExpected frequency: 0 Hz\nExpected Vpp: 0 Vpp`;
  }

  if (state.dut.type === "Loopback") {
    return `Direct loopback\nExpected frequency: ${f.toFixed(4)} Hz\nExpected Vpp: ${(vin/probe).toFixed(6)} Vpp`;
  }

  const fc = 1/(2*Math.PI*R*C);
  const ratio = f/fc;
  let gain;
  let label;
  if (state.dut.type === "RC Low-pass") {
    gain = 1/Math.sqrt(1 + ratio*ratio);
    label = "Low-pass gain";
  } else {
    gain = ratio/Math.sqrt(1 + ratio*ratio);
    label = "High-pass gain";
  }
  const expected = vin*gain/probe;
  return `fc = ${fc.toFixed(3)} Hz
${label} = ${gain.toFixed(6)}
Expected frequency = ${f.toFixed(4)} Hz
Expected Vpp = ${expected.toFixed(6)} Vpp`;
}

function updateExperimentUI() {
  const key = $("experimentSelect").value;
  const exp = EXPERIMENTS[key];
  $("experimentObjective").textContent = exp.objective;
  state.dut.type = exp.dut;
  $("dutType").value = exp.dut;
  $("theoryBox").textContent = theoreticalSummary();
}

async function api(path, options = {}) {
  options.headers = options.headers || {};
  if (options.body && typeof options.body !== "string") {
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(options.body);
  }
  const res = await fetch(path, options);
  if (!res.ok) {
    let detail = "Request failed";
    try { detail = (await res.json()).detail || detail; } catch {}
    throw new Error(detail);
  }
  return res.json();
}

$("loginBtn").addEventListener("click", async () => {
  $("loginError").textContent = "";
  studentId = $("studentId").value.trim();
  studentName = $("studentName").value.trim();

  if (!studentId || !studentName) {
    $("loginError").textContent = "Please enter Student ID and name.";
    return;
  }

  try {
    const data = await api("/api/login", {
      method: "POST",
      body: { student_id: studentId, name: studentName }
    });
    sessionId = data.session_id;
    $("studentBadge").textContent = `${data.student_id} — ${data.name}`;
    $("loginView").classList.add("hidden");
    $("labView").classList.remove("hidden");
    selectedChannel = 1;
    state.selected_afg_channel = 1;
    loadSelectedChannelIntoForm();
    syncScopeFormFromState();
    syncDutFormFromState();
    $("experimentSelect").value = "loopback";
    updateExperimentUI();
    await refreshAll();
  } catch (e) {
    $("loginError").textContent = e.message;
  }
});

function selectedAfgState() {
  return selectedChannel === 1 ? state.afg_ch1 : state.afg_ch2;
}

function saveAFGFormToState() {
  const a = selectedAfgState();
  a.waveform = $("waveform").value;
  a.frequency_hz = Number($("frequency").value);
  a.amplitude_vpp = Number($("amplitude").value);
  a.offset_v = Number($("offset").value);
  a.phase_deg = Number($("phase").value);
  a.duty_pct = Number($("duty").value);
  a.output_on = outputOn;
  state.selected_afg_channel = selectedChannel;
}

function saveScopeFormToState() {
  const mode = $("displayMode").value;
  state.scope.time_div_s = Number($("timeDiv").value);
  state.scope.ch1.enabled = mode === "both" || mode === "ch1";
  state.scope.ch1.volts_div = Number($("ch1Vdiv").value);
  state.scope.ch1.position_div = Number($("ch1Pos").value);
  state.scope.ch1.coupling = $("ch1Coupling").value;
  state.scope.ch1.probe_x = Number($("ch1Probe").value);

  state.scope.ch2.enabled = mode === "both" || mode === "ch2";
  state.scope.ch2.volts_div = Number($("ch2Vdiv").value);
  state.scope.ch2.position_div = Number($("ch2Pos").value);
  state.scope.ch2.coupling = $("ch2Coupling").value;
  state.scope.ch2.probe_x = Number($("ch2Probe").value);
}

function saveDutFormToState() {
  state.dut.type = $("dutType").value;
  state.dut.resistance_ohm = Number($("dutR").value);
  state.dut.capacitance_f = Number($("dutC").value);
}

function loadSelectedChannelIntoForm() {
  const a = selectedAfgState();
  $("waveform").value = a.waveform;
  $("frequency").value = a.frequency_hz;
  $("amplitude").value = a.amplitude_vpp;
  $("offset").value = a.offset_v;
  $("phase").value = a.phase_deg;
  $("duty").value = a.duty_pct;
  outputOn = a.output_on;
  updateOutputButton();
}

function syncScopeFormFromState() {
  $("timeDiv").value = state.scope.time_div_s;
  if (state.scope.ch1.enabled && state.scope.ch2.enabled) $("displayMode").value = "both";
  else if (state.scope.ch1.enabled) $("displayMode").value = "ch1";
  else $("displayMode").value = "ch2";

  $("ch1Vdiv").value = state.scope.ch1.volts_div;
  $("ch1Pos").value = state.scope.ch1.position_div;
  $("ch1Coupling").value = state.scope.ch1.coupling;
  $("ch1Probe").value = String(state.scope.ch1.probe_x);

  $("ch2Vdiv").value = state.scope.ch2.volts_div;
  $("ch2Pos").value = state.scope.ch2.position_div;
  $("ch2Coupling").value = state.scope.ch2.coupling;
  $("ch2Probe").value = String(state.scope.ch2.probe_x);
}

function syncDutFormFromState() {
  $("dutType").value = state.dut.type;
  $("dutR").value = state.dut.resistance_ohm;
  $("dutC").value = state.dut.capacitance_f;
}

function updateOutputButton() {
  $("outputBtn").textContent = outputOn ? "OUTPUT ON" : "OUTPUT OFF";
  $("outputBtn").classList.toggle("on", outputOn);
}

document.querySelectorAll(".channel-btn").forEach(btn => {
  btn.addEventListener("click", async () => {
    saveAFGFormToState();
    selectedChannel = Number(btn.dataset.ch);
    state.selected_afg_channel = selectedChannel;
    document.querySelectorAll(".channel-btn").forEach(b => b.classList.toggle("active", b === btn));
    loadSelectedChannelIntoForm();
    await refreshAll();
  });
});

async function sendTwinStateToHardware(action = "apply_state") {
  if ($("executionMode").value !== "verified" || !gatewayOnline) return;
  if (state.dut.type !== "Loopback") return;

  collectState();
  try {
    const job = await api("/api/hardware/jobs", {
      method: "POST",
      body: {
        student_id: studentId,
        student_name: studentName,
        session_id: sessionId,
        channel: selectedChannel,
        state,
        action
      }
    });

    const box = $("hardwareVerifyBox");
    if (action === "output_off") {
      box.textContent = `Sending CH${selectedChannel} OUTPUT OFF to hardware...`;
    } else {
      box.textContent = `Applying Twin CH${selectedChannel} settings to real AFG...`;
    }

    // Short poll: this is a control/sync job, not a full verification.
    for (let i = 0; i < 20; i++) {
      const r = await api(`/api/hardware/jobs/${job.id}`);
      if (r.status === "done") {
        box.textContent = `Twin → AFG synchronized on CH${selectedChannel}.`;
        return;
      }
      if (r.status === "failed") {
        box.textContent = `Twin → AFG sync failed: ${r.error_message || "hardware job failed"}`;
        return;
      }
      await new Promise(resolve => setTimeout(resolve, 500));
    }
  } catch (e) {
    $("hardwareVerifyBox").textContent = `Twin → AFG sync error: ${e.message}`;
  }
}

$("outputBtn").addEventListener("click", async () => {
  outputOn = !outputOn;
  saveAFGFormToState();
  updateOutputButton();
  await refreshAll();

  // In Verified Hardware mode the OUTPUT button controls the real AFG too.
  if ($("executionMode").value === "verified" && gatewayOnline) {
    if (outputOn) {
      await sendTwinStateToHardware("apply_state");
    } else {
      await sendTwinStateToHardware("output_off");
    }
  }
});

function collectState() {
  saveAFGFormToState();
  saveScopeFormToState();
  saveDutFormToState();
  return state;
}

async function refreshAll() {
  collectState();
  updateAFGDisplay();
  $("theoryBox").textContent = theoreticalSummary();
  await refreshScope();
}

function updateAFGDisplay() {
  const a = selectedAfgState();
  $("afgWaveTitle").textContent = `CH${selectedChannel} ${a.waveform.toUpperCase()}`;
  $("afgReadout").textContent =
`FREQ    ${a.frequency_hz} Hz
AMPL    ${a.amplitude_vpp} Vpp
OFFSET  ${a.offset_v} V
PHASE   ${a.phase_deg} deg
DUTY    ${a.duty_pct} %
CH${selectedChannel} OUTPUT ${a.output_on ? "ON" : "OFF"}`;
  drawAFGPreview(a);
}

function drawAFGPreview(a) {
  const c = $("afgPreview");
  const ctx = c.getContext("2d");
  ctx.clearRect(0,0,c.width,c.height);
  ctx.fillStyle = "#03130e";
  ctx.fillRect(0,0,c.width,c.height);
  ctx.strokeStyle = "#173b2e";
  ctx.lineWidth = 1;
  for (let x=0;x<c.width;x+=50) { ctx.beginPath(); ctx.moveTo(x,0); ctx.lineTo(x,c.height); ctx.stroke(); }
  for (let y=0;y<c.height;y+=35) { ctx.beginPath(); ctx.moveTo(0,y); ctx.lineTo(c.width,y); ctx.stroke(); }

  ctx.strokeStyle = "#55ffad";
  ctx.lineWidth = 2;
  ctx.beginPath();
  for (let i=0;i<c.width;i++) {
    const p = 2*i/c.width;
    const phase = 2*Math.PI*p + a.phase_deg*Math.PI/180;
    let y;
    if (a.waveform === "Sine") y = Math.sin(phase);
    else if (a.waveform === "Square") {
      const frac = ((phase/(2*Math.PI))%1 + 1)%1;
      y = frac < a.duty_pct/100 ? 1 : -1;
    } else if (a.waveform === "Triangle") {
      const frac = ((phase/(2*Math.PI))%1 + 1)%1;
      y = 4*Math.abs(frac-.5)-1;
    } else {
      const frac = ((phase/(2*Math.PI))%1 + 1)%1;
      y = 2*frac-1;
    }
    const py = c.height/2 - y*(c.height*.32);
    if (i===0) ctx.moveTo(i,py); else ctx.lineTo(i,py);
  }
  ctx.stroke();
}

async function refreshScope() {
  const body = collectState();
  const [ch1, ch2] = await Promise.all([
    api("/api/scope/1/trace?samples=2200", { method: "POST", body }),
    api("/api/scope/2/trace?samples=2200", { method: "POST", body })
  ]);
  drawScope(ch1, ch2);
}

function drawScope(ch1, ch2) {
  const c = $("scopeCanvas");
  const ctx = c.getContext("2d");
  const W = c.width, H = c.height;
  ctx.fillStyle = "#050505";
  ctx.fillRect(0,0,W,H);

  ctx.strokeStyle = "#2b2b2b";
  ctx.lineWidth = 1;
  for (let i=0;i<=10;i++) {
    const x = i*W/10;
    ctx.beginPath(); ctx.moveTo(x,0); ctx.lineTo(x,H); ctx.stroke();
  }
  for (let j=0;j<=8;j++) {
    const y = j*H/8;
    ctx.beginPath(); ctx.moveTo(0,y); ctx.lineTo(W,y); ctx.stroke();
  }
  ctx.strokeStyle = "#4a4a4a";
  ctx.beginPath(); ctx.moveTo(0,H/2); ctx.lineTo(W,H/2); ctx.stroke();

  function trace(data, settings, color) {
    if (!settings.enabled || !data.volts.length) return;
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.beginPath();
    data.volts.forEach((v, i) => {
      const x = i*(W/(data.volts.length-1));
      const div = v/settings.volts_div + settings.position_div;
      const y = H/2 - div*(H/8);
      if (i===0) ctx.moveTo(x,y); else ctx.lineTo(x,y);
    });
    ctx.stroke();
  }

  trace(ch1, state.scope.ch1, "#f4d500");
  trace(ch2, state.scope.ch2, "#00e3f0");

  ctx.font = "bold 16px Arial";
  ctx.fillStyle = "#f4d500";
  ctx.fillText(`CH1  ${state.scope.ch1.volts_div} V/div  ${state.scope.ch1.coupling}`, 12, 24);
  ctx.fillStyle = "#00e3f0";
  ctx.fillText(`CH2  ${state.scope.ch2.volts_div} V/div  ${state.scope.ch2.coupling}`, 12, 48);

  const selected = selectedChannel === 1 ? ch1 : ch2;
  $("scopeMetrics").textContent =
`AFG CH${selectedChannel} → GDS CH${selectedChannel}
Frequency: ${selected.frequency_hz.toFixed(4)} Hz
Vpp: ${selected.vpp_v.toFixed(6)} V
RMS: ${selected.rms_v.toFixed(6)} V`;
}

$("autosetBtn").addEventListener("click", async () => {
  saveAFGFormToState();
  const a = selectedAfgState();
  const f = Math.max(a.frequency_hz, 1);
  state.scope.time_div_s = 0.4/f;
  const vpp = Math.max(a.amplitude_vpp, 0.01);
  const vdiv = Math.max(vpp/5, 0.002);

  if (selectedChannel === 1) {
    state.scope.ch1.volts_div = vdiv;
    state.scope.ch1.enabled = true;
    state.scope.ch2.enabled = false;
  } else {
    state.scope.ch2.volts_div = vdiv;
    state.scope.ch2.enabled = true;
    state.scope.ch1.enabled = false;
  }
  syncScopeFormFromState();
  await refreshAll();
});

$("verifyBtn").addEventListener("click", async () => {
  const body = collectState();
  const r = await api(`/api/verify/${selectedChannel}`, { method: "POST", body });
  $("verifyBox").textContent =
`${r.passed ? "PASS" : "FAIL"} — ${r.mode}
Channel: CH${r.channel}

Frequency
Expected: ${r.expected_frequency_hz.toFixed(6)} Hz
Measured: ${r.measured_frequency_hz.toFixed(6)} Hz
Error: ${r.frequency_error_pct.toFixed(4)} %

Amplitude
Expected: ${r.expected_vpp_v.toFixed(6)} Vpp
Measured: ${r.measured_vpp_v.toFixed(6)} Vpp
Error: ${r.amplitude_error_pct.toFixed(4)} %`;
});

$("experimentSelect").addEventListener("change", async () => {
  updateExperimentUI();
  await refreshAll();
});

[
  "waveform","frequency","amplitude","offset","phase","duty"
].forEach(id => $(id).addEventListener("change", async () => {
  await refreshAll();
  if ($("executionMode").value === "verified" && gatewayOnline) {
    await sendTwinStateToHardware("apply_state");
  }
}));

[
  "dutType","dutR","dutC","displayMode","timeDiv",
  "ch1Vdiv","ch1Pos","ch1Coupling","ch1Probe",
  "ch2Vdiv","ch2Pos","ch2Coupling","ch2Probe"
].forEach(id => $(id).addEventListener("change", refreshAll));


$("dutType").addEventListener("change", () => {
  if ($("dutType").value === "Loopback") $("experimentSelect").value = "loopback";
  else if ($("dutType").value === "RC Low-pass") $("experimentSelect").value = "rc-lowpass";
  else if ($("dutType").value === "RC High-pass") $("experimentSelect").value = "rc-highpass";
  $("experimentObjective").textContent = EXPERIMENTS[$("experimentSelect").value].objective;
  $("theoryBox").textContent = theoreticalSummary();
});


// ===== Phase 2 verified-hardware workflow =====
function applyPhysicalAfgStateToTwin(hw) {
  if (!hw) return;
  const target = selectedChannel === 1 ? hw.afg_ch1 : hw.afg_ch2;
  if (!target) return;
  const a = selectedAfgState();
  if (target.waveform) {
    a.waveform = target.waveform;
  }
  if (Number.isFinite(Number(target.frequency_hz))) {
    a.frequency_hz = Number(target.frequency_hz);
  }
  if (Number.isFinite(Number(target.amplitude_vpp))) {
    a.amplitude_vpp = Number(target.amplitude_vpp);
  }
  if (Number.isFinite(Number(target.offset_v))) {
    a.offset_v = Number(target.offset_v);
  }
  if (Number.isFinite(Number(target.phase_deg))) {
    a.phase_deg = Number(target.phase_deg);
  }

  if (Number.isFinite(Number(target.duty_pct))) {
    a.duty_pct = Number(target.duty_pct);
  }

  if (typeof target.output_on === "boolean") {
    a.output_on = target.output_on;
  }

  outputOn = a.output_on;

  // Real AFG -> Virtual Twin display
  loadSelectedChannelIntoForm();
  updateAFGDisplay();
  $("theoryBox").textContent = theoreticalSummary();

  // Refresh virtual oscilloscope
  refreshScope().catch(err => {
    console.warn("Auto scope refresh failed:", err);
  });
}
async function refreshGatewayStatus() {
  const badge = $("gatewayBadge");
  try {
    const s = await api("/api/hardware/status");
    gatewayOnline = Boolean(s.online);
    if (gatewayOnline) {
      badge.textContent = `Hardware gateway: ONLINE (${s.gateway_id || "lab"})`;
      badge.classList.add("gateway-online");
      badge.classList.remove("gateway-offline");

      // In Verified Hardware mode, the physical AFG is authoritative.
      // Manual front-panel changes therefore flow AFG -> Cloud -> Twin.
      if ($("executionMode").value === "verified") {
        applyPhysicalAfgStateToTwin(s);
      }
    } else {
      badge.textContent = "Hardware gateway: OFFLINE / not connected";
      badge.classList.add("gateway-offline");
      badge.classList.remove("gateway-online");
    }
  } catch (e) {
    gatewayOnline = false;
    badge.textContent = "Hardware gateway: connection unavailable";
    badge.classList.add("gateway-offline");
    badge.classList.remove("gateway-online");
  }
  updateHardwareButtonState();
}

function updateHardwareButtonState() {
  const verifiedMode = $("executionMode").value === "verified";
  const directExperiment = state.dut.type === "Loopback";
  $("hardwareVerifyBtn").disabled = !(verifiedMode && directExperiment && gatewayOnline);
}

$("executionMode").addEventListener("change", () => {
  updateHardwareButtonState();
  if ($("executionMode").value === "verified" && state.dut.type !== "Loopback") {
    $("hardwareVerifyBox").textContent =
      "Verified hardware currently supports Experiment 1 (Direct AFG → GDS) only. Select Experiment 1.";
  }
});

$("experimentSelect").addEventListener("change", updateHardwareButtonState);
$("dutType").addEventListener("change", updateHardwareButtonState);

function formatHardwareResult(job) {
  const r = job.result || {};
  const vf = Number(job.virtual_expected_frequency_hz);
  const vv = Number(job.virtual_expected_vpp_v);
  const hf = Number(r.measured_frequency_hz);
  const hv = Number(r.measured_vpp_v);
  const pf = Number(r.frequency_error_pct);
  const pa = Number(r.amplitude_error_pct);
  const passed = job.status === "done" && Number.isFinite(pf) && Number.isFinite(pa) && pf <= 2 && pa <= 10;

  return `${passed ? "PASS" : "FAIL"} — VERIFIED DIGITAL TWIN
Channel: CH${job.channel}

Virtual Twin Reference
Frequency: ${Number.isFinite(vf) ? vf.toFixed(6) : "--"} Hz
Vpp: ${Number.isFinite(vv) ? vv.toFixed(6) : "--"} Vpp

Real Hardware Measurement
Frequency: ${Number.isFinite(hf) ? hf.toFixed(6) : "--"} Hz
Vpp: ${Number.isFinite(hv) ? hv.toFixed(6) : "--"} Vpp

Physical Fidelity Error
Frequency error: ${Number.isFinite(pf) ? pf.toFixed(4) : "--"} %
Amplitude error: ${Number.isFinite(pa) ? pa.toFixed(4) : "--"} %

AFG: ${r.afg_idn || "--"}
GDS: ${r.gds_idn || "--"}
AFG load: ${r.load_text || "--"}`;
}

async function pollHardwareJob(jobId) {
  const box = $("hardwareVerifyBox");
  for (let i = 0; i < 60; i++) {
    const job = await api(`/api/hardware/jobs/${jobId}`);
    if (job.status === "done" || job.status === "failed") {
      box.textContent = formatHardwareResult(job);
      box.classList.toggle("hardware-result-pass", job.status === "done");
      box.classList.toggle("hardware-result-fail", job.status !== "done");
      return;
    }
    box.textContent = `Hardware job ${job.status.toUpperCase()}... waiting for university lab gateway (${i+1}s)`;
    await new Promise(resolve => setTimeout(resolve, 1500));
  }
  box.textContent = "Hardware verification timed out. Check the MATLAB gateway and physical instruments.";
  box.classList.add("hardware-result-fail");
}

$("hardwareVerifyBtn").addEventListener("click", async () => {
  const box = $("hardwareVerifyBox");
  collectState();
  if (state.dut.type !== "Loopback") {
    box.textContent = "Select Experiment 1 — Direct AFG → GDS for physical verification.";
    return;
  }
  if (!selectedAfgState().output_on) {
    box.textContent = "Turn the selected AFG output ON before physical verification.";
    return;
  }
  box.classList.remove("hardware-result-pass", "hardware-result-fail");
  box.textContent = "Creating verified-hardware job...";
  try {
    const job = await api("/api/hardware/jobs", {
      method: "POST",
      body: {
        student_id: studentId,
        student_name: studentName,
        session_id: sessionId,
        channel: selectedChannel,
        state,
        action: "apply_and_measure"
      }
    });
    box.textContent = `Hardware job queued: ${job.id}`;
    await pollHardwareJob(job.id);
  } catch (e) {
    box.textContent = `Hardware verification could not start: ${e.message}`;
    box.classList.add("hardware-result-fail");
  }
});

setInterval(refreshGatewayStatus, 5000);
window.addEventListener("load", refreshGatewayStatus);
