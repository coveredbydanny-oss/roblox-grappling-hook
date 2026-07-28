-- Connected Discord-GitHub
--!strict
--[[
	GrappleHook.client.luau
	A grappling hook with real pendulum swing physics.

	WHERE THIS GOES
		StarterPlayer > StarterPlayerScripts  (a single LocalScript)

	CONTROLS
		Hold LMB / R2   Fire the hook. Keep holding to stay attached, release to let go.
		Hold Shift      Reel in  (shortens the rope -> you accelerate and rise)
		Hold Ctrl       Reel out (lengthens the rope -> you drop and widen the arc)

	DESIGN LAW: THE CONSTRAINT IS THE MECHANIC.
		The swing arc is NOT scripted. I never write a position or a velocity to
		make the player move along a curve. I create one RopeConstraint and let
		Roblox's physics solver produce the pendulum. Everything this script does
		on top of that is expressed as FORCES (VectorForce), because forces
		compose with gravity and momentum instead of overwriting them.

		That single decision is what makes release timing a real skill: when I
		destroy the rope, momentum is already stored in the rigid body, so the
		player keeps flying. Nothing needs to be "handed off".

		The one deliberate exception is the hard velocity clamp in :Update() --
		documented at that line as a safety fuse, not a movement mechanic.

	WHY IT IS ONE FILE
		The system is genuinely one feature, so it is one script with one class.
		Ordering below is bottom-up: config -> Spring helper -> Grapple class ->
		lifecycle/bootstrap, so nothing is referenced before it is defined.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

--[[==========================================================================
	CONFIGURATION

	Every tuning number lives here rather than being buried as a magic number
	at its use site. The *feel* of a swing is almost entirely these values, so
	they are named and commented with WHY, not just what.
	Units: studs, seconds, studs/s, studs/s^2. Roblox gravity is 196.2 studs/s^2.
===========================================================================]]

local CONFIG = {
	-- ---- Aiming and attaching -------------------------------------------
	MaxRange = 500, -- how far the hook can reach
	MinAttachDistance = 12, -- closer than this and the pendulum is degenerate
	HookTravelSpeed = 420, -- studs/s the hook head flies; slow enough to read
	Cooldown = 0.15, -- debounce so holding LMB cannot spam-fire

	-- ---- Rope -----------------------------------------------------------
	MinRopeLength = 8, -- stops ultra-tight orbits that whip the camera
	MaxRopeLength = 600,
	ReelSpeed = 46, -- manual reel (Shift/Ctrl)
	AutoReelSpeed = 9, -- constant slow winch while taut; prevents dead hangs
	TautEpsilon = 0.75, -- distance-to-length slop that still counts as "taut"

	-- Attach slightly SHORTER than the real distance so the rope catches with
	-- a tug and converts falling speed into arc speed immediately.
	AttachLengthFactor = 0.88,
	-- ...but cap the catch in absolute studs. A pure percentage scales with
	-- distance, and a 60-stud instant rope violation on a long grapple is a
	-- solver catapult, not a catch.
	AttachCatchMax = 10,

	-- ---- Forces ---------------------------------------------------------
	-- Expressed as ACCELERATIONS. Every one is multiplied by AssemblyMass at
	-- the use site so tuning is independent of avatar/accessory weight.
	RopePullAccel = 40, -- rope actively contracts; the main height lever
	AirControlAccel = 60, -- well under gravity: input shapes the arc, never fights it
	PumpBonus = 2.6, -- input multiplier at the BOTTOM of the arc (pumping a swing)

	-- Soft speed limit: drag grows linearly past the cap so speed approaches
	-- an asymptote. A hard cap feels like hitting a wall; this feels like air.
	SoftMaxSpeed = 170,
	SoftDragPerStud = 2.2,
	HardMaxSpeed = 260, -- safety fuse only (see :Update)

	-- Catch assist: attaching from a standstill has no tangential energy, so
	-- the player would just hang. One capped impulse buys a real first arc.
	CatchAssistMinTangential = 32,
	CatchAssistMaxBoost = 26,

	-- ---- Body / humanoid ------------------------------------------------
	GroundProbe = 3.6, -- own ground ray; FloorMaterial lies in Physics state
	GroundedGrace = 0.12, -- ignore one-frame ground scrapes at the arc bottom
	ScrapeKeepSpeed = 26, -- skimming the floor this fast is a swing, not a landing
	AlignResponsiveness = 22,
	AlignMaxTorque = 2e5,

	-- ---- Presentation ---------------------------------------------------
	RopeThickness = 0.14,
	BaseFov = 70,
	MaxFovBoost = 18, -- FOV opens up with speed to sell velocity
	FovSpeedRange = 180, -- speed at which the FOV boost is maxed
	ReticleValid = Color3.fromRGB(120, 255, 160),
	ReticleInvalid = Color3.fromRGB(255, 90, 90),
}

--[[==========================================================================
	SPRING  --  a tiny critically-damped spring solver

	Used for camera FOV and reticle scale. A spring is used instead of a Tween
	because the target changes every single frame; tweens must be recreated to
	retarget, springs just absorb the new goal. This is the standard analytic
	critically-damped solution, implemented inline rather than pulled in as a
	dependency because this submission has to be a single file.

	This is also the first of the two metatable-based classes in the script.
===========================================================================]]

local Spring = {}
Spring.__index = Spring

type Spring = typeof(setmetatable(
	{} :: {
		position: number,
		velocity: number,
		target: number,
		stiffness: number,
	},
	Spring
))

local function newSpring(value: number, stiffness: number): Spring
	return setmetatable({
		position = value,
		velocity = 0,
		target = value,
		stiffness = stiffness,
	}, Spring)
end

-- Critically damped step: damping = 2 * sqrt(k) means it settles as fast as
-- possible without ever overshooting, which is what you want for a camera.
function Spring.step(self: Spring, dt: number): number
	local damping = 2 * math.sqrt(self.stiffness)
	local accel = (self.target - self.position) * self.stiffness - self.velocity * damping
	self.velocity += accel * dt
	self.position += self.velocity * dt
	return self.position
end

--[[==========================================================================
	GRAPPLE  --  one instance owns one character's hook

	State machine. Exactly one state is active at a time and each has its own
	update handler, dispatched through STATE_HANDLERS at the bottom of the
	class. That table replaces an if/elseif chain that would otherwise be
	re-evaluated top-to-bottom every frame.

		Idle       -> nothing deployed, reticle is live-testing the crosshair
		Firing     -> hook head is in flight toward a stored world point
		Attached   -> rope exists, physics owns the player
		Retracting -> hook missed or was released, head is flying home
===========================================================================]]

type State = "Idle" | "Firing" | "Attached" | "Retracting"

local Grapple = {}
Grapple.__index = Grapple

type Grapple = typeof(setmetatable(
	{} :: {
		-- character refs
		character: Model,
		humanoid: Humanoid,
		root: BasePart,
		camera: Camera,

		-- state machine
		state: State,
		cooldown: number,
		wantsFire: boolean,
		reelInput: number, -- -1 out, 0 none, +1 in

		-- hook flight
		hookPosition: Vector3,
		targetPoint: Vector3,
		pendingResult: RaycastResult?,

		-- attachment / physics instances
		rootAttachment: Attachment,
		vectorForce: VectorForce,
		alignOrientation: AlignOrientation,
		anchorAttachment: Attachment?,
		rope: RopeConstraint?,

		-- taut bookkeeping
		wasTaut: boolean,

		-- humanoid mode
		inPhysicsMode: boolean,
		groundedTime: number,
		airborneTime: number,

		-- visuals
		ropePart: BasePart,
		hookPart: BasePart,
		reticle: Frame,
		reticleGui: ScreenGui,
		fovSpring: Spring,
		reticleSpring: Spring,

		-- reused scratch objects (allocated once, never per frame)
		aimParams: RaycastParams,
		groundParams: RaycastParams,
	},
	Grapple
))

--[[--------------------------------------------------------------------------
	CONSTRUCTION
	new() only wires up references and calls the three private builders, so
	each builder stays small enough to read in one screen.
----------------------------------------------------------------------------]]

function Grapple.new(character: Model, camera: Camera): Grapple
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local root = character:WaitForChild("HumanoidRootPart") :: BasePart

	-- Two RaycastParams objects are created ONCE and reused for the life of
	-- the character. Building them inside the per-frame aim/ground checks
	-- would allocate two userdata every frame for no reason.
	local aimParams = RaycastParams.new()
	aimParams.FilterType = Enum.RaycastFilterType.Exclude
	aimParams.FilterDescendantsInstances = { character }
	aimParams.IgnoreWater = true

	local groundParams = RaycastParams.new()
	groundParams.FilterType = Enum.RaycastFilterType.Exclude
	groundParams.FilterDescendantsInstances = { character }

	local self: Grapple = setmetatable({
		character = character,
		humanoid = humanoid,
		root = root,
		camera = camera,

		state = "Idle" :: State,
		cooldown = 0,
		wantsFire = false,
		reelInput = 0,

		hookPosition = root.Position,
		targetPoint = root.Position,
		pendingResult = nil,

		rootAttachment = nil :: any,
		vectorForce = nil :: any,
		alignOrientation = nil :: any,
		anchorAttachment = nil,
		rope = nil,

		wasTaut = false,

		inPhysicsMode = false,
		groundedTime = 0,
		airborneTime = 0,

		ropePart = nil :: any,
		hookPart = nil :: any,
		reticle = nil :: any,
		reticleGui = nil :: any,
		fovSpring = newSpring(CONFIG.BaseFov, 90),
		reticleSpring = newSpring(1, 240),

		aimParams = aimParams,
		groundParams = groundParams,
	}, Grapple)

	self:_buildRig()
	self:_buildVisuals()
	self:_buildReticle()
	return self
end

-- The physics rig: one attachment on the root that both movers hang off.
-- Created once and reused for every grapple, because creating/destroying
-- constraints every fire causes the solver to re-evaluate the assembly.
function Grapple._buildRig(self: Grapple)
	local attachment = Instance.new("Attachment")
	attachment.Name = "GrappleRootAttachment"
	attachment.Parent = self.root
	self.rootAttachment = attachment

	-- All steering goes through this one force. Force is rewritten each frame
	-- in _applyForces; the instance itself is never recreated.
	local force = Instance.new("VectorForce")
	force.Name = "GrappleSteering"
	force.Attachment0 = attachment
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.ApplyAtCenterOfMass = true
	force.Force = Vector3.zero
	force.Parent = self.root
	self.vectorForce = force

	-- Leans the body along its own velocity while swinging. Purely cosmetic,
	-- but without it a fast swing reads as a ragdoll drifting sideways.
	local align = Instance.new("AlignOrientation")
	align.Name = "GrappleLean"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.MaxTorque = CONFIG.AlignMaxTorque
	align.Responsiveness = CONFIG.AlignResponsiveness
	align.Enabled = false
	align.Parent = self.root
	self.alignOrientation = align
end

-- The rope is drawn as a single stretched part rather than a Beam so the
-- CFrame math is explicit and the rope reads correctly from every angle.
function Grapple._buildVisuals(self: Grapple)
	local rope = Instance.new("Part")
	rope.Name = "GrappleRope"
	rope.Anchored = true -- driven by CFrame, must not participate in physics
	rope.CanCollide = false
	rope.CanQuery = false -- never let the rope block our own aim raycast
	rope.CanTouch = false
	rope.CastShadow = false
	rope.Material = Enum.Material.Neon
	rope.Color = Color3.fromRGB(235, 240, 255)
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
	hook.Color = Color3.fromRGB(90, 100, 120)
	hook.Size = Vector3.new(0.5, 0.5, 1.4)
	hook.Parent = Workspace
	self.hookPart = hook

	-- A Trail needs two attachments to define the ribbon's width.
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, 0.2, 0)
	a0.Parent = hook
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -0.2, 0)
	a1.Parent = hook

	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 0.25
	trail.LightEmission = 1
	trail.Transparency = NumberSequence.new(0.2, 1)
	trail.Color = ColorSequence.new(Color3.fromRGB(140, 200, 255))
	trail.Parent = hook

	self:_setVisualsEnabled(false)
end

function Grapple._buildReticle(self: Grapple)
	local gui = Instance.new("ScreenGui")
	gui.Name = "GrappleReticle"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

	local dot = Instance.new("Frame")
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromOffset(10, 10)
	dot.BackgroundColor3 = CONFIG.ReticleInvalid
	dot.BorderSizePixel = 0
	dot.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0) -- makes the square a circle
	corner.Parent = dot

	self.reticle = dot
	self.reticleGui = gui
end

-- Rope and hook head are hidden rather than destroyed between shots: creating
-- parts is far more expensive than toggling two booleans.
function Grapple._setVisualsEnabled(self: Grapple, on: boolean)
	self.ropePart.Transparency = if on then 0 else 1
	self.hookPart.Transparency = if on then 0 else 1
end

--[[--------------------------------------------------------------------------
	AIMING
----------------------------------------------------------------------------]]

-- One raycast straight down the camera's look vector. Returns nil when the
-- shot is unusable, so callers only ever handle "valid anchor or nothing".
function Grapple._aim(self: Grapple): RaycastResult?
	local origin = self.camera.CFrame.Position
	local direction = self.camera.CFrame.LookVector * CONFIG.MaxRange
	local result = Workspace:Raycast(origin, direction, self.aimParams)
	if not result then
		return nil
	end
	-- Reject anchors that are too close to swing on, measured from the BODY
	-- (not the camera) because the rope attaches to the body.
	if (result.Position - self.root.Position).Magnitude < CONFIG.MinAttachDistance then
		return nil
	end
	return result
end

--[[--------------------------------------------------------------------------
	FIRING / ATTACHING / RELEASING
----------------------------------------------------------------------------]]

function Grapple.fire(self: Grapple)
	if self.state ~= "Idle" or self.cooldown > 0 then
		return
	end

	local result = self:_aim()
	self.hookPosition = self.root.Position
	self.pendingResult = result
	-- A miss still launches the hook to max range and reels it back. Firing
	-- into empty sky and getting nothing is the correct, readable feedback.
	self.targetPoint = if result
		then result.Position
		else self.camera.CFrame.Position + self.camera.CFrame.LookVector * CONFIG.MaxRange

	self.state = "Firing"
	self:_setVisualsEnabled(true)
end

-- Anchor the rope. The attachment is parented to the part that was HIT, at
-- the hit point converted into that part's local space, so grappling a moving
-- platform drags you with it for free -- no per-frame anchor tracking code.
function Grapple._attach(self: Grapple, result: RaycastResult)
	local hitPart = result.Instance
	if not hitPart or not hitPart:IsA("BasePart") then
		return
	end

	local anchorAttachment = Instance.new("Attachment")
	anchorAttachment.Name = "GrappleAnchor"
	anchorAttachment.CFrame = hitPart.CFrame:ToObjectSpace(CFrame.new(result.Position))
	anchorAttachment.Parent = hitPart
	self.anchorAttachment = anchorAttachment

	local distance = (result.Position - self.root.Position).Magnitude
	local rope = Instance.new("RopeConstraint")
	rope.Name = "GrappleRope"
	rope.Attachment0 = self.rootAttachment
	rope.Attachment1 = anchorAttachment
	-- Catch tug (see CONFIG.AttachLengthFactor / AttachCatchMax).
	local catch = math.min(distance * (1 - CONFIG.AttachLengthFactor), CONFIG.AttachCatchMax)
	rope.Length = math.clamp(distance - catch, CONFIG.MinRopeLength, CONFIG.MaxRopeLength)
	rope.Restitution = 0 -- no bounce; a bouncy rope feels like a bungee
	rope.Visible = false -- we render our own
	rope.Parent = self.root
	self.rope = rope

	self.wasTaut = false
	self.state = "Attached"
end

-- Destroying the constraint is the ENTIRE release. Velocity is already in the
-- rigid body, so momentum carries with no special-casing.
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
		self.cooldown = CONFIG.Cooldown
	end
end

--[[--------------------------------------------------------------------------
	HUMANOID MODE

	The Humanoid state machine actively fights swinging: it applies its own
	balance torque and clamps horizontal speed to WalkSpeed. Putting it into
	Physics state hands the body to the solver. This must be reversed exactly
	on release or the player lands and cannot stand up.
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

	if toGround then
		-- Straighten the body (yaw kept, velocity untouched) BEFORE handing
		-- control back. A tilted body triggers the ~1s ragdoll get-up, which
		-- eats every bit of speed the player just earned.
		local look = self.root.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude > 1e-3 then
			self.root.CFrame = CFrame.lookAt(self.root.Position, self.root.Position + flat.Unit)
		end
		self.humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	else
		self.humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
	end
end

function Grapple._isGrounded(self: Grapple): boolean
	local down = Vector3.new(0, -CONFIG.GroundProbe, 0)
	return Workspace:Raycast(self.root.Position, down, self.groundParams) ~= nil
end

--[[--------------------------------------------------------------------------
	PER-STATE UPDATE HANDLERS
----------------------------------------------------------------------------]]

-- Move the hook head along a straight line at a fixed speed. Framerate
-- independent: distance travelled is speed * dt, never a fixed step.
function Grapple._updateFiring(self: Grapple, dt: number)
	local toTarget = self.targetPoint - self.hookPosition
	local step = CONFIG.HookTravelSpeed * dt

	if toTarget.Magnitude <= step then
		self.hookPosition = self.targetPoint
		local result = self.pendingResult
		self.pendingResult = nil
		if result and self.wantsFire then
			self:_attach(result)
		else
			self.state = "Retracting" -- missed, or the player let go mid-flight
		end
		return
	end

	self.hookPosition += toTarget.Unit * step
end

-- Fly the head back to the body, then go fully idle.
function Grapple._updateRetracting(self: Grapple, dt: number)
	local muzzle = self.root.Position
	local toMuzzle = muzzle - self.hookPosition
	local step = CONFIG.HookTravelSpeed * 1.5 * dt -- returns faster than it left

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
	-- If the anchored part was destroyed out from under us, drop cleanly.
	if not rope or not anchor or not anchor.Parent then
		self:release()
		return
	end

	self.hookPosition = anchor.WorldPosition

	-- Manual reel. Shortening a taut rope does real work on the pendulum:
	-- this is how a player converts a swing into height.
	if self.reelInput ~= 0 then
		rope.Length =
			math.clamp(rope.Length - self.reelInput * CONFIG.ReelSpeed * dt, CONFIG.MinRopeLength, CONFIG.MaxRopeLength)
	end

	local toRoot = self.root.Position - anchor.WorldPosition
	local distance = toRoot.Magnitude
	local isTaut = distance > 1 and distance >= rope.Length - CONFIG.TautEpsilon

	if isTaut then
		-- Constant slow winch while taut, so a swing never dies into a hang.
		rope.Length = math.max(CONFIG.MinRopeLength, rope.Length - CONFIG.AutoReelSpeed * dt)

		-- Catch assist fires exactly once, on the frame the rope FIRST goes
		-- taut, and only when there is almost no tangential energy to build on
		-- (i.e. attaching from a standstill). Mid-chain it would feel like a shove.
		if not self.wasTaut then
			self:_catchAssist(toRoot / distance)
		end
	end
	self.wasTaut = isTaut
end

-- Decompose velocity into radial (along the rope) and tangential (around it).
-- Only the tangential part is real swing energy -- the rope cancels the rest.
function Grapple._catchAssist(self: Grapple, radial: Vector3)
	local velocity = self.root.AssemblyLinearVelocity
	local tangential = velocity - radial * velocity:Dot(radial)
	local tangentialSpeed = tangential.Magnitude
	if tangentialSpeed >= CONFIG.CatchAssistMinTangential then
		return -- already swinging; leave it alone
	end

	-- Push along the camera's flat look direction, projected onto the plane
	-- perpendicular to the rope so the impulse cannot fight the constraint.
	local look = self.camera.CFrame.LookVector
	local desired = Vector3.new(look.X, 0, look.Z)
	local direction = desired - radial * desired:Dot(radial)
	if direction.Magnitude < 1e-3 then
		return
	end

	local boost = math.min(CONFIG.CatchAssistMinTangential - tangentialSpeed, CONFIG.CatchAssistMaxBoost)
	-- Impulse = mass * desired velocity change, so it lands identically on
	-- every avatar regardless of accessory weight.
	self.root:ApplyImpulse(direction.Unit * (boost * self.root.AssemblyMass))
end

-- Dispatch table: replaces a per-frame if/elseif chain with one lookup.
local STATE_HANDLERS: { [State]: (Grapple, number) -> () } = {
	Idle = function() end,
	Firing = Grapple._updateFiring,
	Attached = Grapple._updateAttached,
	Retracting = Grapple._updateRetracting,
}

--[[--------------------------------------------------------------------------
	FORCES

	Every force is an acceleration multiplied by AssemblyMass, and they are
	summed into ONE Vector3 that is written to the VectorForce once per frame.
	Writing the property repeatedly would make the solver read a half-built
	force, and would replicate more than necessary.
----------------------------------------------------------------------------]]

function Grapple._applyForces(self: Grapple, grounded: boolean, velocity: Vector3, speed: number)
	-- Gate on inPhysicsMode, NOT merely on being airborne. Outside physics mode
	-- the Humanoid is still driving the character and already applies its own
	-- air control; adding this force on top would give a plain jump double the
	-- movement authority it should have. The force may only act during the exact
	-- window where the Humanoid has been handed over to the solver.
	if grounded or not self.inPhysicsMode then
		self.vectorForce.Force = Vector3.zero
		return
	end

	local mass = self.root.AssemblyMass
	local force = Vector3.zero
	local bottomness = 0 -- 0 at the top of the arc, 1 hanging straight down

	local rope = self.rope
	local anchor = self.anchorAttachment
	if rope and anchor and self.wasTaut then
		local toAnchor = anchor.WorldPosition - self.root.Position
		if toAnchor.Magnitude > 1 then
			local direction = toAnchor.Unit
			-- The rope actively CONTRACTS; it does not merely hold a length.
			-- This is what carries the player up and over the top of an arc.
			force += direction * (CONFIG.RopePullAccel * mass)
			-- Pointing from body to anchor: Y near +1 means the anchor is
			-- overhead, i.e. we are at the bottom of the swing.
			bottomness = math.clamp(direction.Y, 0, 1)
		end
	end

	-- Air control. MoveDirection is already camera-relative and normalized by
	-- the Humanoid, so WASD works without re-deriving the camera basis here.
	local moveDirection = self.humanoid.MoveDirection
	if moveDirection.Magnitude > 0.01 then
		local accel = CONFIG.AirControlAccel
		if self.wasTaut then
			-- Pumping: input is strongest at the bottom of the arc, fading to
			-- 1x at the top -- exactly how a real swing is pumped.
			accel *= 1 + (CONFIG.PumpBonus - 1) * bottomness
		end
		force += moveDirection * (accel * mass)
	end

	-- Soft speed limit (see CONFIG.SoftMaxSpeed).
	if speed > CONFIG.SoftMaxSpeed then
		force -= velocity.Unit * (CONFIG.SoftDragPerStud * (speed - CONFIG.SoftMaxSpeed) * mass)
	end

	self.vectorForce.Force = force
end

--[[--------------------------------------------------------------------------
	PRESENTATION
----------------------------------------------------------------------------]]

-- Stretch one part between two points. Size.Z is the distance and CFrame.lookAt
-- puts the part's midpoint between them facing the anchor, which aligns the
-- part's local Z axis with the rope. This is why the rope is built as a Z-long
-- block instead of a cylinder: no extra rotation is needed.
function Grapple._renderRope(self: Grapple)
	if self.state == "Idle" then
		return
	end
	-- Fire from the right hand when it exists so the rope reads as held.
	local hand = self.character:FindFirstChild("RightHand") or self.character:FindFirstChild("Right Arm")
	local muzzle = if hand and hand:IsA("BasePart") then hand.Position else self.root.Position
	local target = self.hookPosition

	local delta = target - muzzle
	local distance = delta.Magnitude
	if distance < 0.05 then
		return -- degenerate; lookAt would throw on a zero-length direction
	end

	self.ropePart.Size = Vector3.new(CONFIG.RopeThickness, CONFIG.RopeThickness, distance)
	self.ropePart.CFrame = CFrame.lookAt(muzzle + delta * 0.5, target)
	self.hookPart.CFrame = CFrame.lookAt(target, target + delta.Unit)
end

function Grapple._updatePresentation(self: Grapple, dt: number, speed: number)
	-- FOV opens as speed rises. The spring means the FOV never snaps, even
	-- though its target is recomputed from scratch every frame.
	local t = math.clamp(speed / CONFIG.FovSpeedRange, 0, 1)
	self.fovSpring.target = CONFIG.BaseFov + CONFIG.MaxFovBoost * t
	self.camera.FieldOfView = self.fovSpring:step(dt)

	-- Reticle only live-tests the crosshair while idle; while attached the
	-- answer is irrelevant and the raycast would be wasted work.
	if self.state == "Idle" then
		local valid = self:_aim() ~= nil
		self.reticle.BackgroundColor3 = if valid then CONFIG.ReticleValid else CONFIG.ReticleInvalid
		self.reticleSpring.target = if valid then 1.6 else 1
	else
		self.reticleSpring.target = 1
	end
	local scale = self.reticleSpring:step(dt)
	self.reticle.Size = UDim2.fromOffset(math.round(10 * scale), math.round(10 * scale))
end

--[[--------------------------------------------------------------------------
	MAIN UPDATE  --  one entry point, called once per Heartbeat
----------------------------------------------------------------------------]]

function Grapple.update(self: Grapple, dt: number)
	if not self.root.Parent or self.humanoid.Health <= 0 then
		return
	end

	self.cooldown = math.max(0, self.cooldown - dt)

	local velocity = self.root.AssemblyLinearVelocity
	local speed = velocity.Magnitude

	-- SAFETY FUSE, not a mechanic. A constraint solved against a moving
	-- anchor can occasionally spike to absurd speeds; without this the player
	-- is fired out of the map. This is the only place the script writes
	-- velocity directly, and it is intentionally a hard clamp.
	if speed > CONFIG.HardMaxSpeed then
		velocity = velocity.Unit * CONFIG.HardMaxSpeed
		self.root.AssemblyLinearVelocity = velocity
		speed = CONFIG.HardMaxSpeed
	end

	-- Debounced ground contact: a single-frame scrape at the bottom of an arc
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

	-- Humanoid mode follows the rope, with the scrape guard applied.
	if self.state == "Attached" then
		if not grounded and self.airborneTime > 0.02 then
			self:_setPhysicsMode(true, false)
		elseif self.groundedTime > CONFIG.GroundedGrace and self.inPhysicsMode then
			if speed < CONFIG.ScrapeKeepSpeed or not self.wasTaut then
				self:_setPhysicsMode(false, true)
			end
		end
	elseif self.inPhysicsMode then
		self:_setPhysicsMode(false, self.groundedTime > CONFIG.GroundedGrace)
	end

	self:_applyForces(grounded, velocity, speed)

	-- Cosmetic lean, only while genuinely flying.
	local align = self.alignOrientation
	align.Enabled = self.inPhysicsMode and speed > 12
	if align.Enabled then
		local flat = Vector3.new(velocity.X, 0, velocity.Z)
		local look = if flat.Magnitude > 1
			then flat.Unit
			else Vector3.new(self.camera.CFrame.LookVector.X, 0, self.camera.CFrame.LookVector.Z).Unit
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

	self:_renderRope()
	self:_updatePresentation(dt, speed)
end

-- Full teardown. Every instance created by this class is destroyed here so a
-- respawn cannot leak parts, constraints or GUIs into the next character.
function Grapple.destroy(self: Grapple)
	self:release()
	self.camera.FieldOfView = CONFIG.BaseFov
	self.ropePart:Destroy()
	self.hookPart:Destroy()
	self.reticleGui:Destroy() -- the whole ScreenGui, not just the dot
	self.alignOrientation:Destroy()
	self.vectorForce:Destroy()
	self.rootAttachment:Destroy()
end

--[[==========================================================================
	BOOTSTRAP  --  lifecycle, input binding, and the single update loop
===========================================================================]]

local active: Grapple? = nil

-- ContextActionService is used instead of UserInputService because it binds
-- mouse, gamepad and a touch button in one call, and cleanly yields input
-- priority back when the character dies.
local function onFireAction(_actionName: string, inputState: Enum.UserInputState): Enum.ContextActionResult
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

-- Reel in and out share one handler; the bound action name carries the sign,
-- so there is one code path instead of two near-identical ones.
local function onReelAction(actionName: string, inputState: Enum.UserInputState): Enum.ContextActionResult
	local grapple = active
	if not grapple then
		return Enum.ContextActionResult.Pass
	end
	local direction = if actionName == "GrappleReelIn" then 1 else -1
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
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	local grapple = Grapple.new(character, camera)
	active = grapple

	-- Death must release the rope immediately, otherwise the constraint keeps
	-- dragging the corpse around by the neck.
	local humanoid = grapple.humanoid
	humanoid.Died:Once(function()
		-- Compare against the captured local, then act on it: a respawn may
		-- already have replaced `active` with a newer Grapple by now.
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

-- Heartbeat (post-physics) is correct here: it reads the velocity the solver
-- just produced and sets the forces that the NEXT step will integrate.
-- RenderStepped would run before physics and act on stale data.
RunService.Heartbeat:Connect(function(dt: number)
	local grapple = active
	if grapple then
		-- Clamp dt so a lag spike or an alt-tab cannot teleport the hook head
		-- through geometry on the frame the game resumes.
		grapple:update(math.min(dt, 1 / 20))
	end
end)
