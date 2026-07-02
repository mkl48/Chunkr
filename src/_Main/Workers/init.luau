-- Parallel Luau job pool. Topology/Boxer/Stress are pure buffer -> data
-- functions, so they travel to Actor VMs; this module owns dispatch, join and
-- the serial fallback (Config.parallel = false runs identical code inline,
-- which is the debugging path).
--
-- Wire shape: actor:SendMessage("ChunkrJob", jobId, jobType, payload...),
-- Runner replies through the pool's BindableEvent after task.synchronize().
-- Server only (destruction is server-authoritative).

local ServerScriptService = game:GetService("ServerScriptService")

local Topology = require(script.Parent.Parent._Patterns.Topology)
local Boxer = require(script.Parent.Parent._Patterns.Boxer)
local Stress = require(script.Parent.Parent._Patterns.Stress)

local Workers = {}

local parallel = false
local actors: { Actor } = {}
local reply: BindableEvent? = nil
local pending: { [number]: (any) -> () } = {}
local nextJobId = 0
local roundRobin = 0

local function runSerial(jobType: string, a: any, b: any, c: any, d: any, e: any, f: any, g: any, h: any, i: any): any
	if jobType == "topology" then
		return Topology.islands(a, b, c, d, e)
	elseif jobType == "boxer" then
		return Boxer.decompose(a, b, c, d)
	elseif jobType == "stress" then
		return Stress.unsupported(a, b, c, d, e, f, g, h, i)
	end
	error(`unknown job type {jobType}`)
end

function Workers.start(config: any)
	parallel = config.parallel == true
	if not parallel then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = "ChunkrWorkers"

	reply = Instance.new("BindableEvent")
	reply.Name = "Reply"
	reply.Parent = folder
	reply.Event:Connect(function(jobId: number, result: any)
		local callback = pending[jobId]
		if callback then
			pending[jobId] = nil
			callback(result)
		end
	end)

	for i = 1, config.workerCount do
		local actor = Instance.new("Actor")
		actor.Name = `Worker{i}`

		local package = Instance.new("ObjectValue")
		package.Name = "Package"
		package.Value = script.Parent.Parent -- the Chunkr root
		package.Parent = actor

		local replyRef = Instance.new("ObjectValue")
		replyRef.Name = "ReplyEvent"
		replyRef.Value = reply
		replyRef.Parent = actor

		local runner = script.Runner:Clone()
		runner.Parent = actor
		runner.Enabled = true

		actor.Parent = folder
		table.insert(actors, actor)
	end

	folder.Parent = ServerScriptService
end

-- Dispatches a job; callback runs on the main thread with the result.
-- Serial mode computes inline (callback still async-shaped for callers).
function Workers.dispatch(jobType: string, callback: (any) -> (), ...: any)
	if not parallel or #actors == 0 then
		callback(runSerial(jobType, ...))
		return
	end
	nextJobId += 1
	pending[nextJobId] = callback
	roundRobin = roundRobin % #actors + 1
	actors[roundRobin]:SendMessage("ChunkrJob", nextJobId, jobType, ...)
end

function Workers.stop()
	for _, actor in actors do
		actor.Parent:Destroy()
		break
	end
	table.clear(actors)
	table.clear(pending)
	reply = nil
end

return Workers
