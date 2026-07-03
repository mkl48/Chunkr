-- Client boot: thin by design. Bodies replicate natively as Parts; the client
-- only sends tool intents (Network.request*) and receives FX payloads
-- (Events.OnFx) to drive local particles/sounds. `Client.fx` is the stock
-- handler for that stream - `Client.fx.start()` and destruction has dust,
-- shards, flames and camera shake with zero custom code.

local Network = require(script.Parent.Network)
local Fx = require(script.Parent.Fx)

local Client = {}

local running = false

function Client.start()
	if running then
		return
	end
	running = true
	Network.startClient()
end

Client.fx = Fx
Client.RequestCarve = Network.requestCarve
Client.RequestExplode = Network.requestExplode
Client.RequestCut = Network.requestCut
Client.RequestBuild = Network.requestBuild

return Client
