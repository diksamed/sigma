--[[
Advanced ESP Library
Version: 2.5 (Fixed GetRobloxGui error, using CoreGui directly)

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
-- local GuiService -- No longer needed here
local CoreGui -- Lazy loaded for gethui

-- Variables
local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera
local ViewportSize = Camera.ViewportSize

-- Drawing Container (Uses CoreGui) -- CORRECTED FUNCTION
local function getDrawingContainer()
    -- Ensure CoreGui service is loaded
    if not CoreGui then CoreGui = game:GetService("CoreGui") end

    -- Directly use CoreGui as the parent
    local containerParent = CoreGui
    local container = containerParent:FindFirstChild("EspDrawingContainer")

    if not container then
        -- Create the container Folder if it doesn't exist
        container = Instance.new("Folder", containerParent)
        container.Name = "EspDrawingContainer"
        -- Optional: Make it non-archivable if saving place state matters
        -- container.Archivable = false
    end
    return container
end
-- Initialize DrawingContainer using the corrected function
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
local unpack = table.unpack or unpack -- Compatibility
local find = table.find
local create = table.create -- Luau optimization
local fromMatrix = CFrame.fromMatrix
local wtvp = Camera.WorldToViewportPoint
local getPivot = Workspace.GetPivot
local findFirstChild = Instance.FindFirstChild
local findFirstChildOfClass = Instance.FindFirstChildOfClass
local getChildren = Instance.GetChildren
local toObjectSpace = CFrame.ToObjectSpace
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
    local bbCFrame, bbSize
	local success = pcall(function() bbCFrame, bbSize = character:GetBoundingBox() end)
	if not success or not bbCFrame then
		-- Fallback if GetBoundingBox fails (e.g., no PrimaryPart or parts)
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if hrp then
			bbCFrame = hrp.CFrame
			bbSize = hrp.Size
		else
			return { TopLeft = Vector2.zero, BottomRight = Vector2.zero, Size = Vector2.zero, Center = Vector2.zero, Corners = {} }, false, false
		end
	end


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
	local direction = targetPosition - origin
	local distance = direction.Magnitude
	if distance < 0.1 then return true end -- Target is too close, consider visible

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = ignoreList or {LocalPlayer.Character} -- Ignore self by default

    local result = raycast(origin, direction.Unit * distance, params)
    -- Consider visible if no hit, or hit is very close to the target (allowing for minor part intersections)
    return not result or (result.Position - targetPosition).Magnitude < 1.0
end

-- CORRECTED parseColor function (replaces the old one entirely)
local function parseColor(value, defaultColor, defaultTransparency)
    if type(value) == "table" then
        local color = value[1] or defaultColor
        local transparency = value[2] -- Get potential transparency value
        -- Explicitly check if transparency is nil, if so, use default
        if transparency == nil then
            transparency = defaultTransparency
        end
        return color, transparency
    elseif typeof(value) == "Color3" then
        -- If only a Color3 is provided, use the default transparency
        return value, defaultTransparency
    else
        -- Fallback if input is not a table or Color3
        return defaultColor, defaultTransparency
    end
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
	table.insert(self.Bin, drawing) -- Use table.insert
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
	if self.RenderConnection then self.RenderConnection:Disconnect() self.RenderConnection = nil end
	for _, drawing in ipairs(self.Bin) do
		pcall(drawing.Remove, drawing)
	end
	clear(self.Drawings)
	clear(self.Bin)
    clear(self.BonesCache)
    self.CharacterCache = nil
    -- print("ESP Object Destroyed for:", self.Player and self.Player.Name or "Unknown Player")
end

function EspObject:_Update()
    local interface = self.Interface
    local player = self.Player

    -- Check if player exists and is valid
    if not player or not player.Parent then
        self:Destruct() -- Destroy self if player left unexpectedly
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
    local head = self.Character:FindFirstChild("Head")
    local primaryPart = self.Character.PrimaryPart or self.Character:FindFirstChild("HumanoidRootPart") or head -- Fallback

    if not primaryPart then
        self.OnScreen = false
        self.Occluded = true
        self:_SetAllDrawingsVisible(false)
        return
    end

    self.HeadPosition = head and head.Position or primaryPart.Position -- Use head if available for visibility check/look vector
    local bounds, allCornersOnScreen, anyCornerInFront = getCharacterBounds(self.Character)

    self.Bounds = bounds
    self.OnScreen = anyCornerInFront and (self.Bounds.Size.X > 1 and self.Bounds.Size.Y > 1) -- Must have some size on screen and be in front
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
        self.Occluded = not self.OnScreen or (not self.Options.UseVisibilityCheck and self.OnScreen) -- If on screen but not checking vis, treat as visible
    end
    self.LastVisible = not self.Occluded -- Store inverse for clarity

    -- Off-Screen Direction
    if not self.OnScreen and self.Options.OffScreenArrow.Enabled and primaryPart then
		-- Use CFrame math for more reliable offscreen direction
		local pointToObject = Camera.CFrame:PointToObjectSpace(primaryPart.Position)
		if pointToObject.Z < 0 then -- Only calculate if target is roughly in front
			local screenPoint = Vector2.new(pointToObject.X / -pointToObject.Z * (ViewportSize.X/2), pointToObject.Y / -pointToObject.Z * (ViewportSize.Y/2)) * Vector2.new(1,-1)
        	local centerOffset = screenPoint -- screenPoint is already relative to center *if* using projection math
        	self.OffScreenDirection = centerOffset.Unit
		else
			-- If point is behind, estimate direction based on world space diff projected onto camera plane
			local camPos = Camera.CFrame.Position
			local targetPos = primaryPart.Position
			local diff = Vector3.new(targetPos.X, camPos.Y, targetPos.Z) - Vector3.new(camPos.X, camPos.Y, camPos.Z) -- Flattened difference
			local localDiff = Camera.CFrame:VectorToObjectSpace(diff)
			self.OffScreenDirection = Vector2.new(localDiff.X, -localDiff.Z).Unit -- Use -Z as Y component for screen direction
		end
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
		if drawing and drawing.Visible ~= visible then -- Check if drawing exists and needs changing
        	drawing.Visible = visible
		end
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
-- ... (Render functions remain unchanged from v2.4) ...
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
	if size.X < 1 or size.Y < 1 then return end -- Avoid drawing on zero size bounds

	local cornerLength = math.min(size.X, size.Y) * opt.CornerLengthRatio -- Length relative to smallest dimension
	cornerLength = math.max(2, cornerLength) -- Minimum pixel length

	local tl, tr, bl, br = bounds.TopLeft, bounds.TopLeft + Vector2.new(size.X, 0), bounds.TopLeft + Vector2.new(0, size.Y), bounds.BottomRight

	local points = {
		-- Top Left
		{ From = tl, To = tl + Vector2.new(cornerLength, 0) },
		{ From = tl, To = tl + Vector2.new(0, cornerLength) },
		-- Top Right
		{ From = tr, To = tr - Vector2.new(cornerLength, 0) },
		{ From = tr, To = tr + Vector2.new(0, cornerLength) },
		-- Bottom Left
		{ From = bl, To = bl + Vector2.new(cornerLength, 0) },
		{ From = bl, To = bl - Vector2.new(0, cornerLength) },
		-- Bottom Right
		{ From = br, To = br - Vector2.new(cornerLength, 0) },
		{ From = br, To = br - Vector2.new(0, cornerLength) }
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
        {1, 2}, {2, 3}, {3, 4}, {4, 1}, -- Bottom face (assuming indices 1-4 are one face)
        {5, 6}, {6, 7}, {7, 8}, {8, 5}, -- Top face (assuming indices 5-8 are the opposite)
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
            local pos1, onScreen1, _, inFront1 = worldToScreen(part1.Position)
            local pos2, onScreen2, _, inFront2 = worldToScreen(part2.Position)

            -- Only draw if both points are in front of the camera to avoid lines stretching across screen
            if inFront1 and inFront2 then
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
                lineIndex += 1
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

    local headPos2D, onScreen, _, inFront = worldToScreen(head.Position)
    -- Only show if head is actually on screen and in front
    if not onScreen or not inFront then
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
	if bounds.Size.X < 1 or bounds.Size.Y < 1 then return end -- Don't draw on zero size bounds

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
	-- Ensure bar doesn't draw if health is zero to avoid visual glitches
	if healthPerc > 0.001 then
		d.HealthBar.Visible = true
		applyDrawProperties(d.HealthBar, { From = from, To = to, Color = barColor, Transparency = barTrans, Thickness = barThickness })
	else
		d.HealthBar.Visible = false
	end
end

function EspObject:_RenderTextElements()
    local d = self.Drawings
    local sharedOpt = self.SharedOptions
    local bounds = self.Bounds
	if not self.OnScreen or bounds.Size.X < 1 or bounds.Size.Y < 1 then
		-- Hide all text elements if offscreen or bounds invalid
		d.NameText.Visible = false
		d.DistanceText.Visible = false
		d.HealthText.Visible = false
		d.WeaponText.Visible = false
		return
	end

    local currentYOffset_Top = 0 -- Keep track of vertical space used by text above box
    local currentYOffset_Bottom = 0 -- Keep track of vertical space used by text below box
	local baseTextProps = {} -- Cache common properties

    -- Helper to render a text element
    local function renderText(elementName, drawing, textValue, basePosition, verticalAnchor, horizontalAnchor)
        local opt = self.Options[elementName]
        local enabled = self.Enabled and self.OnScreen and opt.Enabled -- Re-check enabled

        drawing.Visible = enabled
        if not enabled or not textValue or textValue == "" then return 0 end -- Return 0 height if not visible or no text

        local color, trans = self:_GetColor(elementName)
        local outlineColor, outlineTrans = self:_GetOutlineColor(elementName .. "Outline") -- Assumes Outline setting exists

		-- Update common properties (only needed once per frame ideally, but here for safety)
		baseTextProps.Size = opt.Size or sharedOpt.TextSize
        baseTextProps.Font = opt.Font or sharedOpt.TextFont
        baseTextProps.Color = color
        baseTextProps.Transparency = trans
        baseTextProps.Outline = opt.Outline.Enabled
        baseTextProps.OutlineColor = outlineColor
        -- baseTextProps.OutlineTransparency = outlineTrans -- Assuming Drawing doesn't support this yet

		-- Set text first to get bounds
		drawing.Text = textValue
		local textBounds = drawing.TextBounds
		if textBounds.X == 0 and textBounds.Y == 0 then return 0 end -- Skip if text is empty or bounds are zero

		-- Calculate final position based on anchors
		local finalPos = basePosition
		if horizontalAnchor == "Center" then
			finalPos = finalPos - Vector2.new(textBounds.X * 0.5, 0)
		elseif horizontalAnchor == "Right" then
			finalPos = finalPos - Vector2.new(textBounds.X, 0)
		end
		-- Vertical anchor applied by the caller using currentYOffset

        applyDrawProperties(drawing, baseTextProps) -- Apply common props
		drawing.Position = finalPos -- Apply calculated position

        return textBounds.Y + sharedOpt.TextSpacing -- Return height used + spacing
    end

    -- == Top Text Elements ==
    local nameOpt = self.Options.NameText
	local nameBasePos = bounds.TopLeft + Vector2.new(bounds.Size.X * 0.5, -(nameOpt.Size or sharedOpt.TextSize) - nameOpt.VPadding - currentYOffset_Top)
	local nameHeight = renderText("NameText", d.NameText, self.Player.DisplayName, nameBasePos, "Top", "Center")
	currentYOffset_Top += nameHeight

	local healthOpt = self.Options.HealthText
	local healthBasePos -- Declared outside if/else
	local healthHeight = 0 -- Initialize height
	if healthOpt.Enabled then
		-- Corrected formatting using gsub
        local formatString = healthOpt.Format
        local healthStr = formatString:gsub("{Health}", tostring(round(self.Health))):gsub("{MaxHealth}", tostring(self.MaxHealth))

        if self.Options.HealthBar.Enabled and healthOpt.AttachToBar and d.HealthBar.Visible then
             -- Position near the end of the health bar
             local barDraw = d.HealthBar
			 local barOpt = self.Options.HealthBar
             if barOpt.Orientation == "Vertical" then
                 healthBasePos = Vector2.new(barDraw.From.X - healthOpt.HPadding, barDraw.From.Y) -- Attach near top of bar's current health
				 healthHeight = renderText("HealthText", d.HealthText, healthStr, healthBasePos, "Middle", "Right") -- Align right, middle vertically
             else -- Horizontal
                 healthBasePos = Vector2.new(barDraw.To.X + healthOpt.HPadding, barDraw.To.Y) -- Attach near right of bar's current health
				 healthHeight = renderText("HealthText", d.HealthText, healthStr, healthBasePos, "Middle", "Left") -- Align left, middle vertically
             end
        else
            -- Position below the previously calculated top element (Name)
             healthBasePos = bounds.TopLeft + Vector2.new(bounds.Size.X * 0.5, -(nameOpt.Size or sharedOpt.TextSize) - nameOpt.VPadding - currentYOffset_Top)
			 healthHeight = renderText("HealthText", d.HealthText, healthStr, healthBasePos, "Top", "Center")
        end
		currentYOffset_Top += healthHeight -- Add height regardless of attachment for spacing calculation
	else
		d.HealthText.Visible = false -- Explicitly hide if disabled
	end

    -- == Bottom Text Elements ==
    local distOpt = self.Options.DistanceText
	local distBasePos = bounds.BottomLeft + Vector2.new(bounds.Size.X * 0.5, distOpt.VPadding + currentYOffset_Bottom)
    local distHeight = 0
    if distOpt.Enabled then
        local formatString = distOpt.Format
        local distStr = formatString:gsub("{Distance}", tostring(round(self.Distance)))
		distHeight = renderText("DistanceText", d.DistanceText, distStr, distBasePos, "Bottom", "Center")
	else
		d.DistanceText.Visible = false
	end
	currentYOffset_Bottom += distHeight


    local wepOpt = self.Options.WeaponText
	local wepBasePos = bounds.BottomLeft + Vector2.new(bounds.Size.X * 0.5, wepOpt.VPadding + currentYOffset_Bottom)
    local wepHeight = 0
    if wepOpt.Enabled then
        local formatString = wepOpt.Format
        local wepStr = formatString:gsub("{Weapon}", self.WeaponName) -- Use cached weapon name
        wepHeight = renderText("WeaponText", d.WeaponText, wepStr, wepBasePos, "Bottom", "Center")
	else
		d.WeaponText.Visible = false
	end
	currentYOffset_Bottom += wepHeight

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
	local targetPart = nil
	if targetOpt == "Head" then targetPart = self.BonesCache["Head"]
	elseif targetOpt == "Torso" then targetPart = self.BonesCache["UpperTorso"] or self.BonesCache["LowerTorso"]
	elseif targetOpt == "Feet" then targetPart = self.BonesCache["LeftFoot"] or self.BonesCache["RightFoot"] -- Simplification
	end

	if targetPart then
		local screenPos, onScreen, _, inFront = worldToScreen(targetPart.Position)
		if onScreen and inFront then targetPoint = screenPos end -- Use part pos if valid
	end

	-- Fallback to Box Bottom Center if specific part invalid or not chosen
	if not targetPoint then
        if bounds and bounds.BottomLeft then -- Ensure bounds is valid
		    targetPoint = bounds.BottomLeft + Vector2.new(bounds.Size.X * 0.5, 0)
        else
            d.TracerLine.Visible = false -- Cannot determine target
            d.TracerOutline.Visible = false
            return
        end
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

    local startPos, startOnScreen, _, startInFront = worldToScreen(startPosWorld)
    local endPos, endOnScreen, _, endInFront = worldToScreen(endPosWorld)

    -- Only draw if start is on screen and in front (avoids weird lines from behind)
    if not startOnScreen or not startInFront then
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
	-- Rotated triangle points based on angle
    local size = opt.Size
	local angleAdjustRad = 25 * (pi/180) -- Angle for triangle points relative to direction (~25 degrees)
	local cosAngle = cos(angle)
	local sinAngle = sin(angle)

	local p1 = centerPos -- Tip of the arrow points towards centerPos

	-- Calculate back points relative to tip and angle
	local backDist = size * 1.5 -- How far back the base is
	local halfWidth = size -- How wide the base is

	local backCenter = p1 - Vector2.new(cosAngle, sinAngle) * backDist

	local rightVector = Vector2.new(sinAngle, -cosAngle) -- Perpendicular vector

	local p2 = backCenter + rightVector * halfWidth
	local p3 = backCenter - rightVector * halfWidth


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
		self:_RenderTextElements() -- Combined text rendering
		self:_RenderTracer()
        self:_RenderLookVector()

        -- Hide offscreen arrow if we are now on screen
        if self.Drawings.OffScreenArrow and self.Drawings.OffScreenArrow.Visible then
            self.Drawings.OffScreenArrow.Visible = false
            self.Drawings.OffScreenArrowOutline.Visible = false
        end
	else
		-- Hide all on-screen elements if we are off-screen
        if self.Drawings.Box2D and self.Drawings.Box2D.Visible then -- Quick check if hiding is needed
            self:_SetAllDrawingsVisible(false) -- Hide everything except potentially the arrow
        end
        -- Render Off-Screen Elements
		self:_RenderOffScreenArrow() -- Will only draw if enabled and direction exists
	end
end

-- ================= Cham Object (Highlights) =================
-- ... (ChamObject code remains unchanged from v2.4) ...
local ChamObject = {}
ChamObject.__index = ChamObject

function ChamObject.new(player, interface)
    local self = setmetatable({}, ChamObject)
    self.Player = player
    self.Interface = interface
    self.Highlight = Instance.new("Highlight")
    self.Highlight.Name = "EspCham_" .. (player and player.Name or "InvalidPlayer")
    self.Highlight.Adornee = nil
    self.Highlight.Enabled = false
    self.Highlight.Parent = DrawingContainer -- Keep highlights organized

    self.UpdateConnection = RunService.Heartbeat:Connect(function() -- Heartbeat is fine for chams
		-- Wrap update in pcall for extra safety during player leaving etc.
		pcall(self._Update, self)
    end)
    return self
end

function ChamObject:Destruct()
    if self.UpdateConnection then self.UpdateConnection:Disconnect() self.UpdateConnection = nil end
    if self.Highlight then pcall(self.Highlight.Destroy, self.Highlight) self.Highlight = nil end
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
		local primary = character.PrimaryPart or character:FindFirstChild("HumanoidRootPart")
		if primary then
			local dist = (Camera.CFrame.Position - primary.Position).Magnitude
			if dist > sharedOptions.MaxDistance then
				enabled = false
			end
		else
			enabled = false -- Disable if no primary part for distance check
		end
	end

	if not character then enabled = false end -- Disable if no character

    if self.Highlight then -- Check if highlight still exists
		self.Highlight.Enabled = enabled

		if enabled then
			if self.Highlight.Adornee ~= character then
				self.Highlight.Adornee = character -- Update adornee if needed
			end

			local fillVisibleColor, fillVisibleTrans = parseColor(options.FillColor.VisibleColor, Color3.fromRGB(255,0,0), 0.5)
			local fillOccludedColor, fillOccludedTrans = parseColor(options.FillColor.OccludedColor, Color3.fromRGB(0,0,255), 0.5)

			local outlineVisibleColor, outlineVisibleTrans = parseColor(options.OutlineColor.VisibleColor, Color3.fromRGB(255,255,255), 0)
			local outlineOccludedColor, outlineOccludedTrans = parseColor(options.OutlineColor.OccludedColor, Color3.fromRGB(200,200,200), 0)

			-- Determine colors based on DepthMode
			if options.DepthMode == Enum.HighlightDepthMode.AlwaysOnTop then
				-- Always on top uses Occluded colors conceptually, as it draws over everything
				self.Highlight.FillColor = fillOccludedColor
				self.Highlight.FillTransparency = fillOccludedTrans
				self.Highlight.OutlineColor = outlineOccludedColor
				self.Highlight.OutlineTransparency = outlineOccludedTrans
			else -- Occluded mode - This makes the highlight behave like a normal object regarding occlusion
				-- Standard highlights don't have separate visible/occluded colors built-in.
				-- We *could* simulate this by having TWO highlights, one AlwaysOnTop and one Occluded,
				-- but that adds complexity. Here, we use the "Visible" color setting for Occluded mode.
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
end

-- ================= Instance ESP Object =================
-- ... (InstanceObject code remains unchanged from v2.4, includes the ?? fix) ...
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
		pcall(self._Render, self) -- Wrap render in pcall
    end)
    -- print("Instance ESP Created for:", instance:GetFullName())
    return self
end

-- CORRECTED InstanceObject:_InitializeDefaults function
function InstanceObject:_InitializeDefaults()
    local opt = self.Options
    local shared = self.Interface.sharedSettings

    -- Use standard 'or' or explicit nil checks instead of ??
    if opt.Enabled == nil then opt.Enabled = true end
	if opt.UseVisibilityCheck == nil then opt.UseVisibilityCheck = true end
	if opt.RequiresLineOfSight == nil then opt.RequiresLineOfSight = false end

    opt.Format = opt.Format or "{Name}\n[{Distance}m]"
    opt.Color = opt.Color or { VisibleColor = {Color3.new(1,1,1), 0}, OccludedColor = {Color3.new(0.8,0.8,0.8), 0.1} }
    opt.Outline = opt.Outline or { Enabled = true, Color = {Color3.new(0,0,0), 0}, Thickness = 1 }
    opt.Text = opt.Text or { Size = shared.TextSize, Font = shared.TextFont }
    opt.MaxDistance = opt.MaxDistance or shared.MaxDistance
end


function InstanceObject:Destruct()
    if self.RenderConnection then self.RenderConnection:Disconnect() self.RenderConnection = nil end
    if self.DrawingText then pcall(self.DrawingText.Remove, self.DrawingText) self.DrawingText = nil end
    clear(self)
    -- print("Instance ESP Destroyed")
end

function InstanceObject:UpdateOptions(newOptions)
    for key, value in pairs(newOptions) do
		-- Deep merge for nested tables like Outline, Text, Color
		if type(self.Options[key]) == "table" and type(value) == "table" then
			for k2, v2 in pairs(value) do
				self.Options[key][k2] = v2
			end
		else
        	self.Options[key] = value
		end
    end
    self:_InitializeDefaults() -- Re-apply defaults/structure if options change
end

function InstanceObject:_Render()
    local instance = self.Instance
    local opt = self.Options
    local shared = self.Interface.sharedSettings
    local text = self.DrawingText

    -- Basic checks
    if not instance or not instance.Parent or not opt.Enabled or not text then
        if text then text.Visible = false end
        return
    end

    -- Get position (handle models vs parts)
    local worldPosition
    local success, result = pcall(function()
         if instance:IsA("Model") then
			 local modelBBcenter = instance:GetBoundingBox().Position
             worldPosition = modelBBcenter -- Use center of model bounds
         elseif instance:IsA("BasePart") then
             worldPosition = instance.Position
         else
			 local pivot = getPivot(instance)
             worldPosition = pivot and pivot.Position -- Fallback using pivot CFrame
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
		local ignoreList = {LocalPlayer.Character} -- Ignore self
		if instance:IsA("Model") or instance:IsA("BasePart") then table.insert(ignoreList, instance) end -- Ignore the instance itself
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

    -- Format Text String - CORRECTED USING GSUB
    local formatString = opt.Format
    local formattedText = formatString
        :gsub("{Name}", instance.Name)
        :gsub("{Distance}", tostring(round(distance)))
        :gsub("{Position}", string.format("%.1f, %.1f, %.1f", worldPosition.X, worldPosition.Y, worldPosition.Z))
		:gsub("{Class}", instance.ClassName)
		-- Add more placeholders as needed

	-- Set text first for bounds calculation
	text.Text = formattedText
	local textBounds = text.TextBounds
	if textBounds.X == 0 and textBounds.Y == 0 and #formattedText > 0 then
		-- If bounds are zero but text isn't empty, text might not be rendered yet. Skip applying pos this frame.
		-- Consider adding a small delay or check next frame if this becomes an issue.
	else
    	-- Apply Drawing Properties
		applyDrawProperties(text, {
			-- Position is centered horizontally by default if Center=true
			Position = screenPos - Vector2.new(0, textBounds.Y * 0.5), -- Center vertically too
			Color = mainColor,
			Transparency = mainTrans,
			Size = opt.Text.Size,
			Font = opt.Text.Font,
			Outline = opt.Outline.Enabled,
			OutlineColor = outlineColor,
			-- OutlineTransparency = outlineTrans -- If Drawing supports
		})
		-- Manually set outline thickness if separate property exists
		if text.OutlineThickness then text.OutlineThickness = opt.Outline.Thickness end
	end
end

-- ================= ESP Interface (Main Controller) =================
-- ... (EspInterface table and methods remain unchanged from v2.4 - COMMAS ARE CORRECT) ...
local EspInterface = { -- START EspInterface Table {1}
    _IsLoaded = false,
    _ObjectCache = {},
    _PlayerConnections = {},
    _InstanceCleanupConnections = {},

    sharedSettings = { -- START sharedSettings Table {2}
        TextSize = 14,
        TextFont = Enum.Font.GothamSemibold,
        TextSpacing = 2,
        LimitDistance = true,
        MaxDistance = 500,
        UseTeamColor = false,
        FriendlyTeamColor = { Color3.fromRGB(0, 170, 255), 0 },
        EnemyTeamColor = { Color3.fromRGB(255, 80, 80), 0 },
    }, -- END sharedSettings Table }2 COMMA

    teamSettings = { -- START teamSettings Table {3}
        Enemy = { -- START Enemy Table {4}
            Enabled = true,
            UseVisibilityCheck = true,
            Box2D = {
                Enabled = true, Type = "Corner",
                Thickness = 1, CornerLengthRatio = 0.15,
                VisibleColor = { Color3.fromRGB(255, 50, 50), 0 }, OccludedColor = { Color3.fromRGB(200, 50, 50), 0.3 }, IgnoreTeamColor = false,
                Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } },
				Fill = { Enabled = false, TransparencyModifier = 0.6, VisibleColor = { Color3.fromRGB(255, 50, 50), 0 }, OccludedColor = { Color3.fromRGB(200, 50, 50), 0.3 } },
            }, -- COMMA
             Box3D = {
                Enabled = false, Thickness = 1,
                VisibleColor = { Color3.fromRGB(255, 50, 50), 0 }, OccludedColor = { Color3.fromRGB(200, 50, 50), 0.3 }, IgnoreTeamColor = false,
                Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } }
            }, -- COMMA
            Skeleton = {
                Enabled = false, Thickness = 1,
				VisibleColor = { Color3.fromRGB(255, 150, 0), 0 }, OccludedColor = { Color3.fromRGB(200, 120, 0), 0.4 }, IgnoreTeamColor = true,
                Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } }
            }, -- COMMA
			HeadDot = {
				Enabled = false, Radius = 4, Thickness = 1, Filled = true, NumSides = 12,
				VisibleColor = { Color3.fromRGB(255, 255, 0), 0 }, OccludedColor = { Color3.fromRGB(200, 200, 0), 0.3 }, IgnoreTeamColor = true,
				Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } }
			}, -- COMMA
            HealthBar = {
                Enabled = true, Orientation = "Vertical",
                Thickness = 4, Padding = 5,
                ColorHealthy = Color3.fromRGB(0, 255, 0), ColorDying = Color3.fromRGB(255, 0, 0),
				VisibleTransparency = 0, OccludedTransparency = 0.4,
                Background = { Enabled = true, Color = { Color3.new(0,0,0), 0.5 } },
                Outline = { Enabled = true, Thickness = 6, Color = { Color3.new(0,0,0), 0 } }
            }, -- COMMA
            NameText = {
                Enabled = true, VPadding = 2, Size = 14, Font = Enum.Font.GothamSemibold, Format = "{Name}",
                VisibleColor = { Color3.new(1,1,1), 0 }, OccludedColor = { Color3.new(0.8, 0.8, 0.8), 0.1 }, IgnoreTeamColor = true,
                Outline = { Enabled = true, Color = { Color3.new(0,0,0), 0 } }
            }, -- COMMA
            DistanceText = {
                Enabled = true, VPadding = 2, Size = 12, Font = Enum.Font.Gotham, Format = "[{Distance}m]",
                VisibleColor = { Color3.new(1,1,1), 0 }, OccludedColor = { Color3.new(0.8, 0.8, 0.8), 0.1 }, IgnoreTeamColor = true,
                Outline = { Enabled = true, Color = { Color3.new(0,0,0), 0 } }
            }, -- COMMA
			HealthText = {
				Enabled = false, AttachToBar = true, HPadding = 4, Size = 11, Font = Enum.Font.GothamBold, Format = "{Health}HP",
				VisibleColor = { Color3.new(1,1,1), 0 }, OccludedColor = { Color3.new(0.8, 0.8, 0.8), 0.1 }, IgnoreTeamColor = true,
                Outline = { Enabled = true, Color = { Color3.new(0,0,0), 0 } }
			}, -- COMMA
            WeaponText = {
                Enabled = false, VPadding = 0, Size = 12, Font = Enum.Font.Gotham, Format = "{Weapon}",
                VisibleColor = { Color3.new(1,1,1), 0 }, OccludedColor = { Color3.new(0.8, 0.8, 0.8), 0.1 }, IgnoreTeamColor = true,
                Outline = { Enabled = true, Color = { Color3.new(0,0,0), 0 } }
            }, -- COMMA
            Tracer = {
                Enabled = false, Thickness = 1, Origin = "Bottom",
				Target = "Box Bottom Center",
                VisibleColor = { Color3.fromRGB(255, 50, 50), 0 }, OccludedColor = { Color3.fromRGB(200, 50, 50), 0.3 }, IgnoreTeamColor = false,
                Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } }
            }, -- COMMA
            LookVector = {
                Enabled = false, Thickness = 1, Length = 10,
                VisibleColor = { Color3.fromRGB(0, 200, 255), 0 }, OccludedColor = { Color3.fromRGB(0, 150, 200), 0.3 }, IgnoreTeamColor = true,
                Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } }
            }, -- COMMA
            OffScreenArrow = {
                Enabled = true, Radius = 200, Size = 15,
                VisibleColor = { Color3.fromRGB(255, 50, 50), 0 }, OccludedColor = { Color3.fromRGB(255, 50, 50), 0 },
                IgnoreTeamColor = false,
                Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } }
            }, -- COMMA
            Chams = {
                Enabled = false, DepthMode = Enum.HighlightDepthMode.Occluded,
                FillColor = { VisibleColor = { Color3.fromRGB(255, 0, 0), 0.7 }, OccludedColor = { Color3.fromRGB(150, 0, 0), 0.8 } },
                OutlineColor = { VisibleColor = { Color3.new(0,0,0), 0.2 }, OccludedColor = { Color3.new(0,0,0), 0.3 } }
            } -- NO COMMA
        }, -- END Enemy Table }4 COMMA

        Friendly = { -- START Friendly Table {5} -- THIS IS THE TABLE DEFINITION USED IN THE MERGE LATER
            Enabled = false,
            UseVisibilityCheck = true,
            Box2D = {
                Enabled = true, Type = "Normal", Thickness = 1, CornerLengthRatio = 0.15,
                VisibleColor = { Color3.fromRGB(0, 170, 255), 0 }, OccludedColor = { Color3.fromRGB(0, 120, 200), 0.4 }, IgnoreTeamColor = false,
				Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } }, -- Added Outline from Enemy base
				Fill = { Enabled = false, TransparencyModifier = 0.7, VisibleColor = { Color3.fromRGB(0, 170, 255), 0 }, OccludedColor = { Color3.fromRGB(0, 120, 200), 0.4 } },
            }, -- COMMA
            Box3D = { Enabled = false }, -- COMMA
			Skeleton = { Enabled = false }, -- COMMA
			HeadDot = { Enabled = false }, -- COMMA
            HealthBar = { -- Copied more from Enemy base for consistency
                Enabled = true, Orientation = "Vertical",
                Thickness = 4, Padding = 5,
                ColorHealthy = Color3.fromRGB(0, 255, 0), ColorDying = Color3.fromRGB(255, 0, 0),
				VisibleTransparency = 0, OccludedTransparency = 0.4,
                Background = { Enabled = true, Color = { Color3.new(0,0,0), 0.5 } },
                Outline = { Enabled = true, Thickness = 6, Color = { Color3.new(0,0,0), 0 } }
            }, -- COMMA
            NameText = { -- Copied more from Enemy base
                Enabled = true, VPadding = 2, Size = 14, Font = Enum.Font.GothamSemibold, Format = "{Name}",
                VisibleColor = { Color3.new(1,1,1), 0 }, OccludedColor = { Color3.new(0.8, 0.8, 0.8), 0.1 }, IgnoreTeamColor = true,
                Outline = { Enabled = true, Color = { Color3.new(0,0,0), 0 } }
            }, -- COMMA
            DistanceText = { Enabled = false, VPadding = 2, Size = 12, Font = Enum.Font.Gotham, Format = "[{Distance}m]", VisibleColor = { Color3.new(1,1,1), 0 }, OccludedColor = { Color3.new(0.8, 0.8, 0.8), 0.1 }, IgnoreTeamColor = true, Outline = { Enabled = true, Color = { Color3.new(0,0,0), 0 } } }, -- COMMA
			HealthText = { Enabled = false, AttachToBar = true, HPadding = 4, Size = 11, Font = Enum.Font.GothamBold, Format = "{Health}HP", VisibleColor = { Color3.new(1,1,1), 0 }, OccludedColor = { Color3.new(0.8, 0.8, 0.8), 0.1 }, IgnoreTeamColor = true, Outline = { Enabled = true, Color = { Color3.new(0,0,0), 0 } } }, -- COMMA
            WeaponText = { Enabled = false, VPadding = 0, Size = 12, Font = Enum.Font.Gotham, Format = "{Weapon}", VisibleColor = { Color3.new(1,1,1), 0 }, OccludedColor = { Color3.new(0.8, 0.8, 0.8), 0.1 }, IgnoreTeamColor = true, Outline = { Enabled = true, Color = { Color3.new(0,0,0), 0 } } }, -- COMMA
            Tracer = { Enabled = false }, -- COMMA
            LookVector = { Enabled = false }, -- COMMA
            OffScreenArrow = {
				Enabled = false, Radius = 150, Size = 12,
                VisibleColor = { Color3.fromRGB(0, 170, 255), 0 }, OccludedColor = { Color3.fromRGB(0, 170, 255), 0 },
                IgnoreTeamColor = false,
				Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } }
			}, -- COMMA
            Chams = {
                Enabled = false, DepthMode = Enum.HighlightDepthMode.Occluded,
                FillColor = { VisibleColor = { Color3.fromRGB(0, 170, 255), 0.7 }, OccludedColor = { Color3.fromRGB(0, 120, 200), 0.8 } },
                OutlineColor = { VisibleColor = { Color3.new(0,0,0), 0.2 }, OccludedColor = { Color3.new(0,0,0), 0.3 } }
            } -- NO COMMA
        } -- END Friendly Table }5
    }, -- END teamSettings Table }3 COMMA

    Whitelist = {}, -- COMMA

    -- ===== Game Specific Functions (Implement these per game) =====
    getWeapon = function(player)
        local character = player and player.Character
        if character then
            local tool = character:FindFirstChildOfClass("Tool")
            if tool then return tool.Name end
        end
        return "Unarmed"
    end, -- COMMA

    isFriendly = function(player)
		if not LocalPlayer or not player then return false end
        return player.Team and LocalPlayer.Team and player.Team == LocalPlayer.Team
    end, -- COMMA

    getTeamColor = function(player)
        return player and player.Team and player.Team.TeamColor and player.Team.TeamColor.Color
	end, -- COMMA

    getCharacter = function(player)
        return player and player.Character
    end, -- COMMA

    getHealth = function(player)
        local character = player and EspInterface.getCharacter(player)
        local humanoid = character and findFirstChildOfClass(character, "Humanoid")
        if humanoid then
            return humanoid.Health, humanoid.MaxHealth
        end
        return 100, 100
    end, -- COMMA

	-- ===== Deep Table Copy Function =====
	_DeepCopy = function(original)
		local copy = {}
		for k, v in pairs(original) do
			if type(v) == "table" then
				copy[k] = EspInterface._DeepCopy(v)
			else
				copy[k] = v
			end
		end
		return copy
	end, -- COMMA

	-- ===== Deep Table Merge Function =====
	_DeepMerge = function(destination, source)
		for k, v in pairs(source) do
			if type(v) == "table" and type(destination[k]) == "table" then
				EspInterface._DeepMerge(destination[k], v)
			else
				destination[k] = v
			end
		end
		return destination
	end, -- COMMA

    -- ===== Internal Methods =====
    _CreatePlayerObjects = function(player)
		if not player or player == LocalPlayer then return end
        if EspInterface._ObjectCache[player] then return end

		local espObj, chamObj
		local successEsp = pcall(function() espObj = EspObject.new(player, EspInterface) end)
		local successCham = pcall(function() chamObj = ChamObject.new(player, EspInterface) end)

		if successEsp and successCham and espObj and chamObj then
        	EspInterface._ObjectCache[player] = { espObj, chamObj }
		else
			warn("Failed to create ESP objects for:", player.Name)
			if espObj then pcall(espObj.Destruct, espObj) end
			if chamObj then pcall(chamObj.Destruct, chamObj) end
		end
    end, -- COMMA

    _RemovePlayerObjects = function(player)
        local objects = EspInterface._ObjectCache[player]
        if objects then
            for _, obj in ipairs(objects) do
                pcall(obj.Destruct, obj)
            end
            EspInterface._ObjectCache[player] = nil
        end
    end, -- COMMA

	_SetupInstanceCleanup = function(instance, objRef)
		if EspInterface._InstanceCleanupConnections[instance] then
			EspInterface._InstanceCleanupConnections[instance]:Disconnect()
		end
		EspInterface._InstanceCleanupConnections[instance] = instance.AncestryChanged:Connect(function(_, parent)
			if not parent then
				if EspInterface._InstanceCleanupConnections[instance] then
					EspInterface._InstanceCleanupConnections[instance]:Disconnect()
					EspInterface._InstanceCleanupConnections[instance] = nil
				end
				if EspInterface._ObjectCache[instance] then
					pcall(objRef.Destruct, objRef)
					EspInterface._ObjectCache[instance] = nil
				end
			end
		end)
	end, -- COMMA

    -- ===== Public API =====
    Load = function()
        if EspInterface._IsLoaded then warn("ESP Library already loaded.") return end
        print("Loading Advanced ESP Library...")

        if not EspInterface.teamSettings.Friendly then EspInterface.teamSettings.Friendly = {} end
		local enemySettingsCopy = EspInterface._DeepCopy(EspInterface.teamSettings.Enemy)
		EspInterface.teamSettings.Friendly = EspInterface._DeepMerge(enemySettingsCopy, EspInterface.teamSettings.Friendly)

		EspInterface.Unload(true)

        for _, player in ipairs(Players:GetPlayers()) do
            EspInterface._CreatePlayerObjects(player)
        end

        EspInterface._PlayerConnections.Added = Players.PlayerAdded:Connect(EspInterface._CreatePlayerObjects)
        EspInterface._PlayerConnections.Removing = Players.PlayerRemoving:Connect(EspInterface._RemovePlayerObjects)

        EspInterface._IsLoaded = true
        print("ESP Library Loaded Successfully.")
    end, -- COMMA

    Unload = function(silent)
        if not EspInterface._IsLoaded and not silent then warn("ESP Library not loaded.") return end
        if not silent then print("Unloading Advanced ESP Library...") end

        if EspInterface._PlayerConnections.Added then EspInterface._PlayerConnections.Added:Disconnect() EspInterface._PlayerConnections.Added = nil end
        if EspInterface._PlayerConnections.Removing then EspInterface._PlayerConnections.Removing:Disconnect() EspInterface._PlayerConnections.Removing = nil end

		for instance, conn in pairs(EspInterface._InstanceCleanupConnections) do
			pcall(conn.Disconnect, conn)
		end
		clear(EspInterface._InstanceCleanupConnections)

        for key, objOrTable in pairs(EspInterface._ObjectCache) do
            if type(objOrTable) == "table" then
                for _, obj in ipairs(objOrTable) do
                    pcall(obj.Destruct, obj)
                end
            else
                pcall(objOrTable.Destruct, objOrTable)
            end
        end
        clear(EspInterface._ObjectCache)

        EspInterface._IsLoaded = false
        if not silent then print("ESP Library Unloaded.") end
    end, -- COMMA

    AddInstance = function(instance, options)
        if not EspInterface._IsLoaded then warn("Cannot add instance ESP, library not loaded.") return end
        if not instance or typeof(instance) ~= "Instance" then warn("AddInstance: Invalid instance provided.") return end
        if EspInterface._ObjectCache[instance] then warn("AddInstance: ESP already exists for this instance.") return EspInterface._ObjectCache[instance] end

		local instanceEsp
		local success = pcall(function() instanceEsp = InstanceObject.new(instance, options or {}, EspInterface) end)
        if success and instanceEsp then
			EspInterface._ObjectCache[instance] = instanceEsp
			EspInterface._SetupInstanceCleanup(instance, instanceEsp)
        	return instanceEsp
		else
			warn("Failed to create Instance ESP for:", instance)
			return nil
		end
    end, -- COMMA

    RemoveInstance = function(instance)
        if not instance then return end
        local obj = EspInterface._ObjectCache[instance]
        if obj then
			if EspInterface._InstanceCleanupConnections[instance] then
				EspInterface._InstanceCleanupConnections[instance]:Disconnect()
				EspInterface._InstanceCleanupConnections[instance] = nil
			end
            pcall(obj.Destruct, obj)
            EspInterface._ObjectCache[instance] = nil
			return true
        end
		return false
    end, -- COMMA

    UpdateSetting = function(category, settingName, value)
		local targetTable
        if category == "sharedSettings" then
            targetTable = EspInterface.sharedSettings
		elseif EspInterface.teamSettings[category] then
			targetTable = EspInterface.teamSettings[category]
		else
            warn("Invalid setting category:", category)
			return
        end

		if targetTable then
			if type(targetTable[settingName]) == "table" and type(value) == "table" then
				EspInterface._DeepMerge(targetTable[settingName], value)
			else
				targetTable[settingName] = value
			end
		end
    end, -- COMMA

	UpdateInstanceOptions = function(instance, newOptions)
		local obj = EspInterface._ObjectCache[instance]
		if obj and obj.UpdateOptions then
			obj:UpdateOptions(newOptions)
		else
			warn("UpdateInstanceOptions: No ESP found for instance or object doesn't support updates:", instance)
		end
	end, -- COMMA

	Toggle = function(enabled)
		EspInterface.UpdateSetting("Enemy", "Enabled", enabled)
		EspInterface.UpdateSetting("Friendly", "Enabled", enabled)
	end -- NO COMMA (Last element)
} -- END EspInterface Table }1


return EspInterface
