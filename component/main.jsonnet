local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local po = import 'lib/patch-operator.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.openshift4_console;

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

local consolePlugins =
  // set default plugins dynamically based on OCP minor version and append
  // user-configured plugins to the default.
  local defaults =
    if std.parseInt(params.openshift_version.Minor) > 13 then
      [ 'monitoring-plugin' ]
    else
      [];
  // render final plugins list by appending any user-provided plugins that
  // aren't part of the default plugins to the list of plugins. We use
  // `std.set()` on the user-provided plugins so that users don't have to
  // worry about including the same plugin multiple times. Note that this may
  // reorder plugins between the input and the resulting manifest.
  defaults + [
    p
    for p in std.set(std.get(params.config, 'plugins', []))
    if !std.member(defaults, p)
  ];

local consoleSpec =
  // Remove provided route config from console `.spec`, and skip field
  // `plugins` since we manage it dynamically.
  {
    [k]: params.config[k]
    for k in std.objectFields(params.config)
    if !std.member([ 'route', 'plugins' ], k)
  } + {
    plugins: consolePlugins,
  } +
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

local faviconRoute =
  if logoFileName != '' && hostname != null then
    kube._Object('route.openshift.io/v1', 'Route', 'console-favicon') {
      metadata+: {
        namespace: 'openshift-console',
        labels+: {
          app: 'console',
        },
        annotations+: {
          'haproxy.router.openshift.io/rewrite-target':
            '/static/assets/openshift-favicon.png',
        },
      },
      spec: {
        host: hostname,
        path: '/favicon.ico',
        to: {
          kind: 'Service',
          name: 'console',
          weight: 100,
        },
        port: {
          targetPort: 'https',
        },
        tls: {
          termination: 'reencrypt',
          insecureEdgeTerminationPolicy: 'Redirect',
        },
        wildcardPolicy: 'None',
      },
    };

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
      if obj.kind == 'Patch' then
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
      for obj in po.Patch(
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
      if obj.kind == 'Patch' then
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
        po.Patch(
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
  [if faviconRoute != null then '10_console_favicon_route']:
    faviconRoute,
  [if consoleRoutePatch != null then '20_ingress_config_patch']:
    consoleRoutePatch,
  [if openshiftConfigNsAnnotationPatch != null then '20_openshift_config_ns_annotation_patch']:
    openshiftConfigNsAnnotationPatch,
}
