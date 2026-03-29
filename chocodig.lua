_addon.name = 'chocodig'
_addon.author = 'VelnerXI'
_addon.version = '3.2'
_addon.commands = {'chocodig', 'cdig'}

local texts = require('texts')
local config = require('config')
local res = require('resources')

local defaults = {
    dig_interval = 4,
    required_distance = 5,
    move_timeout = 8,
    stuck_check_time = 1.0,
    stuck_progress_epsilon = 0.2,
    max_success_digs = 100,
}

local settings = config.load(defaults)

local running = false
local paused = false
local success_count = 0

local DIG_INTERVAL = settings.dig_interval
local REQUIRED_DISTANCE = settings.required_distance
local MOVE_TIMEOUT = settings.move_timeout
local STUCK_CHECK_TIME = settings.stuck_check_time
local STUCK_PROGRESS_EPSILON = settings.stuck_progress_epsilon
local MAX_SUCCESS_DIGS = settings.max_success_digs

local next_dig_time = 0
local last_dig_pos = nil

local moving = false
local move_start_time = 0
local move_start_pos = nil

local progress_check_time = 0
local progress_check_pos = nil

local turn_index = 1
local escape_turn_key = 'right'

local turn_steps = {
    {name = 'right small', key = 'right', hold = 0.10},
    {name = 'left small',  key = 'left',  hold = 0.10},
    {name = 'right med',   key = 'right', hold = 0.22},
    {name = 'left med',    key = 'left',  hold = 0.22},
    {name = 'right large', key = 'right', hold = 0.40},
    {name = 'left large',  key = 'left',  hold = 0.40},
}

local status_box = texts.new('', {
    pos = {x = 1200, y = 200},
    bg = {alpha = 180},
    flags = {
        right = false,
        bottom = false,
        bold = false,
        draggable = true,
    },
    text = {
        font = 'Consolas',
        size = 10,
        alpha = 255,
    },
    padding = 6,
})

local function log(msg)
    windower.add_to_chat(207, ('[ChocoDig] %s'):format(msg))
end

local function get_greens_count()
    local items = windower.ffxi.get_items()
    if not items or not items.inventory or not items.inventory.max then
        return nil
    end

    local count = 0

    for i = 1, items.inventory.max do
        local entry = items.inventory[i]
        if entry and entry.id and entry.id > 0 and entry.count and entry.count > 0 then
            local item = res.items[entry.id]
            local name = item and item.en and item.en:lower() or ''

            if name:find('gysahl greens', 1, true) then
                count = count + entry.count
            end
        end
    end

    return count
end


local function show_help()
    log('Commands:')
    log('//cdig start - Start digging')
    log('//cdig pause - Pause/resume digging')
    log('//cdig stop - Stop digging')
    log('//cdig reset - Reset successful dig counter')
    log('//cdig status - Show current status')
    log('//cdig turnreset - Reset automatic turn cycle')
    log('//cdig distance <number> - Set required movement distance and save it')
    log('//cdig timer <number> - Set dig timer in seconds and save it')
    log('//cdig help - Show this help')
end

local function save_settings()
    settings.dig_interval = DIG_INTERVAL
    settings.required_distance = REQUIRED_DISTANCE
    settings.move_timeout = MOVE_TIMEOUT
    settings.stuck_check_time = STUCK_CHECK_TIME
    settings.stuck_progress_epsilon = STUCK_PROGRESS_EPSILON
    settings.max_success_digs = MAX_SUCCESS_DIGS
    config.save(settings)
end

local function get_me()
    return windower.ffxi.get_mob_by_target('me')
end

local function get_pos()
    local me = get_me()
    if not me then
        return nil
    end

    return {
        x = me.x,
        y = me.y,
        z = me.z,
    }
end

local function distance(a, b)
    if not a or not b then
        return 0
    end

    local dx = (a.x or 0) - (b.x or 0)
    local dy = (a.y or 0) - (b.y or 0)
    local dz = (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function release_all_keys()
    windower.send_command('setkey w up')
    windower.send_command('setkey left up')
    windower.send_command('setkey right up')
end

local function release_turn_keys()
    windower.send_command('setkey left up')
    windower.send_command('setkey right up')
end

local function stop_moving()
    if moving then
        release_all_keys()
    end

    moving = false
    move_start_time = 0
    move_start_pos = nil
    progress_check_time = 0
    progress_check_pos = nil
end

local function stop_addon(reason)
    running = false
    paused = false
    stop_moving()
    status_box:hide()

    if reason then
        log(('Stopped: %s Total successful digs: %d'):format(reason, success_count))
    else
        log(('Stopped. Total successful digs: %d'):format(success_count))
    end
end

local function reset_turn_cycle()
    turn_index = 1
    escape_turn_key = 'right'
end

local function apply_turn()
    local step = turn_steps[turn_index]
    turn_index = turn_index + 1
    if turn_index > #turn_steps then
        turn_index = 1
    end

    log(('Turning %s...'):format(step.name))
    windower.send_command('setkey ' .. step.key .. ' down')
    coroutine.sleep(step.hold)
    windower.send_command('setkey ' .. step.key .. ' up')
end

local function start_moving(escape_mode)
    local pos = get_pos()
    if not pos then
        log('Could not get player position.')
        return
    end

    move_start_pos = pos
    move_start_time = os.clock()
    progress_check_time = os.clock()
    progress_check_pos = pos
    moving = true

    release_turn_keys()
    windower.send_command('setkey w down')

    if escape_mode then
        windower.send_command('setkey ' .. escape_turn_key .. ' down')
        log(('Stuck detected. Holding %s while moving until next dig opens up...'):format(escape_turn_key))
        if escape_turn_key == 'right' then
            escape_turn_key = 'left'
        else
            escape_turn_key = 'right'
        end
    else
        log(('Moving forward to satisfy %.1f-yalm requirement...'):format(REQUIRED_DISTANCE))
    end
end

local function attempt_dig()
    local pos = get_pos()
    if not pos then
        log('Could not get player position.')
        return
    end

    stop_moving()
    last_dig_pos = pos
    next_dig_time = os.clock() + DIG_INTERVAL

    windower.send_command('input /dig')
    log(('Dig attempt sent. Success count: %d'):format(success_count))
end

local function can_dig_from_here()
    local pos = get_pos()
    if not pos then
        return false
    end

    if not last_dig_pos then
        return true
    end

    return distance(pos, last_dig_pos) >= REQUIRED_DISTANCE
end

local function get_state_text()
    if not running then
        return 'Stopped'
    end
    if paused then
        return 'Paused'
    end
    if moving then
        return 'Moving'
    end
    return 'Waiting'
end

local function update_status_box()
    if not running then
        status_box:hide()
        return
    end

    local now = os.clock()
    local countdown = math.max(0, math.ceil(next_dig_time - now))
    local dist = 0

    local pos = get_pos()
    if pos and last_dig_pos then
        dist = distance(pos, last_dig_pos)
    end

    local greens = get_greens_count()
    local greens_text = greens ~= nil and tostring(greens) or '?'

    local text = string.format(
        'ChocoDig\nState: %s\nSuccesses: %d / %d\nGreens: %s\nNext Dig: %ds\nDistance: %.2f / %.2f\nDig Timer: %.2fs\nTurn Step: %d / %d\nEscape Turn: %s',
        get_state_text(),
        success_count,
        MAX_SUCCESS_DIGS,
        greens_text,
        countdown,
        dist,
        REQUIRED_DISTANCE,
        DIG_INTERVAL,
        turn_index,
        #turn_steps,
        escape_turn_key
    )

    status_box:text(text)
    status_box:show()
end

windower.register_event('addon command', function(cmd, ...)
    cmd = cmd and cmd:lower() or nil
    local args = {...}

    if not cmd then
        show_help()
        return
    end

    if cmd == 'help' then
        show_help()
        return
    end

    if cmd == 'start' then
        running = true
        paused = false
        next_dig_time = 0
        reset_turn_cycle()
        update_status_box()
        log('Started. Make sure you are already mounted on a chocobo.')
        return
    end

    if cmd == 'pause' then
        if not running then
            log('Not running.')
            return
        end

        paused = not paused
        stop_moving()

        if paused then
            log('Paused.')
        else
            log('Resumed.')
            if not can_dig_from_here() then
                start_moving(false)
            end
        end

        update_status_box()
        return
    end

    if cmd == 'stop' then
        stop_addon(nil)
        return
    end

    if cmd == 'reset' then
        success_count = 0
        log('Success counter reset to 0.')
        update_status_box()
        return
    end

    if cmd == 'turnreset' then
        reset_turn_cycle()
        log('Automatic turn cycle reset.')
        update_status_box()
        return
    end

    if cmd == 'distance' then
        local new_distance = tonumber(args[1])

        if not new_distance or new_distance <= 0 then
            log('Usage: //cdig distance <number>')
            return
        end

        REQUIRED_DISTANCE = new_distance
        save_settings()
        log(('Required distance set to %.2f yalms and saved.'):format(REQUIRED_DISTANCE))
        update_status_box()
        return
    end

    if cmd == 'timer' then
        local new_timer = tonumber(args[1])

        if not new_timer or new_timer <= 0 then
            log('Usage: //cdig timer <number>')
            return
        end

        DIG_INTERVAL = new_timer
        save_settings()
        log(('Dig timer set to %.2f seconds and saved.'):format(DIG_INTERVAL))
        update_status_box()
        return
    end

    if cmd == 'status' then
        local greens = get_greens_count()
        local greens_text = greens ~= nil and tostring(greens) or '?'

        log(('running=%s paused=%s moving=%s success_count=%d distance=%.2f timer=%.2f greens=%s'):format(
            tostring(running),
            tostring(paused),
            tostring(moving),
            success_count,
            REQUIRED_DISTANCE,
            DIG_INTERVAL,
            greens_text
        ))
        return
    end

    log('Unknown command. Use //cdig help')
end)

windower.register_event('prerender', function()
    update_status_box()

    if not running or paused then
        return
    end

    local greens = get_greens_count()
    if greens ~= nil and greens <= 0 then
        stop_addon('Out of Gysahl Greens.')
        return
    end

    local now = os.clock()

    if not moving and now < next_dig_time and not can_dig_from_here() then
        start_moving(false)
        return
    end

    if moving then
        local pos = get_pos()

        if pos and move_start_pos and distance(pos, move_start_pos) >= REQUIRED_DISTANCE then
            stop_moving()
            log(('Distance reached: %.2f yalms. Waiting for dig timer...'):format(distance(pos, move_start_pos)))
            return
        end

        if pos and progress_check_pos and (now - progress_check_time) >= STUCK_CHECK_TIME then
            local progress = distance(pos, progress_check_pos)

            if progress < STUCK_PROGRESS_EPSILON then
                stop_moving()
                start_moving(true)
                return
            else
                progress_check_time = now
                progress_check_pos = pos
            end
        end

        if now - move_start_time >= MOVE_TIMEOUT then
            stop_moving()
            log('Movement timed out. Turning and retrying...')
            apply_turn()
            start_moving(false)
            return
        end

        return
    end

    if now < next_dig_time then
        return
    end

    if can_dig_from_here() then
        attempt_dig()

        if running and not paused then
            start_moving(false)
        end
    else
        start_moving(false)
    end
end)

windower.register_event('incoming text', function(original, modified, original_mode, modified_mode, blocked)
    if not running or not original then
        return
    end

    local line = original:lower()

    if line:find('gysahl greens', 1, true) and (line:find("don't have", 1, true) or line:find("dont have", 1, true) or line:find("do not have", 1, true)) then
        stop_addon('Out of Gysahl Greens.')
        return
    end

    if line == "you dig and you dig, but you find nothing." then
        log(('Dig failed. Success count: %d'):format(success_count))
        return
    end

    local obtained_item = original:match('^Obtained:')
    local beastman_cache = original:match('^You discover a cache of beastman resources and receive %d+ conquest points%.$')

    if obtained_item or beastman_cache then
        success_count = success_count + 1

        if beastman_cache then
            log(('Successful dig! Beastman resource cache found. Success count: %d'):format(success_count))
        else
            log(('Successful dig! Success count: %d'):format(success_count))
        end

        update_status_box()

        if success_count >= MAX_SUCCESS_DIGS then
            stop_addon(('Reached %d successful digs.'):format(MAX_SUCCESS_DIGS))
        end
        return
    end
end)

windower.register_event('zone change', function()
    if running then
        stop_addon('Zone change detected.')
    end
end)

windower.register_event('logout', function()
    if running then
        stop_addon('Logout detected.')
    end
end)


windower.register_event('load', function()
    local greens = get_greens_count()
    local greens_text = greens ~= nil and tostring(greens) or '?'
    status_box:text(('ChocoDig\nState: Loaded\nGreens: %s\nUse //cdig start'):format(greens_text))
    status_box:show()
end)

windower.register_event('unload', function()
    stop_moving()
    status_box:hide()
end)
