#!/bin/bash
set -exo pipefail

OCP_MINOR=$(echo $JOB_spec_desiredVersion_version | jq -r 'split(".") | .[0:2] | join(".")')
echo $OCP_MINOR
echo "Deleting upgrade console notification"
kubectl delete consolenotifications -l appuio.io/ocp-version="$OCP_MINOR"
