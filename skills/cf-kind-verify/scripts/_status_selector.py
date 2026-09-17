"""Build a k1=v1,k2=v2 selector string from a deployment's matchLabels. Called by verify-status.sh."""
import json
import os
import sys

try:
    data = json.load(sys.stdin)
except ValueError:
    data = {}
match_labels = data.get("spec", {}).get("selector", {}).get("matchLabels", {})
if not match_labels:
    sys.stderr.write(
        f"verify-status.sh: deployment '{os.environ['DEP']}' not found in "
        f"namespace '{os.environ['NS']}' (or has no selector)\n"
    )
    sys.exit(1)
print(",".join(f"{k}={v}" for k, v in match_labels.items()))
