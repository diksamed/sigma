--[[
Advanced ESP Library
Version: 2.0

Features:
- Player ESP:
    - 2D Box (Normal, Corner)
    - 3D Box
    - Box Fill
    - Skeleton
    - Head Dot
    - Health Bar (Vertical/Horizontal option)
    - Health Text
    - Name Text
    - Distance Text
    - Weapon Text (Requires game-specific implementation)
    - Look Vector Line
    - Tracer Line
    - Off-Screen Arrow
- Chams (Highlight based)
- Instance ESP (Highly configurable text)
- Visibility Checks (Different colors for visible/occluded)
- Team-based Settings (Friendly/Enemy)
- Whitelisting
- Extensive Customization Options
- Optimized Rendering Loop
]]

-- Services
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local GuiService -- Lazy loaded for gethui
local CoreGui -- Lazy loaded for gethui

-- Variables
local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera
local ViewportSize = Camera.ViewportSize

-- Drawing Container (Attempts gethui(), falls back to CoreGui)
local function getDrawingContainer()
    if not GuiService then GuiService = game:GetService("GuiService") end
    if not CoreGui then CoreGui = game:GetService("CoreGui") end
    local success, hui = pcall(GuiService.GetRobloxGui, GuiService) -- Use GetRobloxGui for better compatibility if gethui is deprecated/removed
    local containerParent = (success and hui) or CoreGui
    local container = containerParent:FindFirstChild("EspDrawingContainer")
    if not container then
        container = Instance.new("Folder", containerParent)
        container.Name = "EspDrawingContainer"
    end
    return container
end
local DrawingContainer = getDrawingContainer()

-- Math / Utility Locals
local floor = math.floor
local round = math.round
local sin = math.sin
local cos = math.cos
local atan2 = math.atan2
local huge = math.huge
local pi = math.pi
local abs = math.abs
local clamp = math.clamp
local clear = table.clear
local unpack = table.unpack -- Use table.unpack for Lua 5.1+ environments
local find = table.find
local create = table.create -- Use table.create for potentially better performance on Luau
local fromMatrix = CFrame.fromMatrix
local wtvp = Camera.WorldToViewportPoint
local getPivot = Workspace.GetPivot -- Renamed from workspace.GetPivot for clarity
local findFirstChild = Instance.FindFirstChild
local findFirstChildOfClass = Instance.FindFirstChildOfClass
local getChildren = Instance.GetChildren
local toObjectSpace = CFrame.ToObjectSpace -- More standard name
local lerpColor = Color3.new().Lerp
local min2 = Vector2.zero.Min
local max2 = Vector2.zero.Max
local lerp2 = Vector2.zero.Lerp
local raycast = Workspace.Raycast

-- Constants
local OFFSCREEN_PADDING = 30 -- Pixels from edge for offscreen arrows
local BONE_CONNECTIONS = { -- Define skeleton connections
	{"Head", "UpperTorso"},
	{"UpperTorso", "LowerTorso"},
	{"UpperTorso", "LeftUpperArm"},
	{"LeftUpperArm", "LeftLowerArm"},
	{"LeftLowerArm", "LeftHand"},
	{"UpperTorso", "RightUpperArm"},
	{"RightUpperArm", "RightLowerArm"},
	{"RightLowerArm", "RightHand"},
	{"LowerTorso", "LeftUpperLeg"},
	{"LeftUpperLeg", "LeftLowerLeg"},
	{"LeftLowerLeg", "LeftFoot"},
	{"LowerTorso", "RightUpperLeg"},
	{"RightUpperLeg", "RightLowerLeg"},
	{"RightLowerLeg", "RightFoot"}
}
local BODY_PART_NAMES = {"Head", "UpperTorso", "LowerTorso", "LeftUpperArm", "LeftLowerArm", "LeftHand", "RightUpperArm", "RightLowerArm", "RightHand", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot", "HumanoidRootPart"} -- Include HRP for bounding box/center

-- ================= Helper Functions =================

local function isAlive(player)
	local character = player and player.Character
	local humanoid = character and findFirstChildOfClass(character, "Humanoid")
	return humanoid and humanoid.Health > 0
end

local function getCharacterParts(character)
    local parts = {}
    local bones = {}
    if not character then return parts, bones end

    for _, partName in ipairs(BODY_PART_NAMES) do
        local part = findFirstChild(character, partName)
        if part and part:IsA("BasePart") then
            parts[#parts + 1] = part
            bones[partName] = part -- Store by name for skeleton
        end
    end
    -- Fallback if standard R15/R6 parts aren't found (e.g., custom characters)
    if #parts == 0 then
        for _, obj in ipairs(getChildren(character)) do
            if obj:IsA("BasePart") then
                 parts[#parts + 1] = obj
                 -- Attempt to guess bone names (less reliable)
                 if not bones[obj.Name] then bones[obj.Name] = obj end
            end
        end
    end
    return parts, bones
end

local function worldToScreen(worldPos)
	local screenPos, onScreen = wtvp(Camera, worldPos)
	local depth = (Camera.CFrame.Position - worldPos).Magnitude
	return Vector2.new(floor(screenPos.X), floor(screenPos.Y)), onScreen, floor(depth), screenPos.Z > 0 -- Also return if point is in front of camera
end

local function getCharacterBounds(character)
    if not character then return nil, nil, nil end
    -- Use the model's bounding box for overall dimensions
    local bbCFrame, bbSize = character:GetBoundingBox()

    -- Calculate screen space corners
    local cornersPos = {}
    local minScreen = Vector2.new(huge, huge)
    local maxScreen = Vector2.new(-huge, -huge)
    local allOnScreen = true
    local anyInFront = false

    -- Define AABB corners relative to CFrame and Size
    local halfSize = bbSize * 0.5
    local worldCorners = {
        bbCFrame * CFrame.new(-halfSize.X, -halfSize.Y, -halfSize.Z).Position,
        bbCFrame * CFrame.new(-halfSize.X,  halfSize.Y, -halfSize.Z).Position,
        bbCFrame * CFrame.new( halfSize.X,  halfSize.Y, -halfSize.Z).Position,
        bbCFrame * CFrame.new( halfSize.X, -halfSize.Y, -halfSize.Z).Position,
        bbCFrame * CFrame.new(-halfSize.X, -halfSize.Y,  halfSize.Z).Position,
        bbCFrame * CFrame.new(-halfSize.X,  halfSize.Y,  halfSize.Z).Position,
        bbCFrame * CFrame.new( halfSize.X,  halfSize.Y,  halfSize.Z).Position,
        bbCFrame * CFrame.new( halfSize.X, -halfSize.Y,  halfSize.Z).Position
    }

    for i = 1, #worldCorners do
        local screenPos, onScreen, _, inFront = worldToScreen(worldCorners[i])
        if not onScreen then allOnScreen = false end
        if inFront then anyInFront = true end -- Keep track if *any* part is in front
        cornersPos[i] = screenPos
        minScreen = min2(minScreen, screenPos)
        maxScreen = max2(maxScreen, screenPos)
    end

    -- Clamp to viewport bounds
    minScreen = max2(minScreen, Vector2.zero)
    maxScreen = min2(maxScreen, ViewportSize)

    -- If completely off-screen or behind camera, adjust bounding box to be zero size
    if not anyInFront or maxScreen.X <= minScreen.X or maxScreen.Y <= minScreen.Y then
        local centerScreen, _, _, centerInFront = worldToScreen(bbCFrame.Position)
        if centerInFront then -- If center is in front, collapse to center point, else make invalid
             minScreen = centerScreen
             maxScreen = centerScreen
        else
            -- Return invalid bounds if center is also behind camera
            return { TopLeft = Vector2.zero, BottomRight = Vector2.zero, Size = Vector2.zero, Center = Vector2.zero, Corners = cornersPos }, false, false
        end
    end

    local size = maxScreen - minScreen
    local center = minScreen + size * 0.5

    return {
        TopLeft = minScreen,
        BottomRight = maxScreen,
        Size = size,
        Center = center,
        Corners = cornersPos -- Screen positions of the 8 world corners
    }, allOnScreen, anyInFront
end

local function isVisible(targetPosition, ignoreList)
    if not targetPosition then return false end
	local origin = Camera.CFrame.Position
	local direction = (targetPosition - origin).Unit * (targetPosition - origin).Magnitude -- Use magnitude for range limit if needed
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = ignoreList or {LocalPlayer.Character} -- Ignore self by default

    local result = raycast(origin, direction, params)
    -- Consider visible if no hit, or hit is very close to the target (allowing for minor part intersections)
    return not result or (result.Position - targetPosition).Magnitude < 1.0
end

local function parseColor(value, defaultColor, defaultTransparency)
    if type(value) == "table" then
        return value[1] or defaultColor, value[2] or defaultTransparency
    elseif typeof(value) == "Color3" then
        return value, defaultTransparency
    else
        return defaultColor, defaultTransparency -- Fallback
    end
end

local function getTeamColor(player) -- Default implementation
    return player and player.Team and player.Team.TeamColor and player.Team.TeamColor.Color or Color3.new(1,1,1)
end

local function applyDrawProperties(drawing, props)
	for prop, value in pairs(props) do
		-- Use pcall for safety, especially with Color3 values that might be invalid temporarily
		pcall(function() drawing[prop] = value end)
	end
end

-- ================= ESP Object (Players) =================
local EspObject = {}
EspObject.__index = EspObject

function EspObject.new(player, interface)
	local self = setmetatable({}, EspObject)
	self.Player = assert(player, "Missing argument #1 (Player expected)")
	self.Interface = assert(interface, "Missing argument #2 (table expected)")
	self.IsLocal = (player == LocalPlayer)
	self.Drawings = {}
	self.Bin = {} -- Store all drawings for easy cleanup
    self.CharacterCache = nil
    self.BonesCache = {} -- Cache bone BaseParts
	self.LastVisible = false
    self.LastDistance = 0
    self.IsFriendly = false

	self:_ConstructDrawings()

	self.RenderConnection = RunService.RenderStepped:Connect(function() -- Use RenderStepped for smoother visuals
		self:_Update()
		self:_Render()
	end)
	return self
end

function EspObject:_CreateDrawing(class, properties)
	local drawing = Drawing.new(class)
	drawing.Visible = false -- Start invisible
	applyDrawProperties(drawing, properties or {})
	self.Bin[#self.Bin + 1] = drawing
	return drawing
end

function EspObject:_ConstructDrawings()
    local d = self.Drawings -- Shortcut

    -- Box 2D
    d.Box2D = self:_CreateDrawing("Square", { Thickness = 1, Filled = false })
    d.Box2DOutline = self:_CreateDrawing("Square", { Thickness = 3, Filled = false })
    d.Box2DFill = self:_CreateDrawing("Square", { Thickness = 1, Filled = true })

	-- Corner Box 2D (8 lines)
	d.CornerBoxLines = {}
	for i = 1, 8 do d.CornerBoxLines[i] = self:_CreateDrawing("Line", { Thickness = 1 }) end
	d.CornerBoxOutlines = {}
	for i = 1, 8 do d.CornerBoxOutlines[i] = self:_CreateDrawing("Line", { Thickness = 3 }) end

    -- Box 3D (12 lines)
    d.Box3DLines = {}
    for i = 1, 12 do d.Box3DLines[i] = self:_CreateDrawing("Line", { Thickness = 1 }) end
    d.Box3DOutlines = {}
	for i = 1, 12 do d.Box3DOutlines[i] = self:_CreateDrawing("Line", { Thickness = 3 }) end

    -- Skeleton (Max ~14 lines needed for standard rigs)
    d.SkeletonLines = {}
    for i = 1, #BONE_CONNECTIONS do d.SkeletonLines[i] = self:_CreateDrawing("Line", { Thickness = 1 }) end
	d.SkeletonOutlines = {}
	for i = 1, #BONE_CONNECTIONS do d.SkeletonOutlines[i] = self:_CreateDrawing("Line", { Thickness = 3 }) end

    -- Head Dot
    d.HeadDot = self:_CreateDrawing("Circle", { Thickness = 1, Filled = true, Radius = 3 })
    d.HeadDotOutline = self:_CreateDrawing("Circle", { Thickness = 3, Filled = false, Radius = 3 })

    -- Health Bar
    d.HealthBar = self:_CreateDrawing("Line", { Thickness = 4 })
    d.HealthBarBackground = self:_CreateDrawing("Line", { Thickness = 4 }) -- Background for contrast
    d.HealthBarOutline = self:_CreateDrawing("Line", { Thickness = 6 })

    -- Text Elements
    d.NameText = self:_CreateDrawing("Text", { Center = true, Outline = true })
    d.DistanceText = self:_CreateDrawing("Text", { Center = true, Outline = true })
    d.HealthText = self:_CreateDrawing("Text", { Center = true, Outline = true })
    d.WeaponText = self:_CreateDrawing("Text", { Center = true, Outline = true })

    -- Tracer
    d.TracerLine = self:_CreateDrawing("Line", { Thickness = 1 })
    d.TracerOutline = self:_CreateDrawing("Line", { Thickness = 3 })

    -- Look Vector
    d.LookVectorLine = self:_CreateDrawing("Line", { Thickness = 1 })
    d.LookVectorOutline = self:_CreateDrawing("Line", { Thickness = 3 })

    -- Off-Screen Arrow
    d.OffScreenArrow = self:_CreateDrawing("Triangle", { Filled = true })
    d.OffScreenArrowOutline = self:_CreateDrawing("Triangle", { Thickness = 3, Filled = false })
end

function EspObject:Destruct()
	if self.RenderConnection then self.RenderConnection:Disconnect() end
	for _, drawing in ipairs(self.Bin) do
		drawing:Remove()
	end
	clear(self.Drawings)
	clear(self.Bin)
    clear(self.BonesCache)
    self.CharacterCache = nil
    print("ESP Object Destroyed for:", self.Player.Name)
end

function EspObject:_Update()
    local interface = self.Interface
    local player = self.Player

    -- Check if player exists and is valid
    if not player or not player.Parent then
        self:Destruct() -- Destroy self if player left unexpectedlya
        return
    end

    self.Character = interface.getCharacter(player)
    self.IsAlive = self.Character and isAlive(player)
    self.IsFriendly = interface.isFriendly(player)
    self.Options = interface.teamSettings[self.IsFriendly and "Friendly" or "Enemy"]
    self.SharedOptions = interface.sharedSettings

    -- Basic Enabling Logic
    self.Enabled = self.Options.Enabled and self.IsAlive and not self.IsLocal
    if self.Enabled and #interface.Whitelist > 0 then
        self.Enabled = find(interface.Whitelist, player.UserId)
    end

    if not self.Enabled or not self.Character then
        self.OnScreen = false
        self.Occluded = true -- Assume occluded if not enabled/no character
        self:_SetAllDrawingsVisible(false) -- Hide everything quickly
        return
    end

    -- Get Health & Weapon
    local health, maxHealth = interface.getHealth(player)
    self.Health = health or 0
    self.MaxHealth = maxHealth or 100
    self.WeaponName = interface.getWeapon(player) or "N/A"

    -- Bounding Box & Screen Position
    local head = self.Character:FindFirstChild("Head") or self.Character:FindFirstChild("HumanoidRootPart")
    local primaryPart = self.Character.PrimaryPart or head -- Fallback

    if not primaryPart then
        self.OnScreen = false
        self.Occluded = true
        self:_SetAllDrawingsVisible(false)
        return
    end

    self.HeadPosition = head and head.Position or primaryPart.Position -- Use head if available for visibility check/look vector
    local bounds, allCornersOnScreen, anyCornerInFront = getCharacterBounds(self.Character)

    self.Bounds = bounds
    self.OnScreen = anyCornerInFront and (self.Bounds.Size.X > 0 and self.Bounds.Size.Y > 0) -- Must have some size on screen and be in front
	self.Distance = (Camera.CFrame.Position - primaryPart.Position).Magnitude

    -- Distance Limit Check
	if self.SharedOptions.LimitDistance and self.Distance > self.SharedOptions.MaxDistance then
		self.OnScreen = false -- Treat as off-screen if too far
	end

    -- Visibility Check (Raycast) - Only if needed and on screen
    if self.OnScreen and self.Options.UseVisibilityCheck and self.HeadPosition then
        local ignoreList = {LocalPlayer.Character, self.Character}
        self.Occluded = not isVisible(self.HeadPosition, ignoreList)
    else
        -- If not checking visibility, assume visible if on screen, occluded otherwise
        -- Or if UseVisibilityCheck is off, always treat as visible when rendering on-screen elements
        self.Occluded = not self.OnScreen or (not self.Options.UseVisibilityCheck)
    end
    self.LastVisible = not self.Occluded -- Store inverse for clarity

    -- Off-Screen Direction
    if not self.OnScreen and self.Options.OffScreenArrow.Enabled and primaryPart then
        local screenPoint = Camera.WorldToScreenPoint(Camera, primaryPart.Position)
        local direction = Vector2.new(screenPoint.X - ViewportSize.X / 2, screenPoint.Y - ViewportSize.Y / 2).Unit
        self.OffScreenDirection = direction
    else
        self.OffScreenDirection = nil
    end

    -- Update Bone Cache if Character Changed or Parts need refreshing
    if self.Character ~= self.CharacterCache then
        _, self.BonesCache = getCharacterParts(self.Character)
        self.CharacterCache = self.Character
    end
end

function EspObject:_SetAllDrawingsVisible(visible)
    for _, drawing in ipairs(self.Bin) do
        drawing.Visible = visible
    end
end

function EspObject:_GetColor(colorOptionName)
    local opt = self.Options[colorOptionName]
    if not opt then return Color3.new(1,1,1), 1 end -- Default white

    local colorValue = self.Occluded and opt.OccludedColor or opt.VisibleColor
    if self.SharedOptions.UseTeamColor and not opt.IgnoreTeamColor then
        colorValue = self.IsFriendly and self.SharedOptions.FriendlyTeamColor or self.SharedOptions.EnemyTeamColor
    end
    return parseColor(colorValue, Color3.new(1,1,1), 0) -- Default transparency 0 (visible)
end

function EspObject:_GetOutlineColor(outlineColorOptionName)
    local opt = self.Options[outlineColorOptionName]
     if not opt then return Color3.new(0,0,0), 0 end -- Default black

    -- Outlines typically don't change with visibility, but you could add OccludedOutlineColor if needed
    local colorValue = opt.Color
    -- Outlines often ignore team color, but allow override if needed
    if self.SharedOptions.UseTeamColor and opt.UseTeamColorForOutline then
         colorValue = self.IsFriendly and self.SharedOptions.FriendlyTeamColor or self.SharedOptions.EnemyTeamColor
    end
    return parseColor(colorValue, Color3.new(0,0,0), 0)
end

-- ================= Render Sub-Functions =================

function EspObject:_RenderBox2D()
    local d = self.Drawings
    local opt = self.Options.Box2D
    local enabled = self.Enabled and self.OnScreen and opt.Enabled and opt.Type == "Normal"

    d.Box2D.Visible = enabled
    d.Box2DOutline.Visible = enabled and opt.Outline.Enabled
    d.Box2DFill.Visible = enabled and opt.Fill.Enabled

    if not enabled then return end

    local bounds = self.Bounds
    local color, trans = self:_GetColor("Box2D")
    local outlineColor, outlineTrans = self:_GetOutlineColor("Box2DOutline")
    local fillColor, fillTrans = self:_GetColor("Box2DFill") -- Fill usually uses main color logic

    applyDrawProperties(d.Box2D, {
        Position = bounds.TopLeft,
        Size = bounds.Size,
        Color = color,
        Transparency = trans,
        Thickness = opt.Thickness
    })

    if d.Box2DOutline.Visible then
        applyDrawProperties(d.Box2DOutline, {
            Position = bounds.TopLeft,
            Size = bounds.Size,
            Color = outlineColor,
            Transparency = outlineTrans,
            Thickness = opt.Outline.Thickness
        })
    end

     if d.Box2DFill.Visible then
        applyDrawProperties(d.Box2DFill, {
            Position = bounds.TopLeft,
            Size = bounds.Size,
            Color = fillColor,
            Transparency = fillTrans + opt.Fill.TransparencyModifier -- Additive transparency for fill
        })
    end
end

function EspObject:_RenderCornerBox2D()
    local d = self.Drawings
    local opt = self.Options.Box2D -- Uses Box2D settings but checks Type
    local enabled = self.Enabled and self.OnScreen and opt.Enabled and opt.Type == "Corner"

	local mainLinesVisible = enabled
	local outlineLinesVisible = enabled and opt.Outline.Enabled

	-- Hide all first
	for i = 1, 8 do d.CornerBoxLines[i].Visible = false; d.CornerBoxOutlines[i].Visible = false end

	if not enabled then return end

	local bounds = self.Bounds
	local size = bounds.Size
	local cornerLength = math.min(size.X, size.Y) * opt.CornerLengthRatio -- Length relative to smallest dimension
	cornerLength = math.max(5, cornerLength) -- Minimum pixel length

	local tl, tr, bl, br = bounds.TopLeft, bounds.TopLeft + Vector2.new(size.X, 0), bounds.TopLeft + Vector2.new(0, size.Y), bounds.BottomRight

	local points = {
		-- Top Left
		{ From = tl + Vector2.new(cornerLength, 0), To = tl },
		{ From = tl + Vector2.new(0, cornerLength), To = tl },
		-- Top Right
		{ From = tr - Vector2.new(cornerLength, 0), To = tr },
		{ From = tr + Vector2.new(0, cornerLength), To = tr },
		-- Bottom Left
		{ From = bl + Vector2.new(cornerLength, 0), To = bl },
		{ From = bl - Vector2.new(0, cornerLength), To = bl },
		-- Bottom Right
		{ From = br - Vector2.new(cornerLength, 0), To = br },
		{ From = br - Vector2.new(0, cornerLength), To = br }
	}

	local color, trans = self:_GetColor("Box2D")
	local outlineColor, outlineTrans = self:_GetOutlineColor("Box2DOutline")

	-- Apply properties to main lines
	for i = 1, 8 do
		local line = d.CornerBoxLines[i]
		line.Visible = mainLinesVisible
		if mainLinesVisible then
			applyDrawProperties(line, {
				From = points[i].From,
				To = points[i].To,
				Color = color,
				Transparency = trans,
				Thickness = opt.Thickness
			})
		end
	end

	-- Apply properties to outline lines
	if outlineLinesVisible then
		for i = 1, 8 do
			local outline = d.CornerBoxOutlines[i]
			outline.Visible = true
			applyDrawProperties(outline, {
				From = points[i].From,
				To = points[i].To,
				Color = outlineColor,
				Transparency = outlineTrans,
				Thickness = opt.Outline.Thickness
			})
		end
	end
end


function EspObject:_RenderBox3D()
	local d = self.Drawings
    local opt = self.Options.Box3D
    local enabled = self.Enabled and self.OnScreen and opt.Enabled

	-- Hide all lines first
	for i = 1, 12 do d.Box3DLines[i].Visible = false; d.Box3DOutlines[i].Visible = false end

    if not enabled or not self.Bounds or not self.Bounds.Corners or #self.Bounds.Corners ~= 8 then return end -- Need valid screen corners

    local corners = self.Bounds.Corners -- Use pre-calculated screen corners
	local color, trans = self:_GetColor("Box3D")
	local outlineColor, outlineTrans = self:_GetOutlineColor("Box3DOutline")

	local connections = { -- Define the 12 edges of a cube using the corner indices (1-8)
        {1, 2}, {2, 3}, {3, 4}, {4, 1}, -- Bottom face
        {5, 6}, {6, 7}, {7, 8}, {8, 5}, -- Top face
        {1, 5}, {2, 6}, {3, 7}, {4, 8}  -- Connecting edges
    }

	-- Render main lines
    for i = 1, 12 do
		local line = d.Box3DLines[i]
		line.Visible = true
        local conn = connections[i]
		applyDrawProperties(line, {
            From = corners[conn[1]],
            To = corners[conn[2]],
            Color = color,
            Transparency = trans,
            Thickness = opt.Thickness
        })
    end

	-- Render outlines
	if opt.Outline.Enabled then
		for i = 1, 12 do
			local outline = d.Box3DOutlines[i]
			outline.Visible = true
			local conn = connections[i]
			applyDrawProperties(outline, {
				From = corners[conn[1]],
				To = corners[conn[2]],
				Color = outlineColor,
				Transparency = outlineTrans,
				Thickness = opt.Outline.Thickness
			})
		end
	end
end

function EspObject:_RenderSkeleton()
    local d = self.Drawings
    local opt = self.Options.Skeleton
    local enabled = self.Enabled and self.OnScreen and opt.Enabled

    -- Hide all first
    for i = 1, #BONE_CONNECTIONS do d.SkeletonLines[i].Visible = false; d.SkeletonOutlines[i].Visible = false end

    if not enabled or not self.Character then return end

    local color, trans = self:_GetColor("Skeleton")
    local outlineColor, outlineTrans = self:_GetOutlineColor("SkeletonOutline")

    local lineIndex = 1
    for _, connection in ipairs(BONE_CONNECTIONS) do
        local part1Name, part2Name = connection[1], connection[2]
        local part1 = self.BonesCache[part1Name]
        local part2 = self.BonesCache[part2Name]

        if part1 and part2 and lineIndex <= #d.SkeletonLines then
            local pos1, onScreen1 = worldToScreen(part1.Position)
            local pos2, onScreen2 = worldToScreen(part2.Position)

            -- Only draw if both points are somewhat on screen (or adjust logic as needed)
            if onScreen1 or onScreen2 then
                -- Main line
                local line = d.SkeletonLines[lineIndex]
                line.Visible = true
                applyDrawProperties(line, {
                    From = pos1,
                    To = pos2,
                    Color = color,
                    Transparency = trans,
                    Thickness = opt.Thickness
                })

                -- Outline
                if opt.Outline.Enabled and lineIndex <= #d.SkeletonOutlines then
                    local outline = d.SkeletonOutlines[lineIndex]
                    outline.Visible = true
                    applyDrawProperties(outline, {
                         From = pos1,
                         To = pos2,
                         Color = outlineColor,
                         Transparency = outlineTrans,
                         Thickness = opt.Outline.Thickness
                    })
                end
                lineIndex = lineIndex + 1
            end
        end
         if lineIndex > #d.SkeletonLines then break end -- Stop if we run out of drawing objects
    end
end

function EspObject:_RenderHeadDot()
    local d = self.Drawings
    local opt = self.Options.HeadDot
    local enabled = self.Enabled and self.OnScreen and opt.Enabled

    d.HeadDot.Visible = enabled
    d.HeadDotOutline.Visible = enabled and opt.Outline.Enabled

    if not enabled or not self.Character then return end

    local head = self.BonesCache["Head"]
    if not head then return end -- Need head part

    local headPos2D, onScreen = worldToScreen(head.Position)
    if not onScreen then
        d.HeadDot.Visible = false
        d.HeadDotOutline.Visible = false
        return
    end

    local color, trans = self:_GetColor("HeadDot")
    local outlineColor, outlineTrans = self:_GetOutlineColor("HeadDotOutline")

    applyDrawProperties(d.HeadDot, {
        Position = headPos2D,
        Color = color,
        Transparency = trans,
        Radius = opt.Radius,
		Filled = opt.Filled,
        NumSides = opt.NumSides, -- Make it smoother
		Thickness = opt.Thickness -- Use thickness for non-filled
    })

    if d.HeadDotOutline.Visible then
        applyDrawProperties(d.HeadDotOutline, {
            Position = headPos2D,
            Color = outlineColor,
            Transparency = outlineTrans,
            Radius = opt.Radius,
            Thickness = opt.Outline.Thickness,
			Filled = false, -- Outline is never filled
            NumSides = opt.NumSides
        })
    end
end

function EspObject:_RenderHealthBar()
    local d = self.Drawings
    local opt = self.Options.HealthBar
    local enabled = self.Enabled and self.OnScreen and opt.Enabled

    d.HealthBar.Visible = enabled
    d.HealthBarBackground.Visible = enabled and opt.Background.Enabled
    d.HealthBarOutline.Visible = enabled and opt.Outline.Enabled

    if not enabled then return end

    local bounds = self.Bounds
	local healthPerc = clamp(self.Health / self.MaxHealth, 0, 1)

	-- Colors
	local barColor = lerpColor(opt.ColorDying, opt.ColorHealthy, healthPerc)
	local barTrans = self.Occluded and opt.OccludedTransparency or opt.VisibleTransparency
	local bgColor, bgTrans = parseColor(opt.Background.Color, Color3.new(0,0,0), 0.5)
	local outColor, outTrans = parseColor(opt.Outline.Color, Color3.new(0,0,0), 0)

	-- Positioning
	local barSize = bounds.Size
	local barThickness = opt.Thickness
	local outlineThickness = opt.Outline.Thickness
	local padding = opt.Padding

	local from, to, bgFrom, bgTo, outFrom, outTo

	if opt.Orientation == "Vertical" then
		local startX = bounds.TopLeft.X - padding - (outlineThickness / 2)
		local startY = bounds.TopLeft.Y
		local endY = bounds.BottomRight.Y

		bgFrom = Vector2.new(startX, startY)
		bgTo = Vector2.new(startX, endY)
		from = Vector2.new(startX, lerp(endY, startY, healthPerc)) -- Lerp Y position
		to = Vector2.new(startX, endY)

		-- Outline encompasses background
		outFrom = bgFrom - Vector2.new(0, (outlineThickness - barThickness) / 2)
		outTo = bgTo + Vector2.new(0, (outlineThickness - barThickness) / 2)

	else -- Horizontal
		local startY = bounds.TopLeft.Y - padding - (outlineThickness / 2)
		local startX = bounds.TopLeft.X
		local endX = bounds.BottomRight.X

		bgFrom = Vector2.new(startX, startY)
		bgTo = Vector2.new(endX, startY)
		from = Vector2.new(startX, startY)
		to = Vector2.new(lerp(startX, endX, healthPerc), startY) -- Lerp X position

		-- Outline encompasses background
		outFrom = bgFrom - Vector2.new((outlineThickness - barThickness) / 2, 0)
		outTo = bgTo + Vector2.new((outlineThickness - barThickness) / 2, 0)
	end

	-- Apply properties
	if d.HealthBarOutline.Visible then
		applyDrawProperties(d.HealthBarOutline, { From = outFrom, To = outTo, Color = outColor, Transparency = outTrans, Thickness = outlineThickness })
	end
	if d.HealthBarBackground.Visible then
		applyDrawProperties(d.HealthBarBackground, { From = bgFrom, To = bgTo, Color = bgColor, Transparency = bgTrans, Thickness = barThickness })
	end
	applyDrawProperties(d.HealthBar, { From = from, To = to, Color = barColor, Transparency = barTrans, Thickness = barThickness })
end


function EspObject:_RenderTextElements()
    local d = self.Drawings
    local sharedOpt = self.SharedOptions
    local bounds = self.Bounds
    local yOffset = 0 -- Keep track of vertical space used by text

    -- Helper to render a text element
    local function renderText(elementName, drawing, textValue, positionOffset)
        local opt = self.Options[elementName]
        local enabled = self.Enabled and self.OnScreen and opt.Enabled

        drawing.Visible = enabled
        if not enabled then return 0 end -- Return 0 height if not visible

        local color, trans = self:_GetColor(elementName)
        local outlineColor, outlineTrans = self:_GetOutlineColor(elementName .. "Outline") -- Assumes Outline setting exists

        applyDrawProperties(drawing, {
            Text = textValue,
            Size = opt.Size or sharedOpt.TextSize,
            Font = opt.Font or sharedOpt.TextFont,
            Color = color,
            Transparency = trans,
            Outline = opt.Outline.Enabled,
            OutlineColor = outlineColor,
            OutlineTransparency = outlineTrans, -- Assuming Drawing supports this
            Position = positionOffset - Vector2.new(drawing.TextBounds.X * 0.5, 0) -- Center horizontally
        })
        return drawing.TextBounds.Y + sharedOpt.TextSpacing -- Return height used + spacing
    end

    -- Name Text (Top)
    local nameOpt = self.Options.NameText
    local namePos = bounds.TopLeft + Vector2.new(bounds.Size.X * 0.5, -(nameOpt.Size or sharedOpt.TextSize) - nameOpt.VPadding)
    yOffset = yOffset + renderText("NameText", d.NameText, self.Player.DisplayName, namePos)

    -- Health Text (Can be near health bar or below name)
    local healthOpt = self.Options.HealthText
    if healthOpt.Enabled then
        local healthStr = healthOpt.Format:format(Health = round(self.Health), MaxHealth = self.MaxHealth)
        local healthPos
        if self.Options.HealthBar.Enabled and healthOpt.AttachToBar and self.Drawings.HealthBar.Visible then
             -- Position near the end of the health bar (vertical or horizontal)
             local barDraw = self.Drawings.HealthBar
             if self.Options.HealthBar.Orientation == "Vertical" then
                 healthPos = Vector2.new(barDraw.From.X - healthOpt.HPadding, barDraw.From.Y)
             else -- Horizontal
                 healthPos = Vector2.new(barDraw.To.X + healthOpt.HPadding, barDraw.To.Y)
             end
        else
            -- Position below name
             healthPos = namePos + Vector2.new(0, yOffset)
        end
        yOffset = yOffset + renderText("HealthText", d.HealthText, healthStr, healthPos)
    end


    -- Bottom Text Elements (Distance, Weapon) - Calculate total height first
    local bottomTextY = bounds.BottomRight.Y + sharedOpt.TextSpacing -- Start below the box
    local distanceHeight = 0
    local weaponHeight = 0

    if self.Options.DistanceText.Enabled then distanceHeight = (self.Options.DistanceText.Size or sharedOpt.TextSize) + sharedOpt.TextSpacing end
    if self.Options.WeaponText.Enabled then weaponHeight = (self.Options.WeaponText.Size or sharedOpt.TextSize) + sharedOpt.TextSpacing end

     -- Distance Text (Bottom)
    local distOpt = self.Options.DistanceText
    if distOpt.Enabled then
        local distStr = distOpt.Format:format(Distance = round(self.Distance))
        local distPos = bounds.BottomLeft + Vector2.new(bounds.Size.X * 0.5, distOpt.VPadding)
        yOffset = yOffset + renderText("DistanceText", d.DistanceText, distStr, distPos + Vector2.yAxis * bottomTextY)
		bottomTextY = bottomTextY + distanceHeight
    end

    -- Weapon Text (Below Distance)
    local wepOpt = self.Options.WeaponText
    if wepOpt.Enabled then
        local wepStr = wepOpt.Format:format(Weapon = self.WeaponName)
        local wepPos = bounds.BottomLeft + Vector2.new(bounds.Size.X * 0.5, wepOpt.VPadding)
        yOffset = yOffset + renderText("WeaponText", d.WeaponText, wepStr, wepPos + Vector2.yAxis * bottomTextY)
		bottomTextY = bottomTextY + weaponHeight
    end
end


function EspObject:_RenderTracer()
    local d = self.Drawings
    local opt = self.Options.Tracer
    local enabled = self.Enabled and self.OnScreen and opt.Enabled

    d.TracerLine.Visible = enabled
    d.TracerOutline.Visible = enabled and opt.Outline.Enabled

    if not enabled then return end

    local bounds = self.Bounds
    local color, trans = self:_GetColor("Tracer")
    local outlineColor, outlineTrans = self:_GetOutlineColor("TracerOutline")

    local originPoint
    local originOpt = opt.Origin
    if originOpt == "Top" then
        originPoint = Vector2.new(ViewportSize.X * 0.5, 0)
    elseif originOpt == "Bottom" then
        originPoint = Vector2.new(ViewportSize.X * 0.5, ViewportSize.Y)
    elseif originOpt == "Mouse" then
        originPoint = UserInputService:GetMouseLocation()
    else -- Middle (Default)
        originPoint = ViewportSize * 0.5
    end

	local targetPoint
	local targetOpt = opt.Target
	if targetOpt == "Head" and self.BonesCache["Head"] then
		targetPoint, _ = worldToScreen(self.BonesCache["Head"].Position)
	elseif targetOpt == "Torso" and self.BonesCache["UpperTorso"] then
		targetPoint, _ = worldToScreen(self.BonesCache["UpperTorso"].Position)
	elseif targetOpt == "Feet" and self.BonesCache["LeftFoot"] then -- Approx feet center
		local lf, _ = worldToScreen(self.BonesCache["LeftFoot"].Position)
		local rf, _ = worldToScreen(self.BonesCache["RightFoot"].Position)
		if lf and rf then targetPoint = lf:Lerp(rf, 0.5) else targetPoint = lf or rf end
	else -- Box Bottom Center (Default)
		targetPoint = bounds.BottomLeft + Vector2.new(bounds.Size.X * 0.5, 0)
	end

	if not targetPoint then -- Fallback if specific part not found
		targetPoint = bounds.BottomLeft + Vector2.new(bounds.Size.X * 0.5, 0)
	end

    applyDrawProperties(d.TracerLine, {
        From = originPoint,
        To = targetPoint,
        Color = color,
        Transparency = trans,
        Thickness = opt.Thickness
    })

    if d.TracerOutline.Visible then
         applyDrawProperties(d.TracerOutline, {
            From = originPoint,
            To = targetPoint,
            Color = outlineColor,
            Transparency = outlineTrans,
            Thickness = opt.Outline.Thickness
        })
    end
end

function EspObject:_RenderLookVector()
    local d = self.Drawings
    local opt = self.Options.LookVector
    local enabled = self.Enabled and self.OnScreen and opt.Enabled

    d.LookVectorLine.Visible = enabled
    d.LookVectorOutline.Visible = enabled and opt.Outline.Enabled

    if not enabled or not self.Character then return end

    local head = self.BonesCache["Head"]
    if not head then return end -- Need head

    local headCf = head.CFrame
    local startPosWorld = headCf.Position
    local endPosWorld = startPosWorld + headCf.LookVector * opt.Length

    local startPos, startOnScreen = worldToScreen(startPosWorld)
    local endPos, endOnScreen = worldToScreen(endPosWorld)

    -- Only draw if start is on screen (avoids weird lines from behind)
    if not startOnScreen then
        d.LookVectorLine.Visible = false
        d.LookVectorOutline.Visible = false
        return
    end

    local color, trans = self:_GetColor("LookVector")
    local outlineColor, outlineTrans = self:_GetOutlineColor("LookVectorOutline")

    applyDrawProperties(d.LookVectorLine, {
        From = startPos,
        To = endPos,
        Color = color,
        Transparency = trans,
        Thickness = opt.Thickness
    })

    if d.LookVectorOutline.Visible then
         applyDrawProperties(d.LookVectorOutline, {
            From = startPos,
            To = endPos,
            Color = outlineColor,
            Transparency = outlineTrans,
            Thickness = opt.Outline.Thickness
        })
    end
end

function EspObject:_RenderOffScreenArrow()
    local d = self.Drawings
    local opt = self.Options.OffScreenArrow
    local enabled = self.Enabled and not self.OnScreen and opt.Enabled and self.OffScreenDirection

    d.OffScreenArrow.Visible = enabled
    d.OffScreenArrowOutline.Visible = enabled and opt.Outline.Enabled

    if not enabled then return end

    local dir = self.OffScreenDirection
    local angle = atan2(dir.Y, dir.X) -- Angle of direction vector

    -- Calculate center position clamped to screen bounds with padding
    local centerPos = ViewportSize * 0.5 + dir * opt.Radius
    centerPos = Vector2.new(
        clamp(centerPos.X, OFFSCREEN_PADDING, ViewportSize.X - OFFSCREEN_PADDING),
        clamp(centerPos.Y, OFFSCREEN_PADDING, ViewportSize.Y - OFFSCREEN_PADDING)
    )

    -- Calculate triangle points relative to the angle
    local size = opt.Size
    local p1 = centerPos -- Tip of the arrow
    local p2 = centerPos - Vector2.new(cos(angle + pi / 6), sin(angle + pi / 6)) * size
    local p3 = centerPos - Vector2.new(cos(angle - pi / 6), sin(angle - pi / 6)) * size

    local color, trans = self:_GetColor("OffScreenArrow") -- Use main color logic
    local outlineColor, outlineTrans = self:_GetOutlineColor("OffScreenArrowOutline")

    applyDrawProperties(d.OffScreenArrow, {
        PointA = p1, PointB = p2, PointC = p3,
        Color = color,
        Transparency = trans,
        Filled = true -- Main arrow is filled
    })

    if d.OffScreenArrowOutline.Visible then
        applyDrawProperties(d.OffScreenArrowOutline, {
            PointA = p1, PointB = p2, PointC = p3,
            Color = outlineColor,
            Transparency = outlineTrans,
            Thickness = opt.Outline.Thickness,
            Filled = false -- Outline is not filled
        })
    end
end


-- ================= Main Render Call =================
function EspObject:_Render()
	if not self.Enabled then
		-- Ensure everything is hidden if disabled after update
		if self.Drawings.Box2D and self.Drawings.Box2D.Visible then -- Check if drawings exist and were visible
			self:_SetAllDrawingsVisible(false)
		end
		return
	end

    -- On-Screen Elements
    if self.OnScreen then
		self:_RenderBox2D()
        self:_RenderCornerBox2D() -- Will only draw if type is Corner
		self:_RenderBox3D()
		self:_RenderSkeleton()
		self:_RenderHeadDot()
		self:_RenderHealthBar()
		self:_RenderTextElements()
		self:_RenderTracer()
        self:_RenderLookVector()

        -- Hide offscreen arrow if we are now on screen
        if self.Drawings.OffScreenArrow.Visible then
            self.Drawings.OffScreenArrow.Visible = false
            self.Drawings.OffScreenArrowOutline.Visible = false
        end
	else
		-- Hide all on-screen elements if we are off-screen
        if self.Drawings.Box2D.Visible then -- Quick check if hiding is needed
            self:_SetAllDrawingsVisible(false) -- Hide everything except potentially the arrow
        end
        -- Render Off-Screen Elements
		self:_RenderOffScreenArrow() -- Will only draw if enabled and direction exists
	end
end


-- ================= Cham Object (Highlights) =================
local ChamObject = {}
ChamObject.__index = ChamObject

function ChamObject.new(player, interface)
    local self = setmetatable({}, ChamObject)
    self.Player = player
    self.Interface = interface
    self.Highlight = Instance.new("Highlight")
    self.Highlight.Name = "EspCham_" .. player.Name
    self.Highlight.Adornee = nil
    self.Highlight.Enabled = false
    self.Highlight.Parent = DrawingContainer -- Keep highlights organized

    self.UpdateConnection = RunService.Heartbeat:Connect(function() -- Heartbeat is fine for chams
        self:_Update()
    end)
    return self
end

function ChamObject:Destruct()
    if self.UpdateConnection then self.UpdateConnection:Disconnect() end
    if self.Highlight then self.Highlight:Destroy() end
    clear(self)
end

function ChamObject:_Update()
    local player = self.Player
    local interface = self.Interface

    if not player or not player.Parent then
        self:Destruct()
        return
    end

    local character = interface.getCharacter(player)
    local isFriendly = interface.isFriendly(player)
    local options = interface.teamSettings[isFriendly and "Friendly" or "Enemy"].Chams
    local sharedOptions = interface.sharedSettings
    local isAlive = character and isAlive(player)
    local isLocal = (player == LocalPlayer)

    local enabled = options.Enabled and isAlive and not isLocal
    if enabled and #interface.Whitelist > 0 then
        enabled = find(interface.Whitelist, player.UserId)
    end

	-- Distance Limit Check
	if enabled and character and sharedOptions.LimitDistance then
		local dist = (Camera.CFrame.Position - (character:GetPrimaryPartCFrame().Position)).Magnitude
		if dist > sharedOptions.MaxDistance then
			enabled = false
		end
	end

    self.Highlight.Enabled = enabled

    if enabled then
        if self.Highlight.Adornee ~= character then
             self.Highlight.Adornee = character -- Update adornee if needed
        end

        local fillVisibleColor, fillVisibleTrans = parseColor(options.FillColor.VisibleColor, Color3.new(1,0,0), 0.5)
		local fillOccludedColor, fillOccludedTrans = parseColor(options.FillColor.OccludedColor, Color3.new(0,0,1), 0.5)

		local outlineVisibleColor, outlineVisibleTrans = parseColor(options.OutlineColor.VisibleColor, Color3.new(1,1,1), 0)
		local outlineOccludedColor, outlineOccludedTrans = parseColor(options.OutlineColor.OccludedColor, Color3.new(0.8,0.8,0.8), 0)

        -- Determine colors based on DepthMode
        if options.DepthMode == Enum.HighlightDepthMode.AlwaysOnTop then
            -- Always on top uses Occluded colors conceptually, as it draws over everything
            self.Highlight.FillColor = fillOccludedColor
            self.Highlight.FillTransparency = fillOccludedTrans
            self.Highlight.OutlineColor = outlineOccludedColor
            self.Highlight.OutlineTransparency = outlineOccludedTrans
        else -- Occluded mode - This makes the highlight behave like a normal object regarding occlusion
		    -- Note: Standard highlights don't have separate visible/occluded colors.
            -- We *could* simulate this by having TWO highlights, one AlwaysOnTop and one Occluded,
            -- but that adds complexity. For now, we'll use the "Visible" color setting for Occluded mode.
            self.Highlight.FillColor = fillVisibleColor
            self.Highlight.FillTransparency = fillVisibleTrans
            self.Highlight.OutlineColor = outlineVisibleColor
            self.Highlight.OutlineTransparency = outlineVisibleTrans
        end

		self.Highlight.DepthMode = options.DepthMode

    else
        if self.Highlight.Adornee then
             self.Highlight.Adornee = nil -- Clear adornee when disabled
        end
    end
end

-- ================= Instance ESP Object =================
local InstanceObject = {}
InstanceObject.__index = InstanceObject

function InstanceObject.new(instance, options, interface) -- Pass interface for shared settings
    local self = setmetatable({}, InstanceObject)
    self.Instance = assert(instance, "Missing argument #1 (Instance Expected)")
    self.Options = options or {} -- Use provided options or empty table
    self.Interface = interface -- Store interface reference
    self:_InitializeDefaults() -- Apply defaults after options are set

    self.DrawingText = Drawing.new("Text")
    self.DrawingText.Visible = false
    self.DrawingText.Center = true -- Default to center

    self.RenderConnection = RunService.RenderStepped:Connect(function()
        self:_Render()
    end)
    print("Instance ESP Created for:", instance:GetFullName())
    return self
end

function InstanceObject:_InitializeDefaults()
    local opt = self.Options
    local shared = self.Interface.sharedSettings

    opt.Enabled = opt.Enabled ?? true -- Default true if nil
    opt.Format = opt.Format or "{Name}\n[{Distance} studs]" -- More informative default
    opt.Color = opt.Color or { VisibleColor = {Color3.new(1,1,1), 0}, OccludedColor = {Color3.new(0.8,0.8,0.8), 0.1} } -- Visible/Occluded
    opt.Outline = opt.Outline or { Enabled = true, Color = {Color3.new(0,0,0), 0}, Thickness = 3 }
    opt.Text = opt.Text or { Size = shared.TextSize, Font = shared.TextFont }
    opt.UseVisibilityCheck = opt.UseVisibilityCheck ?? true
    opt.MaxDistance = opt.MaxDistance or shared.MaxDistance -- Inherit from shared by default
	opt.RequiresLineOfSight = opt.RequiresLineOfSight ?? false -- Only show if visible?
end

function InstanceObject:Destruct()
    if self.RenderConnection then self.RenderConnection:Disconnect() end
    if self.DrawingText then self.DrawingText:Remove() end
    clear(self)
    -- print("Instance ESP Destroyed") -- Removed instance name as it might be gone
end

function InstanceObject:UpdateOptions(newOptions)
    for key, value in pairs(newOptions) do
        self.Options[key] = value
    end
    self:_InitializeDefaults() -- Re-apply defaults/structure if options change
end

function InstanceObject:_Render()
    local instance = self.Instance
    local opt = self.Options
    local shared = self.Interface.sharedSettings
    local text = self.DrawingText

    -- Basic checks
    if not instance or not instance.Parent or not opt.Enabled then
        text.Visible = false
        return
    end

    -- Get position (handle models vs parts)
    local worldPosition
    local success, result = pcall(function()
         if instance:IsA("Model") then
             worldPosition = instance:GetBoundingBox().Position
         elseif instance:IsA("BasePart") then
             worldPosition = instance.Position
         else
             worldPosition = getPivot(instance).Position -- Fallback
         end
    end)

    if not success or not worldPosition then
        text.Visible = false
        return -- Cannot get position
    end

    local screenPos, onScreen, distance, inFront = worldToScreen(worldPosition)
    local isTooFar = distance > opt.MaxDistance

    -- Visibility and Distance Checks
    if not onScreen or not inFront or isTooFar then
        text.Visible = false
        return
    end

	-- Line of Sight Check
	local occluded = false
	if opt.UseVisibilityCheck then
		local ignoreList = {LocalPlayer.Character} -- Ignore self, maybe add the instance itself if it's large?
		occluded = not isVisible(worldPosition, ignoreList)
	end

	if opt.RequiresLineOfSight and occluded then
		text.Visible = false
		return
	end

    text.Visible = true

    -- Determine Color
    local colorValue = occluded and opt.Color.OccludedColor or opt.Color.VisibleColor
    local mainColor, mainTrans = parseColor(colorValue, Color3.new(1,1,1), 0)
    local outlineColor, outlineTrans = parseColor(opt.Outline.Color, Color3.new(0,0,0), 0)

    -- Format Text String
    local formattedText = opt.Format
        :gsub("{Name}", instance.Name)
        :gsub("{Distance}", tostring(round(distance)))
        :gsub("{Position}", string.format("%.1f, %.1f, %.1f", worldPosition.X, worldPosition.Y, worldPosition.Z))
		:gsub("{Class}", instance.ClassName)
		-- Add more placeholders as needed

    -- Apply Drawing Properties
    applyDrawProperties(text, {
        Position = screenPos,
        Text = formattedText,
        Color = mainColor,
        Transparency = mainTrans,
        Size = opt.Text.Size,
        Font = opt.Text.Font,
        Outline = opt.Outline.Enabled,
        OutlineColor = outlineColor,
        OutlineTransparency = outlineTrans -- Assuming Drawing supports this
        -- Note: Drawing library might need OutlineThickness property if it exists
    })
	-- Manually set outline thickness if separate property exists
	if text.OutlineThickness then text.OutlineThickness = opt.Outline.Thickness end
end


-- ================= ESP Interface (Main Controller) =================
local EspInterface = {
    _IsLoaded = false,
    _ObjectCache = {}, -- Stores { [Player] = {EspObject, ChamObject}, [Instance] = InstanceObject }
    _PlayerConnections = {}, -- Stores PlayerAdded/Removing connections
    _InstanceCleanupConnections = {}, -- Stores AncestryChanged connections for instances

    -- ===== Shared Settings =====
    sharedSettings = {
        TextSize = 14,
        TextFont = Enum.Font.GothamSemibold, -- Nicer font
        TextSpacing = 2, -- Pixels between vertical text elements
        LimitDistance = true,
        MaxDistance = 500,
        UseTeamColor = false, -- Overrides specific colors if true
        FriendlyTeamColor = { Color3.fromRGB(0, 170, 255), 0 }, -- Light blue
        EnemyTeamColor = { Color3.fromRGB(255, 80, 80), 0 }, -- Light red
    },

    -- ===== Team Settings (Defaults) =====
    teamSettings = {
        Enemy = {
            Enabled = true,
            UseVisibilityCheck = true, -- Check Line of Sight?
            -- == Box 2D ==
            Box2D = {
                Enabled = true, Type = "Corner", -- "Normal" or "Corner"
                Thickness = 1, CornerLengthRatio = 0.15, -- Used only if Type is "Corner"
                VisibleColor = { Color3.fromRGB(255, 50, 50), 0 }, OccludedColor = { Color3.fromRGB(200, 50, 50), 0.3 }, IgnoreTeamColor = false,
                Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } },
				Fill = { Enabled = false, TransparencyModifier = 0.6 }, -- Fill uses Box2D colors but adds transparency
            },
             -- == Box 3D ==
            Box3D = {
                Enabled = false, Thickness = 1,
                VisibleColor = { Color3.fromRGB(255, 50, 50), 0 }, OccludedColor = { Color3.fromRGB(200, 50, 50), 0.3 }, IgnoreTeamColor = false,
                Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } }
            },
            -- == Skeleton ==
            Skeleton = {
                Enabled = false, Thickness = 1,
				VisibleColor = { Color3.fromRGB(255, 150, 0), 0 }, OccludedColor = { Color3.fromRGB(200, 120, 0), 0.4 }, IgnoreTeamColor = true, -- Skeletons often look better ignoring team colors
                Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } }
            },
			-- == Head Dot ==
			HeadDot = {
				Enabled = false, Radius = 4, Thickness = 1, Filled = true, NumSides = 12,
				VisibleColor = { Color3.fromRGB(255, 255, 0), 0 }, OccludedColor = { Color3.fromRGB(200, 200, 0), 0.3 }, IgnoreTeamColor = true,
				Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } }
			},
            -- == Health Bar ==
            HealthBar = {
                Enabled = true, Orientation = "Vertical", -- "Vertical" or "Horizontal"
                Thickness = 4, Padding = 5, -- Pixels away from box edge
                ColorHealthy = Color3.fromRGB(0, 255, 0), ColorDying = Color3.fromRGB(255, 0, 0),
				VisibleTransparency = 0, OccludedTransparency = 0.4, -- Separate alpha control
                Background = { Enabled = true, Color = { Color3.new(0,0,0), 0.5 } },
                Outline = { Enabled = true, Thickness = 6, Color = { Color3.new(0,0,0), 0 } }
            },
            -- == Text Elements ==
            NameText = {
                Enabled = true, VPadding = 2, Size = 14, Font = Enum.Font.GothamSemibold,
                VisibleColor = { Color3.new(1,1,1), 0 }, OccludedColor = { Color3.new(0.8, 0.8, 0.8), 0.1 }, IgnoreTeamColor = true,
                Outline = { Enabled = true, Color = { Color3.new(0,0,0), 0 } }
            },
            DistanceText = {
                Enabled = true, VPadding = 2, Size = 12, Font = Enum.Font.Gotham, Format = "[{Distance}m]",
                VisibleColor = { Color3.new(1,1,1), 0 }, OccludedColor = { Color3.new(0.8, 0.8, 0.8), 0.1 }, IgnoreTeamColor = true,
                Outline = { Enabled = true, Color = { Color3.new(0,0,0), 0 } }
            },
			HealthText = {
				Enabled = false, AttachToBar = true, HPadding = 4, Size = 11, Font = Enum.Font.GothamBold, Format = "{Health} HP",
				VisibleColor = { Color3.new(1,1,1), 0 }, OccludedColor = { Color3.new(0.8, 0.8, 0.8), 0.1 }, IgnoreTeamColor = true,
                Outline = { Enabled = true, Color = { Color3.new(0,0,0), 0 } }
			},
            WeaponText = {
                Enabled = false, VPadding = 0, Size = 12, Font = Enum.Font.Gotham, Format = "{Weapon}",
                VisibleColor = { Color3.new(1,1,1), 0 }, OccludedColor = { Color3.new(0.8, 0.8, 0.8), 0.1 }, IgnoreTeamColor = true,
                Outline = { Enabled = true, Color = { Color3.new(0,0,0), 0 } }
            },
            -- == Tracer ==
            Tracer = {
                Enabled = false, Thickness = 1, Origin = "Bottom", -- "Top", "Bottom", "Middle", "Mouse"
				Target = "Box Bottom Center", -- "Head", "Torso", "Feet", "Box Bottom Center"
                VisibleColor = { Color3.fromRGB(255, 50, 50), 0 }, OccludedColor = { Color3.fromRGB(200, 50, 50), 0.3 }, IgnoreTeamColor = false,
                Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } }
            },
             -- == Look Vector ==
            LookVector = {
                Enabled = false, Thickness = 1, Length = 10, -- Studs
                VisibleColor = { Color3.fromRGB(0, 200, 255), 0 }, OccludedColor = { Color3.fromRGB(0, 150, 200), 0.3 }, IgnoreTeamColor = true,
                Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } }
            },
            -- == Off-Screen Arrow ==
            OffScreenArrow = {
                Enabled = true, Radius = 200, Size = 15,
                VisibleColor = { Color3.fromRGB(255, 50, 50), 0 }, OccludedColor = { Color3.fromRGB(255, 50, 50), 0 }, -- No occlusion for offscreen
                IgnoreTeamColor = false,
                Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } }
            },
            -- == Chams ==
            Chams = {
                Enabled = false, DepthMode = Enum.HighlightDepthMode.Occluded, -- Occluded or AlwaysOnTop
                FillColor = { VisibleColor = { Color3.fromRGB(255, 0, 0), 0.7 }, OccludedColor = { Color3.fromRGB(150, 0, 0), 0.8 } }, -- Reddish fill
                OutlineColor = { VisibleColor = { Color3.new(0,0,0), 0.2 }, OccludedColor = { Color3.new(0,0,0), 0.3 } } -- Subtle black outline
            }
        },
        Friendly = { -- Inherits from Enemy by default, overrides below
            Enabled = false, -- Disabled by default
            UseVisibilityCheck = true,
            Box2D = {
                Enabled = true, Type = "Normal", Thickness = 1,
                VisibleColor = { Color3.fromRGB(0, 170, 255), 0 }, OccludedColor = { Color3.fromRGB(0, 120, 200), 0.4 }, IgnoreTeamColor = false,
                Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } },
				Fill = { Enabled = false, TransparencyModifier = 0.7 },
            },
            Box3D = { Enabled = false }, -- Keep disabled
			Skeleton = { Enabled = false },
			HeadDot = { Enabled = false },
            HealthBar = {
                Enabled = true, Orientation = "Vertical", Thickness = 4, Padding = 5,
                ColorHealthy = Color3.fromRGB(0, 255, 0), ColorDying = Color3.fromRGB(255, 0, 0),
				VisibleTransparency = 0, OccludedTransparency = 0.4,
                Background = { Enabled = true, Color = { Color3.new(0,0,0), 0.5 } },
                Outline = { Enabled = true, Thickness = 6, Color = { Color3.new(0,0,0), 0 } }
            },
            NameText = {
                Enabled = true, VPadding = 2, Size = 14, Font = Enum.Font.GothamSemibold,
                VisibleColor = { Color3.new(1,1,1), 0 }, OccludedColor = { Color3.new(0.8, 0.8, 0.8), 0.1 }, IgnoreTeamColor = true,
                Outline = { Enabled = true, Color = { Color3.new(0,0,0), 0 } }
            },
            DistanceText = { Enabled = false }, -- Disabled for friends usually
			HealthText = { Enabled = false },
            WeaponText = { Enabled = false },
            Tracer = { Enabled = false },
            LookVector = { Enabled = false },
            OffScreenArrow = {
				Enabled = false, Radius = 150, Size = 12,
                VisibleColor = { Color3.fromRGB(0, 170, 255), 0 }, OccludedColor = { Color3.fromRGB(0, 170, 255), 0 },
                IgnoreTeamColor = false,
				Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } }
			},
            Chams = {
                Enabled = false, DepthMode = Enum.HighlightDepthMode.Occluded,
                FillColor = { VisibleColor = { Color3.fromRGB(0, 170, 255), 0.7 }, OccludedColor = { Color3.fromRGB(0, 120, 200), 0.8 } },
                OutlineColor = { VisibleColor = { Color3.new(0,0,0), 0.2 }, OccludedColor = { Color3.new(0,0,0), 0.3 } }
            }
        }
    },

    -- ===== Whitelist =====
    Whitelist = {}, -- List of UserIds to exclusively show ESP for (if populated)

    -- ===== Game Specific Functions (Implement these per game) =====
    getWeapon = function(player)
        -- Example: Search character for Tool, return name
        local character = player and player.Character
        if character then
            local tool = character:FindFirstChildOfClass("Tool")
            if tool then return tool.Name end
        end
        return "Unarmed" -- Default
    end,

    isFriendly = function(player)
        -- Default: Check Team, assumes FFA if teams don't exist or aren't used
        return player.Team and LocalPlayer.Team and player.Team == LocalPlayer.Team
    end,

    getTeamColor = function(player) -- Used if sharedSettings.UseTeamColor is true
		-- Default implementation
        return player and player.Team and player.Team.TeamColor and player.Team.TeamColor.Color
	end,

    getCharacter = function(player)
        return player and player.Character
    end,

    getHealth = function(player)
        local character = player and EspInterface.getCharacter(player) -- Use self reference
        local humanoid = character and findFirstChildOfClass(character, "Humanoid")
        if humanoid then
            return humanoid.Health, humanoid.MaxHealth
        end
        return 100, 100 -- Default
    end,

    -- ===== Internal Methods =====
    _CreatePlayerObjects = function(player)
        if EspInterface._ObjectCache[player] then return end -- Already exists
        if player == LocalPlayer then return end -- Don't make for self

        print("Creating ESP objects for:", player.Name)
        local espObj = EspObject.new(player, EspInterface)
        local chamObj = ChamObject.new(player, EspInterface)
        EspInterface._ObjectCache[player] = { espObj, chamObj }
    end,

    _RemovePlayerObjects = function(player)
        local objects = EspInterface._ObjectCache[player]
        if objects then
            print("Destroying ESP objects for:", player.Name)
            for _, obj in ipairs(objects) do
                pcall(obj.Destruct, obj) -- Safely call Destruct
            end
            EspInterface._ObjectCache[player] = nil
        end
    end,

	_SetupInstanceCleanup = function(instance, objRef)
		-- Simple cleanup: When instance is removed from game, destroy ESP
		local key = instance:GetDebugId() -- Unique key for the connection
		if EspInterface._InstanceCleanupConnections[key] then
			EspInterface._InstanceCleanupConnections[key]:Disconnect() -- Disconnect old if any
		end
		EspInterface._InstanceCleanupConnections[key] = instance.AncestryChanged:Connect(function(_, parent)
			if not parent then -- Instance removed from game
				if EspInterface._InstanceCleanupConnections[key] then
					EspInterface._InstanceCleanupConnections[key]:Disconnect()
					EspInterface._InstanceCleanupConnections[key] = nil
				end
				if EspInterface._ObjectCache[instance] then
					pcall(objRef.Destruct, objRef)
					EspInterface._ObjectCache[instance] = nil
				end
			end
		end)
	end,

    -- ===== Public API =====
    Load = function()
        if EspInterface._IsLoaded then warn("ESP Library already loaded.") return end
        print("Loading Advanced ESP Library...")

		-- Deep copy defaults for friendly team settings to avoid modifying the template
		local enemySettings = EspInterface.teamSettings.Enemy
		local friendlySettings = {}
		for k, v in pairs(enemySettings) do
			if type(v) == "table" then -- Deep copy tables (like Box2D, HealthBar etc.)
				friendlySettings[k] = {}
				for k2, v2 in pairs(v) do
					friendlySettings[k][k2] = v2 -- Copy inner tables/values
				end
			else
				friendlySettings[k] = v -- Copy primitive values
			end
		end
		-- Now apply the specific friendly overrides
		for k, v in pairs(EspInterface.teamSettings.Friendly) do
			if type(v) == "table" and type(friendlySettings[k]) == "table" then
				-- Merge nested tables (e.g., override only Enabled in Box2D)
				for k2, v2 in pairs(v) do
					friendlySettings[k][k2] = v2
				end
			else
				friendlySettings[k] = v -- Direct override
			end
		end
		EspInterface.teamSettings.Friendly = friendlySettings -- Replace template with processed settings


        -- Handle existing players
        for _, player in ipairs(Players:GetPlayers()) do
            EspInterface._CreatePlayerObjects(player)
        end

        -- Connect signals
        EspInterface._PlayerConnections.Added = Players.PlayerAdded:Connect(EspInterface._CreatePlayerObjects)
        EspInterface._PlayerConnections.Removing = Players.PlayerRemoving:Connect(EspInterface._RemovePlayerObjects)

        EspInterface._IsLoaded = true
        print("ESP Library Loaded Successfully.")
    end,

    Unload = function()
        if not EspInterface._IsLoaded then warn("ESP Library not loaded.") return end
        print("Unloading Advanced ESP Library...")

        -- Disconnect signals
        if EspInterface._PlayerConnections.Added then EspInterface._PlayerConnections.Added:Disconnect() end
        if EspInterface._PlayerConnections.Removing then EspInterface._PlayerConnections.Removing:Disconnect() end
		clear(EspInterface._PlayerConnections)

		-- Disconnect instance cleanup signals
		for key, conn in pairs(EspInterface._InstanceCleanupConnections) do
			conn:Disconnect()
		end
		clear(EspInterface._InstanceCleanupConnections)

        -- Destroy all cached objects
        for key, objOrTable in pairs(EspInterface._ObjectCache) do
            if type(objOrTable) == "table" then -- Player objects (ESP + Chams)
                for _, obj in ipairs(objOrTable) do
                    pcall(obj.Destruct, obj)
                end
            else -- Instance object
                pcall(objOrTable.Destruct, objOrTable)
            end
        end
        clear(EspInterface._ObjectCache)

		-- Destroy container? Optional, depends if other scripts use it
		-- DrawingContainer:Destroy()

        EspInterface._IsLoaded = false
        print("ESP Library Unloaded.")
    end,

    AddInstance = function(instance, options)
        if not EspInterface._IsLoaded then warn("Cannot add instance ESP, library not loaded.") return end
        if not instance or typeof(instance) ~= "Instance" then warn("AddInstance: Invalid instance provided.") return end
        if EspInterface._ObjectCache[instance] then warn("AddInstance: ESP already exists for this instance.") return EspInterface._ObjectCache[instance] end

        local instanceEsp = InstanceObject.new(instance, options or {}, EspInterface)
        EspInterface._ObjectCache[instance] = instanceEsp
		EspInterface._SetupInstanceCleanup(instance, instanceEsp) -- Setup automatic removal
        return instanceEsp
    end,

    RemoveInstance = function(instance)
        if not instance then return end
        local obj = EspInterface._ObjectCache[instance]
        if obj then
			local key = instance:GetDebugId()
			if EspInterface._InstanceCleanupConnections[key] then
				EspInterface._InstanceCleanupConnections[key]:Disconnect()
				EspInterface._InstanceCleanupConnections[key] = nil
			end
            pcall(obj.Destruct, obj)
            EspInterface._ObjectCache[instance] = nil
			return true
        end
		return false
    end,

    UpdateSetting = function(category, settingName, value)
		-- Example: EspInterface.UpdateSetting("sharedSettings", "MaxDistance", 1000)
		-- Example: EspInterface.UpdateSetting("Enemy", "Box2D", { Enabled = false }) -- Update nested table
        if category == "sharedSettings" then
            EspInterface.sharedSettings[settingName] = value
		elseif EspInterface.teamSettings[category] then
			-- Handle nested updates carefully
			if type(EspInterface.teamSettings[category][settingName]) == "table" and type(value) == "table" then
				for k, v in pairs(value) do
					EspInterface.teamSettings[category][settingName][k] = v
				end
			else
				EspInterface.teamSettings[category][settingName] = value
			end
        else
            warn("Invalid setting category:", category)
        end
    end,

	-- Add function to update Instance ESP options after creation
	UpdateInstanceOptions = function(instance, newOptions)
		local obj = EspInterface._ObjectCache[instance]
		if obj and obj.UpdateOptions then -- Check if it's an InstanceObject
			obj:UpdateOptions(newOptions)
		else
			warn("UpdateInstanceOptions: No ESP found for instance or object doesn't support updates:", instance)
		end
	end,

	Toggle = function(enabled) -- Simple master toggle
		EspInterface.teamSettings.Enemy.Enabled = enabled
		EspInterface.teamSettings.Friendly.Enabled = enabled
		-- Could also toggle instance ESP based on a shared flag if needed
	end
}

-- Set Metatable for Team Settings access if needed (e.g., EspInterface.Enemy.Box.Enabled)
-- setmetatable(EspInterface, { __index = EspInterface.teamSettings }) -- Optional convenience

-- Automatically initialize Drawing Container
DrawingContainer = getDrawingContainer()

return EspInterface
