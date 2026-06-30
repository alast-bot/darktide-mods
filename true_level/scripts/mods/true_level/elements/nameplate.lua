local mod = get_mod("true_level")
local ProfileUtils = require("scripts/utilities/profile_utils")
local UISettings = require("scripts/settings/ui/ui_settings")
local ref = "nameplate"
local HAVOC_CACHE_SECONDS = 300
local _recent_havoc_cache = {}

local _get_markers_by_id = function()
    local ui_manager = Managers and Managers.ui
    local hud = ui_manager and ui_manager.get_hud and ui_manager:get_hud()
    local world_markers = hud and hud.element and hud:element("HudElementWorldMarkers")
    local markers_by_id = world_markers and world_markers._markers_by_id

    return markers_by_id
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

local _valid_string_id = function(value)
    return type(value) == "string" and value ~= ""
end

local _marker_player_valid = function(marker, player)
    if not marker or not player or player.__deleted then
        return false
    end

    local player_manager = Managers and Managers.player

    if not player_manager or not player_manager.player_from_unique_id then
        return false
    end

    return player_manager:player_from_unique_id(marker.player_unique_id) ~= nil
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

local _cache_key_list = function(marker, player, account_id, character_id, profile)
    local keys = {}

    if _valid_string_id(account_id) then
        keys[#keys + 1] = "a:" .. account_id
    end

    if _valid_string_id(character_id) then
        keys[#keys + 1] = "c:" .. character_id
    end

    if marker and _valid_string_id(marker.player_unique_id) then
        keys[#keys + 1] = "u:" .. marker.player_unique_id
    end

    local profile_character_id = profile and profile.character_id

    if _valid_string_id(profile_character_id) and profile_character_id ~= character_id then
        keys[#keys + 1] = "p:" .. profile_character_id
    end

    local player_name = _safe_method(player, "name")

    if _valid_string_id(player_name) then
        keys[#keys + 1] = "n:" .. player_name
    end

    return keys
end

local _remember_marker_havoc = function(marker, player, account_id, character_id, profile, rank)
    rank = mod.havoc_rank_value and mod.havoc_rank_value(rank) or rank

    if not rank then
        return nil
    end

    local expires = _main_time() + HAVOC_CACHE_SECONDS

    if marker then
        marker.tl_cached_havoc_rank = rank
        marker.tl_cached_havoc_expires = expires
    end

    local keys = _cache_key_list(marker, player, account_id, character_id, profile)

    for i = 1, #keys do
        _recent_havoc_cache[keys[i]] = {
            rank = rank,
            expires = expires
        }
    end

    return rank
end

local _cached_marker_havoc = function(marker, player, account_id, character_id, profile)
    local rank = _valid_string_id(account_id) and mod.cached_havoc_rank and mod.cached_havoc_rank(account_id) or nil

    if rank then
        return _remember_marker_havoc(marker, player, account_id, character_id, profile, rank)
    end

    local t = _main_time()

    if marker and marker.tl_cached_havoc_rank and marker.tl_cached_havoc_expires and marker.tl_cached_havoc_expires > t then
        return marker.tl_cached_havoc_rank
    end

    local keys = _cache_key_list(marker, player, account_id, character_id, profile)

    for i = 1, #keys do
        local cached = _recent_havoc_cache[keys[i]]

        if cached then
            if cached.expires and cached.expires > t and cached.rank then
                if marker then
                    marker.tl_cached_havoc_rank = cached.rank
                    marker.tl_cached_havoc_expires = cached.expires
                end

                return cached.rank
            else
                _recent_havoc_cache[keys[i]] = nil
            end
        end
    end

    return nil
end

local _base_character_text = function(player)
    local profile = _safe_method(player, "profile")
    local character_level = profile and profile.current_level or 1
    local title = profile and ProfileUtils.character_title(profile)
    local archetype = profile and profile.archetype
    local archetype_name = archetype and archetype.name
    local string_symbol = archetype_name and UISettings.archetype_font_icon[archetype_name] or ""
    local text = string_symbol .. " " .. tostring(_safe_method(player, "name") or "") .. " - " .. tostring(character_level) .. " \xEE\x80\x86"

    if title then
        text = text .. " \n " .. title
    end

    return text, profile, title
end

local _player_signature = function(marker, player, profile, title, account_id, character_id)
    local current_level = profile and profile.current_level or ""
    local archetype = profile and profile.archetype
    local archetype_name = archetype and archetype.name or ""

    return tostring(marker.player_unique_id or "") .. ":" .. tostring(account_id or "") .. ":" .. tostring(character_id or "") .. ":" .. tostring(_safe_method(player, "name") or "") .. ":" .. tostring(current_level) .. ":" .. tostring(archetype_name) .. ":" .. tostring(title or "")
end

local _level_signature = function(true_levels)
    return tostring(true_levels.current_level or "") .. ":" .. tostring(true_levels.true_level or "") .. ":" .. tostring(true_levels.additional_level or "") .. ":" .. tostring(true_levels.prestige or "") .. ":" .. tostring(true_levels.havoc_rank or "")
end

local _ensure_marker_base = function(marker, player, account_id, character_id, force)
    local base_text, profile, title = _base_character_text(player)
    local signature = _player_signature(marker, player, profile, title, account_id, character_id)

    if force or marker.tl_player_signature ~= signature or not marker.tl_base_header_text then
        marker.tl_player_signature = signature
        marker.tl_base_header_text = base_text
        marker.tl_last_signature = nil
        marker.tl_modified = false
    end

    return base_text, profile
end

local _apply_marker_levels = function(marker, player, true_levels, force)
    if not _marker_player_valid(marker, player) or not true_levels then
        return false
    end

    local widget = marker.widget
    local content = widget and widget.content

    if not content then
        return false
    end

    local base_text = marker.tl_base_header_text

    if not base_text then
        base_text = _base_character_text(player)
        marker.tl_base_header_text = base_text
    end

    local signature = _level_signature(true_levels)

    if not force and marker.tl_last_signature == signature and marker.tl_modified then
        return false
    end

    local new_text = mod.replace_level(base_text, true_levels, ref, true)

    if content.header_text ~= new_text then
        content.header_text = new_text
        widget.dirty = true
    end

    marker.tl_last_header_text = new_text
    marker.tl_last_signature = signature
    marker.tl_modified = true

    return true
end

local _remember_rank_local = function(account_id, character_id, profile, rank)
    rank = mod.havoc_rank_value and mod.havoc_rank_value(rank) or rank

    if not rank then
        return nil
    end

    if _valid_string_id(account_id) and mod._havoc_cache then
        mod._havoc_cache[account_id] = rank
    end

    local true_levels = mod.get_true_levels and mod.get_true_levels(character_id)

    if not true_levels and profile and mod.ensure_profile_true_levels then
        true_levels = mod.ensure_profile_true_levels(profile, account_id, character_id)
    end

    if true_levels then
        true_levels.havoc_rank = rank

        if _valid_string_id(account_id) then
            true_levels.account_id = account_id
        end
    end

    return true_levels
end

local _finish_marker_havoc = function(marker, player, account_id, character_id, profile, rank)
    if not marker then
        return
    end

    marker.tl_havoc_promise = nil
    rank = _remember_marker_havoc(marker, player, account_id, character_id, profile, rank) or _cached_marker_havoc(marker, player, account_id, character_id, profile)
    marker.tl_next_havoc_request = _main_time() + (rank and HAVOC_CACHE_SECONDS or 20)

    if not rank or not _marker_player_valid(marker, player) then
        return
    end

    local true_levels = _remember_rank_local(account_id, character_id, profile, rank)

    if not true_levels and profile then
        true_levels = {
            current_level = profile.current_level or 1,
            account_id = _valid_string_id(account_id) and account_id or nil,
            havoc_rank = rank
        }
    end

    if true_levels then
        _apply_marker_levels(marker, player, true_levels, true)
    end
end

local _request_marker_havoc = function(marker, player, account_id, character_id, profile)
    if marker.tl_havoc_promise or not _valid_string_id(account_id) then
        return
    end

    local cached_rank = _cached_marker_havoc(marker, player, account_id, character_id, profile)

    if cached_rank then
        marker.tl_next_havoc_request = _main_time() + HAVOC_CACHE_SECONDS

        local true_levels = _remember_rank_local(account_id, character_id, profile, cached_rank)

        if true_levels then
            _apply_marker_levels(marker, player, true_levels, false)
        end

        return
    end

    local t = _main_time()

    if marker.tl_next_havoc_request and marker.tl_next_havoc_request > t then
        return
    end

    marker.tl_next_havoc_request = t + 20

    local data_service = Managers and Managers.data_service
    local havoc_service = data_service and data_service.havoc

    if not havoc_service or not havoc_service.havoc_rank_cadence_high then
        return
    end

    local ok, promise = pcall(havoc_service.havoc_rank_cadence_high, havoc_service, account_id)

    if not ok or not promise or not promise.next then
        return
    end

    marker.tl_havoc_promise = promise

    promise:next(function(rank)
        if rank or not havoc_service.havoc_rank_all_time_high then
            _finish_marker_havoc(marker, player, account_id, character_id, profile, rank)

            return
        end

        local fallback_ok, fallback_promise = pcall(havoc_service.havoc_rank_all_time_high, havoc_service, account_id)

        if not fallback_ok or not fallback_promise or not fallback_promise.next then
            _finish_marker_havoc(marker, player, account_id, character_id, profile, nil)

            return
        end

        marker.tl_havoc_promise = fallback_promise

        fallback_promise:next(function(fallback_rank)
            _finish_marker_havoc(marker, player, account_id, character_id, profile, fallback_rank)
        end):catch(function()
            _finish_marker_havoc(marker, player, account_id, character_id, profile, nil)
        end)
    end):catch(function()
        _finish_marker_havoc(marker, player, account_id, character_id, profile, nil)
    end)
end

local _touch_marker_player = function(marker, player, force)
    if not _marker_player_valid(marker, player) then
        return nil
    end

    local account_id = _safe_method(player, "account_id")
    local profile = _safe_method(player, "profile")
    local character_id = profile and profile.character_id or _safe_method(player, "character_id")
    local base_text

    base_text, profile = _ensure_marker_base(marker, player, account_id, character_id, force)

    marker.peer_id = _safe_method(player, "peer_id")

    local true_levels = mod.get_true_levels and mod.get_true_levels(character_id)

    if not true_levels and mod.ensure_profile_true_levels then
        true_levels = mod.ensure_profile_true_levels(profile, account_id, character_id)
    end

    if true_levels then
        if _valid_string_id(account_id) then
            true_levels.account_id = account_id
        end

        local cached_rank = _cached_marker_havoc(marker, player, account_id, character_id, profile)

        if true_levels.havoc_rank then
            _remember_marker_havoc(marker, player, account_id, character_id, profile, true_levels.havoc_rank)
        elseif cached_rank then
            true_levels.havoc_rank = cached_rank
            force = true
        end

        if cached_rank and true_levels.havoc_rank ~= cached_rank then
            true_levels.havoc_rank = cached_rank
            force = true
        end

        _apply_marker_levels(marker, player, true_levels, force)
    else
        local cached_rank = _cached_marker_havoc(marker, player, account_id, character_id, profile)

        if cached_rank and profile then
            true_levels = {
                current_level = profile.current_level or 1,
                account_id = _valid_string_id(account_id) and account_id or nil,
                havoc_rank = cached_rank
            }

            _apply_marker_levels(marker, player, true_levels, true)
        else
            local widget = marker.widget
            local content = widget and widget.content

            if content and (force or not marker.tl_modified) and content.header_text ~= base_text then
                content.header_text = base_text
                widget.dirty = true
            end
        end
    end

    _request_marker_havoc(marker, player, account_id, character_id, profile)
end

local function _create_character_text(marker)
    local player = marker and marker.data

    if not _marker_player_valid(marker, player) then
        return
    end

    marker.wru_modified = false
    marker.tl_modified = false
    marker.tl_last_signature = nil
    marker.tl_player_signature = nil

    _touch_marker_player(marker, player, true)
end

mod:hook_safe(CLASS.HudElementWorldMarkers, "event_add_world_marker_unit", function(self, marker_type, unit, callback, data)
    if marker_type:match("nameplate") and not marker_type:match("companion") then
        local markers_by_type = self and self._markers_by_type
        local markers = markers_by_type and markers_by_type[marker_type]
        local len = markers and #markers or 0

        for i = 1, len do
            local marker = markers[i]

            if marker and marker.unit == unit then
                marker._event_update_player_name = function(self)
                    _create_character_text(self)
                end

                marker.cb_event_player_profile_updated = function(self, synced_peer_id, synced_local_player_id, new_profile, force_update)
                    local valid = force_update or self.peer_id and self.peer_id == synced_peer_id

                    if not valid then
                        return
                    end

                    local player = marker.data

                    if _marker_player_valid(marker, player) and new_profile then
                        _safe_method(player, "set_profile", new_profile)
                        _create_character_text(marker)
                    end
                end

                _create_character_text(marker)
            end
        end
    end
end)

mod:hook_safe(CLASS.HudElementNameplates, "update", function(self)
    if not mod.is_enabled_feature(ref) then
        return
    end

    local force_refresh = false

    if mod.should_replace(ref) then
        mod.synced(ref)
        force_refresh = true
    end

    local nameplates = self and self._nameplate_units
    local markers_by_id = _get_markers_by_id()

    if markers_by_id and nameplates then
        local t = _main_time()

        for _, data in pairs(nameplates) do
            local id = data and data.marker_id
            local marker = id and markers_by_id[id]
            local player = marker and marker.data

            if marker and player then
                local widget = marker.widget
                local content = widget and widget.content
                local header_changed = marker.tl_last_header_text and content and content.header_text ~= marker.tl_last_header_text

                if force_refresh or header_changed or not marker.tl_next_light_touch or marker.tl_next_light_touch <= t or not marker.tl_modified then
                    marker.tl_next_light_touch = t + 1
                    _touch_marker_player(marker, player, force_refresh or header_changed)
                elseif marker.tl_havoc_promise then
                    local account_id = _safe_method(player, "account_id")
                    local profile = _safe_method(player, "profile")
                    local character_id = profile and profile.character_id or _safe_method(player, "character_id")

                    _request_marker_havoc(marker, player, account_id, character_id, profile)
                end
            end
        end
    end
end)
