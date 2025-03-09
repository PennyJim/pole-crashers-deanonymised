---@class PoleCrashersDeanonymised
---@field car_drivers table<uint,LuaPlayer?>
storage = storage

local function setup_storage()
	storage.car_drivers = storage.car_drivers or {}
end

script.on_init(function ()
	setup_storage()
end)
script.on_configuration_changed(function (p1)
	setup_storage()
end)


--- How many networks would exist without this connector
---@param connector LuaWireConnector
---@return uint
local function splitting_connection(connector)
	if connector.real_connection_count == 0 then
		log("Pole had no real connections of tested type")
		return 0
	end
	local connections = connector.connections
	local real_connections = connector.real_connections

	---@type table<uint,true>
	local networks = {}
	local networks_count = 0

	-- Disconnect every connection
	connector.disconnect_all()
	-- Record and count the disconnected networks
	for _, connection in pairs(real_connections) do
		networks[connection.target.network_id] = true
	end
	for _ in pairs(networks) do
		networks_count = networks_count + 1
	end
	-- Reconnect so the ghost preserves it
	for _, connection in pairs(connections) do
		if connection.origin == defines.wire_origin.player then
			connector.connect_to(connection.target, false)
		end
	end

	return networks_count
end

--- How many networks would exist without these connectors
---@param connectors table<defines.wire_connector_id,LuaWireConnector>
---@return table<defines.wire_connector_id, uint>
local function splitting_connections(connectors)
	---@type table<defines.wire_connector_id, uint>
	local networks = {}
	for connector_id, connector in pairs(connectors) do
		local new_networks = splitting_connection(connector)
		if new_networks > 1 then
			networks[connector_id] = new_networks
		end
	end
	return networks
end

---@type boolean?
local has_better_chat = nil
local send_levels = {
  ["LuaGameScript"] = "global",
  ["LuaForce"] = "force",
  ["LuaPlayer"] = "player",
  ["LuaSurface"] = "surface",
}
--- Safely attempts to print via the Better Chatting's interface
---@param recipient LuaGameScript|LuaForce|LuaPlayer|LuaSurface
---@param msg LocalisedString
---@param print_settings PrintSettings?
local function compat_send(recipient, msg, print_settings)
  if has_better_chat == nil then
    local better_chat = remote.interfaces["better-chat"]
    has_better_chat = better_chat and better_chat["send"]
  end

  if not has_better_chat then return recipient.print(msg, print_settings) end
  print_settings = print_settings or {}


  local send_level = send_levels[recipient.object_name]
  ---@type int?
  local send_index
  if send_level ~= "global" then
    send_index = recipient.index
		if not send_index then
			error("Invalid Recipient", 2)
		end
  end

  remote.call("better-chat", "send", {
    message = msg,
    send_level = send_level,
    color = print_settings.color,
    recipient = send_index,
  })
end

---Returns the LocalisedString of the user's name with color
---@param player LuaPlayer
---@return LocalisedString
local function colored_username(player)
	local color = player.chat_color
	return {"pcd.colored",
		player.name,
		color.r,
		color.g,
		color.b,
	}
end

--MARK: Vehicle driver tracking

script.on_event(defines.events.on_player_driving_changed_state, function (event)
	local player = game.get_player(event.player_index)
	if not player then error("How did the player driving change state, if there's no player???") end
	local new_vehicle = player.vehicle

	if not new_vehicle then return end -- They're just leaving the vehicle
	if new_vehicle.type ~= "car" then return end -- We don't care about non-cars

	storage.car_drivers[new_vehicle.unit_number--[[@as uint]]] = player
	script.register_on_object_destroyed(new_vehicle)
end)

-- Do not memory leak cars that die
script.on_event(defines.events.on_object_destroyed, function (event)
	storage.car_drivers[event.useful_id] = nil
end)

--MARK: Death reaction
script.on_event(defines.events.on_entity_died, function (event)
	if event.damage_type.name ~= "impact" then return end -- Didn't die to impact

	local vehicle = event.cause
	if not vehicle or vehicle.type ~= "car" then return log("Pole didn't die to a Vehicle") end
	local driver = vehicle.get_driver() or storage.car_drivers[vehicle.unit_number]
	if not driver then return log ("Pole was run over by a vehicle with no driver?") end

	if driver.object_name == "LuaEntity" then
		driver = driver.player or driver.associated_player--[[@as LuaPlayer]]
		if not driver then return error("How can a driver not be associated with a LuaPlayer?") end
	end

	local entity = event.entity
	local split_networks = splitting_connections(entity.get_wire_connectors(false))

	---@type LocalisedString
	local message = {"pcd.deanonymised-pole-destruction",
		colored_username(driver),
		entity.gps_tag
	}

	if next(split_networks) then
		message = {"", message, "\n", {"pcd.network-splitting-header"}}
		local count = 4

		for network_type, new_networks  in pairs(split_networks) do
			if new_networks > 1 then
				message[count + 1] = "\n\t"
				message[count + 2] = {"pcd.network-splitting-entry", network_type, new_networks}
				count = count + 2
			end
		end

		-- Modify the header into a sole entry if it's only 1
		local network_type_splits = math.floor((count - 4) / 2)
		if network_type_splits == 1 then
			message[4] = message[6]
			message[4][1] ="pcd.network-split-sole"

			message[5] = nil
			message[6] = nil
		end
	end

	compat_send(game, message)
	log("REPORTED")
end,
{
	{
		filter = "type",
		type = "electric-pole",
	}
})