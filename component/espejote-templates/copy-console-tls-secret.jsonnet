local esp = import 'espejote.libsonnet';
local triggerData = esp.triggerData();
local inDelete(obj) = std.get(obj.metadata, 'deletionTimestamp', '') != '';

local configNs = 'openshift-config';

if esp.triggerName() == 'copy-tls-secret' && triggerData.resource != null then
  local res = triggerData.resource;
  if !inDelete(res) then
    res {
      metadata+: {
        namespace: configNs,
        labels+: {
          'app.kubernetes.io/managed-by': 'espejote',
          'app.kubernetes.io/part-of': 'syn',
          'app.kubernetes.io/component': 'openshift4-console',
        },
      },
    }
  else
    esp.markForDelete(
      {
        apiVersion: res.apiVersion,
        kind: res.kind,
        metadata: {
          name: res.metadata.name,
          namespace: configNs,
        },
      }
    )
