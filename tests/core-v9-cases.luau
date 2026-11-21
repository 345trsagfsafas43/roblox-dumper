return function(h)
    h.test("v9 core: constant string caps preserve UTF-8", function()
        local api, mock = h.make({ globals = {
            getscriptclosure = function() return function() end end,
            getconstants = function() return { string.rep("a", 4095) .. "é" .. "tail" } end,
        } })
        local script = mock.instance("LocalScript", "UnicodeConstant", mock.services.ReplicatedStorage)
        local constants = api.constantsOf(script)
        h.equal(#constants, 1)
        assert(utf8.len(constants[1]), "constant preview broke UTF-8")
    end)

    h.test("v9 core: constant scans yield even without string entries", function()
        local numbers = {}
        for n = 1, 4096 do numbers[n] = n end
        local api, mock = h.make({ globals = {
            getscriptclosure = function() return function() end end,
            getconstants = function() return numbers end,
        } })
        api.SetConfig({ Speed = "Smooth" })
        mock.env.os.clock = function() mock.now += 0.002; return mock.now end
        local waits, wait = 0, mock.task.wait
        mock.task.wait = function(...) waits += 1; return wait(...) end
        api.Budget.start()
        local script = mock.instance("LocalScript", "Numbers", mock.services.ReplicatedStorage)
        h.equal(api.constantsOf(script), nil)
        assert(waits > 0, "large constant scan never yielded")
    end)

    local function prepare(api)
        local ctx = api.newContext()
        ctx.suspects = {}
        api.State.open("State.txt", {})
        return ctx
    end
    local function item(api, inst)
        return { inst = inst, className = inst.ClassName, path = api.pathOf(inst) }
    end

    h.test("v9 core: byte previews and source caps preserve UTF-8", function()
        local api, mock = h.make()
        h.equal(api.utf8Prefix("aé", 2), "a")
        h.equal(api.utf8Prefix("😀", 3), "")
        local preview = api.serialize(string.rep("a", 199) .. "é" .. "x")
        assert(utf8.len(preview), "serialized preview broke UTF-8")
        api.SetConfig({ MaxScriptChars = 1000, ExportScripts = true, DedupeScripts = false })
        local script = mock.instance("LocalScript", "Unicode", mock.services.ReplicatedStorage)
        script.source = string.rep("x", 999) .. "é" .. "more"
        local ctx = prepare(api)
        api.decompileOne(ctx, item(api, script))
        assert(utf8.len(ctx.out.Scripts:text()), "source report broke UTF-8")
        assert(utf8.len(ctx.index[1].exportSource), "source export broke UTF-8")
        h.equal(ctx.index[1].truncated, true)
    end)

    h.test("v9 core: serialized instance references distinguish siblings", function()
        local api, mock = h.make()
        local parent = mock.instance("Folder", "Container", mock.services.ReplicatedStorage)
        local first = mock.instance("Folder", "Same", parent)
        local second = mock.instance("Folder", "Same", parent)
        h.equal(api.serialize(first), "<" .. api.pathOf(first) .. ">")
        h.equal(api.serialize(first) ~= api.serialize(second), true)
    end)

    h.test("v9 core: wide child construction yields within inner loops", function()
        local api, mock = h.make()
        api.SetConfig({ Speed = "Smooth" })
        mock.env.os.clock = function() mock.now += 0.002; return mock.now end
        local waits, wait = 0, mock.task.wait
        mock.task.wait = function(...) waits += 1; return wait(...) end
        local parent = mock.instance("Folder", "Wide", mock.services.ReplicatedStorage)
        for _ = 1, 2048 do mock.instance("Folder", "Clone", parent) end
        local ctx = api.newContext()
        api.Budget.start()
        local frames = api.childFrames(ctx, parent, 1, "", api.pathOf(parent), false, false)
        assert(waits > 0, "wide folder never yielded")
        h.equal(#frames, 2049)
    end)

    h.test("v9 core: cancellation interrupts wide sibling indexing", function()
        local api, mock = h.make()
        api.SetConfig({ Speed = "Smooth" })
        mock.env.os.clock = function() mock.now += 0.01; return mock.now end
        mock.task.wait = function() api.Dump.cancel = true; return 0.02 end
        local parent = mock.instance("Folder", "CancelWide", mock.services.ReplicatedStorage)
        for _ = 1, 2048 do mock.instance("Folder", "Clone", parent) end
        api.Budget.start()
        local frames = api.childFrames(api.newContext(), parent, 1, "", api.pathOf(parent), false, false)
        h.equal(frames, nil)
        h.equal(api.Dump.cancel, true)
    end)

    h.test("v9 core: oversized source is not retained in dedupe keys", function()
        local api, mock = h.make()
        api.SetConfig({ MaxScriptChars = 1000, MaxDedupeMB = 0.01 })
        local script = mock.instance("LocalScript", "Oversized", mock.services.ReplicatedStorage)
        script.source = string.rep("x", 8 * 1024 * 1024)
        local ctx = prepare(api)
        api.decompileOne(ctx, item(api, script))
        h.equal(next(ctx.seenScripts), nil)
        h.equal(ctx.dedupeBytes, 0)
        h.equal(ctx.stats.dedupeLimited > 0, true)
        h.equal(#ctx.out.Scripts:text() < 3000, true)
    end)

    h.test("v9 core: retained dedupe keys obey the total byte budget", function()
        local api, mock = h.make()
        api.SetConfig({ MaxScriptChars = 10000, MaxDedupeMB = 0.005 })
        local ctx = prepare(api)
        for n = 1, 10 do
            local script = mock.instance("LocalScript", "Unique" .. n, mock.services.ReplicatedStorage)
            script.source = string.rep("x", 2000) .. tostring(n)
            api.decompileOne(ctx, item(api, script))
        end
        local retained = 0
        for key, path in pairs(ctx.seenScripts) do retained += #key + #path end
        h.equal(retained, ctx.dedupeBytes)
        assert(retained <= math.floor(0.005 * 1024 * 1024), "dedupe exceeded its byte budget")
        h.equal(ctx.stats.scripts, 10)
        h.equal(ctx.stats.dedupeLimited > 0, true)
    end)

    h.test("v9 core: large bytecode falls back to bounded source dedupe", function()
        local api, mock = h.make({ globals = { getscriptbytecode = function() return string.rep("b", 2 * 1024 * 1024) end } })
        api.SetConfig({ MaxScriptChars = 1000, MaxDedupeMB = 0.01 })
        local script = mock.instance("LocalScript", "LargeBytecode", mock.services.ReplicatedStorage)
        script.source = "return true"
        local ctx = prepare(api)
        api.decompileOne(ctx, item(api, script))
        for key in pairs(ctx.seenScripts) do h.equal(#key < 1000, true) end
        h.equal(ctx.stats.scripts, 1)
        h.equal(ctx.stats.dedupeLimited > 0, true)
    end)

    h.test("v9 core: changed known hash ignores obsolete path suspects", function()
        local api, mock = h.make({ globals = { getscripthash = function() return "new-content" end } })
        local script = mock.instance("LocalScript", "Changed", mock.services.ReplicatedStorage)
        local ctx = prepare(api)
        ctx.suspects = { [api.pathOf(script)] = true, ["hash:old-content"] = true }
        api.decompileOne(ctx, item(api, script))
        h.equal(ctx.stats.scripts, 1)
        h.equal(ctx.stats.suspects, 0)
        h.equal(ctx.index[1].crashIdentity, "hash:new-content")
    end)

    h.test("v9 core: hash suspects work when deduplication is disabled", function()
        local calls = 0
        local api, mock = h.make({ globals = {
            getscripthash = function() return "known-bad" end,
            decompile = function() calls += 1; return "return true" end,
        } })
        api.SetConfig({ DedupeScripts = false })
        local script = mock.instance("LocalScript", "Known", mock.services.ReplicatedStorage)
        local ctx = prepare(api)
        ctx.suspects = { ["hash:known-bad"] = true }
        api.decompileOne(ctx, item(api, script))
        h.equal(ctx.index[1].status, "crash-skipped")
        h.equal(calls, 0)
    end)

    h.test("v9 core: ordinal-only paths do not inherit persistent skips", function()
        local api, mock = h.make()
        local script = mock.instance("LocalScript", "Detached", nil)
        local ctx = prepare(api)
        ctx.suspects = { [api.pathOf(script)] = true }
        api.decompileOne(ctx, item(api, script))
        h.equal(ctx.stats.scripts, 1)
        h.equal(ctx.stats.unstableIdentities, 1)
        h.equal(ctx.index[1].crashIdentity, nil)
        h.equal(mock.files["State.txt"]:find("ATTEMPT", 1, true), nil)
    end)

    h.test("v9 core: failed existing crash-state read preserves the journal", function()
        local api, mock = h.make()
        local statePath = api.filePath("State.txt")
        local original = "FORMAT\t2\nSUSPECT\told-script\n"
        mock.files[statePath] = original
        mock.failRead = statePath
        local ok, result = api.Dump.run()
        h.equal(ok, false)
        h.contains(result.message, "crash-state read failed")
        h.equal(mock.files[statePath], original)
        h.equal(api.Dump.running, false)
    end)

    h.test("v9 core: false-return crash writes and appends are errors", function()
        local api, mock = h.make()
        local write = mock.env.writefile
        mock.env.writefile = function() return false end
        h.equal(pcall(api.State.open, "State.txt", {}), false)
        mock.env.writefile = write
        api.State.open("State.txt", {})
        mock.env.appendfile = function() return false end
        h.equal(pcall(api.State.record, "ATTEMPT", "script"), false)
    end)

    h.test("v9 core: empty bytecode still attempts decompilation", function()
        local calls = 0
        local api, mock = h.make({ globals = {
            getscriptbytecode = function() return "" end,
            decompile = function() calls += 1; return "return 123" end,
        } })
        local script = mock.instance("LocalScript", "NoBytecode", mock.services.ReplicatedStorage)
        local ctx = prepare(api)
        api.decompileOne(ctx, item(api, script))
        h.equal(calls, 1)
        h.equal(ctx.index[1].status, "ok")
    end)

    h.test("v9 core: export source retains the original newline shape", function()
        local api, mock = h.make()
        api.SetConfig({ ExportScripts = true })
        local script = mock.instance("LocalScript", "ExactSource", mock.services.ReplicatedStorage)
        script.source = "return 'FixturePlayer'"
        local ctx = prepare(api)
        api.decompileOne(ctx, item(api, script))
        h.equal(ctx.index[1].exportSource, script.source)
    end)
end
