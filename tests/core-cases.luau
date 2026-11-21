return function(h)
    h.test("core: small numbers preserve their value", function()
        local api = h.make()
        h.equal(tonumber(api.fmt(0.0001)), 0.0001)
        h.equal(tonumber(api.fmt(1.2345678901234567)), 1.2345678901234567)
        h.equal(api.fmt(math.huge), "inf")
    end)

    h.test("core: cyclic values and ambiguous table keys are bounded", function()
        local api = h.make()
        local value = { ["a = b"] = true }
        value.self = value
        local text = api.serialize(value)
        h.contains(text, '["a = b"] = true')
        h.contains(text, "<cycle>")
        h.equal(#text < 1000, true)
    end)

    h.test("core: CFrame serialization preserves rotation", function()
        local api = h.make()
        local value = { __kind = "CFrame", GetComponents = function()
            return 1, 2, 3, 0, -1, 0, 1, 0, 0, 0, 0, 1
        end }
        h.equal(api.serialize(value), "CFrame(1, 2, 3, 0, -1, 0, 1, 0, 0, 0, 0, 1)")
    end)

    h.test("core: escaped paths distinguish duplicate and literal names", function()
        local api, mock = h.make()
        local parent = mock.instance("Folder", "Container", mock.services.ReplicatedStorage)
        local first = mock.instance("Folder", "Alpha", parent)
        local second = mock.instance("Folder", "Alpha", parent)
        local literal = mock.instance("Folder", "Alpha[1]", parent)
        local dotted = mock.instance("Folder", "a.b\\c\t\n", parent)
        api.indexSiblings(parent, parent:GetChildren())
        h.equal(api.pathOf(first) ~= api.pathOf(second), true)
        h.equal(api.pathOf(first) ~= api.pathOf(literal), true)
        h.equal(api.parentPathOf(api.pathOf(dotted)), api.pathOf(parent))
        h.equal(api.pathOf(dotted):find("\n", 1, true), nil)
        h.equal(api.pathOf(dotted):find("\t", 1, true), nil)
    end)

    h.test("core: distinct nil-parented instances have distinct paths", function()
        local api, mock = h.make()
        local first = mock.instance("LocalScript", "Detached", nil)
        local second = mock.instance("LocalScript", "Detached", nil)
        h.equal(api.pathOf(first) ~= api.pathOf(second), true)
        h.equal(api.pathOf(first), api.pathOf(first))
    end)

    h.test("core: folding retains unique scripts remotes and values", function()
        local api, mock = h.make()
        api.SetConfig({ Scripts = true, Remotes = true, Values = true, Tree = true,
            Attributes = true, Tags = false, CollapseRepeats = true, MaxDepth = 40,
            OnlyMyCharacter = false, OnlyMyPlayer = false, SkipGuiValues = false })
        local parent = mock.instance("Folder", "Container", mock.services.ReplicatedStorage)
        local fourth
        for _ = 1, 4 do fourth = mock.instance("Folder", "Clone", parent) end
        mock.instance("LocalScript", "UniqueScript", fourth)
        mock.instance("RemoteEvent", "UniqueRemote", fourth)
        local value = mock.instance("NumberValue", "UniqueValue", fourth)
        value.Value = 0.0001
        local ctx = api.newContext()
        api.visit(ctx, { inst = parent, path = api.pathOf(parent), depth = 0, prefix = "", isLast = true })
        while #ctx.stack > 0 do
            local frame = table.remove(ctx.stack)
            api.visit(ctx, frame)
        end
        h.equal(#ctx.queue, 1)
        h.equal(#ctx.remotes, 1)
        h.equal(ctx.stats.values, 1)
        h.equal(ctx.stats.collapsed, 1)
        h.contains(ctx.out.Tree:text(), "contents still scanned")
    end)

    h.test("core: game PlayerModule is retained outside default location", function()
        local api, mock = h.make()
        local gameModule = mock.instance("ModuleScript", "PlayerModule", mock.services.ReplicatedStorage)
        h.equal(api.isDefaultScript(gameModule), false)
        local playerScripts = mock.instance("PlayerScripts", "PlayerScripts", mock.player)
        local builtin = mock.instance("ModuleScript", "PlayerModule", playerScripts)
        local child = mock.instance("ModuleScript", "ControlModule", builtin)
        h.equal(api.isDefaultScript(builtin), true)
        h.equal(api.isDefaultScript(child), true)
    end)

    h.test("core: crash journal acknowledges completed attempts immediately", function()
        local api, mock = h.make()
        api.State.open("State.txt", {})
        api.State.record("ATTEMPT", "successful")
        api.State.record("DONE", "successful")
        local pending = "path%\twith\ncontrols"
        api.State.record("ATTEMPT", pending)
        local suspects = api.loadSuspects("State.txt")
        h.equal(suspects.successful, nil)
        h.equal(suspects[pending], true)
        h.contains(mock.files["State.txt"], "FORMAT\t2")
        api.State.finish(suspects)
        h.equal(api.loadSuspects("State.txt")[pending], true)
    end)

    h.test("core: legacy crash journal keeps only final unacknowledged attempt", function()
        local api, mock = h.make()
        mock.files["State.txt"] = "ATTEMPT\tfirst\nATTEMPT\tlast\n"
        local suspects = api.loadSuspects("State.txt")
        h.equal(suspects.first, nil)
        h.equal(suspects.last, true)
        mock.files["State.txt"] = "ATTEMPT\tfirst\nDONE\tfirst\nATTEMPT\tlast\n"
        suspects = api.loadSuspects("State.txt")
        h.equal(suspects.first, nil)
        h.equal(suspects.last, true)
    end)

    h.test("core: constants have a hard per-function limit", function()
        local constants = {}
        for i = 1, 1000 do constants[i] = "constant-" .. i end
        local api, mock = h.make({ globals = {
            getscriptclosure = function() return function() end end,
            getconstants = function() return constants end,
        } })
        local script = mock.instance("LocalScript", "ManyConstants", mock.services.ReplicatedStorage)
        local list = api.constantsOf(script)
        h.equal(#list, 800)
    end)

    h.test("core: empty hashes do not merge different script sources", function()
        local api, mock = h.make({ globals = {
            getscripthash = function() return "" end,
            decompile = function(inst) return "return " .. string.format("%q", inst.Name) end,
        } })
        api.SetConfig({ DedupeScripts = true, Constants = false })
        local first = mock.instance("LocalScript", "First", mock.services.ReplicatedStorage)
        local second = mock.instance("LocalScript", "Second", mock.services.ReplicatedStorage)
        local ctx = api.newContext()
        ctx.suspects = {}
        api.State.open("State.txt", {})
        api.decompileOne(ctx, { inst = first, className = "LocalScript", path = api.pathOf(first) })
        api.decompileOne(ctx, { inst = second, className = "LocalScript", path = api.pathOf(second) })
        h.equal(ctx.stats.scripts, 2)
        h.equal(ctx.stats.duplicates, 0)
        h.equal(next(api.loadSuspects("State.txt")), nil)
    end)

    h.test("core: hash and bytecode keys use separate namespaces", function()
        local api, mock = h.make({ globals = {
            getscripthash = function(inst) return inst.Name == "First" and "same-key" or nil end,
            getscriptbytecode = function() return "same-key" end,
            decompile = function(inst) return "return " .. string.format("%q", inst.Name) end,
        } })
        api.SetConfig({ DedupeScripts = true, Constants = false })
        local ctx = api.newContext()
        ctx.suspects = {}
        api.State.open("State.txt", {})
        for _, name in ipairs({ "First", "Second" }) do
            local script = mock.instance("LocalScript", name, mock.services.ReplicatedStorage)
            api.decompileOne(ctx, { inst = script, className = "LocalScript", path = api.pathOf(script) })
        end
        h.equal(ctx.stats.scripts, 2)
    end)

    h.test("core: timeout closes a yielding decompile worker", function()
        local mock
        local api
        api, mock = h.make({ globals = {
            decompile = function()
                while true do mock.task.wait() end
            end,
        } })
        api.SetConfig({ DecompileTimeout = 0.1 })
        local script = mock.instance("LocalScript", "YieldForever", mock.services.ReplicatedStorage)
        local ok, reason, settled = api.decompileWithTimeout(script)
        h.equal(ok, false)
        h.contains(reason, "timed out")
        h.equal(settled, true)
        h.equal(api.Dump.pendingWorker, nil)
    end)

    h.test("core: stop closes a yielding decompile worker", function()
        local mock
        local api
        api, mock = h.make({ globals = {
            decompile = function()
                mock.task.wait()
                api.Dump.cancel = true
                mock.task.wait()
                return "return true"
            end,
        } })
        local script = mock.instance("LocalScript", "StopWorker", mock.services.ReplicatedStorage)
        local ok, reason, settled = api.decompileWithTimeout(script)
        h.equal(ok, false)
        h.contains(reason, "cancelled")
        h.equal(settled, true)
        h.equal(api.Dump.pendingWorker, nil)
    end)

    h.test("core: real source truncation is recorded in index and manifest", function()
        local api, mock = h.make()
        api.SetConfig({ MaxScriptChars = 1000, DedupeScripts = false, HideName = false })
        local script = mock.instance("LocalScript", "LargeSource", mock.services.ReplicatedStorage)
        script.source = string.rep("-- 0123456789\n", 150) .. "return true\n"
        local ctx = api.newContext()
        ctx.suspects, ctx.complete = {}, true
        api.State.open("State.txt", {})
        api.decompileOne(ctx, { inst = script, className = "LocalScript", path = api.pathOf(script) })
        h.equal(ctx.stats.truncated, 1)
        h.equal(ctx.index[1].truncated, true)
        local primary, manifest = api.writeOutputs(ctx)
        h.contains(mock.files[primary], "[truncated]")
        h.contains(mock.files[manifest], "truncated: 1")
    end)

    h.test("core: stopping a script records cancellation without a failure", function()
        local mock
        local api
        api, mock = h.make({ globals = {
            decompile = function()
                mock.task.wait()
                api.Dump.cancel = true
                mock.task.wait()
                return "return true"
            end,
        } })
        local ctx = api.newContext()
        ctx.suspects = {}
        api.State.open("State.txt", {})
        local script = mock.instance("LocalScript", "CancelledScript", mock.services.ReplicatedStorage)
        api.decompileOne(ctx, { inst = script, className = "LocalScript", path = api.pathOf(script) })
        h.equal(ctx.index[1].status, "cancelled")
        h.equal(ctx.stats.failures, 0)
        h.equal(ctx.stats.cancelled, 1)
        h.equal(next(api.loadSuspects("State.txt")), nil)
    end)
end
