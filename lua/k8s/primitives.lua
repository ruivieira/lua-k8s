-- k8s.primitives: the questions a caller's own Kubernetes client shares, as
-- strings and tables rather than as processes. `binary`/`available` decide
-- which CLI and whether it can run, `argv` is the command line with its global
-- flags, `failure` renders a non-zero exit as one readable line and `items`
-- unwraps a decoded `-o json` answer. They never run anything and never touch
-- an editor API, so an asynchronous caller (vim.system) and the synchronous
-- `k8s` client reach the same answers.
--
-- Portability: the Lua 5.1/5.5 common subset, because this loads in LuaJIT
-- (what Neovim embeds) and in a standalone interpreter.

local core = require("k8s.core")

local primitives = {}

-- The CLIs `binary = "auto"` looks for, in preference order: oc speaks the
-- same API and adds the OpenShift view of it.
primitives.candidates = { "oc", "kubectl" }

-- Whether a name is executable. The default is core's `command -v`; a Neovim
-- caller passes `vim.fn.executable` instead so resolving a binary costs no
-- process, and the two answers cannot disagree about anything but speed.
local function on_path(name)
    return core.on_path(name)
end

-- trims the whitespace a CLI call leaves around a value: oc prints its answer
-- with a trailing newline, and an empty answer for a missing object is not
-- always zero bytes.
local function trim(value)
    return (tostring(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The client trims CLI output too, and a second copy would be a second answer
-- about what "empty" means.
primitives.trim = trim

--- The binary a command line would start, or nil when `auto` finds neither.
---
--- `opts.binary` may name one (`oc`, `kubectl`, an absolute path); anything
--- else -- nil, "", "auto" -- takes the first candidate that is executable.
--- An explicitly named binary is returned whether or not it can run: naming one
--- and finding it missing are two answers, and `available` is the second.
---@param opts table|nil
---@param is_executable fun(name: string): boolean|nil
---@return string|nil
function primitives.binary(opts, is_executable)
    opts = opts or {}
    local wanted = opts.binary
    if wanted ~= nil then wanted = trim(wanted) end
    if wanted and wanted ~= "" and wanted ~= "auto" then
        return wanted
    end
    local exists = is_executable or on_path
    for i = 1, #primitives.candidates do
        if exists(primitives.candidates[i]) then
            return primitives.candidates[i]
        end
    end
    return nil
end

--- Whether the binary a command line would start is actually installed.
---@param opts table|nil
---@param is_executable fun(name: string): boolean|nil
---@return boolean
function primitives.available(opts, is_executable)
    local binary = primitives.binary(opts, is_executable)
    if not binary then
        return false
    end
    return (is_executable or on_path)(binary) and true or false
end

--- The argv for one CLI call: the binary, its global flags, then `args`.
---
--- Returns nil and a message -- never a list that would fail on its first
--- element -- because the one thing a caller cannot recover from at the point of
--- use is not knowing which CLI it is talking through. The namespace flag is
--- only added when `opts.namespace` is set: a caller that appends the namespace
--- per read (`-n`) must not get a second one that also applies to cluster-scoped
--- kinds.
---@param opts table|nil
---@param args string[]|nil
---@param is_executable fun(name: string): boolean|nil
---@return string[]|nil argv, string|nil error
function primitives.argv(opts, args, is_executable)
    opts = opts or {}
    local binary = primitives.binary(opts, is_executable)
    if not binary then
        return nil, "neither oc nor kubectl is on PATH"
    end

    local argv = { binary }
    local global = {
        { flag = "--kubeconfig", value = opts.kubeconfig },
        { flag = "--context", value = opts.context },
        { flag = "--namespace", value = opts.namespace },
    }
    for i = 1, #global do
        local value = global[i].value
        if value ~= nil then
            value = trim(value)
            if value ~= "" then
                argv[#argv + 1] = global[i].flag
                argv[#argv + 1] = value
            end
        end
    end
    for i = 1, #(args or {}) do
        argv[#argv + 1] = tostring(args[i])
    end
    return argv
end

--- A failed invocation as one line a notification or a report cell can hold.
---
--- kubectl prefixes nearly everything with `error: ` and its multi-line
--- explanation is what a reader needs, so the prefix goes and the newlines become
--- separators. The command is repeated without the binary, which is the part
--- that says what was being read. Exit 124 is the timeout a caller imposes
--- through `vim.system`, `timeout(1)` or its own deadline.
---@param argv string[]|nil
---@param code integer|string|nil
---@param stderr string|nil
---@return string
function primitives.failure(argv, code, stderr)
    local arguments = {}
    for i = 2, #(argv or {}) do
        arguments[#arguments + 1] = tostring(argv[i])
    end

    local detail = tostring(stderr or "")
    detail = detail:gsub("^%s*error:%s*", "")
    detail = detail:gsub("%s+$", "")
    detail = detail:gsub("%s*\r?\n%s*", "; ")

    local status = tonumber(code) or 0
    if status == 124 then
        detail = "timed out" .. (detail ~= "" and (" (" .. detail .. ")") or "")
    elseif detail == "" then
        detail = "no output"
    end

    return string.format(
        "%s %s failed (exit %s): %s",
        tostring((argv or {})[1] or "?"),
        table.concat(arguments, " "),
        tostring(status),
        detail
    )
end

--- The objects in a decoded `-o json` answer.
---
--- A `List` carries `items`; a single object does not, and is returned as the
--- one-element list it means.
---@param decoded table|nil
---@return table[]
function primitives.items(decoded)
    if type(decoded) ~= "table" then
        return {}
    end
    if type(decoded.items) == "table" then
        return decoded.items
    end
    return { decoded }
end

return primitives
