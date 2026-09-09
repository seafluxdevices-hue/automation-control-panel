import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_boilerplate/src/base/qa/device_probe.dart';
import 'package:flutter_boilerplate/src/base/qa/process_gateway.dart';
import 'package:flutter_boilerplate/src/models/qa/device_model.dart';
import 'package:flutter_boilerplate/src/providers/qa/run_provider.dart';
import 'package:provider/provider.dart';

/// Global (app-level) device list — Android/iOS tabs, both simulators and
/// physical devices under each. Fetched live on demand (no persisted
/// cache — a stale list is worse than a fast query, and `simctl list`/`adb
/// devices` are both sub-second), with a manual Sync/Reload button. Busy
/// status comes from [RunProvider]'s own active-runs registry, not an
/// OS-level signal — see docs/RUN_EXPERIENCE_REDESIGN.md §11.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _loading = true;
  List<DeviceInfo> _android = [];
  List<DeviceInfo> _ios = [];

  DeviceKind? _kindFilter;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _refresh();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final results = await Future.wait([
      DeviceProbe.listAndroidDevices(),
      DeviceProbe.listIosSimulators(),
      DeviceProbe.listIosPhysicalDevices(),
    ]);
    if (!mounted) return;
    setState(() {
      _android = results[0];
      _ios = [...results[1], ...results[2]];
      _loading = false;
    });
  }

  Future<void> _addSimulator() async {
    final platform = await showDialog<DevicePlatform>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Add simulator / emulator'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, DevicePlatform.ios),
            child: const Text('iOS simulator'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, DevicePlatform.android),
            child: const Text('Android emulator (AVD)'),
          ),
        ],
      ),
    );
    if (platform == null || !mounted) return;
    final bool? created;
    if (platform == DevicePlatform.ios) {
      created = await showDialog<bool>(
        context: context,
        builder: (_) => const _AddIosSimulatorDialog(),
      );
    } else {
      created = await showDialog<bool>(
        context: context,
        builder: (_) => const _AddAndroidAvdDialog(),
      );
    }
    if (created == true) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        elevation: 0,
        title: const Text('Devices'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [Tab(text: 'Android'), Tab(text: 'iOS')],
        ),
        actions: [
          Tooltip(
            message: 'Add simulator/emulator',
            child: IconButton(
              icon: const Icon(Icons.add_circle_outline),
              onPressed: _addSimulator,
            ),
          ),
          Tooltip(
            message: 'Sync/Reload',
            child: IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loading ? null : _refresh,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('All'),
                  selected: _kindFilter == null,
                  onSelected: (_) => setState(() => _kindFilter = null),
                ),
                ChoiceChip(
                  label: const Text('Simulators'),
                  selected: _kindFilter == DeviceKind.simulator,
                  onSelected: (_) =>
                      setState(() => _kindFilter = DeviceKind.simulator),
                ),
                ChoiceChip(
                  label: const Text('Physical devices'),
                  selected: _kindFilter == DeviceKind.physical,
                  onSelected: (_) =>
                      setState(() => _kindFilter = DeviceKind.physical),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    controller: _tabController,
                    children: [
                      _DeviceList(devices: _android, kindFilter: _kindFilter),
                      _DeviceList(devices: _ios, kindFilter: _kindFilter),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Device list ────────────────────────────────────────────────────────────

class _DeviceList extends StatelessWidget {
  final List<DeviceInfo> devices;
  final DeviceKind? kindFilter;
  const _DeviceList({required this.devices, this.kindFilter});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final filtered = kindFilter == null
        ? devices
        : devices.where((d) => d.kind == kindFilter).toList();
    if (filtered.isEmpty) {
      return Center(
        child: Text(
          devices.isEmpty ? 'No devices found' : 'No devices match this filter',
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: cs.onSurfaceVariant),
        ),
      );
    }
    return Consumer<RunProvider>(
      builder: (context, run, _) => ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: filtered.length,
        separatorBuilder: (_, _x) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final d = filtered[index];
          final busy = run.isDeviceBusy(d.udid);
          return ListTile(
            leading: Icon(
              d.kind == DeviceKind.simulator
                  ? Icons.smartphone
                  : Icons.phone_iphone,
              color: busy
                  ? cs.error
                  : (d.booted ? cs.primary : cs.onSurfaceVariant),
            ),
            title: Text(d.name),
            subtitle: Text(
              '${d.kind == DeviceKind.simulator ? 'Simulator' : 'Physical'}'
              ' · ${d.udid}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Chip(
              label: Text(busy ? 'Busy' : (d.booted ? 'Idle' : 'Shutdown')),
              backgroundColor: busy
                  ? cs.errorContainer
                  : (d.booted
                      ? cs.primaryContainer
                      : cs.surfaceContainerHighest),
              visualDensity: VisualDensity.compact,
            ),
          );
        },
      ),
    );
  }
}

// ── Shared dialog primitives ───────────────────────────────────────────────

/// Themed, bordered text-field that matches the app's primary colour.
class _DField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final bool autofocus;
  const _DField({
    required this.controller,
    required this.label,
    required this.hint,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return TextField(
      controller: controller,
      autofocus: autofocus,
      style: TextStyle(fontSize: 14, color: cs.onSurface),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(color: cs.primary, fontSize: 13),
        hintStyle: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: cs.primary, width: 2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        isDense: true,
      ),
    );
  }
}

/// Themed dropdown. `isExpanded: true` prevents RenderFlex overflows when
/// system-image package names are long.
class _DDropdown<T> extends StatelessWidget {
  final T? value;
  final String label;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  const _DDropdown({
    required this.value,
    required this.label,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DropdownButtonFormField<T>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: cs.primary, fontSize: 13),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: cs.primary, width: 2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        isDense: true,
      ),
      style: TextStyle(fontSize: 13, color: cs.onSurface),
      items: items,
      onChanged: onChanged,
    );
  }
}

/// Loading spinner / error banner — wraps the dialog body while SDK data loads.
class _DStateWrapper extends StatelessWidget {
  final bool loading;
  final String? error;
  final VoidCallback onRetry;
  final Widget child;
  const _DStateWrapper({
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (loading) {
      return const SizedBox(
        width: 380,
        height: 100,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (error != null) {
      return SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.error_outline, size: 18, color: cs.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(error!,
                    style: TextStyle(color: cs.error, fontSize: 13)),
              ),
            ]),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    return child;
  }
}

/// Card panel used for "SDK not found" / "no images" states.
class _InfoCard extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String body;
  final Widget? footer;
  const _InfoCard({
    required this.icon,
    this.iconColor,
    required this.title,
    required this.body,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 18, color: iconColor ?? cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface)),
            ),
          ]),
          const SizedBox(height: 8),
          Text(body,
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
          if (footer != null) ...[const SizedBox(height: 12), footer!],
        ],
      ),
    );
  }
}

// ── Add iOS simulator ──────────────────────────────────────────────────────

class _AddIosSimulatorDialog extends StatefulWidget {
  const _AddIosSimulatorDialog();

  @override
  State<_AddIosSimulatorDialog> createState() => _AddIosSimulatorDialogState();
}

class _AddIosSimulatorDialogState extends State<_AddIosSimulatorDialog> {
  final _nameCtrl = TextEditingController();
  List<IosDeviceType> _deviceTypes = [];
  List<IosRuntime> _runtimes = [];
  IosDeviceType? _selectedType;
  IosRuntime? _selectedRuntime;
  bool _loading = true;
  bool _creating = false;
  String? _error;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _nameCtrl.addListener(() => setState(() {}));
    _load();
  }

  // `simctl` occasionally hangs on a cold Xcode cache — bounded wait + retry
  // beats a dialog that spins forever.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final results = await Future.wait([
        DeviceProbe.listIosDeviceTypes(),
        DeviceProbe.listIosRuntimes(),
      ]).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      setState(() {
        _deviceTypes = results[0] as List<IosDeviceType>;
        _runtimes = results[1] as List<IosRuntime>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e is TimeoutException
            ? 'Timed out waiting for simctl. Try again.'
            : 'Could not load device types/runtimes: $e';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final type = _selectedType;
    final runtime = _selectedRuntime;
    final name = _nameCtrl.text.trim();
    if (type == null || runtime == null || name.isEmpty) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      await DeviceProbe.createIosSimulator(
        name: name,
        deviceTypeId: type.identifier,
        runtimeId: runtime.identifier,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canCreate = !_creating &&
        _selectedType != null &&
        _selectedRuntime != null &&
        _nameCtrl.text.trim().isNotEmpty;

    return AlertDialog(
      title: Row(children: [
        Icon(Icons.phone_iphone, size: 20, color: cs.primary),
        const SizedBox(width: 8),
        const Text('Add iOS Simulator',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ]),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      content: _DStateWrapper(
        loading: _loading,
        error: _loadError,
        onRetry: _load,
        child: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DField(
                controller: _nameCtrl,
                label: 'Simulator name',
                hint: 'e.g. My iPhone 17 Pro',
                autofocus: true,
              ),
              const SizedBox(height: 14),
              _DDropdown<IosDeviceType>(
                value: _selectedType,
                label: 'Device type',
                items: _deviceTypes
                    .map((t) => DropdownMenuItem(
                          value: t,
                          child: Text(t.name,
                              overflow: TextOverflow.ellipsis, maxLines: 1),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _selectedType = v),
              ),
              const SizedBox(height: 14),
              _DDropdown<IosRuntime>(
                value: _selectedRuntime,
                label: 'iOS version',
                items: _runtimes
                    .map((r) => DropdownMenuItem(
                          value: r,
                          child: Text('iOS ${r.version}',
                              overflow: TextOverflow.ellipsis, maxLines: 1),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _selectedRuntime = v),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.error_outline, size: 16, color: cs.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(_error!,
                        style: TextStyle(color: cs.error, fontSize: 12)),
                  ),
                ]),
              ],
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: canCreate ? _create : null,
          child: _creating
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: cs.onPrimary),
                )
              : const Text('Create'),
        ),
      ],
    );
  }
}

// ── Add Android AVD ────────────────────────────────────────────────────────

class _AddAndroidAvdDialog extends StatefulWidget {
  const _AddAndroidAvdDialog();

  @override
  State<_AddAndroidAvdDialog> createState() => _AddAndroidAvdDialogState();
}

class _AddAndroidAvdDialogState extends State<_AddAndroidAvdDialog> {
  final _nameCtrl = TextEditingController();
  List<AndroidDeviceProfile> _profiles = [];
  List<String> _systemImages = [];
  AndroidDeviceProfile? _selectedProfile;
  String? _selectedImage;
  bool _loading = true;
  bool _creating = false;
  bool _downloading = false;
  String? _error;
  String? _loadError;
  String? _downloadLog;

  @override
  void initState() {
    super.initState();
    // avdmanager only accepts [a-zA-Z0-9._-] — replace any other character
    // (most commonly spaces) with '_' as the user types, so the Create
    // button is never silently broken by an invalid name.
    _nameCtrl.addListener(() {
      final raw = _nameCtrl.text;
      final clean = raw.replaceAll(RegExp(r'[^a-zA-Z0-9._\-]'), '_');
      if (clean != raw) {
        final pos = _nameCtrl.selection.extentOffset
            .clamp(0, clean.length) as int;
        _nameCtrl.value = TextEditingValue(
          text: clean,
          selection: TextSelection.collapsed(offset: pos),
        );
      }
      setState(() {});
    });
    _load();
  }

  // avdmanager/sdkmanager are JVM tools — slow cold-start + possible license
  // stdin hang. Bounded wait beats a silent spinner.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final results = await Future.wait([
        DeviceProbe.listAndroidDeviceProfiles(),
        DeviceProbe.listAndroidSystemImages(),
      ]).timeout(const Duration(seconds: 30));
      if (!mounted) return;
      setState(() {
        _profiles = results[0] as List<AndroidDeviceProfile>;
        _systemImages = results[1] as List<String>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e is TimeoutException
            ? 'Timed out loading Android SDK data. Try again.'
            : 'Could not load SDK data: $e';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final profile = _selectedProfile;
    final image = _selectedImage;
    // Sanitize: avdmanager allows only [a-zA-Z0-9._-]
    final name =
        _nameCtrl.text.trim().replaceAll(RegExp(r'[^a-zA-Z0-9._\-]'), '_');
    if (profile == null || image == null || name.isEmpty) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      await DeviceProbe.createAndroidAvd(
          name: name, systemImage: image, device: profile.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _downloadSystemImage() async {
    const tag = 'google_apis';
    const api = 'android-35';
    final abi = _isAppleSilicon() ? 'arm64-v8a' : 'x86_64';
    final pkg = 'system-images;$api;$tag;$abi';
    setState(() {
      _downloading = true;
      _downloadLog = 'Downloading $pkg…';
      _error = null;
    });
    try {
      await ProcessGateway().exec(
        'yes | ${DeviceProbe.sdkmanagerPath()} "$pkg"',
        ignoreExitCode: true,
      );
      if (!mounted) return;
      setState(() => _downloadLog = 'Done — reloading…');
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = 'Download failed: $e');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  static bool _isAppleSilicon() {
    try {
      return (Process.runSync('uname', ['-m']).stdout as String).trim() ==
          'arm64';
    } catch (_) {
      return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final noProfiles = !_loading && _profiles.isEmpty;
    final noImages = !_loading && _profiles.isNotEmpty && _systemImages.isEmpty;
    final ready = !_loading && _profiles.isNotEmpty && _systemImages.isNotEmpty;
    final canCreate = ready &&
        !_creating &&
        _selectedProfile != null &&
        _selectedImage != null &&
        _nameCtrl.text.trim().isNotEmpty;

    return AlertDialog(
      title: Row(children: [
        Icon(Icons.android, size: 20, color: cs.primary),
        const SizedBox(width: 8),
        const Text('Add Android Emulator',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ]),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      content: _DStateWrapper(
        loading: _loading,
        error: _loadError,
        onRetry: _load,
        child: SizedBox(
          width: 380,
          child: noProfiles
              // ── SDK tools not found ──────────────────────────────────
              ? _InfoCard(
                  icon: Icons.warning_amber_rounded,
                  iconColor: cs.error,
                  title: 'Android SDK not found',
                  body: 'Install the Android SDK command-line tools via '
                      'Android Studio → Settings → SDK Manager → SDK Tools '
                      '→ Android SDK Command-line Tools.',
                  footer: OutlinedButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Retry'),
                  ),
                )
              : noImages
              // ── No system images installed ───────────────────────────
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _InfoCard(
                      icon: Icons.download_for_offline_outlined,
                      title: 'No system image installed',
                      body: 'An Android system image is required to create an '
                          'emulator. Tap Download to install the recommended '
                          'image (Android 35 · Google APIs · '
                          '${_isAppleSilicon() ? 'arm64-v8a' : 'x86_64'}).',
                    ),
                    if (_downloadLog != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _downloadLog!,
                          style: TextStyle(
                              fontSize: 12,
                              color: cs.primary,
                              fontFamily: 'monospace'),
                        ),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.error_outline,
                                size: 16, color: cs.error),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(_error!,
                                  style:
                                      TextStyle(color: cs.error, fontSize: 12)),
                            ),
                          ]),
                    ],
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _downloading ? null : _downloadSystemImage,
                      icon: _downloading
                          ? SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: cs.onPrimary),
                            )
                          : const Icon(Icons.download_rounded, size: 16),
                      label:
                          Text(_downloading ? 'Downloading…' : 'Download image'),
                    ),
                    const SizedBox(height: 4),
                  ],
                )
              // ── Happy path: profiles + images ready ──────────────────
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _DField(
                      controller: _nameCtrl,
                      label: 'AVD name',
                      hint: 'e.g. Pixel_9_API35  (spaces → _)',
                      autofocus: true,
                    ),
                    const SizedBox(height: 14),
                    _DDropdown<AndroidDeviceProfile>(
                      value: _selectedProfile,
                      label: 'Device profile',
                      items: _profiles
                          .map((p) => DropdownMenuItem(
                                value: p,
                                child: Text(p.name,
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1),
                              ))
                          .toList(),
                      onChanged: (v) => setState(() => _selectedProfile = v),
                    ),
                    const SizedBox(height: 14),
                    _DDropdown<String>(
                      value: _selectedImage,
                      label: 'System image',
                      items: _systemImages
                          .map((img) => DropdownMenuItem(
                                value: img,
                                child: Text(img,
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1),
                              ))
                          .toList(),
                      onChanged: (v) => setState(() => _selectedImage = v),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.error_outline,
                                size: 16, color: cs.error),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(_error!,
                                  style:
                                      TextStyle(color: cs.error, fontSize: 12)),
                            ),
                          ]),
                    ],
                    const SizedBox(height: 4),
                  ],
                ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (ready)
          FilledButton(
            onPressed: canCreate ? _create : null,
            child: _creating
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: cs.onPrimary),
                  )
                : const Text('Create'),
          ),
      ],
    );
  }
}
