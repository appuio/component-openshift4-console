local kube = import 'kube-ssa-compat.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.openshift4_console;

{
  [std.asciiLower(link)]: kube._Object('console.openshift.io/v1', 'ConsoleLink', link) {
    spec: params.console_links[link],
  }
  for link in std.objectFields(params.console_links)
  if params.console_links[link] != null
}
