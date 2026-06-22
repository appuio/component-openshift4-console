local esp = import 'espejote.libsonnet';
local resource = esp.triggerData().resource;
local inDelete(obj) = std.get(obj.metadata, 'deletionTimestamp', '') != '';

if resource != null then
  if !inDelete(resource) then
    resource {
      metadata+: {
        namespace: 'openshift-config',
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
        apiVersion: resource.apiVersion,
        kind: resource.kind,
        metadata: {
          name: resource.metadata.name,
          namespace: 'openshift-config',
        },
      }
    )
