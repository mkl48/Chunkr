-- Chunkr worker actor entry. Cloned under each Actor by Workers/init; inert
-- everywhere else (the GetActor guard). Computation happens in the parallel
-- phase; the reply crosses back on the serial phase via the pool's Bindable.

local actor = script:GetActor()
if not actor then
	return
end

local package = actor:WaitForChild("Package").Value
local reply: BindableEvent = actor:WaitForChild("ReplyEvent").Value

local Topology = require(package._Patterns.Topology)
local Boxer = require(package._Patterns.Boxer)
local Stress = require(package._Patterns.Stress)

actor:BindToMessageParallel("ChunkrJob", function(jobId: number, jobType: string, a, b, c, d, e, f, g, h, i, j)
	if jobType == "topology" then
		local islands = Topology.islands(a, b, c, d, e)
		task.synchronize()
		reply:Fire(jobId, islands)
	elseif jobType == "boxer" then
		local boxes = Boxer.decompose(a, b, c, d)
		task.synchronize()
		reply:Fire(jobId, boxes)
	elseif jobType == "stress" then
		local broken, warnings = Stress.unsupported(a, b, c, d, e, f, g, h, i, j)
		task.synchronize()
		reply:Fire(jobId, broken, warnings)
	else
		warn(`[Chunkr] unknown worker job {jobType}`)
	end
end)
