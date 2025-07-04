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
    metadata+: {
      labels+: {
        'appuio.io/notification': 'true',
      },
    },
    spec: std.prune(
      {
        text: args.text,
        location: std.get(args, 'location', 'BannerTop'),
        color: std.get(args, 'color', '#fff'),
        backgroundColor: std.get(args, 'backgroundColor', '#2596be'),
        link: std.get(args, 'link'),
      },
    ),
  };

local consoleNotifications = [
  makeConsoleNotification(name, params.notifications[name])
  for name in std.objectFields(params.notifications)
  if params.notifications[name] != null
];

local nextChannelOverlay() =
  local overlays = inv.parameters.openshift_upgrade_controller.cluster_version.overlays;
  local channelOverlays = {
    [date]: overlays[date].spec.channel
    for date in std.objectFields(overlays)
    if std.objectHas(overlays[date].spec, 'channel')
       && std.split(overlays[date].spec.channel, '.')[1] > params.openshift_version.Minor
  };
  local date = if std.length(channelOverlays) > 0 then
    std.sort(std.objectFields(channelOverlays))[0];
  if date != null then
    {
      date: date,
      channel: channelOverlays[date],
      version: std.split(channelOverlays[date], '-')[1],
    };

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
      {
        apiGroups: [ '' ],
        resources: [ 'configmaps' ],
        resourceNames: [ 'upgrade-notification-template' ],
        verbs: [ '*' ],
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
          makeConsoleNotification('upgrade-%s' % overlay.version, params.upgrade_notification.notification) {
            metadata+: {
              labels+: {
                'appuio.io/ocp-version': overlay.version,
              },
            },
          },
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
          'argocd.argoproj.io/hook-delete-policy': 'BeforeHookCreation',
        },
      },
      spec+: {
        template+: {
          spec+: {
            containers_+: {
              notification: kube.Container('notification') {
                image: '%(registry)s/%(repository)s:%(tag)s' % params.images.oc,
                imagePullPolicy: 'Always',
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

local ujh = kube._Object('managedupgrade.appuio.io/v1beta1', 'UpgradeJobHook', 'cleanup-upgrade-notification') + upgradeControllerNS {
  metadata+: {
    annotations+: {
      'argocd.argoproj.io/sync-options': 'SkipDryRunOnMissingResource=true',
    },
  },
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
                volumeMounts_+: {
                  scripts: {
                    mountPath: '/usr/local/bin/cleanup',
                    readOnly: true,
                    subPath: 'cleanup-upgrade-notification.sh',
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
  local notification = if channelOverlay != null then
    createUpgradeNotification(channelOverlay)
  else [];
  notification + [
    hookScript,
    ujh,
  ] else [];

{
  rbac: if params.upgrade_notification.enabled then
    std.objectValues(notificationRBAC) else [],
  notifications: consoleNotifications,
  upgrade_notification: upgradeNotification,
}
