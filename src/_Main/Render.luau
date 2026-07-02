-- Rebox scheduling: bodies flagged `needsRemesh` get Boxer jobs (parallel via
-- Workers) under a per-frame budget, worst part-count damage first is TODO -
-- v1 is FIFO. Results apply on the main thread (Instance writes are serial).

local RunService = game:GetService("RunService")

local Workers = require(script.Parent.Workers)
local Anchor = require(script.Parent.Parent._Classes.Anchor)

local Render = {}

local connection: RBXScriptConnection? = nil

function Render.start(world: any, config: any)
	connection = RunService.Heartbeat:Connect(function()
		local budget = config.remeshBudgetPerFrame
		for _, body in world:Bodies() do
			if budget <= 0 then
				break
			end
			if not body.needsRemesh or body._remeshInFlight or body.destroyed then
				continue
			end
			budget -= 1
			body.needsRemesh = false
			body._remeshInFlight = true

			-- Snapshot so the worker sees a stable buffer even if a carve
			-- lands while the job is in flight.
			local volume = body.volume
			local snap = buffer.create(buffer.len(volume.voxels))
			buffer.copy(snap, 0, volume.voxels, 0)
			local sx, sy, sz = volume.sx, volume.sy, volume.sz

			Workers.dispatch("boxer", function(boxes)
				body._remeshInFlight = false
				if body.destroyed then
					return
				end
				-- Volume replaced (split) or re-dirtied? This result is stale;
				-- the needsRemesh flag will already be set again.
				if body.volume ~= volume then
					return
				end
				body:ApplyBoxes(boxes)
				for i = #body.anchors, 1, -1 do
					Anchor.Sync(body.anchors[i])
				end
			end, snap, sx, sy, sz)
		end
	end)
end

function Render.stop()
	if connection then
		connection:Disconnect()
		connection = nil
	end
end

return Render
