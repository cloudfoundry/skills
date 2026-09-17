"""Walk pods/replicasets/deployments JSON to find which deployment runs a given image. Called by discover-target.sh."""
import json
import os
import sys

image = os.environ["IMAGE"]
cluster = os.environ["CLUSTER"]
data = json.load(sys.stdin)
items = data.get("items", [])

# Index ReplicaSets and Deployments by (namespace, name) so we can resolve a
# pod's ownerRef chain (pod -> ReplicaSet -> Deployment) with plain dict lookups.
replicasets = {}
deployments = set()
for obj in items:
    kind = obj.get("kind", "")
    ns = obj["metadata"]["namespace"]
    name = obj["metadata"]["name"]
    if kind == "ReplicaSet":
        replicasets[(ns, name)] = obj
    elif kind == "Deployment":
        deployments.add((ns, name))

def owner(obj, kind):
    """Name of obj's ownerReference of the given kind, or ''."""
    for ref in obj["metadata"].get("ownerReferences", []):
        if ref.get("kind") == kind:
            return ref["name"]
    return ""

def deployment_for(ns, pod):
    """Walk pod -> ReplicaSet -> Deployment; fall back to the pod name with its
    two hash suffixes stripped if the ownerRefs aren't present."""
    rs = owner(pod, "ReplicaSet")
    if rs:
        rs_obj = replicasets.get((ns, rs))
        if rs_obj:
            dep = owner(rs_obj, "Deployment")
            if dep:
                return dep
    # e.g. "forwarder-agent-6fccfcdb8d-wpm5n" -> "forwarder-agent"
    return pod.rsplit("-", 2)[0]

found = []
seen = set()
for obj in items:
    if obj.get("kind") != "Pod":
        continue
    ns = obj["metadata"]["namespace"]
    name = obj["metadata"]["name"]
    for container in obj["spec"].get("containers", []):
        # Substring match: image may be "<name>:latest" or a fully-qualified ref.
        if image not in container.get("image", ""):
            continue
        dep = deployment_for(ns, obj)
        key = (dep, container["name"], ns)
        if key in seen:
            continue
        seen.add(key)
        found.append(key)

for dep, cont, ns in found:
    print(dep, cont, ns)

if not found:
    sys.stderr.write(
        f"discover-target.sh: no running container matches image '{image}' "
        f"in cluster '{cluster}'\n"
        "discover-target.sh: (is the deployment present? "
        "try: kubectl get pods -A | grep <name>)\n"
    )
    sys.exit(1)
