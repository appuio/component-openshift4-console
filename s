[1mdiff --git a/component/notifications.libsonnet b/component/notifications.libsonnet[m
[1mindex 70b06a4..8644685 100644[m
[1m--- a/component/notifications.libsonnet[m
[1m+++ b/component/notifications.libsonnet[m
[36m@@ -105,13 +105,17 @@[m [mlocal createUpgradeNotification(overlay) = [[m
                   value: overlay.date,[m
                 },[m
                 {[m
[31m-                  name: 'CHANNEL',[m
[32m+[m[32m                  name: 'OVERLAY_CHANNEL',[m
                   value: overlay.channel,[m
                 },[m
                 {[m
[31m-                  name: 'OCP_VERSION',[m
[32m+[m[32m                  name: 'OVERLAY_VERSION',[m
                   value: overlay.version,[m
                 },[m
[32m+[m[32m                {[m
[32m+[m[32m                  name: 'OVERLAY_VERSION_MINOR',[m
[32m+[m[32m                  value: std.split(overlay.version, '.')[1],[m
[32m+[m[32m                },[m
               ],[m
               volumeMounts_+: {[m
                 'upgrade-notification-template': {[m
[1mdiff --git a/component/scripts/create-console-notification.sh b/component/scripts/create-console-notification.sh[m
[1mindex 0e86530..4aa5ea0 100644[m
[1m--- a/component/scripts/create-console-notification.sh[m
[1m+++ b/component/scripts/create-console-notification.sh[m
[36m@@ -2,11 +2,18 @@[m
 set -euo pipefail[m
 [m
 echo "OVERLAY_DATE: $OVERLAY_DATE"[m
[31m-echo "CHANNEL: $CHANNEL"[m
[31m-echo "OCP_VERSION: $OCP_VERSION"[m
[32m+[m[32mecho "OVERLAY_CHANNEL: $OVERLAY_CHANNEL"[m
[32m+[m[32mecho "OVERLAY_VERSION: $OVERLAY_VERSION"[m
[32m+[m[32mecho "OVERLAY_VERSION_MINOR: $OVERLAY_VERSION_MINOR"[m
[32m+[m
 export NEXT_MAINTENANCE=$(kubectl -n appuio-openshift-upgrade-controller get upgradeconfigs -oyaml | yq '[.items[].status.nextPossibleSchedules[].time | from_yaml | select(. > env(OVERLAY_DATE))][0] | tz("Europe/Zurich") | format_datetime("02.01.2006 15:04")')[m
 test -n "${NEXT_MAINTENANCE:-}" || (echo "No valid maintenance window found" && exit 1)[m
 echo "NEXT_MAINTENANCE: $NEXT_MAINTENANCE"[m
[32m+[m
 yq '(.. | select(tag == "!!str")) |= envsubst' template/upgrade.yaml > notification.yaml[m
 cat notification.yaml[m
[31m-kubectl apply -f notification.yaml[m
[32m+[m[32mCURRENT_MINOR=$(oc version -oyaml | yq '.openshiftVersion' | cut -d'.' -f2)[m
[32m+[m[32mif (( OVERLAY_VERSION_MINOR > CURRENT_MINOR )); then[m
[32m+[m[32m    echo hello[m
[32m+[m[32m    #kubectl apply -f notification.yaml[m
[32m+[m[32mfi[m
