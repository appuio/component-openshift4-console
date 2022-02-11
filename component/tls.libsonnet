local cm = import 'lib/cert-manager.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local kyverno = import 'lib/kyverno.libsonnet';

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

local kyvernoAnnotation = {
  'syn.tools/openshift4-console': 'secret-target-namespace',
};

local makeCert(c, cert) =
  assert
    std.member(inv.applications, 'kyverno') :
    'You need to add component `kyverno` to the cluster to be able to deploy cert-manager Certificate resources for the the openshift web console.';
  [
    cm.cert(c) {
      metadata+: {
        // Certificate must be deployed in the same namespace as the web
        // console, otherwise OpenShift won't admit the HTTP01 solver route.
        // We copy the resulting secret to namespace 'openshift-config' with
        // Kyverno, see below.
        namespace: params.namespace,
      },
      spec+: {
        secretName: '%s' % c,
      },
    } + com.makeMergeable(cert),
    kyverno.ClusterPolicy('openshift4-console-sync-' + c) {
      spec: {
        rules: [
          {
            name: 'Sync "%s" certificate secret to openshift-config' % c,
            match: {
              resources: {
                kinds: [ 'Namespace' ],
                // We copy the created TLS secret into all namespaces which
                // have the annotation specified in `kyvernoAnnotation`.
                annotations: kyvernoAnnotation,
              },
            },
            generate: {
              kind: 'Secret',
              name: c,
              namespace: '{{request.object.metadata.name}}',
              synchronize: true,
              clone: {
                namespace: params.namespace,
                name: c,
              },
            },
          },
        ],
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
  kyvernoAnnotation: kyvernoAnnotation,
}
