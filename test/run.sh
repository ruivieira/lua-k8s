#!/bin/sh
# Run test/smoke.lua under every interpreter on PATH that the rock claims to
# support, with a stub `oc` first on PATH so nothing here needs a cluster.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$here")
work=$(mktemp -d "${TMPDIR:-/tmp}/lua-k8s.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

bin="$work/bin"
mkdir -p "$bin"
# A sandbox PATH: the shell helpers core.run needs, plus only the cluster CLI
# this test provides, so a real oc/kubectl the host happens to have cannot
# decide a result.
for tool in sh printf command test sleep cat rm mkdir; do
    path=$(command -v "$tool" 2>/dev/null || true)
    [ -n "$path" ] && ln -sf "$path" "$bin/$tool"
done

cat >"$bin/oc" <<'STUB'
#!/bin/sh
case "$*" in
  *"get deployment present"*)
    case "$*" in
      *"-o name"*) echo "deployment.apps/present" ;;
      *) printf '{"kind": "Deployment", "metadata": {"name": "present"}}\n' ;;
    esac
    exit 0
    ;;
  *"get deployment absent"*) exit 0 ;;
  *"get deployment forbidden"*)
    echo 'Error from server (Forbidden): deployments.apps "forbidden" is forbidden' >&2
    exit 1
    ;;
  *) echo "unexpected call: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$bin/oc"

found=0
for interpreter in lua lua5.5 lua5.4 lua5.3 lua5.2 lua5.1 luajit; do
    command -v "$interpreter" >/dev/null 2>&1 || continue
    found=$((found + 1))
    printf '%s (%s): ' "$interpreter" "$("$interpreter" -v 2>&1 | head -1)"
    PATH="$bin:$PATH" \
        LUA_PATH="$root/lua/?.lua;$root/lua/?/init.lua;;" \
        "$interpreter" "$here/smoke.lua"
done

if [ "$found" -eq 0 ]; then
    echo "no Lua interpreter found (looked for lua, lua5.x, luajit)" >&2
    exit 1
fi
