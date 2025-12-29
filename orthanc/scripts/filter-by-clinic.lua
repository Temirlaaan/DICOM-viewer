-- =============================================================================
-- Clinic-based Access Control Filter for Orthanc
-- =============================================================================
-- This script filters DICOM data based on clinic_id from JWT tokens.
-- Users can only access studies from their assigned clinics.
-- =============================================================================

-- Configuration
local KEYCLOAK_URL = os.getenv("KEYCLOAK_URL") or "http://keycloak:8080"
local KEYCLOAK_REALM = os.getenv("KEYCLOAK_REALM") or "dicom"
local LOG_LEVEL = os.getenv("LOG_LEVEL") or "info"

-- Helper: Log with JSON format
local function log_json(level, message, data)
    if level == "debug" and LOG_LEVEL ~= "debug" then
        return
    end

    local log_entry = {
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        level = level,
        component = "orthanc-filter",
        message = message
    }

    if data then
        for k, v in pairs(data) do
            log_entry[k] = v
        end
    end

    -- Simple JSON serialization
    local json_parts = {}
    for k, v in pairs(log_entry) do
        local value_str
        if type(v) == "string" then
            value_str = '"' .. v:gsub('"', '\\"') .. '"'
        elseif type(v) == "table" then
            local arr = {}
            for _, item in ipairs(v) do
                table.insert(arr, '"' .. tostring(item) .. '"')
            end
            value_str = "[" .. table.concat(arr, ",") .. "]"
        else
            value_str = tostring(v)
        end
        table.insert(json_parts, '"' .. k .. '":' .. value_str)
    end

    print("{" .. table.concat(json_parts, ",") .. "}")
end

-- Helper: Extract Bearer token from Authorization header
local function extract_token(headers)
    local auth_header = headers["authorization"] or headers["Authorization"]
    if not auth_header then
        return nil
    end

    local token = auth_header:match("^[Bb]earer%s+(.+)$")
    return token
end

-- Helper: Decode base64
local function base64_decode(data)
    local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    data = string.gsub(data, '[^'..b..'=]', '')
    return (data:gsub('.', function(x)
        if x == '=' then return '' end
        local r, f = '', (b:find(x) - 1)
        for i = 6, 1, -1 do r = r .. (f % 2^i - f % 2^(i-1) > 0 and '1' or '0') end
        return r
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
        if #x ~= 8 then return '' end
        local c = 0
        for i = 1, 8 do c = c + (x:sub(i, i) == '1' and 2^(8 - i) or 0) end
        return string.char(c)
    end))
end

-- Helper: Parse JWT payload (without verification - verification done by nginx/keycloak)
local function parse_jwt_payload(token)
    if not token then
        return nil
    end

    local parts = {}
    for part in token:gmatch("[^%.]+") do
        table.insert(parts, part)
    end

    if #parts ~= 3 then
        return nil
    end

    -- Decode payload (second part)
    -- Handle base64url encoding
    local payload_b64 = parts[2]:gsub("-", "+"):gsub("_", "/")
    -- Add padding if needed
    local padding = 4 - (#payload_b64 % 4)
    if padding < 4 then
        payload_b64 = payload_b64 .. string.rep("=", padding)
    end

    local payload_json = base64_decode(payload_b64)

    -- Simple JSON parsing for our specific claims
    local claims = {}

    -- Extract clinic_ids array
    local clinic_ids_match = payload_json:match('"clinic_ids"%s*:%s*%[([^%]]+)%]')
    if clinic_ids_match then
        claims.clinic_ids = {}
        for id in clinic_ids_match:gmatch('"([^"]+)"') do
            table.insert(claims.clinic_ids, id)
        end
    end

    -- Extract roles array
    local roles_match = payload_json:match('"roles"%s*:%s*%[([^%]]+)%]')
    if roles_match then
        claims.roles = {}
        for role in roles_match:gmatch('"([^"]+)"') do
            table.insert(claims.roles, role)
        end
    end

    -- Extract sub (subject/user id)
    claims.sub = payload_json:match('"sub"%s*:%s*"([^"]+)"')

    -- Extract preferred_username
    claims.username = payload_json:match('"preferred_username"%s*:%s*"([^"]+)"')

    return claims
end

-- Helper: Check if user has admin role
local function is_admin(claims)
    if not claims or not claims.roles then
        return false
    end

    for _, role in ipairs(claims.roles) do
        if role == "admin" then
            return true
        end
    end

    return false
end

-- Helper: Check if clinic_id is in user's allowed clinics
local function clinic_allowed(claims, clinic_id)
    if not claims or not claims.clinic_ids then
        return false
    end

    for _, allowed_clinic in ipairs(claims.clinic_ids) do
        if allowed_clinic == clinic_id then
            return true
        end
    end

    return false
end

-- Helper: Get clinic_id from study metadata
local function get_study_clinic_id(study_id)
    local study = ParseJson(RestApiGet("/studies/" .. study_id))
    if study and study.MainDicomTags then
        return study.MainDicomTags.InstitutionName
    end
    return nil
end

-- =============================================================================
-- Orthanc Callbacks
-- =============================================================================

-- Filter callback for incoming HTTP requests
function IncomingHttpRequestFilter(method, uri, ip, username, httpHeaders)
    -- Allow system endpoints without auth
    if uri == "/system" or uri == "/plugins" or uri:match("^/metrics") then
        return true
    end

    -- Allow health checks
    if uri == "/health" or uri == "/" then
        return true
    end

    -- Extract and parse token
    local token = extract_token(httpHeaders)
    if not token then
        log_json("warn", "No authorization token provided", {uri = uri, ip = ip})
        -- Let the request through - nginx should have already validated
        -- This allows for local development without auth
        return true
    end

    local claims = parse_jwt_payload(token)
    if not claims then
        log_json("warn", "Failed to parse JWT token", {uri = uri, ip = ip})
        return true  -- Let through, rely on nginx validation
    end

    log_json("debug", "Request authenticated", {
        uri = uri,
        username = claims.username,
        clinic_ids = claims.clinic_ids
    })

    -- Admin users have full access
    if is_admin(claims) then
        log_json("debug", "Admin access granted", {username = claims.username})
        return true
    end

    -- For study-level access, check clinic authorization
    local study_id = uri:match("/studies/([^/]+)")
    if study_id then
        local clinic_id = get_study_clinic_id(study_id)
        if clinic_id and not clinic_allowed(claims, clinic_id) then
            log_json("warn", "Access denied - clinic not allowed", {
                username = claims.username,
                study_id = study_id,
                clinic_id = clinic_id,
                allowed_clinics = claims.clinic_ids
            })
            return false
        end
    end

    return true
end

-- Filter callback for ReceivedInstanceFilter
function ReceivedInstanceFilter(dicom, origin)
    -- Log received instance
    local tags = ParseJson(dicom)
    local institution = "unknown"
    local patient_id = "unknown"
    local study_uid = "unknown"

    if tags then
        institution = tags["0008,0080"] or "unknown"  -- InstitutionName
        patient_id = tags["0010,0020"] or "unknown"   -- PatientID
        study_uid = tags["0020,000d"] or "unknown"    -- StudyInstanceUID
    end

    log_json("info", "Received DICOM instance", {
        origin = origin.RemoteAet or origin.RemoteIp or "unknown",
        institution = institution,
        patient_id = patient_id,
        study_uid = study_uid
    })

    -- Accept all instances - filtering happens at query time
    return true
end

-- Log on startup
log_json("info", "Clinic filter script loaded", {
    keycloak_url = KEYCLOAK_URL,
    keycloak_realm = KEYCLOAK_REALM
})
