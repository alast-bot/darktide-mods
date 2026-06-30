local mod = get_mod("true_level")
local Promise = require("scripts/foundation/utilities/promise")

mod._info = {
    title = "True Level",
    author = "Zombine",
    date = "2026/06/24",
    version = "1.10.1",
}
mod:info("Version " .. mod._info.version)

local ProfileUtils = require("scripts/utilities/profile_utils")

mod._self = mod:persistent_table("self")
mod._others = mod:persistent_table("others")
mod._queue = mod:persistent_table("queue")
mod._havoc_promises = mod:persistent_table("havoc")
mod._xp_settings = mod:persistent_table("xp_settings")
mod._xp_promise = nil
mod._synced = {}
mod._is_in_hub = false
mod._fetch_xp_settings = function()
    local xp_settings = mod._xp_settings

    if table.is_empty(xp_settings) and not mod._xp_promise then
        local backend_interface = Managers.backend.interfaces
        local xp_promise = backend_interface.progression:get_xp_table("character")

        mod._xp_promise = true
        mod:info("fetching xp settings...")

        xp_promise:next(function(xp_per_level_array)
            local max_level = #xp_per_level_array

            xp_settings.level_array = xp_per_level_array
            xp_settings.total_xp = xp_per_level_array[max_level]
            xp_settings.max_level = max_level
            mod.debug.dump(xp_settings, "xp_settings")

            local queue = mod._queue

            if not table.is_empty(queue) then
                for char_id, args in pairs(queue) do
                    mod.cache_true_levels(unpack(args))
                    queue[char_id] = nil
                end
            end

            mod._xp_promise = nil
            mod.desync_all()
        end):catch(function(e)
            mod:dump(e, "xp_settings", 3)
        end)
    end
end

local _number_or_nil = function(value)
    if type(value) == "number" then
        return value
    elseif type(value) == "string" and value ~= "none" and value ~= "" then
        return tonumber(value)
    end

    return nil
end

local _nested_number = function(data, key_a, key_b)
    local nested = type(data) == "table" and data[key_a]

    if type(nested) == "table" then
        return _number_or_nil(nested[key_b])
    end

    return nil
end

local _valid_string_id = function(value)
    return type(value) == "string" and value ~= ""
end

local _raw_key_value = function(container, key)
    local value = container and container[key]

    if type(value) == "table" then
        return value.value
    end

    return value
end

local _presence_key_value = function(presence_entry, key)
    local immaterium_entry = presence_entry and presence_entry._immaterium_entry
    local key_values = immaterium_entry and immaterium_entry.key_values

    return _raw_key_value(key_values, key)
end

local _presence_key_values = function(presence_entry)
    local immaterium_entry = presence_entry and presence_entry._immaterium_entry

    return immaterium_entry and immaterium_entry.key_values or nil
end

local _lower_string = function(value)
    return string.lower(tostring(value or ""))
end

local _havoc_key_score = function(key)
    local lower_key = _lower_string(key)
    local has_havoc = lower_key:find("havoc", 1, true) ~= nil
    local has_rank = lower_key:find("rank", 1, true) ~= nil
        or lower_key:find("order", 1, true) ~= nil
        or lower_key:find("level", 1, true) ~= nil

    if not has_havoc or not has_rank then
        return nil
    end

    local score = 1

    if lower_key:find("cadence", 1, true) then
        score = score + 100
    end

    if lower_key:find("high", 1, true) or lower_key:find("highest", 1, true) then
        score = score + 30
    end

    if lower_key:find("current", 1, true) then
        score = score + 20
    end

    if lower_key:find("all", 1, true) or lower_key:find("time", 1, true) then
        score = score + 10
    end

    return score
end

local _rank_from_raw_value = function(value)
    local raw_value = value

    if type(raw_value) == "table" and raw_value.value ~= nil then
        raw_value = raw_value.value
    end

    local rank = _number_or_nil(raw_value)

    if rank and rank > 0 then
        return rank
    end

    if type(raw_value) == "string" and cjson then
        local first = string.sub(raw_value, 1, 1)

        if first == "{" or first == "[" then
            local ok, decoded = pcall(cjson.decode, raw_value)

            if ok and type(decoded) == "table" then
                return _number_or_nil(decoded.rank_cadence)
                    or _number_or_nil(decoded.havoc_rank_cadence_high)
                    or _number_or_nil(decoded.rank_all_time)
                    or _number_or_nil(decoded.havoc_rank_all_time_high)
                    or _number_or_nil(decoded.havoc_rank)
                    or _number_or_nil(decoded.rank)
            end
        end
    end

    return nil
end

local _scan_havoc_rank_table = function(data)
    if type(data) ~= "table" then
        return nil, nil
    end

    local best_rank = nil
    local best_key = nil
    local best_score = -1

    for key, value in pairs(data) do
        local score = _havoc_key_score(key)

        if score then
            local rank = _rank_from_raw_value(value)

            if rank and score > best_score then
                best_rank = rank
                best_key = tostring(key)
                best_score = score
            end
        end
    end

    return best_rank, best_key
end

local _havoc_debug_seen = {}

local _log_presence_havoc_keys = function(account_id, key_values, rank, rank_key)
    if type(key_values) ~= "table" then
        return
    end

    local seen_key = account_id or tostring(key_values)
    local t = 0
    local time_manager = Managers and Managers.time

    if time_manager and time_manager.time then
        local ok, time_value = pcall(time_manager.time, time_manager, "main")

        if ok and time_value then
            t = time_value
        end
    end

    if _havoc_debug_seen[seen_key] and _havoc_debug_seen[seen_key] > t then
        return
    end

    _havoc_debug_seen[seen_key] = t + 60

    local found = {}

    for key, value in pairs(key_values) do
        local lower_key = _lower_string(key)

        if lower_key:find("havoc", 1, true) or lower_key:find("rank", 1, true) then
            local raw_value = value

            if type(raw_value) == "table" and raw_value.value ~= nil then
                raw_value = raw_value.value
            end

            found[#found + 1] = tostring(key) .. "=" .. tostring(raw_value)
        end
    end

    if #found > 0 then
        local status = rank and "rank " .. tostring(rank) .. " from " .. tostring(rank_key or "known method") or "no rank"

        mod:info("Havoc presence scan " .. tostring(account_id or "unknown") .. ": " .. status .. "; " .. table.concat(found, ", "))
    else
        mod:info("Havoc presence scan " .. tostring(account_id or "unknown") .. ": no havoc or rank keys exposed")
    end
end

local _profile_character_id = function(profile)
    if type(profile) ~= "table" then
        return nil
    end

    local character = profile.character

    return profile.character_id or profile.id or character and character.id
end

local _profile_current_level = function(profile)
    if type(profile) ~= "table" then
        return nil
    end

    return _number_or_nil(profile.current_level)
        or _number_or_nil(profile.currentLevel)
        or _nested_number(profile, "progression", "currentLevel")
        or _nested_number(profile, "progression", "current_level")
end

mod.havoc_rank_value = function(data)
    local data_type = type(data)

    if data_type == "number" or data_type == "string" then
        return _number_or_nil(data)
    elseif data_type ~= "table" then
        return nil
    end

    return _number_or_nil(data.rank_cadence)
        or _number_or_nil(data.rankCadence)
        or _number_or_nil(data.havoc_rank_cadence_high)
        or _number_or_nil(data.havocRankCadenceHigh)
        or _nested_number(data, "rank", "cadence")
        or _nested_number(data, "rank", "cadenceHigh")
        or _nested_number(data, "havocStats", "rank_cadence")
        or _nested_number(data, "havoc_stats", "rank_cadence")
        or _number_or_nil(data.rank_week)
        or _number_or_nil(data.rankWeek)
        or _nested_number(data, "rank", "week")
        or _number_or_nil(data.rank_all_time)
        or _number_or_nil(data.rankAllTime)
        or _nested_number(data, "rank", "allTime")
        or _number_or_nil(data.highest_rank)
        or _number_or_nil(data.highestRank)
        or _number_or_nil(data.havoc_rank)
        or _number_or_nil(data.current_havoc_rank)
        or _number_or_nil(data.rank)
        or _nested_number(data, "current_order", "rank")
        or _nested_number(data, "currentOrder", "rank")
        or _scan_havoc_rank_table(data)
end

mod._havoc_cache = {}
mod._havoc_watch = {}

local _local_account_id = function()
    if gRPC and gRPC.get_account_id then
        local ok, account_id = pcall(gRPC.get_account_id)

        if ok and account_id then
            return account_id
        end
    end

    local player_manager = Managers and Managers.player
    local local_player = player_manager and player_manager.local_player_safe and player_manager:local_player_safe(1)

    return local_player and local_player.account_id and local_player:account_id()
end

local _is_local_account_id = function(account_id)
    local local_account_id = _local_account_id()

    return account_id and local_account_id and account_id == local_account_id
end

mod.cached_havoc_rank = function(account_id)
    return _valid_string_id(account_id) and mod._havoc_cache[account_id] or nil
end

mod.ensure_profile_true_levels = function(profile, account_id, character_id)
    character_id = character_id or _profile_character_id(profile)

    if not character_id then
        return nil
    end

    local current_level = _profile_current_level(profile)
    local cache = _is_local_account_id(account_id) and mod._self or mod._others
    local true_levels = mod._self[character_id] or mod._others[character_id]
    local rank = mod.cached_havoc_rank(account_id)

    if not true_levels and current_level then
        true_levels = {
            current_level = current_level,
            account_id = _valid_string_id(account_id) and account_id or nil,
            havoc_rank = rank
        }
        cache[character_id] = true_levels

        return true_levels
    elseif true_levels then
        if current_level and not true_levels.current_level then
            true_levels.current_level = current_level
        end

        if _valid_string_id(account_id) and true_levels.account_id ~= account_id then
            true_levels.account_id = account_id
        end

        if rank and true_levels.havoc_rank ~= rank then
            true_levels.havoc_rank = rank
        end
    end

    return true_levels
end

mod.apply_havoc_rank_to_cache = function(account_id, data, character_id)
    local rank = mod.havoc_rank_value(data)

    if not rank then
        return false
    end

    local changed = false
    local caches = {
        mod._self,
        mod._others
    }

    for i = 1, #caches do
        local cache = caches[i]

        for cached_character_id, true_levels in pairs(cache) do
            if type(true_levels) == "table" then
                local matches_account = _valid_string_id(account_id) and true_levels.account_id == account_id
                local matches_character = character_id and cached_character_id == character_id

                if matches_account or matches_character then
                    if true_levels.havoc_rank ~= rank then
                        true_levels.havoc_rank = rank
                        changed = true
                    end

                    if _valid_string_id(account_id) and true_levels.account_id ~= account_id then
                        true_levels.account_id = account_id
                        changed = true
                    end
                end
            end
        end
    end

    if changed then
        mod.desync_all()
    end

    return changed
end

mod.remember_havoc_rank = function(account_id, data, character_id)
    local rank = mod.havoc_rank_value(data)

    if _valid_string_id(account_id) and rank then
        mod._havoc_cache[account_id] = rank
        mod.apply_havoc_rank_to_cache(account_id, rank, character_id)
    elseif rank and character_id then
        mod.apply_havoc_rank_to_cache(account_id, rank, character_id)
    end

    return rank
end

local _safe_method = function(object, method_name, ...)
    if not object then
        return nil
    end

    local method = object[method_name]

    if not method then
        return nil
    end

    local ok, result = pcall(method, object, ...)

    if ok then
        return result
    end

    return nil
end

local _main_time = function()
    local time_manager = Managers and Managers.time

    if time_manager and time_manager.time then
        local ok, t = pcall(time_manager.time, time_manager, "main")

        if ok and t then
            return t
        end
    end

    return 0
end

mod.update_havoc_from_presence = function(presence_entry, account_id, character_id)
    if not presence_entry then
        return nil
    end

    local key_values = _presence_key_values(presence_entry)
    local scanned_rank, scanned_key = _scan_havoc_rank_table(key_values)
    local rank = _safe_method(presence_entry, "havoc_rank_cadence_high")
        or _presence_key_value(presence_entry, "havoc_rank_cadence_high")
        or scanned_rank
        or _safe_method(presence_entry, "havoc_rank_all_time_high")
        or _presence_key_value(presence_entry, "havoc_rank_all_time_high")

    rank = mod.havoc_rank_value(rank)

    _log_presence_havoc_keys(account_id or _safe_method(presence_entry, "account_id"), key_values, rank, scanned_key)

    if rank then
        local resolved_account_id = _valid_string_id(account_id) and account_id or _safe_method(presence_entry, "account_id")
        local profile = _safe_method(presence_entry, "character_profile")
        local resolved_character_id = character_id or profile and profile.character_id or _safe_method(presence_entry, "character_id")

        if _valid_string_id(resolved_account_id) then
            mod._havoc_cache[resolved_account_id] = rank
        else
            resolved_account_id = nil
        end

        if profile then
            mod.ensure_profile_true_levels(profile, resolved_account_id, resolved_character_id)
        end

        mod.apply_havoc_rank_to_cache(resolved_account_id, rank, resolved_character_id)
    end

    return rank
end

mod.update_havoc_from_player_info = function(player_info, account_id, character_id, profile)
    if not player_info then
        return nil
    end

    local resolved_account_id = _valid_string_id(account_id) and account_id or _safe_method(player_info, "account_id")
    local resolved_profile = profile or _safe_method(player_info, "profile")
    local resolved_character_id = character_id or resolved_profile and resolved_profile.character_id or _safe_method(player_info, "character_id")

    if resolved_profile then
        mod.ensure_profile_true_levels(resolved_profile, resolved_account_id, resolved_character_id)
    end

    local presence = player_info._presence

    if not presence then
        _safe_method(player_info, "online_status")
        _safe_method(player_info, "profile")
        _safe_method(player_info, "_get_presence")
        presence = player_info._presence
    end

    return mod.update_havoc_from_presence(presence, resolved_account_id, resolved_character_id)
end

mod.keep_havoc_presence_alive = function(account_id, character_id, profile, player_info)
    if not _valid_string_id(account_id) then
        return nil
    end

    local watch = mod._havoc_watch[account_id]

    if type(watch) ~= "table" then
        watch = {}
        mod._havoc_watch[account_id] = watch
    end

    if character_id then
        watch.character_id = character_id
    end

    if profile then
        mod.ensure_profile_true_levels(profile, account_id, watch.character_id)
    end

    local t = _main_time()

    if watch.next_touch and watch.next_touch > t then
        return mod.cached_havoc_rank(account_id)
    end

    watch.next_touch = t + 3

    local social_service = Managers and Managers.data_service and Managers.data_service.social
    local social_player_info = player_info

    if not social_player_info and social_service and social_service.get_player_info_by_account_id then
        local ok, result = pcall(social_service.get_player_info_by_account_id, social_service, account_id)

        if ok then
            social_player_info = result
        end
    end

    if social_player_info then
        local rank = mod.update_havoc_from_player_info(social_player_info, account_id, watch.character_id, profile)

        if rank then
            return rank
        end

        if not watch.first_update_attached then
            watch.first_update_attached = true

            local first_update_promise = _safe_method(social_player_info, "first_update_promise")

            if first_update_promise and first_update_promise.next then
                first_update_promise:next(function(updated_player_info)
                    local found_rank = mod.update_havoc_from_player_info(updated_player_info or social_player_info, account_id, watch.character_id, profile)

                    if found_rank then
                        mod.desync_all()
                    end
                end):catch(function()
                end)
            end
        end
    end

    local presence_manager = Managers and Managers.presence

    if presence_manager and presence_manager.get_presence then
        local ok, presence_entry, presence_promise = pcall(presence_manager.get_presence, presence_manager, account_id)

        if ok and presence_entry then
            _safe_method(presence_entry, "is_alive")

            local rank = mod.update_havoc_from_presence(presence_entry, account_id, watch.character_id)

            if rank then
                return rank
            end

            if presence_promise and presence_promise.next then
                presence_promise:next(function(presence)
                    local found_rank = mod.update_havoc_from_presence(presence, account_id, watch.character_id)

                    if found_rank then
                        mod.desync_all()
                    end
                end):catch(function()
                end)
            end
        end
    end

    if not mod.cached_havoc_rank(account_id) then
        mod.fetch_havoc_rank(account_id)
    end

    return mod.cached_havoc_rank(account_id)
end

mod.watch_havoc_player = function(player)
    if not player or player.__deleted then
        return nil
    end

    local account_id = _safe_method(player, "account_id")
    local profile = _safe_method(player, "profile")
    local character_id = profile and profile.character_id or _safe_method(player, "character_id")

    if profile then
        mod.ensure_profile_true_levels(profile, account_id, character_id)
    end

    return mod.keep_havoc_presence_alive(account_id, character_id, profile)
end

mod.watch_havoc_player_info = function(player_info)
    if not player_info then
        return nil
    end

    local account_id = _safe_method(player_info, "account_id")
    local profile = _safe_method(player_info, "profile")
    local character_id = profile and profile.character_id or _safe_method(player_info, "character_id")

    if profile then
        mod.ensure_profile_true_levels(profile, account_id, character_id)
    end

    return mod.keep_havoc_presence_alive(account_id, character_id, profile, player_info)
end

mod.watch_havoc_human_players = function()
    local player_manager = Managers and Managers.player
    local players = nil

    if player_manager and player_manager.human_players then
        local ok, result = pcall(player_manager.human_players, player_manager)

        if ok then
            players = result
        end
    end

    if not players and player_manager and player_manager.players then
        local ok, result = pcall(player_manager.players, player_manager)

        if ok then
            players = result
        end
    end

    if type(players) ~= "table" then
        return
    end

    for _, player in pairs(players) do
        mod.watch_havoc_player(player)
    end
end

mod.poll_havoc_watch = function()
    local t = _main_time()

    if mod._next_havoc_watch_poll and mod._next_havoc_watch_poll > t then
        return
    end

    mod._next_havoc_watch_poll = t + 3

    mod.watch_havoc_human_players()

    for account_id, watch in pairs(mod._havoc_watch) do
        if _valid_string_id(account_id) and type(watch) == "table" then
            mod.keep_havoc_presence_alive(account_id, watch.character_id)
        end
    end
end

if CLASS.PresenceManager then
    mod:hook_safe(CLASS.PresenceManager, "update", function()
        mod.poll_havoc_watch()
    end)
end

local _safe_promise = function(callback)
    local ok, promise = pcall(callback)

    if ok and promise and promise.next then
        return promise
    end

    return Promise.resolved(nil)
end

mod.fetch_havoc_rank = function(account_id)
    local cached = mod.cached_havoc_rank(account_id)

    if cached then
        return Promise.resolved(cached)
    end

    local pending = account_id and mod._havoc_promises[account_id]

    if pending and pending ~= true and pending.next then
        return pending
    end

    local rank_promise = Promise.new()

    if not _valid_string_id(account_id) then
        rank_promise:resolve(nil)

        return rank_promise
    end

    mod._havoc_promises[account_id] = rank_promise

    local finish = function(data)
        local rank = mod.remember_havoc_rank(account_id, data)

        mod._havoc_promises[account_id] = nil

        if rank then
            local presence_manager = Managers and Managers.presence

            if _is_local_account_id(account_id) and presence_manager and presence_manager.set_havoc_rank_cadence_high then
                pcall(function()
                    presence_manager:set_havoc_rank_cadence_high(rank)
                end)
            end

            mod.desync_all()
        end

        rank_promise:resolve(rank)
    end

    local fetch_presence = function()
        local presence_manager = Managers and Managers.presence

        if presence_manager and presence_manager.get_presence then
            local ok, presence_entry, presence_promise = pcall(presence_manager.get_presence, presence_manager, account_id)

            if ok and presence_entry then
                _safe_method(presence_entry, "is_alive")

                local immediate_rank = mod.update_havoc_from_presence(presence_entry, account_id)

                if immediate_rank then
                    finish(immediate_rank)

                    return
                end

                if presence_promise and presence_promise.next then
                    presence_promise:next(function(presence)
                        finish(mod.update_havoc_from_presence(presence, account_id))
                    end):catch(function()
                        finish(nil)
                    end)

                    return
                end
            end
        end

        local data_service = Managers and Managers.data_service
        local havoc_service = data_service and data_service.havoc

        if not havoc_service or not havoc_service.havoc_rank_cadence_high then
            finish(nil)

            return
        end

        _safe_promise(function()
            return havoc_service:havoc_rank_cadence_high(account_id)
        end):next(finish):catch(function()
            finish(nil)
        end)
    end

    local data_service = Managers and Managers.data_service
    local havoc_service = data_service and data_service.havoc

    if _is_local_account_id(account_id) and havoc_service and havoc_service.latest then
        _safe_promise(function()
            return havoc_service:latest()
        end):next(function(data)
            local rank = mod.remember_havoc_rank(account_id, data)

            if rank then
                finish(rank)
            elseif havoc_service.summary then
                _safe_promise(function()
                    return havoc_service:summary()
                end):next(function(summary)
                    local summary_rank = mod.remember_havoc_rank(account_id, summary)

                    if summary_rank then
                        finish(summary_rank)
                    else
                        fetch_presence()
                    end
                end):catch(fetch_presence)
            else
                fetch_presence()
            end
        end):catch(fetch_presence)
    else
        fetch_presence()
    end

    return rank_promise
end

local _populate_data = function(base_data, havoc_rank_cadence_high)
    local xp_settings = mod._xp_settings
    local level_array = xp_settings.level_array
    local total_xp = xp_settings.total_xp
    local max_level = xp_settings.max_level
    local current_level = base_data.currentLevel
    local current_xp = base_data.currentXp
    local current_xp_in_level = base_data.currentXpInLevel
    local needed_xp_for_next = base_data.neededXpForNextLevel
    local true_levels = {
        current_xp = current_xp,
        current_level = current_level,
    }

    if current_level < max_level then
        true_levels.xp_per_level = level_array[current_level + 1] - level_array[current_level]
        true_levels.remaining_xp = current_xp_in_level
        true_levels.needed_xp = needed_xp_for_next
    else
        local xp_per_level = level_array[max_level] - level_array[max_level - 1]
        local xp_over_max_level = current_xp - total_xp
        local remaining_xp = xp_over_max_level % xp_per_level
        local additional_level = math.floor(xp_over_max_level / xp_per_level)
        local true_level = current_level + additional_level

        true_levels.xp_per_level = xp_per_level
        true_levels.remaining_xp = remaining_xp
        true_levels.needed_xp = xp_per_level - remaining_xp
        true_levels.additional_level = additional_level
        true_levels.true_level = true_level
        true_levels.prestige = math.floor(current_xp / total_xp)
        true_levels.havoc_rank = mod.havoc_rank_value(havoc_rank_cadence_high)
    end

    return true_levels
end

mod.cache_true_levels = function(self_or_others, character_id, base_data, havoc_rank_cadence_high, account_id)
    if table.is_empty(mod._xp_settings) then
        mod._fetch_xp_settings()

        local queue = mod._queue

        if not queue[character_id] then
            queue[character_id] = {
                self_or_others,
                character_id,
                base_data,
                havoc_rank_cadence_high,
                account_id
            }
        end

        return
    end

    local true_levels = _populate_data(base_data, havoc_rank_cadence_high)

    true_levels.account_id = _valid_string_id(account_id) and account_id or nil

    if _valid_string_id(account_id) and not true_levels.havoc_rank then
        true_levels.havoc_rank = mod.cached_havoc_rank(account_id)
    elseif _valid_string_id(account_id) and true_levels.havoc_rank then
        mod.remember_havoc_rank(account_id, true_levels.havoc_rank)
    end

    self_or_others[character_id] = true_levels
    mod.debug.dump(true_levels, character_id)
end

local _get_best_setting = function(base_id, reference)
    local setting_id = base_id .. "_" .. reference
    local setting = mod:get(setting_id)
    local global_setting = mod:get(base_id)

    if setting == "use_global" then
        setting = global_setting
    elseif type(global_setting) == "boolean" then
        setting = setting == "on" and true or false
    end

    return setting
end

local t = {}

local _has_title = function(text)
    t = {}

    for s in text:gmatch("[^\n]+") do
        t[#t + 1] = s
    end

    return #t > 1, t[1], t[2]
end

local _apply_color_to_text = function(color_code, text)
    local c = Color[color_code](255, true)
    local color_prefix = string.format("{#color(%s,%s,%s)}", c[2], c[3], c[4])

    return color_prefix .. text .. "{#reset()}"
end

local levels = {
    {
        key = "level",
        val = ""
    },
    {
        key = "prestige_level",
        val = ""
    },
    {
        key = "havoc_rank",
        val = ""
    }
}

local _init_levels = function()
    for i = 1, #levels do
        local level = levels[i]

        level.val = ""
    end
end

local _concat_levels = function(ref)
    local result = ""
    local len = #levels

    for i = 1, len do
        local level = levels[i]
        if level.val ~= "" then
            local level_text = level.val .. " " .. mod.get_symbol(level.key .. "_custom")
            local color_code =  _get_best_setting(level.key .. "_color", ref)

            if color_code and color_code ~= "default" and Color[color_code]then
                level_text = _apply_color_to_text(color_code, level_text)
            end

            if result ~= "" then
                result = result .. " "
            end

            result = result .. level_text
        end
    end

    return result
end

local _trim_added_levels = function(text)
    text = text:gsub("%s+%-%s+%d.+", "")
    text = text:gsub("%s+%-%s+{#.-}%d.+", "")

    return text
end

mod.replace_level = function(text, true_levels, reference, need_adding)
    _init_levels()

    mod._symbols.level_custom = _get_best_setting("level_icon", reference)
    mod._symbols.prestige_level_custom = _get_best_setting("prestige_level_icon", reference)
    mod._symbols.havoc_rank_custom = _get_best_setting("havoc_rank_icon", reference)

    local display_style = _get_best_setting("display_style", reference)
    local show_prestige = _get_best_setting("enable_prestige_level", reference)
    local show_havoc_rank = _get_best_setting("enable_havoc_rank", reference)
    local disable_normal_level = _get_best_setting("prioritize_other_levels", reference)
    local current_level = true_levels.current_level
    local additional_level = true_levels.additional_level
    local true_level = true_levels.true_level
    local prestige = true_levels.prestige
    local havoc_rank = true_levels.havoc_rank
    local level_icon = mod.get_symbol()
    local suffix = " " .. level_icon
    local has_title, player_name, title = _has_title(text)

    if has_title then
        text = player_name
    else
        text = text:gsub("\n", "")
    end

    if need_adding then
        text = _trim_added_levels(text)
    end

    if display_style ~= "none" then
        if display_style == "total" and true_level then
            levels[1].val = true_level
        elseif display_style == "separate" and additional_level then
            levels[1].val = current_level .. " (+" .. additional_level .. ")"
        else
            levels[1].val = current_level
        end
    end

    if show_prestige and prestige then
        levels[2].val = prestige
    end

    if show_havoc_rank then
        local account_id = true_levels.account_id
        local cached_havoc_rank = account_id and mod.cached_havoc_rank(account_id)

        if cached_havoc_rank then
            true_levels.havoc_rank = cached_havoc_rank
            levels[3].val = cached_havoc_rank
        elseif havoc_rank then
            levels[3].val = havoc_rank
        elseif account_id and true_level and not mod._havoc_promises[account_id] then
            mod.fetch_havoc_rank(account_id):next(function(rank)
                true_levels.havoc_rank = rank

                if rank then
                    mod.desync_all()
                end
            end)
        end
    end

    if (levels[2].val ~= "" or levels[3].val ~= "") and disable_normal_level then
        levels[1].val = ""
    end

    local levels_text = _concat_levels(reference)

    if need_adding and levels_text ~= "" then
        text = text .. " - " ..  _concat_levels(reference)
    else
        text = text:gsub("%d+" .. suffix, levels_text)
    end

    if title then
        text = text .. "\n" .. title
    end

    return text
end

mod.get_true_levels = function(character_id)
    if character_id then
        if mod._self[character_id] then
            return mod._self[character_id], true
        elseif mod._others[character_id] then
            return mod._others[character_id], false
        end
    end

    return nil
end

mod.get_symbol = function(key)
    key = key or "level"

    return mod._symbols[key]
end

mod.is_enabled_feature = function(ref)
    return mod:is_enabled() and mod:get("enable_" .. ref)
end

mod.should_replace = function(ref)
    if mod.is_enabled_feature(ref) and not mod._synced[ref] then
        return true
    end

    return false
end

mod.is_ready = function(target, key)
    local wru = get_mod("who_are_you")
    local is_waiting = false

    if wru and wru:is_enabled() and wru:get("enable_" .. key) then
        is_waiting = target.wru_modified and not target.tl_modified
    else
        is_waiting = not target.tl_modified
    end

    return is_waiting
end

mod.clear_cache = function ()
    table.clear(mod._others)
    table.clear(mod._havoc_cache)
    table.clear(mod._havoc_watch)
end

mod.synced = function(ref)
    mod._synced[ref] = true
end

mod.desynced = function(ref)
    mod._synced[ref] = false
end

mod.desync = mod.desynced

mod.desync_all = function()
    for _, element in ipairs(mod._elements) do
        mod._synced[element] = false
    end
end

mod.desync_all()


for _, element in ipairs(mod._elements) do
    local path = "true_level/scripts/mods/true_level/elements/" .. element

    mod:io_dofile(path)
end

mod:io_dofile("true_level/scripts/mods/true_level/true_level_debug")


local _key_value = _raw_key_value

mod:hook_safe(CLASS.PresenceEntryImmaterium, "update_with", function(self, new_entry)
    local account_id = _safe_method(self, "account_id")

    if not _valid_string_id(account_id) then
        account_id = new_entry and new_entry.account_id
    end

    if not _valid_string_id(account_id) then
        account_id = nil
    end
    local key_values = new_entry and new_entry.key_values
    local character_id = _key_value(key_values, "character_id")
    local scanned_rank, scanned_key = _scan_havoc_rank_table(key_values)
    local rank = mod.update_havoc_from_presence(self, account_id, character_id) or scanned_rank

    if scanned_rank then
        _log_presence_havoc_keys(account_id, key_values, scanned_rank, scanned_key)
    end

    local character_profile_value = _key_value(key_values, "character_profile")
    local backend_profile_data = nil

    if character_profile_value and character_profile_value ~= "" then
        local ok, decoded_profile = pcall(cjson.decode, character_profile_value)

        if ok and decoded_profile then
            local processed_ok, processed_profile = pcall(ProfileUtils.process_backend_body, decoded_profile)

            if processed_ok then
                backend_profile_data = processed_profile
            end
        end
    end

    if not character_id then
        local profile = _safe_method(self, "character_profile")

        character_id = profile and profile.character_id
    end

    if not character_id and backend_profile_data then
        local character = backend_profile_data.character

        character_id = character and character.id
    end

    if backend_profile_data and backend_profile_data.progression and character_id then
        local character = backend_profile_data.character
        local character_name = character and character.name or character_id

        mod.cache_true_levels(mod._others, character_id, backend_profile_data.progression, rank, account_id)
        mod.debug.echo(character_name .. ": " .. character_id)

        if rank then
            mod.desync_all()
        end
    elseif rank then
        mod.apply_havoc_rank_to_cache(account_id, rank, character_id)
    end
end)


local _is_in_hub = function()
    local state_manager = Managers and Managers.state
    local game_mode_manager = state_manager and state_manager.game_mode
    local game_mode_name = game_mode_manager and game_mode_manager:game_mode_name()

    return game_mode_name == "hub"
end

mod:hook_safe("UIHud", "init", function(self)
    mod._is_in_hub = _is_in_hub()
end)

mod.on_game_state_changed = function(status, state_name)
    if state_name == "StateGameplay" and status == "exit" and mod._is_in_hub then
        mod.clear_cache()
        mod._is_in_hub = false
        mod.debug.echo("Cache Cleared")
    end
end

mod.on_setting_changed = function(id)
    mod._debug_mode = mod:get("enable_debug_mode")
    mod._is_in_hub = _is_in_hub()
    mod.desync_all()
end
