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
  assert verparts[0] == 4 : 'This component only supports OCP4';
  assert
    std.length(verparts) > 1 :
    'The parameter openshift_version must provide the OCP version as "<major>.<minor>"';
  {
    major: verparts[0],
    minor: verparts[1],
  };

local newConfig = clusterVersion.minor >= 8;

local versionGroup = 'operator.openshift.io/v1';

// Extract and remove route config from console spec, this allows legacy
// configs to work unchanged
local consoleRoute =
  if std.objectHas(params.config, 'route') then
    params.config.route
  else
    {};
local consoleSpec = {
  [k]: params.config[k]
  for k in std.objectFields(params.config)
  if k != 'route'
};

// Create ResourceLocker patch to configure console route in
// ingress.config.openshift.io/cluster object
local consoleRoutePatch =
  local target = kube._Object('config.openshift.io/v1', 'ingress', 'cluster');
  local hostname =
    if std.objectHas(params.route, 'hostname') then
      params.route.hostname
    else if std.objectHas(consoleRoute, 'hostname') then
      consoleRoute.hostname
    else
      null;

  if hostname != null then
    local patch = {
      spec: {
        componentRoutes: [
          {
            name: 'console',
            namespace: 'openshift-console',
            hostname: consoleRoute.hostname,
          },
        ],
      },
    };
    rl.Patch(target, patch)
  else
    null;

{
  '00_namespace': kube.Namespace(params.namespace) {
    metadata+: {
      annotations:: {},
      [if std.member(inv.applications, 'networkpolicy') then 'labels']+: {
        [inv.parameters.networkpolicy.labels.noDefaults]: 'true',
        [inv.parameters.networkpolicy.labels.purgeDefaults]: 'true',
      },
    },
  },
  '10_console': kube._Object(versionGroup, 'Console', 'cluster') {
    spec+: if newConfig then consoleSpec else params.config,
  },
  [if newConfig && consoleRoutePatch != null then '20_ingress_config_patch']:
    consoleRoutePatch,
}
