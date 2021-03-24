local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.openshift4_console;

local versionGroup = 'operator.openshift.io/v1';

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
    spec+: params.config,
  },
}
