---@class PoleCrashersDeanonymised
---@field car_drivers table<uint,LuaPlayer?>
---@field dying_pole table<uint, pole_dying_info>
storage = storage

---@class pole_dying_info
---@field connections table<defines.wire_connector_id, LuaWireConnector[]>
---@field driver LuaPlayer
---@field gps_tag string

local function setup_storage()
	storage.car_drivers = storage.car_drivers or {}
	storage.dying_pole = storage.dying_pole or {}
end

script.on_init(function ()
	setup_storage()
end)
script.on_configuration_changed(function (p1)
	setup_storage()
end)

---@param connector LuaWireConnector
---@return LuaWireConnector[]
local function get_real_connections(connector)
	---@type LuaWireConnector[]
	local connections, index = {}, 0
	for _, connection in pairs(connector.real_connections) do
		local other_connector = connection.target
		index = index + 1
		connections[index] = other_connector
	end
	return connections
end
---@param connectors table<defines.wire_connector_id, LuaWireConnector>
---@return table<defines.wire_connector_id, LuaWireConnector[]>
local function get_all_real_connections(connectors)
	---@type table<defines.wire_connector_id, LuaWireConnector[]>
	local all_connections = {}
	for connector_id, connector in pairs(connectors) do
		all_connections[connector_id] = get_real_connections(connector)
	end
	return all_connections
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
	local connectors = entity.get_wire_connectors(false)
	-- local split_networks = splitting_connections(connectors)

	storage.dying_pole[entity.unit_number--[[@as uint]]] = {
		driver = driver,
		gps_tag = entity.gps_tag,
		connections = get_all_real_connections(connectors)
	}
end,
{
	{
		filter = "type",
		type = "electric-pole",
	}
})

script.on_event(defines.events.on_post_entity_died, function (event)
	if not event.unit_number then return end
	local pole_info = storage.dying_pole[event.unit_number--[[@as uint]]]
	if not pole_info then return end

	---@type LocalisedString
	local message = {"pcd.deanonymised-pole-destruction",
		colored_username(pole_info.driver),
		pole_info.gps_tag
	}

	---@type table<defines.wire_connector_id, uint>
	local split_networks = {}

	for connector_type, connections in pairs(pole_info.connections) do
		---@type table<uint,true>
		local networks = {}
		for _, connector in pairs(connections) do
			if connector.valid then
				networks[connector.network_id] = true
			end
		end

		local size = table_size(networks)
		if size > 1 then
			split_networks[connector_type] = size
		end
	end

	if next(split_networks) then
		message = {"", message, "\n", {"pcd.network-splitting-header"}}
		local count = 4

		for network_type, new_networks  in pairs(split_networks) do
			if new_networks > 1 then
				message[count + 1] = "\n\t- "
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