#!/bin/bash
set -euo pipefail

test -n "${SECRET_NAME:-}" || (echo "SECRET_NAME is required" && exit 1)

target_namespace="openshift-config"

# Wait for the secret to be created before trying to get it.
kubectl -n openshift-console wait secret "${SECRET_NAME}" --for=create --timeout=30m

# When using -w flag kubectl returns the secret once on startup and then again when it changes.
kubectl -n openshift-console get secret "${SECRET_NAME}" -ojson -w | jq -c --unbuffered | while read -r secret ; do
   echo "Syncing secret: $(printf "%s" "$secret" | jq -r '.metadata.name')"

   kubectl -n "$target_namespace" apply --server-side -f <(printf "%s" "$secret" | jq '{"apiVersion": .apiVersion, "kind": .kind, "metadata": {"name": .metadata.name}, "type": .type, "data": .data}')
done
