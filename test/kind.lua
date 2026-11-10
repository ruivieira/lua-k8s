-- kind.lua: the same answers test/smoke.lua checks, but against a real API
-- server instead of a stub `oc`.
--
-- smoke.lua proves found, missing and error are three different answers when
-- the CLI is a script that lies in a controlled way. This proves the answers
-- are *right* against a cluster that is actually changing: `-n` is honoured and
-- not guessed, an object that was never created is absent, the wait loop polls
-- until a Deployment that did not exist when the run started appears, and a
-- read whose CLI cannot reach a server is still an error rather than an
-- absence.
--
-- This file never writes to the cluster. test/kind.sh applies the fixtures,
-- creates `late` a few seconds into the run, and deletes everything afterwards;
-- keeping the writes there leaves the module under test read-only, which is what
-- it claims to be.
--
-- Environment, all set by test/kind.sh:
--   K8S_TEST_BINARY      the CLI to run through (`oc` or `kubectl`)
--   K8S_TEST_NAMESPACE   the fixture namespace (default: lua-k8s-test)
--   K8S_TEST_KUBECONFIG  kubeconfig exported from the kind cluster
--   K8S_TEST_CONTEXT     the context inside it (`kind-<cluster>`)
--
-- Run directly:
--   K8S_TEST_BINARY=kubectl K8S_TEST_NAMESPACE=lua-k8s-test \
--   K8S_TEST_KUBECONFIG=$PWD/kind.kubeconfig LUA_PATH="lua/?.lua;lua/?/init.lua;;" \
--   lua test/kind.lua

local k8s = require("k8s")

local function env(name, default)
    local value = os.getenv(name)
    if value == nil or value == "" then return default end
    return value
end

local binary = env("K8S_TEST_BINARY", "kubectl")
local namespace = env("K8S_TEST_NAMESPACE", "lua-k8s-test")
local kubeconfig = env("K8S_TEST_KUBECONFIG")
local context = env("K8S_TEST_CONTEXT")

local checks = 0
local failures = 0
local prefix = ""

-- check records one answer. `detail` is only printed on failure, because on
-- success it is either nil or the reason a negative answer is negative, and the
-- negative answers that matter are asserted on directly.
local function check(ok, what, detail)
    checks = checks + 1
    if ok then
        io.write("ok   ", prefix, what, "\n")
    else
        failures = failures + 1
        io.stderr:write("FAIL ", prefix, what,
            detail and ("\n       " .. tostring(detail)) or "", "\n")
    end
end

local function contains(value, needle)
    return tostring(value):find(needle, 1, true) ~= nil
end

-- A single client for the whole run: interval 1 makes the wait loop poll once a
-- second, which is fine-grained enough that `late` is seen within a second of
-- being created, and short enough that the deadline check below costs the two
-- seconds it asserts on.
local client, err = k8s.new({
    binary = binary,
    namespace = namespace,
    kubeconfig = kubeconfig,
    context = context,
    timeout = 0,
    interval = 1,
})
if not client then
    io.stderr:write("kind: k8s.new: " .. tostring(err) .. "\n")
    os.exit(1)
end
prefix = "[" .. binary .. "] "

-- The cluster is reachable, and the fixture namespace is there. A namespace is
-- cluster-scoped, so this read passes no -n: if the module added one anyway the
-- CLI would still answer, which is why the negative namespace test further down
-- exists.
local found, outcome, detail = client.namespace.exists(namespace)
check(found == true and outcome == "found",
    "namespace " .. namespace .. " is found", detail)

-- found: an object the fixtures created
found, outcome, detail = client.deployment.exists("present")
check(found == true and outcome == "found", "deployment present is found", detail)

-- missing: an object nobody created, asked once
local missing, missing_outcome, missing_detail = client.deployment.exists("absent")
check(missing == false and missing_outcome == "missing",
    "deployment absent is missing",
    tostring(missing) .. "/" .. tostring(missing_outcome))
check(missing_outcome == "missing" and contains(missing_detail, "is not present"),
    "the missing reason explains the absence", missing_detail)

-- The wait loop: a timeout that expires while the object stays absent returns
-- missing, names the deadline it waited for, and actually spends that time
-- polling rather than deciding once and reporting a wait it never performed.
local started = os.time()
local gone, gone_outcome, gone_detail = client.deployment.exists("absent", 2)
local elapsed = os.time() - started
check(gone == false and gone_outcome == "missing",
    "a timeout that expires is missing, not an error",
    tostring(gone) .. "/" .. tostring(gone_outcome))
check(contains(gone_detail, "within 2s"),
    "the missing reason names the deadline", gone_detail)
check(elapsed >= 2, "the wait loop polled until its deadline",
    "elapsed " .. tostring(elapsed) .. "s")

-- The wait loop, the other way: `late` is created by test/kind.sh a few seconds
-- into this run, so an immediate probe cannot see it. 90s is a generous upper
-- bound on a local cluster and still leaves the suite failing fast when the
-- Deployment never appears.
local late, late_outcome, late_detail = client.deployment.exists("late", 90)
check(late == true and late_outcome == "found",
    "deployment late appears while waiting", late_detail)

-- A list of names means all of them: the first one absent is the one named.
local both, both_outcome = client.deployment.exists({ "present", "late" })
check(both == true and both_outcome == "found",
    "exists accepts a list of names that are all present",
    tostring(both) .. "/" .. tostring(both_outcome))
local some, some_outcome, some_detail = client.deployment.exists({ "present", "absent" })
check(some == false and some_outcome == "missing" and contains(some_detail, '"absent"'),
    "exists names the first absent name in a list", some_detail)

-- get returns the CLI's own JSON, for the caller that has a parser
local body, body_outcome = client.deployment.get("present")
check(body_outcome == "found" and contains(body, '"kind": "Deployment"'),
    "get returns a Deployment body", tostring(body_outcome))
check(contains(body, '"name": "present"'), "the get body is the requested object")
local _, absent_body_outcome = client.deployment.get("absent")
check(absent_body_outcome == "missing", "get absent is missing, not empty found",
    tostring(absent_body_outcome))

-- list, narrowed by the selector the fixtures carry
local listed, listed_outcome, listed_detail =
    client.deployment.list({ selector = "app=lua-k8s-present" })
check(listed_outcome == "found" and contains(listed, "lua-k8s-present"),
    "list honours a label selector", listed_detail)
if listed_outcome == "found" then
    check(contains(listed, '"kind": "List"'), "the list body is a List")
    check(not contains(listed, '"absent"'), "the selector excluded the other objects")
end

-- list in a namespace that does not exist: exit 0, no objects. That is an
-- absence, and it must not be reported as an error.
local nowhere, nowhere_outcome, nowhere_detail =
    client.deployment.list({ namespace = namespace .. "-no-such-namespace" })
check(nowhere_outcome == "missing", "list in a missing namespace is missing",
    tostring(nowhere_outcome) .. " " .. tostring(nowhere_detail))

-- A selector that matches nothing is either an empty answer (missing) or an
-- empty List (found with no items): both mean "no such object", and neither is
-- an error. Pinned so a future change that makes an empty List look like a
-- failure has to say so here.
local none, none_outcome, none_detail =
    client.deployment.list({ selector = "app=lua-k8s-no-such-selector" })
check(none_outcome ~= "error"
    and (none_outcome == "missing" or contains(none, '"items": []')),
    "a selector matching nothing is missing or an empty List", none_detail)

-- Every registered accessor, not just deployment: the kind name each one hands
-- the CLI (networkpolicy, configmap, serviceaccount) is what decides whether the
-- read works at all.
local kinds = {
    { accessor = "network_policy", object = "networkpolicy" },
    { accessor = "config_map", object = "configmap" },
    { accessor = "service", object = "service" },
    { accessor = "service_account", object = "serviceaccount" },
    { accessor = "pod", object = "pod" },
}
for i = 1, #kinds do
    local accessor = client[kinds[i].accessor]
    local present, answer = accessor.exists("present")
    check(present == true and answer == "found",
        kinds[i].object .. " present is found")
end

-- The plural spelling is the same table, so it answers the same question
local plural, plural_outcome = client.network_policies.get("present")
check(plural_outcome == "found" and contains(plural, '"kind": "NetworkPolicy"'),
    "the plural accessor answers for one object", tostring(plural_outcome))

-- The escape hatch resolves an unregistered kind through the same machinery
local custom, custom_outcome = client:resource("networkpolicy").exists("present")
check(custom == true and custom_outcome == "found",
    "resource() answers for a kind it did not register",
    tostring(custom) .. "/" .. tostring(custom_outcome))

-- -n is honoured, not guessed: the same object read from another namespace is
-- absent. This is the check that would pass vacuously if the module fell back to
-- the kubeconfig's current namespace.
local elsewhere, elsewhere_outcome = client.config_map.exists("present", { namespace = "default" })
check(elsewhere == false and elsewhere_outcome == "missing",
    "a per-call namespace is passed through",
    tostring(elsewhere) .. "/" .. tostring(elsewhere_outcome))
local here, here_outcome = client.config_map.exists("present", { namespace = namespace })
check(here == true and here_outcome == "found",
    "the same object is found in its own namespace", tostring(here_outcome))

-- A namespaced read with no namespace is a programming error, and it raises
-- instead of silently reading the current context's namespace.
local bare = k8s.new({ binary = binary, kubeconfig = kubeconfig, context = context })
local raised, message = pcall(function() return bare.deployment.exists("present") end)
check(raised == false and contains(message, "namespaced"),
    "a namespaced read without a namespace raises", tostring(message))

-- error: a client whose kubeconfig does not exist cannot read anything, and
-- that is never folded into missing. The CLI's own complaint reaches this
-- terminal (core.run leaves stderr attached) and is also carried in detail;
-- printing it twice is the documented behaviour of a failing call, not noise
-- this test forgot to silence.
local broken = k8s.new({
    binary = binary,
    namespace = namespace,
    kubeconfig = "/nonexistent/lua-k8s/kubeconfig",
})
local unreadable, unreadable_outcome, unreadable_detail =
    broken.deployment.exists("present")
check(unreadable == false and unreadable_outcome == "error",
    "an unreachable server is an error, not an absence",
    tostring(unreadable) .. "/" .. tostring(unreadable_outcome))
check(unreadable_outcome == "error" and tostring(unreadable_detail) ~= "",
    "the error carries the CLI's message", unreadable_detail)

-- cluster-scoped kinds are read as cluster-scoped: a CRD that is not installed
-- is missing, and no -n was needed to ask
local crd, crd_outcome = client.crd.exists("widgets.lua-k8s.example.com")
check(crd == false and crd_outcome == "missing",
    "an uninstalled crd is missing", tostring(crd) .. "/" .. tostring(crd_outcome))

-- run() is the read-only half of the escape hatch: a verb the accessors do not
-- model (here `-o name`) still has to come back as (output, ok).
local out, ok = client:run({ "get", "configmap", "present", "-n", namespace, "-o", "name" })
check(ok == true and contains(out, "configmap/present"),
    "run returns the CLI's own answer", tostring(out))

-- the two pure helpers that decide which CLI answers
check(k8s.binary({ binary = binary }) == binary, "binary keeps an explicit name")
check(k8s.available({ binary = binary }) == true, "the binary under test is executable")

if failures > 0 then
    io.stderr:write(("kind: %d of %d checks failed (%s, %s)\n")
        :format(failures, checks, _VERSION, binary))
    os.exit(1)
end

io.write(("kind ok (%s, %s, %d checks)\n"):format(_VERSION, binary, checks))
