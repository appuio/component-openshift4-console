// Need to use the full path here as the deprecation warning injection in
// https://github.com/projectsyn/commodore/blob/master/commodore/lib/kube.libsonnet
// breaks the topmost reference ($).
local kube = import 'lib/kube-libsonnet/kube.libsonnet';

kube {
  _Object(apiVersion, kind, name):: {
    local this = self,
    apiVersion: apiVersion,
    kind: kind,
    metadata: {
      name: name,
      labels: { name: std.join('-', std.split(this.metadata.name, ':')) },
    },
  },
}
