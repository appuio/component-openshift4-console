#!/bin/bash
set -euo pipefail

echo "OVERLAY_VERSION_MINOR: $OVERLAY_VERSION_MINOR"
# NOTE(sg): We use 4.0.0 as fallback current version since we only care that
# the current minor is less than the overlay minor for no-op upgrades.
export CURRENT_VERSION=${JOB_spec_desiredVersion_version:-"4.0.0"}
CURRENT_MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f2)
echo "CURRENT_MINOR: $CURRENT_MINOR (0 is expected for no-op jobs)"

if (( OVERLAY_VERSION_MINOR > CURRENT_MINOR )); then
    echo "Minor upgrade still pending. Nothing to clean up."
else
    echo "Deleting upgrade console notification"
    kubectl delete consolenotifications upgrade
fi
