#!/bin/bash
set -euo pipefail

echo "OVERLAY_DATE: $OVERLAY_DATE"
echo "OVERLAY_CHANNEL: $OVERLAY_CHANNEL"
echo "OVERLAY_VERSION: $OVERLAY_VERSION"
echo "OVERLAY_VERSION_MINOR: $OVERLAY_VERSION_MINOR"

export NEXT_MAINTENANCE=$(kubectl -n appuio-openshift-upgrade-controller get upgradeconfigs -oyaml | yq '[.items[].status.nextPossibleSchedules[].time | from_yaml | select(. > env(OVERLAY_DATE))][0] | tz("Europe/Zurich") | format_datetime("02.01.2006 15:04")')
test -n "${NEXT_MAINTENANCE:-}" || (echo "No valid maintenance window found" && exit 1)
echo "NEXT_MAINTENANCE: $NEXT_MAINTENANCE"

yq '(.. | select(tag == "!!str")) |= envsubst' template/upgrade.yaml > notification.yaml
cat notification.yaml

CURRENT_MINOR=$(oc version -oyaml | yq '.openshiftVersion' | cut -d'.' -f2)
if (( OVERLAY_VERSION_MINOR > CURRENT_MINOR )); then
    echo "Creating console notification:"
    kubectl apply -f notification.yaml
else
    echo "Current OpenShift minor version matches channel overlay version."
fi
