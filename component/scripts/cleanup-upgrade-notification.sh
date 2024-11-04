#!/bin/bash
set -euo pipefail

echo "OVERLAY_VERSION_MINOR: $OVERLAY_VERSION_MINOR"
CURRENT_MINOR=$(oc version -oyaml | yq '.openshiftVersion' | cut -d'.' -f2)
echo "CURRENT_MINOR: $CURRENT_MINOR"

if (( OVERLAY_VERSION_MINOR > CURRENT_MINOR )); then
    echo "Minor upgrade still pending. Nothing to clean up."
else
    echo "Deleting upgrade console notification"
    kubectl delete consolenotifications upgrade
fi
