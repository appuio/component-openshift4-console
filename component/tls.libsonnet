local cm = import 'lib/cert-manager.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

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
    kube.ConfigMap('openshift4-console-sync-' + c) {
      metadata+: {
        namespace: params.namespace,
      },
      data: {
        'reconcile-console-secret.sh': (importstr 'scripts/reconcile-console-secret.sh'),
      },
    },
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
    kube.Deployment('openshift4-console-sync-' + c) {
      metadata+: {
        namespace: params.namespace,
      },
      spec+: {
        strategy: {
          type: 'Recreate',
        },
        replicas: 1,
        selector: {
          matchLabels: {
            app: 'openshift4-console-sync-' + c,
          },
        },
        template+: {
          metadata: {
            labels: {
              app: 'openshift4-console-sync-' + c,
            },
          },
          spec+: {
            serviceAccountName: 'openshift4-console-sync-' + c,
            containers: [
              {
                name: 'sync',
                image: '%(registry)s/%(repository)s:%(tag)s' % params.images.oc,
                workingDir: '/export',
                env: [
                  {
                    name: 'SECRET_NAME',
                    value: c,
                  },
                  {
                    name: 'HOME',
                    value: '/export',
                  },
                ],
                command: [
                  '/scripts/reconcile-console-secret.sh',
                ],
                volumeMounts: [
                  {
                    name: 'export',
                    mountPath: '/export',
                  },
                  {
                    name: 'scripts',
                    mountPath: '/scripts',
                  },
                ],
              },
            ],
            volumes: [
              {
                name: 'scripts',
                configMap: {
                  name: 'openshift4-console-sync-' + c,
                  defaultMode: 365,  // 365 = 0555
                },
              },
              {
                name: 'export',
                emptyDir: {},
              },
            ],
          },
        },
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
