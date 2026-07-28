-- Connected Discord-GitHub
--!strict
--[[
	GrappleHook.client.luau
	Grappling hook with real pendulum swing physics, in one self-contained
	LocalScript. Drop it in StarterPlayer > StarterPlayerScripts and it runs.

	CONTROLS
		Hold LMB / R2   Fire and hold to stay attached. Release to let go --
		                momentum carries, so release timing is the skill.
		Hold Shift      Reel in  (shorter rope -> you accelerate and rise)
		Hold Ctrl       Reel out (longer rope -> you drop and widen the arc)

	=======================================================================
	DESIGN LAW #1: THE CONSTRAINT IS THE MECHANIC.
	=======================================================================
	The arc is never scripted. I do not write a position or a velocity to
	move the player along a curve. I create ONE RopeConstraint and let the
	physics solver produce the pendulum. Everything layered on top is a
	FORCE (VectorForce), because forces compose with gravity and existing
	momentum instead of overwriting them.

	That is what makes release timing real: destroying the rope IS the
	entire release, because the momentum already lives in the rigid body.
	The only direct velocity write in this script is a documented safety
	fuse in :update(), which is not a movement mechanic.

	=======================================================================
	DESIGN LAW #2: PICKING THE ANCHOR IS HARDER THAN SWINGING ON IT.
	=======================================================================
	A single crosshair raycast picks terrible anchors constantly -- too low
	(the pendulum drags you along the street), behind you, or a swing
	straight into a wall. So a fire is four stages, cheapest first:

		1. FAN      20 rays, biased upward, spread around the aim direction
		2. REJECT   hard filters: too low, too close, too far off-axis
		3. SCORE    arc quality, weighted; best-first sort
		4. SWEEP    spherecast the PREDICTED ARC of the top candidates and
		            take the first one whose path is actually clear

	Stage 4 is the expensive one, so only the best few candidates ever pay
	for it, and the reticle preview skips it entirely (see PreviewInterval).
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

--[[==========================================================================
	CONFIGURATION
	Feel is ~90% these numbers, so they live in one place, named, and
	commented with WHY rather than what.
	Units: studs, seconds, studs/s, studs/s^2. Roblox gravity = 196.2.
===========================================================================]]

local SWING = {
	-- Rope length limits. Min stops degenerate tight orbits that whip the
	-- camera; max is sanity for very long city lines.
	MinRopeLength = 8,
	MaxRopeLength = 900,

	-- Attach slightly SHORTER than the measured distance, so the rope lands
	-- with a catch that converts falling speed into arc speed immediately...
	AttachLengthFactor = 0.88,
	-- ...but cap the catch in absolute studs. A pure percentage scales with
	-- distance, and a 70-stud instant rope violation on a 600-stud line is a
	-- solver catapult, not a catch.
	AttachCatchMax = 10,

	ReelSpeed = 46, -- manual reel (Shift / Ctrl)
	AutoReelSpeed = 9, -- constant slow winch while taut; kills dead hangs

	-- Forces, expressed as ACCELERATIONS and multiplied by AssemblyMass at
	-- the use site, so tuning is independent of avatar/accessory weight.
	RopePullAccel = 40, -- the rope actively contracts: main height lever
	AirControlAccel = 60, -- well under gravity: input shapes the arc, never fights it
	PumpBonus = 2.6, -- input multiplier at the BOTTOM of the arc (pumping)

	-- Soft speed limit: drag grows past the cap so speed approaches an
	-- asymptote. A hard cap feels like a wall; this feels like air.
	SoftMaxSpeed = 170,
	SoftDragPerStud = 2.2,
	HardMaxSpeed = 260, -- safety fuse only

	-- Catch assist: attaching with no tangential energy would just leave you
	-- hanging. One capped impulse, once per grapple, buys a real first arc.
	CatchAssistMinTangential = 32,
	CatchAssistMaxBoost = 26,

	-- Firing from the ground: a RopeConstraint limits distance, it never
	-- pulls. Without an impulse to break ground contact the Humanoid simply
	-- holds you at WalkSpeed and nothing happens at all.
	GroundLaunchSpeed = 52,
	LaunchUpBias = 0.55,

	-- Humanoid handling.
	GroundProbe = 3.6, -- own ray; FloorMaterial lies while in Physics state
	GroundedGrace = 0.12, -- ignore one-frame scrapes at the bottom of an arc
	ScrapeKeepSpeed = 26, -- skimming the street this fast is a swing, not a landing
	RunOutMaxWalk = 55, -- land fast -> sprint out of it instead of gluing
	RunOutDecay = 24,
	AlignResponsiveness = 22,
	AlignMaxTorque = 2e5,
}

local ANCHOR = {
	MaxRange = 900,
	MinDistance = 18,
	-- Candidates must be at least this far ABOVE the character. Low anchors
	-- make pendulums that drag you down the street; this single filter is
	-- most of the difference between a good and an unusable grapple.
	MinHeightAbove = 10,

	-- Ray fan. Pitches are biased UP so aiming at a building face tends to
	-- find its high wall rather than the pavement in front of it.
	FanPitchesDeg = { 0, 12, 24, 38 },
	FanYawsDeg = { 0, -7, 7, -14, 14 },

	-- Reference direction = camera look blended toward velocity as speed
	-- rises. Past ~100 studs/s momentum matters more than the crosshair;
	-- anchors that fight momentum are how you get whiplash swings.
	VelocityBlendStartSpeed = 25,
	VelocityBlendMaxSpeed = 100,
	VelocityBlendMax = 0.55,

	MaxOffAxisDeg = 80, -- candidates behind the reference direction die

	-- Near-flat upward surfaces (rooftops) barely above the player are
	-- rejected; higher roofs just take a score penalty.
	FlatNormalY = 0.72,
	FlatRejectBelowHeight = 25,
	FlatScorePenalty = 0.8,

	-- Arc sweep. Budget is a fixed DISTANCE of upcoming travel, not a fixed
	-- angle: a fixed angle on a 600-stud line dips deep underground and
	-- would veto every long shot.
	SweepRadius = 2.5,
	SweepSamples = 6,
	SweepArcDeg = 120,
	SweepArcLength = 130,
	MaxSweepCandidates = 8,

	-- Scoring weights. Aim is the largest term: respect the crosshair, but
	-- let a great anchor slightly off-axis beat a bad one dead-centre.
	WeightAim = 0.40,
	WeightElevation = 0.30,
	WeightForward = 0.20,
	WeightDistance = 0.10,
	IdealElevationDeg = 45, -- 45 degrees converts swing energy into forward motion best
	ElevationSigmaDeg = 24,
	DistanceRampFull = 60, -- only twitchy short ropes are penalised
	AimFullScoreDeg = 6,

	-- The reticle preview runs the SAME finder as a real fire, so what the
	-- dot promises is what you get. That is 20 raycasts, so it is throttled
	-- to ~12 Hz and skips the expensive arc sweep.
	PreviewInterval = 0.08,
}

local FEEL = {
	BaseFov = 70,
	MaxFovBoost = 20,
	FovSpeedRange = 180,
	RopeThickness = 0.16,
	HookTravelSpeed = 700, -- fast: the hook is a projectile, not a lob
	ReticleValid = Color3.fromRGB(120, 255, 160),
	ReticleInvalid = Color3.fromRGB(235, 90, 90),
}

--[[==========================================================================
	SPRING -- tiny critically-damped solver (metatable class #1)

	Used for camera FOV and reticle scale. A spring rather than a Tween
	because the target is recomputed every frame; tweens must be rebuilt to
	retarget, a spring just absorbs the new goal. Damping = 2*sqrt(k) is the
	critically damped case: settles as fast as possible without overshoot,
	which is exactly what a camera wants.
===========================================================================]]

local Spring = {}
Spring.__index = Spring

type Spring = typeof(setmetatable(
	{} :: { position: number, velocity: number, target: number, stiffness: number },
	Spring
))

local function newSpring(value: number, stiffness: number): Spring
	return setmetatable({ position = value, velocity = 0, target = value, stiffness = stiffness }, Spring)
end

function Spring.step(self: Spring, dt: number): number
	local damping = 2 * math.sqrt(self.stiffness)
	local accel = (self.target - self.position) * self.stiffness - self.velocity * damping
	self.velocity += accel * dt
	self.position += self.velocity * dt
	return self.position
end

--[[==========================================================================
	ANCHOR SELECTION
	Free functions rather than methods: they are pure given their arguments,
	which keeps them trivially testable and makes it obvious they hold no
	state between fires.
===========================================================================]]

type Anchor = { position: Vector3, normal: Vector3, instance: BasePart, distance: number }
type Candidate = { position: Vector3, normal: Vector3, instance: BasePart, distance: number, score: number }

-- Flatten to the XZ plane and normalise. Swing direction is a ground-plane
-- concept; letting pitch leak into it makes scoring wobble as you look up.
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

-- Sweep the circle the pendulum will actually travel: centred on the anchor,
-- radius = rope length, in the plane defined by the rope and the tangential
-- velocity. This is what rejects "technically reachable" anchors that would
-- slam the player into the building they were aiming past.
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

local function scoreCandidate(cand: Candidate, rootPos: Vector3, camLook: Vector3, refDir: Vector3): number
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
	camCFrame: CFrame,
	velocity: Vector3,
	params: RaycastParams,
	skipSweep: boolean
): Anchor?
	local camLook = camCFrame.LookVector
	local refDir = referenceDirection(camLook, velocity)
	-- Fire the fan from just above the character, not from the camera: the
	-- orbit camera sits metres behind you and skews every candidate.
	local origin = rootPos + Vector3.new(0, 1.5, 0)

	local candidates: { Candidate } = {}
	for _, pitchDeg in ANCHOR.FanPitchesDeg do
		for _, yawDeg in ANCHOR.FanYawsDeg do
			local dir = (camCFrame * CFrame.Angles(0, math.rad(yawDeg), 0) * CFrame.Angles(math.rad(pitchDeg), 0, 0)).LookVector
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
		cand.score = scoreCandidate(cand, rootPos, camLook, refDir)
	end
	table.sort(candidates, function(a, b)
		return a.score > b.score
	end)

	-- Only the top-N scored candidates pay for the expensive arc sweep.
	local budget = math.min(#candidates, ANCHOR.MaxSweepCandidates)
	for i = 1, budget do
		local cand = candidates[i]
		if skipSweep or arcIsClear(cand.position, rootPos, velocity, refDir, params) then
			return {
				position = cand.position,
				normal = cand.normal,
				instance = cand.instance,
				distance = cand.distance,
			}
		end
	end
	return nil
end

--[[==========================================================================
	GRAPPLE -- one instance owns one character's hook (metatable class #2)

	State machine, one handler per state, dispatched through a table instead
	of a per-frame if/elseif chain:
		Idle       nothing deployed; reticle previews the shot
		Firing     hook head in flight toward a committed anchor
		Attached   rope exists, the solver owns the player
		Retracting missed or released; head flying home
===========================================================================]]

type State = "Idle" | "Firing" | "Attached" | "Retracting"

local Grapple = {}
Grapple.__index = Grapple

type Grapple = typeof(setmetatable(
	{} :: {
		character: Model,
		humanoid: Humanoid,
		root: BasePart,
		camera: Camera,
		baseWalkSpeed: number,

		state: State,
		wantsFire: boolean,
		reelInput: number, -- +1 in, -1 out

		hookPosition: Vector3,
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
		hookPart: BasePart,
		reticle: Frame,
		reticleGui: ScreenGui,
		previewClock: number,
		previewValid: boolean,
		fovSpring: Spring,
		reticleSpring: Spring,

		aimParams: RaycastParams,
		groundParams: RaycastParams,
	},
	Grapple
))

function Grapple.new(character: Model, camera: Camera): Grapple
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local root = character:WaitForChild("HumanoidRootPart") :: BasePart

	-- Both RaycastParams are built ONCE and reused for the character's whole
	-- life. The fan alone is 20 casts a fire; rebuilding params per cast
	-- would allocate constantly for nothing.
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
		baseWalkSpeed = humanoid.WalkSpeed,

		state = "Idle" :: State,
		wantsFire = false,
		reelInput = 0,

		hookPosition = root.Position,
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
		hookPart = nil :: any,
		reticle = nil :: any,
		reticleGui = nil :: any,
		previewClock = 0,
		previewValid = false,
		fovSpring = newSpring(FEEL.BaseFov, 90),
		reticleSpring = newSpring(1, 240),

		aimParams = aimParams,
		groundParams = groundParams,
	}, Grapple)

	self:_buildRig()
	self:_buildVisuals()
	self:_buildReticle()
	return self
end

-- One attachment on the root that both movers hang off, created once.
-- Recreating constraints per fire forces the solver to re-evaluate the
-- whole assembly, which shows up as a hitch on every shot.
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

	local hook = Instance.new("Part")
	hook.Name = "GrappleHead"
	hook.Anchored = true
	hook.CanCollide = false
	hook.CanQuery = false
	hook.CanTouch = false
	hook.CastShadow = false
	hook.Material = Enum.Material.Metal
	hook.Color = Color3.fromRGB(96, 106, 126)
	hook.Size = Vector3.new(0.5, 0.5, 1.5)
	hook.Parent = Workspace
	self.hookPart = hook

	-- A Trail needs two attachments to define the ribbon width.
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, 0.22, 0)
	a0.Parent = hook
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -0.22, 0)
	a1.Parent = hook

	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 0.22
	trail.LightEmission = 1
	trail.Transparency = NumberSequence.new(0.25, 1)
	trail.Color = ColorSequence.new(Color3.fromRGB(150, 205, 255))
	trail.Parent = hook

	self:_setVisualsEnabled(false)
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
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromOffset(10, 10)
	dot.BackgroundColor3 = FEEL.ReticleInvalid
	dot.BorderSizePixel = 0
	dot.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0) -- square -> circle
	corner.Parent = dot
	self.reticle = dot
end

-- Toggled rather than destroyed between shots: creating parts costs far more
-- than flipping two transparencies.
function Grapple._setVisualsEnabled(self: Grapple, on: boolean)
	self.ropePart.Transparency = if on then 0 else 1
	self.hookPart.Transparency = if on then 0 else 1
end

--[[--------------------------------------------------------------------------
	FIRING / ATTACHING / RELEASING
----------------------------------------------------------------------------]]

function Grapple.fire(self: Grapple)
	if self.state ~= "Idle" then
		return
	end
	-- Commit to the anchor at fire time, with the full arc sweep. The hook
	-- then flies to a point we already proved is good, so travel time is
	-- pure presentation and can never change the outcome.
	local anchor =
		findAnchor(self.root.Position, self.camera.CFrame, self.root.AssemblyLinearVelocity, self.aimParams, false)

	self.hookPosition = self.root.Position
	self.pendingAnchor = anchor
	self.state = "Firing"
	self:_setVisualsEnabled(true)
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

	-- Fired while stood on something: the rope constrains distance but never
	-- pulls, and the Humanoid would hold us at WalkSpeed, so nothing would
	-- happen at all. Break ground contact and hand straight to the solver.
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

--[[--------------------------------------------------------------------------
	HUMANOID MODE
	The Humanoid state machine fights swinging: it applies its own balance
	torque and clamps horizontal speed to WalkSpeed. Physics state hands the
	body to the solver, and this MUST be reversed exactly on release or the
	player lands and cannot stand up.
----------------------------------------------------------------------------]]

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

	-- Straighten the body (yaw kept, velocity untouched) BEFORE handing
	-- control back. A tilted body triggers the ~1s ragdoll get-up, which
	-- eats every bit of speed the player just earned.
	local look = self.root.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude > 1e-3 then
		self.root.CFrame = CFrame.lookAt(self.root.Position, self.root.Position + flatLook.Unit)
	end
	-- Landing run-out: carry swing speed onto the street instead of letting
	-- the Humanoid clamp to WalkSpeed instantly. Decays in :update().
	local v = self.root.AssemblyLinearVelocity
	local flatSpeed = Vector3.new(v.X, 0, v.Z).Magnitude
	if flatSpeed > self.baseWalkSpeed then
		self.humanoid.WalkSpeed = math.min(flatSpeed, SWING.RunOutMaxWalk)
	end
	self.humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
end

function Grapple._isGrounded(self: Grapple): boolean
	return Workspace:Raycast(self.root.Position, Vector3.new(0, -SWING.GroundProbe, 0), self.groundParams) ~= nil
end

--[[--------------------------------------------------------------------------
	PER-STATE HANDLERS
----------------------------------------------------------------------------]]

-- Framerate independent: distance travelled is speed * dt, never a fixed step.
function Grapple._updateFiring(self: Grapple, dt: number)
	local anchor = self.pendingAnchor
	-- A miss still throws the hook out and reels it back: firing into empty
	-- sky and getting nothing is the correct, readable feedback.
	local target = if anchor
		then anchor.position
		else self.root.Position + self.camera.CFrame.LookVector * ANCHOR.MaxRange

	local toTarget = target - self.hookPosition
	local step = FEEL.HookTravelSpeed * dt

	if toTarget.Magnitude <= step then
		self.hookPosition = target
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
		self:_setVisualsEnabled(false)
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
			-- Once per grapple. A pendulum naturally goes slack and taut again
			-- near the top of every arc, where tangential speed is low --
			-- without this latch the assist re-fires each arc and stacks
			-- impulses until the player is flung off the map.
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

--[[--------------------------------------------------------------------------
	FORCES
	Summed into ONE Vector3 and written to the VectorForce once per frame.
	Writing the property repeatedly would let the solver read a half-built
	force and replicates more than necessary.
----------------------------------------------------------------------------]]

function Grapple._applyForces(self: Grapple, velocity: Vector3, speed: number)
	-- Gate on inPhysicsMode, not merely on being airborne. Outside physics
	-- mode the Humanoid is still driving and already applies its own air
	-- control; adding this on top would give a plain jump double authority.
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

--[[--------------------------------------------------------------------------
	PRESENTATION
----------------------------------------------------------------------------]]

-- Stretch one part between two points. Size.Z is the distance and
-- CFrame.lookAt puts the midpoint between them facing the anchor, aligning
-- the part's local Z with the cable -- which is why it is built as a Z-long
-- block rather than a cylinder: no extra rotation is needed.
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
	self.hookPart.CFrame = CFrame.lookAt(self.hookPosition, self.hookPosition + delta.Unit)
end

function Grapple._updatePresentation(self: Grapple, dt: number, speed: number)
	self.fovSpring.target = FEEL.BaseFov + FEEL.MaxFovBoost * math.clamp(speed / FEEL.FovSpeedRange, 0, 1)
	self.camera.FieldOfView = self.fovSpring:step(dt)

	-- The preview runs the real finder, so the dot never lies -- but that is
	-- 20 raycasts, so it is throttled and skips the arc sweep.
	if self.state == "Idle" then
		self.previewClock -= dt
		if self.previewClock <= 0 then
			self.previewClock = ANCHOR.PreviewInterval
			self.previewValid = findAnchor(
				self.root.Position,
				self.camera.CFrame,
				self.root.AssemblyLinearVelocity,
				self.aimParams,
				true
			) ~= nil
		end
		self.reticle.BackgroundColor3 = if self.previewValid then FEEL.ReticleValid else FEEL.ReticleInvalid
		self.reticleSpring.target = if self.previewValid then 1.7 else 1
	else
		self.reticleSpring.target = 1
	end

	local scale = math.round(10 * self.reticleSpring:step(dt))
	self.reticle.Size = UDim2.fromOffset(scale, scale)
end

--[[--------------------------------------------------------------------------
	MAIN UPDATE -- one entry point, once per Heartbeat
----------------------------------------------------------------------------]]

function Grapple.update(self: Grapple, dt: number)
	if not self.root.Parent or self.humanoid.Health <= 0 then
		return
	end

	local velocity = self.root.AssemblyLinearVelocity
	local speed = velocity.Magnitude

	-- SAFETY FUSE, not a mechanic. A constraint solved against a moving
	-- anchor can spike to absurd speeds; without this the player is fired
	-- out of the map. Only direct velocity write in the script.
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

	-- Landing run-out decay (see _setPhysicsMode).
	if grounded and not self.inPhysicsMode and self.humanoid.WalkSpeed > self.baseWalkSpeed then
		self.humanoid.WalkSpeed = math.max(self.baseWalkSpeed, self.humanoid.WalkSpeed - SWING.RunOutDecay * dt)
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
	self.hookPart:Destroy()
	self.reticleGui:Destroy()
	self.alignOrientation:Destroy()
	self.vectorForce:Destroy()
	self.rootAttachment:Destroy()
end

--[[==========================================================================
	BOOTSTRAP -- lifecycle, input, and the single update loop
===========================================================================]]

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

-- Heartbeat (post-physics) is correct: it reads the velocity the solver just
-- produced and sets the forces the NEXT step integrates. RenderStepped runs
-- before physics and would act on stale data.
RunService.Heartbeat:Connect(function(dt: number)
	local grapple = active
	if grapple then
		-- Clamp dt so a lag spike or alt-tab cannot teleport the hook head
		-- through geometry on the frame the game resumes.
		grapple:update(math.min(dt, 1 / 20))
	end
end)
