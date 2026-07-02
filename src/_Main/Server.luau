-- Server boot: wires the whole pipeline for one World.

local Workers = require(script.Parent.Workers)
local Simulation = require(script.Parent.Simulation)
local Render = require(script.Parent.Render)
local Network = require(script.Parent.Network)
local Impact = require(script.Parent.Parent._Patterns.Impact)

local Server = {}

local running = false

function Server.start(world: any, config: any)
	assert(not running, "Chunkr server already started")
	running = true
	Workers.start(config)
	Impact.start(world, config)
	Simulation.start(world, config)
	Render.start(world, config)
	Network.startServer(world, config)
end

function Server.stop()
	if not running then
		return
	end
	running = false
	Render.stop()
	Simulation.stop()
	Impact.stop()
	Workers.stop()
end

return Server
