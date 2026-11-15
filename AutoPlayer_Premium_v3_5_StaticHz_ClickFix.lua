--[[
    Monday Morning Misery Beta - AutoPlayer Script
    Versão: 3.3 - Modern UI, telemetry and adaptive speed

    Estrutura preservada:
    - Estado interno
    - Utilidades
    - Controle de teclas por coluna
    - Núcleo de pressionamento
    - Loop central
    - Setup do match
    - Watchdog
    - Interface gráfica

    Melhorias:
    - Heartbeat limitado a 60 Hz no celular e 120 Hz no desktop.
    - Receptor em cache; não relê sua posição em cada coluna/frame.
    - Predição leve por velocidade da nota para melhorar a precisão.
    - Janela baseada no centro da nota e do receptor.
    - Limpeza/compactação periódica da fila para impedir crescimento contínuo.
    - Busca de match com backoff para reduzir chamadas caras a getgc(true).
    - GUI moderna, responsiva, arrastável e sem animações contínuas.
    - Contador de notas pressionadas em tempo real.
    - Estado visual: escolhendo música, tocando e desativado.
    - Timing adaptativo para velocidades de 0.5x até 5.0x.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local AutoPlayerEnabled = false

--------------------------------------------------------------------
-- Estado interno
--------------------------------------------------------------------
local Connections = {}
local Columns = {}
local RenderConnection = nil
local CurrentMatch = nil
local SettingUp = false
local IsReady = false
local NextMatchSearch = 0
local MatchSearchDelay = 3
local LastFrameUpdate = 0
local PressedNotesCount = 0
local PlaybackState = "Desativado"
local StatusText = nil
local NotesText = nil
local CurrentLanguage = "Português"
local CurrentTheme = "Azul"
local MeasuredHz = 60
local LANGUAGE_ORDER = {"Português", "English", "Español"}
local THEME_ORDER = {"Vermelho", "Azul", "Verde", "Roxo", "Amarelo", "Rosa", "Laranja", "Cinza", "Ciano", "RGB"}
local LANGUAGE_TEXTS = {
    ["Português"] = {status = "STATUS", disabled = "Desativado", choosing = "Escolhendo música", playing = "Tocando", enable = "ATIVAR", enabled = "ATIVADO", language = "Idioma", theme = "Tema"},
    ["English"] = {status = "STATUS", disabled = "Disabled", choosing = "Choosing song", playing = "Playing", enable = "ENABLE", enabled = "ENABLED", language = "Language", theme = "Theme"},
    ["Español"] = {status = "ESTADO", disabled = "Desactivado", choosing = "Eligiendo canción", playing = "Reproduciendo", enable = "ACTIVAR", enabled = "ACTIVADO", language = "Idioma", theme = "Tema"}
}
local THEME_COLORS = {
    ["Vermelho"] = Color3.fromRGB(235, 72, 86), ["Azul"] = Color3.fromRGB(67, 127, 255),
    ["Verde"] = Color3.fromRGB(45, 190, 119), ["Roxo"] = Color3.fromRGB(151, 88, 255),
    ["Amarelo"] = Color3.fromRGB(245, 197, 66), ["Rosa"] = Color3.fromRGB(242, 91, 169),
    ["Laranja"] = Color3.fromRGB(245, 132, 52), ["Cinza"] = Color3.fromRGB(139, 148, 165),
    ["Ciano"] = Color3.fromRGB(42, 211, 219)
}

--------------------------------------------------------------------
-- Parâmetros de timing e performance
--------------------------------------------------------------------
local IS_MOBILE = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
local TARGET_UPDATE_RATE = IS_MOBILE and 60 or 120
local UPDATE_INTERVAL = 1 / TARGET_UPDATE_RATE

local SHORT_NOTE_RELEASE_DELAY = 0.050
local RECEPTOR_DETECTION_RATIO = 0.22
local RECEPTOR_RELEASE_RATIO = 0.10
local INPUT_PREDICTION_TIME = IS_MOBILE and 0.014 or 0.009
local MAX_PREDICTION_TIME = 0.022
local MIN_SUPPORTED_SPEED = 0.5
local MAX_SUPPORTED_SPEED = 5.0
local REFERENCE_NOTE_SPEED = 600
local MIN_INTERVAL_BETWEEN_PRESSES = 0.010
local MAX_SHORT_RELEASE = 0.085
local MIN_SHORT_RELEASE = 0.028
local SONG_WAIT_TIMEOUT = 15
local MATCH_SEARCH_COOLDOWN_MIN = 3
local MATCH_SEARCH_COOLDOWN_MAX = 12
local WATCHDOG_INTERVAL = 0.75
local QUEUE_COMPACT_THRESHOLD = 72
local NOTE_LOOKAHEAD = 24

local KeyMap = {
    [4] = {"Left", "Down", "Up", "Right"},
    [5] = {"Left", "Down", "Space", "Up", "Right"},
    [6] = {"Left", "Up", "Right", "Left2", "Down", "Right2"},
    [7] = {
        "Left", "Up", "Right", "Space",
        "Left2", "Down", "Right2"
    },
    [8] = {
        "Left", "Down", "Up", "Right",
        "Left2", "Down2", "Up2", "Right2"
    },
    [9] = {
        "Left", "Down", "Up", "Right", "Space",
        "Left2", "Down2", "Up2", "Right2"
    }
}

--------------------------------------------------------------------
-- Utilidades
--------------------------------------------------------------------
local function RefreshTelemetry()
    if StatusText then
        local words = LANGUAGE_TEXTS[CurrentLanguage] or LANGUAGE_TEXTS["Português"]
        if PlaybackState == "Tocando" then
            StatusText.Text = words.playing
        elseif PlaybackState == "Escolhendo música" then
            StatusText.Text = words.choosing
        else
            StatusText.Text = words.disabled
        end
        if PlaybackState == "Tocando" then
            StatusText.TextColor3 = Color3.fromRGB(85, 232, 153)
        elseif PlaybackState == "Escolhendo música" then
            StatusText.TextColor3 = Color3.fromRGB(255, 197, 92)
        else
            StatusText.TextColor3 = Color3.fromRGB(164, 170, 191)
        end
    end
    if NotesText then
        NotesText.Text = tostring(PressedNotesCount)
    end
end
local function SetPlaybackState(state)
    PlaybackState = state
    RefreshTelemetry()
end
local function ResetPressedNotes()
    PressedNotesCount = 0
    RefreshTelemetry()
end
local function RegisterPressedNote()
    PressedNotesCount += 1
    RefreshTelemetry()
end
local function SendNotification(title, text, duration)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = title,
            Text = text,
            Duration = duration or 2
        })
    end)
end

local function SafeSendKeyPress(keycode, down)
    if not keycode then
        return
    end

    pcall(function()
        VirtualInputManager:SendKeyEvent(down, keycode, false, nil)
    end)
end

local function SortChildrenByX(container)
    local children = {}
    if not container then
        return children
    end

    for _, child in ipairs(container:GetChildren()) do
        if child:IsA("GuiObject") then
            children[#children + 1] = child
        end
    end

    table.sort(children, function(a, b)
        return a.AbsolutePosition.X < b.AbsolutePosition.X
    end)

    return children
end

local function FindMatch()
    if type(getgc) ~= "function" then
        return nil
    end

    local ok, result = pcall(function()
        for _, value in ipairs(getgc(true)) do
            if type(value) == "table" and rawget(value, "MatchFolder") then
                return value
            end
        end
        return nil
    end)

    if ok then
        return result
    end

    return nil
end

local function IsMatchValid(match)
    if type(match) ~= "table" then
        return false
    end

    local ok, valid = pcall(function()
        local folder = rawget(match, "MatchFolder")
        return folder ~= nil and folder.Parent ~= nil
    end)

    return ok and valid
end

local function RefreshReceptorCache(col)
    local receptor = col.receptor
    if not receptor or not receptor.Parent then
        col.receptorValid = false
        return
    end

    local position = receptor.AbsolutePosition
    local size = receptor.AbsoluteSize
    local height = math.max(size.Y, 1)

    col.receptorValid = true
    col.receptorY = position.Y
    col.receptorCenterY = position.Y + height * 0.5
    col.pressWindow = math.clamp(
        height * RECEPTOR_DETECTION_RATIO,
        3,
        12
    )
    col.releaseThreshold = math.max(
        2,
        height * RECEPTOR_RELEASE_RATIO
    )
end

local function CompactQueue(col)
    if col.head < QUEUE_COMPACT_THRESHOLD then
        return
    end

    local newQueue = {}
    local newTail = 0

    for index = col.head, col.tail do
        local note = col.queue[index]
        if note and note.Parent == col.holder then
            newTail += 1
            newQueue[newTail] = note
        end
    end

    col.queue = newQueue
    col.head = 1
    col.tail = newTail
end

--------------------------------------------------------------------
-- Controle de teclas por coluna
--------------------------------------------------------------------
local function ResetTracking(col)
    col.trackedNote = nil
    col.lastNoteCenterY = nil
    col.lastNoteSampleTime = nil
    col.noteVelocity = 0
end

local function ReleaseColumn(col)
    if col.isDown then
        col.isDown = false
        col.activeLong = nil
        SafeSendKeyPress(col.keycode, false)
    end
end

local function ReleaseAllColumns()
    for i = 1, #Columns do
        ReleaseColumn(Columns[i])
    end
end

local function ClearConnections()
    for _, connection in ipairs(Connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    table.clear(Connections)
end

local function StopRenderLoop()
    if RenderConnection then
        pcall(function()
            RenderConnection:Disconnect()
        end)
        RenderConnection = nil
    end
end

local function Teardown()
    StopRenderLoop()
    ClearConnections()
    ReleaseAllColumns()
    table.clear(Columns)
    IsReady = false
    LastFrameUpdate = 0
end

--------------------------------------------------------------------
-- Núcleo: pressionamento
--------------------------------------------------------------------
local function PressNote(col, note, nextNote, now)
    local longBody = col.longContainer
        and col.longContainer:FindFirstChild(note.Name)
    local isLongNote = longBody ~= nil and longBody:IsA("GuiObject")

    col.lastPress = now

    if isLongNote then
        if col.isDown then
            SafeSendKeyPress(col.keycode, false)
        end

        SafeSendKeyPress(col.keycode, true)
        col.isDown = true
        col.activeLong = longBody
        col.releaseAt = math.huge
    else
        -- Uma nota curta pode chegar na mesma coluna enquanto uma long note
        -- ainda está sendo segurada. Apenas manter a tecla pressionada não
        -- produz um novo KeyDown, então a nota curta não é contabilizada.
        -- Fazemos um retrigger imediato e preservamos a long note ativa.
        local heldLong = col.activeLong

        if col.isDown then
            SafeSendKeyPress(col.keycode, false)
        end
        SafeSendKeyPress(col.keycode, true)

        col.isDown = true

        if heldLong and col.longContainer
            and heldLong.Parent == col.longContainer then
            col.activeLong = heldLong
            col.releaseAt = math.huge
            return
        end

        col.activeLong = nil

        local delay = SHORT_NOTE_RELEASE_DELAY
        if nextNote and nextNote.Parent == col.holder then
            local currentCenter = note.AbsolutePosition.Y
                + note.AbsoluteSize.Y * 0.5
            local nextCenter = nextNote.AbsolutePosition.Y
                + nextNote.AbsoluteSize.Y * 0.5
            local gap = math.abs(nextCenter - currentCenter)
            local speed = math.abs(col.noteVelocity)

            if gap > 0 and speed > 1 then
                delay = math.clamp(
                    (gap / speed) * 0.42,
                    MIN_SHORT_RELEASE,
                    MAX_SHORT_RELEASE
                )
            end
        end

        col.releaseAt = now + delay
    end
end

--------------------------------------------------------------------
-- Núcleo: loop único e limitado para todas as colunas
--------------------------------------------------------------------
local function OnRenderStep()
    if not AutoPlayerEnabled or not IsReady then
        return
    end

    local now = os.clock()
    if now - LastFrameUpdate < UPDATE_INTERVAL then
        return
    end
    LastFrameUpdate = now

    for i = 1, #Columns do
        local col = Columns[i]

        if col.receptorValid and col.receptor.Parent then
            local receptorY = col.receptorY
            local receptorCenterY = col.receptorCenterY

            -- 1) Manutenção da tecla
            local body = col.activeLong
            if body then
                if not col.longContainer or body.Parent ~= col.longContainer then
                    col.activeLong = nil
                    ReleaseColumn(col)
                else
                    local bottom = body.AbsolutePosition.Y
                        + body.AbsoluteSize.Y
                    if bottom < receptorY + col.releaseThreshold then
                        col.activeLong = nil
                        ReleaseColumn(col)
                    end
                end
            elseif col.isDown and now >= col.releaseAt then
                ReleaseColumn(col)
            end

            -- 2) Seleciona a nota realmente mais próxima do receptor.
            -- ChildAdded nem sempre entrega as notas na ordem da música.
            -- Isso é especialmente visível quando uma nota longa e uma
            -- nota simples aparecem juntas em colunas vizinhas.
            local queue = col.queue
            local head = col.head

            while head <= col.tail do
                local first = queue[head]
                if first and first.Parent == col.holder then
                    break
                end
                queue[head] = nil
                head += 1
            end

            local bestIndex = nil
            local bestNote = nil
            local bestCenterY = nil
            local bestDistance = math.huge
            local checked = 0

            for index = head, col.tail do
                local candidate = queue[index]
                if candidate then
                    if candidate.Parent ~= col.holder then
                        queue[index] = nil
                    else
                        checked += 1
                        local centerY = candidate.AbsolutePosition.Y
                            + candidate.AbsoluteSize.Y * 0.5
                        local distance = math.abs(centerY - receptorCenterY)

                        if distance < bestDistance then
                            bestDistance = distance
                            bestIndex = index
                            bestNote = candidate
                            bestCenterY = centerY
                        end

                        if checked >= NOTE_LOOKAHEAD then
                            break
                        end
                    end
                end
            end

            if bestNote then
                if col.trackedNote ~= bestNote then
                    col.trackedNote = bestNote
                    col.lastNoteCenterY = bestCenterY
                    col.lastNoteSampleTime = now
                    col.noteVelocity = 0
                    col.previousDelta = bestCenterY - receptorCenterY
                else
                    local elapsed = now - (col.lastNoteSampleTime or now)
                    if elapsed > 0 then
                        local measuredVelocity =
                            (bestCenterY - col.lastNoteCenterY) / elapsed
                        col.noteVelocity = col.noteVelocity * 0.25
                            + measuredVelocity * 0.75
                        col.lastNoteCenterY = bestCenterY
                        col.lastNoteSampleTime = now
                    end
                end

                -- Ajuste adaptativo: usa a velocidade real observada da nota.
                -- O fator e limitado ao intervalo solicitado de 0.5x a 5.0x.
                local measuredSpeed = math.abs(col.noteVelocity)
                local speedFactor = math.clamp(
                    measuredSpeed / REFERENCE_NOTE_SPEED,
                    MIN_SUPPORTED_SPEED,
                    MAX_SUPPORTED_SPEED
                )
                local predictionTime = math.clamp(
                    INPUT_PREDICTION_TIME * (0.90 + speedFactor * 0.10),
                    0.006,
                    MAX_PREDICTION_TIME
                )
                local dynamicPressWindow = math.clamp(
                    col.pressWindow + measuredSpeed * UPDATE_INTERVAL * 0.32,
                    col.pressWindow,
                    col.pressWindow * 2.35
                )
                local predictedCenterY = bestCenterY
                    + col.noteVelocity * predictionTime
                local predictedDistance = math.abs(
                    predictedCenterY - receptorCenterY
                )
                local currentDelta = bestCenterY - receptorCenterY
                local crossed = col.previousDelta ~= nil
                    and ((col.previousDelta > 0 and currentDelta <= 0)
                    or (col.previousDelta < 0 and currentDelta >= 0))
                col.previousDelta = currentDelta

                if (predictedDistance <= dynamicPressWindow or crossed)
                    and now - col.lastPress >= MIN_INTERVAL_BETWEEN_PRESSES then
                    queue[bestIndex] = nil

                    -- Procura a próxima nota válida da mesma coluna apenas
                    -- para calcular o release. Não bloqueia outras colunas.
                    local nextNote = nil
                    for index = head, col.tail do
                        local candidate = queue[index]
                        if candidate and candidate.Parent == col.holder then
                            nextNote = candidate
                            break
                        end
                    end

                    PressNote(col, bestNote, nextNote, now)
                    ResetTracking(col)
                    col.previousDelta = nil
                end
            else
                ResetTracking(col)
                col.previousDelta = nil
            end

            while head <= col.tail and queue[head] == nil do
                head += 1
            end
            col.head = head
            CompactQueue(col)
        else
            ReleaseColumn(col)
        end
    end
end

--------------------------------------------------------------------
-- Setup do match
--------------------------------------------------------------------
local function SetupMatch(match)
    Teardown()
    SetPlaybackState("Escolhendo música")

    local waitStarted = os.clock()
    while not rawget(match, "Songs") do
        if not AutoPlayerEnabled or not IsMatchValid(match) then
            return false
        end

        if os.clock() - waitStarted >= SONG_WAIT_TIMEOUT then
            return false
        end

        task.wait(0.1)
    end

    if not AutoPlayerEnabled then
        return false
    end

    local playerType = match.PlayerType
    local side = playerType == 1 and "Left" or "Right"
    local arrowGui = match.ArrowGui and match.ArrowGui[side]
    if not arrowGui then
        return false
    end

    local receptors = SortChildrenByX(arrowGui.MainArrowContainer)
    local longNoteHolders = SortChildrenByX(arrowGui.LongNotes)
    local noteHolders = SortChildrenByX(arrowGui.Notes)
    local maxArrows = tonumber(match.MaxArrows) or #noteHolders
    local keys = KeyMap[maxArrows]

    if not keys then
        SendNotification(
            "AutoPlayer",
            "Quantidade de setas não suportada: " .. tostring(maxArrows),
            3
        )
        return false
    end

    local playerOptions
    pcall(function()
        local environment = getrenv()
        local playerData = environment._G.PlayerData
        playerOptions = playerData and playerData.Options
    end)

    if not playerOptions then
        return false
    end

    local binds
    if maxArrows < 5 then
        binds = playerOptions
    else
        binds = (
            playerOptions.ExtraKeySettings
            and playerOptions.ExtraKeySettings[tostring(maxArrows)]
        ) or playerOptions
    end

    for i, holder in ipairs(noteHolders) do
        local keyName = keys[i]
        if keyName then
            local keycode = binds and binds[keyName .. "Key"]
            local receptor = receptors[i]
            local longContainer = longNoteHolders[i]

            if keycode and receptor then
                local col = {
                    holder = holder,
                    receptor = receptor,
                    longContainer = longContainer,
                    keycode = keycode,
                    receptorValid = false,
                    receptorY = 0,
                    receptorCenterY = 0,
                    pressWindow = 4,
                    releaseThreshold = 2,
                    queue = {},
                    head = 1,
                    tail = 0,
                    isDown = false,
                    activeLong = nil,
                    releaseAt = 0,
                    lastPress = 0,
                    trackedNote = nil,
                    lastNoteCenterY = nil,
                    lastNoteSampleTime = nil,
                    noteVelocity = 0,
                    previousDelta = nil
                }

                RefreshReceptorCache(col)
                Columns[#Columns + 1] = col

                local addedConnection = holder.ChildAdded:Connect(function(note)
                    if not AutoPlayerEnabled or not note:IsA("GuiObject") then
                        return
                    end

                    col.tail += 1
                    col.queue[col.tail] = note
                end)
                Connections[#Connections + 1] = addedConnection

                for _, existing in ipairs(holder:GetChildren()) do
                    if existing:IsA("GuiObject") then
                        col.tail += 1
                        col.queue[col.tail] = existing
                    end
                end

                -- Atualiza cache somente quando o receptor realmente muda.
                Connections[#Connections + 1] =
                    receptor:GetPropertyChangedSignal("AbsolutePosition")
                        :Connect(function()
                            RefreshReceptorCache(col)
                        end)

                Connections[#Connections + 1] =
                    receptor:GetPropertyChangedSignal("AbsoluteSize")
                        :Connect(function()
                            RefreshReceptorCache(col)
                        end)

                if longContainer then
                    local removedConnection =
                        longContainer.ChildRemoved:Connect(function(removed)
                            if col.activeLong == removed then
                                col.activeLong = nil
                                ReleaseColumn(col)
                            end
                        end)
                    Connections[#Connections + 1] = removedConnection
                end
            end
        end
    end

    if #Columns == 0 then
        return false
    end

    IsReady = true
    LastFrameUpdate = 0
    SetPlaybackState("Tocando")
    RenderConnection = RunService.Heartbeat:Connect(OnRenderStep)
    return true
end

--------------------------------------------------------------------
-- Watchdog leve com backoff de busca
--------------------------------------------------------------------
task.spawn(function()
    while true do
        task.wait(WATCHDOG_INTERVAL)

        if not AutoPlayerEnabled then
            if IsReady or #Connections > 0 or CurrentMatch then
                Teardown()
                CurrentMatch = nil
            end
        elseif not SettingUp then
            if not IsMatchValid(CurrentMatch) then
                if IsReady then
                    Teardown()
                end

                CurrentMatch = nil
                local now = os.clock()

                if now >= NextMatchSearch then
                    NextMatchSearch = now + MatchSearchDelay
                    local match = FindMatch()

                    if IsMatchValid(match) then
                        MatchSearchDelay = MATCH_SEARCH_COOLDOWN_MIN
                        CurrentMatch = match
                        SettingUp = true
                        local ok, result = pcall(SetupMatch, match)
                        SettingUp = false

                        if not ok or not result then
                            Teardown()
                            CurrentMatch = nil
                        end
                    else
                        MatchSearchDelay = math.min(
                            MatchSearchDelay * 1.6,
                            MATCH_SEARCH_COOLDOWN_MAX
                        )
                    end
                end
            elseif not IsReady and not RenderConnection then
                SettingUp = true
                local ok, result = pcall(SetupMatch, CurrentMatch)
                SettingUp = false

                if not ok or not result then
                    Teardown()
                    CurrentMatch = nil
                end
            end
        end
    end
end)

--------------------------------------------------------------------
-- Interface gráfica moderna
--------------------------------------------------------------------
local oldGui = PlayerGui:FindFirstChild("AutoPlayerGUI")
if oldGui then oldGui:Destroy() end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "AutoPlayerGUI"
ScreenGui.ResetOnSpawn = false
ScreenGui.IgnoreGuiInset = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = PlayerGui

local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.AnchorPoint = Vector2.new(0.5, 1)
MainFrame.Size = UDim2.fromOffset(286, 205)
MainFrame.Position = UDim2.new(0.5, 0, 0.94, 0)
MainFrame.BackgroundColor3 = Color3.fromRGB(18, 20, 28)
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.ClipsDescendants = true
MainFrame.Parent = ScreenGui

local MainCorner = Instance.new("UICorner")
MainCorner.CornerRadius = UDim.new(0, 16)
MainCorner.Parent = MainFrame
local MainStroke = Instance.new("UIStroke")
MainStroke.Transparency = 0.22
MainStroke.Thickness = 1.4
MainStroke.Parent = MainFrame
local MainGradient = Instance.new("UIGradient")
MainGradient.Color = ColorSequence.new({ColorSequenceKeypoint.new(0, Color3.fromRGB(31,34,47)), ColorSequenceKeypoint.new(1, Color3.fromRGB(15,17,24))})
MainGradient.Rotation = 25
MainGradient.Parent = MainFrame

local Header = Instance.new("TextLabel")
Header.BackgroundTransparency = 1
Header.Position = UDim2.fromOffset(16, 9)
Header.Size = UDim2.new(1, -88, 0, 23)
Header.Font = Enum.Font.GothamBold
Header.Text = "AUTOPLAYER"
Header.TextColor3 = Color3.fromRGB(244,246,255)
Header.TextSize = 15
Header.TextXAlignment = Enum.TextXAlignment.Left
Header.Parent = MainFrame

local Subtitle = Instance.new("TextLabel")
Subtitle.BackgroundTransparency = 1
Subtitle.Position = UDim2.fromOffset(16, 31)
Subtitle.Size = UDim2.new(1, -32, 0, 16)
Subtitle.Font = Enum.Font.Gotham
Subtitle.TextColor3 = Color3.fromRGB(145,151,174)
Subtitle.TextSize = 10
Subtitle.TextXAlignment = Enum.TextXAlignment.Left
Subtitle.Parent = MainFrame

local MinimizeButton = Instance.new("TextButton")
MinimizeButton.AnchorPoint = Vector2.new(1,0)
MinimizeButton.Position = UDim2.new(1,-13,0,10)
MinimizeButton.Size = UDim2.fromOffset(30,28)
MinimizeButton.AutoButtonColor = false
MinimizeButton.BackgroundColor3 = Color3.fromRGB(43,46,60)
MinimizeButton.BorderSizePixel = 0
MinimizeButton.Font = Enum.Font.GothamBold
MinimizeButton.Text = "—"
MinimizeButton.TextColor3 = Color3.fromRGB(230,233,245)
MinimizeButton.TextSize = 14
MinimizeButton.Parent = MainFrame
local MinCorner = Instance.new("UICorner")
MinCorner.CornerRadius = UDim.new(0,9)
MinCorner.Parent = MinimizeButton

local Content = Instance.new("Frame")
Content.Name = "Content"
Content.BackgroundTransparency = 1
Content.Position = UDim2.fromOffset(0,50)
Content.Size = UDim2.new(1,0,1,-50)
Content.Parent = MainFrame

local TelemetryFrame = Instance.new("Frame")
TelemetryFrame.Position = UDim2.fromOffset(12,0)
TelemetryFrame.Size = UDim2.new(1,-24,0,35)
TelemetryFrame.BackgroundColor3 = Color3.fromRGB(11,13,20)
TelemetryFrame.BackgroundTransparency = 0.12
TelemetryFrame.BorderSizePixel = 0
TelemetryFrame.Parent = Content
local TelemetryCorner = Instance.new("UICorner")
TelemetryCorner.CornerRadius = UDim.new(0,10)
TelemetryCorner.Parent = TelemetryFrame
local StateCaption = Instance.new("TextLabel")
StateCaption.BackgroundTransparency = 1
StateCaption.Position = UDim2.fromOffset(10,3)
StateCaption.Size = UDim2.new(1,-20,0,12)
StateCaption.Font = Enum.Font.GothamMedium
StateCaption.TextColor3 = Color3.fromRGB(118,124,148)
StateCaption.TextSize = 9
StateCaption.TextXAlignment = Enum.TextXAlignment.Left
StateCaption.Parent = TelemetryFrame
StatusText = Instance.new("TextLabel")
StatusText.BackgroundTransparency = 1
StatusText.Position = UDim2.fromOffset(10,15)
StatusText.Size = UDim2.new(1,-20,0,16)
StatusText.Font = Enum.Font.GothamSemibold
StatusText.TextSize = 11
StatusText.TextXAlignment = Enum.TextXAlignment.Left
StatusText.Parent = TelemetryFrame

local function MakeSelector(x, name)
    local frame = Instance.new("Frame")
    frame.Position = UDim2.fromOffset(x,44)
    frame.Size = UDim2.fromOffset(126,43)
    frame.BackgroundColor3 = Color3.fromRGB(31,34,46)
    frame.BorderSizePixel = 0
    frame.Parent = Content
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0,10)
    corner.Parent = frame
    local caption = Instance.new("TextLabel")
    caption.Name = "Caption"
    caption.BackgroundTransparency = 1
    caption.Position = UDim2.fromOffset(9,3)
    caption.Size = UDim2.new(1,-18,0,13)
    caption.Font = Enum.Font.GothamMedium
    caption.TextColor3 = Color3.fromRGB(120,126,149)
    caption.TextSize = 9
    caption.TextXAlignment = Enum.TextXAlignment.Left
    caption.Parent = frame
    local button = Instance.new("TextButton")
    button.Name = name
    button.BackgroundTransparency = 1
    button.Position = UDim2.fromOffset(9,16)
    button.Size = UDim2.new(1,-18,0,22)
    button.Font = Enum.Font.GothamSemibold
    button.TextColor3 = Color3.fromRGB(238,240,249)
    button.TextSize = 11
    button.TextXAlignment = Enum.TextXAlignment.Left
    button.Parent = frame
    return caption, button
end
local LanguageCaption, LanguageButton = MakeSelector(12,"LanguageButton")
local ThemeCaption, ThemeButton = MakeSelector(148,"ThemeButton")

local ToggleButton = Instance.new("TextButton")
ToggleButton.AnchorPoint = Vector2.new(0.5,1)
ToggleButton.Position = UDim2.new(0.5,0,1,-10)
ToggleButton.Size = UDim2.new(1,-24,0,42)
ToggleButton.AutoButtonColor = false
ToggleButton.BorderSizePixel = 0
ToggleButton.Font = Enum.Font.GothamBold
ToggleButton.TextColor3 = Color3.fromRGB(255,255,255)
ToggleButton.TextSize = 13
ToggleButton.Parent = Content
local ToggleCorner = Instance.new("UICorner")
ToggleCorner.CornerRadius = UDim.new(0,11)
ToggleCorner.Parent = ToggleButton

local UIScale = Instance.new("UIScale")
UIScale.Scale = IS_MOBILE and 0.92 or 1
UIScale.Parent = MainFrame

local activeAccent = THEME_COLORS[CurrentTheme]
local minimized = false
local function GetAccent()
    if CurrentTheme == "RGB" then
        return Color3.fromHSV((os.clock() * 0.12) % 1, 0.78, 1)
    end
    return THEME_COLORS[CurrentTheme] or THEME_COLORS["Azul"]
end
local function ApplyTheme()
    activeAccent = GetAccent()
    MainStroke.Color = activeAccent
    ThemeButton.TextColor3 = activeAccent
    MinimizeButton.TextColor3 = activeAccent
    if AutoPlayerEnabled then ToggleButton.BackgroundColor3 = activeAccent else ToggleButton.BackgroundColor3 = Color3.fromRGB(48,52,67) end
end
local function RefreshLanguage()
    local words = LANGUAGE_TEXTS[CurrentLanguage] or LANGUAGE_TEXTS["Português"]
    StateCaption.Text = words.status
    LanguageCaption.Text = string.upper(words.language)
    ThemeCaption.Text = string.upper(words.theme)
    LanguageButton.Text = CurrentLanguage .. "  ›"
    ThemeButton.Text = CurrentTheme .. "  ›"
    ToggleButton.Text = AutoPlayerEnabled and words.enabled or words.enable
    RefreshTelemetry()
end
local function SetGuiState(enabled)
    local words = LANGUAGE_TEXTS[CurrentLanguage] or LANGUAGE_TEXTS["Português"]
    ToggleButton.Text = enabled and words.enabled or words.enable
    StatusText.TextColor3 = enabled and Color3.fromRGB(85,232,153) or Color3.fromRGB(164,170,191)
    ApplyTheme()
end
local function Cycle(list, current)
    for i,value in ipairs(list) do
        if value == current then return list[(i % #list) + 1] end
    end
    return list[1]
end
LanguageButton.Activated:Connect(function()
    CurrentLanguage = Cycle(LANGUAGE_ORDER, CurrentLanguage)
    RefreshLanguage()
end)
ThemeButton.Activated:Connect(function()
    CurrentTheme = Cycle(THEME_ORDER, CurrentTheme)
    RefreshLanguage()
    ApplyTheme()
end)
MinimizeButton.Activated:Connect(function()
    minimized = not minimized
    Content.Visible = not minimized
    MainFrame.Size = minimized and UDim2.fromOffset(286,50) or UDim2.fromOffset(286,205)
    MinimizeButton.Text = minimized and "+" or "—"
end)

-- Faz uma única leitura inicial da taxa de atualização apresentada pelo cliente.
-- Depois de estabilizar a amostra, o valor fica fixo na interface e não alterna.
local hzFrames, hzElapsed = 0, 0
local hzMeasurementConnection
hzMeasurementConnection = RunService.RenderStepped:Connect(function(deltaTime)
    hzFrames += 1
    hzElapsed += deltaTime
    if hzElapsed >= 1.25 then
        local rawHz = hzFrames / hzElapsed
        local commonRates = {30, 40, 48, 50, 60, 72, 75, 90, 96, 100, 120, 144, 165, 240}
        local closestHz = commonRates[1]
        local closestDistance = math.abs(rawHz - closestHz)
        for i = 2, #commonRates do
            local distance = math.abs(rawHz - commonRates[i])
            if distance < closestDistance then
                closestHz = commonRates[i]
                closestDistance = distance
            end
        end
        MeasuredHz = closestHz
        Subtitle.Text = (IS_MOBILE and "Mobile" or "Desktop") .. " • " .. tostring(MeasuredHz) .. " Hz • 0.5x–5.0x"
        hzMeasurementConnection:Disconnect()
        hzMeasurementConnection = nil
    end
end)

-- O tema RGB continua animado sem alterar o valor de Hz já definido.
RunService.Heartbeat:Connect(function()
    if CurrentTheme == "RGB" then ApplyTheme() end
end)

local dragging, dragInput, dragStart, startPos, dragMoved = false, nil, nil, nil, false
local function UpdateDrag(input)
    if not dragStart or not startPos then return end
    local delta = input.Position - dragStart
    if math.abs(delta.X) + math.abs(delta.Y) > 6 then dragMoved = true end
    MainFrame.Position = UDim2.new(startPos.X.Scale,startPos.X.Offset+delta.X,startPos.Y.Scale,startPos.Y.Offset+delta.Y)
end
MainFrame.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        -- Arrastar começa apenas pelo cabeçalho. Assim, os botões não disputam o toque.
        local localY = input.Position.Y - MainFrame.AbsolutePosition.Y
        if localY > 50 then return end
        dragging, dragMoved, dragStart, startPos = true, false, input.Position, MainFrame.Position
        local endConnection
        endConnection = input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging, dragInput = false, nil
                if endConnection then endConnection:Disconnect() end
            end
        end)
    end
end)
MainFrame.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then dragInput = input end
end)
UserInputService.InputChanged:Connect(function(input)
    if dragging and input == dragInput then UpdateDrag(input) end
end)

local toggleLocked = false
local function ToggleAutoPlayer()
    if toggleLocked then return end
    toggleLocked = true
    AutoPlayerEnabled = not AutoPlayerEnabled
    SetGuiState(AutoPlayerEnabled)
    if AutoPlayerEnabled then
        ResetPressedNotes()
        SetPlaybackState("Escolhendo música")
        MatchSearchDelay = MATCH_SEARCH_COOLDOWN_MIN
        NextMatchSearch = 0
        SendNotification("AutoPlayer", "Ativado • suporte de 0.5x a 5.0x", 2)
    else
        SetPlaybackState("Desativado")
        SendNotification("AutoPlayer", "Desativado", 2)
        Teardown()
        CurrentMatch = nil
    end
    task.delay(0.18, function()
        toggleLocked = false
    end)
end

-- MouseButton1Click melhora a consistência do clique no desktop e no toque móvel.
ToggleButton.MouseButton1Click:Connect(ToggleAutoPlayer)

Subtitle.Text = (IS_MOBILE and "Mobile" or "Desktop") .. " • medindo Hz • 0.5x–5.0x"
RefreshLanguage()
SetGuiState(false)
RefreshTelemetry()
