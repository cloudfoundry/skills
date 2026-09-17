"""Print per-container status lines for each pod in a kubectl -o json pod list. Called by verify-status.sh."""
import json
import sys

data = json.load(sys.stdin)
for pod in data.get("items", []):
    print("pod", pod["metadata"]["name"])
    for cs in pod.get("status", {}).get("containerStatuses", []):
        print(f"  {cs['name']} ready={str(cs['ready']).lower()} "
              f"restarts={cs['restartCount']} image={cs['image']}")
