local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.openshift4_console;

local namespace = {
  metadata+: {
    namespace: params.namespace,
  },
};

local makeConsoleNotification(name, args) =
  kube._Object('console.openshift.io/v1', 'ConsoleNotification', name) {
    spec: {
      text: args.text,
      location: std.get(args, 'location', 'BannerTop'),
      color: std.get(args, 'color', '#fff'),
      backgroundColor: std.get(args, 'backgroundColor', '#2596be'),
      link: std.get(args, 'link'),
    },
  };

local consoleNotifications = [
  makeConsoleNotification(name, params.notifications[name])
  for name in std.objectFields(params.notifications)
  if params.notifications[name] != null
];

local nextChannelOverlay() =
  local overlays = inv.parameters.openshift_upgrade_controller.cluster_version.overlays;
  local channelOverlays = [
    [ name, overlays[name].spec.channel ]
    for name in std.objectFields(overlays)
    if std.objectHas(overlays[name].spec, 'channel')
  ];
  local futureChannelOverlays = [
    overlay
    for
    overlay in channelOverlays
    if std.split(overlay[1], '.')[1] > params.openshift_version.Minor
  ];
  if std.length(futureChannelOverlays) > 0 then {
    date: futureChannelOverlays[0][0],
    channel: futureChannelOverlays[0][1],
    version: std.split(futureChannelOverlays[0][1], '-')[1],
  } else {};

local upgradeControllerNS = {
  metadata+: {
    namespace: inv.parameters.openshift_upgrade_controller.namespace,
  },
};

local notificationRBAC =
  local argocd_sa = kube.ServiceAccount('notification-manager') + namespace;
  local upgrade_sa = argocd_sa + upgradeControllerNS;
  local cluster_role = kube.ClusterRole('appuio:upgrade-notification-editor') {
    rules: [
      {
        apiGroups: [ 'console.openshift.io' ],
        resources: [ 'consolenotifications' ],
        verbs: [ '*' ],
      },
      {
        apiGroups: [ 'managedupgrade.appuio.io' ],
        resources: [ 'upgradeconfigs' ],
        verbs: [ 'get', 'list' ],
      },
      // needed so that `oc version` can get the OCP server version
      {
        apiGroups: [ 'config.openshift.io' ],
        resources: [ 'clusterversions' ],
        verbs: [ 'get', 'list' ],
      },
    ],
  };
  local cluster_role_binding =
    kube.ClusterRoleBinding('appuio:upgrade-notification-manager') {
      subjects_: [ argocd_sa, upgrade_sa ],
      roleRef_: cluster_role,
    };
  {
    argocd_sa: argocd_sa,
    upgrade_sa: upgrade_sa,
    cluster_role: cluster_role,
    cluster_role_binding: cluster_role_binding,
  };

local createUpgradeNotification(overlay) =
  [
    kube.ConfigMap('upgrade-notification-template') + namespace {
      data: {
        'upgrade.yaml': std.manifestYamlDoc(
          makeConsoleNotification('upgrade', params.upgrade_notification.notification)
        ),
      },
    },

    kube.ConfigMap('console-notification-script') {
      metadata+: {
        namespace: params.namespace,
      },
      data: {
        'create-console-notification.sh': (importstr 'scripts/create-console-notification.sh'),
      },
    },

    kube.Job('create-upgrade-notification') + namespace {
      metadata+: {
        annotations+: {
          'argocd.argoproj.io/hook': 'PostSync',
        },
      },
      spec+: {
        template+: {
          spec+: {
            containers_+: {
              notification: kube.Container('notification') {
                image: '%(registry)s/%(repository)s:%(tag)s' % params.images.oc,
                imagePullPolicy: 'Always',  // needed for now to get tzdata, can be removed later
                name: 'create-console-notification',
                workingDir: '/export',
                command: [ '/scripts/create-console-notification.sh' ],
                env_+: {
                  OVERLAY_DATE: overlay.date,
                  OVERLAY_CHANNEL: overlay.channel,
                  OVERLAY_VERSION: overlay.version,
                  OVERLAY_VERSION_MINOR: std.split(overlay.version, '.')[1],
                },
                volumeMounts_+: {
                  'upgrade-notification-template': {
                    mountPath: 'export/template',
                    readOnly: true,
                  },
                  export: {
                    mountPath: '/export',
                  },
                  scripts: {
                    mountPath: '/scripts',
                  },
                },
              },
            },
            volumes_+: {
              'upgrade-notification-template': {
                configMap: {
                  name: 'upgrade-notification-template',
                  defaultMode: std.parseOctal('0550'),
                },
              },
              export: {
                emptyDir: {},
              },
              scripts: {
                configMap: {
                  name: 'console-notification-script',
                  defaultMode: std.parseOctal('0550'),
                },
              },
            },
            serviceAccountName: notificationRBAC.argocd_sa.metadata.name,
          },
        },
      },
    },
  ];


local hookScript = kube.ConfigMap('cleanup-upgrade-notification') + upgradeControllerNS {
  data: {
    'cleanup-upgrade-notification.sh': (importstr 'scripts/cleanup-upgrade-notification.sh'),
  },
};

local ujh(overlayVersion) = kube._Object('managedupgrade.appuio.io/v1beta1', 'UpgradeJobHook', 'cleanup-upgrade-notification') + upgradeControllerNS {
  spec+: {
    selector: {
      matchLabels: {
        'appuio-managed-upgrade': 'true',
      },
    },
    events: [
      'Finish',
    ],
    template+: {
      spec+: {
        template+: {
          spec+: {
            restartPolicy: 'Never',
            containers: [
              kube.Container('cleanup') {
                image: '%(registry)s/%(repository)s:%(tag)s' % params.images.oc,
                command: [ '/usr/local/bin/cleanup' ],
                env_+: {
                  OVERLAY_VERSION: std.split(overlayVersion, '.')[1],
                },
                volumeMounts_+: {
                  scripts: {
                    mountPath: '/usr/local/bin/cleanup',
                  },
                },
              },
            ],
            serviceAccountName: notificationRBAC.upgrade_sa.metadata.name,
            volumes: [
              {
                name: 'scripts',
                configMap: {
                  name: hookScript.metadata.name,
                  defaultMode: std.parseOctal('0550'),
                },
              },
            ],
          },
        },
      },
    },
  },
};


local upgradeNotification = if params.upgrade_notification.enabled then
  local channelOverlay = nextChannelOverlay();
  createUpgradeNotification(channelOverlay) + [
    hookScript,
    ujh(std.get(channelOverlay, 'version', '4.10000')),
  ] else [];

{
  rbac: if params.upgrade_notification.enabled then
    std.objectValues(notificationRBAC) else [],
  notifications: consoleNotifications,
  upgrade_notification: upgradeNotification,
}
