-- k8s.client: the Client implementation behind `require("k8s")`. One object
-- owns the CLI invocation, the quoting, the wait loop and the outcome
-- vocabulary, so a caller asks a question instead of re-deriving
-- `oc get ... >/dev/null 2>&1` plus a deadline plus a sleep.
--
-- The public module is lua/k8s.lua; this file is required by it and exports the
-- constructor and the metatable at the end.
--
-- Every accessor answers rather than raises: (value, outcome, detail)
--
--   outcome == "found"    value is the answer -- true for exists, the JSON body
--                         for get/list -- and detail is nil.
--   outcome == "missing"  value is the negative answer (false, ""), detail the
--                         reason ("networkpolicy "x" is not present in
--                         namespace "y" within 180s").
--   outcome == "error"    the CLI itself failed: not logged in, RBAC, no
--                         server, unknown kind. detail carries the CLI's own
--                         message. This is never folded into "missing": a
--                         caller that skips on absence must not skip because
--                         it could not read the cluster at all.

local core = require("k8s.core")
local primitives = require("k8s.primitives")

local client = {}

-- The kinds that get a first-class accessor. `singular` and `plural` are the
-- table names on the client (`client.network_policy`, `client.network_policies`);
-- both answer the same questions, because "network_policy.exists(x)" and
-- "network_policies.exists({x, y})" are the same question about one and about
-- several. `kind` is what the CLI is told, which is the singular lowercase form
-- without the underscore. `namespaced` decides whether -n is passed at all: a
-- cluster-scoped kind given -n is at best ignored and at worst confusing when
-- read back in a log.
--
-- Not registered: `secret`. `get` would happily return its base64 data and
-- this module never prints credentials; a caller that really wants one
-- builds it explicitly with `client:resource("secret")` and owns that decision.
local RESOURCES = {
    { singular = "namespace", plural = "namespaces", kind = "namespace", namespaced = false },
    { singular = "network_policy", plural = "network_policies", kind = "networkpolicy", namespaced = true },
    { singular = "deployment", plural = "deployments", kind = "deployment", namespaced = true },
    { singular = "pod", plural = "pods", kind = "pod", namespaced = true },
    { singular = "service", plural = "services", kind = "service", namespaced = true },
    { singular = "config_map", plural = "config_maps", kind = "configmap", namespaced = true },
    { singular = "service_account", plural = "service_accounts", kind = "serviceaccount", namespaced = true },
    { singular = "crd", plural = "crds", kind = "customresourcedefinition", namespaced = false },
}

-- Every client field an accessor must not overwrite. The default namespace is
-- `default_namespace` and not `namespace` for exactly this reason: `namespace`
-- is the namespace accessor, and a field of that name would be swapped for a
-- table the moment the accessors are installed -- which is how a message came
-- out as `in namespace "table: 0x..."`.
local RESERVED = { "binary", "default_namespace", "timeout", "interval", "context", "kubeconfig" }
for i = 1, #RESOURCES do
    for j = 1, #RESERVED do
        local spec = RESOURCES[i]
        if spec.singular == RESERVED[j] or spec.plural == RESERVED[j] then
            error("k8s: resource " .. spec.singular .. " collides with the client field "
                .. RESERVED[j], 0)
        end
    end
end

-- q quotes a name for a human-readable message. Not core.shquote: this text
-- goes into a report line, not into a command, so it reads as `"name"`.
local function q(value)
    return '"' .. tostring(value) .. '"'
end

-- seconds turns a timeout or interval into a number the deadline arithmetic can
-- use, and rejects anything else instead of polling forever. A value read
-- from a config file arrives as a string, so "180" is accepted; "" is not.
local function seconds(value, what)
    local number = tonumber(value)
    if not number or number < 0 then
        error("k8s: " .. what .. " must be a non-negative number of seconds, got "
            .. tostring(value), 0)
    end
    return number
end

-- where renders the namespace part of a message, and is empty for a
-- cluster-scoped kind so the reason never names a namespace that played no part.
local function where(kind_namespaced, namespace)
    if not kind_namespaced then return "" end
    if not namespace or namespace == "" then return "" end
    return " in namespace " .. q(namespace)
end

local function describe_missing(kind, kind_namespaced, name, namespace, timeout)
    local waited = ""
    if timeout and timeout > 0 then
        waited = " within " .. tostring(timeout) .. "s"
    end
    return kind .. " " .. q(name) .. " is not present"
        .. where(kind_namespaced, namespace) .. waited
end

local function describe_error(kind, kind_namespaced, name, namespace, detail)
    return "cannot read " .. kind .. " " .. q(name)
        .. where(kind_namespaced, namespace) .. ": " .. tostring(detail)
end

local Client = {}
Client.__index = Client

-- k8s.new(opts) -> client, err
--
-- opts is optional and may carry:
--   binary      the cluster CLI (default: oc when installed, else kubectl).
--               Must be on PATH; a client that would fail on every call is not
--               a client, so the constructor refuses instead.
--   namespace   the namespace namespaced kinds are read from unless a call
--               overrides it. Required for them: a silent fallback to the
--               kubeconfig's current namespace would turn a wrong namespace
--               into a confident "not present".
--   timeout     default wait for exists, in seconds (default 0: ask once)
--   interval    seconds between attempts while waiting (default 5)
--   context     --context value
--   kubeconfig  --kubeconfig value
--
-- Returns nil and a message -- never a client that fails later -- because the
-- one thing a caller cannot recover from at the point of use is not knowing
-- which CLI it is talking through. Callers that trust their environment write
-- `local client = k8s.new()`, which drops the message.
function client.new(opts)
    if opts == nil then opts = {} end
    if type(opts) ~= "table" then
        error("k8s.new: options must be a table, got " .. type(opts), 0)
    end

    local binary = opts.binary
    if not binary or binary == "" then
        if core.on_path("oc") then
            binary = "oc"
        elseif core.on_path("kubectl") then
            binary = "kubectl"
        else
            return nil, "k8s.new: neither oc nor kubectl is on PATH; install one or pass binary"
        end
    end
    if not core.on_path(binary) then
        return nil, "k8s.new: " .. tostring(binary) .. " is not executable on PATH"
    end

    local self = setmetatable({}, Client)
    self.binary = binary
    self.default_namespace = opts.namespace
    self.timeout = opts.timeout ~= nil and seconds(opts.timeout, "timeout") or 0
    self.interval = opts.interval ~= nil and seconds(opts.interval, "interval") or 5
    self.context = opts.context
    self.kubeconfig = opts.kubeconfig

    for i = 1, #RESOURCES do
        local spec = RESOURCES[i]
        local accessor = self:_accessor(spec.kind, spec.namespaced)
        self[spec.singular] = accessor
        self[spec.plural] = accessor
    end
    return self
end

-- client:resource(kind, opts) -> accessor
--
-- The same accessor for a kind RESOURCES does not list, such as an operator's
-- own custom resource: client:resource("ingress") or
-- client:resource("widget"). Defaults to namespaced; pass
-- { namespaced = false } for a cluster-scoped one.
function Client:resource(kind, opts)
    if type(kind) ~= "string" or kind == "" then
        error("k8s: resource kind must be a non-empty string, got " .. tostring(kind), 0)
    end
    if opts == nil then opts = {} end
    if type(opts) ~= "table" then
        error("k8s: resource options must be a table, got " .. type(opts), 0)
    end
    local kind_namespaced = true
    if opts.namespaced ~= nil then kind_namespaced = opts.namespaced and true or false end
    return self:_accessor(tostring(kind), kind_namespaced)
end

-- _accessor builds the question table one kind answers. Both spellings share
-- it -- client.network_policy and client.network_policies are the same table --
-- so an accessor never diverges from its plural.
function Client:_accessor(kind, kind_namespaced)
    local client = self
    local function exists(names, opts)
        return client:_exists(kind, kind_namespaced, names, opts)
    end
    return {
        kind = kind,
        namespaced = kind_namespaced,
        exists = exists,
        exist = exists,
        get = function(name, opts)
            return client:_get(kind, kind_namespaced, name, opts)
        end,
        list = function(opts)
            return client:_list(kind, kind_namespaced, opts)
        end,
    }
end

-- _command builds the shell command line. core.shquote every argument: a
-- namespace or a label selector is caller data, and nothing in it may be
-- re-parsed as shell syntax. The global flags come before the verb, where both
-- oc and kubectl accept them. `k8s.argv` is the argv this is the quoted form of,
-- so the flags are decided in one place and a caller with its own process API
-- (vim.system) uses the same list.
function Client:_command(args)
    local argv = primitives.argv({
        binary = self.binary,
        context = self.context,
        kubeconfig = self.kubeconfig,
    }, args)
    local parts = {}
    for i = 1, #argv do
        parts[i] = core.shquote(argv[i])
    end
    return table.concat(parts, " ")
end

-- _capture runs one CLI call: stdout, and a detail string when it failed.
--
-- The first run leaves stderr attached, so a failing call prints its reason
-- into the caller's output exactly once. A failure is then re-run with stderr
-- merged into stdout to carry that reason back in `detail`. Not the other way
-- round:
-- merging streams on the normal path would let a deprecation warning printed to
-- stderr turn an empty answer -- a missing object -- into a non-empty one, and
-- "found" for something that is not there is the one wrong answer this module
-- must never give. Nothing is written to a temp file, so there is nothing to
-- clean up and no state to leak between calls.
function Client:_capture(args)
    local command = self:_command(args)
    local out, ok = core.run(command)
    if ok then return out, nil end
    local detail = primitives.trim(core.run(command .. " 2>&1"))
    if detail == "" then
        detail = "the CLI exited non-zero: " .. command
    end
    return "", detail
end

-- _scope appends the namespace a namespaced read needs, and refuses to guess.
function Client:_scope(args, kind, kind_namespaced, opts)
    if not kind_namespaced then return end
    local namespace = opts.namespace
    if not namespace or namespace == "" then
        error("k8s: " .. kind .. " is namespaced: pass namespace in the options"
            .. " (or the client) instead of relying on the current context", 0)
    end
    args[#args + 1] = "-n"
    args[#args + 1] = namespace
end

-- _options folds a call's options over the client defaults. A bare number is
-- the timeout, because exists(name, 60) reads better than exists(name, {timeout = 60})
-- for the common case.
function Client:_options(opts)
    local resolved = {
        namespace = self.default_namespace,
        timeout = self.timeout,
        interval = self.interval,
    }
    if opts == nil then return resolved end
    if type(opts) == "number" or type(opts) == "string" then
        resolved.timeout = seconds(opts, "timeout")
        return resolved
    end
    if type(opts) ~= "table" then
        error("k8s: options must be a table, a number of seconds or nil, got "
            .. type(opts), 0)
    end
    if opts.namespace ~= nil then resolved.namespace = opts.namespace end
    if opts.timeout ~= nil then resolved.timeout = seconds(opts.timeout, "timeout") end
    if opts.interval ~= nil then resolved.interval = seconds(opts.interval, "interval") end
    return resolved
end

-- _probe answers one question about one object, without waiting.
--
-- `--ignore-not-found` is what makes the answer unambiguous: the CLI exits 0
-- with no output both when the object is absent and when the namespace is, so
-- an exit 0 plus an empty answer means "not there" and nothing else. Without
-- it every absence would arrive as a non-zero exit and be indistinguishable
-- from a real failure. `-o name` keeps the answer one line whether the object
-- exists or not, so nothing has to parse JSON to learn it.
function Client:_probe(kind, kind_namespaced, name, opts)
    local args = { "get", kind, name, "--ignore-not-found", "-o", "name" }
    self:_scope(args, kind, kind_namespaced, opts)
    local out, detail = self:_capture(args)
    if detail then return nil, detail end
    if primitives.trim(out) == "" then return false end
    return true
end

-- _exists waits for every named object to exist, then says so.
--
-- A list means all of them, which is the question a test suite usually asks
-- ("both policies are deployed"); the first one still absent at the deadline is
-- the one the reason names.
function Client:_exists(kind, kind_namespaced, names, opts)
    local resolved = self:_options(opts)
    local list = {}
    if type(names) == "table" then
        for i = 1, #names do list[i] = names[i] end
    else
        list[1] = names
    end
    if #list == 0 then return true, "found" end

    -- os.time() counts whole seconds, which is the resolution a wait measured
    -- in seconds and polled every five of them actually has.
    local deadline = os.time() + resolved.timeout
    while true do
        local absent
        for i = 1, #list do
            local found, detail = self:_probe(kind, kind_namespaced, list[i], resolved)
            if found == nil then
                return false, "error",
                    describe_error(kind, kind_namespaced, list[i], resolved.namespace, detail)
            end
            if not found then
                absent = list[i]
                break
            end
        end
        if not absent then return true, "found" end
        if os.time() >= deadline then
            return false, "missing",
                describe_missing(kind, kind_namespaced, absent, resolved.namespace, resolved.timeout)
        end
        -- interval 0 means "ask again immediately": the test harness uses it to
        -- exercise the wait without spending the wall-clock time.
        if resolved.interval > 0 then
            core.run("sleep " .. tostring(resolved.interval))
        end
    end
end

-- _get returns the object as the CLI renders it (`-o json`), for the caller
-- that has a JSON parser or hands the body to jq.
function Client:_get(kind, kind_namespaced, name, opts)
    local resolved = self:_options(opts)
    local args = { "get", kind, name, "--ignore-not-found", "-o", "json" }
    self:_scope(args, kind, kind_namespaced, resolved)
    local out, detail = self:_capture(args)
    if detail then
        return "", "error",
            describe_error(kind, kind_namespaced, name, resolved.namespace, detail)
    end
    if primitives.trim(out) == "" then
        return "", "missing",
            describe_missing(kind, kind_namespaced, name, resolved.namespace, 0)
    end
    return out, "found"
end

-- _list returns every object of a kind as `-o json`, optionally narrowed by a
-- label or field selector. opts may also carry all_namespaces, for the
-- cluster-wide read `-n` cannot express.
function Client:_list(kind, kind_namespaced, opts)
    if opts ~= nil and type(opts) ~= "table" then
        error("k8s: list options must be a table, got " .. type(opts), 0)
    end
    local options = opts or {}
    local resolved = self:_options(options)
    local args = { "get", kind, "--ignore-not-found", "-o", "json" }
    if options.all_namespaces then
        args[#args + 1] = "-A"
    else
        self:_scope(args, kind, kind_namespaced, resolved)
    end
    if options.selector and options.selector ~= "" then
        args[#args + 1] = "-l"
        args[#args + 1] = options.selector
    end
    if options.field_selector and options.field_selector ~= "" then
        args[#args + 1] = "--field-selector"
        args[#args + 1] = options.field_selector
    end
    local out, detail = self:_capture(args)
    if detail then
        return "", "error", "cannot list " .. kind .. ": " .. tostring(detail)
    end
    if primitives.trim(out) == "" then
        return "", "missing",
            "no " .. kind .. " matches"
                .. where(kind_namespaced, resolved.namespace)
                .. (options.selector and (" selector " .. q(options.selector)) or "")
    end
    return out, "found"
end

-- client:run(args) -> stdout, ok, detail
--
-- The escape hatch for a verb the accessors do not model (`apply`, `delete`,
-- `wait`, a subresource). args is a list of arguments, each quoted; stderr is
-- left attached, and the failure detail is harvested the same way as above.
-- Nothing is interpreted, so this is the one place a caller can reach the CLI
-- directly -- keep writes out of it unless the caller owns the approval.
function Client:run(args)
    if type(args) ~= "table" then
        error("k8s: run expects a list of arguments, got " .. type(args), 0)
    end
    local out, detail = self:_capture(args)
    if detail then return out, false, detail end
    return out, true
end

-- The constructor under the name a reader of the call sites expects, so
-- k8s.K8sClient.new(opts) and k8s.new(opts) are the same function.

Client.new = client.new
client.Client = Client

return client
