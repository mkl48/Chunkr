-- Client boot: thin by design. Bodies replicate natively as Parts; the client
-- only sends tool intents (Network.request*) and receives FX payloads
-- (Events.OnFx) to drive local particles/sounds.

local Network = require(script.Parent.Network)

local Client = {}

local running = false

function Client.start()
	if running then
		return
	end
	running = true
	Network.startClient()
end

Client.RequestCarve = Network.requestCarve
Client.RequestExplode = Network.requestExplode
Client.RequestCut = Network.requestCut

return Client
