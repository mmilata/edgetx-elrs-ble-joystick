-- Function script that starts the BLE Joystick mode of an ExpressLRS TX module
-- when the model is selected.
--
-- Install to /SCRIPTS/FUNCTIONS/ and add a Special Function to the model:
--   switch ON, action "Lua Script", script "elrsbj", repeat "On"
--
-- Leaving the model turns the joystick off, as EdgeTX powers the module down
-- while switching models.
--
-- If the joystick could not be started, the time and reason are written to
-- /LOGS/elrsbj.txt, replacing the previous error. Lines are kept within 21
-- characters to fit the text viewer of 128x64 radios.
--
-- This work is free. You can redistribute it and/or modify it under the
-- terms of the Do What The Fuck You Want To Public License, Version 2,
-- as published by Sam Hocevar. See http://www.wtfpl.net/ for more details.

local deviceId = 0xEE
local handsetId = 0xEA
local CMD_NAME = "BLE Joystick"
local TYPE_COMMAND = 13
local STEP_TIMEOUT = 1000 -- 10s for each step
local ERROR_DIR = "/LOGS"
local ERROR_FILE = ERROR_DIR .. "/elrsbj.txt"

-- command steps
local lcsClick = 1
local lcsExecuting = 2
local lcsAskConfirm = 3
local lcsConfirmed = 4

local ST_SEARCHING = 0
local ST_SCANNING = 1
local ST_STARTING = 2
local ST_DONE = 3

local state = ST_SEARCHING
local fieldId = 0
local cmdId = nil
local cmdStep = lcsClick
local timeout = 0
local deadline = nil

local function setState(newState)
  state = newState
  timeout = 0
  deadline = getTime() + STEP_TIMEOUT
end

local function reportError(msg)
  state = ST_DONE
  local f = io.open(ERROR_FILE, "w")
  -- EdgeTX creates /LOGS only once SD logging is used, mkdir() needs 2.11+
  if not f and mkdir then
    mkdir(ERROR_DIR)
    f = io.open(ERROR_FILE, "w")
  end
  if f then
    local dt = getDateTime()
    io.write(f, string.format("%04d-%02d-%02d %02d:%02d:%02d\r\n",
      dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec), msg, "\r\n")
    io.close(f)
  end
end

local function reportSuccess()
  state = ST_DONE
end

local function readString(data, offset)
  local s = ""
  while data[offset] ~= nil and data[offset] ~= 0 do
    s = s .. string.char(data[offset])
    offset = offset + 1
  end
  return s, offset + 1
end

local function parseDeviceInfo(data)
  if state ~= ST_SEARCHING or data[2] ~= deviceId then return end
  local _, offset = readString(data, 3)
  local fieldsCount = data[offset + 12] or 0
  if fieldsCount == 0 then
    return reportError("TX has no parameters")
  end
  -- BLE Joystick is registered near the end, so scan backwards
  fieldId = fieldsCount
  setState(ST_SCANNING)
end

local function parseParameterInfo(data)
  if data[2] ~= deviceId then return end
  local id = data[3]
  -- data[4] is chunks remaining, only the first chunk is needed for name/status
  -- low 7 bits are the type, the top bit is the hidden flag
  local fldType = (data[6] or 0) % 128
  local name, offset = readString(data, 7)

  if state == ST_SCANNING and id == fieldId then
    if fldType == TYPE_COMMAND and name == CMD_NAME then
      if data[offset] == lcsExecuting then
        -- already running, e.g. the script was reloaded after a tool script
        return reportSuccess()
      end
      cmdId = id
      cmdStep = lcsClick
      setState(ST_STARTING)
    elseif fieldId <= 1 then
      reportError("No " .. CMD_NAME .. " on TX")
    else
      fieldId = fieldId - 1
      timeout = 0
    end
  elseif state == ST_STARTING and id == cmdId then
    local step = data[offset]
    if step == lcsExecuting then
      reportSuccess()
    elseif step == lcsAskConfirm then
      cmdStep = lcsConfirmed
      timeout = 0
    end
  end
end

local function step()
  if state == ST_DONE then return end

  local command, data
  repeat
    command, data = crossfireTelemetryPop()
    if command == 0x29 then
      parseDeviceInfo(data)
    elseif command == 0x2B then
      parseParameterInfo(data)
    end
  until command == nil or state == ST_DONE

  local time = getTime()
  if state == ST_DONE then
    return
  elseif deadline == nil then
    deadline = time + STEP_TIMEOUT
  elseif time > deadline then
    if state == ST_SEARCHING then
      return reportError("No TX module found")
    elseif state == ST_SCANNING then
      return reportError("TX params timeout")
    else
      return reportError("BLE start timeout")
    end
  end

  if time > timeout then
    -- crossfireTelemetryPush() returns false if the previous frame wasn't sent
    -- yet, only start the retry timeout once the frame has been queued
    if state == ST_SEARCHING then
      if crossfireTelemetryPush(0x28, { 0x00, handsetId }) then
        timeout = time + 100
      end
    elseif state == ST_SCANNING then
      if crossfireTelemetryPush(0x2C, { deviceId, handsetId, fieldId, 0 }) then
        timeout = time + 50
      end
    elseif state == ST_STARTING then
      if crossfireTelemetryPush(0x2D, { deviceId, handsetId, cmdId, cmdStep }) then
        timeout = time + 200
      end
    end
  end
end

-- Same work whether the Special Function calls run() (repeat "On") or
-- background() (repeat "1x")
return { run=step, background=step }
