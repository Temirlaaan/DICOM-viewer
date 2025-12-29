-- =============================================================================
-- On Stored Instance Handler for Orthanc
-- =============================================================================
-- This script handles post-processing of stored DICOM instances:
-- - Logging for audit trail
-- - Metrics collection
-- - Custom metadata tagging
-- =============================================================================

-- Configuration
local LOG_LEVEL = os.getenv("LOG_LEVEL") or "info"

-- Helper: Log with JSON format
local function log_json(level, message, data)
    if level == "debug" and LOG_LEVEL ~= "debug" then
        return
    end

    local log_entry = {
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        level = level,
        component = "orthanc-storage",
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
            value_str = '"' .. v:gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
        elseif type(v) == "number" then
            value_str = tostring(v)
        elseif type(v) == "boolean" then
            value_str = v and "true" or "false"
        elseif type(v) == "table" then
            local arr = {}
            for _, item in ipairs(v) do
                table.insert(arr, '"' .. tostring(item) .. '"')
            end
            value_str = "[" .. table.concat(arr, ",") .. "]"
        else
            value_str = '"' .. tostring(v) .. '"'
        end
        table.insert(json_parts, '"' .. k .. '":' .. value_str)
    end

    print("{" .. table.concat(json_parts, ",") .. "}")
end

-- =============================================================================
-- Orthanc Callbacks
-- =============================================================================

-- Callback when a new instance is stored
function OnStoredInstance(instanceId, tags, metadata, origin)
    -- Extract relevant DICOM tags
    local institution_name = tags["InstitutionName"] or tags["0008,0080"] or "unknown"
    local patient_id = tags["PatientID"] or tags["0010,0020"] or "unknown"
    local patient_name = tags["PatientName"] or tags["0010,0010"] or "unknown"
    local study_date = tags["StudyDate"] or tags["0008,0020"] or "unknown"
    local study_description = tags["StudyDescription"] or tags["0008,1030"] or ""
    local modality = tags["Modality"] or tags["0008,0060"] or "unknown"
    local sop_class_uid = tags["SOPClassUID"] or tags["0008,0016"] or "unknown"
    local study_instance_uid = tags["StudyInstanceUID"] or tags["0020,000d"] or "unknown"
    local series_instance_uid = tags["SeriesInstanceUID"] or tags["0020,000e"] or "unknown"

    -- Determine origin information
    local origin_type = "unknown"
    local origin_info = "unknown"

    if origin then
        if origin.RequestOrigin then
            origin_type = origin.RequestOrigin
        end
        if origin.RemoteAet then
            origin_info = origin.RemoteAet
        elseif origin.RemoteIp then
            origin_info = origin.RemoteIp
        elseif origin.CallerAet then
            origin_info = origin.CallerAet
        end
    end

    -- Log the stored instance
    log_json("info", "Instance stored", {
        instance_id = instanceId,
        clinic_id = institution_name,
        patient_id = patient_id,
        patient_name = patient_name,
        study_date = study_date,
        study_description = study_description,
        modality = modality,
        study_uid = study_instance_uid,
        series_uid = series_instance_uid,
        origin_type = origin_type,
        origin_info = origin_info
    })

    -- Add custom metadata to the instance for tracking
    -- Metadata key 1024 is reserved for clinic_id (defined in orthanc.json)
    local success, err = pcall(function()
        RestApiPut("/instances/" .. instanceId .. "/metadata/1024", institution_name)
    end)

    if not success then
        log_json("warn", "Failed to set clinic_id metadata", {
            instance_id = instanceId,
            error = tostring(err)
        })
    end

    -- Set import timestamp
    local import_timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
    pcall(function()
        RestApiPut("/instances/" .. instanceId .. "/metadata/1025", import_timestamp)
    end)

    -- Set import source
    pcall(function()
        RestApiPut("/instances/" .. instanceId .. "/metadata/1026", origin_type .. ":" .. origin_info)
    end)
end

-- Callback when a study becomes stable (no new instances for StableAge seconds)
function OnStableStudy(studyId, tags, metadata)
    -- Get study information
    local study_info = ParseJson(RestApiGet("/studies/" .. studyId))

    if not study_info then
        log_json("warn", "Failed to get study info", {study_id = studyId})
        return
    end

    local main_tags = study_info.MainDicomTags or {}
    local patient_main_tags = study_info.PatientMainDicomTags or {}

    local institution_name = main_tags.InstitutionName or "unknown"
    local patient_id = patient_main_tags.PatientID or "unknown"
    local patient_name = patient_main_tags.PatientName or "unknown"
    local study_date = main_tags.StudyDate or "unknown"
    local study_description = main_tags.StudyDescription or ""
    local accession_number = main_tags.AccessionNumber or ""

    -- Count series and instances
    local series_count = 0
    local instance_count = 0

    if study_info.Series then
        series_count = #study_info.Series
        for _, series_id in ipairs(study_info.Series) do
            local series_info = ParseJson(RestApiGet("/series/" .. series_id))
            if series_info and series_info.Instances then
                instance_count = instance_count + #series_info.Instances
            end
        end
    end

    log_json("info", "Study stable", {
        study_id = studyId,
        clinic_id = institution_name,
        patient_id = patient_id,
        patient_name = patient_name,
        study_date = study_date,
        study_description = study_description,
        accession_number = accession_number,
        series_count = series_count,
        instance_count = instance_count
    })
end

-- Callback when a study is deleted
function OnDeletedStudy(studyId)
    log_json("info", "Study deleted", {
        study_id = studyId
    })
end

-- Log on startup
log_json("info", "On-stored-instance script loaded")
