local mod = get_mod("true_level")
local MainMenuViewSettings = require("scripts/ui/views/main_menu_view/main_menu_view_settings")
local ProfileUtils = require("scripts/utilities/profile_utils")
local ref = "main_menu"
local cache = mod._self

local _get_havoc_rank = function(self)
    local player_manager = Managers and Managers.player
    local player = player_manager and player_manager.local_player_safe and player_manager:local_player_safe(1)

    if player then
        local account_id = player:account_id()

        return mod.fetch_havoc_rank(account_id)
    end

    return mod.fetch_havoc_rank(nil)
end

local _get_all_progression = function(self)
    local backend_interface = Managers and Managers.backend and Managers.backend.interfaces
    local progression_interface = backend_interface and backend_interface.progression

    if not progression_interface then
        self._tl_promise = nil

        return
    end

    local progression_promise = progression_interface:get_entity_type_progression("character")
    local havoc_promise = _get_havoc_rank(self)

    self._tl_promise = true

    Promise.all(progression_promise, havoc_promise):next(function(result)
        local characters_progression, havoc_rank_cadence_high = unpack(result)
        local player_manager = Managers and Managers.player
        local local_player = player_manager and player_manager.local_player_safe and player_manager:local_player_safe(1)
        local account_id = local_player and local_player:account_id()

        if account_id then
            mod._havoc_promises[account_id] = nil
        end

        self._tl_promise = nil

        for _, data in ipairs(characters_progression) do
            mod.cache_true_levels(cache, data.id, data, havoc_rank_cadence_high, account_id)
        end

        mod.desynced(ref)
        mod.debug.dump(mod._self, "backend_progression")
    end):catch(function()
        local player_manager = Managers and Managers.player
        local local_player = player_manager and player_manager.local_player_safe and player_manager:local_player_safe(1)
        local account_id = local_player and local_player:account_id()

        if account_id then
            mod._havoc_promises[account_id] = nil
        end

        self._tl_promise = nil
    end)
end

local _get_character_progression = function(self, character_id)
    local backend_interface = Managers and Managers.backend and Managers.backend.interfaces
    local progression_interface = backend_interface and backend_interface.progression

    if not character_id or not progression_interface then
        self._tl_promise = nil

        return
    end

    local progression_promise = progression_interface:get_progression("character", character_id)
    local havoc_promise = _get_havoc_rank(self)

    self._tl_promise = true

    Promise.all(progression_promise, havoc_promise):next(function(result)
        local data, havoc_rank_cadence_high = unpack(result)
        local player_manager = Managers and Managers.player
        local local_player = player_manager and player_manager.local_player_safe and player_manager:local_player_safe(1)
        local account_id = local_player and local_player:account_id()

        if account_id then
            mod._havoc_promises[account_id] = nil
        end

        self._tl_promise = nil

        mod.cache_true_levels(mod._self, character_id, data, havoc_rank_cadence_high, account_id)
    end):catch(function()
        local player_manager = Managers and Managers.player
        local local_player = player_manager and player_manager.local_player_safe and player_manager:local_player_safe(1)
        local account_id = local_player and local_player:account_id()

        if account_id then
            mod._havoc_promises[account_id] = nil
        end

        self._tl_promise = nil
    end)
end

local _get_account_level = function(widgets)
    local account_level = 0

    for _, widget in pairs(widgets) do
        local content = widget.content
        local profile = content.profile
        local character_id = profile and profile.character_id
        local true_levels = mod.get_true_levels(character_id)

        if true_levels then
            account_level = account_level + (true_levels.true_level or true_levels.current_level)
        end
    end

    return account_level
end

local _get_title = function(profile)
    return string.format("%s - %s", ProfileUtils.character_archetype_title(profile), tostring(profile.current_level) .. " " .. mod.get_symbol("level"))
end

mod:hook_safe(CLASS.MainMenuView, "init", function(self)
    mod.desynced(ref)
end)

mod:hook_safe(CLASS.MainMenuView, "_event_profiles_changed", function(self)
    mod._fetch_xp_settings()

    if not self._tl_promise then
        _get_all_progression(self)
    end
end)

mod:hook_safe(CLASS.MainMenuView, "update", function(self)
    if not mod.should_replace(ref) then
        return
    end

    local character_widgets = self._character_list_widgets
    local num_characters = character_widgets and #character_widgets or 0

    if num_characters and not self._tl_promise then
        for _, widget in ipairs(character_widgets) do
            local content = widget.content
            local profile = content.profile
            local character_id = profile and profile.character_id
            local true_levels = mod.get_true_levels(character_id)

            if true_levels then
                local title = _get_title(profile)

                content.character_archetype_title = mod.replace_level(title, true_levels, ref, true)
            else
                _get_character_progression(self, character_id)
                return
            end
        end

        local selected_character_list_index = self._selected_character_list_index

        if selected_character_list_index then
            self:_set_selected_character_list_index(selected_character_list_index)
        end

        local account_level = _get_account_level(character_widgets)
        local max_num_characters = MainMenuViewSettings.max_num_characters
        local slots_remaining = num_characters < max_num_characters and max_num_characters - num_characters or 0
        local footer_text = Localize("loc_main_menu_slots_remaining", true, {
            count = slots_remaining
        })

        self._widgets_by_name.slots_count.content.text = footer_text .. "\n" .. mod:localize("account_level", account_level)

        mod.synced(ref)
    end
end)

mod:hook_safe(CLASS.MainMenuView, "_set_selected_character_list_index", function(self, index)
    if not mod.is_enabled_feature(ref) then
        return
    end

    local character_widgets = self._character_list_widgets
    local selected_widget = character_widgets[index]
    local selected_profile = selected_widget.content.profile
    local selected_character_id = selected_profile.character_id
    local true_levels = cache[selected_character_id]

    if true_levels then
        local content = self._widgets_by_name.character_info.content
        local title = _get_title(selected_profile)

        content.character_archetype_title = mod.replace_level(title, true_levels, ref, true)
    end
end)
