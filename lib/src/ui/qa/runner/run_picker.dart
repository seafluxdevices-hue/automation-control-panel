import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_boilerplate/src/base/qa/device_probe.dart';
import 'package:flutter_boilerplate/src/base/qa/run_dispatcher.dart';
import 'package:flutter_boilerplate/src/models/qa/device_model.dart';
import 'package:flutter_boilerplate/src/models/qa/project_model.dart';
import 'package:flutter_boilerplate/src/models/qa/run_record_model.dart';
import 'package:flutter_boilerplate/src/providers/qa/run_provider.dart';
import 'package:provider/provider.dart';

/// The shared (mobile only) Platform → Simulator/Physical → Device picker
/// flow — used by both the Scripts screen's Run buttons and the Recent-runs
/// "Re-run" action, so a script/history entry can trigger a dispatch without
/// duplicating this UI. Deliberately simple sequential dialogs, not a custom
/// wizard widget. See docs/RUN_EXPERIENCE_REDESIGN.md §6/§9.
///
/// No more an environment step — environment is a static property of the
/// surface now ([SurfaceConfig.environmentId]), not asked at Run time. A web
/// surface's Run shows zero popups; a single-platform mobile surface only
/// asks target+device.
class RunPicker {
  RunPicker._();

  /// Walks the full flow for [surface]. Returns null if the user cancels
  /// any step.
  static Future<
      ({
        DevicePlatform? platform,
        DeviceKind? deviceKind,
        String? deviceUdid,
      })?> pick(
    BuildContext context, {
    required ProjectConfig project,
    required SurfaceConfig surface,
  }) async {
    if (!surface.isMobile) {
      return (platform: null, deviceKind: null, deviceUdid: null);
    }

    // A surface's platformType already says which platform it is — only a
    // surface with none set (shouldn't happen for one created through the
    // current Add Surface flow, but kept as a defensive fallback) asks.
    DevicePlatform platform;
    if (surface.isIos) {
      platform = DevicePlatform.ios;
    } else if (surface.isAndroid) {
      platform = DevicePlatform.android;
    } else {
      final picked = await pickPlatform(context);
      if (picked == null || !context.mounted) return null;
      platform = picked;
    }

    final deviceKind = await pickTarget(context);
    if (deviceKind == null || !context.mounted) return null;
    final deviceUdid = await pickDevice(context, platform, deviceKind);
    if (deviceUdid == null || !context.mounted) return null;

    return (platform: platform, deviceKind: deviceKind, deviceUdid: deviceUdid);
  }

  /// Re-runs [record] via [pick] — shared by the surface-level and global
  /// Recent-runs screens so neither duplicates this orchestration. Needs the
  /// original script to still exist on [surface]; `RunRecord` only kept its
  /// display name (it may have been renamed or deleted since), so this can't
  /// blindly resolve an id — falls back to a clear SnackBar rather than
  /// guessing.
  static Future<void> reRun(
    BuildContext context, {
    required ProjectConfig project,
    required SurfaceConfig surface,
    required RunRecord record,
  }) async {
    if (!record.hasRerunInfo) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Not enough info on file to re-run this one — run it '
            'fresh from the Scripts screen.'),
      ));
      return;
    }
    final script = surface.scripts
        .where((s) => s.displayName == record.scriptDisplayName)
        .firstOrNull;
    if (script == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('That script no longer exists on this surface — run '
            'a current one from the Scripts screen instead.'),
      ));
      return;
    }
    final picked = await pick(context, project: project, surface: surface);
    if (picked == null || !context.mounted) return;

    // RunDispatcher.dispatch internally awaits the *entire* pipeline (see
    // ScriptsScreen._startRun's doc) — awaiting it here would mean this
    // button just sits there with no feedback until the whole run is
    // already over. Quick pre-check instead, then fire-and-forget so the
    // toast is immediate and RunPanel picks up live progress on its own.
    final targetKey = picked.deviceKind == null
        ? null
        : (picked.deviceKind == DeviceKind.physical ? 'device' : 'simulator');
    if (project.testCommandFor(surface.id, target: targetKey) == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not start.')));
      return;
    }
    unawaited(RunDispatcher().dispatch(
      runProvider: context.read<RunProvider>(),
      project: project,
      surface: surface,
      script: script,
      platform: picked.platform,
      deviceKind: picked.deviceKind,
      deviceUdid: picked.deviceUdid,
    ));
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Started.')));
  }

  static Future<DevicePlatform?> pickPlatform(BuildContext context) =>
      _showPickerDialog<DevicePlatform>(
        context,
        title: 'Platform',
        titleIcon: Icons.devices_other,
        options: const [
          _PickerOption(
            value: DevicePlatform.android,
            label: 'Android',
            icon: Icons.android,
          ),
          _PickerOption(
            value: DevicePlatform.ios,
            label: 'iOS',
            icon: Icons.apple,
          ),
        ],
      );

  static Future<DeviceKind?> pickTarget(BuildContext context) =>
      _showPickerDialog<DeviceKind>(
        context,
        title: 'Simulator or physical device?',
        titleIcon: Icons.phone_iphone,
        options: const [
          _PickerOption(
            value: DeviceKind.simulator,
            label: 'Simulator',
            subtitle: 'Emulated device on this Mac',
            icon: Icons.desktop_windows_outlined,
          ),
          _PickerOption(
            value: DeviceKind.physical,
            label: 'Physical device',
            subtitle: 'Connected over USB / network',
            icon: Icons.smartphone,
          ),
        ],
      );

  static Future<String?> pickDevice(
    BuildContext context,
    DevicePlatform platform,
    DeviceKind kind,
  ) async {
    final runProvider = context.read<RunProvider>();
    final all = platform == DevicePlatform.android
        ? await DeviceProbe.listAndroidDevices()
        : kind == DeviceKind.simulator
            ? await DeviceProbe.listIosSimulators()
            : await DeviceProbe.listIosPhysicalDevices();
    if (!context.mounted) return null;

    final idle = all
        .where((d) => d.kind == kind && !runProvider.isDeviceBusy(d.udid))
        .toList();
    if (idle.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('No idle '
            '${kind == DeviceKind.simulator ? 'simulators' : 'devices'} found.'),
      ));
      return null;
    }

    return _showPickerDialog<String>(
      context,
      title: 'Device',
      titleIcon: Icons.devices,
      options: [
        _PickerOption(
          value: idle.first.udid,
          label: idle.first.name,
          subtitle: 'Available now',
          icon: Icons.bolt,
        ),
        ...idle.skip(1).map((d) => _PickerOption(
              value: d.udid,
              label: d.name,
              icon: kind == DeviceKind.simulator
                  ? Icons.desktop_windows_outlined
                  : Icons.smartphone,
            )),
      ],
    );
  }
}

// ── Shared picker dialog ──────────────────────────────────────────────────────

/// One selectable row in a [_showPickerDialog] — an icon, a label, and an
/// optional subtitle (e.g. "Last used", "Available now").
class _PickerOption<T> {
  final T value;
  final String label;
  final String? subtitle;
  final IconData icon;

  const _PickerOption({
    required this.value,
    required this.label,
    this.subtitle,
    required this.icon,
  });
}

/// Card-style replacement for the plain [SimpleDialog]/[SimpleDialogOption]
/// rows every Run-button picker step used to show — same sequential-dialogs
/// flow, just easier to scan (icon + label + subtitle per option, a visible
/// Cancel) than a bare list of text rows.
Future<T?> _showPickerDialog<T>(
  BuildContext context, {
  required String title,
  required IconData titleIcon,
  required List<_PickerOption<T>> options,
}) {
  final cs = Theme.of(context).colorScheme;
  return showDialog<T>(
    context: context,
    builder: (ctx) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 400,
          // Cap height so the dialog never taller than 80% of the screen,
          // which makes the list scroll rather than overflow.
          maxHeight: MediaQuery.of(ctx).size.height * 0.80,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Fixed header ───────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Row(
                children: [
                  Icon(titleIcon, color: cs.primary),
                  const SizedBox(width: 10),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ],
              ),
            ),

            // ── Scrollable option list ─────────────────────────────────
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                itemCount: options.length,
                separatorBuilder: (context, index) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final o = options[i];
                  return InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => Navigator.pop(ctx, o.value),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        border: Border.all(color: cs.outlineVariant),
                        borderRadius: BorderRadius.circular(12),
                        // Tint the first (recommended) option subtly.
                        color: i == 0
                            ? cs.primaryContainer.withValues(alpha: 0.25)
                            : null,
                      ),
                      child: Row(
                        children: [
                          Icon(o.icon,
                              size: 20,
                              color: i == 0 ? cs.primary : cs.onSurfaceVariant),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  o.label,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(
                                        fontWeight: FontWeight.w500,
                                        color: i == 0 ? cs.primary : null,
                                      ),
                                ),
                                if (o.subtitle != null)
                                  Text(
                                    o.subtitle!,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(color: cs.onSurfaceVariant),
                                  ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right,
                              size: 18, color: cs.onSurfaceVariant),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

            // ── Fixed footer ───────────────────────────────────────────
            const Divider(height: 1),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
