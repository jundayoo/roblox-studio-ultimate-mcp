--[[
    Ultimate Roblox Studio MCP Plugin v4.0
    - Play-mode guard on ALL write handlers
    - Correct line counting (splitLines trailing-newline fix)
    - Protected services (no deleting Workspace etc.)
    - Safer setProperty parsing (strip braces, full CFrame, Color3.new, Vector2)
    - batch with per-command pcall
    - Backup keyed by Instance (survives rename)
    - os.time timestamps
    - checkSyntax returns `skipped` flag
    - Version handshake
]]

local PLUGIN_VERSION = "5.2.0"
local PROTOCOL_VERSION = 2

local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")
local LogService = game:GetService("LogService")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

-- ===== Play-mode guard =====
local function guardEditMode()
    if RunService:IsRunning() then
        return {error = "Cannot edit scripts during Play mode. Stop the session first."}
    end
    return nil
end

-- 書き込み系ハンドラを包むヘルパー: guard を忘れても守る
local function writeGuarded(fn)
    return function(params)
        local g = guardEditMode()
        if g then return g end
        return fn(params)
    end
end

-- 安全なスクリプト書き込み
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

local MCP_SERVER_URL = "http://127.0.0.1:3002"
local POLL_INTERVAL = 0.3

local plugin = plugin or script:FindFirstAncestorOfClass("Plugin")

-- ===== バックアップストレージ（Instance 参照キー、weak table） =====
local backupHistory = setmetatable({}, {__mode = "k"})
local MAX_BACKUPS = 10

-- ===== ログバッファ（全タイプ、Play中も捕捉）=====
local logBuffer = {}
local MAX_LOG = 500

local function typeToLevel(mt)
    if mt == Enum.MessageType.MessageError then return "error" end
    if mt == Enum.MessageType.MessageWarning then return "warn" end
    if mt == Enum.MessageType.MessageInfo then return "info" end
    return "output"
end

local MAX_LOG_MSG_LEN = 8192

LogService.MessageOut:Connect(function(message, messageType)
    local safeMsg = tostring(message)
    if #safeMsg > MAX_LOG_MSG_LEN then
        safeMsg = safeMsg:sub(1, MAX_LOG_MSG_LEN) .. "...[truncated]"
    end
    table.insert(logBuffer, {
        message = safeMsg,
        level = typeToLevel(messageType),
        type = tostring(messageType),
        time = os.time(),
        duringPlay = RunService:IsRunning(),
    })
    if #logBuffer > MAX_LOG then
        table.remove(logBuffer, 1)
    end
end)

-- ===== ユーティリティ =====

-- パス → Instance（"game.X.Y" 形式。先頭 game はオプション、Service対応）
local function getInstanceByPath(path)
    if not path or path == "" then return nil end
    local parts = string.split(path, ".")
    local current = game
    for i, part in ipairs(parts) do
        if i == 1 and part == "game" then continue end
        -- 最初の Service 解決は GetService 経由
        if current == game then
            local ok, svc = pcall(function() return game:GetService(part) end)
            if ok and svc then
                current = svc
                continue
            end
        end
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

-- 末尾改行を考慮した正確な splitLines
local function splitLines(source)
    local lines = {}
    if source == nil or source == "" then return lines end
    local hadTrailingNewline = source:sub(-1) == "\n"
    for line in (source .. "\n"):gmatch("(.-)\n") do
        table.insert(lines, line)
    end
    -- 末尾 \n が元からあった場合に追加される空要素を除去
    if hadTrailingNewline and #lines > 0 and lines[#lines] == "" then
        table.remove(lines)
    end
    return lines
end

-- 統一された行数カウント
local function countLines(source)
    return #splitLines(source)
end

local function serializeInstance(instance, depth)
    depth = depth or 0
    local data = {
        Name = instance.Name,
        ClassName = instance.ClassName,
        Path = getPathOfInstance(instance),
    }

    if instance:IsA("BasePart") then
        data.Position = tostring(instance.Position)
        data.Size = tostring(instance.Size)
        data.Color = tostring(instance.Color)
        data.Anchored = instance.Anchored
        data.Transparency = instance.Transparency
        data.Material = tostring(instance.Material)
        data.CanCollide = instance.CanCollide
    end

    if instance:IsA("LuaSourceContainer") then
        data.HasSource = true
        data.SourceLength = #instance.Source
    end

    if depth < 2 then
        data.Children = {}
        for _, child in ipairs(instance:GetChildren()) do
            table.insert(data.Children, serializeInstance(child, depth + 1))
        end
    end

    return data
end

-- バックアップを保存（Instance 参照キー）
local function saveBackup(instance, source)
    if not backupHistory[instance] then
        backupHistory[instance] = {}
    end
    table.insert(backupHistory[instance], {
        source = source,
        timestamp = os.time(),
    })
    if #backupHistory[instance] > MAX_BACKUPS then
        table.remove(backupHistory[instance], 1)
    end
end

-- 構文チェック
local function checkSyntax(source)
    local ok, result = pcall(function()
        local func, err = loadstring(source)
        if func then return {valid = true}
        else return {valid = false, error = tostring(err)} end
    end)
    if ok then return result
    else return {valid = true, skipped = true, reason = "loadstring not available"} end
end

-- 保護サービス
local PROTECTED_SERVICES = {
    Workspace = true, ReplicatedStorage = true, ServerStorage = true,
    ServerScriptService = true, StarterPlayer = true, StarterGui = true,
    StarterPack = true, Lighting = true, SoundService = true, Chat = true,
    Players = true, ReplicatedFirst = true, Teams = true, HttpService = true,
    MaterialService = true, TestService = true,
}

-- ===== コマンドハンドラー =====

local handlers = {}

-- スクリプトのソース全文を取得
handlers.getScript = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found: " .. tostring(params.path)} end
    if not instance:IsA("LuaSourceContainer") then
        return {error = "Not a script: " .. params.path}
    end
    return {
        path = params.path,
        source = instance.Source,
        className = instance.ClassName,
        lineCount = countLines(instance.Source),
    }
end

-- スクリプト全書き換え
handlers.setScript = writeGuarded(function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found: " .. tostring(params.path)} end
    if not instance:IsA("LuaSourceContainer") then
        return {error = "Not a script: " .. params.path}
    end

    local syntaxSkipped = false
    if not params.skipSyntaxCheck then
        local syntaxResult = checkSyntax(params.source)
        if not syntaxResult.valid then
            return {
                error = "Syntax error - script NOT updated",
                syntaxError = syntaxResult.error,
                hint = "Fix the syntax error or pass skipSyntaxCheck=true to force",
            }
        end
        syntaxSkipped = syntaxResult.skipped == true
    end

    saveBackup(instance, instance.Source)
    local oldLength = #instance.Source
    safeWriteSource(instance, params.source)
    ChangeHistoryService:SetWaypoint("MCP: Updated " .. instance.Name)

    return {
        success = true,
        path = params.path,
        oldLength = oldLength,
        newLength = #params.source,
        lineCount = countLines(params.source),
        backedUp = true,
        syntaxCheckSkipped = syntaxSkipped,
    }
end)

-- 差分編集
handlers.editScript = writeGuarded(function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found: " .. tostring(params.path)} end
    if not instance:IsA("LuaSourceContainer") then
        return {error = "Not a script: " .. params.path}
    end

    local lines = splitLines(instance.Source)
    local totalLines = #lines
    local startLine = params.startLine or 1
    local endLine = params.endLine or startLine

    -- Range チェック
    if startLine < 1 or endLine < startLine or startLine > totalLines + 1 then
        return {
            error = "Invalid line range",
            startLine = startLine, endLine = endLine, totalLines = totalLines,
        }
    end
    if endLine > totalLines then endLine = totalLines end

    saveBackup(instance, instance.Source)

    local newLines = splitLines(params.newCode)
    local result = {}
    for i = 1, startLine - 1 do
        table.insert(result, lines[i])
    end
    for _, line in ipairs(newLines) do
        table.insert(result, line)
    end
    for i = endLine + 1, #lines do
        table.insert(result, lines[i])
    end

    local newSource = table.concat(result, "\n")
    -- 元ソースが末尾改行ありなら保持
    if instance.Source:sub(-1) == "\n" then newSource = newSource .. "\n" end

    local syntaxSkipped = false
    if not params.skipSyntaxCheck then
        local syntaxResult = checkSyntax(newSource)
        if not syntaxResult.valid then
            return {
                error = "Syntax error after edit - NOT applied",
                syntaxError = syntaxResult.error,
            }
        end
        syntaxSkipped = syntaxResult.skipped == true
    end

    safeWriteSource(instance, newSource)
    ChangeHistoryService:SetWaypoint("MCP: Edited " .. instance.Name .. " L" .. startLine .. "-" .. endLine)

    return {
        success = true,
        path = params.path,
        editedLines = startLine .. "-" .. endLine,
        oldLineCount = totalLines,
        newLineCount = #result,
        syntaxCheckSkipped = syntaxSkipped,
    }
end)

-- バックアップ復元
handlers.restoreBackup = writeGuarded(function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end

    local history = backupHistory[instance]
    if not history or #history == 0 then
        return {error = "No backups available for " .. params.path}
    end

    local idx = params.index or #history
    local backup = history[idx]
    if not backup then return {error = "Backup index out of range"} end

    safeWriteSource(instance, backup.source)
    ChangeHistoryService:SetWaypoint("MCP: Restored backup for " .. instance.Name)

    return {
        success = true,
        restoredFrom = idx,
        totalBackups = #history,
    }
end)

-- バックアップ一覧
handlers.listBackups = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    local history = backupHistory[instance]
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

-- 構文チェック（書き込みなし）
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
                    lineCount = countLines(child.Source),
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
    local count = 0
    local function scan(parent)
        for _, child in ipairs(parent:GetChildren()) do
            if child:IsA("LuaSourceContainer") then
                scripts[getPathOfInstance(child)] = {
                    name = child.Name,
                    className = child.ClassName,
                    source = child.Source,
                    lineCount = countLines(child.Source),
                }
                count = count + 1
            end
            scan(child)
        end
    end
    scan(game)
    return {scripts = scripts, count = count}
end

-- スクリプト内検索
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

-- エラーログ（error/warn のみ）
handlers.getErrors = function(params)
    local count = params.count or 50
    local filtered = {}
    for _, e in ipairs(logBuffer) do
        if e.level == "error" or e.level == "warn" then
            table.insert(filtered, e)
        end
    end
    local recent = {}
    local start = math.max(1, #filtered - count + 1)
    for i = start, #filtered do
        table.insert(recent, filtered[i])
    end
    return {errors = recent, count = #recent, totalBuffered = #filtered}
end

handlers.clearErrors = function()
    logBuffer = {}
    return {success = true}
end

-- 全ログ取得（Play中も含む、info/output も）
handlers.getOutput = function(params)
    local count = params.count or 200
    local levelFilter = params.levelFilter  -- "error", "warn", "info", "output" or nil
    local sinceTime = params.sinceTime  -- os.time ベース
    local onlyPlay = params.onlyPlay  -- trueならPlay中のみ

    local filtered = {}
    for _, e in ipairs(logBuffer) do
        if levelFilter and e.level ~= levelFilter then continue end
        if sinceTime and e.time < sinceTime then continue end
        if onlyPlay and not e.duringPlay then continue end
        table.insert(filtered, e)
    end

    local recent = {}
    local start = math.max(1, #filtered - count + 1)
    for i = start, #filtered do
        table.insert(recent, filtered[i])
    end
    return {
        output = recent,
        count = #recent,
        totalBuffered = #logBuffer,
        latestTime = #logBuffer > 0 and logBuffer[#logBuffer].time or 0,
    }
end

-- Play中の属性取得（Edit/Play両対応）
handlers.watchAttribute = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    local val = instance:GetAttribute(params.attribute)
    return {
        path = params.path,
        attribute = params.attribute,
        value = val,
        valueString = tostring(val),
        type = typeof(val),
        isRunning = RunService:IsRunning(),
        note = RunService:IsRunning() and "Plugin sees edit DataModel; Play-only attributes may not reflect here" or nil,
    }
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

-- 値のパース（拡張版）
local function parseValue(value, propType)
    if propType == "number" then
        return tonumber(value)
    elseif propType == "boolean" then
        return value == true or value == "true"
    elseif propType == "string" then
        return tostring(value)
    end

    -- 文字列前提の解析: {}/() を除去、空白トリム
    local str = tostring(value):gsub("^[%s%{%(]+", ""):gsub("[%s%}%)]+$", "")
    local parts = string.split(str, ",")
    local nums = {}
    for i, p in ipairs(parts) do nums[i] = tonumber(p:match("^%s*(.-)%s*$")) end

    if propType == "Vector3" then
        return Vector3.new(nums[1] or 0, nums[2] or 0, nums[3] or 0)
    elseif propType == "Vector2" then
        return Vector2.new(nums[1] or 0, nums[2] or 0)
    elseif propType == "Color3" then
        -- 0-255 が1つでもあれば fromRGB、全部 0-1 なら Color3.new
        local isRGB = false
        for i = 1, 3 do
            if (nums[i] or 0) > 1 then isRGB = true break end
        end
        if isRGB then
            return Color3.fromRGB(nums[1] or 0, nums[2] or 0, nums[3] or 0)
        else
            return Color3.new(nums[1] or 0, nums[2] or 0, nums[3] or 0)
        end
    elseif propType == "CFrame" then
        if #nums >= 12 then
            return CFrame.new(nums[1], nums[2], nums[3], nums[4], nums[5], nums[6],
                              nums[7], nums[8], nums[9], nums[10], nums[11], nums[12])
        elseif #nums >= 6 then
            -- 位置 + 角度(度)
            return CFrame.new(nums[1], nums[2], nums[3]) *
                   CFrame.fromEulerAnglesXYZ(math.rad(nums[4] or 0), math.rad(nums[5] or 0), math.rad(nums[6] or 0))
        else
            return CFrame.new(nums[1] or 0, nums[2] or 0, nums[3] or 0)
        end
    elseif propType == "UDim2" then
        return UDim2.new(nums[1] or 0, nums[2] or 0, nums[3] or 0, nums[4] or 0)
    elseif propType == "UDim" then
        return UDim.new(nums[1] or 0, nums[2] or 0)
    elseif propType == "NumberRange" then
        return NumberRange.new(nums[1] or 0, nums[2] or nums[1] or 0)
    elseif propType == "Enum" then
        local pp = string.split(tostring(value), ".")
        if #pp >= 3 and pp[1] == "Enum" then
            local ok, v = pcall(function() return Enum[pp[2]][pp[3]] end)
            if ok then return v end
        end
        return nil
    end
    return value
end

-- プロパティ設定
handlers.setProperty = writeGuarded(function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end

    local propType = params.valueType or "string"
    local value = parseValue(params.value, propType)
    if value == nil then
        return {error = "Failed to parse value", rawValue = tostring(params.value), valueType = propType}
    end

    local success, err = pcall(function()
        instance[params.property] = value
    end)

    if success then
        ChangeHistoryService:SetWaypoint("MCP: Set " .. params.property)
        return {success = true, value = tostring(value)}
    else
        return {error = tostring(err)}
    end
end)

-- プロパティ一括設定
handlers.setProperties = writeGuarded(function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end

    local results = {}
    for prop, val in pairs(params.properties or {}) do
        local success, err = pcall(function()
            instance[prop] = val
        end)
        results[prop] = success and "ok" or tostring(err)
    end

    ChangeHistoryService:SetWaypoint("MCP: Set multiple properties")
    return {success = true, results = results}
end)

-- インスタンス作成
handlers.createInstance = writeGuarded(function(params)
    local parent = getInstanceByPath(params.parent)
    if not parent then return {error = "Parent not found"} end

    local ok, instance = pcall(Instance.new, params.className)
    if not ok then return {error = "Failed to create instance: " .. tostring(instance)} end
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
end)

-- インスタンス削除（保護サービス対策）
handlers.deleteInstance = writeGuarded(function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end

    -- 保護
    if instance == game then return {error = "Refusing to delete game"} end
    if instance.Parent == game and PROTECTED_SERVICES[instance.Name] then
        return {error = "Refusing to delete protected service: " .. instance.Name}
    end

    local name = instance.Name
    instance:Destroy()
    ChangeHistoryService:SetWaypoint("MCP: Deleted " .. name)

    return {success = true, deleted = params.path}
end)

-- インスタンスクローン
handlers.cloneInstance = writeGuarded(function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end

    local parent = params.newParent and getInstanceByPath(params.newParent) or instance.Parent
    local clone = instance:Clone()
    if params.newName then clone.Name = params.newName end
    clone.Parent = parent

    ChangeHistoryService:SetWaypoint("MCP: Cloned " .. instance.Name)
    return {success = true, path = getPathOfInstance(clone)}
end)

-- Luaコード実行
handlers.runCode = function(params)
    local func, err = loadstring(params.code)
    if not func then
        return {
            error = "Syntax error or loadstring unavailable",
            details = tostring(err),
        }
    end

    local results = {}
    local oldPrint = print
    local oldWarn = warn
    local capturedPrint = function(...)
        local args = {...}
        local strs = {}
        for _, v in ipairs(args) do table.insert(strs, tostring(v)) end
        table.insert(results, table.concat(strs, "\t"))
        oldPrint(...)
    end
    local capturedWarn = function(...)
        local args = {...}
        local strs = {"[warn]"}
        for _, v in ipairs(args) do table.insert(strs, tostring(v)) end
        table.insert(results, table.concat(strs, "\t"))
        oldWarn(...)
    end

    local env = getfenv(func)
    local newEnv = setmetatable({print = capturedPrint, warn = capturedWarn}, {__index = env})
    setfenv(func, newEnv)

    local success, execErr = pcall(func)

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

-- バッチコマンド（per-command pcall + ChangeHistory グループ化）
handlers.batch = function(params)
    local results = {}
    local cmdCount = #(params.commands or {})
    local recordOk, recordId = pcall(function()
        return ChangeHistoryService:TryBeginRecording("MCP: Batch (" .. cmdCount .. " commands)")
    end)

    for i, cmd in ipairs(params.commands or {}) do
        local handler = handlers[cmd.command]
        if handler then
            local ok, res = pcall(handler, cmd.params or {})
            results[i] = ok and res or {error = "Handler error: " .. tostring(res)}
        else
            results[i] = {error = "Unknown command: " .. tostring(cmd.command)}
        end
    end

    if recordOk and recordId then
        pcall(function() ChangeHistoryService:FinishRecording(recordId, Enum.FinishRecordingOperation.Commit) end)
    end
    return {results = results, count = #results}
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
    for _, path in ipairs(params.paths or {}) do
        local inst = getInstanceByPath(path)
        if inst then table.insert(instances, inst) end
    end
    Selection:Set(instances)
    return {success = true, count = #instances}
end

-- Studio状態（実際の RunService から）
handlers.getStudioInfo = function()
    local isRunning = RunService:IsRunning()
    local mode = "edit"
    if isRunning then
        if RunService:IsClient() and RunService:IsServer() then mode = "run"
        elseif RunService:IsServer() then mode = "play-server"
        elseif RunService:IsClient() then mode = "play-client"
        else mode = "play" end
    end
    return {
        studioMode = mode,
        isRunning = isRunning,
        isEdit = not isRunning,
        gameId = game.GameId,
        placeId = game.PlaceId,
        pluginVersion = PLUGIN_VERSION,
        protocolVersion = PROTOCOL_VERSION,
    }
end

-- Attribute操作
handlers.getAttribute = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    local val = instance:GetAttribute(params.attribute)
    return {value = tostring(val), type = typeof(val)}
end

handlers.setAttribute = writeGuarded(function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    instance:SetAttribute(params.attribute, params.value)
    return {success = true}
end)

-- ===== 行操作 =====

handlers.getFunctionList = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    if not instance:IsA("LuaSourceContainer") then return {error = "Not a script"} end

    local functions = {}
    local lines = splitLines(instance.Source)
    for i, line in ipairs(lines) do
        -- `function ModName.foo(`, `function Mod:foo(`
        local fname = line:match("^%s*function%s+([%w_%.%:]+)%s*%(")
            or line:match("^%s*local%s+function%s+([%w_]+)%s*%(")
            -- `foo = function(`, `M.foo = function(`, `M:foo = function(` など
            or line:match("^%s*([%w_%.%:]+)%s*=%s*function%s*%(")
            or line:match("^%s*local%s+([%w_]+)%s*=%s*function%s*%(")
        if fname then
            table.insert(functions, {name = fname, line = i})
        end
    end
    return {functions = functions, count = #functions, path = params.path}
end

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

handlers.insertCode = writeGuarded(function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    if not instance:IsA("LuaSourceContainer") then return {error = "Not a script"} end

    local lines = splitLines(instance.Source)
    local afterLine = params.afterLine
    if afterLine == nil then afterLine = #lines end
    if afterLine < 0 or afterLine > #lines then
        return {error = "afterLine out of range: " .. afterLine .. " (script has " .. #lines .. " lines)"}
    end

    saveBackup(instance, instance.Source)
    local newLines = splitLines(params.code)

    local result = {}
    for i = 1, afterLine do table.insert(result, lines[i]) end
    for _, line in ipairs(newLines) do table.insert(result, line) end
    for i = afterLine + 1, #lines do table.insert(result, lines[i]) end

    local newSource = table.concat(result, "\n")
    if instance.Source:sub(-1) == "\n" then newSource = newSource .. "\n" end

    safeWriteSource(instance, newSource)
    ChangeHistoryService:SetWaypoint("MCP: Inserted code after L" .. afterLine)
    return {success = true, insertedAfter = afterLine, insertedLines = #newLines, newTotal = #result}
end)

handlers.removeLines = writeGuarded(function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    if not instance:IsA("LuaSourceContainer") then return {error = "Not a script"} end

    local lines = splitLines(instance.Source)
    local startLine = params.startLine or 1
    local endLine = params.endLine or startLine

    if startLine < 1 or endLine > #lines or startLine > endLine then
        return {error = "Invalid line range", startLine = startLine, endLine = endLine, totalLines = #lines}
    end

    saveBackup(instance, instance.Source)

    local result = {}
    for i = 1, startLine - 1 do table.insert(result, lines[i]) end
    for i = endLine + 1, #lines do table.insert(result, lines[i]) end

    local newSource = table.concat(result, "\n")
    if instance.Source:sub(-1) == "\n" and #result > 0 then newSource = newSource .. "\n" end

    safeWriteSource(instance, newSource)
    ChangeHistoryService:SetWaypoint("MCP: Removed L" .. startLine .. "-" .. endLine)
    return {success = true, removed = startLine .. "-" .. endLine, oldTotal = #lines, newTotal = #result}
end)

-- 文字列置換（newText も適切にエスケープ）
handlers.replaceInScript = writeGuarded(function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    if not instance:IsA("LuaSourceContainer") then return {error = "Not a script"} end

    local oldText = params.oldText
    local newText = params.newText
    if not oldText or newText == nil then return {error = "oldText and newText required"} end

    local source = instance.Source
    local pos = source:find(oldText, 1, true)
    if not pos then return {error = "Text not found in script", searchedFor = oldText:sub(1, 100)} end

    saveBackup(instance, source)

    local newSource
    local count = 0
    if params.replaceAll then
        local escapedOld = oldText:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
        local escapedNew = newText:gsub("%%", "%%%%")
        newSource, count = source:gsub(escapedOld, escapedNew)
    else
        newSource = source:sub(1, pos - 1) .. newText .. source:sub(pos + #oldText)
        count = 1
    end

    local syntaxSkipped = false
    if not params.skipSyntaxCheck then
        local syntaxResult = checkSyntax(newSource)
        if not syntaxResult.valid then
            return {error = "Syntax error after replace - NOT applied", syntaxError = syntaxResult.error}
        end
        syntaxSkipped = syntaxResult.skipped == true
    end

    safeWriteSource(instance, newSource)
    ChangeHistoryService:SetWaypoint("MCP: Replace in " .. instance.Name)
    return {success = true, replacements = count, firstReplacedAt = pos, syntaxCheckSkipped = syntaxSkipped}
end)

-- スクリプト検証
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

-- モジュール依存関係
handlers.getModuleDependencies = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    if not instance:IsA("LuaSourceContainer") then return {error = "Not a script"} end

    local deps = {}
    for line in instance.Source:gmatch("[^\n]+") do
        local req = line:match("require%s*%(%s*(.-)%s*%)")
        if req then table.insert(deps, req:gsub("%s+$", "")) end
    end
    return {dependencies = deps, count = #deps, path = params.path}
end

-- 変数/関数の全使用箇所検索
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

        local gvar = line:match("^([%w_%.]+)%s*=")
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

local function isProtected(instance)
    if instance == game then return true end
    return instance.Parent == game and PROTECTED_SERVICES[instance.Name]
end

-- リネーム
handlers.renameInstance = writeGuarded(function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    if isProtected(instance) then
        return {error = "Refusing to rename protected service: " .. instance.Name}
    end
    local oldName = instance.Name
    local ok, err = pcall(function() instance.Name = params.newName end)
    if not ok then return {error = tostring(err)} end
    ChangeHistoryService:SetWaypoint("MCP: Renamed " .. oldName .. " -> " .. params.newName)
    return {success = true, oldName = oldName, newName = params.newName, newPath = getPathOfInstance(instance)}
end)

-- 移動
handlers.moveInstance = writeGuarded(function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    if isProtected(instance) then
        return {error = "Refusing to move protected service: " .. instance.Name}
    end
    local newParent = getInstanceByPath(params.newParent)
    if not newParent then return {error = "New parent not found"} end
    local ok, err = pcall(function() instance.Parent = newParent end)
    if not ok then return {error = tostring(err)} end
    ChangeHistoryService:SetWaypoint("MCP: Moved " .. instance.Name)
    return {success = true, newPath = getPathOfInstance(instance)}
end)

-- 子要素だけ取得
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

-- ===== v4.2 Phase 2 =====

-- 座標近傍のパーツ検索
handlers.findPartsNear = function(params)
    local px = tonumber(params.x) or 0
    local py = tonumber(params.y) or 0
    local pz = tonumber(params.z) or 0
    local center = Vector3.new(px, py, pz)
    local radius = tonumber(params.radius) or 10
    local root = params.root and getInstanceByPath(params.root) or workspace

    local filterName = params.name  -- 部分一致
    local filterClass = params.className
    local filterCanCollide = params.canCollide  -- true/false/nil
    local filterMinSizeY = tonumber(params.minSizeY)  -- 壁検出用
    local limit = tonumber(params.limit) or 50

    local hits = {}
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("BasePart") then
            local dist = (d.Position - center).Magnitude
            if dist <= radius then
                local match = true
                if filterName and not d.Name:lower():find(filterName:lower(), 1, true) then match = false end
                if filterClass and d.ClassName ~= filterClass then match = false end
                if filterCanCollide ~= nil and d.CanCollide ~= filterCanCollide then match = false end
                if filterMinSizeY and d.Size.Y < filterMinSizeY then match = false end
                if match then
                    table.insert(hits, {
                        path = getPathOfInstance(d),
                        name = d.Name,
                        className = d.ClassName,
                        dist = math.floor(dist * 100) / 100,
                        pos = tostring(d.Position),
                        size = tostring(d.Size),
                        canCollide = d.CanCollide,
                        transparency = d.Transparency,
                    })
                end
            end
        end
    end
    table.sort(hits, function(a, b) return a.dist < b.dist end)
    if #hits > limit then
        for i = limit + 1, #hits do hits[i] = nil end
    end
    return {results = hits, count = #hits, center = tostring(center), radius = radius}
end

-- 複数プロパティを複数インスタンスに一括設定
handlers.bulkUpdate = writeGuarded(function(params)
    local updates = params.updates or {}
    local success, failed = 0, {}
    local recordOk, recordId = pcall(function()
        return ChangeHistoryService:TryBeginRecording("MCP: Bulk Update (" .. #updates .. ")")
    end)

    for _, u in ipairs(updates) do
        local inst = getInstanceByPath(u.path)
        if not inst then
            table.insert(failed, {path = u.path, reason = "not found"})
        else
            for prop, val in pairs(u.props or {}) do
                local ok, err = pcall(function() inst[prop] = val end)
                if ok then
                    success = success + 1
                else
                    table.insert(failed, {path = u.path, prop = prop, reason = tostring(err)})
                end
            end
        end
    end

    if recordOk and recordId then
        -- atomic=true なら部分失敗で全取消
        local finishOp = (params.atomic and #failed > 0)
            and Enum.FinishRecordingOperation.Cancel
            or Enum.FinishRecordingOperation.Commit
        pcall(function() ChangeHistoryService:FinishRecording(recordId, finishOp) end)
    else
        ChangeHistoryService:SetWaypoint("MCP: Bulk Update")
    end

    return {
        success = success,
        failed = failed,
        failCount = #failed,
        atomic = params.atomic == true,
        cancelled = params.atomic == true and #failed > 0,
    }
end)

-- Workspace のスナップショット（diff 用）
local snapshots = {}
local function snapshotTree(root, depth, currentDepth)
    currentDepth = currentDepth or 0
    local data = {
        name = root.Name,
        className = root.ClassName,
        childCount = #root:GetChildren(),
    }
    if root:IsA("BasePart") then
        data.pos = tostring(root.Position)
        data.size = tostring(root.Size)
    end
    if currentDepth < depth then
        data.children = {}
        for _, c in ipairs(root:GetChildren()) do
            data.children[c.Name .. ":" .. c.ClassName] = snapshotTree(c, depth, currentDepth + 1)
        end
    end
    return data
end

handlers.snapshot = function(params)
    local label = params.label or "default"
    local rootPath = params.root or "game.Workspace"
    local root = getInstanceByPath(rootPath)
    if not root then return {error = "Root not found: " .. rootPath} end
    local depth = tonumber(params.depth) or 3
    snapshots[label] = {
        tree = snapshotTree(root, depth),
        root = rootPath,
        depth = depth,
        time = os.time(),
    }
    return {success = true, label = label, root = rootPath, depth = depth}
end

-- 2つのスナップショット or 現在との diff
local function diffTrees(a, b, path)
    path = path or ""
    local diffs = {}
    if not a and b then
        table.insert(diffs, {op = "added", path = path, className = b.className})
        return diffs
    elseif a and not b then
        table.insert(diffs, {op = "removed", path = path, className = a.className})
        return diffs
    end
    if a.className ~= b.className then
        table.insert(diffs, {op = "classChanged", path = path, from = a.className, to = b.className})
    end
    if a.pos ~= b.pos then
        table.insert(diffs, {op = "moved", path = path, from = a.pos, to = b.pos})
    end
    if a.size ~= b.size then
        table.insert(diffs, {op = "resized", path = path, from = a.size, to = b.size})
    end
    local aChildren = a.children or {}
    local bChildren = b.children or {}
    local keys = {}
    for k in pairs(aChildren) do keys[k] = true end
    for k in pairs(bChildren) do keys[k] = true end
    for k in pairs(keys) do
        local childPath = path == "" and k or (path .. "/" .. k)
        local subDiffs = diffTrees(aChildren[k], bChildren[k], childPath)
        for _, d in ipairs(subDiffs) do table.insert(diffs, d) end
    end
    return diffs
end

handlers.diffFromSnapshot = function(params)
    local label = params.label or "default"
    local old = snapshots[label]
    if not old then return {error = "No snapshot with label: " .. label} end
    local root = getInstanceByPath(old.root)
    if not root then return {error = "Root no longer exists: " .. old.root} end
    local current = snapshotTree(root, old.depth)
    local diffs = diffTrees(old.tree, current, old.root)
    return {diffs = diffs, count = #diffs, snapshotTime = old.time, now = os.time()}
end

handlers.listSnapshots = function()
    local list = {}
    for k, s in pairs(snapshots) do
        table.insert(list, {label = k, root = s.root, depth = s.depth, time = s.time})
    end
    return {snapshots = list, count = #list}
end

handlers.deleteSnapshot = function(params)
    if not params.label then return {error = "label required"} end
    if snapshots[params.label] then
        snapshots[params.label] = nil
        return {success = true, deleted = params.label}
    end
    return {error = "No snapshot with label: " .. params.label}
end

-- スナップショット数の上限（古いのから削除）
local MAX_SNAPSHOTS = 20
local originalSnapshot = handlers.snapshot
handlers.snapshot = function(params)
    local res = originalSnapshot(params)
    -- 上限超えたら古い順に削除
    local entries = {}
    for k, v in pairs(snapshots) do
        table.insert(entries, {label = k, time = v.time})
    end
    if #entries > MAX_SNAPSHOTS then
        table.sort(entries, function(a, b) return a.time < b.time end)
        for i = 1, #entries - MAX_SNAPSHOTS do
            snapshots[entries[i].label] = nil
        end
    end
    return res
end

-- setScript プレビュー (diff表示、書き込みなし)
handlers.previewSetScript = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    if not instance:IsA("LuaSourceContainer") then return {error = "Not a script"} end

    local old = splitLines(instance.Source)
    local new = splitLines(params.source)

    -- 簡易 line diff (LCS ベースの最小版)
    local diff = {}
    local maxLen = math.max(#old, #new)
    local changed, added, removed = 0, 0, 0
    for i = 1, maxLen do
        if old[i] == nil then
            table.insert(diff, {op = "add", line = i, content = new[i]})
            added = added + 1
        elseif new[i] == nil then
            table.insert(diff, {op = "del", line = i, content = old[i]})
            removed = removed + 1
        elseif old[i] ~= new[i] then
            table.insert(diff, {op = "change", line = i, from = old[i], to = new[i]})
            changed = changed + 1
        end
    end

    local syntaxResult = checkSyntax(params.source)
    return {
        diff = diff,
        stats = {changed = changed, added = added, removed = removed},
        oldLineCount = #old,
        newLineCount = #new,
        syntaxValid = syntaxResult.valid,
        syntaxError = syntaxResult.error,
    }
end

-- RemoteEvent の引数ログ（既存 RemoteEvent にフック）
local remoteEventLog = {}
local MAX_REMOTE_LOG = 100
local hookedRemotes = setmetatable({}, {__mode = "k"})

local function hookRemote(rem)
    if hookedRemotes[rem] then return end
    hookedRemotes[rem] = true
    if rem:IsA("RemoteEvent") then
        -- クライアント→サーバー (サーバー側で受信)
        rem.OnServerEvent:Connect(function(player, ...)
            table.insert(remoteEventLog, {
                time = os.time(),
                name = rem.Name,
                path = getPathOfInstance(rem),
                direction = "C2S",
                player = player.Name,
                args = table.pack(...),
            })
            if #remoteEventLog > MAX_REMOTE_LOG then table.remove(remoteEventLog, 1) end
        end)
    end
end

-- 新規 RemoteEvent を自動フック（起動時に1回接続）
local remoteAutoHookConnected = false
local function ensureRemoteAutoHook()
    if remoteAutoHookConnected then return end
    remoteAutoHookConnected = true
    game.DescendantAdded:Connect(function(d)
        if d:IsA("RemoteEvent") then hookRemote(d) end
    end)
end

handlers.inspectRemoteEvents = function(params)
    ensureRemoteAutoHook()
    -- 既存 RemoteEvent を全部フック
    for _, d in ipairs(game:GetDescendants()) do
        if d:IsA("RemoteEvent") then hookRemote(d) end
    end
    -- ログ取得
    local count = params.count or 20
    local recent = {}
    local start = math.max(1, #remoteEventLog - count + 1)
    for i = start, #remoteEventLog do
        local e = remoteEventLog[i]
        table.insert(recent, {
            time = e.time,
            name = e.name,
            path = e.path,
            direction = e.direction,
            player = e.player,
            argCount = e.args and e.args.n or 0,
            args = e.args and table.concat((function()
                local s = {}
                for i = 1, e.args.n do s[i] = tostring(e.args[i]):sub(1, 50) end
                return s
            end)(), ", ") or "",
        })
    end
    return {events = recent, count = #recent, totalBuffered = #remoteEventLog, hookedCount = #(function()
        local c = {}
        for r in pairs(hookedRemotes) do table.insert(c, r) end
        return c
    end)()}
end

-- ===== v5.0 Measurement / Batch / Diff / Collision / Performance =====

-- 2点間の距離測定
handlers.measureDistance = function(params)
    local a = getInstanceByPath(params.pathA)
    local b = getInstanceByPath(params.pathB)
    if not a or not b then return {error = "One or both instances not found"} end
    local posA = a:IsA("BasePart") and a.Position or (a.PrimaryPart and a.PrimaryPart.Position)
    local posB = b:IsA("BasePart") and b.Position or (b.PrimaryPart and b.PrimaryPart.Position)
    if not posA or not posB then return {error = "Cannot determine position"} end
    return {
        distance = (posA - posB).Magnitude,
        posA = tostring(posA),
        posB = tostring(posB),
        delta = tostring(posA - posB),
    }
end

-- モデルのバウンディングボックス
handlers.measureBounds = function(params)
    local root = getInstanceByPath(params.path)
    if not root then return {error = "Instance not found"} end

    local parts = {}
    if root:IsA("BasePart") then
        table.insert(parts, root)
    else
        for _, d in ipairs(root:GetDescendants()) do
            if d:IsA("BasePart") then table.insert(parts, d) end
        end
    end
    if #parts == 0 then return {error = "No BaseParts found"} end

    local minV = Vector3.new(math.huge, math.huge, math.huge)
    local maxV = Vector3.new(-math.huge, -math.huge, -math.huge)
    for _, p in ipairs(parts) do
        local pos, size = p.Position, p.Size
        local half = size / 2
        minV = Vector3.new(math.min(minV.X, pos.X - half.X), math.min(minV.Y, pos.Y - half.Y), math.min(minV.Z, pos.Z - half.Z))
        maxV = Vector3.new(math.max(maxV.X, pos.X + half.X), math.max(maxV.Y, pos.Y + half.Y), math.max(maxV.Z, pos.Z + half.Z))
    end
    local size = maxV - minV
    return {
        min = tostring(minV),
        max = tostring(maxV),
        center = tostring((minV + maxV) / 2),
        size = tostring(size),
        volume = size.X * size.Y * size.Z,
        partCount = #parts,
    }
end

-- 複数コード連続実行（上限あり）
local MAX_BATCH_SNIPPETS = 50
handlers.batchRunCode = function(params)
    local snippets = params.snippets or {}
    if #snippets > MAX_BATCH_SNIPPETS then
        return {error = "Too many snippets: " .. #snippets .. " > " .. MAX_BATCH_SNIPPETS}
    end
    local results = {}
    for i, code in ipairs(snippets) do
        local ok, res = pcall(handlers.runCode, {code = code})
        results[i] = ok and res or {error = "Handler error: " .. tostring(res)}
    end
    return {results = results, count = #results}
end

-- バックアップ2つの diff
handlers.diffBackup = function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    local history = backupHistory[instance]
    if not history or #history < 2 then
        return {error = "Need at least 2 backups; currently " .. (history and #history or 0)}
    end

    local idxA = params.indexA or (#history - 1)
    local idxB = params.indexB or #history
    local a = history[idxA]
    local b = history[idxB]
    if not a or not b then return {error = "Backup index out of range"} end

    local oldLines = splitLines(a.source)
    local newLines = splitLines(b.source)
    local diff = {}
    local changed, added, removed = 0, 0, 0
    local maxLen = math.max(#oldLines, #newLines)
    for i = 1, maxLen do
        if oldLines[i] == nil then
            table.insert(diff, {op = "add", line = i, content = newLines[i]}); added = added + 1
        elseif newLines[i] == nil then
            table.insert(diff, {op = "del", line = i, content = oldLines[i]}); removed = removed + 1
        elseif oldLines[i] ~= newLines[i] then
            table.insert(diff, {op = "change", line = i, from = oldLines[i], to = newLines[i]}); changed = changed + 1
        end
    end
    return {
        diff = diff,
        stats = {changed = changed, added = added, removed = removed},
        indexA = idxA, indexB = idxB,
        timeA = a.timestamp, timeB = b.timestamp,
    }
end

-- 関数キーワード セマンティック検索
handlers.suggestFunctionLocation = function(params)
    local keyword = params.keyword
    if not keyword or keyword == "" then return {error = "keyword required"} end

    local results = {}
    local function scan(parent)
        for _, child in ipairs(parent:GetChildren()) do
            if child:IsA("LuaSourceContainer") then
                local lines = splitLines(child.Source)
                for i, line in ipairs(lines) do
                    local fname = line:match("^%s*function%s+([%w_%.%:]+)%s*%(")
                        or line:match("^%s*local%s+function%s+([%w_]+)%s*%(")
                        or line:match("^%s*([%w_%.%:]+)%s*=%s*function%s*%(")
                    if fname and fname:lower():find(keyword:lower(), 1, true) then
                        -- 関数の周辺コンテキストも添える
                        local contextLines = {}
                        for j = i, math.min(i + 5, #lines) do
                            table.insert(contextLines, lines[j])
                        end
                        table.insert(results, {
                            path = getPathOfInstance(child),
                            scriptName = child.Name,
                            functionName = fname,
                            line = i,
                            preview = table.concat(contextLines, "\n"):sub(1, 300),
                        })
                    end
                end
            end
            scan(child)
        end
    end
    scan(game)
    return {results = results, count = #results, keyword = keyword}
end

-- Collision Groups
handlers.listCollisionGroups = function()
    local PS = game:GetService("PhysicsService")
    local groups = PS:GetRegisteredCollisionGroups()
    local result = {}
    for _, g in ipairs(groups) do
        table.insert(result, {id = g.id, name = g.name, mask = g.mask})
    end
    return {groups = result, count = #result}
end

handlers.createCollisionGroup = writeGuarded(function(params)
    local PS = game:GetService("PhysicsService")
    local ok, err = pcall(function() PS:RegisterCollisionGroup(params.name) end)
    if not ok then return {error = tostring(err)} end
    return {success = true, name = params.name}
end)

handlers.setPartCollisionGroup = writeGuarded(function(params)
    local instance = getInstanceByPath(params.path)
    if not instance or not instance:IsA("BasePart") then return {error = "Not a BasePart"} end
    instance.CollisionGroup = params.groupName
    ChangeHistoryService:SetWaypoint("MCP: Set CollisionGroup")
    return {success = true}
end)

handlers.setCollisionGroupCollidable = writeGuarded(function(params)
    local PS = game:GetService("PhysicsService")
    local ok, err = pcall(function() PS:CollisionGroupSetCollidable(params.groupA, params.groupB, params.collidable) end)
    if not ok then return {error = tostring(err)} end
    return {success = true}
end)

-- パフォーマンス統計
handlers.getPerformanceStats = function()
    local Stats = game:GetService("Stats")
    local data = {
        time = os.time(),
    }
    pcall(function()
        data.physicsFPS = math.floor(workspace:GetRealPhysicsFPS())
    end)
    pcall(function()
        data.heartbeatTime = Stats.HeartbeatTimeMs:GetValue()
    end)
    pcall(function()
        data.dataSendKBps = Stats.DataSendKbps:GetValue()
        data.dataReceiveKBps = Stats.DataReceiveKbps:GetValue()
    end)
    pcall(function()
        data.memoryMB = math.floor(Stats:GetTotalMemoryUsageMb())
    end)
    pcall(function()
        local itemCount = 0
        for _ in pairs(game:GetDescendants()) do itemCount = itemCount + 1 end
        data.instanceCount = itemCount
    end)
    return data
end

-- Model 最適化の提案（削除はしない、提案のみ）
handlers.suggestModelOptimizations = function(params)
    local root = getInstanceByPath(params.path or "game.Workspace")
    if not root then return {error = "Root not found"} end

    local transparentInvisible = 0
    local zeroSized = 0
    local duplicateNames = {}
    local nameCount = {}

    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("BasePart") then
            if d.Transparency >= 1 and not d.CanCollide and not d.CanQuery then
                transparentInvisible = transparentInvisible + 1
            end
            if d.Size.X < 0.1 and d.Size.Y < 0.1 and d.Size.Z < 0.1 then
                zeroSized = zeroSized + 1
            end
        end
        nameCount[d.Name] = (nameCount[d.Name] or 0) + 1
    end

    for name, c in pairs(nameCount) do
        if c >= 10 then
            table.insert(duplicateNames, {name = name, count = c})
        end
    end
    table.sort(duplicateNames, function(a, b) return a.count > b.count end)

    return {
        transparentInvisibleParts = transparentInvisible,
        zeroSizedParts = zeroSized,
        topDuplicateNames = duplicateNames,
        suggestion = (transparentInvisible + zeroSized > 0)
            and "透明+不可視やゼロサイズのパーツを削除すると軽量化できます"
            or "大きな最適化ポイントは見つかりませんでした",
    }
end

-- ===== v5.1 =====

-- 直近の変更を N 回 Undo/Redo (ユーザー操作も対象になることに注意)
handlers.undoLast = writeGuarded(function(params)
    local count = tonumber(params.count) or 1
    local undone = 0
    for i = 1, count do
        local ok = pcall(function() ChangeHistoryService:Undo() end)
        if ok then undone = undone + 1 else break end
    end
    return {success = true, undone = undone,
        note = "ChangeHistoryService:Undo() は最後の Waypoint を1つ戻します。ユーザー手動操作も対象になります"}
end)

handlers.redoLast = writeGuarded(function(params)
    local count = tonumber(params.count) or 1
    local redone = 0
    for i = 1, count do
        local ok = pcall(function() ChangeHistoryService:Redo() end)
        if ok then redone = redone + 1 else break end
    end
    return {success = true, redone = redone}
end)

-- 旧名前も互換のため残す (deprecated)
handlers.undoLastMcpChange = handlers.undoLast
handlers.redoLastMcpChange = handlers.redoLast

-- JSON からGUI生成（UI系クラスのみホワイトリスト）
local ALLOWED_UI_CLASSES = {
    ScreenGui = true, SurfaceGui = true, BillboardGui = true,
    Frame = true, ScrollingFrame = true, ViewportFrame = true,
    TextLabel = true, TextButton = true, TextBox = true,
    ImageLabel = true, ImageButton = true,
    CanvasGroup = true, VideoFrame = true,
    UICorner = true, UIStroke = true, UIGradient = true, UIPadding = true,
    UIListLayout = true, UIGridLayout = true, UITableLayout = true, UIPageLayout = true,
    UISizeConstraint = true, UIAspectRatioConstraint = true, UITextSizeConstraint = true,
    UIScale = true, UIFlexItem = true,
    Folder = true,  -- UI のグルーピング用
}

local function buildUI(spec, parent)
    if type(spec) ~= "table" or not spec.type then return nil, "spec must have type" end
    if not ALLOWED_UI_CLASSES[spec.type] then
        return nil, "disallowed class: " .. tostring(spec.type) .. " (UI系のみ許可)"
    end
    local ok, instance = pcall(Instance.new, spec.type)
    if not ok then return nil, "Failed to create " .. tostring(spec.type) end

    if spec.props then
        for k, v in pairs(spec.props) do
            pcall(function()
                -- 型推論: "{0,100,0,50}" → UDim2, "255,100,50" + Color3フィールド名 → Color3
                if type(v) == "string" then
                    if v:match("^%s*[%{%(]") then
                        -- Vector3/UDim2/CFrame 推定
                        local stripped = v:gsub("[%{%(%)%}]", "")
                        local parts = {}
                        for n in stripped:gmatch("[^,]+") do table.insert(parts, tonumber(n:match("^%s*(.-)%s*$"))) end
                        if #parts == 4 then instance[k] = UDim2.new(parts[1], parts[2], parts[3], parts[4])
                        elseif #parts == 3 then instance[k] = Vector3.new(parts[1], parts[2], parts[3])
                        elseif #parts == 2 then instance[k] = UDim.new(parts[1], parts[2])
                        else instance[k] = v end
                    elseif k:lower():find("color") then
                        local stripped = v:gsub("[%{%(%)%}]", "")
                        local parts = {}
                        for n in stripped:gmatch("[^,]+") do table.insert(parts, tonumber(n:match("^%s*(.-)%s*$"))) end
                        if #parts == 3 then
                            local isRGB = false
                            for _, n in ipairs(parts) do if n > 1 then isRGB = true end end
                            instance[k] = isRGB and Color3.fromRGB(parts[1], parts[2], parts[3]) or Color3.new(parts[1], parts[2], parts[3])
                        end
                    else
                        instance[k] = v
                    end
                else
                    instance[k] = v
                end
            end)
        end
    end

    if spec.children then
        for _, childSpec in ipairs(spec.children) do
            buildUI(childSpec, instance)
        end
    end

    instance.Parent = parent
    return instance, nil
end

handlers.generateUIFromSpec = writeGuarded(function(params)
    local parent = getInstanceByPath(params.parent or "game.StarterGui")
    if not parent then return {error = "Parent not found"} end
    -- UI系への配置に限定
    local parentOK = parent:IsA("StarterGui") or parent:IsA("PlayerGui")
        or parent:IsA("GuiObject") or parent:IsA("LayerCollector")
        or parent:IsA("SurfaceGui") or parent:IsA("BillboardGui")
        or parent == game:GetService("StarterGui")
    if not parentOK then
        return {error = "Parent must be a GUI container (StarterGui/ScreenGui/GuiObject/SurfaceGui/BillboardGui)"}
    end
    local spec = params.spec
    if type(spec) ~= "table" then return {error = "spec must be a table"} end

    local instance, err = buildUI(spec, parent)
    if not instance then return {error = err} end
    ChangeHistoryService:SetWaypoint("MCP: Generate UI")

    local function countDesc(inst)
        local c = 1
        for _, ch in ipairs(inst:GetChildren()) do c = c + countDesc(ch) end
        return c
    end

    return {
        success = true,
        path = getPathOfInstance(instance),
        totalInstances = countDesc(instance),
    }
end)

-- ===== v5.2 デバッグヘルパー =====

-- 透明 + CanCollide=true な Part を列挙（"透明の壁" の発見用）
handlers.findInvisibleObstacles = function(params)
    local root = params.root and getInstanceByPath(params.root) or workspace
    if not root then return {error = "Root not found"} end
    local transparencyThreshold = params.transparencyThreshold or 0.9
    local limit = params.limit or 50

    local found = {}
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("BasePart") and d.CanCollide and d.Transparency >= transparencyThreshold then
            table.insert(found, {
                path = getPathOfInstance(d),
                name = d.Name,
                className = d.ClassName,
                pos = tostring(d.Position),
                size = tostring(d.Size),
                transparency = d.Transparency,
            })
        end
    end
    if #found > limit then
        for i = limit + 1, #found do found[i] = nil end
    end
    return {results = found, count = #found, threshold = transparencyThreshold}
end

-- プレイヤーが引っかかってる原因を診断（位置 + 4方向 raycast + 触れてるパーツ）
handlers.diagnoseStuckCharacter = function(params)
    local Players = game:GetService("Players")
    local playerName = params.playerName
    local player = playerName and Players:FindFirstChild(playerName) or Players:GetPlayers()[1]
    if not player then return {error = "No player found"} end
    local char = player.Character
    if not char then return {error = "Character not found"} end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return {error = "HumanoidRootPart not found"} end

    local pos = hrp.Position
    local params_ = RaycastParams.new()
    params_.FilterType = Enum.RaycastFilterType.Exclude
    params_.FilterDescendantsInstances = {char}

    local function cast(dirName, dirVec)
        local rr = workspace:Raycast(pos, dirVec, params_)
        if rr then
            local p = rr.Instance
            local path = getPathOfInstance(p)
            return {
                dir = dirName,
                hit = path,
                className = p.ClassName,
                dist = (rr.Position - pos).Magnitude,
                canCollide = p.CanCollide,
                transparency = p.Transparency,
            }
        end
        return {dir = dirName, clear = true}
    end

    local look = hrp.CFrame.LookVector
    local right = hrp.CFrame.RightVector

    -- 触れてるパーツ (Touching)
    local touching = {}
    local ok = pcall(function()
        for _, p in ipairs(hrp:GetTouchingParts()) do
            table.insert(touching, {
                path = getPathOfInstance(p),
                name = p.Name,
                canCollide = p.CanCollide,
                transparency = p.Transparency,
            })
        end
    end)

    return {
        playerName = player.Name,
        position = tostring(pos),
        velocity = tostring(hrp.AssemblyLinearVelocity),
        casts = {
            cast("forward", look * 6),
            cast("back", -look * 6),
            cast("right", right * 6),
            cast("left", -right * 6),
            cast("up", Vector3.new(0, 6, 0)),
            cast("down", Vector3.new(0, -6, 0)),
        },
        touching = touching,
        touchingCount = #touching,
    }
end

-- GameConfig.WEAPONS から武器バランスレポート生成
handlers.balanceReport = function(params)
    local RS = game:GetService("ReplicatedStorage")
    local ok, Config = pcall(function() return require(RS.Modules.GameConfig) end)
    if not ok or not Config or not Config.WEAPONS then
        return {error = "Cannot load GameConfig or WEAPONS missing"}
    end

    local hp = Config.MAX_HP or 100
    local report = {}
    for id, w in pairs(Config.WEAPONS) do
        local damagePerShot = (w.damage or 0) * (w.pellets or 1)
        local dps = damagePerShot / math.max(0.001, w.fireRate or 0.1)
        local ttk = hp / dps
        table.insert(report, {
            id = id,
            name = w.name or id,
            damage = w.damage,
            pellets = w.pellets or 1,
            damagePerShot = damagePerShot,
            fireRate = w.fireRate,
            dps = math.floor(dps * 10) / 10,
            ttk = math.floor(ttk * 100) / 100,
            range = w.range,
            magSize = w.magSize,
            auto = w.auto or false,
            bulletSpeed = w.bulletSpeed,
        })
    end
    table.sort(report, function(a, b) return a.dps > b.dps end)
    return {weapons = report, maxHP = hp, count = #report}
end

-- ===== ポーリングループ =====

local running = true
local lastSuccessfulPoll = 0
local consecutiveFailures = 0

local function pollServer()
    while running do
        local success, response = pcall(function()
            return HttpService:RequestAsync({
                Url = MCP_SERVER_URL .. "/poll",
                Method = "GET",
                Headers = {
                    ["Content-Type"] = "application/json",
                    ["X-Plugin-Version"] = PLUGIN_VERSION,
                    ["X-Protocol-Version"] = tostring(PROTOCOL_VERSION),
                },
            })
        end)

        if success and response.Success then
            lastSuccessfulPoll = os.time()
            consecutiveFailures = 0
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

                -- /result POST はリトライ付き (最大3回)
                local body = HttpService:JSONEncode({id = data.id, result = result})
                local delivered = false
                for attempt = 1, 3 do
                    local postOk = pcall(function()
                        HttpService:RequestAsync({
                            Url = MCP_SERVER_URL .. "/result",
                            Method = "POST",
                            Headers = {["Content-Type"] = "application/json"},
                            Body = body,
                        })
                    end)
                    if postOk then delivered = true; break end
                    task.wait(0.2 * attempt)
                end
                if not delivered then
                    warn("[MCP] Failed to deliver result for id " .. tostring(data.id))
                end
            end
        else
            consecutiveFailures = consecutiveFailures + 1
        end

        -- 連続失敗でバックオフ（最大 5 秒）
        local wait_s = POLL_INTERVAL
        if consecutiveFailures > 3 then
            wait_s = math.min(5, POLL_INTERVAL * 2 ^ math.min(4, consecutiveFailures - 3))
        end
        task.wait(wait_s)
    end
end

-- プラグインツールバー
if plugin then
    local toolbar = plugin:CreateToolbar("MCP Server v" .. PLUGIN_VERSION)
    local button = toolbar:CreateButton("Toggle MCP", "Start/Stop MCP Server", "rbxassetid://4458901886")

    button.Click:Connect(function()
        running = not running
        if running then
            print("[MCP Plugin v" .. PLUGIN_VERSION .. "] Started")
            task.spawn(pollServer)
        else
            print("[MCP Plugin v" .. PLUGIN_VERSION .. "] Stopped")
        end
    end)

    print("[MCP Plugin v" .. PLUGIN_VERSION .. "] Auto-starting...")
    task.spawn(pollServer)
end
