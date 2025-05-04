--[[
	Advanced ESP Library v2.0

	Features:
	- Player ESP (Boxes [2D, Corner, 3D], Skeleton, Health, Name, Distance, Weapon, Head Dot, Look Vector, Tracers, Off-Screen Arrows)
	- Player Chams (Fill, Outline, Material, Visible Only)
	- World ESP (Basic Instance ESP with filtering)
	- Customizable Settings per team (Enemy/Friendly) and shared settings.
	- Abstracted Game Interface (Requires user implementation for game-specific logic)
	- Performance optimizations (caching, selective updates)
	- Modular design

	Requires a Drawing library (global `Drawing` object assumed).
	Designed for exploit environments.
]]

-- // Services \\ --
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")

-- // Roblox Globals (Cache) \\ --
local CAMERA = Workspace.CurrentCamera
local LOCAL_PLAYER = Players.LocalPlayer
local GUI_CONTAINER = gethui and gethui() or Instance.new("Folder", CoreGui) -- Container for Drawings/Highlights

-- // Lua Globals (Cache) \\ --
local T_INSERT = table.insert
local T_REMOVE = table.remove
local T_FIND = table.find
local T_CLEAR = table.clear
local T_CREATE = table.create
local T_PACK = table.pack
local T_UNPACK = table.unpack -- Use select for safety if needed

local M_FLOOR = math.floor
local M_ROUND = math.round
local M_SIN = math.sin
local M_COS = math.cos
local M_ATAN2 = math.atan2
local M_PI = math.pi
local M_RAD = math.rad
local M_DEG = math.deg

local V2_NEW = Vector2.new
local V3_NEW = Vector3.new
local CF_NEW = CFrame.new
local COL3_NEW = Color3.new
local INST_NEW = Instance.new

-- Forward Declarations
local EspLib, Settings, Utils, PlayerEspController, WorldEspController, BaseEspObject, PlayerEspRenderer, PlayerChamsRenderer, WorldInstanceRenderer

-- // ======================== \\ --
-- //         Utilities        \\ --
-- // ======================== \\ --
Utils = {}

function Utils.WorldToScreen(worldPos)
	-- Uses the current camera implicitly
	local screenPos, onScreen = CAMERA:WorldToViewportPoint(worldPos)
	local depth = screenPos.Z -- Keep the depth information
	return V2_NEW(screenPos.X, screenPos.Y), onScreen, depth
end

function Utils.GetBoundingBox(parts)
	if not parts or #parts == 0 then
		return nil, nil
	end

	local min, max
	local firstPos = parts[1].Position

	min = V3_NEW(firstPos.X, firstPos.Y, firstPos.Z)
	max = V3_NEW(firstPos.X, firstPos.Y, firstPos.Z)

	for i = 1, #parts do
		local part = parts[i]
		if typeof(part) == "Instance" and part:IsA("BasePart") then
			local cf = part.CFrame
			local sizeHalf = part.Size * 0.5
			local p1 = cf * sizeHalf
			local p2 = cf * -sizeHalf
			local p3 = cf * V3_NEW(sizeHalf.X, -sizeHalf.Y, sizeHalf.Z)
			local p4 = cf * V3_NEW(sizeHalf.X, sizeHalf.Y, -sizeHalf.Z)
			local p5 = cf * V3_NEW(-sizeHalf.X, sizeHalf.Y, sizeHalf.Z)
			local p6 = cf * V3_NEW(-sizeHalf.X, -sizeHalf.Y, -sizeHalf.Z)
			local p7 = cf * V3_NEW(sizeHalf.X, -sizeHalf.Y, -sizeHalf.Z)
			local p8 = cf * V3_NEW(-sizeHalf.X, sizeHalf.Y, -sizeHalf.Z)


			min = min:Min(p1):Min(p2):Min(p3):Min(p4):Min(p5):Min(p6):Min(p7):Min(p8)
            max = max:Max(p1):Max(p2):Max(p3):Max(p4):Max(p5):Max(p6):Max(p7):Max(p8)

            -- More optimized BBox (Axis Aligned relative to world)
            -- local pos = part.Position
            -- local sizeHalf = part.Size * 0.5
            -- min = min:Min(pos - sizeHalf)
            -- max = max:Max(pos + sizeHalf)
		else
			-- warn("[ESP Utils] GetBoundingBox received non-BasePart:", part)
		end
	end

    if not min or not max then return nil, nil end -- Handle cases where no valid parts were found

	local center = (min + max) * 0.5
	local size = max - min
	-- Calculate a reasonable 'LookVector' for the CFrame, pointing towards positive Z of the box
	local front = center + V3_NEW(0, 0, size.Z * 0.5)
	local cframe = CF_NEW(center, front)

	return cframe, size
end

-- vertices for a standard unit cube
local BBOX_VERTICES = {
	V3_NEW(-0.5, -0.5, -0.5), V3_NEW(-0.5, 0.5, -0.5),
	V3_NEW(0.5, 0.5, -0.5), V3_NEW(0.5, -0.5, -0.5),
	V3_NEW(-0.5, -0.5, 0.5), V3_NEW(-0.5, 0.5, 0.5),
	V3_NEW(0.5, 0.5, 0.5), V3_NEW(0.5, -0.5, 0.5)
}

function Utils.GetScreenCorners(cframe, size)
	local corners2D = {}
	local minX, minY = math.huge, math.huge
	local maxX, maxY = -math.huge, -math.huge
	local anyOnScreen = false
    local allCornersOnScreen = true
	local worldCorners = {}

	for i = 1, #BBOX_VERTICES do
		local worldPos = cframe * (BBOX_VERTICES[i] * size)
		local screenPos, onScreen = Utils.WorldToScreen(worldPos)

		T_INSERT(corners2D, screenPos)
		T_INSERT(worldCorners, worldPos) -- Store world positions too for 3D box

		if onScreen then
			anyOnScreen = true
			minX = math.min(minX, screenPos.X)
			minY = math.min(minY, screenPos.Y)
			maxX = math.max(maxX, screenPos.X)
			maxY = math.max(maxY, screenPos.Y)
        else
            allCornersOnScreen = false
		end
	end

    -- If no corners are on screen, try projecting the center
    local centerScreenPos, centerOnScreen = Utils.WorldToScreen(cframe.Position)
    if not anyOnScreen and centerOnScreen then
        -- Fallback: use center position if no corners visible but center is. Size estimation is tricky here.
        -- Let's just indicate it's visible but provide minimal bounds.
         minX, minY = centerScreenPos.X, centerScreenPos.Y
         maxX, maxY = centerScreenPos.X, centerScreenPos.Y
         anyOnScreen = true
    elseif not anyOnScreen then
        return nil -- Completely off-screen
    end

    -- Clamp bounds to viewport if partially off-screen
    local vpSize = CAMERA.ViewportSize
    minX = math.max(0, math.min(vpSize.X, minX))
    minY = math.max(0, math.min(vpSize.Y, minY))
    maxX = math.max(0, math.min(vpSize.X, maxX))
    maxY = math.max(0, math.min(vpSize.Y, maxY))


	return {
		AnyOnScreen = anyOnScreen,
        AllOnScreen = allCornersOnScreen, -- Useful for deciding between 2D/3D box rendering modes
		Screen = corners2D, -- Raw 2D screen positions of corners
		World = worldCorners, -- Raw 3D world positions of corners
		TopLeft = V2_NEW(M_FLOOR(minX), M_FLOOR(minY)),
		BottomRight = V2_NEW(M_FLOOR(maxX), M_FLOOR(maxY)),
		Size = V2_NEW(M_FLOOR(maxX - minX), M_FLOOR(maxY - minY))
	}
end


function Utils.RotateVector2D(vector, angleRad)
	local x, y = vector.X, vector.Y
	local c, s = M_COS(angleRad), M_SIN(angleRad)
	return V2_NEW(x * c - y * s, x * s + y * c)
end

function Utils.GetColor(context, colorSetting, isOutline)
	-- context should be the 'self' of the calling object (e.g., PlayerEspRenderer)
	local player = context and context.Player
	local useTeamColor = Settings:Get("shared.useTeamColor") and not isOutline

	if player and (colorSetting == "Team" or useTeamColor) then
		local teamColor = EspLib.GameInterface.GetTeamColor(player)
		return teamColor or Settings:Get("defaults.fallbackColor")
	elseif typeof(colorSetting) == "Color3" then
		return colorSetting
	elseif typeof(colorSetting) == "string" and colorSetting == "Rainbow" then
         return Color3.fromHSV(tick() % 5 / 5, 1, 1)
    elseif typeof(colorSetting) == "string" and Settings:Get("colors." .. colorSetting) then
        return Settings:Get("colors." .. colorSetting) -- Allow named colors
	else
		-- warn("[ESP Utils] Invalid color setting:", colorSetting)
		return Settings:Get("defaults.fallbackColor")
	end
end

function Utils.GetTransparency(transparencySetting)
    if typeof(transparencySetting) == "number" then
        return transparencySetting
    end
    -- Could add dynamic transparency based on distance, health, etc. later
    return 0 -- Default to opaque if invalid
end

function Utils.LerpColor(c1, c2, alpha)
	return c1:Lerp(c2, math.clamp(alpha, 0, 1))
end

function Utils.ClampVector2(vec, minV, maxV)
    return V2_NEW(
        math.clamp(vec.X, minV.X, maxV.X),
        math.clamp(vec.Y, minV.Y, maxV.Y)
    )
end

function Utils.IsAlive(player)
    local health, maxHealth = EspLib.GameInterface.GetHealth(player)
    return health > 0
end


-- // ======================== \\ --
-- //      Settings Manager    \\ --
-- // ======================== \\ --
Settings = {}
local _settings = {} -- Internal storage

local DEFAULTS = {
	enabled = true,
	refreshRate = 0, -- Updates per second (0 = RunService default, e.g., 60)
    renderDistance = 2000,
    checkLineOfSight = false, -- More performant than per-object raycasts if needed globally
    lineOfSightOrigin = "Camera", -- "Camera" or "LocalPlayerHead"

    defaults = {
        fallbackColor = COL3_NEW(1, 1, 1),
        outlineColor = COL3_NEW(0, 0, 0),
        fontSize = 13,
        font = Enum.Font.SourceSans,
        thickness = 1,
        outlineThickness = 3,
    },

    colors = { -- Named colors for easier config
        Red = COL3_NEW(1,0,0),
        Green = COL3_NEW(0,1,0),
        Blue = COL3_NEW(0,0,1),
        White = COL3_NEW(1,1,1),
        Black = COL3_NEW(0,0,0),
        Yellow = COL3_NEW(1,1,0),
        Orange = COL3_NEW(1, 0.5, 0),
        Purple = COL3_NEW(0.5, 0, 1),
        Pink = COL3_NEW(1, 0.5, 1),
        Cyan = COL3_NEW(0, 1, 1),
    },

	shared = {
		useTeamColor = false, -- Overrides individual color settings if true (except outlines)
		limitDistance = true, -- Uses 'renderDistance' above
		maxDistance = 500, -- Kept for compatibility, prefer 'renderDistance'
		textSize = 13,
		textFont = Enum.Font.SourceSans,
	},

	player = {
		enabled = true,
        enableForLocalPlayer = false,
		whitelist = {}, -- List of UserIds to ONLY show ESP for (if populated)
		blacklist = {}, -- List of UserIds to HIDE ESP for

		enemy = {
			enabled = true,
            box = {
                enabled = true,
                mode = "2D", -- "2D", "Corner", "3D"
                color = "Red",
                transparency = 0,
                thickness = 1,
                outline = true,
                outlineColor = "Black",
                outlineTransparency = 0,
                outlineThickness = 3,
                cornerSize = 0.15, -- Percentage of box size for corner boxes
                fill = false,
                fillColor = "Red",
                fillTransparency = 0.7,
            },
            skeleton = {
                enabled = false,
                color = "White",
                transparency = 0,
                thickness = 1,
                outline = false,
                outlineColor = "Black",
                outlineTransparency = 0,
                outlineThickness = 2,
            },
            healthBar = {
                enabled = true,
                colorMode = "Gradient", -- "Gradient", "Static", "Team"
                healthyColor = "Green",
                dyingColor = "Red",
                staticColor = "Green",
                transparency = 0,
                thickness = 3,
                position = "Left", -- "Left", "Right", "Top", "Bottom"
                outline = true,
                outlineColor = "Black",
                outlineTransparency = 0,
                outlineThickness = 1, -- Additive to bar thickness for outline effect
            },
            healthText = {
                enabled = false,
                color = "White",
                transparency = 0,
                size = 12,
                font = Enum.Font.SourceSans,
                outline = true,
                outlineColor = "Black",
                format = "{hp}/{maxhp}", -- Available: {hp} {maxhp} {percent}
                position = "HealthBar", -- "HealthBar", "Top", "Bottom"
            },
            name = {
                enabled = true,
                color = "White",
                transparency = 0,
                size = 13,
                font = Enum.Font.SourceSans,
                outline = true,
                outlineColor = "Black",
                position = "Top", -- "Top", "Bottom"
            },
            distance = {
                enabled = true,
                color = "White",
                transparency = 0,
                size = 12,
                font = Enum.Font.SourceSans,
                outline = true,
                outlineColor = "Black",
                format = "{dist}m", -- Available: {dist}
                position = "Bottom", -- "Top", "Bottom" (relative to name/weapon)
            },
            weapon = {
                enabled = false,
                color = "White",
                transparency = 0,
                size = 12,
                font = Enum.Font.SourceSans,
                outline = true,
                outlineColor = "Black",
                position = "Bottom", -- "Top", "Bottom" (relative to name/distance)
            },
            headDot = {
                enabled = false,
                color = "Red",
                transparency = 0,
                size = 5,
                filled = true,
                outline = true,
                outlineColor = "Black",
                outlineTransparency = 0,
                outlineThickness = 1,
            },
            lookVector = {
                enabled = false,
                color = "Blue",
                transparency = 0,
                thickness = 1,
                length = 50, -- Length in studs
            },
            tracer = {
                enabled = false,
                color = "Red",
                transparency = 0,
                thickness = 1,
                origin = "Bottom", -- "Bottom", "Top", "Middle"
                outline = true,
                outlineColor = "Black",
                outlineTransparency = 0,
                outlineThickness = 3,
            },
            offScreenArrow = {
                enabled = true,
                color = "Red",
                transparency = 0,
                size = 15,
                radius = 150,
                filled = true,
                outline = true,
                outlineColor = "Black",
                outlineTransparency = 0,
                outlineThickness = 3,
            },
            chams = {
                enabled = false,
                visibleOnly = false, -- If true, only shows when player is visible (DepthMode = Occluded)
                fill = {
                    enabled = true,
                    color = "Red",
                    transparency = 0.6,
                },
                outline = {
                    enabled = false,
                    color = "White",
                    transparency = 0,
                },
                material = { -- Optional: Apply a material effect
                    enabled = false,
                    material = Enum.Material.ForceField, -- e.g., ForceField, Neon, Glass
                    color = "White", -- Material color often overrides Fill/Outline
                    transparency = 0.5,
                }
            }
		},

		friendly = { -- Defaults copy from enemy, then adjust specifics
            enabled = true,
            box = { color = "Green", fillColor = "Green" },
            skeleton = { enabled = false },
            healthBar = { enabled = false, healthyColor = "Green", dyingColor = "Yellow", staticColor = "Green" },
            healthText = { enabled = false },
            name = { enabled = true },
            distance = { enabled = false },
            weapon = { enabled = false },
            headDot = { enabled = false, color = "Green" },
            lookVector = { enabled = false },
            tracer = { enabled = false, color = "Green" },
            offScreenArrow = { enabled = false, color = "Green" },
            chams = {
                enabled = false,
                visibleOnly = true,
                fill = { color = "Green", transparency = 0.8 },
                outline = { enabled = false },
                material = { enabled = false }
            }
		},
	},

    world = {
        enabled = true,
        instances = { -- Define rules for specific instances
            -- Example: Show ESP for tools named "Gun"
            --[[
            {
                filter = function(instance) return instance:IsA("Tool") and instance.Name == "Gun" end,
                enabled = true,
                text = "{name} [{distance}m]",
                textColor = "Yellow",
                textSize = 12,
                textOutline = true,
                limitDistance = true,
                maxDistance = 100,
                -- Future: Add box, etc. for world items
            },
            -- Example: Show ESP for parts named "Objective"
            {
                filter = function(instance) return instance:IsA("BasePart") and instance.Name == "Objective" end,
                enabled = true,
                text = "Objective",
                textColor = "Cyan",
                limitDistance = false, -- Show regardless of distance
            }
            ]]
        }
    }
}

-- Deep merge utility for settings
local function mergeTables(target, source)
	for k, v in pairs(source) do
		if type(v) == "table" and type(target[k]) == "table" then
			mergeTables(target[k], v)
		else
			target[k] = v
		end
	end
	return target
end

function Settings:Initialize()
	-- Start with deep copy of defaults
	_settings = {}
    mergeTables(_settings, DEFAULTS)

    -- Ensure friendly settings inherit from enemy structure initially, then apply specific friendly defaults
    local enemyDefaults = {}
    mergeTables(enemyDefaults, DEFAULTS.player.enemy)
    mergeTables(_settings.player.friendly, enemyDefaults) -- Base friendly on enemy structure
    mergeTables(_settings.player.friendly, DEFAULTS.player.friendly) -- Apply specific friendly overrides
end

function Settings:Get(path, defaultValue)
	local keys = string.split(path, ".")
	local current = _settings
	for _, key in ipairs(keys) do
		if type(current) == "table" and current[key] ~= nil then
			current = current[key]
		else
			-- warn("[ESP Settings] Setting not found:", path)
			return defaultValue
		end
	end
	return current
end

function Settings:Set(path, value)
    local keys = string.split(path, ".")
    local current = _settings
    for i = 1, #keys - 1 do
        local key = keys[i]
        if type(current[key]) ~= "table" then
            current[key] = {} -- Create intermediate tables if they don't exist
        end
        current = current[key]
    end
    current[keys[#keys]] = value
    -- Potentially trigger an update event here if needed
end

function Settings:GetPlayerSettings(player)
    if not player or not player:IsA("Player") then return nil end
    local isFriendly = EspLib.GameInterface.IsFriendly(player)
    local teamType = isFriendly and "friendly" or "enemy"
    return self:Get("player." .. teamType)
end

-- // ======================== \\ --
-- //    Base ESP Object (Abstract) \\ --
-- // ======================== \\ --
BaseEspObject = {}
BaseEspObject.__index = BaseEspObject

function BaseEspObject:new()
	local self = setmetatable({}, BaseEspObject)
	self._drawings = {} -- Store drawing objects managed by this instance
    self._connections = {} -- Store RBXScriptConnections
	self._lastUpdateTime = 0
	return self
end

-- Must be implemented by subclasses
function BaseEspObject:Update(deltaTime) error("Update method must be implemented by subclass") end
function BaseEspObject:Render(deltaTime) error("Render method must be implemented by subclass") end

function BaseEspObject:_createDrawing(className, properties)
	local drawing = Drawing.new(className)
	for prop, value in pairs(properties or {}) do
		pcall(function() drawing[prop] = value end)
	end
	T_INSERT(self._drawings, drawing)
	return drawing
end

function BaseEspObject:_setVisible(visible)
    -- Optimization: Set visibility on all owned drawings
    for _, drawing in ipairs(self._drawings) do
        if drawing.Visible ~= visible then
            drawing.Visible = visible
        end
    end
end

function BaseEspObject:_connect(event, func)
    local conn = event:Connect(func)
    T_INSERT(self._connections, conn)
    return conn
end

function BaseEspObject:Destroy()
    -- Disconnect all signals
    for _, conn in ipairs(self._connections) do
        conn:Disconnect()
    end
    T_CLEAR(self._connections)

    -- Remove all drawing objects
    for _, drawing in ipairs(self._drawings) do
        drawing:Remove()
    end
    T_CLEAR(self._drawings)

	-- Clear the object itself
	T_CLEAR(self)
	setmetatable(self, nil) -- Allow garbage collection
end


-- // ======================== \\ --
-- //  Player ESP Renderer     \\ --
-- // ======================== \\ --
PlayerEspRenderer = {}
PlayerEspRenderer.__index = PlayerEspRenderer
setmetatable(PlayerEspRenderer, { __index = BaseEspObject }) -- Inheritance

-- Constants for offsets etc.
local HEALTH_BAR_PADDING = V2_NEW(5, 0)
local HEALTH_TEXT_OFFSET = V2_NEW(3, -2)
local NAME_OFFSET = V2_NEW(0, 3)
local DISTANCE_OFFSET = V2_NEW(0, 2)
local WEAPON_OFFSET = V2_NEW(0, 2)
local SKELETON_THICKNESS_MOD = 0.5 -- Make outline slightly thinner

-- Skeleton joint map (adjust based on common rig types - R6/R15)
local R15_SKELETON_JOINTS = {
    {"Head", "UpperTorso"},
    {"UpperTorso", "LowerTorso"},
    {"UpperTorso", "LeftUpperArm"}, {"LeftUpperArm", "LeftLowerArm"}, {"LeftLowerArm", "LeftHand"},
    {"UpperTorso", "RightUpperArm"}, {"RightUpperArm", "RightLowerArm"}, {"RightLowerArm", "RightHand"},
    {"LowerTorso", "LeftUpperLeg"}, {"LeftUpperLeg", "LeftLowerLeg"}, {"LeftLowerLeg", "LeftFoot"},
    {"LowerTorso", "RightUpperLeg"}, {"RightUpperLeg", "RightLowerLeg"}, {"RightLowerLeg", "RightFoot"},
}
local R6_SKELETON_JOINTS = {
    {"Head", "Torso"},
    {"Torso", "Left Arm"}, {"Left Arm", "Left Leg"}, -- R6 structure is different
    {"Torso", "Right Arm"}, {"Right Arm", "Right Leg"},
    {"Torso", "Left Leg"}, {"Torso", "Right Leg"}, -- Connect torso to legs directly
}


function PlayerEspRenderer:new(player)
	local self = setmetatable(BaseEspObject:new(), PlayerEspRenderer) -- Call base constructor
	self.Player = assert(player, "PlayerEspRenderer requires a Player")
	self._lastCharUpdateTime = 0
    self._charPartCache = {}
    self._charJointCache = {} -- For skeleton
    self._isR15 = false -- Detect rig type

    self:InitializeDrawings()
	return self
end

function PlayerEspRenderer:InitializeDrawings()
    -- Box Related
    self.BoxFill = self:_createDrawing("Square", { Filled = true, Visible = false })
    self.BoxOutline = self:_createDrawing("Square", { Filled = false, Visible = false })
    self.BoxLines = {} -- For 3D Box (12 lines)
    for _ = 1, 12 do T_INSERT(self.BoxLines, self:_createDrawing("Line", { Visible = false })) end

    -- Skeleton Related
    self.SkeletonLines = {} -- Store { line, outline } pairs
    -- Determine max needed based on R15 (more joints)
    for _ = 1, #R15_SKELETON_JOINTS do
        T_INSERT(self.SkeletonLines, {
            line = self:_createDrawing("Line", { Visible = false }),
            outline = self:_createDrawing("Line", { Visible = false })
        })
    end

    -- Health Bar Related
    self.HealthBar = self:_createDrawing("Line", { Visible = false })
    self.HealthBarOutline = self:_createDrawing("Line", { Visible = false })
    self.HealthText = self:_createDrawing("Text", { Center = false, Visible = false }) -- Use specific alignment later

    -- Info Texts
    self.NameText = self:_createDrawing("Text", { Center = true, Visible = false })
    self.DistanceText = self:_createDrawing("Text", { Center = true, Visible = false })
    self.WeaponText = self:_createDrawing("Text", { Center = true, Visible = false })

    -- Other Indicators
    self.HeadDot = self:_createDrawing("Circle", { Filled = true, Visible = false })
    self.HeadDotOutline = self:_createDrawing("Circle", { Filled = false, Visible = false })
    self.LookVectorLine = self:_createDrawing("Line", { Visible = false })
    self.TracerLine = self:_createDrawing("Line", { Visible = false })
    self.TracerOutline = self:_createDrawing("Line", { Visible = false })
    self.OffScreenArrow = self:_createDrawing("Triangle", { Filled = true, Visible = false })
    self.OffScreenArrowOutline = self:_createDrawing("Triangle", { Filled = false, Visible = false })

    -- Set ZIndex defaults (higher numbers draw on top)
    local z = 1
    self.BoxFill.ZIndex = z; z+=1
    for _, line in ipairs(self.BoxLines) do line.ZIndex = z end; z+=1
    self.BoxOutline.ZIndex = z; z+=1 -- Draw 2D outline over 3D box lines if both enabled

    for _, pair in ipairs(self.SkeletonLines) do pair.outline.ZIndex = z end; z+=1
    for _, pair in ipairs(self.SkeletonLines) do pair.line.ZIndex = z end; z+=1

    self.HealthBarOutline.ZIndex = z; z+=1
    self.HealthBar.ZIndex = z; z+=1
    self.HealthText.ZIndex = z; z+=1

    self.LookVectorLine.ZIndex = z; z+=1
    self.HeadDotOutline.ZIndex = z; z+=1
    self.HeadDot.ZIndex = z; z+=1

    self.WeaponText.ZIndex = z; z+=1
    self.DistanceText.ZIndex = z; z+=1
    self.NameText.ZIndex = z; z+=1

    self.TracerOutline.ZIndex = z; z+=1
    self.TracerLine.ZIndex = z; z+=1

    self.OffScreenArrowOutline.ZIndex = z; z+=1
    self.OffScreenArrow.ZIndex = z; z+=1
end


function PlayerEspRenderer:_updateCharacterCache(character)
    if not character or not character.Parent then
        T_CLEAR(self._charPartCache)
        T_CLEAR(self._charJointCache)
        self._isR15 = false
        return false
    end

    -- Basic caching: Only update if character instance changes or parts significantly change
    -- More advanced: Could check hierarchy checksum or bounding box stability
    if self._lastCharacter == character and tick() - self._lastCharUpdateTime < 0.5 then -- Update cache every 0.5s max
         return true -- Assume cache is valid
    end

    T_CLEAR(self._charPartCache)
    T_CLEAR(self._charJointCache)
    self._isR15 = false

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return false end -- No humanoid, likely not a standard character

    self._isR15 = (humanoid.RigType == Enum.HumanoidRigType.R15)
    local joints = self._isR15 and R15_SKELETON_JOINTS or R6_SKELETON_JOINTS

    local function findPart(name)
        -- Prioritize FindFirstChild for direct names, fallback to recursive search if needed
        local part = character:FindFirstChild(name, false) -- Non-recursive first
        -- if not part then part = character:FindFirstChild(name, true) end -- Recursive fallback (can be slow)
        return part and part:IsA("BasePart") and part or nil
    end

    for _, part in ipairs(character:GetChildren()) do
        if part:IsA("BasePart") then
            T_INSERT(self._charPartCache, part)
        end
    end

    for _, jointPair in ipairs(joints) do
        local part1 = findPart(jointPair[1])
        local part2 = findPart(jointPair[2])
        if part1 and part2 then
             T_INSERT(self._charJointCache, { Part1 = part1, Part2 = part2 })
        end
    end

    self._lastCharacter = character
    self._lastCharUpdateTime = tick()
    return #self._charPartCache > 0 -- Success if we found parts
end

function PlayerEspRenderer:Update(deltaTime)
	local player = self.Player
	if not player or not player.Parent then return self:Destroy() end -- Player left

    local settings = Settings:GetPlayerSettings(player)
    if not settings or not settings.enabled then
        self.IsVisible = false
        return
    end

    -- Whitelist/Blacklist Check
    local whitelist = Settings:Get("player.whitelist")
    local blacklist = Settings:Get("player.blacklist")
    if (#whitelist > 0 and not T_FIND(whitelist, player.UserId)) or T_FIND(blacklist, player.UserId) then
        self.IsVisible = false
        return
    end

    -- Local Player Check
    if player == LOCAL_PLAYER and not Settings:Get("player.enableForLocalPlayer") then
        self.IsVisible = false
        return
    end

	local character = EspLib.GameInterface.GetCharacter(player)
    local hasCharacter = self:_updateCharacterCache(character)

	if not hasCharacter or not Utils.IsAlive(player) then
		self.IsVisible = false
        self.IsOnScreen = false
		return
	end

	self.Character = character -- Store for Render
    self.Settings = settings -- Store resolved settings for Render

    -- Calculate Bounding Box & Screen Projection (only if needed by enabled features)
    local needsBounds = settings.box.enabled or settings.name.enabled or settings.distance.enabled or
                        settings.weapon.enabled or settings.healthBar.enabled or settings.healthText.enabled or
                        settings.tracer.enabled or settings.headDot.enabled or settings.lookVector.enabled

    local head = self._charPartCache and T_FIND(self._charPartCache, "Head") or character:FindFirstChild("Head") -- Find head specifically
    local primaryPart = character.PrimaryPart or head or self._charPartCache[1]

    if not primaryPart then
        self.IsVisible = false
        self.IsOnScreen = false
        return -- Cannot proceed without a reference point
    end

    local primaryPos = primaryPart.Position
    local screenPos, onScreen, depth = Utils.WorldToScreen(primaryPos)

    self.Depth = depth
    self.IsVisible = true -- Assume visible for now, may be turned off by distance/LOS checks
    self.IsOnScreen = onScreen

    -- Distance Check
    if Settings:Get("shared.limitDistance") and depth > Settings:Get("renderDistance") then
        self.IsVisible = false
        self.IsOnScreen = false -- Treat as offscreen if too far
    end

    -- Line of Sight Check (Optional - can be expensive)
    if self.IsVisible and Settings:Get("checkLineOfSight") then
        local losOriginPoint
        if Settings:Get("lineOfSightOrigin") == "LocalPlayerHead" and LOCAL_PLAYER.Character and LOCAL_PLAYER.Character:FindFirstChild("Head") then
            losOriginPoint = LOCAL_PLAYER.Character.Head.Position
        else
            losOriginPoint = CAMERA.CFrame.Position
        end
        local ray = Ray.new(losOriginPoint, (primaryPos - losOriginPoint).Unit * depth)
        local hitPart = Workspace:FindPartOnRayWithIgnoreList(ray, { LOCAL_PLAYER.Character, character }, true, true) -- TerrainCellsAreCubes, IgnoreWater
        self.HasLineOfSight = (hitPart == nil) -- Visible if ray doesn't hit anything before target
        -- Could potentially use this LOS check to influence rendering (e.g., different color/transparency)
        -- For now, just store it. Chams uses DepthMode for visibility.
    else
        self.HasLineOfSight = true -- Assume visible if check disabled
    end


    if self.IsVisible and self.IsOnScreen and needsBounds then
        self.BoundsCFrame, self.BoundsSize = Utils.GetBoundingBox(self._charPartCache)
        if self.BoundsCFrame then
            self.Corners = Utils.GetScreenCorners(self.BoundsCFrame, self.BoundsSize)
            if not self.Corners then -- If GetScreenCorners returns nil (completely off-screen despite primary part check)
                self.IsOnScreen = false
            end
        else
             -- Fallback if bounding box calculation fails but primary part is visible
            self.IsOnScreen = false -- Can't draw bounds if calculation failed
        end
    elseif self.IsVisible and not self.IsOnScreen and settings.offScreenArrow.enabled then
        -- Calculate direction for Off-Screen Arrow
        local camCF = CAMERA.CFrame
		local flatCam = CF_NEW(camCF.Position * V3_NEW(1,0,1), (camCF.Position + camCF.LookVector) * V3_NEW(1,0,1)) -- Flatten camera CFrame on XZ plane
        local targetPosFlat = primaryPos * V3_NEW(1,0,1)
		local objSpace = flatCam:PointToObjectSpace(targetPosFlat)
		self.OffScreenDirection = V2_NEW(objSpace.X, objSpace.Z).Unit
    end

    -- Cache other frequently needed info
    self.Health, self.MaxHealth = EspLib.GameInterface.GetHealth(player)
    self.WeaponName = EspLib.GameInterface.GetWeapon(player)
    self.HeadPosition = head and head.Position -- Cache for head dot / look vector
    self.LookVector = primaryPart.CFrame.LookVector -- Cache for look vector line
end

function PlayerEspRenderer:Render(deltaTime)
    if not self.IsVisible then
        self:_setVisible(false) -- Hide all drawings if player ESP is disabled/culled
        return
    end

    local settings = self.Settings
    local onScreen = self.IsOnScreen
    local corners = self.Corners -- Could be nil if offscreen or bounds failed

    -- Helper to get text position based on configuration
    local function getTextPosition(config, yOffset, boxTopLeft, boxBottomRight, boxCenter)
        local position = config.position
        local textDraw = self[config.drawingName] -- Assumes drawing name is stored in config
        local bounds = textDraw.TextBounds -- Needs calculation sometimes
        local xPos = boxCenter.X - bounds.X * 0.5

        if position == "Top" then
            return V2_NEW(xPos, boxTopLeft.Y - bounds.Y - yOffset)
        elseif position == "Bottom" then
            return V2_NEW(xPos, boxBottomRight.Y + yOffset)
        elseif position == "HealthBar" and self.HealthBar.Visible then -- Special case for Health Text
             local barFrom = self.HealthBar.From
             local barTo = self.HealthBar.To
             local healthRatio = math.clamp(self.Health / self.MaxHealth, 0, 1)
             local healthYPos = barTo.Y + (barFrom.Y - barTo.Y) * healthRatio
             local barXPos = self.HealthBar.Position.X -- Assuming HealthBar position is set correctly

             if settings.healthBar.position == "Left" then
                 return V2_NEW(barXPos - bounds.X - HEALTH_TEXT_OFFSET.X, healthYPos + HEALTH_TEXT_OFFSET.Y)
             elseif settings.healthBar.position == "Right" then
                 return V2_NEW(barXPos + settings.healthBar.thickness + HEALTH_TEXT_OFFSET.X, healthYPos + HEALTH_TEXT_OFFSET.Y)
             else -- Top/Bottom health bars - needs different logic
                 -- Placeholder: position near the bar center
                 return V2_NEW(barXPos + (self.HealthBar.Size.X * 0.5) - bounds.X * 0.5, barFrom.Y + HEALTH_TEXT_OFFSET.Y)
             end
        else -- Default fallback (e.g., if HealthBar not visible)
            return V2_NEW(xPos, boxBottomRight.Y + yOffset) -- Default to bottom
        end
    end


    -- Box Rendering (2D, Corner, 3D)
    local boxSettings = settings.box
    local boxEnabled = onScreen and boxSettings.enabled and corners
    local boxMode = boxSettings.mode

    -- Hide all box elements first
    self.BoxFill.Visible = false
    self.BoxOutline.Visible = false
    for _, line in ipairs(self.BoxLines) do line.Visible = false end

    if boxEnabled then
        local topLeft = corners.TopLeft
        local bottomRight = corners.BottomRight
        local size = corners.Size
        local center = topLeft + size * 0.5
        local boxColor = Utils.GetColor(self, boxSettings.color)
        local boxOutlineColor = Utils.GetColor(self, boxSettings.outlineColor, true)

        -- Fill
        local fillEnabled = boxSettings.fill
        self.BoxFill.Visible = fillEnabled
        if fillEnabled then
            self.BoxFill.Position = topLeft
            self.BoxFill.Size = size
            self.BoxFill.Color = Utils.GetColor(self, boxSettings.fillColor)
            self.BoxFill.Transparency = Utils.GetTransparency(boxSettings.fillTransparency)
        end

        -- Outline / Main Box Structure
        local outlineEnabled = boxSettings.outline

        if boxMode == "2D" or boxMode == "Corner" then
            self.BoxOutline.Visible = true -- Use Square for 2D/Corner outline
            self.BoxOutline.Position = topLeft
            self.BoxOutline.Size = size
            self.BoxOutline.Thickness = boxSettings.thickness -- Use main thickness for 2D box
            self.BoxOutline.Color = boxColor -- Main color for the box itself
            self.BoxOutline.Transparency = Utils.GetTransparency(boxSettings.transparency)

            if outlineEnabled then
                -- For 2D/Corner, we might draw a thicker background square or use Drawin.Outline property if available
                 -- Using the Outline property is simpler if Drawing lib supports it well
                 self.BoxOutline.Outline = true
                 self.BoxOutline.OutlineColor = boxOutlineColor
                 self.BoxOutline.OutlineTransparency = Utils.GetTransparency(boxSettings.outlineTransparency)
                 -- Thickness property might control main line, need separate control for outline thickness if possible
                 -- Workaround: Draw *another* square behind if OutlineThickness isn't a direct prop
            end

            if boxMode == "Corner" then
                -- Shorten the lines of the BoxOutline Square (Clipping is simplest)
                self.BoxOutline.Visible = false -- Hide the full square
                -- Draw 4 lines manually for corners
                local cornerLengthX = size.X * boxSettings.cornerSize
                local cornerLengthY = size.Y * boxSettings.cornerSize
                local lines = { -- Reuse BoxLines if available, otherwise create temp
                    { From = topLeft, To = topLeft + V2_NEW(cornerLengthX, 0) }, -- TL H
                    { From = topLeft, To = topLeft + V2_NEW(0, cornerLengthY) }, -- TL V
                    { From = V2_NEW(bottomRight.X, topLeft.Y), To = V2_NEW(bottomRight.X - cornerLengthX, topLeft.Y) }, -- TR H
                    { From = V2_NEW(bottomRight.X, topLeft.Y), To = V2_NEW(bottomRight.X, topLeft.Y + cornerLengthY) }, -- TR V
                    { From = V2_NEW(topLeft.X, bottomRight.Y), To = V2_NEW(topLeft.X + cornerLengthX, bottomRight.Y) }, -- BL H
                    { From = V2_NEW(topLeft.X, bottomRight.Y), To = V2_NEW(topLeft.X, bottomRight.Y - cornerLengthY) }, -- BL V
                    { From = bottomRight, To = bottomRight - V2_NEW(cornerLengthX, 0) }, -- BR H
                    { From = bottomRight, To = bottomRight - V2_NEW(0, cornerLengthY) }  -- BR V
                }
                for i = 1, math.min(#lines, #self.BoxLines) do
                    local lineDraw = self.BoxLines[i]
                    local data = lines[i]
                    lineDraw.Visible = true
                    lineDraw.From = data.From
                    lineDraw.To = data.To
                    lineDraw.Color = boxColor
                    lineDraw.Transparency = Utils.GetTransparency(boxSettings.transparency)
                    lineDraw.Thickness = boxSettings.thickness
                    -- TODO: Add outline support for corner lines (e.g., draw thicker lines behind)
                end
            end

        elseif boxMode == "3D" and corners.World and corners.Screen and #corners.Screen == 8 then
            -- Use pre-created BoxLines
             local edges = { -- Indices into corners.Screen array (0-7) for cube edges
                {1, 2}, {2, 3}, {3, 4}, {4, 1}, -- Bottom face
                {5, 6}, {6, 7}, {7, 8}, {8, 5}, -- Top face
                {1, 5}, {2, 6}, {3, 7}, {4, 8}  -- Connecting edges
             }
             for i = 1, #edges do
                 local lineDraw = self.BoxLines[i]
                 local p1Idx = edges[i][1]
                 local p2Idx = edges[i][2]
                 lineDraw.Visible = true
                 lineDraw.From = corners.Screen[p1Idx]
                 lineDraw.To = corners.Screen[p2Idx]
                 lineDraw.Color = boxColor
                 lineDraw.Transparency = Utils.GetTransparency(boxSettings.transparency)
                 lineDraw.Thickness = boxSettings.thickness
                 -- TODO: Outline for 3D lines
             end
        end
    end


    -- Skeleton Rendering
    local skeletonSettings = settings.skeleton
    local skeletonEnabled = onScreen and skeletonSettings.enabled and #self._charJointCache > 0

    -- Hide unused skeleton lines first
    for i = #self._charJointCache + 1, #self.SkeletonLines do
        self.SkeletonLines[i].line.Visible = false
        self.SkeletonLines[i].outline.Visible = false
    end
    -- Set visibility for used lines based on enabled status
    for i = 1, #self._charJointCache do
        local pair = self.SkeletonLines[i]
        pair.line.Visible = skeletonEnabled
        pair.outline.Visible = skeletonEnabled and skeletonSettings.outline
    end

    if skeletonEnabled then
        local skelColor = Utils.GetColor(self, skeletonSettings.color)
        local skelTrans = Utils.GetTransparency(skeletonSettings.transparency)
        local skelThick = skeletonSettings.thickness
        local skelOutline = skeletonSettings.outline
        local skelOutlineColor = Utils.GetColor(self, skeletonSettings.outlineColor, true)
        local skelOutlineTrans = Utils.GetTransparency(skeletonSettings.outlineTransparency)
        local skelOutlineThick = skeletonSettings.outlineThickness

        for i = 1, #self._charJointCache do
            local joint = self._charJointCache[i]
            local pos1, onScreen1 = Utils.WorldToScreen(joint.Part1.Position)
            local pos2, onScreen2 = Utils.WorldToScreen(joint.Part2.Position)

            -- Only draw if both points are reasonably on screen (prevents lines stretching across screen)
            local pair = self.SkeletonLines[i]
            if onScreen1 and onScreen2 then
                if skelOutline then
                    local outlineDraw = pair.outline
                    outlineDraw.From = pos1
                    outlineDraw.To = pos2
                    outlineDraw.Color = skelOutlineColor
                    outlineDraw.Transparency = skelOutlineTrans
                    outlineDraw.Thickness = skelThick + skelOutlineThick -- Render outline slightly thicker
                end
                local lineDraw = pair.line
                lineDraw.From = pos1
                lineDraw.To = pos2
                lineDraw.Color = skelColor
                lineDraw.Transparency = skelTrans
                lineDraw.Thickness = skelThick
            else
                -- Hide this specific line if it goes off-screen
                pair.line.Visible = false
                pair.outline.Visible = false
            end
        end
    end


    -- Health Bar & Text Rendering
    local healthBarSettings = settings.healthBar
    local healthTextSettings = settings.healthText
    local healthBarEnabled = onScreen and healthBarSettings.enabled and corners
    local healthTextEnabled = onScreen and healthTextSettings.enabled and corners

    self.HealthBar.Visible = healthBarEnabled
    self.HealthBarOutline.Visible = healthBarEnabled and healthBarSettings.outline
    self.HealthText.Visible = healthTextEnabled

    if healthBarEnabled then
        local topLeft = corners.TopLeft
        local bottomRight = corners.BottomRight
        local size = corners.Size
        local healthRatio = math.clamp(self.Health / self.MaxHealth, 0, 1)
        local barColor

        if healthBarSettings.colorMode == "Gradient" then
            barColor = Utils.LerpColor(
                Utils.GetColor(self, healthBarSettings.dyingColor),
                Utils.GetColor(self, healthBarSettings.healthyColor),
                healthRatio
            )
        elseif healthBarSettings.colorMode == "Team" then
             barColor = Utils.GetColor(self, "Team")
        else -- Static
            barColor = Utils.GetColor(self, healthBarSettings.staticColor)
        end

        local barThickness = healthBarSettings.thickness
        local barOutlineThickness = healthBarSettings.outlineThickness
        local barOutlineColor = Utils.GetColor(self, healthBarSettings.outlineColor, true)
        local barOutlineTrans = Utils.GetTransparency(healthBarSettings.outlineTransparency)
        local barTrans = Utils.GetTransparency(healthBarSettings.transparency)

        local barFrom, barTo, outlineFrom, outlineTo

        if healthBarSettings.position == "Left" then
            barTo = topLeft - HEALTH_BAR_PADDING + V2_NEW(0, size.Y) -- Bottom left corner of bar space
            barFrom = topLeft - HEALTH_BAR_PADDING -- Top left corner
            outlineFrom = barFrom - V2_NEW(barOutlineThickness*0.5, barOutlineThickness)
            outlineTo = barTo + V2_NEW(-barOutlineThickness*0.5, barOutlineThickness)
        elseif healthBarSettings.position == "Right" then
            barTo = V2_NEW(bottomRight.X, topLeft.Y) + HEALTH_BAR_PADDING + V2_NEW(0, size.Y) -- Bottom right
            barFrom = V2_NEW(bottomRight.X, topLeft.Y) + HEALTH_BAR_PADDING -- Top right
             outlineFrom = barFrom + V2_NEW(barOutlineThickness*0.5, -barOutlineThickness)
            outlineTo = barTo + V2_NEW(barOutlineThickness*0.5, barOutlineThickness)
        elseif healthBarSettings.position == "Top" then
            barFrom = topLeft - V2_NEW(0, HEALTH_BAR_PADDING.X) -- Top Left
            barTo = V2_NEW(bottomRight.X, topLeft.Y) - V2_NEW(0, HEALTH_BAR_PADDING.X) -- Top Right
             outlineFrom = barFrom + V2_NEW(-barOutlineThickness, -barOutlineThickness*0.5)
            outlineTo = barTo + V2_NEW(barOutlineThickness, -barOutlineThickness*0.5)
        else -- Bottom
            barFrom = V2_NEW(topLeft.X, bottomRight.Y) + V2_NEW(0, HEALTH_BAR_PADDING.X) -- Bottom Left
            barTo = bottomRight + V2_NEW(0, HEALTH_BAR_PADDING.X) -- Bottom Right
             outlineFrom = barFrom + V2_NEW(-barOutlineThickness, barOutlineThickness*0.5)
            outlineTo = barTo + V2_NEW(barOutlineThickness, barOutlineThickness*0.5)
        end

        -- Calculate the actual health segment
        local healthEndPos
        if healthBarSettings.position == "Left" or healthBarSettings.position == "Right" then
            healthEndPos = barTo:Lerp(barFrom, healthRatio)
        else -- Top or Bottom
             healthEndPos = barFrom:Lerp(barTo, healthRatio)
        end

        local bar = self.HealthBar
        bar.Color = barColor
        bar.Transparency = barTrans
        bar.Thickness = barThickness
        if healthBarSettings.position == "Left" or healthBarSettings.position == "Right" then
            bar.From = healthEndPos
            bar.To = barTo
            bar.Position = V2_NEW(barFrom.X - barThickness*0.5, barFrom.Y) -- Adjust position for vertical bar
            bar.Size = V2_NEW(barThickness, size.Y) -- Size for vertical bar
        else
            bar.From = barFrom
            bar.To = healthEndPos
            bar.Position = V2_NEW(barFrom.X, barFrom.Y - barThickness*0.5) -- Adjust pos for horizontal
            bar.Size = V2_NEW(size.X, barThickness) -- Size for horizontal
        end
        -- WORKAROUND: Since Drawing.Line doesn't have easy vertical/horizontal modes,
        -- we might need to use Squares for horizontal/vertical bars instead of Lines.
        -- Assuming Line works like this for now. If not, switch to Square.


        if self.HealthBarOutline.Visible then
            local outline = self.HealthBarOutline
             -- Using a line for outline seems simpler
            outline.From = outlineFrom
            outline.To = outlineTo
            outline.Color = barOutlineColor
            outline.Transparency = barOutlineTrans
            outline.Thickness = barThickness + barOutlineThickness -- Make outline slightly thicker
             -- Need to adjust outline From/To based on vertical/horizontal too if using Line
        end

        -- Health Text (positioning relies on health bar visibility/position)
        if healthTextEnabled then
            local text = self.HealthText
            text.Visible = true
            text.Text = healthTextSettings.format
                :gsub("{hp}", tostring(M_ROUND(self.Health)))
                :gsub("{maxhp}", tostring(M_ROUND(self.MaxHealth)))
                :gsub("{percent}", tostring(M_ROUND(healthRatio * 100)))
            text.Color = Utils.GetColor(self, healthTextSettings.color)
            text.Transparency = Utils.GetTransparency(healthTextSettings.transparency)
            text.Size = healthTextSettings.size or Settings:Get("shared.textSize")
            text.Font = healthTextSettings.font or Settings:Get("shared.textFont")
            text.Outline = healthTextSettings.outline
            text.OutlineColor = Utils.GetColor(self, healthTextSettings.outlineColor, true)
            -- ZIndex set during init

            -- Calculate position based on health bar position
            text.Position = getTextPosition({ position = healthTextSettings.position, drawingName = "HealthText"}, 0, topLeft, bottomRight, corners.TopLeft + corners.Size * 0.5) -- Pass necessary info

        end
    end


    -- Info Texts (Name, Distance, Weapon)
    local nameSettings = settings.name
    local distSettings = settings.distance
    local weaponSettings = settings.weapon
    local nameEnabled = onScreen and nameSettings.enabled and corners
    local distEnabled = onScreen and distSettings.enabled and corners and self.Depth
    local weaponEnabled = onScreen and weaponSettings.enabled and corners and self.WeaponName ~= "Unknown" and self.WeaponName ~= ""

    self.NameText.Visible = nameEnabled
    self.DistanceText.Visible = distEnabled
    self.WeaponText.Visible = weaponEnabled

    local currentYOffsetTop = NAME_OFFSET.Y
    local currentYOffsetBottom = 0

    if nameEnabled then
        local text = self.NameText
        text.Text = self.Player.DisplayName -- Or use Name if preferred
        text.Color = Utils.GetColor(self, nameSettings.color)
        text.Transparency = Utils.GetTransparency(nameSettings.transparency)
        text.Size = nameSettings.size or Settings:Get("shared.textSize")
        text.Font = nameSettings.font or Settings:Get("shared.textFont")
        text.Outline = nameSettings.outline
        text.OutlineColor = Utils.GetColor(self, nameSettings.outlineColor, true)

        local pos = getTextPosition({ position = nameSettings.position, drawingName = "NameText"}, currentYOffsetTop, corners.TopLeft, corners.BottomRight, corners.TopLeft + corners.Size * 0.5)
        text.Position = pos
        currentYOffsetTop = currentYOffsetTop + text.TextBounds.Y -- Adjust offset for next top item
    end

     -- Order: Distance usually below name/box, Weapon below distance
    if distEnabled then
        local text = self.DistanceText
        text.Text = distSettings.format:gsub("{dist}", tostring(M_ROUND(self.Depth)))
        text.Color = Utils.GetColor(self, distSettings.color)
        text.Transparency = Utils.GetTransparency(distSettings.transparency)
        text.Size = distSettings.size or Settings:Get("shared.textSize")
        text.Font = distSettings.font or Settings:Get("shared.textFont")
        text.Outline = distSettings.outline
        text.OutlineColor = Utils.GetColor(self, distSettings.outlineColor, true)

        local pos = getTextPosition({ position = distSettings.position, drawingName = "DistanceText"}, currentYOffsetBottom + DISTANCE_OFFSET.Y, corners.TopLeft, corners.BottomRight, corners.TopLeft + corners.Size * 0.5)
        text.Position = pos
        currentYOffsetBottom = currentYOffsetBottom + text.TextBounds.Y + DISTANCE_OFFSET.Y -- Adjust offset for next bottom item
    end

    if weaponEnabled then
        local text = self.WeaponText
        text.Text = self.WeaponName
        text.Color = Utils.GetColor(self, weaponSettings.color)
        text.Transparency = Utils.GetTransparency(weaponSettings.transparency)
        text.Size = weaponSettings.size or Settings:Get("shared.textSize")
        text.Font = weaponSettings.font or Settings:Get("shared.textFont")
        text.Outline = weaponSettings.outline
        text.OutlineColor = Utils.GetColor(self, weaponSettings.outlineColor, true)

        local pos = getTextPosition({ position = weaponSettings.position, drawingName = "WeaponText"}, currentYOffsetBottom + WEAPON_OFFSET.Y, corners.TopLeft, corners.BottomRight, corners.TopLeft + corners.Size * 0.5)
        text.Position = pos
         -- No need to update bottom offset further unless more items are added below
    end


    -- Head Dot
    local headDotSettings = settings.headDot
    local headDotEnabled = onScreen and headDotSettings.enabled and self.HeadPosition

    self.HeadDot.Visible = headDotEnabled and headDotSettings.filled
    self.HeadDotOutline.Visible = headDotEnabled and headDotSettings.outline

    if headDotEnabled then
        local headScreenPos, headOnScreen = Utils.WorldToScreen(self.HeadPosition)
        if headOnScreen then
            local dotColor = Utils.GetColor(self, headDotSettings.color)
            local dotTrans = Utils.GetTransparency(headDotSettings.transparency)
            local dotSize = headDotSettings.size
            local dotOutlineColor = Utils.GetColor(self, headDotSettings.outlineColor, true)
            local dotOutlineTrans = Utils.GetTransparency(headDotSettings.outlineTransparency)
            local dotOutlineThickness = headDotSettings.outlineThickness

            if self.HeadDot.Visible then
                local dot = self.HeadDot
                dot.Position = headScreenPos
                dot.Radius = dotSize * 0.5
                dot.Color = dotColor
                dot.Transparency = dotTrans
                dot.Filled = true -- Explicitly set
                 dot.NumSides = 12 -- Make it look like a circle
            end
            if self.HeadDotOutline.Visible then
                local outline = self.HeadDotOutline
                outline.Position = headScreenPos
                outline.Radius = dotSize * 0.5
                outline.Color = dotOutlineColor
                outline.Transparency = dotOutlineTrans
                outline.Thickness = dotOutlineThickness
                outline.Filled = false -- Explicitly set
                outline.NumSides = 12
            end
        else
             self.HeadDot.Visible = false
             self.HeadDotOutline.Visible = false
        end
    end


    -- Look Vector
    local lookVecSettings = settings.lookVector
    local lookVecEnabled = onScreen and lookVecSettings.enabled and self.HeadPosition and self.LookVector

    self.LookVectorLine.Visible = lookVecEnabled

    if lookVecEnabled then
        local startPos = self.HeadPosition
        local endPos = startPos + self.LookVector * lookVecSettings.length
        local startScreen, startOnScreen = Utils.WorldToScreen(startPos)
        local endScreen, endOnScreen = Utils.WorldToScreen(endPos)

        if startOnScreen and endOnScreen then -- Only draw if both points are visible
            local line = self.LookVectorLine
            line.From = startScreen
            line.To = endScreen
            line.Color = Utils.GetColor(self, lookVecSettings.color)
            line.Transparency = Utils.GetTransparency(lookVecSettings.transparency)
            line.Thickness = lookVecSettings.thickness
        else
            self.LookVectorLine.Visible = false
        end
    end


    -- Tracer
    local tracerSettings = settings.tracer
    local tracerEnabled = onScreen and tracerSettings.enabled and corners -- Requires corners for target point

    self.TracerLine.Visible = tracerEnabled
    self.TracerOutline.Visible = tracerEnabled and tracerSettings.outline

    if tracerEnabled then
        local tracerColor = Utils.GetColor(self, tracerSettings.color)
        local tracerTrans = Utils.GetTransparency(tracerSettings.transparency)
        local tracerThick = tracerSettings.thickness
        local tracerOutline = tracerSettings.outline
        local tracerOutlineColor = Utils.GetColor(self, tracerSettings.outlineColor, true)
        local tracerOutlineTrans = Utils.GetTransparency(tracerSettings.outlineTransparency)
        local tracerOutlineThick = tracerSettings.outlineThickness

        local vpSize = CAMERA.ViewportSize
        local originPoint
        if tracerSettings.origin == "Top" then
            originPoint = V2_NEW(vpSize.X * 0.5, 0)
        elseif tracerSettings.origin == "Middle" then
            originPoint = V2_NEW(vpSize.X * 0.5, vpSize.Y * 0.5)
        else -- Bottom (default)
            originPoint = V2_NEW(vpSize.X * 0.5, vpSize.Y)
        end

        local targetPoint = corners.TopLeft + corners.Size * V2_NEW(0.5, 1) -- Middle bottom of the box

        if tracerOutline then
            local outline = self.TracerOutline
            outline.From = originPoint
            outline.To = targetPoint
            outline.Color = tracerOutlineColor
            outline.Transparency = tracerOutlineTrans
            outline.Thickness = tracerThick + tracerOutlineThick
        end

        local line = self.TracerLine
        line.From = originPoint
        line.To = targetPoint
        line.Color = tracerColor
        line.Transparency = tracerTrans
        line.Thickness = tracerThick
    end


    -- Off-Screen Arrow
    local arrowSettings = settings.offScreenArrow
    local arrowEnabled = not onScreen and arrowSettings.enabled and self.OffScreenDirection

    self.OffScreenArrow.Visible = arrowEnabled and arrowSettings.filled
    self.OffScreenArrowOutline.Visible = arrowEnabled and arrowSettings.outline

    if arrowEnabled then
        local arrowColor = Utils.GetColor(self, arrowSettings.color)
        local arrowTrans = Utils.GetTransparency(arrowSettings.transparency)
        local arrowSize = arrowSettings.size
        local arrowRadius = arrowSettings.radius
        local arrowOutline = arrowSettings.outline
        local arrowOutlineColor = Utils.GetColor(self, arrowSettings.outlineColor, true)
        local arrowOutlineTrans = Utils.GetTransparency(arrowSettings.outlineTransparency)
        local arrowOutlineThickness = arrowSettings.outlineThickness
        local arrowFilled = arrowSettings.filled

        local vpCenter = CAMERA.ViewportSize * 0.5
        local direction = self.OffScreenDirection

        -- Calculate arrow points
        local tipPos = vpCenter + direction * arrowRadius
        -- Clamp tip position to be slightly inside the screen borders
        tipPos = Utils.ClampVector2(tipPos, V2_NEW(arrowSize, arrowSize), CAMERA.ViewportSize - V2_NEW(arrowSize, arrowSize))

        local angle = M_ATAN2(direction.Y, direction.X)
        local rightVec = Utils.RotateVector2D(direction, M_PI / 2) -- Perpendicular vector

        local baseCenter = tipPos - direction * arrowSize -- Move base back along direction
        local basePoint1 = baseCenter + rightVec * (arrowSize * 0.5)
        local basePoint2 = baseCenter - rightVec * (arrowSize * 0.5)

        -- Alternative using rotation (from original code, might be better)
        -- local basePoint1 = tipPos - Utils.RotateVector2D(direction, M_RAD(30)) * arrowSize -- Adjust angle (e.g., 30 deg)
        -- local basePoint2 = tipPos - Utils.RotateVector2D(direction, M_RAD(-30)) * arrowSize

        if self.OffScreenArrowOutline.Visible then
            local outline = self.OffScreenArrowOutline
            outline.PointA = tipPos
            outline.PointB = basePoint1
            outline.PointC = basePoint2
            outline.Color = arrowOutlineColor
            outline.Transparency = arrowOutlineTrans
            outline.Thickness = arrowOutlineThickness
            outline.Filled = false
        end

        if self.OffScreenArrow.Visible then
            local arrow = self.OffScreenArrow
            arrow.PointA = tipPos
            arrow.PointB = basePoint1
            arrow.PointC = basePoint2
            arrow.Color = arrowColor
            arrow.Transparency = arrowTrans
            arrow.Filled = true
        end
    end
end

function PlayerEspRenderer:Destroy()
    -- print("Destroying PlayerEspRenderer for", self.Player)
    self._lastCharacter = nil -- Clear reference
	BaseEspObject.Destroy(self) -- Call base destroy method
end

-- // ======================== \\ --
-- //   Player Chams Renderer  \\ --
-- // ======================== \\ --
PlayerChamsRenderer = {}
PlayerChamsRenderer.__index = PlayerChamsRenderer
setmetatable(PlayerChamsRenderer, { __index = BaseEspObject }) -- Inheritance

function PlayerChamsRenderer:new(player)
	local self = setmetatable(BaseEspObject:new(), PlayerChamsRenderer)
	self.Player = assert(player, "PlayerChamsRenderer requires a Player")

    -- Use Highlight instance for chams
    self.Highlight = INST_NEW("Highlight")
    self.Highlight.Parent = GUI_CONTAINER -- Put in designated container
    self.Highlight.Enabled = false
    -- Adornee set during Update

    -- Could potentially add BillboardGui based chams here for more complex effects later
	return self
end

function PlayerChamsRenderer:Update(deltaTime)
    local player = self.Player
    if not player or not player.Parent then return self:Destroy() end

    local settings = Settings:GetPlayerSettings(player)
    if not settings or not settings.enabled then
        self.Highlight.Enabled = false
        return
    end

    -- Reuse checks from PlayerEspRenderer if possible, or redo them here for Chams specifically
    local whitelist = Settings:Get("player.whitelist")
    local blacklist = Settings:Get("player.blacklist")
    if (#whitelist > 0 and not T_FIND(whitelist, player.UserId)) or T_FIND(blacklist, player.UserId) then
        self.Highlight.Enabled = false
        return
    end
    if player == LOCAL_PLAYER and not Settings:Get("player.enableForLocalPlayer") then
        self.Highlight.Enabled = false
        return
    end

    local character = EspLib.GameInterface.GetCharacter(player)
    local isAlive = Utils.IsAlive(player)
    local chamsSettings = settings.chams

    if character and character.Parent and isAlive and chamsSettings.enabled then
        self.Highlight.Adornee = character
        self.Highlight.Enabled = true

        -- Configure Highlight based on settings
        self.Highlight.DepthMode = chamsSettings.visibleOnly and Enum.HighlightDepthMode.Occluded or Enum.HighlightDepthMode.AlwaysOnTop

        local fillSettings = chamsSettings.fill
        self.Highlight.FillColor = fillSettings.enabled and Utils.GetColor(self, fillSettings.color) or COL3_NEW() -- Use black if disabled? Or keep last?
        self.Highlight.FillTransparency = fillSettings.enabled and Utils.GetTransparency(fillSettings.transparency) or 1 -- Fully transparent if disabled

        local outlineSettings = chamsSettings.outline
        self.Highlight.OutlineColor = outlineSettings.enabled and Utils.GetColor(self, outlineSettings.color, true) or COL3_NEW()
        self.Highlight.OutlineTransparency = outlineSettings.enabled and Utils.GetTransparency(outlineSettings.transparency) or 1

        -- Material Chams (Overrides Highlight visuals if enabled)
        -- Note: Highlight doesn't directly support materials. This needs a different approach.
        -- Common methods:
        -- 1. Iterate parts, clone, set material, parent to Camera (old method, laggy).
        -- 2. Iterate parts, apply SurfaceAppearance or Texture (better, needs PBR support).
        -- 3. Use ViewportFrames (complex).
        -- For simplicity, we'll *ignore* the material setting for Highlight-based chams.
        -- A more advanced library might swap between Highlight and another method based on settings.
        local materialSettings = chamsSettings.material
        if materialSettings.enabled then
            -- warn("[ESP Chams] Material chams are not supported with Highlight instance. Use Fill/Outline instead.")
            -- If implementing alternative methods, do it here.
        end

    else
        self.Highlight.Enabled = false
        self.Highlight.Adornee = nil -- Clear adornee when disabled
    end
end

function PlayerChamsRenderer:Render(deltaTime)
    -- Highlight instance updates automatically based on its properties.
    -- No specific render logic needed here unless implementing alternative cham methods.
end

function PlayerChamsRenderer:Destroy()
    -- print("Destroying PlayerChamsRenderer for", self.Player)
    if self.Highlight then
        self.Highlight:Destroy()
        self.Highlight = nil
    end
	BaseEspObject.Destroy(self)
end


-- // ======================== \\ --
-- // World Instance Renderer  \\ --
-- // ======================== \\ --
WorldInstanceRenderer = {}
WorldInstanceRenderer.__index = WorldInstanceRenderer
setmetatable(WorldInstanceRenderer, { __index = BaseEspObject }) -- Inheritance

function WorldInstanceRenderer:new(instance, rule)
	local self = setmetatable(BaseEspObject:new(), WorldInstanceRenderer)
	self.Instance = assert(instance, "WorldInstanceRenderer requires an Instance")
	self.Rule = assert(rule, "WorldInstanceRenderer requires a rule definition") -- Contains settings like text format, color etc.

    self.Text = self:_createDrawing("Text", { Center = true, Visible = false })
    -- Future: Add Box, etc. drawings here for world items
    -- self.Box = self:_createDrawing("Square", { Filled = false, Visible = false })

    self.Text.ZIndex = 50 -- Ensure world text is generally visible

	return self
end

function WorldInstanceRenderer:Update(deltaTime)
    local inst = self.Instance
    if not inst or not inst.Parent then
        return self:Destroy() -- Instance removed
    end

    local rule = self.Rule
    if not rule.enabled then
        self.IsVisible = false
        return
    end

    -- Determine position (Pivot for models, Position for parts/tools)
    local worldPos
    if inst:IsA("Model") and inst.PrimaryPart then
        worldPos = inst.PrimaryPart.Position
    elseif inst:IsA("BasePart") then
        worldPos = inst.Position
    elseif inst:IsA("Tool") and inst.Parent and inst.Parent:IsA("Model") and inst.Parent.PrimaryPart then -- Tool equipped
        worldPos = inst.Parent.PrimaryPart.Position
    elseif inst:IsA("Tool") and inst:FindFirstChild("Handle") then -- Tool dropped
        worldPos = inst.Handle.Position
    else
        -- Try GetPivot as a fallback for models without PrimaryPart etc.
        local success, pivot = pcall(inst.GetPivot, inst)
        if success and typeof(pivot) == "CFrame" then
            worldPos = pivot.Position
        else
            self.IsVisible = false -- Cannot determine position
            return
        end
    end

    self.WorldPosition = worldPos
    local screenPos, onScreen, depth = Utils.WorldToScreen(worldPos)
    self.ScreenPosition = screenPos
    self.Depth = depth
    self.IsOnScreen = onScreen
    self.IsVisible = true

    -- Distance Check
    if rule.limitDistance and depth > rule.maxDistance then
        self.IsVisible = false
        self.IsOnScreen = false
    end

    -- Potentially add LOS check here too if needed for world items
end

function WorldInstanceRenderer:Render(deltaTime)
     if not self.IsVisible or not self.IsOnScreen then
        self:_setVisible(false)
        return
     end

     local rule = self.Rule
     local textSettings = rule -- Assume rule table contains text settings directly

     local textEnabled = textSettings.text and textSettings.text ~= ""

     self.Text.Visible = textEnabled

     if textEnabled then
         local text = self.Text
         text.Visible = true -- Make sure it's visible
         text.Text = textSettings.text
            :gsub("{name}", self.Instance.Name)
            :gsub("{distance}", tostring(M_ROUND(self.Depth)))
            -- Add more format options like {classname}, {position} if needed

         text.Color = Utils.GetColor(self, textSettings.textColor or Settings:Get("defaults.fallbackColor"))
         text.Transparency = Utils.GetTransparency(textSettings.textColor and textSettings.textColor.Transparency or 0) -- Assuming color can be table {Color, Transparency} or just Color3
         text.Size = textSettings.textSize or Settings:Get("shared.textSize")
         text.Font = textSettings.textFont or Settings:Get("shared.textFont")
         text.Outline = textSettings.textOutline -- Use directly if bool, else check if defined
         text.OutlineColor = Utils.GetColor(self, textSettings.textOutlineColor or Settings:Get("defaults.outlineColor"), true)

         -- Position text above the object's screen position
         text.Position = self.ScreenPosition - V2_NEW(text.TextBounds.X * 0.5, text.TextBounds.Y + 5) -- Centered horizontally, offset above
     end

     -- Render Box, etc. for world items here if added
end

function WorldInstanceRenderer:Destroy()
    -- print("Destroying WorldInstanceRenderer for", self.Instance)
	BaseEspObject.Destroy(self)
end


-- // ======================== \\ --
-- // Player ESP Controller    \\ --
-- // ======================== \\ --
PlayerEspController = {}
PlayerEspController.__index = PlayerEspController

function PlayerEspController:new()
	local self = setmetatable({}, PlayerEspController)
	self._playerObjects = {} -- [Player] = { espRenderer, chamsRenderer }
    self._connections = {}
	return self
end

function PlayerEspController:Initialize()
    local function onPlayerAdded(player)
        -- Wait briefly for character/team potentially
        task.wait(0.1)
        if player ~= LOCAL_PLAYER or Settings:Get("player.enableForLocalPlayer") then
             self:AddPlayer(player)
        end
    end

    local function onPlayerRemoving(player)
        self:RemovePlayer(player)
    end

    -- Connect signals
    self._connections.PlayerAdded = Players.PlayerAdded:Connect(onPlayerAdded)
    self._connections.PlayerRemoving = Players.PlayerRemoving:Connect(onPlayerRemoving)

    -- Add existing players
    for _, player in ipairs(Players:GetPlayers()) do
        onPlayerAdded(player)
    end
end

function PlayerEspController:AddPlayer(player)
    if not player or self._playerObjects[player] then return end -- Already added or invalid

    -- print("Adding player:", player.Name)
    local espRenderer = PlayerEspRenderer:new(player)
    local chamsRenderer = PlayerChamsRenderer:new(player)

    self._playerObjects[player] = {
        Esp = espRenderer,
        Chams = chamsRenderer,
    }
end

function PlayerEspController:RemovePlayer(player)
    local objects = self._playerObjects[player]
    if objects then
        -- print("Removing player:", player.Name)
        objects.Esp:Destroy()
        objects.Chams:Destroy()
        self._playerObjects[player] = nil
    end
end

function PlayerEspController:Update(deltaTime)
    -- Iterate safely as players might be removed during iteration
    for player, objects in pairs(self._playerObjects) do
        -- Update ESP renderer first (calculates visibility, bounds etc.)
        objects.Esp:Update(deltaTime)
        -- Update Chams renderer (can potentially reuse some info from ESP update if needed)
        objects.Chams:Update(deltaTime)
    end
end

function PlayerEspController:Render(deltaTime)
    for player, objects in pairs(self._playerObjects) do
         -- Only render if the ESP object determined the player is visible overall
        if objects.Esp.IsVisible then
            objects.Esp:Render(deltaTime)
            -- Chams rendering is mostly handled by the Highlight instance itself
            -- objects.Chams:Render(deltaTime) -- Only call if Chams has manual render steps
        else
            -- Ensure drawings are hidden if player ESP is not visible
             objects.Esp:_setVisible(false)
             -- Chams visibility handled in its own Update
        end
    end
end

function PlayerEspController:Destroy()
    -- Disconnect signals
    for _, conn in pairs(self._connections) do
        conn:Disconnect()
    end
    T_CLEAR(self._connections)

    -- Destroy all player objects
    for player, objects in pairs(self._playerObjects) do
        objects.Esp:Destroy()
        objects.Chams:Destroy()
    end
    T_CLEAR(self._playerObjects)
    -- print("Player ESP Controller Destroyed")
end


-- // ======================== \\ --
-- //  World ESP Controller    \\ --
-- // ======================== \\ --
WorldEspController = {}
WorldEspController.__index = WorldEspController

function WorldEspController:new()
	local self = setmetatable({}, WorldEspController)
	self._trackedInstances = {} -- [Instance] = WorldInstanceRenderer
    self._lastScanTime = 0
    self._scanInterval = 1 -- Seconds between full workspace scans
	return self
end

function WorldEspController:Initialize()
    -- Initial scan
    self:_scanWorkspace()
end

function WorldEspController:_scanWorkspace()
    local rules = Settings:Get("world.instances")
    if not rules or #rules == 0 then return end -- No rules defined

    local foundInstances = {} -- Keep track of instances found in this scan

    -- Iterate through potential containers (Workspace, Debris, etc.)
    -- For simplicity, just scanning Workspace for now.
    for _, instance in ipairs(Workspace:GetDescendants()) do
        if not instance or not instance.Parent then continue end -- Skip invalid

        for _, rule in ipairs(rules) do
             -- Protect against errors in user-defined filter functions
            local success, match = pcall(rule.filter, instance)
            if success and match then
                foundInstances[instance] = true -- Mark as found
                if not self._trackedInstances[instance] then
                    -- New instance matching a rule
                    -- print("Tracking new world instance:", instance:GetFullName())
                    self._trackedInstances[instance] = WorldInstanceRenderer:new(instance, rule)
                else
                    -- Instance already tracked, ensure its rule is up-to-date if rules change dynamically
                    self._trackedInstances[instance].Rule = rule
                end
                break -- Stop checking rules for this instance once matched
            end
            if not success then
                 warn("[ESP World Scan] Error in filter function for rule:", rule, "Error:", match)
            end
        end
    end

    -- Clean up instances that were tracked but no longer exist or match rules
    for instance, renderer in pairs(self._trackedInstances) do
        if not instance or not instance.Parent or not foundInstances[instance] then
             -- print("Stopping tracking for world instance:", instance:GetFullName())
             renderer:Destroy()
             self._trackedInstances[instance] = nil
        end
    end
end

function WorldEspController:Update(deltaTime)
    if not Settings:Get("world.enabled") then
        -- If world ESP is disabled globally, destroy existing renderers
        if next(self._trackedInstances) then -- Check if table is not empty
            for instance, renderer in pairs(self._trackedInstances) do
                renderer:Destroy()
            end
            T_CLEAR(self._trackedInstances)
        end
        return
    end

    -- Periodically rescan workspace for new/removed items
    if tick() - self._lastScanTime > self._scanInterval then
        self:_scanWorkspace()
        self._lastScanTime = tick()
    end

    -- Update existing tracked instances
    for instance, renderer in pairs(self._trackedInstances) do
        -- Check instance validity again before updating (might have been destroyed between scan and update)
        if instance and instance.Parent then
            renderer:Update(deltaTime)
        else
            -- Instance became invalid, schedule for removal on next scan or remove now
            renderer:Destroy()
            self._trackedInstances[instance] = nil
        end
    end
end

function WorldEspController:Render(deltaTime)
     if not Settings:Get("world.enabled") then return end

     for instance, renderer in pairs(self._trackedInstances) do
         if renderer.IsVisible then -- Check visibility flag set during Update
             renderer:Render(deltaTime)
         else
             renderer:_setVisible(false) -- Ensure drawings are hidden
         end
     end
end

function WorldEspController:AddRule(rule)
    local rules = Settings:Get("world.instances") or {}
    T_INSERT(rules, rule)
    Settings:Set("world.instances", rules)
    self:_scanWorkspace() -- Rescan after adding rule
end

function WorldEspController:ClearRules()
    Settings:Set("world.instances", {})
     for instance, renderer in pairs(self._trackedInstances) do
        renderer:Destroy()
     end
     T_CLEAR(self._trackedInstances)
end

function WorldEspController:Destroy()
    -- Destroy all instance renderers
    for instance, renderer in pairs(self._trackedInstances) do
        renderer:Destroy()
    end
    T_CLEAR(self._trackedInstances)
    -- print("World ESP Controller Destroyed")
end


-- // ======================== \\ --
-- //     Main ESP Library     \\ --
-- // ======================== \\ --
EspLib = {}
EspLib._isLoaded = false
EspLib._connections = {}
EspLib._controllers = {}

-- Stubs for required game-specific functions
EspLib.GameInterface = {
	GetCharacter = function(player) return player and player.Character end,
	GetHealth = function(player)
		local char = player and player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		return hum and hum.Health or 100, hum and hum.MaxHealth or 100
	end,
	IsFriendly = function(player) return player and LOCAL_PLAYER and player.Team and player.Team == LOCAL_PLAYER.Team end,
	GetTeamColor = function(player) return player and player.Team and player.Team.TeamColor.Color or COL3_NEW(1,1,1) end,
	GetWeapon = function(player)
        local char = player and player.Character
        if not char then return "" end
        -- Basic check for Tool in character
        local tool = char:FindFirstChildOfClass("Tool")
        return tool and tool.Name or "" -- Return tool name if found
    end,
    -- Add more stubs as needed (e.g., GetRank, IsAdmin, GetStatusEffect)
}

function EspLib:SetupGameInterface(interfaceTable)
	assert(type(interfaceTable) == "table", "GameInterface setup requires a table")
	-- Validate required functions exist?
    local required = {"GetCharacter", "GetHealth", "IsFriendly", "GetTeamColor", "GetWeapon"}
    for _, funcName in ipairs(required) do
        assert(type(interfaceTable[funcName]) == "function", "GameInterface missing required function: " .. funcName)
    end
	self.GameInterface = interfaceTable -- Override the default stubs
end

function EspLib:Load()
	if self._isLoaded then
		warn("[ESP Lib] Already loaded.")
		return
	end

    -- print("[ESP Lib] Loading...")

	-- Initialize Settings first
	Settings:Initialize()

    -- Initialize Controllers
    self._controllers.Player = PlayerEspController:new()
    self._controllers.World = WorldEspController:new()

    self._controllers.Player:Initialize()
    self._controllers.World:Initialize() -- Does initial scan

	-- Connect main render loop
    local lastRenderTime = 0
    local targetFps = Settings:Get("refreshRate")
    local targetDelta = targetFps > 0 and (1 / targetFps) or 0

    self._connections.RenderStepped = RunService.RenderStepped:Connect(function(deltaTime)
        if not Settings:Get("enabled") then return end -- Check global toggle

        local currentTime = tick()
        if currentTime - lastRenderTime < targetDelta then return end -- Throttle update rate if set

        -- Update Camera reference (just in case it changes, though unlikely)
        CAMERA = Workspace.CurrentCamera
        if not CAMERA then return end -- Cannot render without camera

        -- Update phase (calculations)
        self._controllers.Player:Update(deltaTime)
        self._controllers.World:Update(deltaTime)

        -- Render phase (drawing)
        self._controllers.Player:Render(deltaTime)
        self._controllers.World:Render(deltaTime)

        lastRenderTime = currentTime
	end)

	self._isLoaded = true
	print("[ESP Lib] Loaded successfully.")
end

function EspLib:Unload()
	if not self._isLoaded then
		warn("[ESP Lib] Not loaded.")
		return
	end

    -- print("[ESP Lib] Unloading...")

	-- Disconnect main loop first
	if self._connections.RenderStepped then
		self._connections.RenderStepped:Disconnect()
		self._connections.RenderStepped = nil
	end

    -- Destroy controllers (which handle destroying their objects)
    if self._controllers.Player then
        self._controllers.Player:Destroy()
        self._controllers.Player = nil
    end
    if self._controllers.World then
        self._controllers.World:Destroy()
        self._controllers.World = nil
    end
    T_CLEAR(self._controllers)

	self._isLoaded = false
	print("unloaded fucktard")
end

EspLib.Settings = Settings
EspLib.Utils = Utils

EspLib.AddWorldRule = function(rule)
    if EspLib._isLoaded and EspLib._controllers.World then
        EspLib._controllers.World:AddRule(rule)
    else
        warn(cannot add world rule: library not loaded or worldcontroller missing lil nigga")
    end
end

EspLib.ClearWorldRules = function()
    if EspLib._isLoaded and EspLib._controllers.World then
        EspLib._controllers.World:ClearRules()
    else
         warn("nigga i cant clear world rules")
    end
end



return EspLib
