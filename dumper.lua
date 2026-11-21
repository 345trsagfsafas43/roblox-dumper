local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local env = (typeof(getgenv) == "function" and getgenv()) or _G

local previous = env.__DumperSession
if typeof(previous) == "table" and typeof(previous.stop) == "function" then
    pcall(previous.stop)
    local deadline = os.clock() + 2
    while (previous.running or (previous.busy and previous.busy())) and os.clock() < deadline do task.wait() end
    if previous.running or (previous.busy and previous.busy()) then
        warn("[Dumper] The previous dump is still finishing. Reload after it stops.")
        return
    end
end
if typeof(env.__DumperUnload) == "function" then pcall(env.__DumperUnload) end

local function has(fn) return typeof(fn) == "function" end
local dbg = typeof(debug) == "table" and debug or {}

local Has = {
    writefile = has(writefile),
    appendfile = has(appendfile),
    readfile = has(readfile),
    makefolder = has(makefolder),
    isfolder = has(isfolder),
    isfile = has(isfile),
    delfile = has(delfile),
    decompile = has(decompile),
    scripthash = has(getscripthash),
    bytecode = has(getscriptbytecode),
    scriptclosure = has(getscriptclosure) or has(getscriptfunction),
    constants = has(dbg.getconstants) or has(getconstants),
    protos = has(dbg.getprotos) or has(getprotos),
    nilinstances = has(getnilinstances),
    loadedmodules = has(getloadedmodules),
    runningscripts = has(getrunningscripts),
    connections = has(getconnections),
    info = has(dbg.info),
    callbackvalue = has(getcallbackvalue),
    renv = has(getrenv),
    hook = has(hookmetamethod) and has(getnamecallmethod),
    checkcaller = has(checkcaller),
    callingscript = has(getcallingscript),
    clipboard = has(setclipboard),
}

local VERSION = "Dumper v8"
local WIDTH = 80
local RULE = string.rep("=", WIDTH)
local THIN = string.rep("-", WIDTH)

local ROOT_ORDER = {
    "Workspace", "ReplicatedStorage", "ReplicatedFirst", "StarterGui", "StarterPlayer",
    "StarterPack", "Players", "Lighting", "SoundService", "Teams", "Chat",
}
local SCRIPT_ROOT_RANK = {
    ReplicatedFirst = 1, ReplicatedStorage = 2, StarterPlayer = 3, StarterGui = 4,
    StarterPack = 5, Players = 6, Workspace = 7, Lighting = 8, SoundService = 9,
    Teams = 10, Chat = 11,
}

local SPEEDS = { Smooth = 0.006, Fast = 0.016, Max = 0.05 }

local Config = {
    Output = "Single file",
    Speed = "Fast",
    Info = true,
    Scripts = true,
    Tree = true,
    Remotes = true,
    Listeners = true,
    Signals = true,
    Tags = true,
    Globals = true,
    Modules = false,
    Values = true,
    Interactables = true,
    UiText = true,
    Hidden = true,
    Constants = true,
    Spy = false,
    SpySeconds = 20,
    Attributes = true,
    SkipDefaults = true,
    DedupeScripts = true,
    OnlyMyCharacter = true,
    OnlyMyPlayer = false,
    CollapseRepeats = true,
    SkipGuiValues = true,
    HideName = true,
    MaxFileMB = 24,
    MaxDepth = 40,
    MaxScriptChars = 500000,
    DecompileTimeout = 10,
    ModuleTimeout = 10,
    Roots = { "Workspace", "ReplicatedStorage", "ReplicatedFirst", "StarterGui", "StarterPlayer",
        "StarterPack", "Players", "Lighting", "SoundService", "Teams" },
    AutoStart = false,
    NoUI = false,
}

local ConfigDefaults = table.clone(Config)
ConfigDefaults.Roots = table.clone(Config.Roots)

if typeof(env.DumperConfig) == "table" then
    for key, value in pairs(env.DumperConfig) do
        if Config[key] ~= nil then Config[key] = value end
    end
end

local function normaliseConfig(input)
    local result = table.clone(ConfigDefaults)
    for key, fallback in pairs(ConfigDefaults) do
        if typeof(fallback) == "boolean" and typeof(input[key]) == "boolean" then
            result[key] = input[key]
        end
    end
    result.Output = input.Output == "Split files" and "Split files" or "Single file"
    result.Speed = SPEEDS[input.Speed] and input.Speed or ConfigDefaults.Speed
    local bounds = {
        SpySeconds = { 0, 3600 }, MaxFileMB = { 0, 1024 }, MaxDepth = { 1, 200 },
        MaxScriptChars = { 1000, 10000000 }, DecompileTimeout = { 0.1, 120 },
        ModuleTimeout = { 0.1, 120 },
    }
    for key, bound in pairs(bounds) do
        local value = tonumber(input[key])
        if value and value == value and math.abs(value) ~= math.huge then
            result[key] = math.clamp(value, bound[1], bound[2])
        end
    end
    result.MaxDepth = math.floor(result.MaxDepth)
    result.MaxScriptChars = math.floor(result.MaxScriptChars)
    if result.MaxFileMB > 0 then result.MaxFileMB = math.max(1 / 1024, result.MaxFileMB) end
    result.Roots = {}
    local wanted = {}
    for _, name in ipairs(typeof(input.Roots) == "table" and input.Roots or ConfigDefaults.Roots) do
        if typeof(name) == "string" then wanted[name] = true end
    end
    for _, name in ipairs(ROOT_ORDER) do
        if wanted[name] then result.Roots[#result.Roots + 1] = name end
    end
    return result
end

Config = normaliseConfig(Config)
local UserConfig = Config

local SCRIPT_CLASSES = { Script = true, LocalScript = true, ModuleScript = true }
local REMOTE_CLASSES = {
    RemoteEvent = true, RemoteFunction = true, UnreliableRemoteEvent = true,
    BindableEvent = true, BindableFunction = true,
}
local VALUE_CLASSES = {
    StringValue = true, IntValue = true, NumberValue = true, BoolValue = true,
    ObjectValue = true, Vector3Value = true, CFrameValue = true, Color3Value = true,
    BrickColorValue = true, RayValue = true,
}
local INTERACT_CLASSES = { ProximityPrompt = true, ClickDetector = true, TouchTransmitter = true }
local TEXT_CLASSES = { TextButton = "button", TextLabel = "label", TextBox = "box" }

local function readValue(inst) return inst.Value end
local function readRunContext(inst) return inst.RunContext end
local function readText(inst) return inst.Text end

local function fmt(n)
    if n ~= n then return "nan" end
    if n == math.huge then return "inf" elseif n == -math.huge then return "-inf" end
    if n == math.floor(n) and math.abs(n) < 1e15 then return tostring(n) end
    return ("%.17g"):format(n)
end

local function serialize(value, depth, state)
    depth = depth or 0
    state = state or { seen = {}, nodes = 0 }
    state.nodes = state.nodes + 1
    if state.nodes > 120 then return "<value limit>" end
    local kind = typeof(value)
    if kind == "string" then
        if #value > 200 then value = value:sub(1, 200) .. ("... [%d bytes total]"):format(#value) end
        return (("%q"):format(value):gsub("\\\n", "\\n"):gsub("\r", "\\r"))
    elseif kind == "number" then
        return fmt(value)
    elseif kind == "boolean" or kind == "nil" then
        return tostring(value)
    elseif kind == "Instance" then
        local ok, name = pcall(value.GetFullName, value)
        return "<" .. (ok and name or "?") .. ">"
    elseif kind == "Vector3" then
        return ("Vector3(%s, %s, %s)"):format(fmt(value.X), fmt(value.Y), fmt(value.Z))
    elseif kind == "Vector2" then
        return ("Vector2(%s, %s)"):format(fmt(value.X), fmt(value.Y))
    elseif kind == "CFrame" then
        local components, parts = { value:GetComponents() }, {}
        for i, n in ipairs(components) do parts[i] = fmt(n) end
        return "CFrame(" .. table.concat(parts, ", ") .. ")"
    elseif kind == "Color3" then
        return ("Color3(%s, %s, %s)"):format(fmt(value.R), fmt(value.G), fmt(value.B))
    elseif kind == "UDim2" then
        return ("UDim2({%s, %s}, {%s, %s})"):format(fmt(value.X.Scale), fmt(value.X.Offset), fmt(value.Y.Scale), fmt(value.Y.Offset))
    elseif kind == "EnumItem" then
        return tostring(value)
    elseif kind == "function" then
        local okInfo, src, line = pcall(dbg.info or error, value, "sl")
        return okInfo and src and ("function @%s:%s"):format(tostring(src), tostring(line)) or "function"
    elseif kind == "table" then
        if state.seen[value] then return "<cycle>" end
        if depth >= 3 then return "{...}" end
        state.seen[value] = true
        local parts, count = {}, 0
        for k, v in next, value do
            count = count + 1
            if count > 12 then
                parts[#parts + 1] = "..."
                break
            end
            local key = "[" .. serialize(k, depth + 1, state) .. "]"
            parts[#parts + 1] = key .. " = " .. serialize(v, depth + 1, state)
        end
        state.seen[value] = nil
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    local ok, text = pcall(tostring, value)
    return kind .. "(" .. (ok and text or "?") .. ")"
end

local function readAttributes(inst)
    local ok, attrs = pcall(inst.GetAttributes, inst)
    if not ok or typeof(attrs) ~= "table" or next(attrs) == nil then return nil end
    local list = {}
    for key, value in pairs(attrs) do
        list[#list + 1] = { key = key, text = serialize(value, 1) }
    end
    table.sort(list, function(a, b) return a.key < b.key end)
    return list
end

local function inlineAttributes(list)
    local parts = {}
    for i, attr in ipairs(list) do parts[i] = attr.key .. "=" .. attr.text end
    local text = table.concat(parts, ", ")
    if #text > 300 then text = text:sub(1, 300) .. "..." end
    return text
end

local function readTags(inst)
    local ok, tags = pcall(CollectionService.GetTags, CollectionService, inst)
    if not ok or typeof(tags) ~= "table" or #tags == 0 then return nil end
    table.sort(tags)
    return tags
end

local function pad(text, width)
    if #text >= width then return text end
    return text .. string.rep(" ", width - #text)
end

local function padLeft(text, width)
    if #text >= width then return text end
    return string.rep(" ", width - #text) .. text
end

local function plural(n, word)
    return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

local siblingIndex = setmetatable({}, { __mode = "k" })
local nilOrdinals = setmetatable({}, { __mode = "k" })
local nilNameCounts = {}

local function escapeSegment(name)
    if name == "" then return "\\e" end
    return (name:gsub("[\\%.%[%]%z\1-\31\127]", function(char)
        if char == "\n" then return "\\n" end
        if char == "\r" then return "\\r" end
        if char == "\t" then return "\\t" end
        if char == "." or char == "[" or char == "]" or char == "\\" then return "\\" .. char end
        return ("\\x%02X"):format(string.byte(char))
    end))
end

local function indexSiblings(parent, children)
    local counts, seen, map = {}, {}, {}
    for _, child in ipairs(children) do
        local name = child.Name
        counts[name] = (counts[name] or 0) + 1
    end
    for _, child in ipairs(children) do
        local name = child.Name
        if counts[name] > 1 then
            seen[name] = (seen[name] or 0) + 1
            map[child] = seen[name]
        end
    end
    siblingIndex[parent] = map
    return map
end

local function segment(inst, map)
    local index = map and map[inst]
    local name = escapeSegment(inst.Name)
    return index and (name .. "[" .. index .. "]") or name
end

local function pathOf(inst)
    local parts = {}
    local current = inst
    while current and current ~= game do
        local parent = current.Parent
        if not parent then
            if not nilOrdinals[current] then
                nilNameCounts[current.Name] = (nilNameCounts[current.Name] or 0) + 1
                nilOrdinals[current] = nilNameCounts[current.Name]
            end
            table.insert(parts, 1, escapeSegment(current.Name) .. "[nil:" .. nilOrdinals[current] .. "]")
            table.insert(parts, 1, "nil")
            break
        end
        local map = siblingIndex[parent]
        if not map then
            local ok, children = pcall(parent.GetChildren, parent)
            map = ok and indexSiblings(parent, children) or {}
        end
        table.insert(parts, 1, segment(current, map))
        current = parent
    end
    return table.concat(parts, ".")
end

local function safePath(inst)
    local ok, path = pcall(pathOf, inst)
    return ok and path or tostring(inst)
end

local function parentPathOf(path: string): string
    local at, lastDot = 1, nil
    while at <= #path do
        local char = path:sub(at, at)
        if char == "\\" then at = at + 2
        else
            if char == "." then lastDot = at end
            at = at + 1
        end
    end
    return lastDot and path:sub(1, lastDot - 1) or path
end

local function whereIs(fn)
    if not Has.info or type(fn) ~= "function" then return nil end
    local ok, src, line = pcall(dbg.info, fn, "sl")
    if not ok or type(src) ~= "string" then return nil end
    src = src:gsub("^[=@]", "")
    if src == "[C]" then return "[C]" end
    return src .. ":" .. tostring(line)
end

local function signature(fn)
    if not Has.info then return "function" end
    local ok, count, vararg = pcall(dbg.info, fn, "a")
    if not ok or type(count) ~= "number" then return "function" end
    local params = {}
    for i = 1, count do params[i] = "p" .. i end
    if vararg then params[#params + 1] = "..." end
    return "function(" .. table.concat(params, ", ") .. ")"
end

local Buffer = {}
Buffer.__index = Buffer

function Buffer.new()
    return setmetatable({ parts = {}, n = 0, lines = 0 }, Buffer)
end

function Buffer:line(text)
    if text:find("[\r\n]") then text = text:gsub("\r?\n", "\\n"):gsub("\r", "\\r") end
    local n = self.n
    self.parts[n + 1] = text
    self.parts[n + 2] = "\n"
    self.n = n + 2
    self.lines = self.lines + 1
end

function Buffer:block(text, count)
    if text:sub(-1) ~= "\n" then text = text .. "\n" end
    if not count then
        local _, newlines = text:gsub("\n", "")
        count = newlines
    end
    self.n = self.n + 1
    self.parts[self.n] = text
    self.lines = self.lines + count
    return count
end

function Buffer:text()
    return table.concat(self.parts, "", 1, self.n)
end

local function folder()
    return ("Dumper/%d"):format(game.PlaceId)
end

local function ensureFolder()
    if not Has.makefolder then return end
    for _, path in ipairs({ "Dumper", folder() }) do
        local exists = false
        if Has.isfolder then
            local ok, result = pcall(isfolder, path)
            if not ok then error("isfolder failed for " .. path .. ": " .. tostring(result), 0) end
            exists = result == true
        end
        if not exists then
            local ok, result = pcall(makefolder, path)
            if not ok or result == false then error("makefolder failed for " .. path .. ": " .. tostring(result), 0) end
        end
    end
end

local function filePath(name)
    if Has.makefolder then return folder() .. "/" .. name end
    return ("Dumper_%d_%s"):format(game.PlaceId, name)
end

local function anonymise(text: string): string
    local name = LocalPlayer and LocalPlayer.Name
    if not Config.HideName or type(name) ~= "string" or #name < 4 then return text end
    local pattern = name:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    return (text:gsub(pattern, "<you>"))
end

local function checkedFileCall(operation, fn, path, content)
    local ok, result = pcall(fn, path, content)
    if not ok or result == false then
        error(operation .. " failed for " .. path .. ": " .. tostring(result), 0)
    end
    return result
end

local function writeAll(path: string, chunks: {string})
    if Has.appendfile then
        checkedFileCall("writefile", writefile, path, chunks[1] or "")
        for i = 2, #chunks do checkedFileCall("appendfile", appendfile, path, chunks[i]) end
    else
        checkedFileCall("writefile", writefile, path, table.concat(chunks))
    end
end
local function partPath(path: string, n: number): string
    if n == 1 then return path end
    return (path:gsub("%.txt$", "")) .. "_" .. n .. ".txt"
end
local function writeChunks(path: string, chunks: {string})
    local limit = math.floor((tonumber(Config.MaxFileMB) or 0) * 1024 * 1024)
    local part, size, cur, metadata = 1, 0, {}, {}
    local nextLine, newlines, startsMidLine, lastByte = 1, 0, false, ""
    local function append(text)
        if text == "" then return end
        cur[#cur + 1] = text
        size = size + #text
        local _, count = text:gsub("\n", "")
        newlines = newlines + count
        lastByte = text:sub(-1)
    end
    local function flush()
        local physicalPath = partPath(path, part)
        writeAll(physicalPath, cur)
        local endsMidLine = size > 0 and lastByte ~= "\n"
        metadata[#metadata + 1] = {
            path = physicalPath, bytes = size, firstLine = nextLine,
            lastLine = size == 0 and nextLine - 1 or nextLine + newlines - (endsMidLine and 0 or 1),
            startsMidLine = startsMidLine, endsMidLine = endsMidLine,
        }
        nextLine = nextLine + newlines
        startsMidLine = endsMidLine
        part, size, cur, newlines, lastByte = part + 1, 0, {}, 0, ""
    end
    for _, original in ipairs(chunks) do
        local chunk = anonymise(original)
        local cursor = 1
        while cursor <= #chunk do
            local remaining = #chunk - cursor + 1
            local room = limit > 0 and limit - size or remaining
            if room <= 0 then flush(); room = limit end
            if remaining <= room then
                append(chunk:sub(cursor))
                cursor = #chunk + 1
            else
                local cut = chunk:sub(cursor, cursor + room - 1):match("^.*()\n")
                if not cut and size > 0 then flush()
                else
                    if not cut then
                        cut = room
                        local nextByte = chunk:byte(cursor + cut)
                        while cut > 0 and nextByte and nextByte >= 128 and nextByte < 192 do
                            cut = cut - 1
                            nextByte = chunk:byte(cursor + cut)
                        end
                        if cut == 0 then cut = room end
                    end
                    append(chunk:sub(cursor, cursor + cut - 1))
                    cursor = cursor + cut
                    flush()
                end
            end
        end
    end
    if size > 0 or #metadata == 0 then flush() end
    metadata[#metadata].endsMidLine = false
    if Has.isfile and Has.delfile then
        local n = part
        while true do
            local stalePath = partPath(path, n)
            local ok, exists = pcall(isfile, stalePath)
            if not ok then error("isfile failed for " .. stalePath .. ": " .. tostring(exists), 0) end
            if exists ~= true then break end
            checkedFileCall("delfile", delfile, stalePath)
            n = n + 1
        end
    end
    return #metadata, metadata
end

local function encodeStateName(name)
    return (name:gsub("[%%\r\n\t]", function(char)
        return ("%%%02X"):format(string.byte(char))
    end))
end

local function decodeStateName(name)
    return (name:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

local function loadSuspects(path)
    local suspects = {}
    if not Has.readfile then return suspects end
    if Has.isfile then
        local okFile, exists = pcall(isfile, path)
        if okFile and not exists then return suspects end
    end
    local ok, content = pcall(readfile, path)
    if not ok or typeof(content) ~= "string" then return suspects end
    local pending, lastAttempt, hasDone = {}, nil, false
    local version2 = content:match("^FORMAT\t2[\r\n]") ~= nil
    for line in content:gmatch("[^\r\n]+") do
        local tag, name = line:match("^(%a+)\t(.+)$")
        if name and version2 then name = decodeStateName(name) end
        if tag == "SUSPECT" then
            suspects[name] = true
        elseif tag == "ATTEMPT" then
            pending[name] = true
            lastAttempt = name
        elseif tag == "DONE" then
            pending[name] = nil
            hasDone = true
        end
    end
    if version2 or hasDone then
        for name in pairs(pending) do suspects[name] = true end
    elseif lastAttempt then
        suspects[lastAttempt] = true
    end
    return suspects
end

local State = {}

function State.open(path, suspects)
    State.path, State.text = path, { "FORMAT\t2\n" }
    local names = {}
    for name in pairs(suspects) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do State.text[#State.text + 1] = "SUSPECT\t" .. encodeStateName(name) .. "\n" end
    local ok, err = pcall(writefile, path, table.concat(State.text))
    if not ok then error("crash-state write failed for " .. path .. ": " .. tostring(err), 0) end
end

function State.add(line)
    State.text[#State.text + 1] = line
    local ok, err
    if Has.appendfile then
        ok, err = pcall(appendfile, State.path, line)
    else
        ok, err = pcall(writefile, State.path, table.concat(State.text))
    end
    if not ok then error("crash-state write failed for " .. State.path .. ": " .. tostring(err), 0) end
end

function State.record(tag, name)
    State.add(tag .. "\t" .. encodeStateName(name) .. "\n")
end

function State.finish(suspects)
    State.open(State.path, suspects)
end

local Spy = env.__DumperSpy7
if typeof(Spy) ~= "table" then
    Spy = { active = false }
    env.__DumperSpy7 = Spy
end

local SPY_SAMPLES = 5
local SPY_CALLERS = 4
local SPY_CLASSES = { RemoteEvent = true, RemoteFunction = true, UnreliableRemoteEvent = true }

function Spy.reset()
    Spy.entries, Spy.order, Spy.started, Spy.connections = {}, {}, os.clock(), {}
end

function Spy.record(direction, remote, caller, ...)
    local key = direction .. "\0" .. tostring(remote)
    local entry = Spy.entries[key]
    if not entry then
        entry = { direction = direction, remote = remote, count = 0, samples = {}, callers = {}, callerCount = 0 }
        Spy.entries[key] = entry
        Spy.order[#Spy.order + 1] = entry
    end
    entry.count = entry.count + 1
    if caller and not entry.callers[caller] and entry.callerCount < SPY_CALLERS then
        entry.callers[caller] = true
        entry.callerCount = entry.callerCount + 1
    end
    if #entry.samples < SPY_SAMPLES then
        local n = select("#", ...)
        local args = { ... }
        local parts = {}
        for i = 1, n do parts[i] = serialize(args[i]) end
        entry.samples[#entry.samples + 1] = ("@%6.2fs  (%s)"):format(os.clock() - Spy.started, table.concat(parts, ", "))
    end
end

local function installSpyHook()
    if not Has.hook or env.__DumperSpyHooked7 then return Has.hook end
    env.__DumperSpyHooked7 = true
    local original
    local function onNamecall(self, ...)
        local spy = env.__DumperSpy7
        if spy and spy.active and typeof(self) == "Instance" then
            local method = getnamecallmethod()
            if (method == "FireServer" or method == "InvokeServer")
                and SPY_CLASSES[self.ClassName]
                and not (Has.checkcaller and checkcaller())
            then
                local caller = nil
                if Has.callingscript then
                    local okCaller, found = pcall(getcallingscript)
                    if okCaller and typeof(found) == "Instance" then caller = found end
                end
                pcall(spy.record, method == "FireServer" and "OUT FireServer" or "OUT InvokeServer", self, caller, ...)
            end
        end
        return original(self, ...)
    end
    if has(newcclosure) then onNamecall = newcclosure(onNamecall) end
    original = hookmetamethod(game, "__namecall", onNamecall)
    return true
end

function Spy.start()
    Spy.reset()
    Spy.hooked = installSpyHook()
    for _, root in ipairs({ game:GetService("ReplicatedStorage"), workspace, LocalPlayer }) do
        local ok, descendants = pcall(root.GetDescendants, root)
        for _, inst in ipairs(ok and descendants or {}) do
            local className = inst.ClassName
            if className == "RemoteEvent" or className == "UnreliableRemoteEvent" then
                local okConn, connection = pcall(function()
                    return inst.OnClientEvent:Connect(function(...)
                        if Spy.active then pcall(Spy.record, "IN  OnClientEvent", inst, nil, ...) end
                    end)
                end)
                if okConn then Spy.connections[#Spy.connections + 1] = connection end
            end
        end
    end
    Spy.active = true
end

function Spy.stop()
    Spy.active = false
    for _, connection in ipairs(Spy.connections or {}) do pcall(function() connection:Disconnect() end) end
    Spy.connections = {}
end

function Spy.write(out)
    if not Spy.hooked then
        out:line("outgoing calls need hookmetamethod, which this executor does not have - incoming only")
        out:line("")
    end
    if not Spy.order or #Spy.order == 0 then
        out:line("nothing fired while recording - play the game (use tools, buy, move) during the spy window")
        return
    end
    table.sort(Spy.order, function(a, b)
        if a.direction ~= b.direction then return a.direction > b.direction end
        return a.count > b.count
    end)
    local lastSide
    for _, entry in ipairs(Spy.order) do
        local side = entry.direction:match("^%a+")
        if side ~= lastSide then
            if lastSide then out:line("") end
            out:line(side == "OUT" and "sent by the game (client -> server)" or "received (server -> client)")
            out:line(THIN)
            lastSide = side
        end
        out:line(("%-18s %s   x%d"):format(entry.direction:gsub("^%a+%s+", ""), safePath(entry.remote), entry.count))
        if entry.callerCount > 0 then
            local from = {}
            for caller in pairs(entry.callers) do from[#from + 1] = safePath(caller) end
            table.sort(from)
            out:line("      from " .. table.concat(from, ", "))
        end
        for _, sample in ipairs(entry.samples) do
            out:line("      " .. sample)
        end
    end
end

local Dump = { running = false, cancel = false }

local function isDefaultScript(inst)
    local current = inst
    while current and current ~= game do
        local parent = current.Parent
        local player = parent and parent.Parent
        local expectedClass = current.Name == "PlayerModule" and "ModuleScript" or "LocalScript"
        local knownRoot = current.Name == "PlayerModule" or current.Name == "PlayerScriptsLoader"
            or current.Name == "RbxCharacterSounds" or current.Name == "ChatScript"
        if knownRoot and current.ClassName == expectedClass and parent
            and parent.ClassName == "PlayerScripts" and player and player.ClassName == "Player"
            and player.Parent == Players
        then return true end
        current = current.Parent
    end
    return false
end

local function isClientReadable(inst, className)
    if className ~= "Script" then return true end
    local ok, context = pcall(readRunContext, inst)
    return ok and context == Enum.RunContext.Client
end

local function decompileWithTimeout(inst)
    if Dump.cancel then return false, "cancelled", true end
    local done, ok, result = false, false, nil
    local started = os.clock()
    local worker
    worker = task.spawn(function()
        ok, result = pcall(decompile, inst)
        done = true
        if Dump.pendingWorker == worker then Dump.pendingWorker = nil end
    end)
    while not done do
        if Dump.cancel or os.clock() - started >= Config.DecompileTimeout then
            local message = Dump.cancel and "cancelled" or ("timed out after %.1fs"):format(Config.DecompileTimeout)
            if has(task.cancel) then pcall(task.cancel, worker) end
            local okStatus, status = pcall(coroutine.status, worker)
            if not done and (not okStatus or status ~= "dead") and has(coroutine.close) then
                pcall(coroutine.close, worker)
                okStatus, status = pcall(coroutine.status, worker)
            end
            local settled = done or (okStatus and status == "dead")
            if not settled then
                Dump.pendingWorker, Dump.cancel = worker, true
                message = message .. "; worker could not be stopped, ending this run"
            end
            return false, message, settled
        end
        task.wait()
    end
    return ok, result, true
end

local function constantsOf(inst)
    if not Has.scriptclosure or not Has.constants then return nil end
    local getClosure = has(getscriptclosure) and getscriptclosure or getscriptfunction
    local getConstants = has(dbg.getconstants) and dbg.getconstants or getconstants
    local getProtos = Has.protos and (has(dbg.getprotos) and dbg.getprotos or getprotos) or nil
    local ok, closure = pcall(getClosure, inst)
    if not ok or type(closure) ~= "function" then return nil end
    local seen, seenFns, list, visited, bytes = {}, {}, {}, 0, 0
    local function walk(fn, depth)
        if seenFns[fn] or depth > 8 or visited >= 600 or #list >= 800 or bytes >= 256 * 1024 or Dump.cancel then return end
        seenFns[fn] = true
        visited = visited + 1
        local okC, consts = pcall(getConstants, fn)
        if okC and type(consts) == "table" then
            for _, value in pairs(consts) do
                if #list >= 800 or bytes >= 256 * 1024 or Dump.cancel then break end
                if type(value) == "string" and #value > 0 and not seen[value] then
                    seen[value] = true
                    local text = #value > 4096 and (value:sub(1, 4096) .. ("... [%d bytes total]"):format(#value)) or value
                    local remaining = 256 * 1024 - bytes
                    if #text > remaining then text = text:sub(1, remaining) end
                    bytes = bytes + #text
                    list[#list + 1] = text
                end
            end
        end
        if getProtos then
            local okP, protos = pcall(getProtos, fn)
            if okP and type(protos) == "table" then
                for _, proto in pairs(protos) do
                    if visited >= 600 or #list >= 800 or bytes >= 256 * 1024 or Dump.cancel then break end
                    if type(proto) == "function" then walk(proto, depth + 1) end
                end
            end
        end
    end
    walk(closure, 0)
    if #list == 0 then return nil end
    table.sort(list)
    return list
end

local function newContext()
    local characters = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character then characters[player.Character] = player end
    end
    return {
        stats = {
            instances = 0, scripts = 0, duplicates = 0, defaults = 0, serverScripts = 0,
            failures = 0, constants = 0, suspects = 0, remotes = 0, values = 0, interactables = 0,
            collapsed = 0, hidden = 0, tags = 0, texts = 0, remotesLeftOut = 0,
            depthLimited = 0,
            truncated = 0, cancelled = 0,
        },
        myPath = pathOf(LocalPlayer) .. ".",
        timings = {},
        characters = characters,
        classCount = {},
        visited = setmetatable({}, { __mode = "k" }),
        stack = {},
        queue = {},
        remotes = {},
        interactables = {},
        texts = {},
        hidden = {},
        index = {},
        seenScripts = {},
        out = {
            Tree = Buffer.new(),
            Values = Buffer.new(),
            Scripts = Buffer.new(),
        },
    }
end

local Budget = { last = 0 }

function Budget.start() Budget.last = os.clock() end

function Budget.check(onYield)
    if os.clock() - Budget.last >= (SPEEDS[Config.Speed] or SPEEDS.Fast) then
        if onYield then onYield() end
        task.wait()
        Budget.last = os.clock()
    end
end

local function treeNote(className, value, hasValue)
    if REMOTE_CLASSES[className] then return "  <- remote" end
    if className == "Script" then return nil end
    if hasValue then return "  = " .. value end
    return ""
end

local function childFrames(ctx, inst, depth, prefix, parentPath, inGui, suppressTree)
    local ok, children = pcall(inst.GetChildren, inst)
    if not ok or #children == 0 then return nil end
    if depth > Config.MaxDepth then
        ctx.stats.depthLimited = ctx.stats.depthLimited + #children
        return nil
    end
    local map = indexSiblings(inst, children)

    local groups, kept = {}, {}
    for _, child in ipairs(children) do
        local name, className = child.Name, child.ClassName
        if className ~= "Terrain" then
            local owner = className == "Model" and Config.OnlyMyCharacter and ctx.characters[child]
            if owner and owner ~= LocalPlayer then
                kept[#kept + 1] = { note = name .. " (Model)  -- " .. owner.Name .. "'s character, same as yours, skipped" }
            elseif className == "Player" and Config.OnlyMyPlayer and child ~= LocalPlayer then
                kept[#kept + 1] = { note = name .. " (Player)  -- skipped, only your own player is dumped" }
            elseif Config.SkipDefaults and SCRIPT_CLASSES[className] and isDefaultScript(child) then
                kept[#kept + 1] = { note = name .. " (" .. className .. ")  -- roblox default, skipped" }
                ctx.stats.defaults = ctx.stats.defaults + 1
            else
                local groupKey = name .. "\0" .. className
                local group = groups[groupKey]
                if not group then
                    group = { count = 0, name = name, className = className }
                    groups[groupKey] = group
                end
                group.count = group.count + 1
                local foldable = Config.CollapseRepeats and not REMOTE_CLASSES[className] and not SCRIPT_CLASSES[className]
                local label = segment(child, map)
                kept[#kept + 1] = {
                    inst = child, className = className, label = label,
                    path = parentPath .. "." .. label,
                    inGui = inGui or className == "PlayerGui" or className == "StarterGui",
                    suppressTree = suppressTree or (foldable and group.count > 3),
                }
                if not foldable or group.count <= 3 then
                    group.last = #kept
                end
            end
        end
    end

    for _, group in pairs(groups) do
        local extra = group.count - 3
        if extra > 0 and group.last and Config.CollapseRepeats
            and not REMOTE_CLASSES[group.className] and not SCRIPT_CLASSES[group.className]
        then
            kept[group.last].fold = ("... +%d more %s (%s), tree rows folded; contents still scanned")
                :format(extra, group.name, group.className)
            ctx.stats.collapsed = ctx.stats.collapsed + extra
        end
    end

    local frames = {}
    for _, item in ipairs(kept) do
        frames[#frames + 1] = item
        if item.fold then frames[#frames + 1] = { note = item.fold, suppressTree = suppressTree } end
    end
    local count = 0
    for _, frame in ipairs(frames) do if not frame.suppressTree then count = count + 1 end end
    local visible = 0
    for _, frame in ipairs(frames) do
        if not frame.suppressTree then visible = visible + 1 end
        frame.depth, frame.prefix, frame.isLast = depth, prefix, visible == count
    end
    return frames
end

local function noteText(ctx, inst, className, path)
    local kind = TEXT_CLASSES[className]
    if not kind or not path:find("PlayerGui", 1, true) then return end
    local ok, text = pcall(readText, inst)
    if not ok or type(text) ~= "string" then return end
    text = text:gsub("<[^>]->", ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
    if text == "" or #ctx.texts >= 3000 then return end
    ctx.texts[#ctx.texts + 1] = { kind = kind, text = #text > 120 and (text:sub(1, 120) .. "...") or text, path = path }
    ctx.stats.texts = ctx.stats.texts + 1
end

local function visit(ctx, frame)
    local out, stats = ctx.out, ctx.stats
    local branch = frame.depth == 0 and "" or (frame.isLast and "`-- " or "|-- ")

    if frame.note then
        if Config.Tree and not frame.suppressTree then out.Tree:line(frame.prefix .. branch .. frame.note) end
        return
    end

    local inst, path = frame.inst, frame.path
    local className = frame.className or inst.ClassName
    if ctx.visited[inst] then return end
    frame.inGui = frame.inGui or className == "PlayerGui" or className == "StarterGui"
    ctx.visited[inst] = true
    stats.instances = stats.instances + 1
    ctx.classCount[className] = (ctx.classCount[className] or 0) + 1

    local attrs = Config.Attributes and readAttributes(inst) or nil
    local tags = Config.Tags and readTags(inst) or nil
    local hasValue, valueText = false, nil
    if VALUE_CLASSES[className] then
        local ok, value = pcall(readValue, inst)
        hasValue, valueText = true, ok and serialize(value) or "<unreadable>"
    end

    if Config.Tree and not frame.suppressTree then
        local note
        if className == "Script" then
            local ok, context = pcall(readRunContext, inst)
            note = (ok and context == Enum.RunContext.Client) and "  [client]" or "  [server, unreadable]"
        else
            note = treeNote(className, valueText, hasValue)
        end
        out.Tree:line(frame.prefix .. branch .. (frame.label or inst.Name) .. " (" .. className .. ")" .. note
            .. (tags and ("  [tags: " .. table.concat(tags, ", ") .. "]") or "")
            .. (attrs and ("  {" .. inlineAttributes(attrs) .. "}") or ""))
    end

    if SCRIPT_CLASSES[className] then
        if Config.Scripts then
            ctx.queue[#ctx.queue + 1] = { inst = inst, className = className, path = path }
        end
    elseif REMOTE_CLASSES[className] then
        if Config.Remotes then
            local guiBindable = frame.inGui and (className == "BindableEvent" or className == "BindableFunction")
            local otherPlayer = path:sub(1, 8) == "Players." and path:sub(1, #ctx.myPath) ~= ctx.myPath
            if guiBindable or otherPlayer then
                stats.remotesLeftOut = stats.remotesLeftOut + 1
            else
                ctx.remotes[#ctx.remotes + 1] = { inst = inst, parent = parentPathOf(path), name = frame.label or inst.Name, className = className }
                stats.remotes = stats.remotes + 1
            end
        end
    elseif INTERACT_CLASSES[className] and Config.Interactables then
        ctx.interactables[#ctx.interactables + 1] = { inst = inst, className = className, path = path }
        stats.interactables = stats.interactables + 1
    elseif Config.UiText and frame.inGui then
        noteText(ctx, inst, className, path)
    end

    if Config.Values and not (Config.SkipGuiValues and frame.inGui) then
        local values = out.Values
        if attrs then
            if values.group ~= path then
                values.group = path
                values:line("")
                values:line(path)
            end
            for _, attr in ipairs(attrs) do
                values:line("    @" .. pad(attr.key, 26) .. " = " .. attr.text)
            end
        end
        if hasValue then
            local parent = parentPathOf(path)
            if values.group ~= parent then
                values.group = parent
                values:line("")
                values:line(parent)
            end
            values:line("    " .. pad(frame.label or inst.Name, 27) .. " = " .. pad(valueText, 30) .. "  " .. className)
            stats.values = stats.values + 1
        end
    end

    local childPrefix = frame.prefix
    if frame.depth > 0 then childPrefix = childPrefix .. (frame.isLast and "    " or "|   ") end
    local children = childFrames(ctx, inst, frame.depth + 1, childPrefix, path, frame.inGui, frame.suppressTree)
    if children then
        local stack = ctx.stack
        for i = #children, 1, -1 do stack[#stack + 1] = children[i] end
    end
end

local function collectHidden(ctx)
    local sources = {
        { "nil parented", Has.nilinstances and getnilinstances },
        { "loaded module", Has.loadedmodules and getloadedmodules },
        { "running script", Has.runningscripts and getrunningscripts },
    }
    for _, source in ipairs(sources) do
        local label, getter = source[1], source[2]
        if getter then
            local ok, list = pcall(getter)
            for _, inst in ipairs(ok and typeof(list) == "table" and list or {}) do
                if Dump.cancel then return end
                local okClass, className = pcall(function() return inst.ClassName end)
                if okClass and not ctx.visited[inst] and (SCRIPT_CLASSES[className] or REMOTE_CLASSES[className]) then
                    ctx.visited[inst] = true
                    local path = safePath(inst)
                    ctx.hidden[#ctx.hidden + 1] = { className = className, path = path, label = label }
                    ctx.stats.hidden = ctx.stats.hidden + 1
                    if Config.Scripts and SCRIPT_CLASSES[className]
                        and not (Config.SkipDefaults and isDefaultScript(inst))
                    then
                        ctx.queue[#ctx.queue + 1] = { inst = inst, className = className, path = path, hidden = true }
                    elseif Config.Remotes and REMOTE_CLASSES[className] then
                        ctx.remotes[#ctx.remotes + 1] = {
                            inst = inst, parent = parentPathOf(path), name = segment(inst), className = className,
                        }
                        ctx.stats.remotes = ctx.stats.remotes + 1
                    end
                end
                Budget.check()
            end
        else
            ctx.hidden[#ctx.hidden + 1] = { note = label .. ": not supported on this executor" }
        end
    end
end

local function decompileOne(ctx, item)
    local stats, out = ctx.stats, ctx.out.Scripts
    local row = { path = item.path, className = item.className }
    ctx.index[#ctx.index + 1] = row

    if not isClientReadable(item.inst, item.className) then
        stats.serverScripts = stats.serverScripts + 1
        row.status = "server"
        return
    end
    if ctx.suspects[item.path] then
        stats.suspects = stats.suspects + 1
        row.status = "crash-skipped"
        return
    end

    local key
    if Config.DedupeScripts then
        if Has.scripthash then
            local ok, hash = pcall(getscripthash, item.inst)
            if ok and typeof(hash) == "string" and hash ~= "" then key = "hash:" .. hash end
        end
        if not key and Has.bytecode then
            local ok, bytecode = pcall(getscriptbytecode, item.inst)
            if ok and typeof(bytecode) == "string" then
                if bytecode == "" then
                    row.status = "empty"
                    return
                end
                key = "bytecode:" .. bytecode
            end
        end
        if key and ctx.seenScripts[key] then
            stats.duplicates = stats.duplicates + 1
            row.status, row.sameAs = "same", ctx.seenScripts[key]
            return
        end
    end

    local ok, source, took = false, "no decompiler on this executor", 0
    if Has.decompile then
        State.record("ATTEMPT", item.path)
        local started = os.clock()
        local settled
        ok, source, settled = decompileWithTimeout(item.inst)
        took = os.clock() - started
        if settled then State.record("DONE", item.path)
        else ctx.suspects[item.path] = true end
    end

    if not ok or typeof(source) ~= "string" then
        local okWhy, why = pcall(tostring, source)
        if not okWhy then why = "decompiler returned an unreadable error" end
        if Dump.cancel then
            row.status, row.note = "cancelled", why
            stats.cancelled = stats.cancelled + 1
            return
        end
        local constants = Config.Constants and not Dump.cancel and constantsOf(item.inst)
        if Dump.cancel then
            row.status, row.note = "cancelled", "cancelled while reading constants"
            stats.cancelled = stats.cancelled + 1
            return
        end
        if constants then
            if key then ctx.seenScripts[key] = item.path end
            out:line("")
            out:line(THIN)
            row.line = out.lines + 1
            out:line(("-- [%s] %s%s  (strings only: %s)"):format(item.className, item.inst.Name, item.hidden and "  (hidden)" or "", why))
            out:line("-- " .. item.path)
            out:line(("-- %d string constants"):format(#constants))
            out:line(THIN)
            for _, text in ipairs(constants) do out:line("--   " .. serialize(text)) end
            row.lines, row.kb = #constants, 0
            row.status, row.note = "constants", why
            stats.constants = stats.constants + 1
            return
        end
        stats.failures = stats.failures + 1
        row.status, row.note = "failed", why
        return
    end

    if Config.DedupeScripts then
        key = key or ("source:" .. source)
        if ctx.seenScripts[key] then
            stats.duplicates = stats.duplicates + 1
            row.status, row.sameAs = "same", ctx.seenScripts[key]
            return
        end
        ctx.seenScripts[key] = item.path
    end

    local chars = #source
    if chars > Config.MaxScriptChars then
        row.truncated = true
        stats.truncated = stats.truncated + 1
        source = source:sub(1, Config.MaxScriptChars) .. ("\n-- [...truncated, %d chars total]"):format(chars)
    end
    if source:sub(-1) ~= "\n" then source = source .. "\n" end
    local _, lines = source:gsub("\n", "")

    out:line("")
    out:line(THIN)
    row.line = out.lines + 1
    out:line(("-- [%s] %s%s"):format(item.className, item.inst.Name, item.hidden and "  (hidden)" or ""))
    out:line("-- " .. item.path)
    out:line(("-- %d lines, %.1f KB, decompiled in %.2fs"):format(lines, chars / 1024, took))
    out:line(THIN)
    out:block(source, lines)
    row.lines, row.kb = lines, chars / 1024
    stats.scripts = stats.scripts + 1
    row.status = "ok"
end

local function sectionHeader(out, number, title)
    out:line("")
    out:line(RULE)
    out:line((" %d. %s"):format(number, title))
    out:line(RULE)
    out:line("")
end
local SECTION_HEADER_LINES = 5

local EXECUTOR_FUNCTIONS = {
    { "decompiling", { "decompile", "getscriptbytecode", "getscripthash", "getscriptclosure" } },
    { "memory", { "getgc", "getreg", "getrenv", "getsenv", "getloadedmodules", "getrunningscripts", "getnilinstances", "getinstances" } },
    { "functions", { "hookfunction", "hookmetamethod", "getnamecallmethod", "newcclosure", "checkcaller", "getcallingscript", "iscclosure", "islclosure", "clonefunction" } },
    { "debug", { "debug.info", "debug.getupvalues", "debug.setupvalue", "debug.getconstants", "debug.getprotos", "debug.getstack" } },
    { "signals", { "getconnections", "firesignal", "replicatesignal", "getcallbackvalue" } },
    { "actors", { "run_on_actor", "getactors", "create_comm_channel" } },
    { "world", { "fireclickdetector", "fireproximityprompt", "firetouchinterest", "isnetworkowner", "sethiddenproperty", "gethiddenproperty", "setsimulationradius" } },
    { "input", { "keypress", "keyrelease", "mouse1click", "mousemoverel", "isrbxactive" } },
    { "drawing", { "Drawing.new", "gethui", "cloneref", "getcustomasset" } },
    { "files", { "writefile", "appendfile", "readfile", "makefolder", "listfiles", "setclipboard" } },
    { "web", { "request", "http_request", "WebSocket.connect" } },
}

local function lookup(name)
    local current = getfenv and getfenv(0) or _G
    for part in name:gmatch("[^%.]+") do
        local ok, value = pcall(function() return current[part] end)
        if not ok or value == nil then
            if part == name:match("^[^%.]+") then
                local okEnv, fromEnv = pcall(function() return env[part] end)
                value = okEnv and fromEnv or nil
            end
            if value == nil then return nil end
        end
        current = value
    end
    return current
end

local function writeExecutor(out)
    for _, group in ipairs(EXECUTOR_FUNCTIONS) do
        local yes, no = {}, {}
        for _, name in ipairs(group[2]) do
            local found = lookup(name)
            if found ~= nil then yes[#yes + 1] = name else no[#no + 1] = name end
        end
        out:line("  " .. pad(group[1], 12) .. (#yes > 0 and table.concat(yes, " ") or "-"))
        if #no > 0 then out:line("  " .. pad("", 12) .. "missing: " .. table.concat(no, " ")) end
    end
end

local function writeInfo(ctx, out)
    local identify = has(identifyexecutor) and identifyexecutor or has(getexecutorname) and getexecutorname
    local okExec, executor = pcall(function() return identify and identify() end)
    local s, t = ctx.stats, ctx.timings

    out:line(pad("game", 12) .. (ctx.gameName or "?") .. (ctx.creator and ("   by " .. ctx.creator) or ""))
    out:line(pad("place", 12) .. ("%d   (game %d, version %d)"):format(game.PlaceId, game.GameId, game.PlaceVersion))
    out:line(pad("server", 12) .. ("%s   players %d/%d"):format(game.JobId, #Players:GetPlayers(), Players.MaxPlayers))
    out:line(pad("executor", 12) .. (okExec and tostring(executor or "?") or "?"))
    out:line(pad("generated", 12) .. os.date("%Y-%m-%d %H:%M:%S"))
    out:line(pad("took", 12) .. ("%.1fs   walk %.1fs, hidden %.1fs, decompile %.1fs, spy %.1fs"):format(
        t.total or 0, t.walk or 0, t.hidden or 0, t.decompile or 0, t.spy or 0))
    out:line("")
    out:line(pad("instances", 12) .. ("%d walked, %d repeats folded"):format(s.instances, s.collapsed))
    out:line(pad("scripts", 12) .. ("%d decompiled, %d strings only, %d same as another, %d roblox default, %d server-only, %d failed, %d crash-skipped")
        :format(s.scripts, s.constants, s.duplicates, s.defaults, s.serverScripts, s.failures, s.suspects))
    out:line(pad("found", 12) .. ("%d remotes, %d values, %d tags, %d interactables, %d texts, %d hidden"):format(
        s.remotes, s.values, s.tags, s.interactables, s.texts, s.hidden))
    out:line("")
    out:line("executor functions")
    writeExecutor(out)
    out:line("")
    local keys = {}
    for key in pairs(Config) do keys[#keys + 1] = key end
    table.sort(keys)
    out:line("settings")
    for _, key in ipairs(keys) do
        local value = Config[key]
        out:line("  " .. pad(key, 18) .. (typeof(value) == "table" and table.concat(value, ", ") or tostring(value)))
    end
end

local function listeners(signal)
    if not Has.connections then return nil end
    local ok, list = pcall(getconnections, signal)
    if not ok or type(list) ~= "table" then return nil end
    local order, counts = {}, {}
    for _, connection in ipairs(list) do
        local okFn, fn = pcall(function() return connection.Function end)
        local where = okFn and whereIs(fn) or nil
        where = where or "(no Lua function here: engine or another VM)"
        if not counts[where] then
            counts[where] = 0
            order[#order + 1] = where
        end
        counts[where] = counts[where] + 1
    end
    for i, where in ipairs(order) do
        order[i] = counts[where] > 1 and (where .. "  x" .. counts[where]) or where
    end
    return order, #list
end

local function writeRemotes(ctx, out)
    table.sort(ctx.remotes, function(a, b)
        if a.parent ~= b.parent then return a.parent < b.parent end
        return a.name < b.name
    end)
    if ctx.stats.remotesLeftOut > 0 then
        out:line(("(%d left out: bindables inside guis and other players' copies - they're in the tree)"):format(ctx.stats.remotesLeftOut))
        out:line("")
    end
    if Config.Listeners and not Has.connections then
        out:line("(listeners need getconnections, which this executor does not have)")
        out:line("")
    end
    local last
    for _, remote in ipairs(ctx.remotes) do
        if remote.parent ~= last then
            if last then out:line("") end
            out:line(remote.parent)
            last = remote.parent
        end
        out:line("    " .. pad(remote.className, 22) .. remote.name)
        if Config.Listeners then
            local inst, className = remote.inst, remote.className
            local signal
            pcall(function()
                if className == "RemoteEvent" or className == "UnreliableRemoteEvent" then
                    signal = inst.OnClientEvent
                elseif className == "BindableEvent" then
                    signal = inst.Event
                end
            end)
            if signal then
                local list = listeners(signal)
                if list and #list > 0 then
                    for _, where in ipairs(list) do out:line("        heard by " .. where) end
                end
            elseif className == "RemoteFunction" and Has.callbackvalue then
                local ok, fn = pcall(getcallbackvalue, inst, "OnClientInvoke")
                if ok and type(fn) == "function" then out:line("        answered by " .. (whereIs(fn) or "?")) end
            end
        end
    end
    if #ctx.remotes == 0 then out:line("none found") end
end

local function writeSignals(out)
    if not Has.connections then
        out:line("needs getconnections, which this executor does not have")
        return
    end
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local camera = workspace.CurrentCamera
    local groups = {
        { "input", {
            { "UserInputService.InputBegan", UserInputService.InputBegan },
            { "UserInputService.InputEnded", UserInputService.InputEnded },
            { "UserInputService.InputChanged", UserInputService.InputChanged },
            { "UserInputService.JumpRequest", UserInputService.JumpRequest },
            { "UserInputService.TouchStarted", UserInputService.TouchStarted },
            { "UserInputService.TouchEnded", UserInputService.TouchEnded },
        } },
        { "frame loop", {
            { "RunService.RenderStepped", RunService.RenderStepped },
            { "RunService.PreRender", RunService.PreRender },
            { "RunService.PreSimulation", RunService.PreSimulation },
            { "RunService.Stepped", RunService.Stepped },
            { "RunService.PostSimulation", RunService.PostSimulation },
            { "RunService.Heartbeat", RunService.Heartbeat },
        } },
        { "you", {
            { "LocalPlayer.CharacterAdded", LocalPlayer.CharacterAdded },
            { "LocalPlayer.Idled", LocalPlayer.Idled },
            { "LocalPlayer.Chatted", LocalPlayer.Chatted },
            { "Humanoid.Died", hum and hum.Died },
            { "Humanoid.StateChanged", hum and hum.StateChanged },
            { "Humanoid.HealthChanged", hum and hum.HealthChanged },
            { "Humanoid.Running", hum and hum.Running },
            { "Camera.CFrame changed", camera and camera:GetPropertyChangedSignal("CFrame") },
        } },
    }
    for gi, group in ipairs(groups) do
        if gi > 1 then out:line("") end
        out:line(group[1])
        out:line(THIN)
        for _, entry in ipairs(group[2]) do
            local name, signal = entry[1], entry[2]
            if signal then
                local list, total = listeners(signal)
                if list and total > 0 then
                    out:line(("%s  (%d)"):format(name, total))
                    for i, where in ipairs(list) do
                        if i > 12 then
                            out:line(("    ... +%d more"):format(#list - 12))
                            break
                        end
                        out:line("    " .. where)
                    end
                else
                    out:line(name .. "  (none)")
                end
            end
        end
    end
end

local function writeTags(out)
    local ok, tags = pcall(CollectionService.GetAllTags, CollectionService)
    if not ok or typeof(tags) ~= "table" or #tags == 0 then
        out:line("none found")
        return
    end
    table.sort(tags)
    for _, tag in ipairs(tags) do
        local okTagged, tagged = pcall(CollectionService.GetTagged, CollectionService, tag)
        tagged = okTagged and tagged or {}
        out:line(("%s  (%d)"):format(tag, #tagged))
        for i = 1, math.min(#tagged, 4) do out:line("    " .. safePath(tagged[i])) end
        if #tagged > 4 then out:line(("    ... +%d more"):format(#tagged - 4)) end
    end
    local char = LocalPlayer.Character
    local mine = char and readTags(char)
    out:line("")
    out:line("your character's tags: " .. (mine and table.concat(mine, ", ") or "none"))
end

local function describeTable(out, tbl, indent, limit)
    local keys = {}
    for key in pairs(tbl) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local holders = {}
    for _, key in ipairs(keys) do
        local value = rawget(tbl, key)
        if type(value) == "table" then
            holders[value] = holders[value] or {}
            table.insert(holders[value], tostring(key))
        end
    end
    local printed = {}
    for i, key in ipairs(keys) do
        if i > limit then
            out:line(indent .. ("... +%d more"):format(#keys - limit))
            break
        end
        local value = rawget(tbl, key)
        local label = pad(tostring(key), 28)
        local shared = type(value) == "table" and holders[value]
        if shared and #shared > 1 then
            if printed[value] then continue end
            printed[value] = true
            local names = table.concat(shared, ", ")
            if #names > 240 then names = names:sub(1, 240) .. "..." end
            label = ("%s  (%d keys, all the same table)  "):format(names, #shared)
        end
        if type(value) == "function" then
            local where = whereIs(value)
            local line = where and where:match(":(%d+)$")
            out:line(indent .. label .. signature(value) .. (line and ("  @line " .. line) or ""))
        elseif type(value) == "table" then
            local count = 0
            for _ in pairs(value) do count = count + 1 end
            out:line(indent .. label .. ("table (%d)  %s"):format(count, serialize(value, 2)))
        else
            out:line(indent .. label .. serialize(value))
        end
    end
end

local function writeGlobals(out)
    if not Has.renv then
        out:line("needs getrenv, which this executor does not have")
        return
    end
    local ok, renv = pcall(getrenv)
    if not ok or type(renv) ~= "table" then
        out:line("getrenv failed")
        return
    end
    for _, name in ipairs({ "_G", "shared" }) do
        local okValue, value = pcall(function() return renv[name] end)
        out:line(name)
        if okValue and type(value) == "table" and next(value) ~= nil then
            describeTable(out, value, "    ", 80)
        else
            out:line("    (empty)")
        end
        out:line("")
    end
end

local function requireWithTimeout(inst)
    local done, ok, result = false, false, nil
    local worker
    local started = os.clock()
    worker = task.spawn(function()
        ok, result = pcall(require, inst)
        done = true
        if Dump.pendingWorker == worker then Dump.pendingWorker = nil end
    end)
    while not done do
        if Dump.cancel or os.clock() - started >= Config.ModuleTimeout then
            local message = Dump.cancel and "cancelled" or ("timed out after %.1fs"):format(Config.ModuleTimeout)
            if has(task.cancel) then pcall(task.cancel, worker) end
            local okStatus, status = pcall(coroutine.status, worker)
            if not done and (not okStatus or status ~= "dead") and has(coroutine.close) then
                pcall(coroutine.close, worker)
                okStatus, status = pcall(coroutine.status, worker)
            end
            if not done and (not okStatus or status ~= "dead") then
                Dump.pendingWorker, Dump.cancel = worker, true
                message = message .. "; worker could not be stopped, ending this run"
            end
            return false, message
        end
        task.wait()
    end
    return ok, result
end

local function writeModules(ctx, out)
    if not Has.loadedmodules then
        out:line("needs getloadedmodules, which this executor does not have")
        return
    end
    local ok, list = pcall(getloadedmodules)
    if not ok or type(list) ~= "table" then
        out:line("getloadedmodules failed")
        return
    end
    local modules = {}
    for _, module in ipairs(list) do
        if typeof(module) == "Instance" and module.ClassName == "ModuleScript"
            and not (Config.SkipDefaults and isDefaultScript(module)) then
            modules[#modules + 1] = { inst = module, path = safePath(module) }
        end
    end
    table.sort(modules, function(a, b) return a.path < b.path end)
    out:line(("%d loaded modules"):format(#modules))
    ctx.stats.modules = 0
    for _, module in ipairs(modules) do
        if Dump.cancel then return end
        out:line("")
        out:line(module.path)
        local okRequire, result = requireWithTimeout(module.inst)
        if not okRequire then
            out:line("    require failed: " .. tostring(result))
        elseif type(result) == "table" then
            describeTable(out, result, "    ", 60)
        elseif type(result) == "function" then
            out:line("    returns " .. signature(result))
        else
            out:line("    returns " .. serialize(result))
        end
        ctx.stats.modules = ctx.stats.modules + 1
        Budget.check()
    end
end

local function writeInteractables(ctx, out)
    local groups = {
        { "ProximityPrompt", "proximity prompts" },
        { "ClickDetector", "click detectors" },
        { "TouchTransmitter", "touch parts" },
    }
    local any = false
    for _, group in ipairs(groups) do
        local first = true
        for _, item in ipairs(ctx.interactables) do
            if item.className == group[1] then
                if first then
                    if any then out:line("") end
                    out:line(group[2])
                    first, any = false, true
                end
                if item.className == "ProximityPrompt" then
                    local ok, text = pcall(function()
                        return ("action=%q object=%q hold=%ss range=%s enabled=%s"):format(
                            item.inst.ActionText, item.inst.ObjectText, fmt(item.inst.HoldDuration),
                            fmt(item.inst.MaxActivationDistance), tostring(item.inst.Enabled))
                    end)
                    out:line("    " .. item.path .. "   " .. (ok and text or ""))
                elseif item.className == "ClickDetector" then
                    local ok, range = pcall(function() return item.inst.MaxActivationDistance end)
                    out:line("    " .. item.path .. "   range=" .. (ok and fmt(range) or "?"))
                else
                    out:line("    " .. item.path:gsub("%.TouchInterest$", ""))
                end
            end
        end
    end
    if not any then out:line("none found") end
end

local function writeUiText(ctx, out)
    if #ctx.texts == 0 then
        out:line("none found")
        return
    end
    local groups, order = {}, {}
    for _, row in ipairs(ctx.texts) do
        local gui = row.path:match("PlayerGui%.([^%.]+)") or "?"
        local group = groups[gui]
        if not group then
            group = { rows = {}, seen = {} }
            groups[gui] = group
            order[#order + 1] = gui
        end
        local key = row.kind .. "\0" .. row.text
        if group.seen[key] then
            group.seen[key].count = group.seen[key].count + 1
        else
            local entry = { row = row, count = 1 }
            group.seen[key] = entry
            group.rows[#group.rows + 1] = entry
        end
    end
    for i, gui in ipairs(order) do
        if i > 1 then out:line("") end
        out:line(gui)
        for _, entry in ipairs(groups[gui].rows) do
            local row = entry.row
            out:line(("    %-7s %s%s   %s"):format(row.kind, serialize(row.text), entry.count > 1 and ("  x" .. entry.count) or "",
                row.path:match("([^%.]+%.[^%.]+)$") or row.path))
        end
    end
end

local function writeHidden(ctx, out)
    for _, item in ipairs(ctx.hidden) do
        if item.note then
            out:line(item.note)
        else
            out:line(pad("[" .. item.className .. "]", 18) .. pad(item.label, 16) .. item.path)
        end
    end
    if #ctx.hidden == 0 then out:line("none found") end
end

local function writeTreeSummary(ctx, out)
    local list = {}
    for className, count in pairs(ctx.classCount) do list[#list + 1] = { className, count } end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    local parts = {}
    for i = 1, math.min(12, #list) do parts[i] = ("%s %d"):format(list[i][1], list[i][2]) end
    out:line("most common: " .. table.concat(parts, ", "))
    out:line("")
end

local function writeIndex(ctx, out, bodyAt, scriptsFile)
    local rows = ctx.index
    local written, other = {}, {}
    for _, row in ipairs(rows) do
        if row.status == "ok" or row.status == "constants" or row.status == "truncated" then written[#written + 1] = row else other[#other + 1] = row end
    end
    out:line(("%d written below%s, %d not written"):format(#written,
        scriptsFile and (" in " .. scriptsFile) or "", #other))
    out:line("")
    out:line(padLeft("line", 7) .. padLeft("lines", 7) .. padLeft("KB", 7) .. "   " .. pad("type", 14) .. "path")
    for _, row in ipairs(written) do
        out:line(padLeft(tostring(bodyAt + row.line - 1), 7) .. padLeft(tostring(row.lines), 7)
            .. padLeft(row.status == "constants" and "strs" or ("%.1f"):format(row.kb), 7) .. "   " .. pad(row.className, 14) .. row.path
            .. ((row.truncated or row.status == "truncated") and "  [truncated]" or ""))
    end
    if #other > 0 then
        out:line("")
        out:line("not written")
        for _, row in ipairs(other) do
            local why = row.status == "same" and ("same as " .. tostring(row.sameAs))
                or row.status == "failed" and ("decompile failed: " .. (row.note or "?"))
                or row.status == "server" and "server script, never sent to the client"
                or row.status == "crash-skipped" and "crashed a previous dump - forget crash skips to retry"
                or row.status or "unknown"
            out:line("    " .. pad(row.className, 14) .. row.path)
            out:line("    " .. string.rep(" ", 14) .. "-> " .. why)
        end
    end
end

local function writeOutputs(ctx)
    local sections = {}
    local metadata = {}
    local manifestPath = filePath("Manifest.txt")
    ctx.outputParts, ctx.manifestPath = metadata, manifestPath
    local function writeManifest(status, primaryPath)
        local manifest = Buffer.new()
        manifest:line(VERSION .. " OUTPUT MANIFEST")
        manifest:line("status: " .. status)
        manifest:line("primary file: " .. (primaryPath or "pending"))
        manifest:line("place: " .. tostring(game.PlaceId) .. "   generated: " .. os.date("%Y-%m-%d %H:%M:%S"))
        if ctx.cancelled then manifest:line("stopped early: output contains only work completed before cancellation") end
        if ctx.error then manifest:line("run error: " .. tostring(ctx.error)) end
        manifest:line("")
        manifest:line("COMPLETE means the run finished; script failures, truncation and configured filters still apply.")
        manifest:line("This is a snapshot of objects and code visible to this client at capture time.")
        manifest:line("Server-only source and objects never replicated to the client cannot be included.")
        manifest:line("Streaming can leave unloaded parts of the map absent; objects can change during capture.")
        manifest:line("Selected roots: " .. table.concat(Config.Roots, ", "))
        manifest:line(("Tree depth limit: %s; script byte limit: %s; file byte limit: %s"):format(
            tostring(Config.MaxDepth), tostring(Config.MaxScriptChars), tostring(math.floor(Config.MaxFileMB * 1024 * 1024))))
        manifest:line("Filters: OnlyMyCharacter=" .. tostring(Config.OnlyMyCharacter) .. ", OnlyMyPlayer=" .. tostring(Config.OnlyMyPlayer)
            .. ", SkipDefaults=" .. tostring(Config.SkipDefaults) .. ", Hidden=" .. tostring(Config.Hidden))
        manifest:line("Immediate children excluded at depth limit: " .. tostring(ctx.stats.depthLimited or 0)
            .. " (their unvisited descendants are not counted)")
        manifest:line("Repeated sibling roots folded in tree presentation: " .. tostring(ctx.stats.collapsed or 0)
            .. " (their contents were still scanned within the configured depth)")
        manifest:line("")
        manifest:line("PARTS (line numbers are aggregate within each logical file)")
        manifest:line("For an ordinary part, local line = aggregate line - first line + 1.")
        manifest:line("A continuation shares a line with its neighbor; join parts in the listed order to reconstruct it.")
        manifest:line("Manifest.txt is metadata and is not split by the data-file limit.")
        for _, item in ipairs(metadata) do
            manifest:line(("%s | bytes=%d | lines=%d-%d | continues-from-previous=%s | continues-to-next=%s | logical=%s"):format(
                item.path, item.bytes, item.firstLine, item.lastLine, tostring(item.startsMidLine), tostring(item.endsMidLine), item.logicalPath))
        end
        manifest:line("")
        manifest:line("SECTIONS")
        for _, section in ipairs(sections) do
            manifest:line(section.title .. " | count=" .. tostring(section.count or "n/a")
                .. " | lines=" .. tostring(section == ctx.indexSection and section.lines or (section.out and section.out.lines) or 0))
        end
        local statuses = {}
        for _, row in ipairs(ctx.index) do
            local key = (row.truncated or row.status == "truncated") and "truncated" or (row.status or "unknown")
            statuses[key] = (statuses[key] or 0) + 1
        end
        local keys = {}
        for key in pairs(statuses) do keys[#keys + 1] = key end
        table.sort(keys)
        manifest:line("")
        manifest:line("SCRIPT RESULTS")
        for _, key in ipairs(keys) do manifest:line(key .. ": " .. tostring(statuses[key])) end
        writeAll(manifestPath, { anonymise(manifest:text()) })
    end
    local function save(path, chunks)
        local count, parts = writeChunks(path, chunks)
        for _, item in ipairs(parts) do
            item.logicalPath = path
            metadata[#metadata + 1] = item
        end
        return count
    end
    local function finish(primaryPath)
        writeManifest(ctx.complete == true and "COMPLETE" or "PARTIAL", primaryPath)
        return primaryPath, manifestPath
    end
    local function add(key, title, build, count)
        if key and not Config[key] then return end
        local out = Buffer.new()
        build(out)
        sections[#sections + 1] = { key = key or title, title = title, out = out, count = count }
        return sections[#sections]
    end

    add("Info", "GAME INFO", function(out) writeInfo(ctx, out) end)
    add("Spy", "REMOTE SPY", function(out) Spy.write(out) end)
    add("Remotes", "REMOTES (and who listens)", function(out) writeRemotes(ctx, out) end, #ctx.remotes)
    add("Signals", "SIGNALS (who listens to input, the frame loop and you)", function(out) writeSignals(out) end)
    add("Tags", "TAGS", function(out) writeTags(out) end)
    add("Globals", "GLOBALS (the game's _G and shared)", function(out) writeGlobals(out) end)
    if ctx.modules then
        sections[#sections + 1] = { key = "Modules", title = "MODULES (what each loaded module returns)", out = ctx.modules }
    end
    add("Interactables", "INTERACTABLES", function(out) writeInteractables(ctx, out) end, #ctx.interactables)
    local values = ctx.out.Values
    if Config.Values then
        if values.lines == 0 then values:line("none found") end
        sections[#sections + 1] = { key = "Values", title = "VALUES + ATTRIBUTES", out = values, count = ctx.stats.values }
    end
    add("UiText", "UI TEXT (your screen)", function(out) writeUiText(ctx, out) end, #ctx.texts)
    add("Hidden", "HIDDEN (nil parented, loaded or running, not in the tree)", function(out) writeHidden(ctx, out) end, #ctx.hidden)
    local index
    if Config.Scripts then
        index = { key = "Index", title = "SCRIPT INDEX", out = nil, count = ctx.stats.scripts + ctx.stats.constants }
        sections[#sections + 1] = index
        ctx.indexSection = index
    end
    if Config.Tree then
        local tree = Buffer.new()
        writeTreeSummary(ctx, tree)
        tree:block(ctx.out.Tree:text())
        sections[#sections + 1] = { key = "Tree", title = "INSTANCE TREE", out = tree, count = ctx.stats.instances }
    end
    local scripts
    if Config.Scripts then
        scripts = { key = "Scripts", title = "SCRIPTS", out = ctx.out.Scripts, count = ctx.stats.scripts + ctx.stats.constants }
        if scripts.out.lines == 0 then scripts.out:line("none written") end
        sections[#sections + 1] = scripts
    end

    if index then
        local probe = Buffer.new()
        writeIndex(ctx, probe, 1)
        index.lines = probe.lines
    end

    local function titled(section)
        return section.count and ("%s  (%d)"):format(section.title, section.count) or section.title
    end
    local gameName = ctx.gameName or "?"
    writeManifest("WRITING")

    if Config.Output == "Split files" then
        local contents = Buffer.new()
        contents:line(RULE)
        contents:line(("  %s  -  %s  (place %d, %s)"):format(VERSION, gameName, game.PlaceId, ctx.complete == true and "COMPLETE" or "PARTIAL"))
        contents:line(RULE)
        contents:line("")
        for _, section in ipairs(sections) do
            section.file = section.key .. ".txt"
            contents:line("  " .. pad(titled(section), 60) .. filePath(section.file))
        end
        if index then
            contents:line("")
            contents:line(RULE)
            contents:line(" SCRIPT INDEX  (aggregate line numbers are in " .. filePath("Scripts.txt") .. ")")
            contents:line(RULE)
            contents:line("")
            writeIndex(ctx, contents, 1, filePath("Scripts.txt"))
        end
        local primaryPath = filePath("Index.txt")
        save(primaryPath, { contents:text() })
        for _, section in ipairs(sections) do
            if section ~= index then
                save(filePath(section.file), { section.out:text() })
            end
        end
        return finish(primaryPath)
    end

    local headLines = 5 + 4 + #sections
    local line = headLines + 1
    for number, section in ipairs(sections) do
        section.number = number
        section.titleAt = line + 2
        section.bodyAt = line + SECTION_HEADER_LINES
        local bodyLines = section == index and index.lines or section.out.lines
        line = line + SECTION_HEADER_LINES + bodyLines
    end

    local head = Buffer.new()
    head:line(RULE)
    head:line(("  %s  -  %s"):format(VERSION, gameName))
    head:line(("  place %d  -  game %d  -  version %d  -  %s  -  %s"):format(game.PlaceId, game.GameId, game.PlaceVersion,
        os.date("%Y-%m-%d %H:%M"), ctx.complete == true and "COMPLETE" or "PARTIAL"))
    head:line(RULE)
    head:line("")
    head:line("CONTENTS" .. string.rep(" ", WIDTH - 8 - 4) .. "line")
    head:line("")
    for _, section in ipairs(sections) do
        local label = ("  %d. %s "):format(section.number, titled(section))
        local at = " " .. tostring(section.titleAt)
        head:line(label .. string.rep(".", math.max(2, WIDTH - #label - #at)) .. at)
    end
    head:line("")
    head:line("")

    local chunks = { head:text() }
    for _, section in ipairs(sections) do
        local header = Buffer.new()
        sectionHeader(header, section.number, titled(section))
        if section == index then
            local body = Buffer.new()
            writeIndex(ctx, body, scripts.bodyAt)
            chunks[#chunks + 1] = header:text() .. body:text()
        else
            chunks[#chunks + 1] = header:text() .. section.out:text()
        end
    end
    local path = filePath("Dump.txt")
    save(path, chunks)
    return finish(path)
end

local Session = {
    running = false,
    stop = function() Dump.cancel = true end,
    busy = function() return Dump.running or Dump.pendingWorker ~= nil end,
}
env.__DumperSession = Session

function Dump.run(ui)
    ui = typeof(ui) == "table" and ui or {}
    local function phase(name, fraction, detail)
        if ui.phase then pcall(ui.phase, name, fraction, detail) end
    end
    local function log(text, kind)
        if ui.log then pcall(ui.log, text, kind) end
    end

    if Dump.running or Dump.pendingWorker then return false, "a dump or an unfinished worker is already running" end
    if not Has.writefile then
        log("writefile is not available on this executor", "bad")
        if ui.done then pcall(ui.done, false, nil, "", "writefile is not available on this executor") end
        return false, "writefile is not available on this executor"
    end
    Dump.running, Dump.cancel, Dump.lastOutput = true, false, nil
    Session.running = true
    local started = os.clock()
    local ctx, stats, statePath

    local ok, err = pcall(function()
        Config = normaliseConfig(UserConfig)
        ensureFolder()
        ctx = newContext()
        stats = ctx.stats
        Dump.ctx = ctx
        ctx.infoWorker = task.spawn(function()
            local okInfo, info = pcall(function()
                local service = game:GetService("MarketplaceService")
                if has(service.GetProductInfoAsync) then
                    return service:GetProductInfoAsync(game.PlaceId)
                end
                return service:GetProductInfo(game.PlaceId)
            end)
            if okInfo and typeof(info) == "table" then
                ctx.gameName = info.Name
                ctx.creator = typeof(info.Creator) == "table" and info.Creator.Name or nil
            end
        end)
        statePath = filePath("State.txt")
        ctx.suspects = loadSuspects(statePath)
        State.open(statePath, ctx.suspects)
        if Config.Spy then
            Spy.start()
            log(Spy.hooked and "remote spy recording, in and out" or "remote spy recording, incoming only")
        end

        Budget.start()
        local wanted = {}
        for _, name in ipairs(Config.Roots) do wanted[name] = true end
        local roots = {}
        for _, name in ipairs(ROOT_ORDER) do
            if wanted[name] then
                local okService, service = pcall(game.GetService, game, name)
                if okService and service then roots[#roots + 1] = service end
            end
        end
        for i = #roots, 1, -1 do
            ctx.stack[#ctx.stack + 1] = {
                inst = roots[i], path = roots[i].Name, depth = 0, prefix = "", isLast = i == #roots,
            }
        end
        log(("walking %s"):format(plural(#roots, "service")))
        local walkStart = os.clock()
        local function walkProgress()
            local done = stats.instances
            phase("walking", done / math.max(1, done + #ctx.stack),
                ("%d instances, %d scripts found"):format(done, #ctx.queue))
            if ui.stats then pcall(ui.stats, ctx) end
        end
        local stack = ctx.stack
        while #stack > 0 and not Dump.cancel do
            local frame = stack[#stack]
            stack[#stack] = nil
            visit(ctx, frame)
            Budget.check(walkProgress)
        end
        ctx.timings.walk = os.clock() - walkStart
        log(("walked %d instances in %.1fs"):format(stats.instances, ctx.timings.walk))

        if Config.Hidden and not Dump.cancel then
            phase("hidden", 0, "nil parented, loaded and running scripts")
            local hiddenStart = os.clock()
            collectHidden(ctx)
            ctx.timings.hidden = os.clock() - hiddenStart
            log(("found %d hidden"):format(stats.hidden))
        end

        if Config.Tags then
            local okTags, all = pcall(CollectionService.GetAllTags, CollectionService)
            stats.tags = okTags and typeof(all) == "table" and #all or 0
        end

        if Config.Modules and not Dump.cancel then
            phase("modules", 0, "reading what each loaded module returns")
            ctx.modules = Buffer.new()
            writeModules(ctx, ctx.modules)
            log(("read %s"):format(plural(ctx.stats.modules or 0, "module")))
        end

        if Config.Scripts and not Dump.cancel then
            local queue = ctx.queue
            for _, item in ipairs(queue) do
                item.rank = item.hidden and 99 or (SCRIPT_ROOT_RANK[item.path:match("^[^%.]+")] or 50)
            end
            table.sort(queue, function(a, b)
                if a.rank ~= b.rank then return a.rank < b.rank end
                return a.path < b.path
            end)
            local decompileStart = os.clock()
            log(("decompiling %s"):format(plural(#queue, "script")))
            for i, item in ipairs(queue) do
                if Dump.cancel then break end
                decompileOne(ctx, item)
                Budget.check(function()
                    phase("decompiling", i / #queue, ("%d / %d  -  %s"):format(i, #queue, item.inst.Name))
                    if ui.stats then pcall(ui.stats, ctx) end
                end)
            end
            ctx.timings.decompile = os.clock() - decompileStart
            log(("decompiled %d, %d strings only, %d same as another, %d failed, in %.1fs"):format(
                stats.scripts, stats.constants, stats.duplicates, stats.failures, ctx.timings.decompile))
            if stats.failures > 0 then log(("%d scripts failed to decompile - see the index"):format(stats.failures), "bad") end
        end

        if Config.Spy then
            local spyStart = os.clock()
            local remaining = Config.SpySeconds - (os.clock() - started)
            while remaining > 0 and not Dump.cancel do
                phase("recording remotes", 1 - remaining / math.max(1, Config.SpySeconds),
                    ("%ds left - keep playing"):format(math.ceil(remaining)))
                task.wait(0.25)
                remaining = Config.SpySeconds - (os.clock() - started)
            end
            Spy.stop()
            ctx.timings.spy = os.clock() - spyStart
        end
    end)
    pcall(Spy.stop)
    if ctx and ctx.infoWorker and has(task.cancel) then pcall(task.cancel, ctx.infoWorker) end

    local okWrite, output, manifest = false, nil, nil
    if ctx then
        ctx.complete = ok and not Dump.cancel
        ctx.cancelled = Dump.cancel
        ctx.error = not ok and tostring(err) or nil
        ctx.timings.total = os.clock() - started
        phase("writing", 1, ctx.complete and "" or "saving partial dump")
        okWrite, output, manifest = pcall(writeOutputs, ctx)
        if ui.stats then pcall(ui.stats, ctx) end
        if statePath and ctx.suspects then
            local okState, stateError = pcall(State.finish, ctx.suspects)
            if not okState then log("crash state could not be saved: " .. tostring(stateError), "bad") end
        end
    end

    local summary = stats and ("%d instances - %d scripts (+%d same) - %d remotes - %d values - %.1fs"):format(
        stats.instances, stats.scripts, stats.duplicates, stats.remotes, stats.values, os.clock() - started) or ""
    local success = ok and okWrite
    local message = not ok and ("errored: " .. tostring(err))
        or not okWrite and ("writing failed: " .. tostring(output))
        or (Dump.cancel and "stopped early, saved what it had" or "done")
    Dump.lastOutput = okWrite and output or nil
    Dump.lastResult = {
        success = success, complete = ctx and ctx.complete and okWrite or false,
        output = Dump.lastOutput, manifest = okWrite and manifest or nil,
        summary = summary, message = message,
    }
    Dump.running, Session.running = false, false
    Config = UserConfig
    log(message, success and "good" or "bad")
    if ui.done then pcall(ui.done, success, Dump.lastOutput, summary, message) end
    return success, Dump.lastResult
end
local function forgetCrashes()
    if Dump.running then return false, "stop the dump before clearing crash state" end
    local ok, err = pcall(writeAll, filePath("State.txt"), { "" })
    return ok, err
end

env.Dumper = {
    Config = UserConfig,
    Run = Dump.run,
    Stop = function() Dump.cancel = true end,
    ForgetCrashes = forgetCrashes,
    IsRunning = Session.busy,
    LastResult = function() return Dump.lastResult end,
}

local function startHeadless()
    task.spawn(Dump.run, {
        log = function(text, kind)
            if kind == "bad" then warn("[Dumper] " .. text) else print("[Dumper] " .. text) end
        end,
        done = function(_, output, summary, message)
            print("[Dumper] " .. (message or "") .. (summary and (" - " .. summary) or "")
                .. (output and ("\n[Dumper] saved to " .. output) or ""))
        end,
    })
end

if UserConfig.NoUI then
    if UserConfig.AutoStart then startHeadless() end
    return
end

local UI_URL = "https://raw.githubusercontent.com/iamdookie1/Ui3/5a1ac6ef1d124d84f62557e77bfa1d74cf24544d/Ui.lua"
local okLibrary, Library = pcall(function()
    local chunk, compileError = loadstring(game:HttpGet(UI_URL))
    if not chunk then error("UI did not compile: " .. tostring(compileError)) end
    local library = chunk()
    if typeof(library) ~= "table" or not has(library.CreateWindow) or not has(library.OnUnload) then
        error("UI returned an incompatible library")
    end
    return library
end)
if not okLibrary then
    warn("[Dumper] Menu unavailable: " .. tostring(Library) .. ". Dumper.Run() still works.")
    if UserConfig.AutoStart then startHeadless() end
    return
end

local Window = Library:CreateWindow({
    Title = 'Dumper',
    Footer = VERSION,
    Icon = 'database',
    ToggleKeybind = Enum.KeyCode.RightShift,
    Theme = 'Ember',
    ConfigFolder = 'Dumper',
})

local function unloadMenu()
    Dump.cancel = true
    pcall(function() Library:Unload() end)
end
env.__DumperUnload = unloadMenu
Library:OnUnload(function()
    Dump.cancel = true
    if env.__DumperUnload == unloadMenu then env.__DumperUnload = nil end
end)

local LOG_COLORS = {
    good = Color3.fromRGB(126, 217, 87),
    bad = Color3.fromRGB(255, 96, 106),
    info = Color3.fromRGB(150, 200, 255),
}

local Run = {}

do
    local Tab = Window:AddTab('Dump', 'database', 'Dump the game to a file')

    local run = Tab:AddBigGroupbox('Run', 'play')
    Run.cards = run:AddStatCards('dumper_cards', {
        Cards = {
            { Title = 'Instances', Value = '0', Icon = 'boxes' },
            { Title = 'Scripts', Value = '0', Icon = 'file-code' },
            { Title = 'Remotes', Value = '0', Icon = 'radio' },
            { Title = 'Elapsed', Value = '-', Icon = 'timer' },
        },
    })
    Run.progress = run:AddProgressBar('dumper_progress', { Text = 'idle', Max = 100, Percent = true })
    Run.status = run:AddLabel('ready - press Start dump', true)
    local start = run:AddButton({
        Text = 'Start dump',
        Func = function()
            if Dump.running then return end
            Run.start()
        end,
    })
    start:AddButton({
        Text = 'Stop',
        Func = function()
            if Dump.running then
                Dump.cancel = true
                Run.log:Log('stopping...', LOG_COLORS.info)
            end
        end,
    })
    Run.saved = run:AddLabel('saved to: -', true)
    run:AddButton({
        Text = 'Copy file path',
        Func = function()
            if Dump.lastOutput and Has.clipboard then
                pcall(setclipboard, Dump.lastOutput)
                Library:Notify({ Title = 'Dumper', Description = 'path copied', Time = 3 })
            end
        end,
    })
    Run.log = run:AddLog('dumper_log', { Height = 150, MaxLines = 120, Timestamps = true })

    local what = Tab:AddLeftGroupbox('What goes in', 'list-checks')
    local function toggle(box, key, text, tooltip)
        box:AddToggle('dumper_' .. key, {
            Text = text,
            Tooltip = tooltip,
            Default = UserConfig[key],
            Callback = function(state) UserConfig[key] = state end,
        })
    end
    toggle(what, 'Info', 'Game info', 'place, server, timings, and which executor functions this client has')
    toggle(what, 'Scripts', 'Scripts', 'decompiles every client script, one copy of each')
    toggle(what, 'Constants', 'Strings when decompile fails', 'a script that won\'t decompile gets its string constants instead (remote and attribute names, messages)')
    toggle(what, 'Tree', 'Instance tree')
    toggle(what, 'Remotes', 'Remotes')
    toggle(what, 'Listeners', 'Who listens to each remote', 'the script and line connected to each remote (needs getconnections)')
    toggle(what, 'Signals', 'Input + frame loop listeners', 'which scripts listen to input, RenderStepped / Heartbeat and your character')
    toggle(what, 'Tags', 'Tags', 'every CollectionService tag, also shown in the tree')
    toggle(what, 'Globals', 'The game\'s _G and shared')
    toggle(what, 'Modules', 'Module APIs (careful)', 'what each loaded module returns: its functions and fields. require on a module only loaded in another VM (an actor) runs it again here, which can double up what it does')
    toggle(what, 'Values', 'Values + attributes')
    toggle(what, 'Attributes', 'Attributes in the tree')
    toggle(what, 'Interactables', 'Prompts, click + touch parts')
    toggle(what, 'UiText', 'Text on your screen')
    toggle(what, 'Hidden', 'Hidden scripts', 'nil parented, loaded and running scripts that aren\'t in the tree')

    local spy = Tab:AddRightGroupbox('Remote spy', 'radar')
    toggle(spy, 'Spy', 'Record remotes while dumping', 'every remote the game fires and receives, with the real arguments and the script that fired it')
    spy:AddSlider('dumper_spy_seconds', {
        Text = 'Record for',
        Min = 5, Max = 180, Default = UserConfig.SpySeconds, Rounding = 0, Suffix = 's',
        Callback = function(value) UserConfig.SpySeconds = tonumber(value) or UserConfig.SpySeconds end,
    })
    spy:AddLabel('The dump waits out this window at the end, so play normally while it runs: use tools, attack, buy, open menus.', true)

    local out = Tab:AddRightGroupbox('Output', 'file-text')
    out:AddDropdown('dumper_output', {
        Text = 'File',
        Values = { 'Single file', 'Split files' },
        Default = UserConfig.Output,
        Tooltip = 'single file: Dumper/<place id>/Dump.txt with a contents page and a script index giving the line each part starts on. split files: one file per section plus Index.txt',
        Callback = function(value) UserConfig.Output = value or UserConfig.Output end,
    })
    toggle(out, 'HideName', 'Hide my name in the file', 'your username is written as <you>, so a dump can be shared')
    out:AddSlider('dumper_maxfile', {
        Text = 'Max file size',
        Min = 0, Max = 95, Default = UserConfig.MaxFileMB, Rounding = 0, Suffix = ' MB',
        Tooltip = 'bigger files are written in parts (Dump.txt, Dump_2.txt ...), cut at a line break. 24 fits GitHub web upload (25 MB). 0 = never split',
        Callback = function(value) UserConfig.MaxFileMB = tonumber(value) or UserConfig.MaxFileMB end,
    })

    Tab = Window:AddTab('Options', 'sliders-horizontal', 'Speed, filters and limits')

    local speed = Tab:AddLeftGroupbox('Speed', 'gauge')
    speed:AddDropdown('dumper_speed', {
        Text = 'Speed',
        Values = { 'Smooth', 'Fast', 'Max' },
        Default = UserConfig.Speed,
        Tooltip = 'how much of each frame the dump gets. smooth keeps the game playable, max finishes soonest but the game stutters',
        Callback = function(value) if SPEEDS[value] then UserConfig.Speed = value end end,
    })

    local filters = Tab:AddLeftGroupbox('Filters', 'filter')
    toggle(filters, 'SkipDefaults', 'Skip roblox default scripts')
    toggle(filters, 'DedupeScripts', 'One copy of identical scripts')
    toggle(filters, 'OnlyMyCharacter', 'Only my character')
    toggle(filters, 'OnlyMyPlayer', 'Only my player')
    toggle(filters, 'CollapseRepeats', 'Fold 4+ identical siblings')
    toggle(filters, 'SkipGuiValues', 'Skip values inside guis')

    local where = Tab:AddRightGroupbox('Where to look', 'map')
    where:AddDropdown('dumper_roots', {
        Text = 'Services',
        Values = ROOT_ORDER,
        Multi = true,
        Default = UserConfig.Roots,
        Callback = function(value)
            if typeof(value) ~= "table" then return end
            local list = {}
            for _, name in ipairs(ROOT_ORDER) do
                if value[name] == true or table.find(value, name) then list[#list + 1] = name end
            end
            UserConfig.Roots = list
        end,
    })

    local limits = Tab:AddRightGroupbox('Limits', 'ruler')
    limits:AddSlider('dumper_depth', {
        Text = 'Max tree depth', Min = 4, Max = 60, Default = UserConfig.MaxDepth, Rounding = 0,
        Callback = function(value) UserConfig.MaxDepth = tonumber(value) or UserConfig.MaxDepth end,
    })
    limits:AddSlider('dumper_chars', {
        Text = 'Max KB per script', Min = 10, Max = 1000, Default = math.floor(UserConfig.MaxScriptChars / 1000), Rounding = 0, Suffix = ' KB',
        Callback = function(value) UserConfig.MaxScriptChars = (tonumber(value) or 500) * 1000 end,
    })
    limits:AddSlider('dumper_timeout', {
        Text = 'Decompile timeout', Min = 2, Max = 60, Default = UserConfig.DecompileTimeout, Rounding = 0, Suffix = 's',
        Callback = function(value) UserConfig.DecompileTimeout = tonumber(value) or UserConfig.DecompileTimeout end,
    })

    local crash = Tab:AddLeftGroupbox('Crash guard', 'shield')
    crash:AddLabel('A decompile that crashes the game is remembered, and that script is skipped next run so the dump can finish.', true)
    crash:AddButton({
        Text = 'Forget crash skips',
        DoubleClick = true,
        Func = function()
            if Dump.running then return end
            local ok, err = forgetCrashes()
            Run.log:Log(ok and 'crash skips cleared - every script gets retried'
                or ('could not clear crash skips: ' .. tostring(err)), ok and LOG_COLORS.info or LOG_COLORS.bad)
        end,
    })
end

function Run.showStats(ctx)
    local s = ctx.stats
    Run.cards:SetValue('Instances', tostring(s.instances))
    Run.cards:SetValue('Scripts', tostring(s.scripts + s.constants))
    Run.cards:SetValue('Remotes', tostring(s.remotes))
end

function Run.start()
    local started = os.clock()
    Run.progress:SetValue(0)
    Run.progress:SetText('starting')
    Run.saved:SetText('saved to: -')
    Run.log:Clear()
    task.spawn(Dump.run, {
        phase = function(name, fraction, detail)
            Run.progress:SetText(name)
            Run.progress:SetValue(math.clamp((fraction or 0) * 100, 0, 100))
            Run.status:SetText(detail ~= "" and detail or name)
            Run.cards:SetValue('Elapsed', ("%.1fs"):format(os.clock() - started))
        end,
        stats = Run.showStats,
        log = function(text, kind)
            Run.log:Log(text, LOG_COLORS[kind or "info"] or LOG_COLORS.info)
        end,
        done = function(success, output, summary, message)
            Run.progress:SetValue(success and 100 or 0)
            Run.progress:SetText(message or (success and "done" or "failed"))
            Run.status:SetText(summary or "")
            Run.cards:SetValue('Elapsed', ("%.1fs"):format(os.clock() - started))
            if output then Run.saved:SetText('saved to: ' .. output) end
            Library:Notify({
                Title = 'Dumper',
                Description = success and ("saved - " .. summary) or (message or "failed"),
                Time = 8,
            })
        end,
    })
end

if UserConfig.AutoStart then Run.start() end

Library:Notify({ Title = 'Dumper', Description = 'loaded - RightShift opens and closes it', Time = 5 })
