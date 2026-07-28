# Grappling Hook — Luau Scripter Application

A grappling hook with real pendulum swing physics for Roblox, written as a
single self-contained LocalScript.

**Submission file → [`GrappleHook.client.luau`](GrappleHook.client.luau)**

---

## The one idea

**The constraint is the mechanic.**

The swing arc is never scripted. The script does not write a position or a
velocity to move the player along a curve. It creates one `RopeConstraint` and
lets Roblox's physics solver produce the pendulum. Everything layered on top is
expressed as **forces** (`VectorForce`), because forces compose with gravity and
existing momentum instead of overwriting them.

That single decision is what makes release timing a real skill: destroying the
rope *is* the entire release, because momentum is already stored in the rigid
body. Nothing has to be handed off.

The only place the script writes velocity directly is a documented hard clamp in
`update()` — a safety fuse against solver spikes, not a movement mechanic.

---

## What it demonstrates

| Area | Where |
|---|---|
| **Metatable OOP** | Two classes — `Spring` (analytic critically-damped solver) and `Grapple` (one instance per character), both `__index`-based with full Luau type definitions |
| **CFrame math** | `ToObjectSpace` to anchor in a moving part's local space · `CFrame.lookAt` to stretch the rope part between two points · `CFrame.lookAlong` for the swing lean |
| **Physics API** | `RopeConstraint`, `VectorForce`, `AlignOrientation`, `ApplyImpulse`, `AssemblyLinearVelocity`, `AssemblyMass` |
| **Vector math** | Velocity decomposed into radial vs tangential components to measure real swing energy |
| **Raycasting** | Reused `RaycastParams` for aiming and for the ground probe |
| **State machine** | Four states dispatched through a handler table instead of a per-frame if/else chain |
| **Strict typing** | `--!strict` throughout, verified with `luau-lsp analyze` against the Roblox API definitions |

---

## Controls

| Input | Action |
|---|---|
| Hold **LMB** / **R2** | Fire the hook. Keep holding to stay attached, release to let go — momentum carries. |
| Hold **Shift** / **L2** | Reel in — shortens the rope, so you accelerate and rise |
| Hold **Ctrl** / **B** | Reel out — lengthens the rope, so you drop and widen the arc |

---

## Details worth pointing at

**Anchoring in local space.** The rope's attachment is parented to the part that
was hit, positioned via `hitPart.CFrame:ToObjectSpace(...)`. Grapple a moving
platform and it drags you along for free — there is no per-frame anchor-tracking
code anywhere in the script.

**Mass-independent tuning.** Every force is written as an *acceleration* and
multiplied by `AssemblyMass` at the point of use, so the hook feels identical
regardless of avatar or accessory weight.

**The Humanoid has to be managed.** Roblox's Humanoid state machine actively
fights swinging — it applies its own balance torque and clamps horizontal speed
to `WalkSpeed`. The script moves it into `Physics` state while roped and
airborne and reverses that exactly on release, straightening the body first so
landing doesn't trigger the ~1s ragdoll get-up that would eat all the earned
speed.

**Pumping.** Air-control input is amplified near the bottom of the arc and fades
to 1× at the top, which is how a real swing is pumped.

**Scrape guard.** A one-frame ground touch at the bottom of an arc is not a
landing. Ground contact is debounced, and skimming the floor above a threshold
speed keeps you in the swing.

**Catch assist.** Attaching from a standstill has no tangential energy, so the
player would just hang. One capped impulse — fired only on the frame the rope
first goes taut, and only when tangential speed is genuinely low — buys a real
first arc without ever shoving a player mid-chain.

---

## Repository layout

| File | Role |
|---|---|
| `GrappleHook.client.luau` | **The submission.** A single LocalScript → `StarterPlayer/StarterPlayerScripts` |
| `DemoCourse.server.luau` | Builds the demo place at runtime → `ServerScriptService`. Not part of the submission. |

The demo course is generated entirely by code — a spiral of climbing towers,
floating sky anchors, and two moving platforms included specifically to show the
rope tracking a moving anchor.

---

## Verification

```bash
stylua --check GrappleHook.client.luau
luau-lsp analyze --defs=globalTypes.d.luau --no-strict-dm-types GrappleHook.client.luau
```

Both pass clean. (`globalTypes.d.luau` comes from
[JohnnyMorganz/luau-lsp](https://github.com/JohnnyMorganz/luau-lsp/blob/main/scripts/globalTypes.d.luau)
and is not committed.)
