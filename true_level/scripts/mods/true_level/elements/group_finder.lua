local mod = get_mod("true_level")
local ProfileUtils = require("scripts/utilities/profile_utils")
local ref = "group_finder"

mod:hook_safe(CLASS.GroupFinderView, "init", function(self)
    mod.desynced(ref)
end)

local _set_modified = function(widget, is_modified)
    if not widget then
        return
    end

    widget.tl_modified = is_modified
end

mod:hook_safe(CLASS.GroupFinderView, "_update_listed_group", function(self)
    mod.debug.echo("desync: listed group")
    mod.desynced(ref)

    local widgets = self._widgets_by_name

    if not widgets then
        return
    end

    for i = 1, 4 do
        _set_modified(widgets["team_member_" .. i], false)
    end
end)

mod:hook_safe(CLASS.GroupFinderView, "_populate_player_request_grid", function(self)
    mod.debug.echo("desync: request")
    mod.desynced(ref)

    local grid = self._player_request_grid
    local widgets = grid and grid:widgets() or {}

    for i = 1, #widgets do
        _set_modified(widgets[i], false)
    end
end)

mod:hook_safe(CLASS.GroupFinderView, "_populate_preview_grid", function(self)
    mod.debug.echo("desync: preview")
    mod.desynced(ref)

    local grid = self._preview_grid
    local widgets = grid and grid:widgets() or {}

    for i = 1, #widgets do
        _set_modified(widgets[i], false)
    end
end)

local _get_player_info = function(account_id)
    local data_service = Managers and Managers.data_service
    local social_service = data_service and data_service.social

    return account_id and social_service and social_service:get_player_info_by_account_id(account_id)
end

local _add_level = function(widget, profile, account_id, havoc_rank)
    local content = widget and widget.content
    local character_id = profile and profile.character_id

    if not content or not character_id then
        return
    end

    if account_id and havoc_rank then
        mod.remember_havoc_rank(account_id, havoc_rank, character_id)
    end

    mod.ensure_profile_true_levels(profile, account_id, character_id)

    local true_levels = mod.get_true_levels(character_id)

    if true_levels then
        local character_archetype = ProfileUtils.character_archetype_title(profile)

        content.character_archetype_title = mod.replace_level(character_archetype, true_levels, ref, true)
        widget.tl_modified = true
    end
end

local _replace_listed_group = function(self)
    local own_group = self._own_group_visualization
    local members = own_group and own_group.members
    local widgets = self._widgets_by_name

    if not members or not widgets then
        return
    end

    for i = 1, #members do
        local member = members[i]

        if member then
            local widget = widgets["team_member_" .. i]
            local player_info = _get_player_info(member.account_id)
            local profile = player_info and player_info:profile()

            mod.watch_havoc_player_info(player_info)
            _add_level(widget, profile, member.account_id, member.havoc_rank_cadence_high)
        end
    end
end

local _replace_grid = function(grid)
    local widgets = grid and grid:widgets() or {}

    for i = 1, #widgets do
        local widget = widgets[i]
        local content = widget and widget.content
        local element = content and content.element
        local presence_info = element and element.presence_info

        if presence_info then
            local profile = presence_info.profile

            _add_level(widget, profile, element.account_id, presence_info.havoc_rank_cadence_high)
        end
    end
end

local _replace_preview_grid = function(self)
    _replace_grid(self._preview_grid)
end

local _replace_request_grid = function(self)
    _replace_grid(self._player_request_grid)
end

mod:hook_safe(CLASS.GroupFinderView, "update", function(self)
    if not mod.should_replace(ref) then
        return
    end

    local state = self._state

    if state == "browsing" then
        _replace_preview_grid(self)
        mod.synced(ref)
        mod.debug.echo("synced: browsing")
    elseif state == "advertising" then
        _replace_listed_group(self)
        _replace_request_grid(self)
        mod.synced(ref)
        mod.debug.echo("synced: advertising")
    end
end)
