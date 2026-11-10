# lua-k8s

A Kubernetes and OpenShift client for Lua, backed by the cluster CLI already
configured in your environment (`oc`, else `kubectl`). It answers one kind of
question — *does this object exist, and wait for it* — and keeps the answer
honest: **missing** and **cannot read** are different outcomes.

Pure Lua, no C modules, no runtime dependencies. It stays inside the Lua
5.1/LuaJIT common subset, which is what Neovim embeds, and also loads in PUC
Lua 5.1 through 5.5.

```lua
local k8s = require("k8s")

local client, err = k8s.new({ namespace = "default" })
if not client then error(err) end

client.namespace.exists("default")                 -- true
client.deployment.exists("my-app", 120)           -- wait up to 120s
client.network_policy.exists("allow-ports", { namespace = "default", timeout = 180 })
local body = client.deployment.get("my-app")      -- `-o json` string
local objects = k8s.items(vim.json.decode(body))
```

Every accessor returns `(value, outcome, detail)`:

| `outcome` | `value` | meaning |
| --- | --- | --- |
| `"found"` | `true` for `exists`, the JSON body for `get`/`list` | the answer |
| `"missing"` | `false`, `""` | absent (or still absent at the deadline) |
| `"error"` | `false`, `""` | the CLI itself failed: not logged in, RBAC, no server |

A caller that only needs yes/no reads the first value; a caller that must not
skip on an RBAC failure reads `outcome`.

## API

Module:

- `k8s.new(opts) -> client, err` — `binary` (`oc`/`kubectl`/path/`"auto"`),
  `namespace`, `timeout`, `interval`, `context`, `kubeconfig`. The constructor
  refuses a binary that is not executable instead of handing out a client that
  fails on every call.
- `k8s.binary(opts, is_executable)`, `k8s.available(opts, is_executable)`
- `k8s.argv(opts, args, is_executable)` — the argv `vim.system` can run.
- `k8s.failure(argv, code, stderr)` — a failed call as one readable line.
- `k8s.items(decoded)` — the objects in a decoded `-o json` answer.
- `k8s.candidates` — `{ "oc", "kubectl" }`, in preference order.
- `k8s.K8sClient` — the client metatable; `K8sClient.new` is `k8s.new`.

Client (each kind has a singular and a plural accessor):

- `namespace`/`namespaces` (cluster-scoped)
- `network_policy`/`network_policies`
- `deployment`/`deployments`
- `pod`/`pods`
- `service`/`services`
- `config_map`/`config_maps`
- `service_account`/`service_accounts`
- `crd`/`crds` (cluster-scoped)
- `client:resource(kind, { namespaced = false })` — any other kind
- `client:run(args)` — escape hatch for verbs the accessors do not model

`secret` is deliberately not registered: `get` would return base64 credential
data. Build it explicitly with `client:resource("secret")` if you own that
decision.

Accessor methods: `exists`/`exist(names, opts)`, `get(name, opts)`,
`list(opts)` where `opts` may be a number of seconds or a table carrying
`namespace`, `timeout`, `interval`, `all_namespaces`, `selector`,
`field_selector`.

## Install

From LuaRocks (once published):

```sh
luarocks install lua-k8s
```

From a checkout, against a Lua 5.1/LuaJIT tree:

```sh
luarocks --lua-version=5.1 make lua-k8s-0.1.0-1.rockspec
```

### Neovim

Neovim embeds LuaJIT, which reports itself as Lua 5.1, so the rock installs
into the `5.1` tree. [rocks.nvim](https://github.com/nvim-neorocks/rocks.nvim)
is the least friction: declare `lua-k8s` in `rocks.toml` and it manages a
LuaJIT-compatible tree for you.

With a plain `luarocks` tree, make it visible to a running Neovim either by
exporting the path before starting it:

```sh
eval "$(luarocks --lua-version=5.1 path)"
nvim
```

or from `init.lua`:

```lua
local tree = vim.fn.expand("~/.local/share/nvim/rocks")
for _, entry in ipairs({ "/share/lua/5.1/?.lua", "/share/lua/5.1/?/init.lua" }) do
  package.path = tree .. entry .. ";" .. package.path
end
```

(The tree is not a runtimepath directory: LuaRocks writes `share/lua/5.1/`,
while Neovim's `runtimepath` expects a `lua/` directory.)

## Layout

```
lua/k8s.lua               the public module (module `k8s`): re-exports the
                          primitives and the constructor
lua/k8s/primitives.lua    binary/available/argv/failure/items (module `k8s.primitives`)
lua/k8s/client.lua        the Client implementation (module `k8s.client`)
lua/k8s/core.lua          the process/quoting helpers it needs (module `k8s.core`)
test/run.sh               the no-cluster suite: stub `oc`, every interpreter
test/kind.lua             the real-cluster suite (read-only)
test/kind.sh              its fixtures, on a kind cluster
lua-k8s-0.1.0-1.rockspec
```

`lua/` is written for this rock: it does not claim the top-level module name
`core`, so it can be installed alongside other rocks without a namespace
collision. The internal modules are `k8s.core` (process and path helpers) and
`k8s.primitives` (the pure helpers), with `k8s.lua` as the public surface and
`k8s/client.lua` holding the client itself.

Two implementation notes a reader of the source may want:

1. Every internal require is namespaced (`k8s.*`) rather than top-level, so
   nothing here shadows a module another rock might install.
2. `k8s/core.lua` reads with `file:read("*a")`; the bare `"a"` form is a Lua
   5.2+ spelling that PUC Lua 5.1 rejects (the form a 5.1/LuaJIT rock must
   support). `"*a"` is accepted by 5.1 through 5.5 and LuaJIT.

## Test

The unit suite needs no cluster: it puts a stub `oc` on a sandbox `PATH` and
checks that the module reports found, missing and forbidden as three different
answers, under every interpreter it finds.

```sh
./test/run.sh
```

### Against a cluster

`test/kind.sh` runs the same assertions against a kind cluster, where absence is
real, `-n` has consequences and the wait loop polls a cluster that is changing.
It applies its own fixtures in a namespace of its own, exports the cluster's
kubeconfig to a temp file (so `~/.kube/config` is untouched), creates a
Deployment a few seconds into the run so the wait loop has something to wait
for, and deletes the namespace afterwards. The Lua suite only reads.

```sh
sh test/kind.sh                     # an existing kind cluster named lua-k8s-test
sh test/kind.sh --create            # create it first
sh test/kind.sh --create --delete   # ... and remove it when the run ends
sh test/kind.sh --keep              # leave the fixtures for inspection
```

The suite runs once per interpreter it finds, through `oc` and `kubectl` when
both are installed (`K8S_TEST_BINARIES`). Nothing in the fixtures has to run:
every assertion is about an object existing or not, so a cluster with no image
registry access is fine.

## License

Apache-2.0. See [LICENSE](LICENSE).
