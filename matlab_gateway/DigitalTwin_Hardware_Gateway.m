function DigitalTwin_Hardware_Gateway()
% DIGITALTWIN_HARDWARE_GATEWAY
% Cloud hardware worker for GW Instek AFG-2225 + GDS-1102B.
%
% Browser/Vercel -> Upstash Redis -> this MATLAB gateway -> instruments.
%
% IMPORTANT:
% 1) Put your Upstash REST URL/token below OR set environment variables
%    KV_REST_API_URL and KV_REST_API_TOKEN before starting MATLAB.
% 2) Never put the token in GitHub/browser code.
% 3) AFG-2225 is expected on COM3; GDS-1102B on COM4 by default.
%
% Start:
%   DigitalTwin_Hardware_Gateway_v6_Fixed
%
% Stop:
%   Ctrl+C

clc;
fprintf('\n=== Cloud Digital Twin Hardware Gateway ===\n');

cfg.redisUrl   = "https://game-platypus-276859.upstash.io"; % Upstash REST URL
cfg.redisToken = "gQAAAAAABDl7AAIgcDJlMThmMjU2YzhhMzQ0ODZmYWZiMTZkZTVhNDJkMjAyMA"; % Upstash REST read/write token

cfg.gatewayId = "QUEST-DTL-GW-01";
cfg.afgPort    = "COM3";
cfg.scopePort  = "COM4";
cfg.afgBaud    = 9600;
cfg.scopeBaud  = 9600;
cfg.pollSeconds = 1.0;

% SECURITY:
% Never hard-code Redis credentials in this .m file and never commit them
% to GitHub. Configure them locally before starting MATLAB, for example:
%
%   setenv("KV_REST_API_TOKEN", "<your NEW rotated Upstash write token>");
%
% Because any token pasted into chat/source control should be considered
% compromised, rotate it first and use the replacement token here.



fprintf('Connecting instruments...\n');
afg = openInstrument(cfg.afgPort, cfg.afgBaud);
scope = openInstrument(cfg.scopePort, cfg.scopeBaud);
cleanupObj = onCleanup(@()cleanupGateway(afg,scope)); %#ok<NASGU>

idAfg = queryAscii(afg,"*IDN?");
idScope = queryAscii(scope,"*IDN?");
fprintf('AFG   : %s\n',idAfg);
fprintf('Scope : %s\n',idScope);

if ~contains(upper(idAfg),"AFG-2225")
    error('COM3 did not identify as AFG-2225.');
end
if ~contains(upper(idScope),"GDS-1102B")
    warning('COM4 identity did not contain GDS-1102B: %s',idScope);
end

% Safety: do not energize the output merely because the gateway starts.
safeWrite(afg,"OUTPUT1 OFF");

fprintf('\nTesting Upstash connection...\n');
try
    pong = redisCommand(cfg, {"PING"});
    fprintf('Upstash: %s\n', string(pong));
catch ME
    error('Upstash connection failed: %s', ME.message);
end

fprintf('\nGateway ONLINE. Waiting for cloud jobs. Ctrl+C to stop.\n');

lastJobId = "";
while true
    try
        nowIso = char(datetime("now","TimeZone","UTC", ...
            "Format","yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"));

        status = struct("gatewayId",cfg.gatewayId, ...
            "online",true,"updatedAt",nowIso, ...
            "afg",idAfg,"scope",idScope);
        redisSetJson(cfg,"hardware:gateway:status",status,15);

        % The web app should write the newest command as JSON to:
        % hardware:job:pending
        job = redisGetJson(cfg,"hardware:job:pending");

        if ~isempty(job) && isfield(job,"id")
            jobId = string(job.id);
            if jobId ~= lastJobId
                fprintf('\nJob %s received\n',jobId);
                result = executeJob(job,afg,scope);
                result.id = char(jobId);
                result.gatewayId = cfg.gatewayId;
                result.completedAt = char(datetime("now","TimeZone","UTC", ...
                    "Format","yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"));

                redisSetJson(cfg,"hardware:job:result:"+jobId,result,300);
                redisSetJson(cfg,"hardware:job:latest-result",result,300);
                redisDelete(cfg,"hardware:job:pending");
                lastJobId = jobId;
                fprintf('Job %s completed: %s\n',jobId,result.status);
            end
        end
    catch ME
        fprintf(2,'Gateway cycle error: %s\n',ME.message);
    end
    pause(cfg.pollSeconds);
end
end

function result = executeJob(job,afg,scope)
result = struct("status","ok","message","Command executed");

try
    if isfield(job,"channel"), ch = max(1,min(2,double(job.channel))); else, ch=1; end
    p = "SOURCE"+ch+":";

    if isfield(job,"waveform")
        w = upper(string(job.waveform));
        switch w
            case {"SINE","SIN"}, scpi="SIN";
            case {"SQUARE","SQU"}, scpi="SQU";
            case {"TRIANGLE","TRI"}, scpi="RAMP";
            case {"SAW","SAWTOOTH","RAMP"}, scpi="RAMP";
            otherwise, scpi="SIN";
        end
        safeWrite(afg,p+"FUNCTION "+scpi);
        if w=="TRIANGLE" || w=="TRI"
            safeWrite(afg,p+"RAMP:SYMMETRY 50");
        elseif w=="SAW" || w=="SAWTOOTH"
            safeWrite(afg,p+"RAMP:SYMMETRY 100");
        end
    end

    if isfield(job,"frequency")
        f=max(1e-6,double(job.frequency));
        safeWrite(afg,p+"FREQUENCY "+sprintf("%.12g",f));
    end

    if isfield(job,"amplitudeVpp")
        vpp=max(0.001,double(job.amplitudeVpp));
        safeWrite(afg,p+"VOLTAGE:UNIT VPP");
        safeWrite(afg,p+"AMPLITUDE "+sprintf("%.12g",vpp));
    end

    if isfield(job,"offset")
        off=double(job.offset);
        safeWrite(afg,p+"DCOFFSET "+sprintf("%.12g",off));
    end

    if isfield(job,"phase")
        ph=double(job.phase);
        safeWrite(afg,p+"PHASE "+sprintf("%.12g",ph));
    end

    if isfield(job,"duty")
        duty=max(1,min(99,double(job.duty)));
        safeWrite(afg,p+"SQUARE:DCYCLE "+sprintf("%.12g",duty));
    end

    if isfield(job,"output")
        if logical(job.output), state="ON"; else, state="OFF"; end
        safeWrite(afg,"OUTPUT"+ch+" "+state);
    end

    pause(0.25);

    result.afgFrequencyHz = str2double(queryAscii(afg,p+"FREQUENCY?"));
    safeWrite(afg,p+"VOLTAGE:UNIT VPP");
    result.afgAmplitudeVpp = str2double(queryAscii(afg,p+"AMPLITUDE?"));
    result.afgOffsetV = str2double(queryAscii(afg,p+"DCOFFSET?"));
    result.afgOutput = queryAscii(afg,"OUTPUT"+ch+"?");

    % Ask GDS for selected channel measurements.
    try
        safeWrite(scope,":MEASure:SOURce1 CH"+ch);
        result.scopeVpp = str2double(queryAscii(scope,":MEASure:PK2Pk?"));
    catch
        result.scopeVpp = NaN;
    end
    try
        result.scopeFrequencyHz = str2double(queryAscii(scope,":MEASure:FREQuency?"));
    catch
        result.scopeFrequencyHz = NaN;
    end
catch ME
    result.status="error";
    result.message=ME.message;
end
end

function s = openInstrument(port,baud)
ports=serialportlist("available");
if ~any(strcmpi(ports,port))
    error('%s is not available. Available ports: %s',port,strjoin(ports,", "));
end
s=serialport(port,baud,"Timeout",2);
s.DataBits=8; s.StopBits=1; s.Parity="none"; s.FlowControl="none";
configureTerminator(s,"LF");
pause(0.8); flush(s);
end

function safeWrite(s,cmd)
writeline(s,char(cmd));
pause(0.10);
end

function reply = queryAscii(s,cmd)
flush(s,"input");
writeline(s,char(cmd));
pause(0.20);
raw="";
t=tic;
while toc(t)<2.0
    n=s.NumBytesAvailable;
    if n>0
        raw=raw+string(read(s,n,"char"));
        if contains(raw,newline) || contains(raw,char(13)), break; end
    end
    pause(0.03);
end
reply=strtrim(raw);
if strlength(reply)==0
    error('No reply to SCPI query: %s',cmd);
end
end

function obj = redisGetJson(cfg,key)
result = redisCommand(cfg, {"GET", char(key)});
obj = [];
if isempty(result)
    return;
end

if ischar(result) || isstring(result)
    raw = char(result);
    if ~isempty(strtrim(raw))
        obj = jsondecode(raw);
    end
elseif isstruct(result)
    obj = result;
end
end

function redisSetJson(cfg,key,value,ttl)
payload = jsonencode(value);

if nargin >= 4 && ~isempty(ttl)
    redisCommand(cfg, {"SET", char(key), payload, "EX", num2str(ttl)});
else
    redisCommand(cfg, {"SET", char(key), payload});
end
end

function redisDelete(cfg,key)
redisCommand(cfg, {"DEL", char(key)});
end

function result = redisCommand(cfg,command)
% Upstash Redis REST API using POST JSON command format.
% Compatible with older MATLAB weboptions HeaderFields syntax.

url = char(cfg.redisUrl);
token = char(cfg.redisToken);

headers = {
    'Authorization', ['Bearer ' token]
    'Content-Type',  'application/json'
};

opts = weboptions( ...
    'HeaderFields', headers, ...
    'MediaType', 'application/json', ...
    'Timeout', 8);

body = jsonencode(command);

try
    response = webwrite(url, body, opts);
catch ME
    error('Upstash REST request failed: %s', ME.message);
end

if isstruct(response)
    if isfield(response,'error') && ~isempty(response.error)
        error('Upstash command error: %s', char(string(response.error)));
    end
    if isfield(response,'result')
        result = response.result;
    else
        result = [];
    end
else
    result = response;
end
end

function cleanupGateway(afg,scope)
fprintf('\nStopping hardware gateway...\n');
try, writeline(afg,'OUTPUT1 OFF'); catch, end
try, writeline(afg,'OUTPUT2 OFF'); catch, end
try, delete(afg); catch, end
try, delete(scope); catch, end
fprintf('Gateway stopped; AFG outputs commanded OFF.\n');
end
