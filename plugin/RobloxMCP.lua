--[[
    Ultimate Roblox Studio MCP Plugin v2
    構文チェック、自動バックアップ、エラーログ取得、差分編集、
    一括操作、スクリプト内検索、バッチ処理に対応
]]

local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")
local LogService = game:GetService("LogService")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

-- Playモード中の書き込みガード
local function guardEditMode()
    if RunService:IsRunning() then
        return {error = "Cannot edit scripts during Play mode. Stop the session first."}
    end
    return nil
end

-- 安全なスクリプト書き込み（UpdateSourceAsync + フォールバック）
local function safeWriteSource(instance, newSource)
    local ok = false
    pcall(function()
        local SES = game:GetService("ScriptEditorService")
        SES:UpdateSourceAsync(instance, function() return newSource end)
        ok = true
    end)
    if not ok then
        pcall(function()
            local SES = game:GetService("ScriptEditorService")
            for _, doc in ipairs(SES:GetScriptDocuments()) do
                pcall(function() if doc:GetScript() == instance then doc:CloseAsync() end end)
            end
        end)
        instance.Source = newSource
    end
end

local MCP_SERVER_URL = "http://localhost:3002"
local POLL_INTERVAL = 0.3

local plugin = plugin or script:FindFirstAncestorOfClass("Plugin")

-- ===== バックアップストレージ =====
local backupHistory = {} -- [path] = {source, timestamp}[]
local MAX_BACKUPS = 10

-- ===== エラーログバッファ =====
local errorBuffer = {}
local MAX_ERRORS = 50

LogService.MessageOut:Connect(function(message, messageType)
    if messageType == Enum.MessageType.MessageError or messageType == Enum.MessageType.MessageWarning then
        table.insert(errorBuffer, {
            message = message,
            type = tostring(messageType),
            time = os.clock(),
        })
        if #errorBuffer > MAX_ERRORS then
            table.remove(errorBuffer, 1)
        end
    end
end)

-- ===== ユーティリティ =====

local function getInstanceByPath(path)
    local parts = string.split(path, ".")
    local current = game
    for i, part in ipairs(parts) do
        if i == 1 and part == "game" then continue end
        current = current:FindFirstChild(part)
        if not current then return nil end
    end
    return current
end

local function getPathOfInstance(instance)
    local path = {}
    local current = instance
    while current and current ~= game do
        table.insert(path, 1, current.Name)
        current = current.Parent
    end
    return "game." .. table.concat(path, ".")
end

local function serializeInstance(instance, depth)
    depth = depth or 0
    local data = {
        Name = instance.Name,
        ClassName = instance.ClassName,
        Path = getPathOfInstance(instance),
    }

    pcall(function()
        if instance:IsA("BasePart") then
            data.Position = tostring(instance.Position)
            data.Size = tostring(instance.Size)
            data.Color = tostring(instance.Color)
            data.Anchored = instance.Anchored
            data.Transparency = instance.Transparency
            data.Material = tostring(instance.Material)
            data.CanCollide = instance.CanCollide
        end
    end)

    pcall(function()
        if instance:IsA("LuaSourceContainer") then
            data.HasSource = true
            data.SourceLength = #instance.Source
        end
    end)

    if depth < 2 then
        data.Children = {}
        for _, child in ipairs(instance:GetChildren()) do
            table.insert(data.Children, serializeInstance(child, depth + 1))
        end
    end

    return data
end

-- バックアップを保存
local function saveBackup(path, source)
    if not backupHistory[path] then
        backupHistory[path] = {}
    end
    table.insert(backupHistory[path], {
        source = source,
        timestamp = os.clock(),
    })
    if #backupHistory[path] > MAX_BACKUPS then
        table.remove(backupHistory[path], 1)
    end
end

-- 構文チェック（loadstring使えない環境対応）
local function checkSyntax(source)
    local ok, result = pcall(function()
        local func, err = loadstring(source)
        if func then return {valid = true}
        else return {valid = false, error = tostring(err)} end
    end)
    if ok then return result
    else return {valid = true, skipped = true, reason = "loadstring not available"} end
end

-- 行分割ユーティリティ（確実版）
local function splitLines(source)
    local lines = {}
    for line in (source .. "\n"):gmatch("(.-)\n") do
        table.insert(lines, line)
    end
    return lines
end

-- ===== コマンドハンドラー =====

local handlers = {}

-- スクリプトのソース全文を取得
handlers.getScript = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found: " .. params.path} end
    if not instance:IsA("LuaSourceContainer") then
        return {error = "Not a script: " .. params.path}
    end
    return {
        path = params.path,
        source = instance.Source,
        className = instance.ClassName,
        lineCount = select(2, instance.Source:gsub("\n", "")) + 1,
    }
end

-- スクリプトのソースを丸ごと書き換え（構文チェック＋自動バックアップ付き）
handlers.setScript = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found: " .. params.path} end
    if not instance:IsA("LuaSourceContainer") then
        return {error = "Not a script: " .. params.path}
    end

    -- 構文チェック（スキップ可能）
    if not params.skipSyntaxCheck then
        local syntaxResult = checkSyntax(params.source)
        if not syntaxResult.valid then
            return {
                error = "Syntax error - script NOT updated",
                syntaxError = syntaxResult.error,
                hint = "Fix the syntax error or pass skipSyntaxCheck=true to force",
            }
        end
    end

    -- Playモードガード
    local guard = guardEditMode()
    if guard then return guard end

    -- 自動バックアップ
    saveBackup(params.path, instance.Source)

    local oldLength = #instance.Source

    safeWriteSource(instance, params.source)

    ChangeHistoryService:SetWaypoint("MCP: Updated " .. instance.Name)

    return {
        success = true,
        path = params.path,
        oldLength = oldLength,
        newLength = #params.source,
        lineCount = select(2, params.source:gsub("\n", "")) + 1,
        backedUp = true,
    }
end

-- 差分編集（行番号指定で部分書き換え）
handlers.editScript = function(params)
    local guard = guardEditMode()
    if guard then return guard end

    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found: " .. params.path} end
    if not instance:IsA("LuaSourceContainer") then
        return {error = "Not a script: " .. params.path}
    end

    saveBackup(params.path, instance.Source)

    local lines = splitLines(instance.Source)
    local startLine = params.startLine or 1
    local endLine = params.endLine or startLine
    local newLines = splitLines(params.newCode)

    -- 置き換え
    local result = {}
    for i = 1, startLine - 1 do
        table.insert(result, lines[i] or "")
    end
    for _, line in ipairs(newLines) do
        table.insert(result, line)
    end
    for i = endLine + 1, #lines do
        table.insert(result, lines[i])
    end

    local newSource = table.concat(result, "\n")

    -- 構文チェック
    if not params.skipSyntaxCheck then
        local syntaxResult = checkSyntax(newSource)
        if not syntaxResult.valid and not syntaxResult.skipped then
            return {
                error = "Syntax error after edit - NOT applied",
                syntaxError = syntaxResult.error,
            }
        end
    end

    safeWriteSource(instance, newSource)
    ChangeHistoryService:SetWaypoint("MCP: Edited " .. instance.Name .. " L" .. startLine .. "-" .. endLine)

    return {
        success = true,
        path = params.path,
        editedLines = startLine .. "-" .. endLine,
        oldLineCount = #lines,
        newLineCount = #result,
    }
end

-- バックアップ復元
handlers.restoreBackup = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end

    local history = backupHistory[params.path]
    if not history or #history == 0 then
        return {error = "No backups available for " .. params.path}
    end

    local idx = params.index or #history -- デフォルトは最新
    local backup = history[idx]
    if not backup then return {error = "Backup index out of range"} end

    local guard = guardEditMode()
    if guard then return guard end
    safeWriteSource(instance, backup.source)
    ChangeHistoryService:SetWaypoint("MCP: Restored backup for " .. instance.Name)

    return {
        success = true,
        restoredFrom = idx,
        totalBackups = #history,
    }
end

-- バックアップ一覧
handlers.listBackups = function(params)
    local history = backupHistory[params.path]
    if not history then return {backups = {}, count = 0} end
    local list = {}
    for i, b in ipairs(history) do
        table.insert(list, {
            index = i,
            timestamp = b.timestamp,
            sourceLength = #b.source,
        })
    end
    return {backups = list, count = #list}
end

-- 構文チェックのみ（書き込みなし）
handlers.checkSyntax = function(params)
    return checkSyntax(params.source)
end

-- 全スクリプト一覧
handlers.listScripts = function(params)
    local scripts = {}
    local function scan(parent)
        for _, child in ipairs(parent:GetChildren()) do
            if child:IsA("LuaSourceContainer") then
                table.insert(scripts, {
                    name = child.Name,
                    className = child.ClassName,
                    path = getPathOfInstance(child),
                    lineCount = select(2, child.Source:gsub("\n", "")) + 1,
                    sourceLength = #child.Source,
                })
            end
            scan(child)
        end
    end
    scan(game)
    return {scripts = scripts, count = #scripts}
end

-- 全スクリプトのソースを一括取得
handlers.getAllScripts = function(params)
    local scripts = {}
    local function scan(parent)
        for _, child in ipairs(parent:GetChildren()) do
            if child:IsA("LuaSourceContainer") then
                scripts[getPathOfInstance(child)] = {
                    name = child.Name,
                    className = child.ClassName,
                    source = child.Source,
                    lineCount = select(2, child.Source:gsub("\n", "")) + 1,
                }
            end
            scan(child)
        end
    end
    scan(game)
    return {scripts = scripts, count = 0} -- countは後で計算
end

-- スクリプト内検索（全スクリプトからキーワード検索）
handlers.searchInScripts = function(params)
    local query = params.query
    if not query or query == "" then return {error = "Query required"} end

    local results = {}
    local function scan(parent)
        for _, child in ipairs(parent:GetChildren()) do
            if child:IsA("LuaSourceContainer") then
                local lineNum = 0
                for line in child.Source:gmatch("[^\n]+") do
                    lineNum = lineNum + 1
                    if line:lower():find(query:lower(), 1, true) then
                        table.insert(results, {
                            path = getPathOfInstance(child),
                            scriptName = child.Name,
                            line = lineNum,
                            content = line:sub(1, 200), -- 最大200文字
                        })
                    end
                end
            end
            scan(child)
        end
    end
    scan(game)
    return {results = results, count = #results, query = query}
end

-- エラーログ取得
handlers.getErrors = function(params)
    local count = params.count or MAX_ERRORS
    local recent = {}
    local start = math.max(1, #errorBuffer - count + 1)
    for i = start, #errorBuffer do
        table.insert(recent, errorBuffer[i])
    end
    return {errors = recent, count = #recent, totalBuffered = #errorBuffer}
end

-- エラーログクリア
handlers.clearErrors = function()
    errorBuffer = {}
    return {success = true}
end

-- インスタンスツリー取得
handlers.getTree = function(params)
    local root = params.path and getInstanceByPath(params.path) or game
    if not root then return {error = "Instance not found"} end
    local depth = params.depth or 2
    local function serialize(inst, d)
        local data = {
            Name = inst.Name,
            ClassName = inst.ClassName,
            Path = getPathOfInstance(inst),
        }
        if d < depth then
            data.Children = {}
            for _, child in ipairs(inst:GetChildren()) do
                table.insert(data.Children, serialize(child, d + 1))
            end
        end
        return data
    end
    return serialize(root, 0)
end

-- プロパティ取得
handlers.getProperty = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end

    local success, value = pcall(function()
        return instance[params.property]
    end)

    if success then
        return {path = params.path, property = params.property, value = tostring(value), type = typeof(value)}
    else
        return {error = "Cannot read property: " .. params.property}
    end
end

-- プロパティ設定
handlers.setProperty = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end

    local value = params.value
    local propType = params.valueType or "string"

    if propType == "number" then value = tonumber(value)
    elseif propType == "boolean" then value = value == "true"
    elseif propType == "Vector3" then
        local parts = string.split(value, ",")
        value = Vector3.new(tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3]))
    elseif propType == "Color3" then
        local parts = string.split(value, ",")
        value = Color3.fromRGB(tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3]))
    elseif propType == "CFrame" then
        local parts = string.split(value, ",")
        value = CFrame.new(tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3]))
    elseif propType == "UDim2" then
        local parts = string.split(value, ",")
        value = UDim2.new(tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3]), tonumber(parts[4]))
    elseif propType == "Enum" then
        local parts = string.split(value, ".")
        value = Enum[parts[2]][parts[3]]
    end

    local success, err = pcall(function()
        instance[params.property] = value
    end)

    if success then
        ChangeHistoryService:SetWaypoint("MCP: Set " .. params.property)
        return {success = true}
    else
        return {error = tostring(err)}
    end
end

-- プロパティ一括設定
handlers.setProperties = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end

    local results = {}
    for prop, val in pairs(params.properties) do
        local success, err = pcall(function()
            instance[prop] = val
        end)
        results[prop] = success and "ok" or tostring(err)
    end

    ChangeHistoryService:SetWaypoint("MCP: Set multiple properties")
    return {success = true, results = results}
end

-- インスタンス作成
handlers.createInstance = function(params)
    local parent = getInstanceByPath(params.parent)
    if not parent then return {error = "Parent not found"} end

    local instance = Instance.new(params.className)
    instance.Name = params.name or params.className

    if params.properties then
        for prop, val in pairs(params.properties) do
            pcall(function() instance[prop] = val end)
        end
    end

    instance.Parent = parent
    ChangeHistoryService:SetWaypoint("MCP: Created " .. instance.Name)

    return {
        success = true,
        path = getPathOfInstance(instance),
        className = params.className,
    }
end

-- インスタンス削除
handlers.deleteInstance = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end

    local name = instance.Name
    instance:Destroy()
    ChangeHistoryService:SetWaypoint("MCP: Deleted " .. name)

    return {success = true, deleted = params.path}
end

-- インスタンスクローン
handlers.cloneInstance = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end

    local parent = params.newParent and getInstanceByPath(params.newParent) or instance.Parent
    local clone = instance:Clone()
    if params.newName then clone.Name = params.newName end
    clone.Parent = parent

    ChangeHistoryService:SetWaypoint("MCP: Cloned " .. instance.Name)
    return {success = true, path = getPathOfInstance(clone)}
end

-- Luaコード実行（出力キャプチャ改善版）
handlers.runCode = function(params)
    local func, err = loadstring(params.code)
    if not func then return {error = "Syntax error: " .. tostring(err)} end

    -- 方法1: print上書き
    local results = {}
    local oldPrint = print
    local capturedPrint = function(...)
        local args = {...}
        local strs = {}
        for _, v in ipairs(args) do table.insert(strs, tostring(v)) end
        table.insert(results, table.concat(strs, "\t"))
        oldPrint(...) -- 元のprintも呼ぶ（出力ウィンドウにも表示）
    end

    -- グローバルを上書き
    local env = getfenv(func)
    local newEnv = setmetatable({print = capturedPrint}, {__index = env})
    setfenv(func, newEnv)

    local success, execErr = pcall(func)

    -- 方法2: print上書きが効かない場合、Attributeに書き込み
    -- （結果はresultsに入ってるはず）

    if success then
        return {output = table.concat(results, "\n"), success = true}
    else
        return {error = tostring(execErr), output = table.concat(results, "\n")}
    end
end

-- インスタンス検索
handlers.findInstances = function(params)
    local results = {}
    local function search(parent)
        for _, child in ipairs(parent:GetChildren()) do
            local match = true
            if params.name and not child.Name:lower():find(params.name:lower()) then match = false end
            if params.className and child.ClassName ~= params.className then match = false end
            if match and (params.name or params.className) then
                table.insert(results, {
                    name = child.Name,
                    className = child.ClassName,
                    path = getPathOfInstance(child),
                })
            end
            search(child)
        end
    end
    search(params.root and getInstanceByPath(params.root) or game)
    return {results = results, count = #results}
end

-- バッチコマンド実行
handlers.batch = function(params)
    local results = {}
    for i, cmd in ipairs(params.commands) do
        local handler = handlers[cmd.command]
        if handler then
            results[i] = handler(cmd.params or {})
        else
            results[i] = {error = "Unknown command: " .. cmd.command}
        end
    end
    return {results = results, count = #params.commands}
end

-- Undo/Redo
handlers.undo = function() ChangeHistoryService:Undo(); return {success = true} end
handlers.redo = function() ChangeHistoryService:Redo(); return {success = true} end

-- 選択取得/設定
handlers.getSelection = function()
    local sel = Selection:Get()
    local paths = {}
    for _, s in ipairs(sel) do table.insert(paths, getPathOfInstance(s)) end
    return {selection = paths}
end

handlers.setSelection = function(params)
    local instances = {}
    for _, path in ipairs(params.paths) do
        local inst = getInstanceByPath(path)
        if inst then table.insert(instances, inst) end
    end
    Selection:Set(instances)
    return {success = true}
end

-- Studio状態
handlers.getStudioInfo = function()
    return {
        studioMode = "edit",
        gameId = game.GameId,
        placeId = game.PlaceId,
        pluginVersion = "2.0",
    }
end

-- Attribute操作
handlers.getAttribute = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    local val = instance:GetAttribute(params.attribute)
    return {value = tostring(val), type = typeof(val)}
end

handlers.setAttribute = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    instance:SetAttribute(params.attribute, params.value)
    return {success = true}
end

-- ===== 新機能（v3） =====

-- 関数リスト取得（スクリプト内の全関数名と行番号）
handlers.getFunctionList = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    if not instance:IsA("LuaSourceContainer") then return {error = "Not a script"} end

    local functions = {}
    local lines = splitLines(instance.Source)
    for i, line in ipairs(lines) do
        local fname = line:match("^%s*function%s+([%w_%.%:]+)%s*%(")
            or line:match("^%s*local%s+function%s+([%w_]+)%s*%(")
            or line:match("^%s*([%w_]+)%s*=%s*function%s*%(")
            or line:match("^%s*([%w_%.]+)%s*=%s*function%s*%(")
        if fname then
            table.insert(functions, {name = fname, line = i})
        end
    end
    return {functions = functions, count = #functions, path = params.path}
end

-- 行範囲取得（部分読み込み）
handlers.getLines = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    if not instance:IsA("LuaSourceContainer") then return {error = "Not a script"} end

    local lines = splitLines(instance.Source)
    local startLine = math.max(1, params.startLine or 1)
    local endLine = math.min(#lines, params.endLine or #lines)

    local result = {}
    for i = startLine, endLine do
        table.insert(result, {line = i, content = lines[i]})
    end
    return {lines = result, totalLines = #lines, range = startLine .. "-" .. endLine}
end

-- コード挿入（指定行の後に挿入）
handlers.insertCode = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    if not instance:IsA("LuaSourceContainer") then return {error = "Not a script"} end

    saveBackup(params.path, instance.Source)
    local lines = splitLines(instance.Source)
    local afterLine = params.afterLine or #lines
    local newLines = splitLines(params.code)

    local result = {}
    for i = 1, afterLine do table.insert(result, lines[i] or "") end
    for _, line in ipairs(newLines) do table.insert(result, line) end
    for i = afterLine + 1, #lines do table.insert(result, lines[i]) end

    local newSource = table.concat(result, "\n")
    safeWriteSource(instance, newSource)
    ChangeHistoryService:SetWaypoint("MCP: Inserted code after L" .. afterLine)
    return {success = true, insertedAfter = afterLine, insertedLines = #newLines, newTotal = #result}
end

-- 行削除
handlers.removeLines = function(params)
    local guard = guardEditMode()
    if guard then return guard end
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    if not instance:IsA("LuaSourceContainer") then return {error = "Not a script"} end

    saveBackup(params.path, instance.Source)
    local lines = splitLines(instance.Source)
    local startLine = params.startLine or 1
    local endLine = params.endLine or startLine

    local result = {}
    for i = 1, startLine - 1 do table.insert(result, lines[i]) end
    for i = endLine + 1, #lines do table.insert(result, lines[i]) end

    safeWriteSource(instance, table.concat(result, "\n"))
    ChangeHistoryService:SetWaypoint("MCP: Removed L" .. startLine .. "-" .. endLine)
    return {success = true, removed = startLine .. "-" .. endLine, oldTotal = #lines, newTotal = #result}
end

-- 文字列置換（サーバー側で確実に実行）
handlers.replaceInScript = function(params)
    local guard = guardEditMode()
    if guard then return guard end
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    if not instance:IsA("LuaSourceContainer") then return {error = "Not a script"} end

    local oldText = params.oldText
    local newText = params.newText
    if not oldText or not newText then return {error = "oldText and newText required"} end

    local source = instance.Source
    local pos = source:find(oldText, 1, true) -- plain text search
    if not pos then return {error = "Text not found in script", searchedFor = oldText:sub(1, 100)} end

    saveBackup(params.path, source)
    local newSource
    if params.replaceAll then
        newSource = source:gsub(oldText:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"), newText)
    else
        newSource = source:sub(1, pos - 1) .. newText .. source:sub(pos + #oldText)
    end

    local syntaxResult = checkSyntax(newSource)
    if not syntaxResult.valid and not syntaxResult.skipped and not params.skipSyntaxCheck then
        return {error = "Syntax error after replace - NOT applied", syntaxError = syntaxResult.error}
    end

    safeWriteSource(instance, newSource)
    ChangeHistoryService:SetWaypoint("MCP: Replace in " .. instance.Name)
    return {success = true, replacedAt = pos}
end

-- スクリプト検証（行数/長さで確認）
handlers.verifyScript = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    if not instance:IsA("LuaSourceContainer") then return {error = "Not a script"} end

    local lines = splitLines(instance.Source)
    return {
        path = params.path,
        lineCount = #lines,
        sourceLength = #instance.Source,
        firstLine = lines[1] or "",
        lastLine = lines[#lines] or "",
    }
end

-- 全スクリプト構文チェック
handlers.validateAllScripts = function()
    local results = {}
    local function scan(parent)
        for _, child in ipairs(parent:GetChildren()) do
            if child:IsA("LuaSourceContainer") then
                local r = checkSyntax(child.Source)
                if not r.valid then
                    table.insert(results, {
                        path = getPathOfInstance(child),
                        name = child.Name,
                        valid = false,
                        error = r.error,
                    })
                end
            end
            scan(child)
        end
    end
    scan(game)
    if #results == 0 then
        return {allValid = true, message = "All scripts pass syntax check"}
    end
    return {allValid = false, errors = results, count = #results}
end

-- モジュール依存関係取得
handlers.getModuleDependencies = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    if not instance:IsA("LuaSourceContainer") then return {error = "Not a script"} end

    local deps = {}
    for line in instance.Source:gmatch("[^\n]+") do
        local req = line:match("require%s*%(%s*(.-)%s*%)") or line:match("require%s+(.*)")
        if req then table.insert(deps, req:gsub("%s+$", "")) end
    end
    return {dependencies = deps, count = #deps, path = params.path}
end

-- 変数/関数の全使用箇所検索（getReferencesの強化版）
handlers.getReferences = function(params)
    local query = params.query
    if not query then return {error = "query required"} end

    local results = {}
    local function scan(parent)
        for _, child in ipairs(parent:GetChildren()) do
            if child:IsA("LuaSourceContainer") then
                local lines = splitLines(child.Source)
                for i, line in ipairs(lines) do
                    if line:find(query, 1, true) then
                        table.insert(results, {
                            path = getPathOfInstance(child),
                            name = child.Name,
                            line = i,
                            content = line:sub(1, 200),
                        })
                    end
                end
            end
            scan(child)
        end
    end
    scan(game)
    return {results = results, count = #results, query = query}
end

-- スクリプトサマリー
handlers.getScriptSummary = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    if not instance:IsA("LuaSourceContainer") then return {error = "Not a script"} end

    local lines = splitLines(instance.Source)
    local functions = {}
    local requires = {}
    local globals = {}

    for i, line in ipairs(lines) do
        local fname = line:match("^%s*function%s+([%w_%.%:]+)%s*%(")
            or line:match("^%s*local%s+function%s+([%w_]+)%s*%(")
        if fname then table.insert(functions, {name = fname, line = i}) end

        local req = line:match("require%s*%(%s*(.-)%s*%)")
        if req then table.insert(requires, req) end

        local gvar = line:match("^([%w_]+)%s*=")
        if gvar and not line:match("^%s*local") and not line:match("^%s*%-%-") then
            table.insert(globals, {name = gvar, line = i})
        end
    end

    return {
        path = params.path,
        className = instance.ClassName,
        lineCount = #lines,
        sourceLength = #instance.Source,
        functions = functions,
        requires = requires,
        globals = globals,
    }
end

-- インスタンスのリネーム
handlers.renameInstance = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    local oldName = instance.Name
    instance.Name = params.newName
    ChangeHistoryService:SetWaypoint("MCP: Renamed " .. oldName .. " → " .. params.newName)
    return {success = true, oldName = oldName, newName = params.newName, newPath = getPathOfInstance(instance)}
end

-- インスタンスの移動
handlers.moveInstance = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    local newParent = getInstanceByPath(params.newParent)
    if not newParent then return {error = "New parent not found"} end
    instance.Parent = newParent
    ChangeHistoryService:SetWaypoint("MCP: Moved " .. instance.Name)
    return {success = true, newPath = getPathOfInstance(instance)}
end

-- 子要素だけ取得（軽量版）
handlers.getChildren = function(params)
    local instance = params.path and getInstanceByPath(params.path) or game
    if not instance then return {error = "Instance not found"} end
    local children = {}
    for _, child in ipairs(instance:GetChildren()) do
        table.insert(children, {
            name = child.Name,
            className = child.ClassName,
            path = getPathOfInstance(child),
        })
    end
    return {children = children, count = #children}
end

-- ===== ポーリングループ =====

local running = true

local function pollServer()
    while running do
        local success, response = pcall(function()
            return HttpService:RequestAsync({
                Url = MCP_SERVER_URL .. "/poll",
                Method = "GET",
                Headers = {["Content-Type"] = "application/json"},
            })
        end)

        if success and response.Success then
            local ok, data = pcall(function()
                return HttpService:JSONDecode(response.Body)
            end)
            if ok and data and data.command then
                local handler = handlers[data.command]
                local result
                if handler then
                    local handlerOk, handlerResult = pcall(handler, data.params or {})
                    if handlerOk then
                        result = handlerResult
                    else
                        result = {error = "Handler error: " .. tostring(handlerResult)}
                    end
                else
                    result = {error = "Unknown command: " .. data.command}
                end

                pcall(function()
                    HttpService:RequestAsync({
                        Url = MCP_SERVER_URL .. "/result",
                        Method = "POST",
                        Headers = {["Content-Type"] = "application/json"},
                        Body = HttpService:JSONEncode({
                            id = data.id,
                            result = result,
                        }),
                    })
                end)
            end
        end

        wait(POLL_INTERVAL)
    end
end

-- プラグインツールバー
if plugin then
    local toolbar = plugin:CreateToolbar("MCP Server v2")
    local button = toolbar:CreateButton("Toggle MCP", "Start/Stop MCP Server", "rbxassetid://4458901886")

    button.Click:Connect(function()
        running = not running
        if running then
            print("[MCP Plugin v2] Started")
            task.spawn(pollServer)
        else
            print("[MCP Plugin v2] Stopped")
        end
    end)

    print("[MCP Plugin v2] Auto-starting...")
    task.spawn(pollServer)
end
