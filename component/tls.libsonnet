local kube = import 'kube-ssa-compat.libsonnet';
local cm = import 'lib/cert-manager.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local esp = import 'lib/espejote.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.openshift4_console;

local isTlsSecret(secret) =
  local secretKeys = std.set(std.objectFields(secret.stringData));
  local keyDiff = std.setDiff(secretKeys, std.set([
    'ca.crt',
    'tls.crt',
    'tls.key',
  ]));
  secret.type == 'kubernetes.io/tls' && std.length(keyDiff) == 0;

local secrets = std.filter(
  function(it) it != null,
  [
    local scontent = params.secrets[s];
    local secret = kube.Secret(s) {
      type: 'kubernetes.io/tls',
      metadata+: {
        // Secrets must be deployed in namespace openshift-config
        namespace: 'openshift-config',
      },
    } + com.makeMergeable(scontent);
    if scontent != null then
      if isTlsSecret(secret) then
        secret
      else
        error "Invalid secret definition for key '%s'. This component expects secret definitions which are valid for kubernetes.io/tls secrets." % s
    for s in std.objectFields(params.secrets)
  ]
);

local makeCert(c, cert) =
  local sa = kube.ServiceAccount('openshift4-console-sync-' + c) {
    metadata+: {
      namespace: params.namespace,
    },
  };
  local sourceNsRole = kube.Role('openshift4-console-sync-' + c) {
    metadata+: {
      namespace: params.namespace,
    },
    rules: [
      {
        apiGroups: [ '' ],
        resources: [ 'secrets' ],
        verbs: [ 'get', 'list', 'watch' ],
      },
    ],
  };
  local targetNsRole = kube.Role('openshift4-console-sync-' + c) {
    metadata+: {
      namespace: 'openshift-config',
    },
    rules: [
      {
        apiGroups: [ '' ],
        resources: [ 'secrets' ],
        verbs: [ 'get', 'create', 'update', 'patch' ],
      },
    ],
  };

  [
    cm.cert(c) {
      metadata+: {
        // Certificate must be deployed in the same namespace as the web
        // console, otherwise OpenShift won't admit the HTTP01 solver route.
        // We copy the resulting secret to namespace 'openshift-config', see below.
        namespace: params.namespace,
      },
      spec+: {
        secretName: '%s' % c,
      },
    } + com.makeMergeable(cert),
    sa,
    sourceNsRole,
    targetNsRole,
    kube.RoleBinding('openshift4-console-sync-' + c) {
      metadata+: {
        namespace: sourceNsRole.metadata.namespace,
      },
      subjects_: [ sa ],
      roleRef_: sourceNsRole,
    },
    kube.RoleBinding('openshift4-console-sync-' + c) {
      metadata+: {
        namespace: targetNsRole.metadata.namespace,
      },
      subjects_: [ sa ],
      roleRef_: targetNsRole,
    },
    esp.managedResource('copy-tls-secret-' + c, 'openshift4-console') {
      metadata+: {
        annotations+: {
          'syn.tools/description': |||
            Watches for the certificate secret created by cert-manager in the web console namespace and copies it to the openshift-config namespace, where the web console picks it up from. 
          |||,
          'syn.tools/managed-by': 'espejote',
        },
      },
      spec: {
        triggers: [
          {
            name: 'copy-tls-secret',
            watchResource: {
              apiVersion: 'v1',
              kind: 'Secret',
              name: c,
            },
          },
        ],
        serviceAccountRef: {
          name: sa.metadata.name,
        },
        template: |||
          local esp = import 'espejote.libsonnet';
          local resource = esp.triggerData().resource;
          local inDelete(obj) = std.get(obj.metadata, 'deletionTimestamp', '') != '';

          if !inDelete(resource) then
            resource {
              metadata+: {
                namespace: 'openshift-config',
                labels+: {
                  'espejote.io/created-by': 'copy-tls-secret-%s',
                  'app.kubernetes.io/managed-by': 'espejote',
                  'app.kubernetes.io/part-of': 'syn',
                  'app.kubernetes.io/component': 'openshift4-console',
                }
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
            )
        ||| % c,
      },
    },
  ];

local certs =
  std.foldl(
    function(arr, e) arr + e,
    std.filter(
      function(it) it != null,
      [
        local cert = params.cert_manager_certs[c];
        if cert != null then
          makeCert(c, cert)
        for c in std.objectFields(params.cert_manager_certs)
      ],
    ),
    []
  );

{
  certs: certs,
  secrets: secrets,
}
