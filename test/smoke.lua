-- smoke.lua: no cluster and no test framework. Exercises the three answers the
-- module exists to keep apart -- found, missing, forbidden -- plus the two
-- editor-facing pure functions, against a stub `oc` that test/run.sh puts first
-- on PATH.
--
-- Run directly with any interpreter the rock supports:
--   LUA_PATH="lua/?.lua;lua/?/init.lua;;" lua test/smoke.lua

local k8s = require("k8s")

local function fails(message)
    io.stderr:write("smoke: " .. message .. "\n")
    os.exit(1)
end

local client, err = k8s.new({ binary = "oc", namespace = "default" })
if not client then fails("k8s.new: " .. tostring(err)) end

-- found
local found, found_outcome = client.deployment.exists("present")
if found ~= true or found_outcome ~= "found" then
    fails("present: expected found, got " .. tostring(found) .. "/" .. tostring(found_outcome))
end

-- missing: an exit-0 empty answer is an absence, not an error
local missing, missing_outcome, missing_detail = client.deployment.exists("absent")
if missing ~= false or missing_outcome ~= "missing" then
    fails("absent: expected missing, got " .. tostring(missing) .. "/" .. tostring(missing_outcome))
end
if not missing_detail:find("is not present", 1, true) then
    fails("absent: detail does not explain the absence: " .. tostring(missing_detail))
end

-- error: a failed read is never folded into missing
local errored, error_outcome, error_detail = client.deployment.exists("forbidden")
if errored ~= false or error_outcome ~= "error" then
    fails("forbidden: expected error, got " .. tostring(errored) .. "/" .. tostring(error_outcome))
end
if not error_detail:find("Forbidden", 1, true) then
    fails("forbidden: detail lost the CLI message: " .. tostring(error_detail))
end

-- get returns the CLI's own JSON body, and the same three outcomes
local body, body_outcome = client.deployment.get("present")
if body_outcome ~= "found" or not body:find('"kind": "Deployment"', 1, true) then
    fails("get present: unexpected answer " .. tostring(body_outcome) .. " " .. tostring(body))
end
local _, absent_body = client.deployment.get("absent")
if absent_body ~= "missing" then
    fails("get absent: expected missing, got " .. tostring(absent_body))
end

-- the pure helpers a Neovim caller uses instead of shelling out
if k8s.binary({ binary = "kubectl" }) ~= "kubectl" then fails("binary: explicit name lost") end
if not k8s.available({ binary = "oc" }) then fails("available: stub oc not seen") end
if k8s.failure({ "oc", "get", "pod", "x" }, 1, 'error: pods "x" is forbidden\n'):find("\n") then
    fails("failure: multi-line output not folded into one line")
end
if #k8s.items({ items = { 1, 2, 3 } }) ~= 3 then fails("items: list not flattened") end
if #k8s.items({ kind = "Pod" }) ~= 1 then fails("items: single object not wrapped") end

-- Lua 5.1 is the reason the reader uses "*a"; prove a process round-trip works
local core = require("k8s.core")
local out, ok = core.run("printf 'hello'")
if not ok or out ~= "hello" then fails("core.run: " .. tostring(out) .. " " .. tostring(ok)) end

io.write("smoke ok (", _VERSION, ")\n")
