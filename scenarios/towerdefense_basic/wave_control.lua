local Math = require("Utils.Maths")

local mod_gui = require("mod-gui")
local Table = require("Utils.Table")
local GuiUtils = require("Utils.Gui")
local GuiEvent = require("stdlib.event.gui")
local Event = require("stdlib.event.event")


require("util")


local WaveCtrl = {}

global.wave_controls_all = global.wave_controls_all or {}




-- Custom Events

WaveCtrl.on_wave_starting = script.generate_event_name()
-- {wave_index, waves_ended}
WaveCtrl.on_wave_destroyed = script.generate_event_name()
-- {wave_index, game_ended,  wave_control}



-- Utilities

function WaveCtrl.wave_decode(unit_string, factor)
    local units = {}
    local unit_keys = {
        ["1"] = "small-biter",
        ["a"] = "small-spitter",
        ["2"] = "medium-biter",
        ["b"] = "medium-spitter",
        ["3"] = "big-biter",
        ["c"] = "big-spitter",
        ["4"] = "behemoth-biter",
        ["d"] = "behemoth-spitter",
    }

    for i = 1, #unit_string do
        local c = unit_string:sub(i, i)
        if unit_keys[c] then 
            local added_unit = unit_keys[c]
            if units[added_unit] then 
                units[added_unit] = units[added_unit] + (factor or 1)
            else 
                units[added_unit] = factor or 1
            end
        else
            error("Wave Data error. >" .. c .. "<. " .. debug.traceback())
        end
    end

    return units
end





-- UI
------------------------------------------------------------------------------



local function update_wave_icons(wave_control, element)
    if not wave_control then return end
    element.clear()
    if wave_control.spawning_wave_index >= 1 then
        local wave
        if wave_control.wave_active then
            wave = wave_control.waves[wave_control.active_wave_index]
        else
            wave = wave_control.waves[wave_control.spawning_wave_index]
        end
        if wave then
            element.style.visible = true
            for entity_name, count in pairs(wave.unit_counts) do
                if entity_name ~= "total" then
                    for i = 1, math.ceil(count / 50) do
                        element.add{type="sprite", name="wave_sprite_" .. entity_name .. i, sprite = "entity/" .. entity_name, tooltip={"entity-name." .. entity_name}}
                    end
                end
            end
        end
    end
end

 function WaveCtrl.create_ui(player, wave_control)
    local mod_flow = mod_gui.get_frame_flow(player)
    if mod_flow.wave_frame and mod_flow.wave_frame.valid then
        WaveCtrl.destroy_ui(player)
    end

    local frame = mod_flow.add{type="frame", direction="vertical", name="wave_frame", caption="Wave starting soon."}

    -- Icons for next or current wave units
    local flow = frame.add{type="flow", name="wave_display_flow", direction="horizontal"}
    update_wave_icons(wave_control, flow)

    GuiUtils.make_hide_button(player, frame, true, "entity/medium-biter")
    wave_control.players_with_ui[player.index] = true
end

function WaveCtrl.update_ui(player, wave_control)
    local mod_flow = mod_gui.get_frame_flow(player)
    if not mod_flow.wave_frame or not mod_flow.wave_frame.valid then
        return
    end

    if wave_control.spawning_wave_index < 1 then return end
    local total_wave_count = #wave_control.waves
    if wave_control.active_wave_index < total_wave_count or wave_control.wave_active then
        if wave_control.wave_active then
            mod_flow.wave_frame.caption = "Wave " .. wave_control.active_wave_index .. " active!"
        else
            mod_flow.wave_frame.caption = "Wave " .. wave_control.spawning_wave_index .. " / " .. total_wave_count .. " in " .. Math.prettytime(wave_control.next_wave_tick - game.tick, true)
        end
    else
        mod_flow.wave_frame.caption = "Waves Ended"
    end
end

function WaveCtrl.destroy_ui(player)
    local mod_flow = mod_gui.get_frame_flow(player)
    if mod_flow.wave_frame and mod_flow.wave_frame.valid then
        mod_flow.wave_frame.destroy()
    end

    for _, wave_control in pairs(global.wave_controls_all) do
        wave_control.players_with_ui[player.index] = nil
    end
end




-- Core Logic
------------------------------------------------------------------------------


local function move_next_group(wave_control)
    local active_wave = wave_control.waves[wave_control.active_wave_index]
    if not active_wave then
        return
    end

    -- TODO Finish
    local next_tick
    for _, lane in pairs(active_wave.lanes) do
        if game.tick > lane.next_active_tick then
            -- Pick group
            local group = lane.groups[lane.waiting_group_index]

            if group then
                group.group_object.set_command(table.deepcopy(lane.move_cmd))
                -- Free waiting area
                lane.buffers[group.buffer_key].occupied = false
            end

            lane.waiting_group_index = lane.waiting_group_index + 1
            local next_group = lane.groups[lane.waiting_group_index]
            if next_group then
                lane.next_active_tick = active_wave.group_size * active_wave.group_time_factor + (lane.buffers.max_dist - Math.distance(lane.path[2], next_group.buffer_position)) / 5 - 5
            else
                lane.next_active_tick = nil
            end
            -- local next_group = lane.groups[ind]
            lane.next_active_tick = active_wave.group_size * active_wave.group_time_factor + (lane.buffers.max_dist - lane.buffers[group.buffer_key]) / 5

        end

        if not next_tick or lane.next_active_tick < next_tick then
            next_tick = lane.next_active_tick
        end
    end
    return next_tick
end


local function spawn_next_unit(wave_control, time_left)
    local index = wave_control.spawning_wave_index
    local spawning_wave = wave_control.waves[index]
    if not spawning_wave or spawning_wave.finished_spawning then
        return nil
    end

    -- Randomly pick Wave
    local lane_name = Math.roulette_choice(spawning_wave.weights)
    local lane = spawning_wave.lanes[lane_name]

    -- Pick Unit Type
    local total = spawning_wave.to_spawn.total
    spawning_wave.to_spawn.total = nil
    local unit_type = Math.roulette_choice(spawning_wave.to_spawn)
    spawning_wave.to_spawn.total = total

    -- Spawn Unit
    spawning_wave.to_spawn[unit_type] = spawning_wave.to_spawn[unit_type] - 1
    spawning_wave.to_spawn.total = spawning_wave.to_spawn.total - 1
    local position = wave_control.surface.find_non_colliding_position(unit_type, lane.path[1], 10, 1)
    local unit = wave_control.surface.create_entity{name=unit_type, position = position, force=wave_control.wave_force, }
    wave_control.wave_units_by_index[index] = wave_control.wave_units_by_index[index] or {}
    wave_control.wave_units_by_index[index][unit.unit_number] = true

    -- Assign group
    local groups = lane.groups
    local group
    if groups[#groups] then group = groups[#groups].group_object end
    if not group or #group.members >= spawning_wave.group_size then
        -- Select waiting area
        local free_buffer_weights = {}
        local have_buffer = false
        for k, b in pairs(lane.buffers) do
            if not b.occupied then
                free_buffer_weights[k] = b.weight
                have_buffer = true
            end
        end
        if not have_buffer then
            error("No free waiting area! Wave " .. index .. ", Lane " .. lane_name)
        end
        local buffer_key = Math.roulette_choice(free_buffer_weights)
        local buffer = lane.buffers[buffer_key]
        buffer.occupied = true

        -- Create group
        group = wave_control.surface.create_unit_group{position=buffer.position, force=wave_control.wave_force}
        table.insert(groups, {group_object = group, lane_name = lane_name, buffer_key = buffer_key})
        -- local command = {
        --     type = defines.command.wander,
        --     distraction = defines.distraction.none,
        -- }
        -- group.set_command(command)
    end
    group.add_member(unit)

    -- Check if this wave is finished spawning
    if spawning_wave.to_spawn.total <= 0 then
        spawning_wave.finished_spawning = true
        return
    end

    return math.floor(time_left / spawning_wave.to_spawn.total)
end



function WaveCtrl.next_wave(wave_control)
    if wave_control.active_wave_index >= #wave_control.waves then 
        return 
    end

    -- Update wave indices
    wave_control.active_wave_index = wave_control.spawning_wave_index
    wave_control.spawning_wave_index = wave_control.spawning_wave_index + 1

    -- Update Player UI
    for player_index, has_ui in pairs(wave_control.players_with_ui) do
        local player = game.players[player_index]
        if has_ui then 
            local mod_flow = mod_gui.get_frame_flow(player)            
            update_wave_icons(wave_control, mod_flow.wave_frame.wave_display_flow)
        end
    end
    
    local active_wave = wave_control.waves[wave_control.active_wave_index]
    local waves_ended = active_wave == nil
    
    -- Raise event
    local event = {
        wave_index = wave_control.active_wave_index,
        waves_ended = waves_ended
    }
    script.raise_event(WaveCtrl.on_wave_starting, event)

    
    -- If this is the first wave, only start spawning
    if wave_control.active_wave_index == 0 then
        wave_control.next_wave_tick = game.tick + wave_control.initial_wait
        wave_control.next_unit_tick = 1
    else
        -- Restart spawning and moving units
        wave_control.wave_active = true
        
        if not waves_ended then
            wave_control.next_group_tick = 1
            wave_control.next_unit_tick = 1
            wave_control.next_wave_tick = game.tick + active_wave.duration
        end

        -- Sort list of spawned groups by distance to first waypoint
        for _, lane in pairs(active_wave.lanes) do
            table.sort(
                lane.groups, 
                function(a, b) 
                    return Math.sqdistance(a.buffer_position, lane.path[2]) < Math.sqdistance(b.buffer_position, lane.path[2]) 
                end
            )
        end
    end
end



function WaveCtrl.main(wave_control)
    local function check(tick)
        return tick ~= nil and game.tick >= tick
    end

    -- (TODO): Get a better system.
    -- TODO: Spawn new wave or wait and end game.
    if check(wave_control.next_wave_tick) then
        WaveCtrl.next_wave(wave_control)
    end

    -- Move next group
    if check(wave_control.next_group_tick) then
        local next_group_in = move_next_group(wave_control)
        if not next_group_in then
            wave_control.next_group_tick = nil
        else
            wave_control.next_group_tick = game.tick + next_group_in
        end
    end

    -- Spawn unit for pending wave
    if check(wave_control.next_unit_tick) then
        local time_left = (wave_control.next_wave_tick - game.tick - 60*10)
        if time_left < 0 then error("Error in wave data: Not enough time to spawn units!") end
        local next_unit_in = spawn_next_unit(wave_control, time_left)
        if not next_unit_in then
            wave_control.next_unit_tick = nil
        else
            wave_control.next_unit_tick = game.tick + next_unit_in
        end
    end


    -- TODO: Game End
end



Event.register(defines.events.on_entity_died, function(event)
    local ent = event.entity
    if ent.type == "unit" then
        for _, wave_control in pairs(global.wave_controls_all) do
            if not wave_control.ended then 
                for wave_ind, wave in pairs(wave_control.wave_units_by_index) do 
                    if wave[ent.unit_number] then
                        wave[ent.unit_number] = nil

                        -- Wave ended
                        if next(wave) == nil then
                            wave_control.wave_active = false

                            -- Update Player UI
                            for player_index, has_ui in pairs(wave_control.players_with_ui) do
                                local player = game.players[player_index]
                                if has_ui then 
                                    local mod_flow = mod_gui.get_frame_flow(player)            
                                    update_wave_icons(wave_control, mod_flow.wave_frame.wave_display_flow)
                                end
                            end

                            wave_control.wave_units_by_index[wave_ind] = nil
                            local game_ended = (wave_ind == #wave_control.waves)
                            if game_ended then WaveCtrl.next_wave(wave_control) end

                            local raised_event = {wave_index = wave_ind, game_ended = game_ended,  wave_control = wave_control}
                            script.raise_event(WaveCtrl.on_wave_destroyed, raised_event)
                            break
                        end
                    end
                end
            end
        end
    end
end)





-- More External Controls
------------------------------------------------------------------------------

function WaveCtrl.delay_wave(wave_control, time)
    wave_control.next_wave_tick = wave_control.next_wave_tick + time
end



-- Example for wave:
-- wave = {
--     lanes = {...}, -- Lanes objects, see example at bottom of file.
--     group_size = 15,
--     unit = {"3b", 5},  -- short form
--     to_spawn = {  -- or long form
--         ["big-biter"] = 5,
--         ["medium-spitter"] = 5,
--     },
--     duration = 60*60*1.5
-- }

function WaveCtrl.make_wave(wave_control, wave)
    wave.finished_spawning = false
    wave.group_size = wave.group_size or 15
    wave.group_time_factor = wave.group_time_factor or 20
    for _, lane in pairs(wave.lanes) do
        lane.waiting_group_index = 1
        lane.groups = {}

        -- Make Unit Move Command for this lane
        if not lane.move_cmd then
            lane.move_cmd = {
                type = defines.command.compound,
                structure_type = defines.compound_command.return_last,
                distraction = defines.distraction.none,
                commands = {},
            }

            for i=2, #lane.path-1 do
                local pos = lane.path[i]
                table.insert(lane.move_cmd.commands, {
                    type = defines.command.go_to_location,
                    destination = pos,
                    distraction = defines.distraction.none
                })
            end
            local silo = game.surfaces.nauvis.find_entities_filtered{name="rocket-silo"}[1]
            table.insert(lane.move_cmd.commands, {
                type = defines.command.attack,
                target = silo,
                distraction = defines.distraction.none,
            })
        end
    end
    if not wave.to_spawn and wave.unit then
        wave.to_spawn = WaveCtrl.wave_decode(wave.unit[1], wave.unit[2])
    end
    if not wave.to_spawn.total then 
        local total = 0
        for _, m in pairs(wave.to_spawn) do
            total = total + m
        end
        wave.to_spawn.total = total
    end
    wave.unit_counts = Table.deepcopy(wave.to_spawn)

    -- Gather buffer positions per lane.
    for lane_name, lane in pairs(wave.lanes) do
        local buffers = {}
            
        if not lane.buffers then error("Lane " .. lane_name .. " is missing waiting areas!") end
        for _, buffer in pairs(lane.buffers) do
            table.insert(lane.buffers, {
                position = buffer,
                occupied = false,
                weight = Math.sqdistance(lane.path[1], buffer),
                distance = Math.distance(lane.path[2], buffer),
            })
        end
        table.sort(buffers, function(a, b) return a.distance < b.distance end)
        lane.buffers = buffers
    end

    -- Gather lane weights for randomized lane choosing later
    local lane_weights = {}
    for k, lane in pairs(wave.lanes) do
        lane_weights[k] = lane.weight
    end
    wave.weights = lane_weights


    table.insert(wave_control.waves, wave)
end

-- params = {
--     initial_wait, 
--     surface, 
--     wave_force,
-- }

function WaveCtrl.init(params)
    local wave_control = {
        initial_wait = params.initial_wait or 60*60, 
        wave_force = params.wave_force or game.forces.enemy,
        surface = params.surface or game.surfaces.nauvis,
        next_wave_tick = 60,
        spawning_wave_index = 0, -- Points to wave that is moved to waiting position currently
        active_wave_index = -1,
        waves = {},
        buffers = {},
        wave_units_by_index = {},
        players_with_ui = {}
    }

    local i = 1 
    while global.wave_controls_all[i] do
        i = i + 1
    end
    global.wave_controls_all[i] = wave_control

    return wave_control
end

function WaveCtrl.stop(wave_control, win)
    -- Stop spawning etc.
    wave_control.next_wave_tick = nil
    wave_control.next_unit_tick = nil
    wave_control.next_group_tick = nil

    -- Initiate biter celebration 
    local cmd = {
        type = defines.command.attack,
        target = nil,
        distraction = defines.distraction.none,
    }
    for _, unit in pairs(wave_control.surface.find_entities_filtered{type="unit", force = wave_control.wave_force}) do
        cmd.target = unit
        unit.set_command(cmd)
    end

    wave_control.ended = true
end

function WaveCtrl.destroy(wave_control)
    for _, player in pairs(game.players) do
        WaveCtrl.destroy_ui(player)
    end

    global.wave_controls_all[wave_control.index] = nil
end


return WaveCtrl





-- Wave control data overview

--     wave_control = {
--         ended = false,
--         wave_active = false,
--         next_wave_tick = 60*60, 
--         next_unit_tick = 0,
--         next_group_tick = 0,
--         spawning_wave_index = 0, -- Points to wave that is moved to waiting position currently
--         active_wave_index = 0, -- Points to wave that is walking on lanes currently
--         wave_force = "enemy",
--         players_with_ui = {1=true, 2=false, ...} 
--         surface = game.surfaces.nauvis,
--         buffers = {
--             lane_name = {
--                 {position = {x, y}, occupied = false},
--             }
--         },
--         waves = {
--             [1] = {
--                 finished_spawning = false,
--                 lanes = {
--                     ["lane1"] = {
--                         weight = 1, 
--                         path = {pos1, pos2, ...},
--                         buffers = {buffer1, buffer2},
--                         groups = { {group_obj = ..., buffer_position = ..., lane_name = ... } },
--                         max_buffer_dist = ...,
--                         waiting_group_index = 1,
--                         move_cmd = {},
--                         next_active_tick = ...,
--                     }
--                 },
--                 group_size = 15,
--                 group_time_factor = 20, -- Time interval between sending groups is calculated as group size times this.
--                 to_spawn = {
--                     ["big-biter"] = 5,
--                     ["big-spitter"] = 5,
--                     total = 10,
--                 },
--                 unit_counts = {} -- copy of to_spawn that doesnt get modified during the game
--                 duration = 60*60*1.5,
--             },
--         },-
--         wave_units_by_index = { -- Lists unit numbers for all units of all waves.
--             1 = {}
--         }
--         index -- unique identifier for wave control in global.wave_controls_all
--     }
