local job = require('plenary.job')

local M = {}

---@param a any[]
---@param b any[]
---@return table
function M.array_join(a, b)
    local res = {}
    for _, value in ipairs(a) do
        table.insert(res, value)
    end

    for _, value in ipairs(b) do
        table.insert(res, value)
    end

    return res
end

---@param arr any[]
---@param f function
--- @return table
function M.filter(arr, f)
    local result = {}
    for _, value in pairs(arr) do
        if f(value) then
            table.insert(result, value)
        end
    end

    return result
end

---@class CmdResult
---@field success boolean
---@field stdout string | nil
---@field stderr string | nil

---@param command string
---@return CmdResult
function M.exec_cmd(command)
    local tmpfile = os.tmpname()

    WikiLogger.trace("executing command " .. command)
    WikiLogger.trace("stdout sent to " .. tmpfile)
    WikiLogger.trace("stdderr sent to " .. tmpfile .. ".err")

    local exit = os.execute(command .. ' > ' .. tmpfile .. ' 2> ' .. tmpfile .. '.err')

    local stdout_file = io.open(tmpfile)
    local stdout = nil
    if stdout_file ~= nil then
        stdout = stdout_file:read("*all")
        if string.gsub(stdout, "%s+", "") == "" then
            stdout = nil
        end

        stdout_file:close()
    end


    local stderr_file = io.open(tmpfile .. '.err')
    local stderr = nil
    if stderr_file ~= nil then
        stderr = stderr_file:read("*all")
        if string.gsub(stderr, "%s+", "") == "" then
            stderr = nil
        end

        stderr_file:close()
    end

    WikiLogger.trace("command '" .. command .. "'" .. "exited with code " .. exit)
    return {
        success = exit == 0,
        stdout = stdout,
        stderr = stderr,
    }
end

---@param triple_b string[]
---@param triple_a string[]
---@param digit "major"|"minor"|"patch"
---@return "greater"|"equal"|"smaller"
local function cmp_semver_version_digit(triple_a, triple_b, digit)
    ---@type integer
    local idx
    if digit == "major" then
        idx = 1
    elseif digit == "minor" then
        idx = 2
    else
        idx = 3
    end

    local ver_a = tonumber(triple_a[idx])
    assert(ver_a ~= nil,
        "semantic version string contains the none number value '" .. triple_a[idx] .. "' as the " .. digit .. " version")
    local ver_b = tonumber(triple_b[idx])
    assert(ver_b ~= nil,
        "semantic version string contains the none number value '" .. triple_b[idx] .. "' as the " .. digit .. " version")

    if ver_a > ver_b then
        return "greater"
    elseif ver_a < ver_b then
        return "smaller"
    end

    return "equal"
end

--- Compare 2 semantic version strings of the form x.y.z
---@param smvr_string_a string
---@param smvr_string_b string
---@return "greater"|"equal"|"smaller"
function M.cmp_semver_version(smvr_string_a, smvr_string_b)
    local a = vim.trim(smvr_string_a)
    local b = vim.trim(smvr_string_b)

    local triple_a = vim.split(a, ".", { plain = true });
    WikiLogger.trace("parsed smvr triple as: ", triple_a)
    assert(#triple_a == 3, "semantic version string '" .. a .. "' is not of the form 'x.y.z'")

    local triple_b = vim.split(a, ".", { plain = true });
    WikiLogger.trace("parsed smvr triple as: ", triple_b)
    assert(#triple_b == 3, "semantic version string '" .. b .. "' is not of the form 'x.y.z'")

    local ord_major = cmp_semver_version_digit(triple_a, triple_b, "major")
    if ord_major ~= "equal" then
        return ord_major
    end

    local ord_minor = cmp_semver_version_digit(triple_a, triple_b, "minor")
    if ord_minor ~= "equal" then
        return ord_minor
    end

    return cmp_semver_version_digit(triple_a, triple_b, "patch")
end

function M.fetch_wiki_metadata()
    local res = M.exec_cmd("archwiki-rs info -o -d")
    assert(res.success, "Failed to fetch ArchWiki metadata")

    local dir = string.gsub(res.stdout, "\n$", "")
    local path = dir .. "/pages.yml"

    local f = io.open(path, "r")
    if f ~= nil then
        io.close(f)
        return
    end

    job:new({
        command = "archwiki-rs",
        args = { "sync-wiki", "-H" },
        on_start = function()
            WikiLogger.info("Fetching ArchWiki metadata")
        end,
        on_exit = function(_, code)
            if code ~= 0 then
                WikiLogger.info("Failed to fetch ArchWiki metadata")
            end
        end
    }):start()
end

return M
