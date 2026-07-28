-- Connected Discord-GitHub
--!strict
--[[
	GrappleHook.client.luau
	Grappling hook with real pendulum swing physics, in one self-contained
	LocalScript. Drop it in StarterPlayer > StarterPlayerScripts and it runs.

	CONTROLS  Hold LMB/R2 to fire and stay attached, release to let go.
	          Hold Shift to reel in, Ctrl to reel out.

	DESIGN LAW #1: THE CONSTRAINT IS THE MECHANIC.
	The arc is never scripted. ONE RopeConstraint makes the pendulum; everything
	on top is a FORCE, so it composes with gravity and momentum instead of
	overwriting them. Destroying the rope IS the release, because the momentum
	already lives in the rigid body. Only direct velocity write: a safety fuse.

	DESIGN LAW #2: PICKING THE ANCHOR IS HARDER THAN SWINGING ON IT.
	One crosshair raycast picks terrible anchors constantly: too low (the
	pendulum drags you down the street), behind you, or a swing into a wall.
	See findAnchor for the four-stage fan/reject/score/sweep that replaces it.
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

-- CONFIG. Feel is ~90% these numbers. Units: studs, s, studs/s^2 (gravity 196.2).

local SWING = {
	-- Min stops tight orbits that whip the camera; max is sanity for long lines.
	MinRopeLength = 8,
	MaxRopeLength = 900,
	-- Attach slightly SHORTER than the measured distance, so the rope lands
	-- with a catch that converts falling speed into arc speed immediately...
	AttachLengthFactor = 0.88,
	-- ...capped in absolute studs: a percentage scales with distance, and a
	-- 70-stud rope violation on a 600-stud line is a catapult, not a catch.
	AttachCatchMax = 10,
	ReelSpeed = 46, -- manual reel (Shift / Ctrl)
	AutoReelSpeed = 9, -- constant slow winch while taut; kills dead hangs
	-- ACCELERATIONS, multiplied by AssemblyMass at use: mass-independent tuning.
	RopePullAccel = 40, -- the rope actively contracts: main height lever
	AirControlAccel = 60, -- well under gravity: input shapes the arc, never fights it
	PumpBonus = 2.6, -- input multiplier at the BOTTOM of the arc (pumping)
	-- Drag grows past the cap so speed approaches an asymptote, not a wall.
	SoftMaxSpeed = 170,
	SoftDragPerStud = 2.2,
	HardMaxSpeed = 260, -- safety fuse only
	-- Attaching with no tangential energy just hangs; one capped impulse fixes it.
	CatchAssistMinTangential = 32,
	CatchAssistMaxBoost = 26,
	-- A RopeConstraint limits distance, it never pulls: without an impulse to
	-- break ground contact the Humanoid just holds you at WalkSpeed.
	GroundLaunchSpeed = 52,
	LaunchUpBias = 0.55,
	-- Humanoid handling.
	GroundProbe = 3.6, -- own ray; FloorMaterial lies while in Physics state
	GroundedGrace = 0.12, -- ignore one-frame scrapes at the bottom of an arc
	ScrapeKeepSpeed = 26, -- skimming the street this fast is a swing, not a landing
	AlignResponsiveness = 22,
	AlignMaxTorque = 2e5,
}

local ANCHOR = {
	MaxRange = 900,
	MinDistance = 12,
	-- Assist candidates only, never the point you clicked: the assist will not
	-- volunteer a street-level anchor, but you may deliberately aim at one.
	MinHeightAbove = 10,
	-- Fan biased UP, so aiming at a facade finds its high wall, not the pavement.
	FanPitchesDeg = { 0, 12, 24, 38 },
	FanYawsDeg = { 0, -7, 7, -14, 14 },
	-- Aim blended toward velocity as speed rises: past ~100 studs/s momentum
	-- matters more than the crosshair, and fighting it gives whiplash swings.
	VelocityBlendStartSpeed = 25,
	VelocityBlendMaxSpeed = 100,
	VelocityBlendMax = 0.55,
	MaxOffAxisDeg = 80, -- candidates behind the reference direction die
	-- Rooftops barely above the player are rejected; higher ones just get a penalty.
	FlatNormalY = 0.72,
	FlatRejectBelowHeight = 25,
	FlatScorePenalty = 0.8,
	-- Sweep budget is a fixed DISTANCE of travel, not an angle: a fixed angle on
	-- a 600-stud line dips underground and would veto every long shot.
	SweepRadius = 2.5,
	SweepSamples = 6,
	SweepArcDeg = 120,
	SweepArcLength = 130,
	MaxSweepCandidates = 8,
	-- Aim is largest: respect the crosshair, but let a great off-axis anchor win.
	WeightAim = 0.40,
	WeightElevation = 0.30,
	WeightForward = 0.20,
	WeightDistance = 0.10,
	IdealElevationDeg = 45, -- 45 degrees converts swing energy into forward motion best
	ElevationSigmaDeg = 24,
	DistanceRampFull = 60, -- only twitchy short ropes are penalised
	AimFullScoreDeg = 6,
	-- Preview runs the SAME finder as a real fire, so the dot never lies. That is
	-- 20 raycasts, so it is throttled to ~12Hz and skips the arc sweep.
	PreviewInterval = 0.08,
}

local FEEL = {
	BaseFov = 70,
	MaxFovBoost = 20,
	FovSpeedRange = 180,
	FovSmoothing = 6, -- exponential decay rate of the FOV follow
	RopeThickness = 0.16,
	HookTravelSpeed = 700, -- fast: the hook is a projectile, not a lob
	ReticleValid = Color3.fromRGB(120, 255, 160),
	ReticleInvalid = Color3.fromRGB(235, 90, 90),
}

-- ANCHOR SELECTION. Free functions: pure, testable, no state between fires.

-- One type for both stages: the scored winner is returned directly, never copied.
type Anchor = { position: Vector3, normal: Vector3, instance: BasePart, distance: number, score: number }

-- Flatten to XZ: swing direction is a ground-plane concept, so pitch must not leak in.
local function flat(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-4 then f.Unit else Vector3.zAxis
end

local function gaussian(x: number, mean: number, sigma: number): number
	local d = (x - mean) / sigma
	return math.exp(-0.5 * d * d)
end

local function referenceDirection(camLook: Vector3, velocity: Vector3): Vector3
	local speed = velocity.Magnitude
	if speed < ANCHOR.VelocityBlendStartSpeed then
		return flat(camLook)
	end
	local t = math.clamp(
		(speed - ANCHOR.VelocityBlendStartSpeed) / (ANCHOR.VelocityBlendMaxSpeed - ANCHOR.VelocityBlendStartSpeed),
		0,
		1
	)
	return flat(flat(camLook):Lerp(flat(velocity), t * ANCHOR.VelocityBlendMax))
end

-- Sweep the circle the pendulum will travel (centred on the anchor, radius =
-- rope length). Rejects assist anchors whose arc would slam you into a wall.
local function arcIsClear(
	anchorPos: Vector3,
	rootPos: Vector3,
	velocity: Vector3,
	refDir: Vector3,
	params: RaycastParams
): boolean
	local ropeVec = rootPos - anchorPos
	local ropeLen = ropeVec.Magnitude
	if ropeLen < 1 then
		return false
	end
	local radial = ropeVec / ropeLen

	-- Swing direction = velocity with the radial component removed. Near
	-- stationary, assume we will swing along the reference direction.
	local tangential = velocity - radial * velocity:Dot(radial)
	if tangential.Magnitude < 4 then
		tangential = refDir - radial * refDir:Dot(radial)
	end
	if tangential.Magnitude < 1e-3 then
		return true -- dead overhead with no direction: nothing to sweep
	end
	local tangent = tangential.Unit

	local sweepAngle = math.min(math.rad(ANCHOR.SweepArcDeg), ANCHOR.SweepArcLength / ropeLen)
	local step = sweepAngle / ANCHOR.SweepSamples
	local prev = rootPos
	for i = 1, ANCHOR.SweepSamples do
		local angle = step * i
		-- Rotate the radial vector toward the tangent to walk around the arc.
		local point = anchorPos + (radial * math.cos(angle) + tangent * math.sin(angle)) * ropeLen
		local delta = point - prev
		if delta.Magnitude > 0.5 and Workspace:Spherecast(prev, ANCHOR.SweepRadius, delta, params) then
			return false
		end
		prev = point
	end
	return true
end

local function scoreCandidate(cand: Anchor, rootPos: Vector3, camLook: Vector3, refDir: Vector3): number
	local toAnchor = cand.position - rootPos
	local dist = cand.distance

	-- Elevation is THE arc-quality term: a gaussian peaking at 45 degrees.
	local elevation = math.deg(math.asin(math.clamp(toAnchor.Y / dist, -1, 1)))
	local elevationScore = gaussian(elevation, ANCHOR.IdealElevationDeg, ANCHOR.ElevationSigmaDeg)

	-- Aim is the forgiveness term: full marks inside a small cone, fading out.
	local aimAngle = math.deg(math.acos(math.clamp(toAnchor.Unit:Dot(camLook.Unit), -1, 1)))
	local aimScore = 1
		- math.clamp((aimAngle - ANCHOR.AimFullScoreDeg) / (ANCHOR.MaxOffAxisDeg - ANCHOR.AimFullScoreDeg), 0, 1)

	local forwardScore = math.clamp(flat(toAnchor):Dot(refDir) * 0.5 + 0.5, 0, 1)
	local distScore = math.clamp(dist / ANCHOR.DistanceRampFull, 0, 1)

	local score = ANCHOR.WeightAim * aimScore
		+ ANCHOR.WeightElevation * elevationScore
		+ ANCHOR.WeightForward * forwardScore
		+ ANCHOR.WeightDistance * distScore

	-- Rooftop top-surface hits drag the rope over the parapet edge; usable
	-- when high, but a wall face is always the better anchor.
	if cand.normal.Y > ANCHOR.FlatNormalY then
		score *= ANCHOR.FlatScorePenalty
	end
	return score
end

-- Synchronous: one call, same frame, so a failed fire is instant feedback.
-- skipSweep is used by the reticle preview, which must stay cheap.
local function findAnchor(
	rootPos: Vector3,
	aimCFrame: CFrame,
	velocity: Vector3,
	params: RaycastParams,
	skipSweep: boolean
): Anchor?
	local aimLook = aimCFrame.LookVector
	local refDir = referenceDirection(aimLook, velocity)
	-- Fire from just above the character, not from the camera: the orbit camera
	-- sits metres behind you and skews every candidate.
	local origin = rootPos + Vector3.new(0, 1.5, 0)

	-- STAGE 0 -- WHAT THE PLAYER POINTED AT WINS, UNCONDITIONALLY. The scored
	-- fan below is only an assist for when you aimed at open sky. Without this
	-- it hijacks ordinary shots: aim at a facade 70 studs off and the upward
	-- pitches sail over it onto a tower 380 studs behind, which reads as the
	-- hook firing through the building you picked. Casting from the CHARACTER
	-- also guarantees line of sight, so the cable never crosses geometry.
	local direct = Workspace:Raycast(origin, aimLook * ANCHOR.MaxRange, params)
	if direct and direct.Instance:IsA("BasePart") then
		local reach = (direct.Position - rootPos).Magnitude
		if reach >= ANCHOR.MinDistance then
			return {
				position = direct.Position,
				normal = direct.Normal,
				instance = direct.Instance,
				distance = reach,
				score = 1,
			}
		end
	end

	local candidates: { Anchor } = {}
	for _, pitchDeg in ANCHOR.FanPitchesDeg do
		for _, yawDeg in ANCHOR.FanYawsDeg do
			local dir = (aimCFrame * CFrame.Angles(0, math.rad(yawDeg), 0) * CFrame.Angles(math.rad(pitchDeg), 0, 0)).LookVector
			local result = Workspace:Raycast(origin, dir * ANCHOR.MaxRange, params)

			if result and result.Instance:IsA("BasePart") then
				local pos = result.Position
				-- Dedup: rays landing on the same spot add nothing but cost.
				local duplicate = false
				for _, existing in candidates do
					if (existing.position - pos).Magnitude < 4 then
						duplicate = true
						break
					end
				end

				if not duplicate then
					local toAnchor = pos - rootPos
					local dist = toAnchor.Magnitude
					local offAxis = math.deg(math.acos(math.clamp(flat(toAnchor):Dot(refDir), -1, 1)))

					-- Hard rejections, cheapest test first.
					local heightOk = toAnchor.Y >= ANCHOR.MinHeightAbove
					local distOk = dist >= ANCHOR.MinDistance and dist <= ANCHOR.MaxRange
					local frontOk = offAxis <= ANCHOR.MaxOffAxisDeg
					local flatOk = not (
						result.Normal.Y > ANCHOR.FlatNormalY and toAnchor.Y < ANCHOR.FlatRejectBelowHeight
					)

					if heightOk and distOk and frontOk and flatOk then
						table.insert(candidates, {
							position = pos,
							normal = result.Normal,
							instance = result.Instance,
							distance = dist,
							score = 0,
						})
					end
				end
			end
		end
	end

	if #candidates == 0 then
		return nil
	end

	for _, cand in candidates do
		cand.score = scoreCandidate(cand, rootPos, aimLook, refDir)
	end
	table.sort(candidates, function(a, b)
		return a.score > b.score
	end)

	-- Only the top-N scored candidates pay for the expensive arc sweep.
	local budget = math.min(#candidates, ANCHOR.MaxSweepCandidates)
	for i = 1, budget do
		local cand = candidates[i]
		if skipSweep or arcIsClear(cand.position, rootPos, velocity, refDir, params) then
			return cand
		end
	end
	return nil
end

-- GRAPPLE: one character's hook. Metatable class (__index), methods shared once.
-- Four states dispatched via table, not an if/elseif chain: Idle | Firing |
-- Attached | Retracting.

type State = "Idle" | "Firing" | "Attached" | "Retracting"

local Grapple = {}
Grapple.__index = Grapple

type Grapple = typeof(setmetatable(
	{} :: {
		character: Model,
		humanoid: Humanoid,
		root: BasePart,
		camera: Camera,
		state: State,
		wantsFire: boolean,
		reelInput: number,
		hookPosition: Vector3,
		fireTarget: Vector3,
		pendingAnchor: Anchor?,
		rootAttachment: Attachment,
		vectorForce: VectorForce,
		alignOrientation: AlignOrientation,
		anchorAttachment: Attachment?,
		rope: RopeConstraint?,
		wasTaut: boolean,
		usedCatchAssist: boolean,
		inPhysicsMode: boolean,
		groundedTime: number,
		airborneTime: number,
		ropePart: BasePart,
		reticle: Frame,
		reticleGui: ScreenGui,
		previewClock: number,
		previewValid: boolean,
		aimParams: RaycastParams,
		groundParams: RaycastParams,
	},
	Grapple
))

function Grapple.new(character: Model, camera: Camera): Grapple
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local root = character:WaitForChild("HumanoidRootPart") :: BasePart

	-- Built ONCE and reused for the character's life. The fan alone is 20 casts
	-- per fire; rebuilding params per cast would allocate for nothing.
	local aimParams = RaycastParams.new()
	aimParams.FilterType = Enum.RaycastFilterType.Exclude
	aimParams.FilterDescendantsInstances = { character }
	aimParams.IgnoreWater = true
	aimParams.RespectCanCollide = true

	local groundParams = RaycastParams.new()
	groundParams.FilterType = Enum.RaycastFilterType.Exclude
	groundParams.FilterDescendantsInstances = { character }

	local self: Grapple = setmetatable({
		character = character,
		humanoid = humanoid,
		root = root,
		camera = camera,
		state = "Idle" :: State,
		wantsFire = false,
		reelInput = 0,
		hookPosition = root.Position,
		fireTarget = root.Position,
		pendingAnchor = nil,
		rootAttachment = nil :: any,
		vectorForce = nil :: any,
		alignOrientation = nil :: any,
		anchorAttachment = nil,
		rope = nil,
		wasTaut = false,
		usedCatchAssist = false,
		inPhysicsMode = false,
		groundedTime = 0,
		airborneTime = 0,
		ropePart = nil :: any,
		reticle = nil :: any,
		reticleGui = nil :: any,
		previewClock = 0,
		previewValid = false,
		aimParams = aimParams,
		groundParams = groundParams,
	}, Grapple)

	self:_buildRig()
	self:_buildVisuals()
	self:_buildReticle()
	return self
end

-- One attachment both movers hang off, created once: recreating constraints
-- per fire makes the solver re-evaluate the assembly, hitching every shot.
function Grapple._buildRig(self: Grapple)
	local attachment = Instance.new("Attachment")
	attachment.Name = "GrappleRoot"
	attachment.Parent = self.root
	self.rootAttachment = attachment

	local force = Instance.new("VectorForce")
	force.Name = "GrappleSteering"
	force.Attachment0 = attachment
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.ApplyAtCenterOfMass = true
	force.Force = Vector3.zero
	force.Parent = self.root
	self.vectorForce = force

	-- Cosmetic only, but without it a fast swing reads as a ragdoll drifting
	-- sideways instead of a person leaning into an arc.
	local align = Instance.new("AlignOrientation")
	align.Name = "GrappleLean"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.MaxTorque = SWING.AlignMaxTorque
	align.Responsiveness = SWING.AlignResponsiveness
	align.Enabled = false
	align.Parent = self.root
	self.alignOrientation = align
end

function Grapple._buildVisuals(self: Grapple)
	local rope = Instance.new("Part")
	rope.Name = "GrappleCable"
	rope.Anchored = true -- driven by CFrame; must not enter the simulation
	rope.CanCollide = false
	rope.CanQuery = false -- must never block our own aim fan
	rope.CanTouch = false
	rope.CastShadow = false
	rope.Material = Enum.Material.Neon
	rope.Color = Color3.fromRGB(226, 236, 255)
	rope.Size = Vector3.zero
	rope.Parent = Workspace
	self.ropePart = rope

	self.ropePart.Transparency = 1
end

function Grapple._buildReticle(self: Grapple)
	local gui = Instance.new("ScreenGui")
	gui.Name = "GrappleReticle"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	self.reticleGui = gui

	local dot = Instance.new("Frame")
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Size = UDim2.fromOffset(10, 10)
	dot.BackgroundColor3 = FEEL.ReticleInvalid
	dot.BorderSizePixel = 0
	dot.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0) -- square -> circle
	corner.Parent = dot
	self.reticle = dot
end

-- ---- FIRING / ATTACHING / RELEASING ----

-- Aim from the CURSOR, not camera.LookVector: Roblox's third-person camera
-- lets the mouse move independently, so the camera's forward vector fires at
-- screen-centre wherever you point. Shift-lock parks the cursor at centre, so
-- this covers every camera mode; gamepad/touch fall back to the camera.
function Grapple._aimCFrame(self: Grapple): CFrame
	local origin = self.root.Position + Vector3.new(0, 1.5, 0)
	if not UserInputService.MouseEnabled then
		return CFrame.lookAlong(origin, self.camera.CFrame.LookVector)
	end
	-- GetMouseLocation includes the top-bar inset; ViewportPointToRay does not.
	local inset = GuiService:GetGuiInset()
	local loc = UserInputService:GetMouseLocation()
	local ray = self.camera:ViewportPointToRay(loc.X - inset.X, loc.Y - inset.Y)
	-- Resolve what the cursor is over, then aim from the CHARACTER at that
	-- point: the camera sits behind the body, so its ray has parallax error.
	local hit = Workspace:Raycast(ray.Origin, ray.Direction * ANCHOR.MaxRange, self.aimParams)
	local focus = if hit then hit.Position else ray.Origin + ray.Direction * ANCHOR.MaxRange
	local toFocus = focus - origin
	if toFocus.Magnitude < 1 then
		return CFrame.lookAlong(origin, self.camera.CFrame.LookVector)
	end
	return CFrame.lookAlong(origin, toFocus.Unit)
end

function Grapple.fire(self: Grapple)
	if self.state ~= "Idle" then
		return
	end
	-- Commit at fire time: the hook then flies to a point already proved good,
	-- so travel time is pure presentation and cannot change the outcome.
	local aim = self:_aimCFrame()
	local anchor = findAnchor(self.root.Position, aim, self.root.AssemblyLinearVelocity, self.aimParams, false)

	self.hookPosition = self.root.Position
	self.pendingAnchor = anchor
	-- Commit the target now: a miss must fly where the player aimed.
	self.fireTarget = if anchor then anchor.position else aim.Position + aim.LookVector * ANCHOR.MaxRange
	self.state = "Firing"
	self.ropePart.Transparency = 0
end

-- Anchor in the hit part's LOCAL space, so grappling a moving object drags
-- you with it for free -- there is no per-frame anchor tracking anywhere.
function Grapple._attach(self: Grapple, anchor: Anchor)
	local hitPart = anchor.instance
	if not hitPart.Parent then
		self.state = "Retracting"
		return
	end

	local anchorAttachment = Instance.new("Attachment")
	anchorAttachment.Name = "GrappleAnchor"
	anchorAttachment.CFrame = hitPart.CFrame:ToObjectSpace(CFrame.new(anchor.position))
	anchorAttachment.Parent = hitPart
	self.anchorAttachment = anchorAttachment

	local distance = (anchor.position - self.root.Position).Magnitude
	local rope = Instance.new("RopeConstraint")
	rope.Name = "GrappleRope"
	rope.Attachment0 = self.rootAttachment
	rope.Attachment1 = anchorAttachment
	local catch = math.min(distance * (1 - SWING.AttachLengthFactor), SWING.AttachCatchMax)
	rope.Length = math.clamp(distance - catch, SWING.MinRopeLength, SWING.MaxRopeLength)
	rope.Restitution = 0 -- a bouncy rope reads as a bungee
	rope.Visible = false -- we draw our own cable
	rope.Parent = self.root
	self.rope = rope

	self.wasTaut = false
	self.usedCatchAssist = false
	self.state = "Attached"

	-- Fired while grounded: the rope constrains distance but never pulls, and
	-- the Humanoid holds us at WalkSpeed. Break contact, hand to the solver.
	if self.groundedTime > 0 then
		local toAnchor = anchor.position - self.root.Position
		if toAnchor.Magnitude > 1 then
			local launch = (toAnchor.Unit + Vector3.yAxis * SWING.LaunchUpBias).Unit
			self.root:ApplyImpulse(launch * (SWING.GroundLaunchSpeed * self.root.AssemblyMass))
		end
		-- Restart the grace window so the ground we are still touching this
		-- frame cannot read as a landing and instantly undo the launch.
		self.groundedTime = 0
		self:_setPhysicsMode(true, false)
	end
end

-- Destroying the constraint is the ENTIRE release: the velocity already
-- lives in the rigid body, so momentum carries with no special casing.
function Grapple.release(self: Grapple)
	if self.rope then
		self.rope:Destroy()
		self.rope = nil
	end
	if self.anchorAttachment then
		self.anchorAttachment:Destroy()
		self.anchorAttachment = nil
	end
	self.wasTaut = false
	self.vectorForce.Force = Vector3.zero

	if self.inPhysicsMode then
		self:_setPhysicsMode(false, self.groundedTime > 0)
	end
	if self.state == "Attached" then
		self.state = "Retracting"
	end
end

-- ---- HUMANOID MODE ---- The Humanoid fights swinging: its balance torque and
-- WalkSpeed clamp. Physics state hands the body to the solver; reversing this
-- exactly on release is what keeps the player able to stand up afterwards.

function Grapple._setPhysicsMode(self: Grapple, on: boolean, toGround: boolean)
	if on == self.inPhysicsMode then
		return
	end
	self.inPhysicsMode = on

	if on then
		self.humanoid.AutoRotate = false
		self.humanoid:ChangeState(Enum.HumanoidStateType.Physics)
		return
	end

	self.humanoid.AutoRotate = true
	self.alignOrientation.Enabled = false

	if not toGround then
		self.humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		return
	end

	-- Straighten the body (yaw kept, velocity untouched) BEFORE handing control
	-- back: a tilted body triggers the ~1s ragdoll get-up that eats all speed.
	local look = self.root.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude > 1e-3 then
		self.root.CFrame = CFrame.lookAt(self.root.Position, self.root.Position + flatLook.Unit)
	end
	self.humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
end

function Grapple._isGrounded(self: Grapple): boolean
	return Workspace:Raycast(self.root.Position, Vector3.new(0, -SWING.GroundProbe, 0), self.groundParams) ~= nil
end

-- ---- PER-STATE HANDLERS ----

-- Framerate independent: distance travelled is speed * dt, never a fixed step.
function Grapple._updateFiring(self: Grapple, dt: number)
	local anchor = self.pendingAnchor
	-- A miss still throws the hook out and reels it back: firing into empty
	-- sky and getting nothing is the correct, readable feedback.
	local toTarget = self.fireTarget - self.hookPosition
	local step = FEEL.HookTravelSpeed * dt

	if toTarget.Magnitude <= step then
		self.hookPosition = self.fireTarget
		self.pendingAnchor = nil
		if anchor and self.wantsFire then
			self:_attach(anchor)
		else
			self.state = "Retracting" -- missed, or released mid-flight
		end
		return
	end
	self.hookPosition += toTarget.Unit * step
end

function Grapple._updateRetracting(self: Grapple, dt: number)
	local toMuzzle = self.root.Position - self.hookPosition
	local step = FEEL.HookTravelSpeed * 1.4 * dt -- returns faster than it left
	if toMuzzle.Magnitude <= step then
		self.state = "Idle"
		self.ropePart.Transparency = 1
		return
	end
	self.hookPosition += toMuzzle.Unit * step
end

function Grapple._updateAttached(self: Grapple, dt: number)
	local rope = self.rope
	local anchor = self.anchorAttachment
	-- Anchor destroyed out from under us: drop cleanly rather than error.
	if not rope or not anchor or not anchor.Parent then
		self:release()
		return
	end
	self.hookPosition = anchor.WorldPosition

	-- Reeling a taut rope in does real work on the pendulum: this is how a
	-- player converts a swing into height.
	if self.reelInput ~= 0 then
		rope.Length =
			math.clamp(rope.Length - self.reelInput * SWING.ReelSpeed * dt, SWING.MinRopeLength, SWING.MaxRopeLength)
	end

	local toRoot = self.root.Position - anchor.WorldPosition
	local distance = toRoot.Magnitude
	local isTaut = distance > 1 and distance >= rope.Length - 0.75

	if isTaut then
		-- Constant slow winch, so a swing never decays into a dead hang.
		rope.Length = math.max(SWING.MinRopeLength, rope.Length - SWING.AutoReelSpeed * dt)

		if not self.wasTaut and not self.usedCatchAssist then
			-- Once per grapple: a pendulum re-tautens near the top of every arc,
			-- and without this latch the assist stacks impulses and flings you.
			self.usedCatchAssist = true
			self:_catchAssist(toRoot / distance)
		end
	end
	self.wasTaut = isTaut
end

-- Decompose velocity into radial (along the rope) and tangential (around it).
-- Only the tangential part is real swing energy; the rope cancels the rest.
function Grapple._catchAssist(self: Grapple, radial: Vector3)
	local velocity = self.root.AssemblyLinearVelocity
	local tangential = velocity - radial * velocity:Dot(radial)
	local tangentialSpeed = tangential.Magnitude
	if tangentialSpeed >= SWING.CatchAssistMinTangential then
		return -- already swinging: leave it alone
	end

	-- Push along the flat camera direction, projected onto the plane
	-- perpendicular to the rope so it can never fight the constraint.
	local look = self.camera.CFrame.LookVector
	local desired = Vector3.new(look.X, 0, look.Z)
	local direction = desired - radial * desired:Dot(radial)
	if direction.Magnitude < 1e-3 then
		return
	end

	local boost = math.min(SWING.CatchAssistMinTangential - tangentialSpeed, SWING.CatchAssistMaxBoost)
	-- Impulse = mass * desired velocity change, so it lands identically on
	-- every avatar regardless of accessory weight.
	self.root:ApplyImpulse(direction.Unit * (boost * self.root.AssemblyMass))
end

-- Dispatch table: one lookup per frame instead of an if/elseif chain.
local STATE_HANDLERS: { [State]: (Grapple, number) -> () } = {
	Idle = function() end,
	Firing = Grapple._updateFiring,
	Attached = Grapple._updateAttached,
	Retracting = Grapple._updateRetracting,
}

-- ---- FORCES ---- Summed into ONE Vector3, written once per frame; repeated
-- writes let the solver read a half-built force and over-replicate.

function Grapple._applyForces(self: Grapple, velocity: Vector3, speed: number)
	-- Gate on inPhysicsMode, not merely airborne: outside it the Humanoid still
	-- drives and applies its own air control, doubling a plain jump's authority.
	if not self.inPhysicsMode then
		self.vectorForce.Force = Vector3.zero
		return
	end

	local mass = self.root.AssemblyMass
	local force = Vector3.zero
	local bottomness = 0 -- 0 at the top of the arc, 1 hanging straight down

	local anchor = self.anchorAttachment
	if anchor and self.wasTaut then
		local toAnchor = anchor.WorldPosition - self.root.Position
		if toAnchor.Magnitude > 1 then
			local direction = toAnchor.Unit
			-- The rope actively CONTRACTS rather than merely holding length.
			-- This is what carries the player up and over the top of an arc.
			force += direction * (SWING.RopePullAccel * mass)
			-- Body-to-anchor Y near +1 means the anchor is overhead, i.e. we
			-- are at the bottom of the swing.
			bottomness = math.clamp(direction.Y, 0, 1)
		end
	end

	-- MoveDirection is already camera-relative and normalised by the
	-- Humanoid, so WASD works without re-deriving the camera basis here.
	local moveDirection = self.humanoid.MoveDirection
	if moveDirection.Magnitude > 0.01 then
		local accel = SWING.AirControlAccel
		if self.wasTaut then
			-- Pumping: strongest at the bottom of the arc, fading to 1x at
			-- the top -- exactly how a real swing is pumped.
			accel *= 1 + (SWING.PumpBonus - 1) * bottomness
		end
		force += moveDirection * (accel * mass)
	end

	if speed > SWING.SoftMaxSpeed then
		force -= velocity.Unit * (SWING.SoftDragPerStud * (speed - SWING.SoftMaxSpeed) * mass)
	end

	self.vectorForce.Force = force
end

-- ---- PRESENTATION ----

-- Size.Z is the distance and lookAt puts the midpoint facing the anchor, so the
-- part's local Z aligns with the cable -- hence a Z-long block, not a cylinder.
function Grapple._renderCable(self: Grapple)
	if self.state == "Idle" then
		return
	end
	local hand = self.character:FindFirstChild("RightHand") or self.character:FindFirstChild("Right Arm")
	local muzzle = if hand and hand:IsA("BasePart") then hand.Position else self.root.Position
	local delta = self.hookPosition - muzzle
	local distance = delta.Magnitude
	if distance < 0.05 then
		return -- degenerate: lookAt would throw on a zero-length direction
	end

	self.ropePart.Size = Vector3.new(FEEL.RopeThickness, FEEL.RopeThickness, distance)
	self.ropePart.CFrame = CFrame.lookAt(muzzle + delta * 0.5, self.hookPosition)
end

function Grapple._updatePresentation(self: Grapple, dt: number, speed: number)
	-- FOV opens with speed. Exponential decay raised to dt, so feel is identical
	-- at 30 and 240fps; a lerp by a constant factor is frame-rate dependent.
	local targetFov = FEEL.BaseFov + FEEL.MaxFovBoost * math.clamp(speed / FEEL.FovSpeedRange, 0, 1)
	self.camera.FieldOfView += (targetFov - self.camera.FieldOfView) * (1 - math.exp(-FEEL.FovSmoothing * dt))

	-- The preview runs the real finder, so the dot never lies -- but that is
	-- 20 raycasts, so it is throttled and skips the arc sweep.
	if self.state == "Idle" then
		self.previewClock -= dt
		if self.previewClock <= 0 then
			self.previewClock = ANCHOR.PreviewInterval
			self.previewValid = findAnchor(
				self.root.Position,
				self:_aimCFrame(),
				self.root.AssemblyLinearVelocity,
				self.aimParams,
				true
			) ~= nil
		end
		self.reticle.BackgroundColor3 = if self.previewValid then FEEL.ReticleValid else FEEL.ReticleInvalid
	end
	-- Follow the cursor: a centred dot would misreport where the hook goes.
	-- IgnoreGuiInset puts this in GetMouseLocation's coordinate space.
	local m = UserInputService:GetMouseLocation()
	self.reticle.Position = UDim2.fromOffset(m.X, m.Y)
end

-- ---- MAIN UPDATE: one entry point, once per Heartbeat ----

function Grapple.update(self: Grapple, dt: number)
	if not self.root.Parent or self.humanoid.Health <= 0 then
		return
	end

	local velocity = self.root.AssemblyLinearVelocity
	local speed = velocity.Magnitude

	-- SAFETY FUSE, not a mechanic: a constraint solved against a moving anchor
	-- can spike and fire the player out of the map. Only direct velocity write.
	if speed > SWING.HardMaxSpeed then
		velocity = velocity.Unit * SWING.HardMaxSpeed
		self.root.AssemblyLinearVelocity = velocity
		speed = SWING.HardMaxSpeed
	end

	-- Debounced ground contact: a one-frame scrape at the bottom of an arc
	-- must never count as landing, or the Humanoid eats the whole swing.
	local grounded = self:_isGrounded()
	if grounded then
		self.groundedTime += dt
		self.airborneTime = 0
	else
		self.airborneTime += dt
		self.groundedTime = 0
	end

	STATE_HANDLERS[self.state](self, dt)

	if self.state == "Attached" then
		if not grounded and self.airborneTime > 0.02 then
			self:_setPhysicsMode(true, false)
		elseif self.groundedTime > SWING.GroundedGrace and self.inPhysicsMode then
			-- Scrape guard: skimming the street at speed mid-arc is part of a
			-- swing, not a landing.
			if speed < SWING.ScrapeKeepSpeed or not self.wasTaut then
				self:_setPhysicsMode(false, true)
			end
		end
	elseif self.inPhysicsMode then
		self:_setPhysicsMode(false, self.groundedTime > SWING.GroundedGrace)
	end

	self:_applyForces(velocity, speed)

	local align = self.alignOrientation
	align.Enabled = self.inPhysicsMode and speed > 12
	if align.Enabled then
		local flatVel = Vector3.new(velocity.X, 0, velocity.Z)
		local look = if flatVel.Magnitude > 1 then flatVel.Unit else flat(self.camera.CFrame.LookVector)
		-- Blend "up" toward the rope so the body hangs from the anchor
		-- instead of standing bolt upright mid-swing.
		local up = Vector3.yAxis
		local anchor = self.anchorAttachment
		if anchor and self.wasTaut then
			local toAnchor = anchor.WorldPosition - self.root.Position
			if toAnchor.Magnitude > 1 then
				up = (Vector3.yAxis * 0.5 + toAnchor.Unit * 0.5).Unit
			end
		end
		align.CFrame = CFrame.lookAlong(Vector3.zero, look, up)
	end

	self:_renderCable()
	self:_updatePresentation(dt, speed)
end

-- Full teardown: everything this class created is destroyed here, so a
-- respawn cannot leak parts, constraints or GUIs into the next character.
function Grapple.destroy(self: Grapple)
	self:release()
	self.camera.FieldOfView = FEEL.BaseFov
	self.ropePart:Destroy()
	self.reticleGui:Destroy()
	self.alignOrientation:Destroy()
	self.vectorForce:Destroy()
	self.rootAttachment:Destroy()
end

-- ---- BOOTSTRAP: lifecycle, input, and the single update loop ----

local active: Grapple? = nil

-- ContextActionService over UserInputService: it binds mouse, gamepad and a
-- touch button in one call and yields input priority back cleanly.
local function onFireAction(_action: string, inputState: Enum.UserInputState): Enum.ContextActionResult
	local grapple = active
	if not grapple then
		return Enum.ContextActionResult.Pass
	end
	if inputState == Enum.UserInputState.Begin then
		grapple.wantsFire = true
		grapple:fire()
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		grapple.wantsFire = false
		grapple:release()
	end
	return Enum.ContextActionResult.Sink
end

-- Reel in and out share one handler; the action name carries the sign, so
-- there is one code path instead of two near-identical ones.
local function onReelAction(action: string, inputState: Enum.UserInputState): Enum.ContextActionResult
	local grapple = active
	if not grapple then
		return Enum.ContextActionResult.Pass
	end
	local direction = if action == "GrappleReelIn" then 1 else -1
	grapple.reelInput = if inputState == Enum.UserInputState.Begin then direction else 0
	return Enum.ContextActionResult.Sink
end

ContextActionService:BindAction(
	"GrappleFire",
	onFireAction,
	true,
	Enum.UserInputType.MouseButton1,
	Enum.KeyCode.ButtonR2
)
ContextActionService:BindAction("GrappleReelIn", onReelAction, false, Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonL2)
ContextActionService:BindAction("GrappleReelOut", onReelAction, false, Enum.KeyCode.LeftControl, Enum.KeyCode.ButtonB)
ContextActionService:SetTitle("GrappleFire", "Grapple")

local function onCharacterAdded(character: Model)
	if active then
		active:destroy()
		active = nil
	end
	-- CurrentCamera can briefly be nil on the first spawn, so wait for it
	-- rather than bailing out and leaving the player with no grapple at all.
	local camera = Workspace.CurrentCamera
	while not camera do
		task.wait()
		camera = Workspace.CurrentCamera
	end

	local grapple = Grapple.new(character, camera)
	active = grapple

	-- Death must release immediately, or the constraint keeps dragging the
	-- corpse around by the neck.
	grapple.humanoid.Died:Once(function()
		-- Compare against the captured local: a respawn may already have
		-- replaced `active` with a newer Grapple by the time this fires.
		if active == grapple then
			grapple:destroy()
			active = nil
		end
	end)
end

if LocalPlayer.Character then
	onCharacterAdded(LocalPlayer.Character :: Model)
end
LocalPlayer.CharacterAdded:Connect(onCharacterAdded)

-- Heartbeat (post-physics): reads the velocity the solver just produced and
-- sets the forces the NEXT step integrates. RenderStepped would act on stale data.
RunService.Heartbeat:Connect(function(dt: number)
	local grapple = active
	if grapple then
		-- Clamp dt so a lag spike or alt-tab cannot teleport the hook head
		-- through geometry on the frame the game resumes.
		grapple:update(math.min(dt, 1 / 20))
	end
end)
