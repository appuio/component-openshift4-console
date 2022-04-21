local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local rl = import 'lib/resource-locker.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.openshift4_console;

local clusterVersion =
  local verparts = std.map(
    std.parseInt,
    std.split(params.openshift_version, '.')
  );
  if verparts[0] != 4 then
    error 'This component only supports OCP4'
  else
    assert
      std.length(verparts) > 1 :
      'The parameter openshift_version must provide the OCP version as "<major>.<minor>"';
    {
      major: verparts[0],
      minor: verparts[1],
    };

local oldConfig = clusterVersion.minor < 8;

local versionGroup = 'operator.openshift.io/v1';

local logoFileName =
  if std.length(std.objectFields(params.custom_logo)) > 0 then
    assert std.length(std.objectFields(params.custom_logo)) == 1 :
           'The parameter custom_logo can only contain a single logo';
    local name = std.objectFields(params.custom_logo)[0];
    local nameParts = std.split(name, '.');
    assert std.length(nameParts) > 1 :
           'The key of custom_logo must provide a filename with a valid filename extension';
    name
  else
    '';


// Extract route config from console spec, this allows legacy
// configs to work unchanged
local consoleRoute =
  if std.objectHas(params.config, 'route') then
    params.config.route
  else
    {};

local hostname =
  if std.objectHas(params.route.console, 'hostname') then
    params.route.console.hostname
  else if std.objectHas(consoleRoute, 'hostname') then
    consoleRoute.hostname
  else
    null;

local tlsSecret =
  if std.objectHas(params.route.console, 'servingCertKeyPairSecret') then
    params.route.console.servingCertKeyPairSecret
  else if std.objectHas(consoleRoute, 'secret') then
    consoleRoute.secret
  else
    null;

local oldRouteCfg =
  if hostname != null then
    {
      hostname: hostname,
      [if tlsSecret != null then 'secret']: tlsSecret,
    }
  else
    {};

local consoleSpec =
  // Remove provided route config from console `.spec`
  {
    [k]: params.config[k]
    for k in std.objectFields(params.config)
    if k != 'route'
  } +
  (
    // Inject route config using both parameters in consoleSpec on OCP4.7 and
    // older.
    if oldConfig then
      { route: oldRouteCfg }
    else
      {}
  ) +
  (
    if logoFileName != '' then
      {
        customization+: {
          customLogoFile: {
            key: logoFileName,
            name: 'console-logo',
          },
        },
      }
    else
      {}
  );

// Create ResourceLocker patch to configure console route in
// ingress.config.openshift.io/cluster object
local consoleRoutePatch =
  local target = kube._Object('config.openshift.io/v1', 'Ingress', 'cluster');
  local needsPatch =
    hostname != null || std.objectHas(params.route.downloads, 'hostname');
  if needsPatch then
    local patch = {
      spec: {
        componentRoutes: std.filter(
          function(it) it != null,
          [
            if hostname != null then
              {
                name: 'console',
                namespace: 'openshift-console',
                hostname: hostname,
                [if tlsSecret != null then 'servingCertKeyPairSecret']:
                  tlsSecret,
              },
            if std.objectHas(params.route.downloads, 'hostname') then
              params.route.downloads {
                name: 'downloads',
                namespace: 'openshift-console',
              },
          ]
        ),
      },
    };
    [
      if obj.kind == 'ResourceLocker' then
        obj {
          metadata+: {
            annotations+: {
              // Ensure the patch is only applied after the certificate or secret
              // exists.
              'argocd.argoproj.io/sync-wave': '10',
            },
          },
        }
      else
        obj
      for obj in rl.Patch(
        target,
        patch,
        patchstrategy='application/merge-patch+json'
      )
    ]
  else
    null;

local tls = import 'tls.libsonnet';

// If we deploy cert-manager Certificates, we annotate namespace
// openshift-config with the `kyvernoAnnotation` defined in `tls.libsonnet`
// through a ResourceLocker patch. This triggers the the Kyverno policy to
// copy the cert-manager TLS secrets into namespace openshift-config.
//
// We add the ResourceLocker patch to ArgoCD sync-wave 5, so it's guaranteed
// to be applied in the cluster after the certificate has been issued and
// before the custom openshift console route config is applied.
//
// NOTE: Due to the current implementation of the resource locker component
// library this prevents other components from also providing ResourceLocker
// patches for the `openshift-config` namespace.
local openshiftConfigNsAnnotationPatch =
  local needsPatch = hostname != null && std.length(tls.certs) > 0;
  if needsPatch then
    local target = kube.Namespace('openshift-config');
    local patch = {
      metadata: {
        annotations: tls.kyvernoAnnotation,
      },
    };
    [
      if obj.kind == 'ResourceLocker' then
        obj {
          metadata+: {
            annotations+: {
              // Annotate namespace openshift-config before we configure the
              // route certificate, see patch above
              'argocd.argoproj.io/sync-wave': '5',
            },
          },
        }
      else
        obj
      for obj in
        rl.Patch(
          target,
          patch,
          patchstrategy='application/merge-patch+json'
        )
    ];

{
  '00_namespace': kube.Namespace(params.namespace) {
    metadata+: {
      annotations: std.prune(params.namespace_annotations),
      [if std.member(inv.applications, 'networkpolicy') then 'labels']+: {
        [inv.parameters.networkpolicy.labels.noDefaults]: 'true',
        [inv.parameters.networkpolicy.labels.purgeDefaults]: 'true',
      },
    },
  },
  [if std.length(tls.secrets) > 0 then '01_tls_secrets']: tls.secrets,
  [if std.length(tls.certs) > 0 then '01_certs']: tls.certs,
  [if logoFileName != '' then '01_logo']:
    kube.ConfigMap('console-logo') {
      metadata+: {
        // ConfigMap must be deployed in namespace openshift-config
        namespace: 'openshift-config',
        // ConfigMap will be copied to namespace openshift-console
        // To prevent ArgoCD from removing or complaining about the copy we add these annotations
        annotations+: {
          'argocd.argoproj.io/sync-options': 'Prune=false',
          'argocd.argoproj.io/compare-options': 'IgnoreExtraneous',
        },
      },
      data: params.custom_logo,
    },
  '10_console': kube._Object(versionGroup, 'Console', 'cluster') {
    spec+: consoleSpec,
  },
  [if !oldConfig && consoleRoutePatch != null then '20_ingress_config_patch']:
    consoleRoutePatch,
  [if openshiftConfigNsAnnotationPatch != null then '20_openshift_config_ns_annotation_patch']:
    openshiftConfigNsAnnotationPatch,
}
