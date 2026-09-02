function MATLAB_Hardware_Gateway_Bidirectional_v2(baseUrl, gatewayId, gatewayKey)
% MATLAB_Hardware_Gateway  Cloud Digital Twin Lab Phase-2 hardware worker.
%
% Run this on the UNIVERSITY LAB PC only. The PC must be connected by USB to:
%   GW Instek AFG-2225
%   GW Instek GDS-1102B
% and the analogue signal path must be:
%   AFG CH1 BNC -> GDS CH1, AFG CH2 BNC -> GDS CH2.
%
% Example:
%   MATLAB_Hardware_Gateway( ...
%       "https://cloud-digital-twin-lab-vercel.vercel.app", ...
%       "quest-lab-01", ...
%       "paste-the-same-GATEWAY_SHARED_KEY-used-in-Vercel")
%
% This worker polls the cloud OUTBOUND. No inbound firewall port is opened.
% Browser clients never send raw SCPI. They send validated LabState objects;
% this gateway alone translates them to SCPI.
%
% Source driver design is adapted from the user's working AFG-2225/GDS-1102B
% Digital Twin: raw-byte ASCII queries, automatic AFG REMOTE->LOCAL restoration,
% GDS PK2Pk measurements, robust frequency fallbacks and binary waveform capture.

arguments
    baseUrl (1,1) string
    gatewayId (1,1) string
    gatewayKey (1,1) string
end

baseUrl = strip(baseUrl,"right","/");
gatewayId = regexprep(gatewayId,'[^A-Za-z0-9_.-]','_');
if strlength(gatewayKey) < 16
    error('Gateway key is too short. Use a long random GATEWAY_SHARED_KEY.');
end

fprintf('\n=== CLOUD DIGITAL TWIN MATLAB HARDWARE GATEWAY ===\n');
fprintf('Cloud   : %s\n',baseUrl);
fprintf('Gateway : %s\n',gatewayId);
fprintf('Press Ctrl+C to stop. Fail-safe shutdown turns both AFG outputs OFF.\n\n');

[afg, afgPort, afgIdn] = connectInstrument("AFG-2225", "COM3");
[gds, gdsPort, gdsIdn] = connectInstrument("GDS-1102B", "COM4");
cleanupObj = onCleanup(@()safeShutdown(afg)); %#ok<NASGU>

fprintf('AFG: %s on %s\n',afgIdn,afgPort);
fprintf('GDS: %s on %s\n',gdsIdn,gdsPort);

sendHeartbeat("online");
lastHeartbeat = tic;

while true
    if toc(lastHeartbeat) >= 5
        sendHeartbeat("online");
        lastHeartbeat = tic;
    end

    try
        opts = gatewayWebOptions();
        nextUrl = sprintf('%s/api/gateway/jobs/next?gateway_id=%s',baseUrl,gatewayId);
        resp = webread(nextUrl, opts);
        if ~isfield(resp,'job') || isempty(resp.job)
            pause(1.5);
            continue;
        end

        job = resp.job;
        fprintf('\n[%s] Claimed hardware job %s (CH%d, %s)\n', ...
            datestr(now,'HH:MM:SS'), string(job.id), double(job.channel), string(job.action));

        try
            result = executeJob(job);
            result.status = 'done';
            result.error_message = '';
        catch ME
            fprintf(2,'JOB FAILED: %s\n',ME.message);
            try, outputOff(afg,1); catch, end
            try, outputOff(afg,2); catch, end
            try, restoreAfgLocal(afg); catch, end
            result = baseResult();
            result.status = 'failed';
            result.error_message = getReport(ME,'extended','hyperlinks','off');
        end

        result.gateway_id = char(gatewayId);
        submitUrl = sprintf('%s/api/gateway/jobs/%s/result',baseUrl,string(job.id));
        webwrite(submitUrl, result, gatewayWebOptions());
        fprintf('Result returned to cloud.\n');

    catch ME
        fprintf(2,'Gateway loop warning: %s\n',ME.message);
        pause(3.0);
    end
end

    function opts = gatewayWebOptions()
        opts = weboptions( ...
            'ContentType','json', ...
            'MediaType','application/json', ...
            'Timeout',12, ...
            'HeaderFields',{'X-Gateway-Key',char(gatewayKey)});
    end

    function sendHeartbeat(statusText)
        % Read the physical generator so front-panel changes can flow
        % AFG -> Cloud -> Browser Twin. Some serial queries place the AFG
        % in REMOTE. Always restore LOCAL after the snapshot so the front
        % panel remains usable for hardware -> twin changes.
        try, enterAfgRemote(afg); catch, end
        localCleanup = onCleanup(@()restoreAfgLocal(afg)); %#ok<NASGU>
        liveCh1 = readAfgChannelState(afg,1);
        liveCh2 = readAfgChannelState(afg,2);

        hb = struct( ...
            'gateway_id',char(gatewayId), ...
            'status',char(statusText), ...
            'afg_idn',char(afgIdn), ...
            'gds_idn',char(gdsIdn), ...
            'afg_port',char(afgPort), ...
            'gds_port',char(gdsPort), ...
            'version','phase2-bidir-1.0', ...
            'afg_ch1',liveCh1, ...
            'afg_ch2',liveCh2);
        try
            webwrite(baseUrl + "/api/gateway/heartbeat", hb, gatewayWebOptions());
        catch ME
            fprintf(2,'Heartbeat warning: %s\n',ME.message);
        end
        try, restoreAfgLocal(afg); catch, end
    end

    function result = executeJob(job)
        if ~isfield(job,'state')
            error('Job is missing LabState.');
        end
        state = job.state;
        ch = double(job.channel);
        if ~ismember(ch,[1 2])
            error('Invalid channel.');
        end
        if isfield(state,'dut') && isfield(state.dut,'type') && ~strcmpi(string(state.dut.type),'Loopback')
            error('Verified hardware Phase 2 currently supports Loopback/direct BNC only.');
        end

        if strcmpi(string(job.action),'output_off')
            outputOff(afg,ch);
            restoreAfgLocal(afg);
            result = baseResult();
            result.hardware_connected = true;
            return;
        end

        if ch == 1
            a = state.afg_ch1;
            s = state.scope.ch1;
        else
            a = state.afg_ch2;
            s = state.scope.ch2;
        end

        validateSafety(a);
        enterAfgRemote(afg);
        remoteCleanup = onCleanup(@()restoreAfgLocal(afg)); %#ok<NASGU>
        outputCleanup = onCleanup(@()outputOff(afg,ch)); %#ok<NASGU>

        configureAfg(afg,ch,a);
        configureGds(gds,ch,state.scope,s);
        pause(0.45);

        fConfigured = str2double(queryAfg(afg,sprintf('SOURCE%d:FREQUENCY?',ch)));
        ampReadback = str2double(queryAfg(afg,sprintf('SOURCE%d:AMPLITUDE?',ch)));
        ampUnit = upper(strtrim(queryAfg(afg,sprintf('SOURCE%d:VOLTAGE:UNIT?',ch))));
        if ~contains(ampUnit,'VPP')
            error('Gateway expects AFG readback in VPP but received %s.',ampUnit);
        end

        % In this gateway we explicitly force OUTPUTn:LOAD to INF/HIGH-Z,
        % therefore AFG VPP readback and the voltage expected at the high-Z
        % GDS input use the same Vpp quantity.
        ampConfigured = double(a.amplitude_vpp);
        expectedVpp = ampReadback;
        try
            loadText = upper(strtrim(queryAfg(afg,sprintf('OUTPUT%d:LOAD?',ch))));
        catch
            loadText = 'UNKNOWN';
        end

        [fMeasured,fMethod] = queryGdsFrequencyRobust(gds,ch);
        vppMeasured = NaN;
        for measTry = 1:3
            vppMeasured = queryGdsMeasurement(gds,ch,'PK2Pk');
            if isfinite(vppMeasured) && vppMeasured > 0.001
                break;
            end
            pause(0.20);
        end

        [traceT,traceV] = captureGdsWaveform(gds,ch,1000);
        if ~isfinite(fMeasured) && ~isempty(traceT)
            fMeasured = estimateFrequencyFFT(traceT,traceV);
            fMethod = 'waveform-FFT';
        end

        % GDS-1102B v1.29 may intermittently return '?' for PK2Pk.
        % If so, derive Vpp from the captured waveform instead of failing.
        if ~isfinite(vppMeasured) && ~isempty(traceV)
            vppMeasured = max(traceV) - min(traceV);
        end

        freqErr = NaN;
        ampErr = NaN;
        if isfinite(fConfigured) && fConfigured > 0 && isfinite(fMeasured)
            freqErr = 100*abs(fMeasured-fConfigured)/fConfigured;
        end
        if isfinite(expectedVpp) && expectedVpp > 0 && isfinite(vppMeasured)
            ampErr = 100*abs(vppMeasured-expectedVpp)/expectedVpp;
        end

        result = baseResult();
        result.hardware_connected = true;
        result.configured_frequency_hz = finiteOrEmpty(fConfigured);
        result.configured_vpp_v = finiteOrEmpty(ampConfigured);
        result.afg_readback_vpp_v = finiteOrEmpty(ampReadback);
        result.expected_hardware_vpp_v = finiteOrEmpty(expectedVpp);
        result.measured_frequency_hz = finiteOrEmpty(fMeasured);
        result.measured_vpp_v = finiteOrEmpty(vppMeasured);
        result.frequency_error_pct = finiteOrEmpty(freqErr);
        result.amplitude_error_pct = finiteOrEmpty(ampErr);
        result.load_text = char(loadText);
        result.frequency_method = char(fMethod);
        result.trace_time_s = downsampleVector(traceT,1000);
        result.trace_volts = downsampleVector(traceV,1000);

        fprintf('CH%d: f %.9g -> %.9g Hz (%.3g%%), Vpp requested %.9g, AFG readback %.9g, measured %.9g (%.3g%%)\n', ...
            ch,fConfigured,fMeasured,freqErr,ampConfigured,ampReadback,vppMeasured,ampErr);
    end

    function r = baseResult()
        r = struct( ...
            'gateway_id',char(gatewayId), ...
            'status','failed', ...
            'hardware_connected',false, ...
            'afg_idn',char(afgIdn), ...
            'gds_idn',char(gdsIdn), ...
            'afg_port',char(afgPort), ...
            'gds_port',char(gdsPort), ...
            'configured_frequency_hz',[], ...
            'configured_vpp_v',[], ...
            'afg_readback_vpp_v',[], ...
            'expected_hardware_vpp_v',[], ...
            'measured_frequency_hz',[], ...
            'measured_vpp_v',[], ...
            'frequency_error_pct',[], ...
            'amplitude_error_pct',[], ...
            'load_text','', ...
            'frequency_method','', ...
            'trace_time_s',[], ...
            'trace_volts',[], ...
            'error_message','');
    end
end


% ============================ Device helpers =============================

function [obj,portName,idn] = connectInstrument(modelName,preferredPort)
ports = string(serialportlist("available"));
if isempty(ports)
    error('No available serial ports.');
end
if any(strcmpi(ports,preferredPort))
    ports = [string(preferredPort), ports(~strcmpi(ports,preferredPort))];
end
obj = [];
portName = "";
idn = "";
for p = ports
    candidate = [];
    try
        candidate = serialport(p,9600,'Timeout',1.5);
        candidate.DataBits = 8;
        candidate.StopBits = 1;
        candidate.Parity = 'none';
        candidate.FlowControl = 'none';
        configureTerminator(candidate,'LF');
        pause(0.25);
        flush(candidate);
        id = rawAsciiQuery(candidate,'*IDN?',1.5);
        fprintf('%s -> %s\n',p,id);
        if contains(id,modelName,'IgnoreCase',true)
            obj = candidate;
            portName = p;
            idn = string(id);
            return;
        end
        clear candidate
    catch ME
        fprintf(2,'%s discovery on %s: %s\n',modelName,p,ME.message);
        candidate = []; %#ok<NASGU>
    end
end
error('%s was not found on any available serial port.',modelName);
end

function response = rawAsciiQuery(obj,commandText,timeoutSeconds)
if nargin < 3, timeoutSeconds = 1.2; end
if obj.NumBytesAvailable > 0, flush(obj,'input'); end
writeline(obj,commandText);
raw = '';
t0 = tic;
while toc(t0) < timeoutSeconds
    n = obj.NumBytesAvailable;
    if n > 0
        raw = [raw, read(obj,n,'char')]; %#ok<AGROW>
        if contains(raw,newline) || contains(raw,char(13)), break; end
    end
    pause(0.02);
end
response = strtrim(raw);
if isempty(response)
    error('No reply to "%s".',commandText);
end
end

function response = queryAfg(afg,commandText)
last = [];
for k=1:2
    try
        response = rawAsciiQuery(afg,commandText,1.2);
        fprintf('AFG RX: %s\n',response);
        return;
    catch ME
        last = ME; pause(0.1);
    end
end
error('AFG query failed: %s',last.message);
end

function writeAfg(afg,commandText)
if afg.NumBytesAvailable > 0, flush(afg,'input'); end
fprintf('AFG TX: %s\n',commandText);
writeline(afg,commandText);
pause(0.12);
end

function enterAfgRemote(afg)
writeline(afg,'SYSTEM:REMOTE'); pause(0.12);
end

function restoreAfgLocal(afg)
try, writeline(afg,'SYSTEM:LOCAL'); pause(0.12); catch, end
end

function outputOff(afg,ch)
try, writeAfg(afg,sprintf('OUTPUT%d OFF',ch)); catch, end
end

function s = readAfgChannelState(afg,ch)
% Read current physical AFG state. This is used only for heartbeat sync.
s = struct( ...
    'waveform','Sine', ...
    'frequency_hz',[], ...
    'amplitude_vpp',[], ...
    'offset_v',[], ...
    'phase_deg',[], ...
    'duty_pct',50, ...
    'output_on',false);

src = sprintf('SOURCE%d',ch);
outp = sprintf('OUTPUT%d',ch);

try
    f = str2double(queryAfg(afg,sprintf('%s:FREQUENCY?',src)));
    if isfinite(f), s.frequency_hz = f; end
catch
end

try
    a = str2double(queryAfg(afg,sprintf('%s:AMPLITUDE?',src)));
    if isfinite(a), s.amplitude_vpp = a; end
catch
end

try
    o = str2double(queryAfg(afg,sprintf('%s:DCOFFSET?',src)));
    if isfinite(o), s.offset_v = o; end
catch
end

try
    p = str2double(queryAfg(afg,sprintf('%s:PHASE?',src)));
    if isfinite(p), s.phase_deg = p; end
catch
end

try
    fn = upper(strtrim(queryAfg(afg,sprintf('%s:FUNCTION?',src))));
    if contains(fn,'SIN')
        s.waveform = 'Sine';
    elseif contains(fn,'SQU')
        s.waveform = 'Square';
        try
            d = str2double(queryAfg(afg,sprintf('%s:SQUARE:DCYCLE?',src)));
            if isfinite(d), s.duty_pct = d; end
        catch
        end
    elseif contains(fn,'RAMP')
        sym = NaN;
        try
            sym = str2double(queryAfg(afg,sprintf('%s:RAMP:SYMMETRY?',src)));
        catch
        end
        if isfinite(sym) && sym > 75
            s.waveform = 'Sawtooth';
        else
            s.waveform = 'Triangle';
        end
    end
catch
end

try
    outText = strtrim(queryAfg(afg,sprintf('%s?',outp)));
    outNum = str2double(outText);
    if isfinite(outNum)
        s.output_on = outNum ~= 0;
    else
        s.output_on = strcmpi(outText,'ON');
    end
catch
end
end

function safeShutdown(afg)
if isempty(afg), return; end
try, outputOff(afg,1); catch, end
try, outputOff(afg,2); catch, end
try, restoreAfgLocal(afg); catch, end
fprintf('Gateway shutdown: AFG CH1/CH2 OFF, front panel LOCAL.\n');
end

function validateSafety(a)
f = double(a.frequency_hz);
vpp = double(a.amplitude_vpp);
offset = double(a.offset_v);
phase = double(a.phase_deg);
duty = double(a.duty_pct);
if ~isfinite(f) || f < 1 || f > 10000
    error('Phase-2 verified mode safety limit: frequency must be 1..10000 Hz.');
end
if ~isfinite(vpp) || vpp < 0.001 || vpp > 10
    error('Phase-2 verified mode safety limit: amplitude must be 0.001..10 Vpp.');
end
if ~isfinite(offset) || abs(offset) > 5
    error('Phase-2 verified mode safety limit: |offset| must be <= 5 V.');
end
if abs(offset) + vpp/2 > 5
    error('Safety envelope exceeded: |offset| + Vpp/2 must be <= 5 V.');
end
if ~isfinite(phase) || abs(phase) > 180
    error('Phase must be within -180..180 degrees.');
end
if ~isfinite(duty) || duty < 1 || duty > 99
    error('Duty must be within 1..99%%.');
end
end

function configureAfg(afg,ch,a)
src = sprintf('SOURCE%d',ch);
wave = char(string(a.waveform));
switch lower(wave)
    case 'sine', scpi='SIN';
    case 'square', scpi='SQU';
    case {'triangle','sawtooth'}, scpi='RAMP';
    otherwise, error('Unsupported waveform: %s',wave);
end

% Put the generator in a deterministic voltage-reference mode.
% The GDS input is high impedance, so make the AFG amplitude itself be
% referenced to HIGH-Z rather than leaving the instrument at DEF(50 ohm).
try
    writeAfg(afg,sprintf('OUTPUT%d:LOAD INF',ch));
    pause(0.12);
catch
    % Some firmware may reject INF spelling; HIGHZ is attempted below.
    try
        writeAfg(afg,sprintf('OUTPUT%d:LOAD HIGHZ',ch));
        pause(0.12);
    catch
    end
end

writeAfg(afg,sprintf('%s:FUNCTION %s',src,scpi));
if strcmpi(wave,'Square')
    writeAfg(afg,sprintf('%s:SQUARE:DCYCLE %.12g',src,double(a.duty_pct)));
elseif strcmpi(wave,'Triangle')
    writeAfg(afg,sprintf('%s:RAMP:SYMMETRY 50',src));
elseif strcmpi(wave,'Sawtooth')
    writeAfg(afg,sprintf('%s:RAMP:SYMMETRY 100',src));
end

writeAfg(afg,sprintf('%s:FREQUENCY %.12g',src,double(a.frequency_hz)));
writeAfg(afg,sprintf('%s:VOLTAGE:UNIT VPP',src));

requestedVpp = double(a.amplitude_vpp);

% First try the documented full keyword.
writeAfg(afg,sprintf('%s:AMPLITUDE %.12g',src,requestedVpp));
pause(0.18);
readbackVpp = str2double(queryAfg(afg,sprintf('%s:AMPLITUDE?',src)));

% If firmware did not commit it, retry with valid short form AMP.
tol = max(1e-3,0.005*max(abs(requestedVpp),1));
if ~isfinite(readbackVpp) || abs(readbackVpp-requestedVpp) > tol
    fprintf(2,'AFG amplitude retry: requested %.9g Vpp, readback %.9g Vpp
', ...
        requestedVpp,readbackVpp);
    writeAfg(afg,sprintf('%s:AMP %.12g',src,requestedVpp));
    pause(0.20);
    readbackVpp = str2double(queryAfg(afg,sprintf('%s:AMPLITUDE?',src)));
end

if ~isfinite(readbackVpp) || abs(readbackVpp-requestedVpp) > tol
    error(['AFG-2225 did not accept requested amplitude. Requested %.9g Vpp, ' ...
           'readback %.9g Vpp. Physical verification aborted.'], ...
           requestedVpp,readbackVpp);
end

% Avoid selecting/activating the AFG OFFSET front-panel parameter when
% the requested offset is exactly zero. Non-zero offsets are still applied.
if abs(double(a.offset_v)) > 1e-12
    writeAfg(afg,sprintf('%s:DCOFFSET %.12g',src,double(a.offset_v)));
end
writeAfg(afg,sprintf('%s:PHASE %.12g',src,double(a.phase_deg)));

if logical(a.output_on)
    writeAfg(afg,sprintf('OUTPUT%d ON',ch));
else
    writeAfg(afg,sprintf('OUTPUT%d OFF',ch));
end
pause(0.20);
end

function configureGds(gds,ch,scope,s)
writeGds(gds,sprintf(':CHANnel%d:DISPlay ON',ch));
writeGds(gds,sprintf(':CHANnel%d:COUPling %s',ch,upper(char(string(s.coupling)))));
writeGds(gds,sprintf(':CHANnel%d:PROBe:RATio %.12g',ch,double(s.probe_x)));
writeGds(gds,sprintf(':CHANnel%d:SCALe %.12g',ch,max(double(s.volts_div),0.002)));
writeGds(gds,sprintf(':CHANnel%d:POSition %.12g',ch,double(s.position_div)*max(double(s.volts_div),0.002)));
writeGds(gds,sprintf(':TIMebase:SCALe %.12g',max(double(scope.time_div_s),5e-9)));
writeGds(gds,':TRIGger:TYPe EDGE');
writeGds(gds,sprintf(':TRIGger:EDGe:SOURce CH%d',ch));
writeGds(gds,sprintf(':TRIGger:LEVel %.12g',double(scope.trigger_level_v)));
if strcmpi(string(scope.trigger_edge),'Falling')
    writeGds(gds,':TRIGger:EDGe:SLOP FALL');
else
    writeGds(gds,':TRIGger:EDGe:SLOP RISE');
end
writeGds(gds,':RUN');
% Allow several acquisitions before asking for automatic measurements.
pause(0.55);
end

function response = queryGds(gds,commandText)
last=[];
for k=1:2
    try
        response=rawAsciiQuery(gds,commandText,1.2);
        fprintf('GDS RX: %s\n',response);
        return;
    catch ME
        last=ME; pause(0.1);
    end
end
error('GDS query failed: %s',last.message);
end

function writeGds(gds,commandText)
if gds.NumBytesAvailable > 0, flush(gds,'input'); end
fprintf('GDS TX: %s\n',commandText);
writeline(gds,commandText); pause(0.08);
end

function value = parseNumber(text)
s = strtrim(char(text));
tok = regexp(s,'[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?','match','once');
if isempty(tok), value=NaN; else, value=str2double(tok); end
end

function value = queryGdsMeasurement(gds,ch,measurement)
value=NaN;
try
    writeGds(gds,sprintf(':MEASure:SOURce1 CH%d',ch));
    pause(0.06);
    value=parseNumber(queryGds(gds,sprintf(':MEASure:%s?',measurement)));
catch
end
end

function [frequency,method] = queryGdsFrequencyRobust(gds,ch)
frequency=NaN; method='unresolved';
writeGds(gds,sprintf(':MEASure:SOURce1 CH%d',ch)); pause(0.05);
f=parseNumber(queryGds(gds,':MEASure:FREQuency?'));
if isfinite(f) && f>0, frequency=f; method='frequency'; return; end
p=parseNumber(queryGds(gds,':MEASure:PERiod?'));
if isfinite(p) && p>0, frequency=1/p; method='period-derived'; return; end
pw=parseNumber(queryGds(gds,':MEASure:PWIDth?'));
nw=parseNumber(queryGds(gds,':MEASure:NWIDth?'));
if isfinite(pw) && pw>0 && isfinite(nw) && nw>0
    frequency=1/(pw+nw); method='pulse-width-derived';
end
end

function [expectedVpp,loadText] = expectedHighZVpp(afg,ch,configuredVpp)
expectedVpp=NaN; loadText='';
try, loadText=upper(strtrim(queryAfg(afg,sprintf('OUTPUT%d:LOAD?',ch)))); catch, end
if contains(loadText,'INF') || contains(loadText,'HIGH')
    expectedVpp=configuredVpp; return;
end
if contains(loadText,'DEF')
    R=50; loadText='DEF(50OHM)';
else
    R=str2double(loadText);
end
if isfinite(R) && R>0
    expectedVpp=configuredVpp*(R+50)/R;
end
end

function [t,volts] = captureGdsWaveform(gds,ch,recordLength)
t=[]; volts=[];
oldLength=NaN;
try, oldLength=parseNumber(queryGds(gds,':ACQuire:RECOrdlength?')); catch, end
cleanup=onCleanup(@()restoreRecord(gds,oldLength)); %#ok<NASGU>
try
    writeGds(gds,':HEADer ON');
    writeGds(gds,sprintf(':ACQuire:RECOrdlength %d',recordLength));
    writeGds(gds,':RUN'); pause(0.2); writeGds(gds,':STOP');
    if ~waitDataReady(gds,ch,2), return; end
    if gds.NumBytesAvailable>0, flush(gds,'input'); end
    writeline(gds,sprintf(':ACQuire%d:MEMory?',ch));
    bytes=uint8([]); totalNeeded=inf; hashPos=NaN; dataStart=NaN; dataBytes=NaN; t0=tic;
    while toc(t0)<8
        n=gds.NumBytesAvailable;
        if n>0
            bytes=[bytes reshape(uint8(read(gds,n,'uint8')),1,[])]; %#ok<AGROW>
            if ~isfinite(hashPos)
                hpList=find(bytes==uint8('#'));
                for hp=hpList
                    if numel(bytes)<hp+1, continue; end
                    c=char(bytes(hp+1)); if c<'1'||c>'9', continue; end
                    nd=str2double(c); if numel(bytes)<hp+1+nd, continue; end
                    countText=char(bytes(hp+2:hp+1+nd));
                    if isempty(regexp(countText,'^\d+$','once')), continue; end
                    db=str2double(countText); if ~isfinite(db)||db<=0||db>500000, continue; end
                    hashPos=hp; dataBytes=db; dataStart=hp+2+nd; totalNeeded=dataStart+dataBytes-1; break;
                end
            end
            if isfinite(totalNeeded)&&numel(bytes)>=totalNeeded, break; end
        else
            pause(0.01);
        end
    end
    if ~isfinite(hashPos)||numel(bytes)<totalNeeded, return; end
    header=char(bytes(1:hashPos-1)); raw=bytes(dataStart:dataStart+dataBytes-1);
    if mod(numel(raw),2), raw=raw(1:end-1); end
    pairs=reshape(uint8(raw),2,[]);
    u16=uint16(pairs(1,:))*256+uint16(pairs(2,:));
    samples=double(typecast(uint16(u16),'int16'));
    st=regexpi(header,'Vertical\s*Scale\s*,\s*([0-9eE+\-.]+)','tokens','once');
    dtok=regexpi(header,'Sampling\s*Period\s*,\s*([0-9eE+\-.]+)','tokens','once');
    if isempty(st)||isempty(dtok), return; end
    scale=str2double(st{1}); dt=str2double(dtok{1});
    if ~isfinite(scale)||~isfinite(dt)||dt<=0, return; end
    volts=reshape((samples/25)*scale,1,[]);
    t=(0:numel(volts)-1)*dt;
catch ME
    fprintf(2,'Waveform capture warning: %s\n',ME.message);
    t=[]; volts=[];
end
end

function ready = waitDataReady(gds,ch,timeoutSeconds)
ready=false; t0=tic;
while toc(t0)<timeoutSeconds
    try
        x=parseNumber(queryGds(gds,sprintf(':ACQuire%d:STATe?',ch)));
        if isfinite(x)&&x~=0, ready=true; return; end
    catch
    end
    pause(0.05);
end
end

function restoreRecord(gds,oldLength)
try, if isfinite(oldLength)&&oldLength>=1000, writeline(gds,sprintf(':ACQuire:RECOrdlength %.12g',oldLength)); end, catch, end
try, writeline(gds,':RUN'); catch, end
end

function f = estimateFrequencyFFT(t,v)
f=NaN;
if isempty(t)||isempty(v)||numel(t)<32, return; end
n=min(numel(t),numel(v)); t=double(t(1:n)); v=double(v(1:n));
dt=median(diff(t)); if ~isfinite(dt)||dt<=0, return; end
x=v(:)-mean(v); if max(x)-min(x)<=0, return; end
N=numel(x); w=0.5-0.5*cos(2*pi*(0:N-1).'/(N-1));
nfft=2^nextpow2(max(4096,8*N)); X=abs(fft(x.*w,nfft)).^2;
P=X(1:floor(nfft/2)+1); P(1)=0; fs=1/dt;
freq=(0:numel(P)-1)'*fs/nfft; mask=freq>=1/max(t(end)-t(1),eps)&freq<=0.45*fs;
idx=find(mask); if isempty(idx), return; end
[~,k0]=max(P(idx)); k=idx(k0); f=freq(k);
end

function x = finiteOrEmpty(x)
if isempty(x) || ~isnumeric(x) || ~isscalar(x) || ~isfinite(x)
    x = [];
end
end

function y = downsampleVector(x,maxN)
if isempty(x), y=[]; return; end
x=double(x(:)).';
if numel(x)<=maxN, y=x; else, idx=round(linspace(1,numel(x),maxN)); y=x(idx); end
end