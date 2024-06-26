local read_page    = require("archwiki.__read_page")
local utils        = require("archwiki.__utils")

local job          = require("plenary.job")

local pickers      = require("telescope.pickers")
local finders      = require("telescope.finders")
local conf         = require("telescope.config").values
local actions      = require("telescope.actions")
local action_state = require("telescope.actions.state")

local M            = {}

---@param items string[]
---@param opts table
function M.page_picker_itemized(items, opts)
    M.page_picker({
        finder = finders.new_table({
            results = items
        }),
        prompt_title = opts.prompt_title,
        results_title = opts.results_title
    })
end

---@param opts table
function M.page_picker(opts)
    pickers.new({}, {
        prompt_title = opts.prompt_title or "Pages",
        results_title = opts.results_title or "Search pages",
        finder = opts.finder,
        sorter = conf.generic_sorter({}),
        previewer = read_page.previewer({}),
        attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local entry = action_state.get_selected_entry()
                local text = action_state.get_current_line()
                local selection = text

                if (entry and entry[1]) then
                    selection = entry[1]
                end


                local function on_success(bufnr)
                    Config.page.handle_buf(bufnr)
                end
                local function on_err(err)
                    WikiLogger.warn("Failed to load page '" .. selection .. "'")
                    WikiLogger.error(err)
                end

                WikiLogger.info("Loading page '" .. selection .. "'")
                read_page.read_page_raw(selection, on_success, on_err)
            end)

            return true
        end,

    }):find()
end

---@class DebouncedSearchOpts
---@field timeout number|nil
---@field prompt_title string|nil
---@field results_title string|nil
---@field previewer function|nil
---@field entry_maker function|nil

---@param args string[]
---@param on_select function
---@param opts DebouncedSearchOpts
function M.debounced_search(args, on_select, opts)
    local results               = {
        current = {},
        fetched = {}
    }

    local new_results_available = false

    local runnin_job            = nil
    local picker                = nil
    local prev_prompt           = nil

    local function update_current_items()
        if picker == nil then
            return
        end

        results.current       = results.fetched
        new_results_available = false
        picker:refresh()
        WikiLogger.trace("displayed search results updated")
    end

    local function on_prompt_line_change(text)
        if text == prev_prompt then
            return
        end

        if runnin_job ~= nil then
            runnin_job:shutdown()
        end

        local stdout = ""
        runnin_job = job:new({
            command = "archwiki-rs",
            args = utils.array_join({ "search", text }, args),
            on_stdout = function(_, out)
                if not out then
                    return
                end

                stdout = stdout .. out
            end,
            on_exit = function(_, code)
                vim.schedule(function()
                    if code == 0 then
                        local parsed = vim.json.decode(stdout)
                        if parsed and picker and #parsed ~= 0 then
                            results.fetched       = parsed
                            new_results_available = true
                            WikiLogger.trace("new search results loaded")

                            if #results.current == 0 then
                                update_current_items()
                            else
                                picker:refresh()
                            end
                        end
                    end
                end)
            end
        })

        runnin_job:start()
    end

    local search_finder = finders.new_dynamic({
        fn = function(prompt)
            on_prompt_line_change(prompt)
            prev_prompt = prompt

            return results.current
        end,
        entry_maker = opts.entry_maker
    })

    picker = pickers.new({}, {
        prompt_title = opts.prompt_title or "Search the ArchWiki",
        results_title = opts.results_title or "Pages",
        finder = search_finder,
        sorter = conf.generic_sorter({}),
        previewer = opts.previewer,
        get_status_text = function()
            if new_results_available then
                return "󰑐  " .. Config.mappings.reload_search
            else
                return ""
            end
        end,
        attach_mappings = function(prompt_bufnr, map)
            map({ "i", "n" }, Config.mappings.reload_search, function(_)
                update_current_items()
            end)

            actions.select_default:replace(function()
                on_select(prompt_bufnr)
            end)
            return true
        end,
    })

    picker:find()
end

function M.cached_pages()
    local res = utils.exec_cmd('archwiki-rs info -c -o')
    if not res.success then
        WikiLogger.error('Failed to find cache directory')
        WikiLogger.debug(res)
        return
    end
    local cache_dir = vim.trim(res.stdout)

    local files = vim.fs.find(function(name)
        if Config.page.format == "markdown" then
            return name:match(".*%.md$")
        elseif Config.page.format == 'html' then
            return name:match(".*%.html$")
        end

        return true
    end, {
        type = 'file',
        path = cache_dir,
        limit = math.huge,
    })

    if #files == 0 then
        WikiLogger.info("Found no cached pages for format '" .. Config.page.format .. "'")
        return
    end

    pickers.new({}, {
        prompt_title = "Search local page caches (" .. Config.page.format .. ")",
        results_title = "Files",
        finder = finders.new_table({
            results = files,
            entry_maker = function(entry)
                local filename = vim.fs.basename(entry)
                if Config.page.format == "markdown" then
                    filename = filename:gsub(".md$", "")
                elseif Config.page.format == "html" then
                    filename = filename:gsub(".html$", "")
                end

                return {
                    value = entry,
                    display = filename,
                    ordinal = filename,

                }
            end
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
                local picker = action_state.get_current_picker(prompt_bufnr)
                local entries = picker:get_multi_selection()

                if #entries == 0 then
                    entries = { picker:get_selection() }
                end

                local entry_str = "entries"
                if #entries == 1 then
                    entry_str = "entry"
                end

                local confirmation = vim.fn.input({
                    prompt = "Delete " .. #entries .. " cache " .. entry_str .. " [y/n]: ",
                })

                if vim.tbl_contains({ 'yes', 'y' }, confirmation:lower()) then
                    actions.close(prompt_bufnr)
                    for _, entry in pairs(entries) do
                        WikiLogger.trace("deleting file based on entry value: " .. vim.inspect(entry))
                        os.remove(entry.value)
                    end
                elseif vim.tbl_contains({ 'no', 'n' }, confirmation:lower()) then
                    actions.close(prompt_bufnr)
                else
                    WikiLogger.info('Invalid confirmation input')
                end
            end)
            return true
        end,
    }):find()
end

return M
