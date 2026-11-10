-- core: the process, shell-quoting and path helpers the Kubernetes client is
-- built on, kept in their own module.
--
-- Why these and nothing else: the Lua standard library has no process API, no
-- shell quoting and no way to ask a question about a path, so any code that has
-- to call git, jq or a cluster CLI ends up needing all three. Keeping them in
-- one place stops every caller from re-deriving them slightly differently: the
-- popen wrapper below exists because the obvious one is silently wrong under
-- LuaJIT, and is_file/is_executable/parent are the three path questions such
-- code always asks.
--
-- Portability: this file loads in LuaJIT (what Neovim embeds) and in a
-- standalone interpreter, so it stays inside the 5.1/5.5 common subset. No
-- `//`, no `<const>`/`<close>` attributes, no table.unpack, no utf8, no
-- string.pack, and nothing from any editor or application API.

local core = {}

-- shquote: wrap a value in single quotes for a POSIX shell, embedded single
-- quotes included ("'" becomes "'\''"). Use it on every path, name or value
-- that reaches a command string; nothing then gets re-parsed as shell syntax.
function core.shquote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- The marker core.run appends to a command. A control character, so ordinary
-- command output cannot forge it.
local STATUS = "\1__status__="

-- core.run(cmd) -> output, ok
--
-- Runs cmd through the shell and returns its stdout and whether it exited 0.
-- stderr stays connected to the caller's: a failure worth diagnosing should be
-- visible.
--
-- The exit status comes from a marker the command prints, not from
-- handle:close(). In stock Lua close() reports (true, "exit", code), but LuaJIT
-- returns true whatever the child returned, so the obvious implementation
-- silently turns every failure into a success on the interpreter Neovim embeds
-- -- a missing jq or a failed mkdir would look like it worked. The marker costs
-- one printf and is correct on both.
function core.run(cmd)
    local handle = io.popen(cmd .. '; printf "\\001__status__=%s\\n" "$?"')
    if not handle then return "", false end
    -- "*a", not "a": PUC Lua 5.1 (the version a Neovim rock must suit)
    -- rejects the bare form, while 5.2+ and LuaJIT accept the starred one.
    local out = handle:read("*a") or ""
    handle:close()
    local body, code = out:match("^(.-)" .. STATUS .. "(%d+)\n$")
    if not body then return out, false end
    return body, code == "0"
end

-- core.on_path(name) -> boolean
--
-- Whether an executable called name can be found on PATH. `command -v` prints
-- the path it found, so its stdout is discarded; core.run still reports the
-- status.
--
-- When that misses, walk PATH again with each entry's leading `~` expanded.
-- bash expands that form while it searches PATH, but POSIX sh -- io.popen here,
-- and the `sh -c` of a cron job or CI step -- does not, while installers
-- commonly write exactly that form (`export PATH="$PATH:~/go/bin"`). A tool
-- installed into ~/go/bin would otherwise look missing. Only a regular
-- executable file counts on the second pass: `command -v` alone answers for a
-- builtin, function or alias, none of which a subprocess has.
function core.on_path(name)
    local _, ok = core.run("command -v " .. core.shquote(name) .. " >/dev/null 2>&1")
    if ok then return true end
    -- An explicit path was already answered by `command -v`; prefixing a PATH
    -- entry to it would build a path nobody asked for.
    if name:find("/", 1, true) then return false end
    local home = os.getenv("HOME") or ""
    for raw in (os.getenv("PATH") or ""):gmatch("[^:]+") do
        -- A separate local, because a for-loop's control variable is const in
        -- Lua 5.5: assigning the expanded entry back through it fails to load
        -- this module there, and 5.5 is what a Homebrew `lua` is now.
        local entry = raw
        if home ~= "" then
            if entry == "~" then
                entry = home
            elseif entry:sub(1, 2) == "~/" then
                entry = home .. entry:sub(2)
            end
        end
        local candidate = entry .. "/" .. name
        local _, executable = core.run("test -f " .. core.shquote(candidate)
            .. " && test -x " .. core.shquote(candidate) .. " >/dev/null 2>&1")
        if executable then return true end
    end
    return false
end

-- core.is_file(path) -> boolean
--
-- Whether path is a regular file. `test -f` through the shell, because the Lua
-- standard library can open a file but cannot ask about one: a directory would
-- show up as an io.open failure and a special file would not show up at all.
-- The same reason `on_path` asks `command -v` instead of stat-ing PATH itself.
function core.is_file(path)
    local _, ok = core.run("test -f " .. core.shquote(path))
    return ok
end

-- core.is_executable(path) -> boolean
--
-- Whether path exists and is executable: the check a caller makes before it runs
-- a script it found by walking a list of anchors, so a missing +x is reported as
-- `chmod +x <path>` rather than as the shell's "permission denied" once the run
-- is already under way.
function core.is_executable(path)
    local _, ok = core.run("test -x " .. core.shquote(path))
    return ok
end

-- core.parent(path) -> string
--
-- dirname: everything before the last "/", with trailing slashes dropped. Pure
-- Lua, because this is a string operation and a shell call for it would be two
-- process starts for one path. The answers are dirname's: "/" is its own parent,
-- one level below the root is "/", and a bare name is ".".
function core.parent(path)
    local trimmed = tostring(path):gsub("/+$", "")
    if trimmed == "" then return "/" end
    local head = trimmed:match("^(.*)/[^/]*$")
    if head == nil then return "." end
    if head == "" then return "/" end
    return head
end

-- core.tmpdir() -> path, ok
--
-- Creates a directory of its own under the system temp directory. Lua 5.4
-- creates the file behind os.tmpname() and 5.1 does not, so the name is cleared
-- either way before the directory is made. Removing what is left is the
-- caller's job (`rm -rf` through core.run): a caller that forgets leaks a
-- directory, so it should either drop it at the end of the run or as soon as it
-- is no longer needed.
function core.tmpdir()
    local path = os.tmpname()
    os.remove(path)
    return path, core.make_dir(path)
end

-- core.make_dir(path) -> ok, err
--
-- `mkdir -p`, without a shell call at the caller: creates path and any missing
-- parent, and is a no-op when the directory is already there. err is what mkdir
-- said (empty when it worked), captured rather than printed, so the caller can
-- put it in its own message -- core exits nothing and writes nothing.
function core.make_dir(path)
    local out, ok = core.run("mkdir -p " .. core.shquote(path) .. " 2>&1")
    if ok then return true end
    return false, (out:gsub("\n+$", ""))
end

-- core.write_file(path, text) -> ok, err
--
-- Writes text to path, replacing it, and reports whether the file is on disk.
-- No trailing newline is added: the caller writes the bytes it means, because
-- such files are often read line by line or handed unchanged to another tool.
-- The second return value is the OS message, for the caller to put in its own
-- error -- core exits nothing and writes nothing, so the exit policy stays with
-- the script.
function core.write_file(path, text)
    local handle, open_err = io.open(path, "w")
    if not handle then return false, open_err end
    local wrote, write_err = handle:write(text)
    local closed, close_err = handle:close()
    if not wrote then return false, write_err end
    if not closed then return false, close_err end
    return true
end

return core
