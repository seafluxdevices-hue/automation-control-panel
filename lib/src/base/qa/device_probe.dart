import 'dart:convert';
import 'dart:io';

import 'package:flutter_boilerplate/src/base/qa/process_gateway.dart';
import 'package:flutter_boilerplate/src/models/qa/device_model.dart';

/// Lists real simulators/emulators and physical devices via the platform
/// tooling already relied on elsewhere in this app (`xcrun simctl`, `adb`,
/// `xcrun devicectl`) — no persisted cache, per
/// docs/RUN_EXPERIENCE_REDESIGN.md §11 ("fetch-on-demand, no stored cache").
///
/// Every method is best-effort and never throws: a missing tool, a
/// never-installed Android SDK, or an unexpected JSON shape just yields an
/// empty list rather than blocking the device picker — manual udid entry
/// stays available wherever these are used.
class DeviceProbe {
  DeviceProbe._();

  // ── Android SDK path resolution ─────────────────────────────────────────
  //
  // `avdmanager` and `sdkmanager` live inside the Android SDK, which is
  // typically NOT on the shell PATH when the app is launched from VS Code or
  // the Dock (launchd environment). We look in three places in order:
  //   1. ANDROID_HOME  (the canonical env var)
  //   2. ANDROID_SDK_ROOT  (older alias, still widely used)
  //   3. ~/Library/Android/sdk  (Android Studio default on macOS)
  //
  // Returning `null` means "SDK not found" — callers show an actionable
  // error rather than a confusing "command not found" failure.
  static String? _androidSdkRoot() {
    for (final envKey in ['ANDROID_HOME', 'ANDROID_SDK_ROOT']) {
      final v = Platform.environment[envKey];
      if (v != null && v.isNotEmpty && Directory(v).existsSync()) return v;
    }
    final home = Platform.environment['HOME'] ?? '';
    final defaultPath = '$home/Library/Android/sdk';
    if (Directory(defaultPath).existsSync()) return defaultPath;
    return null;
  }

  /// Full path to `avdmanager`, or bare `avdmanager` as a fallback so the
  /// login-shell PATH still has a chance to find it.
  static String _avdmanager() {
    final sdk = _androidSdkRoot();
    if (sdk != null) {
      for (final candidate in [
        '$sdk/cmdline-tools/latest/bin/avdmanager',
        '$sdk/tools/bin/avdmanager',
      ]) {
        if (File(candidate).existsSync()) return candidate;
      }
    }
    return 'avdmanager';
  }

  /// Public accessor used by the UI to run sdkmanager directly (e.g. to
  /// download a system image). Returns the resolved full path or bare name.
  static String sdkmanagerPath() => _sdkmanager();

  /// Full path to `sdkmanager`, or bare fallback.
  static String _sdkmanager() {
    final sdk = _androidSdkRoot();
    if (sdk != null) {
      for (final candidate in [
        '$sdk/cmdline-tools/latest/bin/sdkmanager',
        '$sdk/tools/bin/sdkmanager',
      ]) {
        if (File(candidate).existsSync()) return candidate;
      }
    }
    return 'sdkmanager';
  }

  /// Full path to `adb`, or bare fallback.
  static String _adb() {
    final sdk = _androidSdkRoot();
    if (sdk != null) {
      final candidate = '$sdk/platform-tools/adb';
      if (File(candidate).existsSync()) return candidate;
    }
    return 'adb';
  }

  static Future<List<DeviceInfo>> listIosSimulators({ProcessGateway? gateway}) async {
    final gw = gateway ?? ProcessGateway();
    try {
      final out = await gw.exec('xcrun simctl list devices --json',
          ignoreExitCode: true);
      if (out.trim().isEmpty) return [];
      final parsed = jsonDecode(out);
      if (parsed is! Map) return [];
      final byRuntime = parsed['devices'] as Map? ?? {};
      final result = <DeviceInfo>[];
      for (final list in byRuntime.values) {
        if (list is! List) continue;
        for (final d in list) {
          if (d is! Map) continue;
          if (d['isAvailable'] == false) continue;
          final udid = d['udid'];
          if (udid is! String) continue;
          result.add(DeviceInfo(
            udid: udid,
            name: (d['name'] as String?) ?? 'Unknown simulator',
            platform: DevicePlatform.ios,
            kind: DeviceKind.simulator,
            booted: d['state'] == 'Booted',
          ));
        }
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  /// Returns all Android devices: running physical devices + running emulators
  /// (from `adb devices`) merged with all created AVDs (`avdmanager list avd`).
  ///
  /// A created AVD that is not currently running is included with
  /// `booted: false` so users can see it in the Devices screen even before
  /// they launch it — matching how iOS simulators behave.
  static Future<List<DeviceInfo>> listAndroidDevices({ProcessGateway? gateway}) async {
    final gw = gateway ?? ProcessGateway();

    // ── 1. Running devices from adb ──────────────────────────────────────
    final Map<String, DeviceInfo> byId = {};
    try {
      final out = await gw.exec('${_adb()} devices -l', ignoreExitCode: true);
      for (final raw in out.split('\n').skip(1)) {
        final line = raw.trim();
        if (line.isEmpty) continue;
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length < 2 || parts[1] != 'device') continue;
        final id = parts[0];
        final modelToken = parts
            .skip(2)
            .where((p) => p.startsWith('model:'))
            .firstOrNull;
        final name = modelToken != null
            ? modelToken.substring('model:'.length).replaceAll('_', ' ')
            : id;
        byId[id] = DeviceInfo(
          udid: id,
          name: name,
          platform: DevicePlatform.android,
          kind: id.startsWith('emulator-')
              ? DeviceKind.simulator
              : DeviceKind.physical,
          booted: true,
        );
      }
    } catch (_) {}

    // ── 2. All created AVDs from avdmanager ──────────────────────────────
    // `avdmanager list avd` block format (one AVD per block):
    //   Name: Pixel_3
    //   Device: pixel_3 (Google)
    //   Path: /Users/…/Pixel_3.avd
    //   Target: …
    //   …
    // Blocks are separated by a blank line or a line starting with "---".
    try {
      final out = await gw.exec(
          '${_avdmanager()} list avd', ignoreExitCode: true);
      String? avdName;
      for (final raw in out.split('\n')) {
        final line = raw.trim();
        final nameMatch = RegExp(r'^Name:\s*(.+)$').firstMatch(line);
        if (nameMatch != null) {
          avdName = nameMatch.group(1)!.trim();
          continue;
        }
        // End of block — blank line, separator, or next "Name:" will reset.
        if ((line.isEmpty || line.startsWith('-')) && avdName != null) {
          // Only add if not already present as a running emulator.
          if (!byId.containsKey(avdName)) {
            byId[avdName] = DeviceInfo(
              udid: avdName,
              name: avdName.replaceAll('_', ' '),
              platform: DevicePlatform.android,
              kind: DeviceKind.simulator,
              booted: false,
            );
          }
          avdName = null;
        }
      }
      // Flush a trailing AVD block with no trailing separator.
      if (avdName != null && !byId.containsKey(avdName)) {
        byId[avdName] = DeviceInfo(
          udid: avdName,
          name: avdName.replaceAll('_', ' '),
          platform: DevicePlatform.android,
          kind: DeviceKind.simulator,
          booted: false,
        );
      }
    } catch (_) {}

    return byId.values.toList();
  }

  /// `devicectl`'s JSON shape has changed across Xcode releases and the
  /// tool may not exist at all on older toolchains — any failure here just
  /// means no physical iOS devices are listed.
  static Future<List<DeviceInfo>> listIosPhysicalDevices({ProcessGateway? gateway}) async {
    final gw = gateway ?? ProcessGateway();
    final tmp = File(
        '${Directory.systemTemp.path}/qa_devicectl_${DateTime.now().microsecondsSinceEpoch}.json');
    try {
      await gw.exec('xcrun devicectl list devices --json-output "${tmp.path}"',
          ignoreExitCode: true);
      if (!tmp.existsSync()) return [];
      final parsed = jsonDecode(tmp.readAsStringSync());
      if (parsed is! Map) return [];
      final devices = (parsed['result'] as Map?)?['devices'] as List? ?? [];
      final result = <DeviceInfo>[];
      for (final d in devices) {
        if (d is! Map) continue;
        final udid = (d['hardwareProperties'] as Map?)?['udid'];
        if (udid is! String) continue;
        final name = (d['deviceProperties'] as Map?)?['name'] as String?;
        result.add(DeviceInfo(
          udid: udid,
          name: name ?? 'Unknown device',
          platform: DevicePlatform.ios,
          kind: DeviceKind.physical,
          booted: true,
        ));
      }
      return result;
    } catch (_) {
      return [];
    } finally {
      if (tmp.existsSync()) {
        try {
          tmp.deleteSync();
        } catch (_) {}
      }
    }
  }

  // ── Add simulator/emulator (docs/RUN_EXPERIENCE_REDESIGN.md §11) ─────────
  //
  // Listing here follows the same never-throws convention as above. The
  // create* methods below are the one exception — a user just pressed
  // "Create" and needs to see the real error (bad device type, SDK not
  // installed, ...), so those let `ProcessGateway`'s `ProcessException`
  // propagate rather than swallowing it, matching how the Doctor "Fix"
  // button already treats a user-initiated action's failure.

  static Future<List<IosDeviceType>> listIosDeviceTypes({ProcessGateway? gateway}) async {
    final gw = gateway ?? ProcessGateway();
    try {
      final out = await gw.exec('xcrun simctl list devicetypes --json',
          ignoreExitCode: true);
      final parsed = jsonDecode(out);
      if (parsed is! Map) return [];
      final list = parsed['devicetypes'] as List? ?? [];
      return list
          .whereType<Map>()
          .map((d) => (d['identifier'] as String?, d['name'] as String?))
          .where((t) => t.$1 != null && t.$2 != null)
          .map((t) => IosDeviceType(identifier: t.$1!, name: t.$2!))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<List<IosRuntime>> listIosRuntimes({ProcessGateway? gateway}) async {
    final gw = gateway ?? ProcessGateway();
    try {
      final out = await gw.exec('xcrun simctl list runtimes --json',
          ignoreExitCode: true);
      final parsed = jsonDecode(out);
      if (parsed is! Map) return [];
      final list = parsed['runtimes'] as List? ?? [];
      return list
          .whereType<Map>()
          .where((r) => r['isAvailable'] != false)
          .map((r) => (r['identifier'] as String?, r['version'] as String?))
          .where((t) => t.$1 != null && t.$2 != null)
          .map((t) => IosRuntime(identifier: t.$1!, version: t.$2!))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Creates a new simulator; returns its udid. Lets failures propagate —
  /// see the class-level note above.
  static Future<String> createIosSimulator({
    required String name,
    required String deviceTypeId,
    required String runtimeId,
    ProcessGateway? gateway,
  }) async {
    final gw = gateway ?? ProcessGateway();
    final udid = await gw.exec('xcrun simctl create "$name" $deviceTypeId $runtimeId');
    return udid.trim();
  }

  /// Parses `avdmanager list device`'s block format:
  /// ```
  /// id: 0 or "Galaxy Nexus"
  ///     Name: Galaxy Nexus
  ///     OEM : Google
  /// ---------
  /// ```
  /// Exposed separately from [listAndroidDeviceProfiles] so it's testable
  /// against recorded sample output — this dev environment has no Android
  /// SDK installed to verify the live command against.
  static List<AndroidDeviceProfile> parseAndroidDeviceProfiles(String output) {
    final result = <AndroidDeviceProfile>[];
    String? currentId;
    String? currentName;
    for (final raw in output.split('\n')) {
      final line = raw.trim();
      final idMatch = RegExp(r'^id:\s*\d+\s+or\s+"(.+)"$').firstMatch(line);
      if (idMatch != null) {
        currentId = idMatch.group(1);
        currentName = null;
        continue;
      }
      final nameMatch = RegExp(r'^Name:\s*(.+)$').firstMatch(line);
      if (nameMatch != null) currentName = nameMatch.group(1);
      if (line.startsWith('---') && currentId != null) {
        result.add(AndroidDeviceProfile(id: currentId, name: currentName ?? currentId));
        currentId = null;
        currentName = null;
      }
    }
    // A final entry with no trailing "---------" separator.
    if (currentId != null) {
      result.add(AndroidDeviceProfile(id: currentId, name: currentName ?? currentId));
    }
    return result;
  }

  static Future<List<AndroidDeviceProfile>> listAndroidDeviceProfiles({ProcessGateway? gateway}) async {
    final gw = gateway ?? ProcessGateway();
    try {
      final out = await gw.exec('${_avdmanager()} list device', ignoreExitCode: true);
      return parseAndroidDeviceProfiles(out);
    } catch (_) {
      return [];
    }
  }

  /// Parses `sdkmanager --list_installed` output for installed
  /// `system-images;...` package paths — the values `avdmanager create avd
  /// -k` needs.
  ///
  /// Handles two formats:
  ///   • Legacy (sdkmanager ≤10): pipe-delimited table
  ///       `system-images;android-34;google_apis;arm64-v8a | 4 | ...`
  ///   • Current (sdkmanager 23+, which deprecated itself and now wraps the
  ///     Android CLI): space-aligned table where the first token on each
  ///     non-header line is the package path, e.g.:
  ///       `  system-images;android-35;google_apis;arm64-v8a   4.0   ...`
  static List<String> parseInstalledSystemImages(String output) {
    final result = <String>[];
    for (final raw in output.split('\n')) {
      // Both formats have the package path as the first non-whitespace token.
      final trimmed = raw.trim();
      if (!trimmed.startsWith('system-images;')) continue;
      // Grab everything up to the first whitespace or pipe.
      final pkg = trimmed.split(RegExp(r'[\s|]')).first.trim();
      if (pkg.isNotEmpty) result.add(pkg);
    }
    return result;
  }

  /// Returns installed system images, falling back to scanning the
  /// `system-images/` directory on disk when `sdkmanager` output is empty
  /// (covers the case where sdkmanager is deprecated / changes output format
  /// again, but the images were installed via Android Studio's GUI).
  static Future<List<String>> listAndroidSystemImages({ProcessGateway? gateway}) async {
    final gw = gateway ?? ProcessGateway();
    try {
      final out = await gw.exec('${_sdkmanager()} --list_installed', ignoreExitCode: true);
      final parsed = parseInstalledSystemImages(out);
      if (parsed.isNotEmpty) return parsed;
    } catch (_) {}

    // Fallback: scan the SDK's system-images directory directly.
    // Layout: <sdk>/system-images/<api>/<tag>/<abi>/
    final sdk = _androidSdkRoot();
    if (sdk == null) return [];
    final sysImgDir = Directory('$sdk/system-images');
    if (!sysImgDir.existsSync()) return [];
    final result = <String>[];
    for (final api in sysImgDir.listSync().whereType<Directory>()) {
      for (final tag in api.listSync().whereType<Directory>()) {
        for (final abi in tag.listSync().whereType<Directory>()) {
          // e.g. system-images;android-35;google_apis;arm64-v8a
          result.add(
            'system-images;${api.path.split('/').last};'
            '${tag.path.split('/').last};'
            '${abi.path.split('/').last}',
          );
        }
      }
    }
    return result;
  }

  /// Creates a new AVD; auto-answers avdmanager's "create a custom hardware
  /// profile?" prompt with "no" (the [device] profile is enough). Lets
  /// failures propagate — see the class-level note above.
  static Future<void> createAndroidAvd({
    required String name,
    required String systemImage,
    required String device,
    ProcessGateway? gateway,
  }) async {
    final gw = gateway ?? ProcessGateway();
    await gw.exec(
        'echo no | ${_avdmanager()} create avd -n "$name" -k "$systemImage" -d "$device"');
  }
}
