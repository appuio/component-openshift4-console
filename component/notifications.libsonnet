local kube = import 'kube-ssa-compat.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local esp = import 'lib/espejote.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';

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

local notificationRBAC =
  local sa = kube.ServiceAccount('notification-manager') + namespace;
  local cluster_role = kube.ClusterRole('appuio:notification-manager') {
    rules: [
      {
        apiGroups: [ 'console.openshift.io' ],
        resources: [ 'consolenotifications' ],
        verbs: [ '*' ],
      },
      {
        apiGroups: [ 'managedupgrade.appuio.io' ],
        resources: [ 'upgradeconfigs' ],
        verbs: [ 'get', 'list', 'watch' ],
      },
      {
        apiGroups: [ 'managedupgrade.appuio.io' ],
        resources: [ 'clusterversions' ],
        verbs: [ 'get', 'list', 'watch' ],
      },
      {
        apiGroups: [ 'config.openshift.io' ],
        resources: [ 'clusterversions' ],
        verbs: [ 'get', 'list', 'watch' ],
      },
      {
        apiGroups: [ 'espejote.io' ],
        resources: [ 'jsonnetlibraries' ],
        verbs: [ 'get', 'list', 'watch' ],
      },
    ],
  };
  local cluster_role_binding =
    kube.ClusterRoleBinding('appuio:notification-manager') {
      subjects_: [ sa ],
      roleRef_: cluster_role,
    };
  {
    sa: sa,
    cluster_role: cluster_role,
    cluster_role_binding: cluster_role_binding,
  };

local jsonnetlib =
  esp.jsonnetLibrary('minor-upgrade-notification', params.namespace) {
    spec: {
      data: {
        'config.json': std.manifestJson({
          notification: params.upgrade_notification.notification,
        }),
        'dst.json': std.manifestJson({
          '2025-10-26': 1,
          '2026-03-29': 2,
          '2026-10-25': 1,
          '2027-03-28': 2,
          '2027-10-31': 1,
          '2028-03-26': 2,
          '2028-10-29': 1,
          '2029-03-25': 2,
          '2029-10-28': 1,
        }),
      },
    },
  };

local jsonnetlib_ref = {
  apiVersion: jsonnetlib.apiVersion,
  kind: jsonnetlib.kind,
  name: jsonnetlib.metadata.name,
  namespace: jsonnetlib.metadata.namespace,
};

local managedresource =
  esp.managedResource('minor-upgrade-notification', params.namespace) {
    metadata+: {
      annotations: {
        'syn.tools/description': |||
          Creates ConsoleNotifications to inform cluster users about scheduled minor OpenShift upgrades.
        |||,
      },
    },
    spec: {
      serviceAccountRef: { name: notificationRBAC.sa.metadata.name },
      applyOptions: { force: true },
      context: [
        {
          name: 'clusterversion_appuio',
          resource: {
            apiVersion: 'managedupgrade.appuio.io/v1beta1',
            kind: 'ClusterVersion',
            name: 'version',
            namespace: 'appuio-openshift-upgrade-controller',
          },
        },
        {
          name: 'clusterversion_ocp',
          resource: {
            apiVersion: 'config.openshift.io/v1',
            kind: 'ClusterVersion',
            name: 'version',
          },
        },
        {
          name: 'upgradeconfig',
          resource: {
            apiVersion: 'managedupgrade.appuio.io/v1beta1',
            kind: 'UpgradeConfig',
            namespace: 'appuio-openshift-upgrade-controller',
            labelSelector: {
              matchExpressions: [
                {
                  key: 'argocd.argoproj.io/instance',
                  operator: 'In',
                  values: [ 'openshift-upgrade-controller' ],
                },
              ],
            },
          },
        },
      ],
      triggers: [
        {
          name: 'clusterversion_appuio',
          watchContextResource: {
            name: 'clusterversion_appuio',
          },
        },
        {
          name: 'clusterversion_ocp',
          watchContextResource: {
            name: 'clusterversion_ocp',
          },
        },
        {
          name: 'upgradeconfig',
          watchContextResource: {
            name: 'upgradeconfig',
          },
        },
        {
          name: 'jsonnetlib',
          watchResource: jsonnetlib_ref,
        },
      ],
      template: importstr 'espejote-templates/upgrade-notification.jsonnet',
    },
  };

{
  rbac: if params.upgrade_notification.enabled then
    std.objectValues(notificationRBAC) else [],
  notifications: consoleNotifications,
  upgrade_notification: if params.upgrade_notification.enabled then [ managedresource, jsonnetlib ] else [],
}
