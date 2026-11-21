return function(harness)
    local equal, contains = harness.equal, harness.contains
    local function options()
        return { Config = { HideName = false, MaxFileMB = 0 } }
    end
    local function disableReports(api)
        api.SetConfig({
            HideName = false, MaxFileMB = 0, Info = false, Spy = false, Remotes = false,
            Signals = false, Tags = false, Globals = false, Modules = false, Interactables = false,
            Values = false, UiText = false, Hidden = false, Tree = false, Scripts = true,
        })
    end

    harness.test("writes preserve all bytes and line metadata", function()
        local api, mock = harness.make(options())
        api.SetConfig({ HideName = false, MaxFileMB = 0 })
        local count, parts = api.writeChunks("Dump.txt", { "abc\n", "def\n" })
        equal(count, 1)
        equal(mock.files["Dump.txt"], "abc\ndef\n")
        equal(parts[1].bytes, 8)
        equal(parts[1].firstLine, 1)
        equal(parts[1].lastLine, 2)
        equal(parts[1].startsMidLine, false)
        equal(parts[1].endsMidLine, false)
    end)

    harness.test("multipart metadata identifies a split long line", function()
        local api, mock = harness.make(options())
        api.SetConfig({ HideName = false, MaxFileMB = 8 / (1024 * 1024) })
        local original = "abcdefghijkl\nxy\n"
        local count, parts = api.writeChunks("Dump.txt", { original })
        equal(count, 2)
        equal(mock.files["Dump.txt"] .. mock.files["Dump_2.txt"], original)
        equal(parts[1].firstLine, 1)
        equal(parts[1].lastLine, 1)
        equal(parts[1].endsMidLine, true)
        equal(parts[2].firstLine, 1)
        equal(parts[2].lastLine, 2)
        equal(parts[2].startsMidLine, true)
        equal(parts[2].endsMidLine, false)
    end)

    harness.test("an unterminated final line has no phantom next part", function()
        local api, mock = harness.make(options())
        api.SetConfig({ HideName = false, MaxFileMB = 8 / (1024 * 1024) })
        local count, parts = api.writeChunks("Dump.txt", { "abcdefghijkl" })
        equal(count, 2)
        equal(mock.files["Dump.txt"] .. mock.files["Dump_2.txt"], "abcdefghijkl")
        equal(parts[2].firstLine, 1)
        equal(parts[2].lastLine, 1)
        equal(parts[2].startsMidLine, true)
        equal(parts[2].endsMidLine, false)
    end)

    harness.test("split text files retain complete UTF-8 characters", function()
        local api, mock = harness.make(options())
        api.SetConfig({ HideName = false, MaxFileMB = 5 / (1024 * 1024) })
        local original = string.rep(string.char(226, 130, 172), 3) .. "\n"
        local count, parts = api.writeChunks("Dump.txt", { original })
        local reconstructed = {}
        for i = 1, count do
            local content = mock.files[parts[i].path]
            assert(utf8.len(content) ~= nil, "part contains a broken UTF-8 character")
            assert(#content <= 5, "part exceeds byte limit")
            reconstructed[#reconstructed + 1] = content
        end
        equal(table.concat(reconstructed), original)
    end)

    harness.test("failed writes throw and preserve stale parts", function()
        local api, mock = harness.make(options())
        api.SetConfig({ HideName = false, MaxFileMB = 0 })
        mock.files["Dump_2.txt"] = "older part"
        mock.failWrite = "Dump.txt"
        local ok, err = pcall(api.writeChunks, "Dump.txt", { "new\n" })
        equal(ok, false)
        contains(tostring(err), "Dump.txt")
        equal(mock.files["Dump_2.txt"], "older part")
    end)

    harness.test("failed append cannot be reported as saved", function()
        local api, mock = harness.make(options())
        api.Has.appendfile = true
        mock.failAppend = true
        local ok, err = pcall(api.writeAll, "Dump.txt", { "first\n", "second\n" })
        equal(ok, false)
        contains(tostring(err), "appendfile")
        contains(tostring(err), "Dump.txt")
    end)

    harness.test("successful smaller replacement removes old extra parts", function()
        local api, mock = harness.make(options())
        api.SetConfig({ HideName = false, MaxFileMB = 0 })
        api.Has.isfile, api.Has.delfile = true, true
        mock.files["Dump_2.txt"], mock.files["Dump_3.txt"] = "old2", "old3"
        api.writeChunks("Dump.txt", { "new\n" })
        equal(mock.files["Dump_2.txt"], nil)
        equal(mock.files["Dump_3.txt"], nil)
    end)

    harness.test("flat split output returns a real primary path", function()
        local api, mock = harness.make(options())
        disableReports(api)
        api.SetConfig({ Output = "Split files" })
        api.Has.makefolder = false
        local ctx = api.newContext()
        ctx.complete = true
        local primary, manifest = api.writeOutputs(ctx)
        equal(primary, api.filePath("Index.txt"))
        equal(manifest, api.filePath("Manifest.txt"))
        assert(mock.files[primary] ~= nil, "primary path was not written")
        contains(mock.files[manifest], "status: COMPLETE")
        contains(mock.files[primary], api.filePath("Scripts.txt"))
    end)

    harness.test("partial output and truncation are explicit", function()
        local api, mock = harness.make(options())
        disableReports(api)
        api.SetConfig({ Output = "Single file" })
        local ctx = api.newContext()
        ctx.complete, ctx.cancelled, ctx.error = false, true, "fixture error"
        ctx.stats.depthLimited, ctx.stats.collapsed = 17, 5
        ctx.out.Scripts:line("-- fixture script")
        ctx.index[1] = { status = "ok", truncated = true, path = "ReplicatedStorage.Example", className = "LocalScript", line = 1, lines = 1, kb = 0.1 }
        ctx.stats.scripts = 1
        local primary, manifest = api.writeOutputs(ctx)
        contains(mock.files[primary], "PARTIAL")
        contains(mock.files[primary], "[truncated]")
        contains(mock.files[manifest], "status: PARTIAL")
        contains(mock.files[manifest], "fixture error")
        contains(mock.files[manifest], "truncated: 1")
        contains(mock.files[manifest], "Server-only source")
        contains(mock.files[manifest], "Immediate children excluded at depth limit: 17")
        contains(mock.files[manifest], "Repeated sibling roots folded in tree presentation: 5")
    end)

    harness.test("script index points to the actual header across multipart output", function()
        local api, mock = harness.make(options())
        disableReports(api)
        api.SetConfig({ Output = "Single file", MaxFileMB = 160 / (1024 * 1024) })
        local ctx = api.newContext()
        ctx.complete = true
        ctx.out.Scripts:line("-- fixture body marker")
        ctx.index[1] = { status = "ok", path = "ReplicatedStorage.Example", className = "LocalScript", line = 1, lines = 1, kb = 0.1 }
        ctx.stats.scripts = 1
        local primary = api.writeOutputs(ctx)
        local chunks = {}
        for _, part in ipairs(ctx.outputParts) do
            if part.logicalPath == primary then chunks[#chunks + 1] = mock.files[part.path] end
        end
        local output = table.concat(chunks)
        local current, indexed, actual = 0, nil, nil
        for line in output:gmatch("([^\n]*)\n") do
            current = current + 1
            local pointer = line:match("^%s*(%d+)%s+%d+%s+[%d%.]+%s+LocalScript%s+ReplicatedStorage%.Example")
            if pointer then indexed = tonumber(pointer) end
            if line == "-- fixture body marker" then actual = current end
        end
        assert(indexed ~= nil, "index row was not found")
        assert(actual ~= nil, "script header was not found")
        equal(indexed, actual)
        assert(#ctx.outputParts > 1, "fixture did not exercise multipart output")
    end)

    harness.test("a report write failure leaves manifest unfinished", function()
        local api, mock = harness.make(options())
        disableReports(api)
        local ctx = api.newContext()
        ctx.complete = true
        mock.failWrite = api.filePath("Dump.txt")
        local ok = pcall(api.writeOutputs, ctx)
        equal(ok, false)
        contains(mock.files[api.filePath("Manifest.txt")], "status: WRITING")
    end)
end
