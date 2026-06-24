local esp = import 'espejote.libsonnet';
local inDelete(obj) = std.get(obj.metadata, 'deletionTimestamp', '') != '';

local configNs = 'openshift-config';
local source = esp.context().source_secret;
assert
  std.length(source) == 1
  : 'Expected source context to have exactly 1 element';
assert
  source[0].kind == 'Secret'
  : 'Expected source to be a `Secret`, is a `%s`' % source[0].kind;

local sourceSecret = source[0];

if sourceSecret != null && !inDelete(sourceSecret) then
  {
    apiVersion: sourceSecret.apiVersion,
    kind: sourceSecret.kind,
    metadata: {
      name: sourceSecret.metadata.name,
      namespace: configNs,
      annotations: sourceSecret.metadata.annotations,
      labels: sourceSecret.metadata.labels {
        'app.kubernetes.io/managed-by': 'espejote',
        'app.kubernetes.io/part-of': 'syn',
        'app.kubernetes.io/component': 'openshift4-console',
      },
    },
    type: sourceSecret.type,
    data: sourceSecret.data,
  }
else
  esp.markForDelete(
    {
      apiVersion: sourceSecret.apiVersion,
      kind: sourceSecret.kind,
      metadata: {
        name: sourceSecret.metadata.name,
        namespace: configNs,
      },
    }
  )
