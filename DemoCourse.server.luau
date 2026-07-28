--!strict
--[[
	DemoCourse.server.luau   --   NOT PART OF THE SUBMISSION
	Put this in ServerScriptService. It builds the demo place at runtime so the
	place file contains no hand-placed geometry and the course can be retuned by
	editing numbers. The submitted script is GrappleHook.client.luau only.

	Builds: a start plaza, a rising ring of towers to swing between, floating
	anchor rings, two MOVING anchors (these prove the rope tracks a moving part),
	and a finish pad.
]]

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local COURSE = {
	TowerCount = 14,
	RingRadius = 260, -- distance of the tower ring from the plaza
	RadiusGrowth = 34, -- each tower steps further out -> the course spirals
	BaseHeight = 90,
	HeightGrowth = 26, -- towers climb, so the run gains altitude
	TowerSize = Vector3.new(26, 1, 26),
	FloorY = 0,
}

local PALETTE = {
	Tower = Color3.fromRGB(58, 64, 82),
	Accent = Color3.fromRGB(120, 200, 255),
	Plaza = Color3.fromRGB(38, 42, 55),
	Finish = Color3.fromRGB(120, 255, 160),
}

local course = Instance.new("Folder")
course.Name = "GrappleCourse"
course.Parent = Workspace

-- One helper for every static part in the level: anchored, collidable, and
-- parented into the course folder. Keeps the builders below to pure layout.
local function block(name: string, size: Vector3, cf: CFrame, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Anchored = true
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = course
	return part
end

-- ---------------------------------------------------------------- ground ----
-- A large floor so a missed swing is survivable and the player can restart.
block("Floor", Vector3.new(2048, 4, 2048), CFrame.new(0, COURSE.FloorY - 2, 0), Color3.fromRGB(28, 30, 40))

-- --------------------------------------------------------------- plaza ------
local plaza = block("StartPlaza", Vector3.new(80, 4, 80), CFrame.new(0, 12, 0), PALETTE.Plaza)

local spawnPoint = Instance.new("SpawnLocation")
spawnPoint.Name = "Start"
spawnPoint.Size = Vector3.new(12, 1, 12)
spawnPoint.CFrame = CFrame.new(0, 15, 0)
spawnPoint.Anchored = true
spawnPoint.Color = PALETTE.Accent
spawnPoint.Material = Enum.Material.Neon
spawnPoint.Parent = course

-- ------------------------------------------------------------- towers -------
-- Towers are laid out on a spiral: angle steps evenly while radius and height
-- both grow, so each swing is longer and higher than the last.
local lastTowerCFrame = plaza.CFrame

for i = 1, COURSE.TowerCount do
	local angle = (i / COURSE.TowerCount) * math.pi * 2.4 -- >2pi so it overlaps into a second loop
	local radius = COURSE.RingRadius + (i - 1) * COURSE.RadiusGrowth
	local height = COURSE.BaseHeight + (i - 1) * COURSE.HeightGrowth

	local x = math.cos(angle) * radius
	local z = math.sin(angle) * radius

	-- Shaft: a tall thin column. Its TOP is the grapple target.
	local shaft = block(
		"Tower" .. i,
		Vector3.new(COURSE.TowerSize.X, height, COURSE.TowerSize.Z),
		CFrame.new(x, height * 0.5, z),
		PALETTE.Tower
	)

	-- A glowing cap makes the anchor point readable from a distance, which is
	-- most of what makes a swing course learnable.
	local cap = block(
		"TowerCap" .. i,
		Vector3.new(COURSE.TowerSize.X + 4, 2, COURSE.TowerSize.Z + 4),
		CFrame.new(x, height + 1, z),
		PALETTE.Accent
	)
	cap.Material = Enum.Material.Neon

	lastTowerCFrame = shaft.CFrame
end

-- ------------------------------------------------- floating anchor rings ----
-- Small high anchors between towers reward precise aim over the easy roof shot.
for i = 1, 8 do
	local angle = (i / 8) * math.pi * 2
	local radius = COURSE.RingRadius * 0.55
	local anchor = block(
		"SkyAnchor" .. i,
		Vector3.new(10, 10, 10),
		CFrame.new(math.cos(angle) * radius, 150 + i * 18, math.sin(angle) * radius)
			* CFrame.Angles(math.rad(45), math.rad(45), 0),
		PALETTE.Accent
	)
	anchor.Material = Enum.Material.Neon
	anchor.Transparency = 0.15
end

-- -------------------------------------------------------- moving anchors ----
-- These exist specifically to prove the rope anchors in the hit part's LOCAL
-- space: grapple one and it carries you along with no tracking code.
local movers: { { part: Part, origin: Vector3, axis: Vector3, span: number, speed: number } } = {}

local function addMover(origin: Vector3, axis: Vector3, span: number, speed: number)
	local part = block("MovingAnchor", Vector3.new(22, 3, 22), CFrame.new(origin), Color3.fromRGB(255, 190, 90))
	part.Material = Enum.Material.Neon
	table.insert(movers, { part = part, origin = origin, axis = axis, span = span, speed = speed })
end

addMover(Vector3.new(140, 170, -60), Vector3.new(1, 0, 0), 120, 0.6)
addMover(Vector3.new(-90, 230, 180), Vector3.new(0, 0, 1), 150, 0.4)

-- Driven on Heartbeat with a sine so motion is smooth and loops forever
-- without accumulating drift the way an incremented offset would.
RunService.Heartbeat:Connect(function()
	local t = time()
	for _, mover in movers do
		local offset = math.sin(t * mover.speed * math.pi) * mover.span
		mover.part.CFrame = CFrame.new(mover.origin + mover.axis * offset)
	end
end)

-- ------------------------------------------------------------- finish -------
-- The last tower's CFrame is centred on its shaft, so its Y is half the tower
-- height. Doubling it puts the pad at roof level, plus clearance above that.
local lastTop = lastTowerCFrame.Position
local finish =
	block("FinishPad", Vector3.new(50, 3, 50), CFrame.new(lastTop.X, lastTop.Y * 2 + 30, lastTop.Z), PALETTE.Finish)
finish.Material = Enum.Material.Neon

local sign = Instance.new("BillboardGui")
sign.Size = UDim2.fromScale(18, 5)
sign.StudsOffset = Vector3.new(0, 8, 0)
sign.AlwaysOnTop = true
sign.Parent = finish

local label = Instance.new("TextLabel")
label.Size = UDim2.fromScale(1, 1)
label.BackgroundTransparency = 1
label.Text = "FINISH"
label.TextColor3 = PALETTE.Finish
label.TextScaled = true
label.Font = Enum.Font.GothamBold
label.Parent = sign

-- ------------------------------------------------------------ lighting -----
Lighting.ClockTime = 17.5
Lighting.Brightness = 2.5
Lighting.ExposureCompensation = 0.2
Lighting.OutdoorAmbient = Color3.fromRGB(85, 95, 120)
Lighting.FogEnd = 2200
Lighting.FogColor = Color3.fromRGB(150, 170, 200)

if not Lighting:FindFirstChildOfClass("Atmosphere") then
	local atmosphere = Instance.new("Atmosphere")
	atmosphere.Density = 0.32
	atmosphere.Haze = 1.6
	atmosphere.Color = Color3.fromRGB(200, 215, 240)
	atmosphere.Parent = Lighting
end

if not Lighting:FindFirstChildOfClass("SunRaysEffect") then
	local rays = Instance.new("SunRaysEffect")
	rays.Intensity = 0.12
	rays.Parent = Lighting
end
