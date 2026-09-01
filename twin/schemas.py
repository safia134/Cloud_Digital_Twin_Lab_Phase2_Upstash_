from typing import Literal, Optional
from pydantic import BaseModel, Field

Waveform = Literal["Sine", "Square", "Triangle", "Sawtooth"]
Coupling = Literal["DC", "AC", "GND"]
DUTType = Literal["Loopback", "RC Low-pass", "RC High-pass"]

class LoginRequest(BaseModel):
    student_id: str = Field(min_length=1, max_length=64)
    name: str = Field(min_length=1, max_length=120)

class LoginResponse(BaseModel):
    session_id: str
    student_id: str
    name: str

class AFGChannelSettings(BaseModel):
    waveform: Waveform = "Sine"
    frequency_hz: float = Field(default=1000.0, gt=0, le=20_000_000)
    amplitude_vpp: float = Field(default=2.0, ge=0, le=20)
    offset_v: float = Field(default=0.0, ge=-10, le=10)
    phase_deg: float = Field(default=0.0, ge=-360, le=360)
    duty_pct: float = Field(default=50.0, ge=1, le=99)
    output_on: bool = True

class ScopeChannelSettings(BaseModel):
    enabled: bool = True
    volts_div: float = Field(default=1.0, gt=0, le=100)
    position_div: float = Field(default=0.0, ge=-8, le=8)
    coupling: Coupling = "DC"
    probe_x: Literal[1, 10] = 1

class ScopeSettings(BaseModel):
    time_div_s: float = Field(default=0.0005, gt=0, le=10)
    trigger_level_v: float = Field(default=0.0, ge=-100, le=100)
    trigger_edge: Literal["Rising", "Falling"] = "Rising"
    ch1: ScopeChannelSettings = ScopeChannelSettings(position_div=1.0)
    ch2: ScopeChannelSettings = ScopeChannelSettings(position_div=-1.0)

class DUTSettings(BaseModel):
    type: DUTType = "Loopback"
    resistance_ohm: float = Field(default=1000.0, gt=0, le=1e9)
    capacitance_f: float = Field(default=1e-6, gt=0, le=1)

class LabState(BaseModel):
    selected_afg_channel: Literal[1, 2] = 1
    afg_ch1: AFGChannelSettings = AFGChannelSettings()
    afg_ch2: AFGChannelSettings = AFGChannelSettings(frequency_hz=1000, amplitude_vpp=1.0)
    scope: ScopeSettings = ScopeSettings()
    dut: DUTSettings = DUTSettings()

class TraceResponse(BaseModel):
    channel: int
    time_s: list[float]
    volts: list[float]
    frequency_hz: float
    vpp_v: float
    rms_v: float

class VerifyResponse(BaseModel):
    channel: int
    expected_frequency_hz: float
    measured_frequency_hz: float
    frequency_error_pct: float
    expected_vpp_v: float
    measured_vpp_v: float
    amplitude_error_pct: float
    passed: bool
    mode: str = "Virtual Twin Lab"
