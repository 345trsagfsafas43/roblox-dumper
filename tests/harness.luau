-- The runner prepends SOURCE from the actual dumper.lua; no Roblox/executor code is executed.
local harness = { passed = 0, failed = 0 }
local base = getfenv(0)

function harness.equal(actual, expected)
    assert(actual == expected, ("expected %s, got %s"):format(tostring(expected), tostring(actual)))
end
function harness.contains(text, needle)
    assert(type(text) == "string" and text:find(needle, 1, true), "missing: " .. needle .. " in " .. tostring(text))
end
function harness.test(name, fn)
    local ok, err = pcall(fn)
    if ok then harness.passed += 1; print("PASS " .. name)
    else harness.failed += 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end

function harness.make(options)
    options = options or {}
    local mock = { files = table.clone(options.files or {}), folders = {}, workers = {}, now = 0, warnings = {} }
    local e = setmetatable({}, { __index = base })
    mock.env = e
    local sharedEnv = options.sharedEnv or {}
    mock.sharedEnv = sharedEnv
    local config = {
        Info = false, Scripts = true, Tree = true, Remotes = true, Listeners = false,
        Signals = false, Tags = false, Globals = false, Modules = false, Values = true,
        Interactables = false, UiText = false, Hidden = false, Attributes = true,
        Spy = false, HideName = false, NoUI = true, AutoStart = false, Assets = false,
        Roots = { "ReplicatedStorage" }, OnlyMyCharacter = false,
    }
    for key, value in pairs(options.Config or {}) do config[key] = value end
    sharedEnv.DumperConfig = config
    e.getgenv = function() return sharedEnv end
    e._G, e.shared = {}, {}
    e.typeof = function(value)
        return type(value) == "table" and rawget(value, "__kind") or type(value)
    end
    e.warn = function(message) table.insert(mock.warnings, tostring(message)) end
    e.print = function() end
    e.os = table.clone(os)
    e.os.clock = function() return mock.now end
    e.Enum = {
        RunContext = { Client = "Client", Server = "Server", Legacy = "Legacy" },
        InfoType = { Asset = "Asset" }, KeyCode = { RightShift = "RightShift" },
    }
    e.Color3 = { fromRGB = function(r, g, b) return { __kind = "Color3", R = r / 255, G = g / 255, B = b / 255 } end }
    function mock.signal()
        local signal = { connections = {} }
        function signal:Connect(fn)
            local connection = { Connected = true, callback = fn }
            function connection:Disconnect() self.Connected = false end
            table.insert(self.connections, connection)
            return connection
        end
        return signal
    end
    function mock.instance(className, name, parent)
        local inst = { __kind = "Instance", ClassName = className, Name = name, Parent = parent,
            children = {}, attributes = {}, RunContext = "Legacy", Value = nil, Text = "" }
        if parent then table.insert(parent.children, inst) end
        function inst:GetChildren() return table.clone(self.children) end
        function inst:GetDescendants()
            local result = {}
            local function add(object)
                for _, child in ipairs(object.children) do table.insert(result, child); add(child) end
            end
            add(self)
            return result
        end
        function inst:GetFullName()
            local result, current = {}, self
            while current and current.ClassName ~= "DataModel" do
                table.insert(result, 1, current.Name); current = current.Parent
            end
            return table.concat(result, ".")
        end
        function inst:GetAttributes() return table.clone(self.attributes) end
        function inst:FindFirstChild(childName)
            for _, child in ipairs(self.children) do if child.Name == childName then return child end end
        end
        function inst:FindFirstChildOfClass(childClass)
            for _, child in ipairs(self.children) do if child.ClassName == childClass then return child end end
        end
        function inst:IsA(childClass) return self.ClassName == childClass end
        function inst:GetPropertyChangedSignal() return mock.signal() end
        if className == "RemoteEvent" or className == "UnreliableRemoteEvent" then inst.OnClientEvent = mock.signal() end
        return inst
    end
    mock.newInstance = mock.instance
    mock.game = mock.instance("DataModel", "game")
    mock.game.PlaceId, mock.game.GameId, mock.game.PlaceVersion, mock.game.JobId = 123, 456, 7, "fixture"
    mock.services = {}
    for _, name in ipairs({ "Players", "CollectionService", "UserInputService", "RunService", "Workspace",
        "ReplicatedStorage", "ReplicatedFirst", "StarterGui", "StarterPlayer", "StarterPack", "Lighting",
        "SoundService", "Teams", "Chat", "MarketplaceService" }) do
        mock.services[name] = mock.instance(name, name, mock.game)
    end
    mock.player = mock.instance("Player", "FixturePlayer", mock.services.Players)
    mock.player.UserId, mock.player.DisplayName = 100, "Fixture"
    mock.services.Players.LocalPlayer = mock.player
    mock.services.Players.GetPlayers = function() return { mock.player } end
    mock.services.CollectionService.GetTags = function() return {} end
    mock.services.CollectionService.GetAllTags = function() return {} end
    mock.services.CollectionService.GetTagged = function() return {} end
    mock.services.MarketplaceService.GetProductInfoAsync = function() return { Name = "Fixture Game", Creator = { Name = "Fixture" } } end
    mock.game.GetService = function(_, name) assert(mock.services[name], "unknown service " .. name); return mock.services[name] end
    mock.game.HttpGet = function() error("offline UI download failure") end
    e.game, e.workspace = mock.game, mock.services.Workspace
    local function fail(field, path)
        if mock[field] == true or mock[field] == path then error(field .. ": " .. path) end
    end
    e.writefile = function(path, content) fail("failWrite", path); mock.files[path] = content end
    e.appendfile = function(path, content)
        fail("failAppend", path); mock.files[path] = (mock.files[path] or "") .. content
    end
    e.readfile = function(path) fail("failRead", path); assert(mock.files[path] ~= nil, "file missing " .. path); return mock.files[path] end
    e.isfile = function(path) fail("failIsfile", path); return mock.files[path] ~= nil end
    e.isfolder = function(path) fail("failIsfolder", path); return mock.folders[path] == true end
    e.makefolder = function(path) fail("failMkdir", path); mock.folders[path] = true end
    e.delfile = function(path) fail("failDelete", path); mock.files[path] = nil end
    if options.noAppend then e.appendfile = false end
    if options.noFolders then e.makefolder, e.isfolder = false, false end
    e.decompile = function(inst) return inst.source or "return true\n" end
    e.require = function(inst) return inst.moduleValue or {} end
    e.task = {}
    function e.task.spawn(fn, ...)
        local worker = type(fn) == "thread" and fn or coroutine.create(fn)
        table.insert(mock.workers, worker)
        local previousWorker = mock.currentWorker
        mock.currentWorker = worker
        local ok, err = coroutine.resume(worker, ...)
        mock.currentWorker = previousWorker
        if not ok then error(err) end
        return worker
    end
    function mock.tick(seconds)
        mock.now += seconds or 0.02
        local snapshot = table.clone(mock.workers)
        for _, worker in ipairs(snapshot) do
            if coroutine.status(worker) == "suspended" then
                local previousWorker = mock.currentWorker
                mock.currentWorker = worker
                local ok, err = coroutine.resume(worker)
                mock.currentWorker = previousWorker
                if not ok then error(err) end
            end
        end
    end
    function e.task.wait(seconds)
        if mock.currentWorker then return coroutine.yield(seconds) end
        mock.tick(seconds or 0.02)
        return seconds or 0.02
    end
    e.task.cancel = function(worker) coroutine.close(worker) end
    mock.task = e.task
    for key, value in pairs(options.globals or {}) do e[key] = value end
    local exports = [[
return {
    Config = Config, UserConfig = UserConfig, Dump = Dump, Has = Has, Spy = Spy, Session = Session, Host = Host,
    Buffer = Buffer, fmt = fmt, serialize = serialize, indexSiblings = indexSiblings,
    segment = segment, pathOf = pathOf, parentPathOf = parentPathOf, loadSuspects = loadSuspects,
    State = State, newContext = newContext, childFrames = childFrames, visit = visit,
    constantsOf = constantsOf, decompileOne = decompileOne, decompileWithTimeout = decompileWithTimeout,
    isDefaultScript = isDefaultScript, writeAll = writeAll, writeChunks = writeChunks,
    writeOutputs = writeOutputs, writeIndex = writeIndex, filePath = filePath,
    normaliseConfig = normaliseConfig,
    utf8Prefix = utf8Prefix, Budget = Budget, collectAssets = collectAssets, writeAssets = writeAssets,
    capabilityReport = capabilityReport, writeInfo = writeInfo,
    SetConfig = function(changes) for key, value in pairs(changes) do Config[key] = value end end,
}
]]
    local prefix = SOURCE:sub(1, assert(SOURCE:find("local function startHeadless()", 1, true)) - 1)
    local chunk, err = loadstring(prefix .. exports, "dumper-under-test")
    assert(chunk, err)
    setfenv(chunk, e)
    local api = chunk()
    mock.boot = function()
        local full, compileError = loadstring(SOURCE, "dumper-full-boot")
        assert(full, compileError); setfenv(full, e); return full()
    end
    return api, mock
end

require("../tests/core-cases")(harness)
require("../tests/output-cases")(harness)
require("../tests/lifecycle-cases")(harness)
require("../tests/export-cases")(harness)
require("../tests/core-v9-cases")(harness)
require("../tests/asset-host-cases")(harness)
print(("RESULT %d passed, %d failed"):format(harness.passed, harness.failed))
assert(harness.failed == 0, "regression suite failed")
