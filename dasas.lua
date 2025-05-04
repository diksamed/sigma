--[[
Advanced ESP Library
Version: 2.6 (Refactored function definitions to fix self-reference issues)

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
local CoreGui -- Lazy loaded

-- Variables
local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera
local ViewportSize = Camera.ViewportSize

-- Forward declare classes used within Interface methods
local EspObject
local ChamObject
local InstanceObject

-- Drawing Container (Uses CoreGui)
local function getDrawingContainer()
    if not CoreGui then CoreGui = game:GetService("CoreGui") end
    local containerParent = CoreGui
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
local OFFSCREEN_PADDING = 30
local BONE_CONNECTIONS = {
	{"Head", "UpperTorso"},{"UpperTorso", "LowerTorso"},{"UpperTorso", "LeftUpperArm"},{"LeftUpperArm", "LeftLowerArm"},
	{"LeftLowerArm", "LeftHand"},{"UpperTorso", "RightUpperArm"},{"RightUpperArm", "RightLowerArm"},{"RightLowerArm", "RightHand"},
	{"LowerTorso", "LeftUpperLeg"},{"LeftUpperLeg", "LeftLowerLeg"},{"LeftLowerLeg", "LeftFoot"},{"LowerTorso", "RightUpperLeg"},
	{"RightUpperLeg", "RightLowerLeg"},{"RightLowerLeg", "RightFoot"}
}
local BODY_PART_NAMES = {"Head", "UpperTorso", "LowerTorso", "LeftUpperArm", "LeftLowerArm", "LeftHand", "RightUpperArm", "RightLowerArm", "RightHand", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot", "HumanoidRootPart"}

-- ================= Helper Functions =================
-- ... (isAlive, getCharacterParts, worldToScreen, getCharacterBounds, isVisible, parseColor, applyDrawProperties remain unchanged) ...
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
            bones[partName] = part
        end
    end
    if #parts == 0 then
        for _, obj in ipairs(getChildren(character)) do
            if obj:IsA("BasePart") then
                 parts[#parts + 1] = obj
                 if not bones[obj.Name] then bones[obj.Name] = obj end
            end
        end
    end
    return parts, bones
end

local function worldToScreen(worldPos)
	local screenPos, onScreen = wtvp(Camera, worldPos)
	local depth = (Camera.CFrame.Position - worldPos).Magnitude
	return Vector2.new(floor(screenPos.X), floor(screenPos.Y)), onScreen, floor(depth), screenPos.Z > 0
end

local function getCharacterBounds(character)
    if not character then return nil, nil, nil end
    local bbCFrame, bbSize
	local success = pcall(function() bbCFrame, bbSize = character:GetBoundingBox() end)
	if not success or not bbCFrame then
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if hrp then
			bbCFrame = hrp.CFrame
			bbSize = hrp.Size
		else
			return { TopLeft = Vector2.zero, BottomRight = Vector2.zero, Size = Vector2.zero, Center = Vector2.zero, Corners = {} }, false, false
		end
	end
    local cornersPos = {}
    local minScreen = Vector2.new(huge, huge)
    local maxScreen = Vector2.new(-huge, -huge)
    local allOnScreen = true
    local anyInFront = false
    local halfSize = bbSize * 0.5
    local worldCorners = {
        bbCFrame * CFrame.new(-halfSize.X, -halfSize.Y, -halfSize.Z).Position, bbCFrame * CFrame.new(-halfSize.X,  halfSize.Y, -halfSize.Z).Position,
        bbCFrame * CFrame.new( halfSize.X,  halfSize.Y, -halfSize.Z).Position, bbCFrame * CFrame.new( halfSize.X, -halfSize.Y, -halfSize.Z).Position,
        bbCFrame * CFrame.new(-halfSize.X, -halfSize.Y,  halfSize.Z).Position, bbCFrame * CFrame.new(-halfSize.X,  halfSize.Y,  halfSize.Z).Position,
        bbCFrame * CFrame.new( halfSize.X,  halfSize.Y,  halfSize.Z).Position, bbCFrame * CFrame.new( halfSize.X, -halfSize.Y,  halfSize.Z).Position
    }
    for i = 1, #worldCorners do
        local screenPos, onScreen, _, inFront = worldToScreen(worldCorners[i])
        if not onScreen then allOnScreen = false end
        if inFront then anyInFront = true end
        cornersPos[i] = screenPos
        minScreen = min2(minScreen, screenPos)
        maxScreen = max2(maxScreen, screenPos)
    end
    minScreen = max2(minScreen, Vector2.zero)
    maxScreen = min2(maxScreen, ViewportSize)
    if not anyInFront or maxScreen.X <= minScreen.X or maxScreen.Y <= minScreen.Y then
        local centerScreen, _, _, centerInFront = worldToScreen(bbCFrame.Position)
        if centerInFront then
             minScreen = centerScreen; maxScreen = centerScreen
        else
            return { TopLeft = Vector2.zero, BottomRight = Vector2.zero, Size = Vector2.zero, Center = Vector2.zero, Corners = cornersPos }, false, false
        end
    end
    local size = maxScreen - minScreen; local center = minScreen + size * 0.5
    return { TopLeft = minScreen, BottomRight = maxScreen, Size = size, Center = center, Corners = cornersPos }, allOnScreen, anyInFront
end

local function isVisible(targetPosition, ignoreList)
    if not targetPosition then return false end
	local origin = Camera.CFrame.Position
	local direction = targetPosition - origin
	local distance = direction.Magnitude
	if distance < 0.1 then return true end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = ignoreList or {LocalPlayer.Character}
    local result = raycast(origin, direction.Unit * distance, params)
    return not result or (result.Position - targetPosition).Magnitude < 1.0
end

local function parseColor(value, defaultColor, defaultTransparency)
    if type(value) == "table" then
        local color = value[1] or defaultColor
        local transparency = value[2]
        if transparency == nil then transparency = defaultTransparency end
        return color, transparency
    elseif typeof(value) == "Color3" then
        return value, defaultTransparency
    else
        return defaultColor, defaultTransparency
    end
end

local function applyDrawProperties(drawing, props)
	for prop, value in pairs(props) do
		pcall(function() drawing[prop] = value end)
	end
end
-- ================= ESP Object (Players) =================
-- ... (EspObject definition and methods remain unchanged from v2.5) ...
EspObject = {}
EspObject.__index = EspObject

function EspObject.new(player, interface)
	local self = setmetatable({}, EspObject)
	self.Player = assert(player, "Missing argument #1 (Player expected)")
	self.Interface = assert(interface, "Missing argument #2 (table expected)")
	self.IsLocal = (player == LocalPlayer)
	self.Drawings = {}
	self.Bin = {}
    self.CharacterCache = nil
    self.BonesCache = {}
	self.LastVisible = false
    self.LastDistance = 0
    self.IsFriendly = false
	self:_ConstructDrawings()
	self.RenderConnection = RunService.RenderStepped:Connect(function()
        pcall(function() -- Wrap update/render loop
		    self:_Update()
		    self:_Render()
        end)
	end)
	return self
end

function EspObject:_CreateDrawing(class, properties)
	local drawing = Drawing.new(class)
	drawing.Visible = false
	applyDrawProperties(drawing, properties or {})
	table.insert(self.Bin, drawing)
	return drawing
end

function EspObject:_ConstructDrawings()
    local d = self.Drawings
    d.Box2D = self:_CreateDrawing("Square", { Thickness = 1, Filled = false })
    d.Box2DOutline = self:_CreateDrawing("Square", { Thickness = 3, Filled = false })
    d.Box2DFill = self:_CreateDrawing("Square", { Thickness = 1, Filled = true })
	d.CornerBoxLines = {}
	for i = 1, 8 do d.CornerBoxLines[i] = self:_CreateDrawing("Line", { Thickness = 1 }) end
	d.CornerBoxOutlines = {}
	for i = 1, 8 do d.CornerBoxOutlines[i] = self:_CreateDrawing("Line", { Thickness = 3 }) end
    d.Box3DLines = {}
    for i = 1, 12 do d.Box3DLines[i] = self:_CreateDrawing("Line", { Thickness = 1 }) end
    d.Box3DOutlines = {}
	for i = 1, 12 do d.Box3DOutlines[i] = self:_CreateDrawing("Line", { Thickness = 3 }) end
    d.SkeletonLines = {}
    for i = 1, #BONE_CONNECTIONS do d.SkeletonLines[i] = self:_CreateDrawing("Line", { Thickness = 1 }) end
	d.SkeletonOutlines = {}
	for i = 1, #BONE_CONNECTIONS do d.SkeletonOutlines[i] = self:_CreateDrawing("Line", { Thickness = 3 }) end
    d.HeadDot = self:_CreateDrawing("Circle", { Thickness = 1, Filled = true, Radius = 3 })
    d.HeadDotOutline = self:_CreateDrawing("Circle", { Thickness = 3, Filled = false, Radius = 3 })
    d.HealthBar = self:_CreateDrawing("Line", { Thickness = 4 })
    d.HealthBarBackground = self:_CreateDrawing("Line", { Thickness = 4 })
    d.HealthBarOutline = self:_CreateDrawing("Line", { Thickness = 6 })
    d.NameText = self:_CreateDrawing("Text", { Center = true, Outline = true })
    d.DistanceText = self:_CreateDrawing("Text", { Center = true, Outline = true })
    d.HealthText = self:_CreateDrawing("Text", { Center = true, Outline = true })
    d.WeaponText = self:_CreateDrawing("Text", { Center = true, Outline = true })
    d.TracerLine = self:_CreateDrawing("Line", { Thickness = 1 })
    d.TracerOutline = self:_CreateDrawing("Line", { Thickness = 3 })
    d.LookVectorLine = self:_CreateDrawing("Line", { Thickness = 1 })
    d.LookVectorOutline = self:_CreateDrawing("Line", { Thickness = 3 })
    d.OffScreenArrow = self:_CreateDrawing("Triangle", { Filled = true })
    d.OffScreenArrowOutline = self:_CreateDrawing("Triangle", { Thickness = 3, Filled = false })
end

function EspObject:Destruct()
	if self.RenderConnection then self.RenderConnection:Disconnect() self.RenderConnection = nil end
	for _, drawing in ipairs(self.Bin) do
		pcall(drawing.Remove, drawing)
	end
	clear(self.Drawings); clear(self.Bin); clear(self.BonesCache)
    self.CharacterCache = nil
end

function EspObject:_Update()
    local interface = self.Interface; local player = self.Player
    if not player or not player.Parent then self:Destruct(); return end
    self.Character = interface.getCharacter(player)
    self.IsAlive = self.Character and isAlive(player)
    self.IsFriendly = interface.isFriendly(player)
    self.Options = interface.teamSettings[self.IsFriendly and "Friendly" or "Enemy"]
    self.SharedOptions = interface.sharedSettings
    self.Enabled = self.Options.Enabled and self.IsAlive and not self.IsLocal
    if self.Enabled and #interface.Whitelist > 0 then self.Enabled = find(interface.Whitelist, player.UserId) end
    if not self.Enabled or not self.Character then self.OnScreen = false; self.Occluded = true; self:_SetAllDrawingsVisible(false); return end
    local health, maxHealth = interface.getHealth(player); self.Health = health or 0; self.MaxHealth = maxHealth or 100
    self.WeaponName = interface.getWeapon(player) or "N/A"
    local head = self.Character:FindFirstChild("Head"); local primaryPart = self.Character.PrimaryPart or self.Character:FindFirstChild("HumanoidRootPart") or head
    if not primaryPart then self.OnScreen = false; self.Occluded = true; self:_SetAllDrawingsVisible(false); return end
    self.HeadPosition = head and head.Position or primaryPart.Position
    local bounds, allCornersOnScreen, anyCornerInFront = getCharacterBounds(self.Character); self.Bounds = bounds
    self.OnScreen = anyCornerInFront and (self.Bounds.Size.X > 1 and self.Bounds.Size.Y > 1)
	self.Distance = (Camera.CFrame.Position - primaryPart.Position).Magnitude
	if self.SharedOptions.LimitDistance and self.Distance > self.SharedOptions.MaxDistance then self.OnScreen = false end
    if self.OnScreen and self.Options.UseVisibilityCheck and self.HeadPosition then
        self.Occluded = not isVisible(self.HeadPosition, {LocalPlayer.Character, self.Character})
    else
        self.Occluded = not self.OnScreen or (not self.Options.UseVisibilityCheck and self.OnScreen)
    end
    self.LastVisible = not self.Occluded
    if not self.OnScreen and self.Options.OffScreenArrow.Enabled and primaryPart then
		local pointToObject = Camera.CFrame:PointToObjectSpace(primaryPart.Position)
		if pointToObject.Z < 0 then
			local screenPoint = Vector2.new(pointToObject.X / -pointToObject.Z * (ViewportSize.X/2), pointToObject.Y / -pointToObject.Z * (ViewportSize.Y/2)) * Vector2.new(1,-1)
        	self.OffScreenDirection = screenPoint.Unit
		else
			local camPos = Camera.CFrame.Position; local targetPos = primaryPart.Position
			local diff = Vector3.new(targetPos.X, camPos.Y, targetPos.Z) - Vector3.new(camPos.X, camPos.Y, camPos.Z)
			local localDiff = Camera.CFrame:VectorToObjectSpace(diff)
			self.OffScreenDirection = Vector2.new(localDiff.X, -localDiff.Z).Unit
		end
    else
        self.OffScreenDirection = nil
    end
    if self.Character ~= self.CharacterCache then _, self.BonesCache = getCharacterParts(self.Character); self.CharacterCache = self.Character end
end

function EspObject:_SetAllDrawingsVisible(visible)
    for _, drawing in ipairs(self.Bin) do if drawing and drawing.Visible ~= visible then drawing.Visible = visible end end
end

function EspObject:_GetColor(colorOptionName)
    local opt = self.Options[colorOptionName]; if not opt then return Color3.new(1,1,1), 1 end
    local colorValue = self.Occluded and opt.OccludedColor or opt.VisibleColor
    if self.SharedOptions.UseTeamColor and not opt.IgnoreTeamColor then colorValue = self.IsFriendly and self.SharedOptions.FriendlyTeamColor or self.SharedOptions.EnemyTeamColor end
    return parseColor(colorValue, Color3.new(1,1,1), 0)
end

function EspObject:_GetOutlineColor(outlineColorOptionName)
    local opt = self.Options[outlineColorOptionName]; if not opt then return Color3.new(0,0,0), 0 end
    local colorValue = opt.Color
    if self.SharedOptions.UseTeamColor and opt.UseTeamColorForOutline then colorValue = self.IsFriendly and self.SharedOptions.FriendlyTeamColor or self.SharedOptions.EnemyTeamColor end
    return parseColor(colorValue, Color3.new(0,0,0), 0)
end

-- Render Sub-Functions (Unchanged Structurally)
function EspObject:_RenderBox2D() local d=self.Drawings; local opt=self.Options.Box2D; local enabled=self.Enabled and self.OnScreen and opt.Enabled and opt.Type=="Normal"; d.Box2D.Visible=enabled; d.Box2DOutline.Visible=enabled and opt.Outline.Enabled; d.Box2DFill.Visible=enabled and opt.Fill.Enabled; if not enabled then return end; local bounds=self.Bounds; local c,t=self:_GetColor("Box2D"); local oc,ot=self:_GetOutlineColor("Box2DOutline"); local fc,ft=self:_GetColor("Box2DFill"); applyDrawProperties(d.Box2D,{Position=bounds.TopLeft,Size=bounds.Size,Color=c,Transparency=t,Thickness=opt.Thickness}); if d.Box2DOutline.Visible then applyDrawProperties(d.Box2DOutline,{Position=bounds.TopLeft,Size=bounds.Size,Color=oc,Transparency=ot,Thickness=opt.Outline.Thickness}) end; if d.Box2DFill.Visible then applyDrawProperties(d.Box2DFill,{Position=bounds.TopLeft,Size=bounds.Size,Color=fc,Transparency=ft+opt.Fill.TransparencyModifier}) end end
function EspObject:_RenderCornerBox2D() local d=self.Drawings; local opt=self.Options.Box2D; local enabled=self.Enabled and self.OnScreen and opt.Enabled and opt.Type=="Corner"; local mv=enabled; local ov=enabled and opt.Outline.Enabled; for i=1,8 do d.CornerBoxLines[i].Visible=false; d.CornerBoxOutlines[i].Visible=false end; if not enabled then return end; local b=self.Bounds; local s=b.Size; if s.X<1 or s.Y<1 then return end; local cl=math.min(s.X,s.Y)*opt.CornerLengthRatio; cl=math.max(2,cl); local tl,tr,bl,br=b.TopLeft, b.TopLeft+Vector2.new(s.X,0), b.TopLeft+Vector2.new(0,s.Y), b.BottomRight; local p={{From=tl,To=tl+Vector2.new(cl,0)},{From=tl,To=tl+Vector2.new(0,cl)},{From=tr,To=tr-Vector2.new(cl,0)},{From=tr,To=tr+Vector2.new(0,cl)},{From=bl,To=bl+Vector2.new(cl,0)},{From=bl,To=bl-Vector2.new(0,cl)},{From=br,To=br-Vector2.new(cl,0)},{From=br,To=br-Vector2.new(0,cl)}}; local c,t=self:_GetColor("Box2D"); local oc,ot=self:_GetOutlineColor("Box2DOutline"); for i=1,8 do local l=d.CornerBoxLines[i]; l.Visible=mv; if mv then applyDrawProperties(l,{From=p[i].From,To=p[i].To,Color=c,Transparency=t,Thickness=opt.Thickness}) end end; if ov then for i=1,8 do local o=d.CornerBoxOutlines[i]; o.Visible=true; applyDrawProperties(o,{From=p[i].From,To=p[i].To,Color=oc,Transparency=ot,Thickness=opt.Outline.Thickness}) end end end
function EspObject:_RenderBox3D() local d=self.Drawings; local opt=self.Options.Box3D; local enabled=self.Enabled and self.OnScreen and opt.Enabled; for i=1,12 do d.Box3DLines[i].Visible=false; d.Box3DOutlines[i].Visible=false end; if not enabled or not self.Bounds or not self.Bounds.Corners or #self.Bounds.Corners~=8 then return end; local cn=self.Bounds.Corners; local c,t=self:_GetColor("Box3D"); local oc,ot=self:_GetOutlineColor("Box3DOutline"); local co={{1,2},{2,3},{3,4},{4,1},{5,6},{6,7},{7,8},{8,5},{1,5},{2,6},{3,7},{4,8}}; for i=1,12 do local l=d.Box3DLines[i]; l.Visible=true; local con=co[i]; applyDrawProperties(l,{From=cn[con[1]],To=cn[con[2]],Color=c,Transparency=t,Thickness=opt.Thickness}) end; if opt.Outline.Enabled then for i=1,12 do local o=d.Box3DOutlines[i]; o.Visible=true; local con=co[i]; applyDrawProperties(o,{From=cn[con[1]],To=cn[con[2]],Color=oc,Transparency=ot,Thickness=opt.Outline.Thickness}) end end end
function EspObject:_RenderSkeleton() local d=self.Drawings; local opt=self.Options.Skeleton; local enabled=self.Enabled and self.OnScreen and opt.Enabled; for i=1,#BONE_CONNECTIONS do d.SkeletonLines[i].Visible=false; d.SkeletonOutlines[i].Visible=false end; if not enabled or not self.Character then return end; local c,t=self:_GetColor("Skeleton"); local oc,ot=self:_GetOutlineColor("SkeletonOutline"); local li=1; for _,conn in ipairs(BONE_CONNECTIONS) do local p1n,p2n=conn[1],conn[2]; local p1=self.BonesCache[p1n]; local p2=self.BonesCache[p2n]; if p1 and p2 and li<=#d.SkeletonLines then local pos1,os1,_,if1=worldToScreen(p1.Position); local pos2,os2,_,if2=worldToScreen(p2.Position); if if1 and if2 then local l=d.SkeletonLines[li]; l.Visible=true; applyDrawProperties(l,{From=pos1,To=pos2,Color=c,Transparency=t,Thickness=opt.Thickness}); if opt.Outline.Enabled and li<=#d.SkeletonOutlines then local o=d.SkeletonOutlines[li]; o.Visible=true; applyDrawProperties(o,{From=pos1,To=pos2,Color=oc,Transparency=ot,Thickness=opt.Outline.Thickness}) end; li+=1 end end; if li>#d.SkeletonLines then break end end end
function EspObject:_RenderHeadDot() local d=self.Drawings; local opt=self.Options.HeadDot; local enabled=self.Enabled and self.OnScreen and opt.Enabled; d.HeadDot.Visible=enabled; d.HeadDotOutline.Visible=enabled and opt.Outline.Enabled; if not enabled or not self.Character then return end; local h=self.BonesCache["Head"]; if not h then return end; local hp2d,os,_,if_=worldToScreen(h.Position); if not os or not if_ then d.HeadDot.Visible=false; d.HeadDotOutline.Visible=false; return end; local c,t=self:_GetColor("HeadDot"); local oc,ot=self:_GetOutlineColor("HeadDotOutline"); applyDrawProperties(d.HeadDot,{Position=hp2d,Color=c,Transparency=t,Radius=opt.Radius,Filled=opt.Filled,NumSides=opt.NumSides,Thickness=opt.Thickness}); if d.HeadDotOutline.Visible then applyDrawProperties(d.HeadDotOutline,{Position=hp2d,Color=oc,Transparency=ot,Radius=opt.Radius,Thickness=opt.Outline.Thickness,Filled=false,NumSides=opt.NumSides}) end end
function EspObject:_RenderHealthBar() local d=self.Drawings; local opt=self.Options.HealthBar; local enabled=self.Enabled and self.OnScreen and opt.Enabled; d.HealthBar.Visible=enabled; d.HealthBarBackground.Visible=enabled and opt.Background.Enabled; d.HealthBarOutline.Visible=enabled and opt.Outline.Enabled; if not enabled then return end; local b=self.Bounds; if b.Size.X<1 or b.Size.Y<1 then return end; local hp=clamp(self.Health/self.MaxHealth,0,1); local bc=lerpColor(opt.ColorDying,opt.ColorHealthy,hp); local bt=self.Occluded and opt.OccludedTransparency or opt.VisibleTransparency; local bgc,bgt=parseColor(opt.Background.Color,Color3.new(0,0,0),0.5); local oc,ot=parseColor(opt.Outline.Color,Color3.new(0,0,0),0); local bsz=b.Size; local bth=opt.Thickness; local oth=opt.Outline.Thickness; local pad=opt.Padding; local f,t,bf,bt_,of,ot_; if opt.Orientation=="Vertical" then local sx=b.TopLeft.X-pad-(oth/2); local sy=b.TopLeft.Y; local ey=b.BottomRight.Y; bf=Vector2.new(sx,sy); bt_=Vector2.new(sx,ey); f=Vector2.new(sx,lerp(ey,sy,hp)); t=Vector2.new(sx,ey); of=bf-Vector2.new(0,(oth-bth)/2); ot_=bt_+Vector2.new(0,(oth-bth)/2) else local sy=b.TopLeft.Y-pad-(oth/2); local sx=b.TopLeft.X; local ex=b.BottomRight.X; bf=Vector2.new(sx,sy); bt_=Vector2.new(ex,sy); f=Vector2.new(sx,sy); t=Vector2.new(lerp(sx,ex,hp),sy); of=bf-Vector2.new((oth-bth)/2,0); ot_=bt_+Vector2.new((oth-bth)/2,0) end; if d.HealthBarOutline.Visible then applyDrawProperties(d.HealthBarOutline,{From=of,To=ot_,Color=oc,Transparency=ot,Thickness=oth}) end; if d.HealthBarBackground.Visible then applyDrawProperties(d.HealthBarBackground,{From=bf,To=bt_,Color=bgc,Transparency=bgt,Thickness=bth}) end; if hp>0.001 then d.HealthBar.Visible=true; applyDrawProperties(d.HealthBar,{From=f,To=t,Color=bc,Transparency=bt,Thickness=bth}) else d.HealthBar.Visible=false end end
function EspObject:_RenderTextElements() local d=self.Drawings; local so=self.SharedOptions; local b=self.Bounds; if not self.OnScreen or b.Size.X<1 or b.Size.Y<1 then d.NameText.Visible=false; d.DistanceText.Visible=false; d.HealthText.Visible=false; d.WeaponText.Visible=false; return end; local cyoT=0; local cyoB=0; local bp={}; local function rt(en,dr,tv,bP,va,ha) local o=self.Options[en]; local e=self.Enabled and self.OnScreen and o.Enabled; dr.Visible=e; if not e or not tv or tv=="" then return 0 end; local c,t=self:_GetColor(en); local oc,ot=self:_GetOutlineColor(en.."Outline"); bp.Size=o.Size or so.TextSize; bp.Font=o.Font or so.TextFont; bp.Color=c; bp.Transparency=t; bp.Outline=o.Outline.Enabled; bp.OutlineColor=oc; dr.Text=tv; local tb=dr.TextBounds; if tb.X==0 and tb.Y==0 then return 0 end; local fp=bP; if ha=="Center" then fp=fp-Vector2.new(tb.X*0.5,0) elseif ha=="Right" then fp=fp-Vector2.new(tb.X,0) end; applyDrawProperties(dr,bp); dr.Position=fp; return tb.Y+so.TextSpacing end; local nO=self.Options.NameText; local nbP=b.TopLeft+Vector2.new(b.Size.X*0.5, -(nO.Size or so.TextSize)-nO.VPadding-cyoT); local nH=rt("NameText",d.NameText,self.Player.DisplayName,nbP,"Top","Center"); cyoT+=nH; local hO=self.Options.HealthText; local hbP; local hH=0; if hO.Enabled then local fs=hO.Format; local hs=fs:gsub("{Health}",tostring(round(self.Health))):gsub("{MaxHealth}",tostring(self.MaxHealth)); if self.Options.HealthBar.Enabled and hO.AttachToBar and d.HealthBar.Visible then local brD=d.HealthBar; local brO=self.Options.HealthBar; if brO.Orientation=="Vertical" then hbP=Vector2.new(brD.From.X-hO.HPadding,brD.From.Y); hH=rt("HealthText",d.HealthText,hs,hbP,"Middle","Right") else hbP=Vector2.new(brD.To.X+hO.HPadding,brD.To.Y); hH=rt("HealthText",d.HealthText,hs,hbP,"Middle","Left") end else hbP=b.TopLeft+Vector2.new(b.Size.X*0.5, -(nO.Size or so.TextSize)-nO.VPadding-cyoT); hH=rt("HealthText",d.HealthText,hs,hbP,"Top","Center") end; cyoT+=hH else d.HealthText.Visible=false end; local dsO=self.Options.DistanceText; local dbP=b.BottomLeft+Vector2.new(b.Size.X*0.5, dsO.VPadding+cyoB); local dsH=0; if dsO.Enabled then local fs=dsO.Format; local dss=fs:gsub("{Distance}",tostring(round(self.Distance))); dsH=rt("DistanceText",d.DistanceText,dss,dbP,"Bottom","Center") else d.DistanceText.Visible=false end; cyoB+=dsH; local wpO=self.Options.WeaponText; local wbP=b.BottomLeft+Vector2.new(b.Size.X*0.5, wpO.VPadding+cyoB); local wpH=0; if wpO.Enabled then local fs=wpO.Format; local wps=fs:gsub("{Weapon}",self.WeaponName); wpH=rt("WeaponText",d.WeaponText,wps,wbP,"Bottom","Center") else d.WeaponText.Visible=false end; cyoB+=wpH end
function EspObject:_RenderTracer() local d=self.Drawings; local opt=self.Options.Tracer; local enabled=self.Enabled and self.OnScreen and opt.Enabled; d.TracerLine.Visible=enabled; d.TracerOutline.Visible=enabled and opt.Outline.Enabled; if not enabled then return end; local b=self.Bounds; local c,t=self:_GetColor("Tracer"); local oc,ot=self:_GetOutlineColor("TracerOutline"); local op; local oo=opt.Origin; if oo=="Top" then op=Vector2.new(ViewportSize.X*0.5,0) elseif oo=="Bottom" then op=Vector2.new(ViewportSize.X*0.5,ViewportSize.Y) elseif oo=="Mouse" then op=UserInputService:GetMouseLocation() else op=ViewportSize*0.5 end; local tp; local to=opt.Target; local tpt=nil; if to=="Head" then tpt=self.BonesCache["Head"] elseif to=="Torso" then tpt=self.BonesCache["UpperTorso"] or self.BonesCache["LowerTorso"] elseif to=="Feet" then tpt=self.BonesCache["LeftFoot"] or self.BonesCache["RightFoot"] end; if tpt then local sp,os,_,if_=worldToScreen(tpt.Position); if os and if_ then tp=sp end end; if not tp then if b and b.BottomLeft then tp=b.BottomLeft+Vector2.new(b.Size.X*0.5,0) else d.TracerLine.Visible=false; d.TracerOutline.Visible=false; return end end; applyDrawProperties(d.TracerLine,{From=op,To=tp,Color=c,Transparency=t,Thickness=opt.Thickness}); if d.TracerOutline.Visible then applyDrawProperties(d.TracerOutline,{From=op,To=tp,Color=oc,Transparency=ot,Thickness=opt.Outline.Thickness}) end end
function EspObject:_RenderLookVector() local d=self.Drawings; local opt=self.Options.LookVector; local enabled=self.Enabled and self.OnScreen and opt.Enabled; d.LookVectorLine.Visible=enabled; d.LookVectorOutline.Visible=enabled and opt.Outline.Enabled; if not enabled or not self.Character then return end; local h=self.BonesCache["Head"]; if not h then return end; local hcf=h.CFrame; local spw=hcf.Position; local epw=spw+hcf.LookVector*opt.Length; local sp,sos,_,sif=worldToScreen(spw); local ep,eos,_,eif=worldToScreen(epw); if not sos or not sif then d.LookVectorLine.Visible=false; d.LookVectorOutline.Visible=false; return end; local c,t=self:_GetColor("LookVector"); local oc,ot=self:_GetOutlineColor("LookVectorOutline"); applyDrawProperties(d.LookVectorLine,{From=sp,To=ep,Color=c,Transparency=t,Thickness=opt.Thickness}); if d.LookVectorOutline.Visible then applyDrawProperties(d.LookVectorOutline,{From=sp,To=ep,Color=oc,Transparency=ot,Thickness=opt.Outline.Thickness}) end end
function EspObject:_RenderOffScreenArrow() local d=self.Drawings; local opt=self.Options.OffScreenArrow; local enabled=self.Enabled and not self.OnScreen and opt.Enabled and self.OffScreenDirection; d.OffScreenArrow.Visible=enabled; d.OffScreenArrowOutline.Visible=enabled and opt.Outline.Enabled; if not enabled then return end; local dir=self.OffScreenDirection; local ang=atan2(dir.Y,dir.X); local cp=ViewportSize*0.5+dir*opt.Radius; cp=Vector2.new(clamp(cp.X,OFFSCREEN_PADDING,ViewportSize.X-OFFSCREEN_PADDING),clamp(cp.Y,OFFSCREEN_PADDING,ViewportSize.Y-OFFSCREEN_PADDING)); local sz=opt.Size; local car=25*(pi/180); local ca=cos(ang); local sa=sin(ang); local p1=cp; local bd=sz*1.5; local hw=sz; local bc=p1-Vector2.new(ca,sa)*bd; local rv=Vector2.new(sa,-ca); local p2=bc+rv*hw; local p3=bc-rv*hw; local c,t=self:_GetColor("OffScreenArrow"); local oc,ot=self:_GetOutlineColor("OffScreenArrowOutline"); applyDrawProperties(d.OffScreenArrow,{PointA=p1,PointB=p2,PointC=p3,Color=c,Transparency=t,Filled=true}); if d.OffScreenArrowOutline.Visible then applyDrawProperties(d.OffScreenArrowOutline,{PointA=p1,PointB=p2,PointC=p3,Color=oc,Transparency=ot,Thickness=opt.Outline.Thickness,Filled=false}) end end
function EspObject:_Render() if not self.Enabled then if self.Drawings.Box2D and self.Drawings.Box2D.Visible then self:_SetAllDrawingsVisible(false) end; return end; if self.OnScreen then self:_RenderBox2D(); self:_RenderCornerBox2D(); self:_RenderBox3D(); self:_RenderSkeleton(); self:_RenderHeadDot(); self:_RenderHealthBar(); self:_RenderTextElements(); self:_RenderTracer(); self:_RenderLookVector(); if self.Drawings.OffScreenArrow and self.Drawings.OffScreenArrow.Visible then self.Drawings.OffScreenArrow.Visible=false; self.Drawings.OffScreenArrowOutline.Visible=false end else if self.Drawings.Box2D and self.Drawings.Box2D.Visible then self:_SetAllDrawingsVisible(false) end; self:_RenderOffScreenArrow() end end

-- ================= Cham Object (Highlights) =================
-- ... (ChamObject definition and methods remain unchanged from v2.5) ...
ChamObject = {}
ChamObject.__index = ChamObject
function ChamObject.new(player, interface) local self=setmetatable({},ChamObject); self.Player=player; self.Interface=interface; self.Highlight=Instance.new("Highlight"); self.Highlight.Name="EspCham_"..(player and player.Name or "InvalidPlayer"); self.Highlight.Adornee=nil; self.Highlight.Enabled=false; self.Highlight.Parent=DrawingContainer; self.UpdateConnection=RunService.Heartbeat:Connect(function() pcall(self._Update,self) end); return self end
function ChamObject:Destruct() if self.UpdateConnection then self.UpdateConnection:Disconnect() self.UpdateConnection=nil end; if self.Highlight then pcall(self.Highlight.Destroy,self.Highlight) self.Highlight=nil end; clear(self) end
function ChamObject:_Update() local player=self.Player; local interface=self.Interface; if not player or not player.Parent then self:Destruct(); return end; local character=interface.getCharacter(player); local isFriendly=interface.isFriendly(player); local options=interface.teamSettings[isFriendly and "Friendly" or "Enemy"].Chams; local sharedOptions=interface.sharedSettings; local isAlive=character and isAlive(player); local isLocal=(player==LocalPlayer); local enabled=options.Enabled and isAlive and not isLocal; if enabled and #interface.Whitelist>0 then enabled=find(interface.Whitelist,player.UserId) end; if enabled and character and sharedOptions.LimitDistance then local primary=character.PrimaryPart or character:FindFirstChild("HumanoidRootPart"); if primary then local dist=(Camera.CFrame.Position-primary.Position).Magnitude; if dist>sharedOptions.MaxDistance then enabled=false end else enabled=false end end; if not character then enabled=false end; if self.Highlight then self.Highlight.Enabled=enabled; if enabled then if self.Highlight.Adornee~=character then self.Highlight.Adornee=character end; local fvc,fvt=parseColor(options.FillColor.VisibleColor,Color3.fromRGB(255,0,0),0.5); local foc,fot=parseColor(options.FillColor.OccludedColor,Color3.fromRGB(0,0,255),0.5); local ovc,ovt=parseColor(options.OutlineColor.VisibleColor,Color3.fromRGB(255,255,255),0); local ooc,oot=parseColor(options.OutlineColor.OccludedColor,Color3.fromRGB(200,200,200),0); if options.DepthMode==Enum.HighlightDepthMode.AlwaysOnTop then self.Highlight.FillColor=foc; self.Highlight.FillTransparency=fot; self.Highlight.OutlineColor=ooc; self.Highlight.OutlineTransparency=oot else self.Highlight.FillColor=fvc; self.Highlight.FillTransparency=fvt; self.Highlight.OutlineColor=ovc; self.Highlight.OutlineTransparency=ovt end; self.Highlight.DepthMode=options.DepthMode else if self.Highlight.Adornee then self.Highlight.Adornee=nil end end end end

-- ================= Instance ESP Object =================
-- ... (InstanceObject definition and methods remain unchanged from v2.5) ...
InstanceObject = {}
InstanceObject.__index = InstanceObject
function InstanceObject.new(instance, options, interface) local self=setmetatable({},InstanceObject); self.Instance=assert(instance,"Missing argument #1 (Instance Expected)"); self.Options=options or {}; self.Interface=interface; self:_InitializeDefaults(); self.DrawingText=Drawing.new("Text"); self.DrawingText.Visible=false; self.DrawingText.Center=true; self.RenderConnection=RunService.RenderStepped:Connect(function() pcall(self._Render,self) end); return self end
function InstanceObject:_InitializeDefaults() local opt=self.Options; local shared=self.Interface.sharedSettings; if opt.Enabled==nil then opt.Enabled=true end; if opt.UseVisibilityCheck==nil then opt.UseVisibilityCheck=true end; if opt.RequiresLineOfSight==nil then opt.RequiresLineOfSight=false end; opt.Format=opt.Format or "{Name}\n[{Distance}m]"; opt.Color=opt.Color or {VisibleColor={Color3.new(1,1,1),0},OccludedColor={Color3.new(0.8,0.8,0.8),0.1}}; opt.Outline=opt.Outline or {Enabled=true,Color={Color3.new(0,0,0),0},Thickness=1}; opt.Text=opt.Text or {Size=shared.TextSize,Font=shared.TextFont}; opt.MaxDistance=opt.MaxDistance or shared.MaxDistance end
function InstanceObject:Destruct() if self.RenderConnection then self.RenderConnection:Disconnect() self.RenderConnection=nil end; if self.DrawingText then pcall(self.DrawingText.Remove,self.DrawingText) self.DrawingText=nil end; clear(self) end
function InstanceObject:UpdateOptions(newOptions) for key,value in pairs(newOptions) do if type(self.Options[key])=="table" and type(value)=="table" then for k2,v2 in pairs(value) do self.Options[key][k2]=v2 end else self.Options[key]=value end end; self:_InitializeDefaults() end
function InstanceObject:_Render() local instance=self.Instance; local opt=self.Options; local shared=self.Interface.sharedSettings; local text=self.DrawingText; if not instance or not instance.Parent or not opt.Enabled or not text then if text then text.Visible=false end; return end; local worldPosition; local success,result=pcall(function() if instance:IsA("Model") then local modelBBcenter=instance:GetBoundingBox().Position; worldPosition=modelBBcenter elseif instance:IsA("BasePart") then worldPosition=instance.Position else local pivot=getPivot(instance); worldPosition=pivot and pivot.Position end end); if not success or not worldPosition then text.Visible=false; return end; local screenPos,onScreen,distance,inFront=worldToScreen(worldPosition); local isTooFar=distance>opt.MaxDistance; if not onScreen or not inFront or isTooFar then text.Visible=false; return end; local occluded=false; if opt.UseVisibilityCheck then local ignoreList={LocalPlayer.Character}; if instance:IsA("Model") or instance:IsA("BasePart") then table.insert(ignoreList,instance) end; occluded=not isVisible(worldPosition,ignoreList) end; if opt.RequiresLineOfSight and occluded then text.Visible=false; return end; text.Visible=true; local colorValue=occluded and opt.Color.OccludedColor or opt.Color.VisibleColor; local mainColor,mainTrans=parseColor(colorValue,Color3.new(1,1,1),0); local outlineColor,outlineTrans=parseColor(opt.Outline.Color,Color3.new(0,0,0),0); local formatString=opt.Format; local formattedText=formatString:gsub("{Name}",instance.Name):gsub("{Distance}",tostring(round(distance))):gsub("{Position}",string.format("%.1f, %.1f, %.1f",worldPosition.X,worldPosition.Y,worldPosition.Z)):gsub("{Class}",instance.ClassName); text.Text=formattedText; local textBounds=text.TextBounds; if textBounds.X==0 and textBounds.Y==0 and #formattedText>0 then else applyDrawProperties(text,{Position=screenPos-Vector2.new(0,textBounds.Y*0.5),Color=mainColor,Transparency=mainTrans,Size=opt.Text.Size,Font=opt.Text.Font,Outline=opt.Outline.Enabled,OutlineColor=outlineColor}); if text.OutlineThickness then text.OutlineThickness=opt.Outline.Thickness end end end

-- ================= ESP Interface (Main Controller) =================
-- Initial table definition with non-function properties
local EspInterface = {
    _IsLoaded = false,
    _ObjectCache = {},
    _PlayerConnections = {},
    _InstanceCleanupConnections = {},

    sharedSettings = {
        TextSize = 14, TextFont = Enum.Font.GothamSemibold, TextSpacing = 2, LimitDistance = true, MaxDistance = 500, UseTeamColor = false,
        FriendlyTeamColor = { Color3.fromRGB(0, 170, 255), 0 }, EnemyTeamColor = { Color3.fromRGB(255, 80, 80), 0 },
    },

    teamSettings = {
        Enemy = {
            Enabled = true, UseVisibilityCheck = true,
            Box2D = { Enabled = true, Type = "Corner", Thickness = 1, CornerLengthRatio = 0.15, VisibleColor = { Color3.fromRGB(255, 50, 50), 0 }, OccludedColor = { Color3.fromRGB(200, 50, 50), 0.3 }, IgnoreTeamColor = false, Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } }, Fill = { Enabled = false, TransparencyModifier = 0.6, VisibleColor = { Color3.fromRGB(255, 50, 50), 0 }, OccludedColor = { Color3.fromRGB(200, 50, 50), 0.3 } } },
            Box3D = { Enabled = false, Thickness = 1, VisibleColor = { Color3.fromRGB(255, 50, 50), 0 }, OccludedColor = { Color3.fromRGB(200, 50, 50), 0.3 }, IgnoreTeamColor = false, Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } } },
            Skeleton = { Enabled = false, Thickness = 1, VisibleColor = { Color3.fromRGB(255, 150, 0), 0 }, OccludedColor = { Color3.fromRGB(200, 120, 0), 0.4 }, IgnoreTeamColor = true, Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } } },
			HeadDot = { Enabled = false, Radius = 4, Thickness = 1, Filled = true, NumSides = 12, VisibleColor = { Color3.fromRGB(255, 255, 0), 0 }, OccludedColor = { Color3.fromRGB(200, 200, 0), 0.3 }, IgnoreTeamColor = true, Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } } },
            HealthBar = { Enabled = true, Orientation = "Vertical", Thickness = 4, Padding = 5, ColorHealthy = Color3.fromRGB(0, 255, 0), ColorDying = Color3.fromRGB(255, 0, 0), VisibleTransparency = 0, OccludedTransparency = 0.4, Background = { Enabled = true, Color = { Color3.new(0,0,0), 0.5 } }, Outline = { Enabled = true, Thickness = 6, Color = { Color3.new(0,0,0), 0 } } },
            NameText = { Enabled = true, VPadding = 2, Size = 14, Font = Enum.Font.GothamSemibold, Format = "{Name}", VisibleColor = { Color3.new(1,1,1), 0 }, OccludedColor = { Color3.new(0.8, 0.8, 0.8), 0.1 }, IgnoreTeamColor = true, Outline = { Enabled = true, Color = { Color3.new(0,0,0), 0 } } },
            DistanceText = { Enabled = true, VPadding = 2, Size = 12, Font = Enum.Font.Gotham, Format = "[{Distance}m]", VisibleColor = { Color3.new(1,1,1), 0 }, OccludedColor = { Color3.new(0.8, 0.8, 0.8), 0.1 }, IgnoreTeamColor = true, Outline = { Enabled = true, Color = { Color3.new(0,0,0), 0 } } },
			HealthText = { Enabled = false, AttachToBar = true, HPadding = 4, Size = 11, Font = Enum.Font.GothamBold, Format = "{Health}HP", VisibleColor = { Color3.new(1,1,1), 0 }, OccludedColor = { Color3.new(0.8, 0.8, 0.8), 0.1 }, IgnoreTeamColor = true, Outline = { Enabled = true, Color = { Color3.new(0,0,0), 0 } } },
            WeaponText = { Enabled = false, VPadding = 0, Size = 12, Font = Enum.Font.Gotham, Format = "{Weapon}", VisibleColor = { Color3.new(1,1,1), 0 }, OccludedColor = { Color3.new(0.8, 0.8, 0.8), 0.1 }, IgnoreTeamColor = true, Outline = { Enabled = true, Color = { Color3.new(0,0,0), 0 } } },
            Tracer = { Enabled = false, Thickness = 1, Origin = "Bottom", Target = "Box Bottom Center", VisibleColor = { Color3.fromRGB(255, 50, 50), 0 }, OccludedColor = { Color3.fromRGB(200, 50, 50), 0.3 }, IgnoreTeamColor = false, Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } } },
            LookVector = { Enabled = false, Thickness = 1, Length = 10, VisibleColor = { Color3.fromRGB(0, 200, 255), 0 }, OccludedColor = { Color3.fromRGB(0, 150, 200), 0.3 }, IgnoreTeamColor = true, Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } } },
            OffScreenArrow = { Enabled = true, Radius = 200, Size = 15, VisibleColor = { Color3.fromRGB(255, 50, 50), 0 }, OccludedColor = { Color3.fromRGB(255, 50, 50), 0 }, IgnoreTeamColor = false, Outline = { Enabled = true, Thickness = 3, Color = { Color3.new(0,0,0), 0 } } },
            Chams = { Enabled = false, DepthMode = Enum.HighlightDepthMode.Occluded, FillColor = { VisibleColor = { Color3.fromRGB(255, 0, 0), 0.7 }, OccludedColor = { Color3.fromRGB(150, 0, 0), 0.8 } }, OutlineColor = { VisibleColor = { Color3.new(0,0,0), 0.2 }, OccludedColor = { Color3.new(0,0,0), 0.3 } } }
        },
        Friendly = {} -- Friendly settings are populated by deep copy/merge in Load()
    },

    Whitelist = {},
}

-- Define functions *after* the main table exists
function EspInterface.getWeapon(player)
    local character = player and EspInterface.getCharacter(player) -- Use EspInterface here now
    if character then
        local tool = character:FindFirstChildOfClass("Tool")
        if tool then return tool.Name end
    end
    return "Unarmed"
end

function EspInterface.isFriendly(player)
    if not LocalPlayer or not player then return false end
    return player.Team and LocalPlayer.Team and player.Team == LocalPlayer.Team
end

function EspInterface.getTeamColor(player)
    return player and player.Team and player.Team.TeamColor and player.Team.TeamColor.Color
end

function EspInterface.getCharacter(player)
    return player and player.Character
end

function EspInterface.getHealth(player)
    local character = player and EspInterface.getCharacter(player)
    local humanoid = character and findFirstChildOfClass(character, "Humanoid")
    if humanoid then
        return humanoid.Health, humanoid.MaxHealth
    end
    return 100, 100
end

function EspInterface._DeepCopy(original)
    local copy = {}
    for k, v in pairs(original) do
        if type(v) == "table" then
            copy[k] = EspInterface._DeepCopy(v)
        else
            copy[k] = v
        end
    end
    return copy
end

function EspInterface._DeepMerge(destination, source)
	if not source then return destination end -- Handle nil source
    for k, v in pairs(source) do
        if type(v) == "table" and type(destination[k]) == "table" then
            EspInterface._DeepMerge(destination[k], v)
        else
            destination[k] = v
        end
    end
    return destination
end

function EspInterface._CreatePlayerObjects(player)
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
end

function EspInterface._RemovePlayerObjects(player)
    local objects = EspInterface._ObjectCache[player]
    if objects then
        for _, obj in ipairs(objects) do
            pcall(obj.Destruct, obj)
        end
        EspInterface._ObjectCache[player] = nil
    end
end

function EspInterface._SetupInstanceCleanup(instance, objRef)
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
end

function EspInterface.Load()
    if EspInterface._IsLoaded then warn("ESP Library already loaded.") return end
    print("Loading Advanced ESP Library...")

    -- Populate Friendly settings using deep copy/merge
	local friendlyDefaults = EspInterface._DeepCopy(EspInterface.teamSettings.Enemy) -- Start with Enemy copy
    -- Manually define specific Friendly overrides here before merging if the structure is different
    -- For now, assuming the structure defined in the initial table was just for documentation/defaults
    local friendlyOverrides = {
        Enabled = false, -- Default friendly off
        Box2D = { Enabled = true, Type = "Normal", VisibleColor = { Color3.fromRGB(0, 170, 255), 0 }, OccludedColor = { Color3.fromRGB(0, 120, 200), 0.4 }, Fill = { Enabled = false, TransparencyModifier = 0.7, VisibleColor = { Color3.fromRGB(0, 170, 255), 0 }, OccludedColor = { Color3.fromRGB(0, 120, 200), 0.4 } } },
        Box3D = { Enabled = false }, Skeleton = { Enabled = false }, HeadDot = { Enabled = false },
        DistanceText = { Enabled = false }, HealthText = { Enabled = false }, WeaponText = { Enabled = false },
        Tracer = { Enabled = false }, LookVector = { Enabled = false },
        OffScreenArrow = { Enabled = false, VisibleColor = { Color3.fromRGB(0, 170, 255), 0 }, OccludedColor = { Color3.fromRGB(0, 170, 255), 0 } },
        Chams = { Enabled = false, FillColor = { VisibleColor = { Color3.fromRGB(0, 170, 255), 0.7 }, OccludedColor = { Color3.fromRGB(0, 120, 200), 0.8 } } }
    }
	EspInterface.teamSettings.Friendly = EspInterface._DeepMerge(friendlyDefaults, friendlyOverrides)


    EspInterface.Unload(true) -- Clear previous state silently

    for _, player in ipairs(Players:GetPlayers()) do
        EspInterface._CreatePlayerObjects(player)
    end

    EspInterface._PlayerConnections.Added = Players.PlayerAdded:Connect(EspInterface._CreatePlayerObjects)
    EspInterface._PlayerConnections.Removing = Players.PlayerRemoving:Connect(EspInterface._RemovePlayerObjects)

    EspInterface._IsLoaded = true
    print("ESP Library Loaded Successfully.")
end

function EspInterface.Unload(silent)
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
            for _, obj in ipairs(objOrTable) do pcall(obj.Destruct, obj) end
        else
            pcall(objOrTable.Destruct, objOrTable)
        end
    end
    clear(EspInterface._ObjectCache)

    EspInterface._IsLoaded = false
    if not silent then print("ESP Library Unloaded.") end
end

function EspInterface.AddInstance(instance, options)
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
end

function EspInterface.RemoveInstance(instance)
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
end

function EspInterface.UpdateSetting(category, settingName, value)
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
            EspInterface._DeepMerge(targetTable[settingName], value) -- Use deep merge for tables
        else
            targetTable[settingName] = value -- Direct overwrite otherwise
        end
    end
end

function EspInterface.UpdateInstanceOptions(instance, newOptions)
    local obj = EspInterface._ObjectCache[instance]
    if obj and obj.UpdateOptions then
        obj:UpdateOptions(newOptions)
    else
        warn("UpdateInstanceOptions: No ESP found for instance or object doesn't support updates:", instance)
    end
end

function EspInterface.Toggle(enabled)
    EspInterface.UpdateSetting("Enemy", "Enabled", enabled)
    EspInterface.UpdateSetting("Friendly", "Enabled", enabled)
    -- Add logic here to iterate _ObjectCache and toggle Instance ESP if needed
end


return EspInterface
