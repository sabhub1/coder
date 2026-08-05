-- Venom Hub (mutually exclusive modes + owner-first-person handling)
-- Tailored for "Steal a Brainrot" announcements: when an announcement uses first-person
-- pronouns (I, my, we, etc.) it will be treated as coming from the game's owner.

-- Services & Globals
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TeleportService = game:GetService("TeleportService")
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local CONFIG_FILE = "VenomHub_config.json"
local GAME_NAME = "Steal a Brainrot"

local defaultConfig = {
    ModeNormal = true,
    ModeRiddle = false,
    RiddleWordThreshold = 10,
    RiddleDelay = 0.5,
    EnableNotifications = true,
    AutoRejoin = false,
    Minimized = false,
}

local config = {}
local redeemedCodes = {}
local processedAnnouncements = {}
local riddleBuffer = {}
local listeners = {}
local hasReadFile, hasWriteFile = type(readfile) == "function", type(writefile) == "function"

local HttpService
local function ensureHttp()
    if not HttpService then HttpService = game:GetService("HttpService") end
end

-- Try to detect game owner name (if user creator)
local ownerName = "Owner"
pcall(function()
    if game.CreatorType == Enum.CreatorType.User then
        local id = game.CreatorId
        if id and type(id) == "number" then
            local ok, name = pcall(function() return Players:GetNameFromUserIdAsync(id) end)
            if ok and type(name) == "string" and name ~= "" then
                ownerName = name
            end
        end
    else
        -- group or unknown
        ownerName = "Game Owner"
    end
end)

-- Config load/save
local function loadConfig()
    config = {}
    for k,v in pairs(defaultConfig) do config[k] = v end
    if hasReadFile and hasWriteFile then
        local ok, content = pcall(readfile, CONFIG_FILE)
        if ok and content then
            pcall(function()
                ensureHttp()
                local parsed = HttpService:JSONDecode(content)
                if type(parsed) == "table" then
                    for k,v in pairs(parsed) do config[k] = v end
                end
            end)
        end
    end
    return config
end

local function saveConfig()
    if not (hasWriteFile and hasReadFile) then return end
    pcall(function()
        ensureHttp()
        writefile(CONFIG_FILE, HttpService:JSONEncode(config))
    end)
end

-- Notifications
local function sendNotification(title, text, duration)
    if not config.EnableNotifications then return end
    duration = duration or 4
    local suc = pcall(function()
        StarterGui:SetCore("SendNotification", {Title = title or "Venom Hub"; Text = text or ""; Duration = duration})
    end)
    if not suc then
        local sg = PlayerGui:FindFirstChild("VenomHubNotifications")
        if not sg then
            sg = Instance.new("ScreenGui")
            sg.Name = "VenomHubNotifications"
            sg.ResetOnSpawn = false
            sg.Parent = PlayerGui
        end
        local lbl = Instance.new("TextLabel", sg)
        lbl.BackgroundTransparency = 0.2
        lbl.Size = UDim2.new(0, 300, 0, 28)
        lbl.Position = UDim2.new(1, -310, 0, 10 + (#sg:GetChildren()-1)*34)
        lbl.Text = "["..tostring(title).."] "..tostring(text)
        lbl.TextColor3 = Color3.fromRGB(235,235,235)
        lbl.BackgroundColor3 = Color3.fromRGB(28,28,28)
        lbl.Font = Enum.Font.Gotham
        lbl.TextSize = 14
        delay(duration, function() if lbl and lbl.Parent then lbl:Destroy() end end)
    end
end

-- Remote finders and safe fire
local function findRemoteByNames(names)
    local roots = {ReplicatedStorage, workspace, PlayerGui}
    local out = {}
    for _,root in ipairs(roots) do
        for _,desc in ipairs(root:GetDescendants()) do
            local cn = desc.ClassName
            if (cn == "RemoteEvent" or cn == "RemoteFunction") and desc.Name then
                for _,n in ipairs(names) do
                    if string.find(string.lower(desc.Name), string.lower(n)) then
                        table.insert(out, desc)
                        break
                    end
                end
            end
        end
    end
    return out
end

local function findRedeemRemote()
    local patterns = {"redeem","code","claim","redeemcode","claimcode"}
    local f = findRemoteByNames(patterns)
    return f[1]
end

local function findRiddleSubmitRemote()
    local patterns = {"riddle","answer","submit","solve","submitanswer"}
    local f = findRemoteByNames(patterns)
    return f[1]
end

-- Try to detect Notification-style remotes (Phi/NotificationController) by inspecting
-- client connections. This mirrors the approach used by TestSender so VenomHub can
-- hook remotes that don't include "announce" in their name.
local function findNotificationRemote()
    -- allow user to predefine the remote via _G
    if _G and _G.PhiNotifyRemote then return _G.PhiNotifyRemote end

    if type(getconnections) ~= "function" then return nil end
    local getinfo = debug and (debug.getinfo or debug.info)
    if not getinfo then return nil end

    local roots = {ReplicatedStorage, workspace, PlayerGui}
    for _,root in ipairs(roots) do
        for _,d in ipairs(root:GetDescendants()) do
            if d.ClassName == "RemoteEvent" then
                local ok, cs = pcall(getconnections, d.OnClientEvent)
                if ok and cs then
                    for _,c in ipairs(cs) do
                        local fOk, fn = pcall(function() return c.Function end)
                        if fOk and type(fn) == "function" then
                            local iOk, info = pcall(getinfo, fn)
                            if iOk and tostring(info.short_src or info.source or ""):lower():find("notificationcontroller") then
                                return d
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function fireRemoteSafe(remote, ...)
    if not remote then return false, "no remote found" end
    local ok, err = pcall(function()
        if remote.ClassName == "RemoteFunction" then
            remote:InvokeServer(...)
        else
            remote:FireServer(...)
        end
    end)
    return ok, err
end

-- Parsing helpers
local function extractCodesFromText(text)
    local codes = {}
    if type(text) ~= "string" then return codes end
    for code in string.gmatch(text, "[Cc]ode[%s%p:]*([%w-_]+)") do table.insert(codes, code) end
    for code in string.gmatch(text, "use[%s%p]+([%w-_]{4,})") do table.insert(codes, code) end
    for code in string.gmatch(text, "([A-Z0-9%-_]{4,})") do
        if #code >= 4 then table.insert(codes, code) end
    end
    local seen, out = {}, {}
    for _,c in ipairs(codes) do if c and not seen[c] then seen[c]=true; table.insert(out,c) end end
    return out
end

local function containsFirstPerson(text)
    if not text or type(text) ~= "string" then return false end
    local lower = string.lower(text)
    -- simple heuristics for first-person pronouns / contractions
    local patterns = {"%si%p?%s","^i%p?%s"," i'm","i'm","i've","i'll"," my "," me "," we "," our "," us "," ours "," i'm "," i've "," i'll "}
    for _,pat in ipairs(patterns) do
        if string.find(lower, pat) then
            return true
        end
    end
    return false
end

local function isSammyAnnouncement(sourceName, text)
    -- If announcement mentions Sammy or comes directly from the owner
    if sourceName and string.find(string.lower(sourceName), "sammy") then return true end
    if text and string.find(string.lower(text), "sammy") then return true end
    return false
end

-- Redeem logic
local redeemRemote, riddleRemote
local redeemDebounce = {}
local function attemptRedeem(code)
    if not code then return false, "no code" end
    if redeemedCodes[code] then
        sendNotification("Code already redeemed", code, 3)
        return false, "already redeemed"
    end
    if redeemDebounce[code] then return false, "debounced" end
    redeemDebounce[code] = true
    delay(2, function() redeemDebounce[code] = nil end)

    redeemRemote = redeemRemote or findRedeemRemote()
    sendNotification("Redeeming...", code, 3)
    local ok, err = fireRemoteSafe(redeemRemote, code)
    if ok then
        redeemedCodes[code] = true
        sendNotification("Redeem successful", code, 4)
        return true
    else
        sendNotification("Redeem failed", tostring(err or "unknown"), 4)
        return false, err
    end
end

-- Riddle handling
local riddleWordCount = 0
local riddleAccumulated = ""
local function resetRiddleBuffer()
    riddleBuffer = {}
    riddleWordCount = 0
    riddleAccumulated = ""
end

local function trySubmitRiddleAnswer(answer)
    if not answer or answer == "" then
        sendNotification("Riddle submit failed", "No answer", 3)
        return false
    end
    riddleRemote = riddleRemote or findRiddleSubmitRemote()
    local ok, err = fireRemoteSafe(riddleRemote, answer)
    if ok then
        sendNotification("Riddle submitted", answer, 4)
        resetRiddleBuffer()
        return true
    else
        local chatOk = false
        pcall(function()
            local chat = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
            if chat and chat:FindFirstChild("SayMessageRequest") then
                chat.SayMessageRequest:FireServer(answer, "All")
                chatOk = true
            end
        end)
        if chatOk then
            sendNotification("Riddle answer sent to chat", answer, 4)
            resetRiddleBuffer()
            return true
        else
            sendNotification("Riddle submit failed", tostring(err or "no remote"), 4)
            return false
        end
    end
end

local function handleRiddleText(text)
    if not config.ModeRiddle then return end
    if not text or text == "" then return end
    for word in string.gmatch(text, "%S+") do
        table.insert(riddleBuffer, word)
        riddleWordCount = riddleWordCount + 1
        if riddleAccumulated == "" then riddleAccumulated = word else riddleAccumulated = riddleAccumulated.." "..word end
    end
    if ui and ui.statusLabel then ui.statusLabel.Text = "Solving riddle... ("..tostring(riddleWordCount).." words)" end
    if riddleWordCount >= (config.RiddleWordThreshold or 10) then
        local answer = riddleAccumulated
        local dt = tonumber(config.RiddleDelay) or 0
        sendNotification("Riddle threshold reached", "Submitting in "..tostring(dt).."s", 3)
        delay(dt, function() trySubmitRiddleAnswer(answer) end)
    end
end

-- Announcement handler
local function onAnnouncement(sourceName, text, uniqueId)
    uniqueId = tostring(uniqueId or text)
    if processedAnnouncements[uniqueId] then return end
    processedAnnouncements[uniqueId] = true

    -- If announcement is first-person, treat as from the game's owner
    if containsFirstPerson(text) then
        sourceName = ownerName or "Owner"
    end

    if ui and ui.statusLabel then
        ui.statusLabel.Text = "Code detected."
    end

    local codes = extractCodesFromText(text)
    if #codes > 0 and config.ModeNormal then
        for _,code in ipairs(codes) do
            if not redeemedCodes[code] then
                sendNotification("New code detected", code, 4)
                attemptRedeem(code)
            else
                sendNotification("Code already redeemed", code, 3)
            end
        end
    end

    -- Riddle detection: treat owner/"Sammy" announcements as legitimate riddle sources
    if config.ModeRiddle and (isSammyAnnouncement(sourceName, text) or string.find(string.lower(text), "riddle") or sourceName == ownerName) then
        handleRiddleText(text)
    end
end

-- Lightweight announcement listeners
local announcementConnected = false
local function connectAnnouncementListeners()
    if announcementConnected then return end
    announcementConnected = true

    local function connectPlayer(p)
        if not p then return end
        local key = "player_"..tostring(p.UserId)
        if listeners[key] then return end
        local con = p.Chatted:Connect(function(msg)
            if string.find(string.lower(msg), "code") or string.find(string.lower(msg), "sammy") or string.find(string.lower(msg), "riddle") or containsFirstPerson(msg) then
                onAnnouncement(p.Name, msg, "chat:"..p.UserId..":"..tostring(os.time()))
            end
        end)
        listeners[key] = con
    end
    for _,p in ipairs(Players:GetPlayers()) do connectPlayer(p) end
    listeners["playerAdded"] = Players.PlayerAdded:Connect(connectPlayer)

    local function watchDesc(desc)
        if not desc then return end
        if desc.ClassName == "RemoteEvent" and string.find(string.lower(desc.Name), "announce") then
            local key = "announce_"..tostring(desc:GetDebugId())
            if listeners[key] then return end
            local con = desc.OnClientEvent:Connect(function(data)
                local msg, from = "", desc.Name
                if type(data) == "table" then msg = data.message or data.text or tostring(data[1] or ""); from = data.from or data.sender or from
                else msg = tostring(data) end
                onAnnouncement(from, msg, "remote:"..tostring(desc:GetDebugId()))
            end)
            listeners[key] = con
        end
        if desc.ClassName == "StringValue" and (string.find(string.lower(desc.Name), "announce") or string.find(string.lower(desc.Name), "sammy")) then
            local key = "string_"..tostring(desc:GetDebugId())
            if listeners[key] then return end
            local con = desc.Changed:Connect(function()
                onAnnouncement(desc.Name, tostring(desc.Value), "string:"..tostring(desc:GetDebugId()))
            end)
            listeners[key] = con
        end
    end

    for _,d in ipairs(ReplicatedStorage:GetDescendants()) do watchDesc(d) end
    for _,d in ipairs(workspace:GetDescendants()) do watchDesc(d) end
    listeners["repAdded"] = ReplicatedStorage.DescendantAdded:Connect(watchDesc)
    listeners["wsAdded"] = workspace.DescendantAdded:Connect(watchDesc)

    -- Additionally, try to hook NotificationController-/Phi-style remotes that don't include
    -- "announce" in their name by inspecting client connections (if available).
    local notifyRemote = findNotificationRemote()
    if notifyRemote then
        local key = "notify_"..tostring(notifyRemote:GetDebugId())
        if not listeners[key] then
            local con = notifyRemote.OnClientEvent:Connect(function(data, ...)
                -- Phi/TestSender typically fires a plain string as first arg; some remotes send tables
                local msg, from = "", notifyRemote.Name
                if type(data) == "table" then
                    msg = data.message or data.text or tostring(data[1] or "")
                    from = data.from or data.sender or from
                else
                    msg = tostring(data)
                end
                onAnnouncement(from, msg, "notify:"..tostring(notifyRemote:GetDebugId()))
            end)
            listeners[key] = con
            sendNotification("Venom Hub", "Hooked notification remote: "..tostring(notifyRemote.Name), 3)
        end
    end
end

-- UI (small, draggable, mutually exclusive mode buttons)
ui = {}
local function createUI()
    if PlayerGui:FindFirstChild("VenomHubMain") then
        ui.screenGui = PlayerGui:FindFirstChild("VenomHubMain")
        return ui
    end

    local sg = Instance.new("ScreenGui")
    sg.Name = "VenomHubMain"
    sg.ResetOnSpawn = false
    sg.Parent = PlayerGui
    ui.screenGui = sg

    local main = Instance.new("Frame")
    main.Name = "MainFrame"
    main.Size = UDim2.new(0, 320, 0, 160)
    main.Position = UDim2.new(0.5, -160, 0.2, 0)
    main.BackgroundColor3 = Color3.fromRGB(18,18,18)
    main.BorderSizePixel = 0
    main.AnchorPoint = Vector2.new(0.5, 0)
    main.Parent = sg
    ui.mainFrame = main
    local corner = Instance.new("UICorner", main); corner.CornerRadius = UDim.new(0,8)

    local titleBar = Instance.new("Frame")
    titleBar.Name = "TitleBar"
    titleBar.Size = UDim2.new(1, 0, 0, 30)
    titleBar.BackgroundTransparency = 1
    titleBar.Parent = main

    local title = Instance.new("TextLabel", titleBar)
    title.Size = UDim2.new(1, -60, 1, 0)
    title.Position = UDim2.new(0, 8, 0, 0)
    title.BackgroundTransparency = 1
    title.Text = "Venom Hub - "..GAME_NAME
    title.TextColor3 = Color3.fromRGB(235,235,235)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 16
    title.TextXAlignment = Enum.TextXAlignment.Left

    local minBtn = Instance.new("TextButton", titleBar)
    minBtn.Size = UDim2.new(0, 48, 0, 22)
    minBtn.Position = UDim2.new(1, -56, 0, 4)
    minBtn.Text = config.Minimized and "_" or "—"
    minBtn.BackgroundColor3 = Color3.fromRGB(36,36,36)
    minBtn.TextColor3 = Color3.fromRGB(230,230,230)
    minBtn.Font = Enum.Font.Gotham
    minBtn.TextSize = 16
    local mcorner = Instance.new("UICorner", minBtn)

    local content = Instance.new("Frame", main)
    content.Name = "Content"
    content.Position = UDim2.new(0, 10, 0, 36)
    content.Size = UDim2.new(1, -20, 1, -46)
    content.BackgroundTransparency = 1

    local status = Instance.new("TextLabel", main)
    status.Name = "Status"
    status.Size = UDim2.new(1, -20, 0, 14)
    status.Position = UDim2.new(0, 10, 1, -20)
    status.BackgroundTransparency = 1
    status.Text = "Waiting for announcement..."
    status.Font = Enum.Font.Gotham
    status.TextSize = 12
    status.TextColor3 = Color3.fromRGB(185,185,185)
    ui.statusLabel = status

    local lbl = Instance.new("TextLabel", content)
    lbl.Size = UDim2.new(1, 0, 0, 16)
    lbl.Position = UDim2.new(0, 0, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = "Mode"
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = 14
    lbl.TextColor3 = Color3.fromRGB(230,230,230)

    local normalBtn = Instance.new("TextButton", content)
    normalBtn.Name = "NormalBtn"
    normalBtn.Size = UDim2.new(0, 140, 0, 30)
    normalBtn.Position = UDim2.new(0, 0, 0, 24)
    normalBtn.Text = config.ModeNormal and "Normal: ON" or "Normal: OFF"
    normalBtn.Font = Enum.Font.Gotham
    normalBtn.TextSize = 14
    normalBtn.TextColor3 = Color3.fromRGB(240,240,240)
    normalBtn.BackgroundColor3 = config.ModeNormal and Color3.fromRGB(50,150,50) or Color3.fromRGB(120,30,30)
    local nCorner = Instance.new("UICorner", normalBtn)

    local riddleBtn = Instance.new("TextButton", content)
    riddleBtn.Name = "RiddleBtn"
    riddleBtn.Size = UDim2.new(0, 140, 0, 30)
    riddleBtn.Position = UDim2.new(0, 160, 0, 24)
    riddleBtn.Text = config.ModeRiddle and "Riddle: ON" or "Riddle: OFF"
    riddleBtn.Font = Enum.Font.Gotham
    riddleBtn.TextSize = 14
    riddleBtn.TextColor3 = Color3.fromRGB(240,240,240)
    riddleBtn.BackgroundColor3 = config.ModeRiddle and Color3.fromRGB(50,150,50) or Color3.fromRGB(120,30,30)
    local rCorner = Instance.new("UICorner", riddleBtn)

    -- Mutually exclusive toggle behavior
    local function setModeNormal(on)
        config.ModeNormal = not not on
        if on then
            config.ModeRiddle = false
        end
        normalBtn.Text = config.ModeNormal and "Normal: ON" or "Normal: OFF"
        normalBtn.BackgroundColor3 = config.ModeNormal and Color3.fromRGB(50,150,50) or Color3.fromRGB(120,30,30)
        riddleBtn.Text = config.ModeRiddle and "Riddle: ON" or "Riddle: OFF"
        riddleBtn.BackgroundColor3 = config.ModeRiddle and Color3.fromRGB(50,150,50) or Color3.fromRGB(120,30,30)
        saveConfig()
    end

    local function setModeRiddle(on)
        config.ModeRiddle = not not on
        if on then
            config.ModeNormal = false
        end
        riddleBtn.Text = config.ModeRiddle and "Riddle: ON" or "Riddle: OFF"
        riddleBtn.BackgroundColor3 = config.ModeRiddle and Color3.fromRGB(50,150,50) or Color3.fromRGB(120,30,30)
        normalBtn.Text = config.ModeNormal and "Normal: ON" or "Normal: OFF"
        normalBtn.BackgroundColor3 = config.ModeNormal and Color3.fromRGB(50,150,50) or Color3.fromRGB(120,30,30)
        saveConfig()
    end

    normalBtn.MouseButton1Click:Connect(function()
        if config.ModeNormal then
            setModeNormal(false)
            sendNotification("Mode", "Normal mode disabled", 2)
        else
            setModeNormal(true)
            sendNotification("Mode", "Normal mode enabled (Riddle disabled)", 2)
        end
    end)

    riddleBtn.MouseButton1Click:Connect(function()
        if config.ModeRiddle then
            setModeRiddle(false)
            sendNotification("Mode", "Riddle mode disabled", 2)
        else
            setModeRiddle(true)
            sendNotification("Mode", "Riddle mode enabled (Normal disabled)", 2)
        end
    end)

    -- Compact controls
    local redeemBox = Instance.new("TextBox", content)
    redeemBox.PlaceholderText = "Code"
    redeemBox.Size = UDim2.new(0, 180, 0, 28)
    redeemBox.Position = UDim2.new(0, 0, 0, 64)
    redeemBox.BackgroundColor3 = Color3.fromRGB(28,28,28)
    redeemBox.TextColor3 = Color3.fromRGB(230,230,230)
    redeemBox.Font = Enum.Font.Gotham
    redeemBox.TextSize = 14

    local redeemBtn = Instance.new("TextButton", content)
    redeemBtn.Text = "Redeem"
    redeemBtn.Size = UDim2.new(0, 120, 0, 28)
    redeemBtn.Position = UDim2.new(0, 190, 0, 64)
    redeemBtn.BackgroundColor3 = Color3.fromRGB(45,95,200)
    redeemBtn.Font = Enum.Font.Gotham
    redeemBtn.TextSize = 14
    redeemBtn.MouseButton1Click:Connect(function()
        local code = tostring(redeemBox.Text or "")
        if code ~= "" then attemptRedeem(code) end
    end)

    local resetBtn = Instance.new("TextButton", content)
    resetBtn.Text = "Reset Riddle"
    resetBtn.Size = UDim2.new(0, 120, 0, 26)
    resetBtn.Position = UDim2.new(0, 190, 0, 100)
    resetBtn.BackgroundColor3 = Color3.fromRGB(140,70,70)
    resetBtn.Font = Enum.Font.Gotham
    resetBtn.TextSize = 13
    resetBtn.MouseButton1Click:Connect(function()
        resetRiddleBuffer()
        sendNotification("Riddle", "Buffer cleared", 2)
    end)

    -- Dragging (title bar)
    local dragging = false
    local dragStart, startPos
    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    titleBar.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)

    -- Minimize handling
    minBtn.MouseButton1Click:Connect(function()
        config.Minimized = not config.Minimized
        if config.Minimized then
            main.Size = UDim2.new(0, 320, 0, 36)
            minBtn.Text = "_"
        else
            main.Size = UDim2.new(0, 320, 0, 160)
            minBtn.Text = "—"
        end
        saveConfig()
    end)
    if config.Minimized then main.Size = UDim2.new(0, 320, 0, 36) end

    return ui
end

-- Cleanup
local function disconnectAll()
    for k,con in pairs(listeners) do
        if con and type(con.Disconnect) == "function" then
            pcall(function() con:Disconnect() end)
        end
        listeners[k] = nil
    end
end

local function autoRejoin()
    if not config.AutoRejoin then return end
    pcall(function()
        local placeId = game.PlaceId
        local jobId = game.JobId
        if placeId and jobId then TeleportService:TeleportToPlaceInstance(placeId, jobId, LocalPlayer) end
    end)
end

-- Bootstrap
local function start()
    loadConfig()
    createUI()
    connectAnnouncementListeners()
    sendNotification("Venom Hub", "Loaded. Normal="..tostring(config.ModeNormal).." Riddle="..tostring(config.ModeRiddle), 3)
    spawn(function()
        while task.wait(2) do
            if ui and ui.statusLabel then
                if next(processedAnnouncements) == nil then
                    ui.statusLabel.Text = "Waiting for announcement..."
                end
            end
        end
    end)
end

start()

-- Expose for debugging
_G.VenomHub = {
    AttemptRedeem = attemptRedeem,
    TrySubmitRiddleAnswer = trySubmitRiddleAnswer,
    ResetRiddleBuffer = resetRiddleBuffer,
    Config = config,
    SaveConfig = saveConfig,
    LoadConfig = loadConfig,
    Disconnect = disconnectAll,
}
