-- k8s: a Kubernetes client for Lua scripts, backed by a cluster CLI (oc or
-- kubectl). One object owns the CLI invocation, the quoting, the wait loop and
-- the outcome vocabulary, so a caller asks a question instead of re-deriving
-- `oc get ... >/dev/null 2>&1` plus a deadline plus a sleep.
--
--   local k8s = require("k8s")
--   local client, err = k8s.new()                       -- oc, else kubectl
--   local client = k8s.new({ binary = "kubectl", namespace = "default" })
--
--   client.namespace.exists("default")                  -- cluster-scoped
--   client.namespaces.exists({"a", "b"}, 120)           -- all of them, waiting
--   client.network_policy.exists("allow-ports", { namespace = "default", timeout = 180 })
--   client.pods.exists("my-pod")                        -- plural accessor too
--   local body = client.deployment.get("my-app")
--
-- The parts of a caller's own client that are not about *when* a process runs
-- are here too, so an asynchronous caller (a Neovim adapter using vim.system)
-- and this one agree instead of keeping two copies: `binary`/`available` (which
-- CLI, and whether it can run), `argv` (the command line with its global flags),
-- `failure` (a non-zero exit as one readable line) and `items` (the objects in
-- a decoded `-o json` answer). Those answer questions about strings and tables;
-- they never run anything and never touch an editor API.
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
--
-- A caller that only wants the yes/no reads the first value. A caller that
-- must tell "absent" from "cannot read" -- the skip-versus-fail distinction a
-- test suite makes -- reads outcome. Anything else, such as a bad timeout, is a
-- programming error and raises.
--
-- Portability: the same Lua 5.1/5.5 common subset as `k8s.core`, because this
-- loads in LuaJIT (what Neovim embeds) and in a standalone interpreter. No
-- `//`, no `<const>`, no table.unpack, no utf8, no string.pack.


-- The implementation lives beside this file: `k8s/primitives.lua` holds the
-- questions a caller's own client shares and `k8s/client.lua` the Client
-- itself, so neither has to require this module back. What is left here is the
-- public surface a caller sees.

local primitives = require("k8s.primitives")
local client = require("k8s.client")

local k8s = {}

-- The pieces a caller's own client shares.
k8s.candidates = primitives.candidates
k8s.binary = primitives.binary
k8s.available = primitives.available
k8s.argv = primitives.argv
k8s.failure = primitives.failure
k8s.items = primitives.items

-- The client, and the constructor under the name a reader of the call sites
-- expects: k8s.K8sClient.new(opts) and k8s.new(opts) are the same function.
k8s.new = client.new
k8s.K8sClient = client.Client

return k8s
