return function(harness)
    local function fixture(options)
        local api, mock = harness.make(options)
        api.SetConfig({
            ExportScripts = true, Info = false, Spy = false, Remotes = false, Signals = false,
            Tags = false, Assets = false, Globals = false, Modules = false, Interactables = false,
            Values = false, UiText = false, Hidden = false, Tree = false, Scripts = true,
        })
        local ctx = api.newContext()
        ctx.complete = true
        return api, mock, ctx
    end
    local function add(ctx, path, source, status)
        local row = { path = path, className = "LocalScript", status = status or "ok",
            line = ctx.out.Scripts.lines + 1, lines = 1, kb = #source / 1024,
            exportSource = source }
        ctx.out.Scripts:block(source)
        ctx.index[#ctx.index + 1] = row
        ctx.stats.scripts += 1
        return row
    end
    harness.test("script files preserve collected bytes while reports redact names", function()
        local api, mock, ctx = fixture({ Config = { HideName = true } })
        local source = 'return "FixturePlayer"\r\n-- an original source comment\n'
        local row = add(ctx, "ReplicatedStorage.FixturePlayer", source)
        local primary, manifest = api.writeOutputs(ctx)
        harness.equal(mock.files[row.exportFile], source)
        harness.equal(row.exportSource, nil)
        harness.equal(row.exportBytes, #source)
        assert(not row.exportFile:find("FixturePlayer", 1, true), "export filename leaks a redacted name")
        harness.contains(mock.files[manifest], row.exportFile)
        harness.contains(mock.files[manifest], "ReplicatedStorage.<you>")
        harness.contains(mock.files[manifest], "Files written: 1")
        harness.contains(mock.files[primary], "[file: " .. row.exportFile .. "]")
    end)
    harness.test("script export filenames cannot traverse and stay unique and bounded", function()
        local api, mock, ctx = fixture({ Config = { HideName = false } })
        local first = add(ctx, "ReplicatedStorage." .. string.rep("../CON\\:?", 80), "return 1\n")
        local second = add(ctx, "ReplicatedStorage." .. string.rep("../CON\\:?", 80), "return 2\n")
        api.writeOutputs(ctx)
        harness.equal(first.exportFile ~= second.exportFile, true)
        for _, row in ipairs({ first, second }) do
            local filename = row.exportFile:match("([^/]+)$")
            assert(filename:match("^%d+_[A-Za-z0-9_%-]+%.lua$"), "unsafe source filename")
            assert(#filename < 100, "source filename is unbounded")
            assert(not row.exportFile:find("..", 1, true), "path contains traversal")
            harness.equal(mock.files[row.exportFile] ~= nil, true)
        end
    end)
    harness.test("identical scripts reference one exported source file", function()
        local api, mock, ctx = fixture()
        local source = add(ctx, "ReplicatedStorage.One", "return 1\n")
        local duplicate = { path = "Workspace.Clone", className = "LocalScript", status = "same", sameAs = source.path }
        ctx.index[#ctx.index + 1] = duplicate
        api.writeOutputs(ctx)
        harness.equal(#ctx.scriptExports, 1)
        harness.equal(duplicate.exportFile, source.exportFile)
        harness.equal(duplicate.exportBytes, source.exportBytes)
        harness.contains(mock.files[ctx.manifestPath], "same-as=" .. source.path)
        harness.contains(mock.files[api.filePath("Dump.txt")], "same as " .. source.path .. "  [file: " .. source.exportFile .. "]")
    end)
    harness.test("constants-only exports have an explicit non-source extension", function()
        local api, mock, ctx = fixture()
        local row = add(ctx, "ReplicatedStorage.Constants", '-- "RemoteName"\n', "constants")
        row.truncated = true
        api.writeOutputs(ctx)
        harness.equal(row.exportFile:sub(-14), ".constants.txt")
        harness.equal(mock.files[row.exportFile], '-- "RemoteName"\n')
        harness.contains(mock.files[ctx.manifestPath], "status=constants | truncated=true")
    end)
    harness.test("export write failure retains WRITING status and successful file metadata", function()
        local api, mock, ctx = fixture()
        local first = add(ctx, "ReplicatedStorage.One", "return 1\n")
        local second = add(ctx, "ReplicatedStorage.Two", "return 2\n")
        mock.failWrite = "Dumper/123/Scripts/000002_Two.lua"
        local ok, err = pcall(api.writeOutputs, ctx)
        harness.equal(ok, false)
        harness.contains(tostring(err), mock.failWrite)
        harness.equal(first.exportSource, nil)
        harness.equal(second.exportFile, nil)
        harness.equal(mock.files[first.exportFile], "return 1\n")
        harness.contains(mock.files[ctx.manifestPath], "status: WRITING")
        harness.contains(mock.files[ctx.manifestPath], first.exportFile)
        harness.contains(mock.files[ctx.manifestPath], "Files written: 1")
        harness.equal(mock.files[api.filePath("Dump.txt")], nil)
    end)
    harness.test("flat script exports are valid without folder creation", function()
        local api, mock, ctx = fixture({ noFolders = true })
        local row = add(ctx, "ReplicatedStorage.One", "return 1\n")
        api.writeOutputs(ctx)
        harness.equal(row.exportFile, "Dumper_123_Script_000001_One.lua")
        harness.equal(mock.files[row.exportFile], "return 1\n")
        harness.contains(mock.files[ctx.manifestPath], row.exportFile)
    end)
    harness.test("script export directory failure cannot claim completed output", function()
        local api, mock, ctx = fixture()
        local row = add(ctx, "ReplicatedStorage.One", "return 1\n")
        mock.failMkdir = "Dumper/123/Scripts"
        local ok, err = pcall(api.writeOutputs, ctx)
        harness.equal(ok, false)
        harness.contains(tostring(err), "Dumper/123/Scripts")
        harness.equal(row.exportFile, nil)
        harness.contains(mock.files[ctx.manifestPath], "status: WRITING")
    end)
    harness.test("partial captures still export completed sources and disclose truncation", function()
        local api, mock, ctx = fixture()
        ctx.complete, ctx.cancelled = false, true
        local row = add(ctx, "ReplicatedStorage.Partial", "return 1\n-- [...truncated]\n")
        row.truncated = true
        api.writeOutputs(ctx)
        harness.equal(mock.files[row.exportFile], "return 1\n-- [...truncated]\n")
        harness.contains(mock.files[ctx.manifestPath], "status: PARTIAL")
        harness.contains(mock.files[ctx.manifestPath], "truncated=true")
    end)
    harness.test("source export references do not shift report index pointers", function()
        local api, mock, ctx = fixture()
        add(ctx, "ReplicatedStorage.Export", "return 'export-marker'\n")
        local primary = api.writeOutputs(ctx)
        local output = mock.files[primary]
        local pointer = tonumber(output:match("\n%s*(%d+)%s+%d+%s+[%d%.]+%s+LocalScript%s+ReplicatedStorage%.Export"))
        assert(pointer, "index pointer missing")
        local line = 0
        for text in output:gmatch("([^\n]*)\n") do
            line += 1
            if text == "return 'export-marker'" then harness.equal(line, pointer); return end
        end
        error("export fixture source not found in report")
    end)
end
