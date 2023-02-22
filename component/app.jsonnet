local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.openshift4_console;
local argocd = import 'lib/argocd.libjsonnet';

local app = argocd.App('openshift4-console', params.namespace, secrets=false) {
  spec+: {
    ignoreDifferences+: [
      {
        group: 'operator.openshift.io',
        kind: 'Console',
        jsonPointers: [
          '/spec/plugins',
        ],
      },
    ],
  },
};

{
  'openshift4-console': app,
}
