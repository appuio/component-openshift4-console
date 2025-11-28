local esp = import 'espejote.libsonnet';
local config = import 'minor-upgrade-notification/config.json';
local dst = import 'minor-upgrade-notification/dst.json';

// Finds the next (i.e. "oldest") clusterversion overlay that sets a channel
// higher than the current OpenShift minor version.
local nextChannelOverlay =
  local overlays = esp.context().clusterversion_appuio[0].spec.overlays;
  local current_minor = std.split(esp.context().clusterversion_ocp[0].spec.desiredUpdate.version, '.')[1];
  local pendingOverlays = [
    [overlay.from, overlay.overlay.spec.channel]
    for overlay in overlays
    if std.objectHas(overlay.overlay.spec, 'channel')
      && std.split(overlay.overlay.spec.channel, '.')[1] > current_minor
  ];
  if std.length(pendingOverlays) > 0 then
    local next = std.sort(pendingOverlays)[0];
    {date: next[0], channel: next[1]};

// Finds the first upgrade window after the overlay date. Upgradeconfigs only
// display the next 10 maintenance windows, so it's not guaranteed to find one
// if the overlay is far in the future.
local upgradeWindow = if nextChannelOverlay != null then
  local possible = [t.time for t in esp.context().upgradeconfig[0].status.nextPossibleSchedules if t.time > nextChannelOverlay.date ];
  if std.length(possible) > 0 then possible[0];

// Custom format datetime and calculate Europe/Zurich time based on dates where
// daylight saving times change.
local formatDate(date) =
  local lastChange = std.reverse([t for t in std.objectFields(dst) if t < date])[0];
  local UTCOffset = dst[lastChange];
  local parts = std.split(date, 'T');
  assert std.length(parts) == 2 : 'Expected RFC-3339 datetime to have exactly one "T"';
  local YMD = std.split(parts[0], '-');
  assert std.length(YMD) == 3 : 'Expected RFC-3339 date to have exactly two "-"';
  local Y = YMD[0];
  local M = YMD[1];
  local D = YMD[2];
  local hms = std.split(parts[1], ':');
  assert std.length(hms) == 3 : 'Expected RFC-3339 time to have exactly two ":"';
  local h = std.toString(std.parseInt(hms[0]) + UTCOffset);
  local m = hms[1];
  '%s.%s.%s %s:%s' % [D, M, Y, h, m];

local replacementValues = {
  '$OVERLAY_DATE': formatDate(nextChannelOverlay.date),
  '$NEXT_MAINTENANCE': formatDate(upgradeWindow),
  '$OVERLAY_CHANNEL': nextChannelOverlay.channel,
  '$OVERLAY_VERSION': std.split(nextChannelOverlay.channel, '-')[1],
  '$OVERLAY_VERSION_MINOR': std.split(nextChannelOverlay.channel, '.')[1],
};

local makeConsoleNotification(name, args, repl) =
  local replace(t, v) = std.strReplace(t, v, std.get(repl, v));
  local text = std.foldl(replace, std.reverse(std.sort(std.objectFields(repl))), args.text);
  {
    apiVersion: 'console.openshift.io/v1',
    kind: 'ConsoleNotification',
    metadata: {
      labels: {
        'appuio.io/notification': 'true',
      },
      name: name,
    },
    spec: std.prune(
      {
        text: text,
        location: std.get(args, 'location', 'BannerTop'),
        color: std.get(args, 'color', '#fff'),
        backgroundColor: std.get(args, 'backgroundColor', '#2596be'),
        link: std.get(args, 'link'),
      },
    ),
  };

if upgradeWindow != null then makeConsoleNotification('upgrade-%s' % replacementValues['$OVERLAY_VERSION'], config.notification, replacementValues)
