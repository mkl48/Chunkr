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

actor:BindToMessageParallel("ChunkrJob", function(jobId: number, jobType: string, a, b, c, d, e, f, g, h, i)
	local result
	if jobType == "topology" then
		result = Topology.islands(a, b, c, d, e)
	elseif jobType == "boxer" then
		result = Boxer.decompose(a, b, c, d)
	elseif jobType == "stress" then
		result = Stress.unsupported(a, b, c, d, e, f, g, h, i)
	else
		warn(`[Chunkr] unknown worker job {jobType}`)
		return
	end
	task.synchronize()
	reply:Fire(jobId, result)
end)
