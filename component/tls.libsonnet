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

local certs = std.filter(
  function(it) it != null,
  [
    local cert = params.cert_manager_certs[c];
    if cert != null then
      cm.cert(c) {
        metadata+: {
          // Certificates must be deployed in namespace openshift-config
          namespace: 'openshift-config',
        },
        spec+: {
          secretName: '%s' % c,
        },
      } + com.makeMergeable(cert)
    for c in std.objectFields(params.cert_manager_certs)
  ]
);

{
  certs: certs,
  secrets: secrets,
}
