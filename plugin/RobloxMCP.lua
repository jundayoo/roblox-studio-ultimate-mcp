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

local PLUGIN_VERSION = "4.0.0"
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

-- ===== エラーログバッファ =====
local errorBuffer = {}
local MAX_ERRORS = 50

LogService.MessageOut:Connect(function(message, messageType)
    if messageType == Enum.MessageType.MessageError or messageType == Enum.MessageType.MessageWarning then
        table.insert(errorBuffer, {
            message = message,
            type = tostring(messageType),
            time = os.time(),
        })
        if #errorBuffer > MAX_ERRORS then
            table.remove(errorBuffer, 1)
        end
    end
end)

-- ===== ユーティリティ =====

-- パス → Instance（"game.X.Y" 形式。先頭 game はオプション）
local function getInstanceByPath(path)
    if not path or path == "" then return nil end
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

-- エラーログ
handlers.getErrors = function(params)
    local count = params.count or MAX_ERRORS
    local recent = {}
    local start = math.max(1, #errorBuffer - count + 1)
    for i = start, #errorBuffer do
        table.insert(recent, errorBuffer[i])
    end
    return {errors = recent, count = #recent, totalBuffered = #errorBuffer}
end

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

-- バッチコマンド（per-command pcall）
handlers.batch = function(params)
    local results = {}
    for i, cmd in ipairs(params.commands or {}) do
        local handler = handlers[cmd.command]
        if handler then
            local ok, res = pcall(handler, cmd.params or {})
            results[i] = ok and res or {error = "Handler error: " .. tostring(res)}
        else
            results[i] = {error = "Unknown command: " .. tostring(cmd.command)}
        end
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

-- リネーム
handlers.renameInstance = writeGuarded(function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    local oldName = instance.Name
    instance.Name = params.newName
    ChangeHistoryService:SetWaypoint("MCP: Renamed " .. oldName .. " -> " .. params.newName)
    return {success = true, oldName = oldName, newName = params.newName, newPath = getPathOfInstance(instance)}
end)

-- 移動
handlers.moveInstance = writeGuarded(function(params)
    local instance = getInstanceByPath(params.path)
    if not instance then return {error = "Instance not found"} end
    local newParent = getInstanceByPath(params.newParent)
    if not newParent then return {error = "New parent not found"} end
    instance.Parent = newParent
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
