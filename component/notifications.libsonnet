local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.openshift4_console;

local makeConsoleNotification(name, args) =
  kube._Object('console.openshift.io/v1', 'ConsoleNotification', name) {
    spec: {
      text: args.text,
      location: std.get(args, 'location', 'BannerTop'),
      color: std.get(args, 'color', '#fff'),
      backgroundColor: std.get(args, 'backgroundColor', '#2596be'),
      //link: if std.objectHas(args, 'link') then args.link,
      link: std.get(args, 'link'),
    },
  };

local consoleNotifications = [
  makeConsoleNotification(name, params.notifications[name])
  for name in std.objectFields(params.notifications)
  if params.notifications[name] != null
];

local motdText = std.join(
  '\n',
  [
    params.notifications[name].text
    for name in std.objectFields(params.notifications)
    if params.notifications[name] != null
  ],
);

local motd = if std.length(motdText) > 0 then [
  kube.ConfigMap('motd') {
    metadata+: {
      namespace: 'openshift',
    },
    data: {
      message: motdText,
    },
  },
] else [];


{
  notifications: consoleNotifications + motd,
}
