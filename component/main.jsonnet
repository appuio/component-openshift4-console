local esp = import 'lib/espejote.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.openshift4_console;

local versionGroup = 'operator.openshift.io/v1';

local openshiftMinor = std.parseInt(params.openshift_version.Minor);
local openshiftFlavor = inv.parameters.facts.distribution;

local validateConfig(obj, kind='logo') =
  assert
    std.set(std.objectFields(obj)) == std.set([ 'type', 'data' ]) :
    'Expected custom %s config to have keys `type` and `data`' % [ kind ];
  obj;

local customLogos =
  local keys = std.set(std.objectFields(params.custom_logos));
  local unsupportedKeys = std.setDiff(keys, std.set([ 'light', 'dark', '*' ]));
  assert std.length(unsupportedKeys) == 0 :
         'Parameter `custom_logos` contains unsupported keys: %s' %
         [ unsupportedKeys ];
  local config = {
    default: if std.length(params.custom_logos['*']) > 0 then
      validateConfig(params.custom_logos['*']) {
        key: 'default.%s' % super.type,
      }
    else {},
    Dark: if std.length(params.custom_logos.dark) > 0 then
      validateConfig(params.custom_logos.dark) {
        key: 'dark.%s' % super.type,
      }
    else {},
    Light: if std.length(params.custom_logos.light) > 0 then
      validateConfig(params.custom_logos.light) {
        key: 'light.%s' % super.type,
      }
    else {},
  };
  if openshiftMinor > 18 && std.length(std.prune(config)) > 0 then
    {
      cm_data: {
        [if std.length(config[theme]) > 0 && config[theme].type == 'svg' then config[theme].key]:
          config[theme].data
        for theme in [ 'default', 'Light', 'Dark' ]
      },
      cm_bindata: {
        [if std.length(config[theme]) > 0 && config[theme].type != 'svg' then config[theme].key]:
          config[theme].data
        for theme in [ 'default', 'Light', 'Dark' ]
      },
      config: {
        type: 'Masthead',
        themes: [
          {
            mode: theme,
            source: {
              from: 'ConfigMap',
              configMap: {
                name: 'console-logos',
                key: (if std.length(config[theme]) > 0 then config[theme] else config.default).key,
              },
            },
          }
          for theme in [ 'Light', 'Dark' ]
        ],
      },
    }
  else
    {};

local favicon =
  if openshiftMinor > 18 && std.length(params.custom_favicon) > 0 then
    local config = validateConfig(params.custom_favicon, kind='favicon');
    config {
      key: 'favicon.%s' % super.type,
    }
  else
    {};

local legacyLogoFileName =
  local legacy_logo = std.get(params, 'custom_logo', {});
  // OpenShift doesn't allow `customLogoFile` and `logos` to be set at the
  // same time, so we never try to configure the legacy `customLogoFile` if
  // we're configuring the new `logos`.
  if std.length(std.objectFields(legacy_logo)) > 0 && std.length(customLogos) == 0 then
    assert std.length(std.objectFields(legacy_logo)) == 1 :
           'The parameter custom_logo can only contain a single logo';
    local name = std.objectFields(legacy_logo)[0];
    local nameParts = std.split(name, '.');
    assert std.length(nameParts) > 1 :
           'The key of custom_logo must provide a filename with a valid filename extension';
    std.trace(
      'Parameter `custom_logo` is deprecated for OpenShift 4.19 and newer. '
      + 'Use parameters `custom_logos` and `custom_favicon` instead.',
      name
    )
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
  local defaults = [ 'monitoring-plugin' ] + (
    if openshiftMinor > 16 then
      [ 'networking-console-plugin' ]
    else
      []
  );
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
    if legacyLogoFileName != '' then
      {
        customization+: {
          customLogoFile: {
            key: legacyLogoFileName,
            name: 'console-logo',
          },
        },
      }
    else
      {}
  ) + (
    if std.length(customLogos) > 0 then
      {
        customization+: {
          logos+: [
            customLogos.config,
          ],
        },
      }
    else
      {}
  ) + (
    if std.length(favicon) > 0 then
      {
        customization+: {
          logos+: [
            {
              type: 'Favicon',
              themes: [
                {
                  mode: mode,
                  source: {
                    from: 'ConfigMap',
                    configMap: {
                      name: 'console-favicon',
                      key: favicon.key,
                    },
                  },
                }
                for mode in [ 'Dark', 'Light' ]
              ],
            },
          ],
        },
      }
    else
      {}
  ) + (
    if openshiftMinor > 18 then {
      customization+: {
        perspectives: [
          {
            id: 'dev',
            visibility: {
              state:
                if openshiftFlavor == 'oke' then
                  'Disabled'
                else
                  'Enabled',
            },
          },
        ],

      },
    }
    else {}
  ) + (
    if openshiftMinor > 18 then
      local availableCaps = {
        '19': std.set([
          'LightspeedButton',
          'GettingStartedBanner',
        ]),
      };
      {
        local existingCaps = std.set(
          [ c.name for c in std.get(super.customization, 'capabilities', []) ]
        ),
        customization+: {
          capabilities+: [
            // add capabilities that aren't configured directly via parameter
            // `config`.
            {
              name: name,
              visibility: {
                state: params.capabilities[name],
              },
            }
            for name in std.objectFields(params.capabilities)
            if
              !std.setMember(name, existingCaps) &&
              std.setMember(name, availableCaps[params.openshift_version.Minor])
          ],
        },
      } else {}
  );

local faviconRoute =
  if legacyLogoFileName != '' && hostname != null then
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
  local mrAnnotations = {
    'syn.tools/source': 'https://github.com/appuio/component-openshift4-console.git',
  };
  local mrLabels = {
    'app.kubernetes.io/managed-by': 'espejote',
    'app.kubernetes.io/part-of': 'syn',
    'app.kubernetes.io/component': 'openshift4-console',
  };
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
      if obj.kind == 'ManagedResource' then
        obj {
          metadata+: {
            annotations+: {
              // Ensure the patch is only applied after the certificate or secret
              // exists.
              'argocd.argoproj.io/sync-wave': '10',
            } + mrAnnotations,
            labels+: mrLabels,
          },
        }
      else
        obj {
          metadata+: {
            annotations+: mrAnnotations,
            labels+: mrLabels,
          },
        }
      for obj in esp.clusterScopedObject(
        inv.parameters.espejote.namespace,
        {
          apiVersion: 'config.openshift.io/v1',
          kind: 'Ingress',
          metadata: {
            name: 'cluster',
          },
          spec: patch.spec,
        }
      )
    ]
  else
    null;

local tls = import 'tls.libsonnet';

local notifications = import 'notifications.libsonnet';

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
  [if legacyLogoFileName != '' then '01_logo']:
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
  [if std.length(customLogos) > 0 then '01_logos']:
    kube.ConfigMap('console-logos') {
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
      binaryData: customLogos.cm_bindata,
      data: customLogos.cm_data,
    },
  [if std.length(favicon) > 0 then '01_favicon']:
    kube.ConfigMap('console-favicon') {
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
      [if favicon.type == 'svg' then 'data' else 'binaryData']: {
        [favicon.key]: favicon.data,
      },
    },
  '10_console': kube._Object(versionGroup, 'Console', 'cluster') {
    spec+: consoleSpec,
  },
  [if faviconRoute != null then '10_console_favicon_route']:
    faviconRoute,
  [if consoleRoutePatch != null then '20_ingress_config_patch']:
    consoleRoutePatch,
  [if std.length(notifications.rbac) > 0 then '30_notification_rbac']:
    notifications.rbac,
  [if std.length(notifications.notifications) > 0 then '30_notifications']: notifications.notifications,
  [if std.length(notifications.upgrade_notification) > 0 then '31_upgrade_notification']: notifications.upgrade_notification,
}
