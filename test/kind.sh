#!/bin/sh
# kind.sh: run the real-cluster suite (test/kind.lua) against a kind cluster.
#
# test/run.sh answers "does the module work" with no cluster at all, using a
# stub `oc`. This answers the other question -- "does it work against a real API
# server" -- where an absent object is absent for real, `-n` has consequences,
# and the wait loop polls a cluster that is actually changing underneath it.
#
# The script owns every write: it applies the fixtures, creates a Deployment a
# few seconds into the run so the wait loop has something to wait for, and
# removes the namespace afterwards. The Lua suite only reads.
#
# It exports the cluster's kubeconfig to a temporary file and points everything
# at it, so nothing here reads or writes ~/.kube/config and a cluster you use for
# real is never the one being tested.
#
#   sh test/kind.sh                     reuse an existing kind cluster `lua-k8s-test`
#   sh test/kind.sh --create            create it first (needs kind + a runtime)
#   sh test/kind.sh --create --delete   ... and remove it when the run ends
#   sh test/kind.sh --keep              leave the fixture namespace for inspection
#
# Environment:
#   KIND_CLUSTER       cluster name (default: lua-k8s-test; a non-default name
#                      is never created or deleted unless --create/--delete say so)
#   K8S_TEST_NAMESPACE fixture namespace (default: lua-k8s-test)
#   K8S_TEST_LATE_DELAY  seconds before the `late` Deployment is created (default: 5)
#   K8S_TEST_BINARIES  CLIs to run the suite through (default: "oc kubectl")
#   KIND_EXPERIMENTAL_PROVIDER  pass through to kind (e.g. podman)
#
# Nothing in the fixtures has to *run*: every assertion is about an object
# existing or not, so the images below are never waited on. That is what keeps
# the suite meaningful on a cluster with no image registry access.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$here")

cluster=${KIND_CLUSTER:-lua-k8s-test}
namespace=${K8S_TEST_NAMESPACE:-lua-k8s-test}
late_delay=${K8S_TEST_LATE_DELAY:-5}
binaries=${K8S_TEST_BINARIES:-"oc kubectl"}
create=0
delete=0
keep=0

usage() {
    cat <<'USAGE'
usage: test/kind.sh [--create] [--delete] [--keep]

  --create   create the kind cluster when it does not exist
  --delete   delete the kind cluster when the run ends
  --keep     leave the fixture namespace behind (it is deleted by default)

The cluster is KIND_CLUSTER (default: lua-k8s-test). Without --create the
cluster must already exist; the script refuses to run against nothing rather
than reporting green off an unreachable server.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --create) create=1 ;;
        --delete) delete=1 ;;
        --keep) keep=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; echo "kind: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

die() {
    echo "kind: $*" >&2
    exit 1
}

command -v kind >/dev/null 2>&1 || die "kind is not on PATH"
command -v kubectl >/dev/null 2>&1 || die "kubectl is not on PATH"

# kind reports a missing container runtime itself, with the provider it tried;
# this only says where to look when that message is the one that shows up.
have_cluster=0
if kind get clusters 2>/dev/null | grep -qx "$cluster"; then
    have_cluster=1
fi

if [ "$have_cluster" -eq 0 ]; then
    [ "$create" -eq 1 ] || die "no kind cluster named \"$cluster\" (kind get clusters); rerun with --create, or set KIND_CLUSTER to the cluster you mean"
    echo "kind: creating cluster \"$cluster\""
    kind create cluster --name "$cluster" --wait 120s \
        || die "kind create cluster failed (is a container runtime running? see KIND_EXPERIMENTAL_PROVIDER)"
    have_cluster=1
elif [ "$create" -eq 1 ]; then
    echo "kind: cluster \"$cluster\" already exists, reusing it"
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/lua-k8s-kind.XXXXXX")
kubeconfig_file="$work/kubeconfig"
late_pid=

# Everything the run made, removed in the order it was made: the background
# create may still be sleeping, the namespace may still be terminating, and a
# --delete is meaningless until both are done. `|| true` throughout, because a
# failed cleanup must not replace the exit status of the tests with its own.
cleanup() {
    status=$1
    trap - EXIT INT TERM
    if [ -n "$late_pid" ]; then
        kill "$late_pid" 2>/dev/null || true
        wait "$late_pid" 2>/dev/null || true
    fi
    if [ "$keep" -eq 0 ] && [ -f "$kubeconfig_file" ]; then
        kubectl --kubeconfig "$kubeconfig_file" delete namespace "$namespace" \
            --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
    fi
    if [ "$delete" -eq 1 ]; then
        echo "kind: deleting cluster \"$cluster\""
        kind delete cluster --name "$cluster" >/dev/null 2>&1 || true
    fi
    rm -rf "$work"
    exit "$status"
}
trap 'cleanup $?' EXIT INT TERM

echo "kind: exporting kubeconfig for \"$cluster\""
kind export kubeconfig --name "$cluster" --kubeconfig "$kubeconfig_file" >/dev/null \
    || die "kind export kubeconfig failed"

context="kind-$cluster"
export KUBECONFIG="$kubeconfig_file"

kubectl --context "$context" get nodes --request-timeout=20s >/dev/null 2>&1 \
    || die "the API server at context \"$context\" did not answer"

echo "kind: applying fixtures in \"$namespace\""
kubectl apply -f - <<YAML >/dev/null || die "applying the fixtures failed"
apiVersion: v1
kind: Namespace
metadata:
  name: $namespace
  labels:
    app.kubernetes.io/managed-by: lua-k8s-test
    app.kubernetes.io/part-of: lua-k8s
---
# replicas: 0 -- nothing in the suite waits for a workload, so this object
# exists without ever needing a schedulable pod or a pullable image.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: present
  namespace: $namespace
  labels:
    app: lua-k8s-present
spec:
  replicas: 0
  selector:
    matchLabels:
      app: lua-k8s-present
  template:
    metadata:
      labels:
        app: lua-k8s-present
    spec:
      containers:
        - name: app
          image: registry.k8s.io/pause:3.9
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: present
  namespace: $namespace
  labels:
    app: lua-k8s-present
spec:
  podSelector:
    matchLabels:
      app: lua-k8s-present
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector: {}
      ports:
        - protocol: TCP
          port: 8080
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: present
  namespace: $namespace
  labels:
    app: lua-k8s-present
data:
  key: value
---
apiVersion: v1
kind: Service
metadata:
  name: present
  namespace: $namespace
  labels:
    app: lua-k8s-present
spec:
  selector:
    app: lua-k8s-present
  ports:
    - port: 80
      targetPort: 8080
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: present
  namespace: $namespace
  labels:
    app: lua-k8s-present
---
apiVersion: v1
kind: Pod
metadata:
  name: present
  namespace: $namespace
  labels:
    app: lua-k8s-present-pod
spec:
  restartPolicy: Never
  containers:
    - name: app
      image: registry.k8s.io/pause:3.9
YAML

# The wait loop needs an object that does not exist yet. A previous --keep run
# may have left one behind, and finding it immediately would make the assertion
# pass without polling at all.
kubectl delete deployment late --namespace "$namespace" --ignore-not-found >/dev/null 2>&1 || true
(
    sleep "$late_delay"
    kubectl create deployment late --namespace "$namespace" \
        --image=registry.k8s.io/pause:3.9 >/dev/null 2>&1 || true
) &
late_pid=$!
echo "kind: \"late\" will be created in ${late_delay}s"

failures=0
ran=0
for interpreter in lua lua5.5 lua5.4 lua5.3 lua5.2 lua5.1 luajit; do
    command -v "$interpreter" >/dev/null 2>&1 || continue
    for binary in $binaries; do
        command -v "$binary" >/dev/null 2>&1 || continue
        ran=$((ran + 1))
        # No prefix of our own: the suite's last line already names the
        # interpreter, the CLI and the number of checks, and on failure it names
        # the count that failed. A prefix here would only be left dangling when
        # a run dies before printing anything.
        if LUA_PATH="$root/lua/?.lua;$root/lua/?/init.lua;;" \
            K8S_TEST_BINARY="$binary" \
            K8S_TEST_NAMESPACE="$namespace" \
            K8S_TEST_KUBECONFIG="$kubeconfig_file" \
            K8S_TEST_CONTEXT="$context" \
            "$interpreter" "$here/kind.lua"; then
            :
        else
            failures=$((failures + 1))
        fi
    done
done

[ "$ran" -gt 0 ] || die "no Lua interpreter (looked for lua, lua5.x, luajit) or no cluster CLI ($binaries)"

# The background create outlives the suite that waited for it; join it here so a
# failure inside it is not reported after the summary.
if [ -n "$late_pid" ]; then
    wait "$late_pid" 2>/dev/null || true
    late_pid=
fi

if [ "$failures" -gt 0 ]; then
    echo "kind: $failures of $ran runs failed" >&2
    exit 1
fi

echo "kind ok ($ran runs)"
