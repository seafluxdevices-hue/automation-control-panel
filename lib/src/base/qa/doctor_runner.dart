import 'dart:io';

import 'package:flutter_boilerplate/src/base/qa/appium_probe.dart';
import 'package:flutter_boilerplate/src/base/qa/env_file_parser.dart';
import 'package:flutter_boilerplate/src/base/qa/process_gateway.dart';
import 'package:flutter_boilerplate/src/models/qa/doctor_model.dart';
import 'package:flutter_boilerplate/src/models/qa/machine_profile_model.dart';
import 'package:flutter_boilerplate/src/models/qa/manifest_model.dart';

// All Doctor check logic.
//
// Every method is static and returns a DoctorCheck — it never throws.
// Checks within a surface run concurrently via Future.wait.
// The iOS checks branch on IosBuildTarget so the panel reflects the active toggle.

class DoctorRunner {
  // ── Public entry point ─────────────────────────────────────────────────────

  static Future<DoctorResult> run({
    required RecipeConfig recipe,
    required MachineProfile profile,
    required ManifestModel manifest,
    IosBuildTarget iosTarget = IosBuildTarget.simulator,
    required ProcessGateway gateway,
  }) async {
    final futures = <Future<DoctorCheck>>[];

    // 1. Repo existence + git state (shared, parallel)
    for (final repoKey in _reposForRecipe(recipe)) {
      final repo = manifest.repos[repoKey];
      if (repo == null) continue;
      final absPath = profile.repoPath(repo.relPath);

      futures.add(_checkRepoDirExists(repoKey, absPath));
      futures.add(_checkRepoBranch(repoKey, absPath, repo.branch, gateway));
      futures.add(_checkRepoClean(repoKey, absPath, gateway));
    }

    // 2. Surface-specific (parallel)
    if (recipe.isWeb) {
      futures.addAll(_webChecks(profile, manifest, gateway));
    } else if (recipe.isIos) {
      futures.addAll(_mobileSharedChecks(profile, manifest, gateway));
      futures.addAll(_iosChecks(profile, manifest, iosTarget, gateway));
    } else if (recipe.isAndroid) {
      futures.addAll(_mobileSharedChecks(profile, manifest, gateway));
      futures.addAll(_androidChecks(gateway));
    }

    final checks = await Future.wait(futures);
    return DoctorResult(recipeId: recipe.id, checks: checks, ranAt: DateTime.now());
  }

  // ── Repo sets per recipe ───────────────────────────────────────────────────

  static List<String> _reposForRecipe(RecipeConfig recipe) {
    // Both role-name conventions listed — the caller skips whichever pair
    // doesn't exist on this project (`repo == null` → continue), so this
    // supports a newly-created Centurion project (mobile_ui/mobile_test)
    // and an already-saved one from before that rename (app/mobile_tests)
    // without picking one and breaking the other. Keyed by platformType
    // (not the raw surface id string) so a custom-named surface like
    // `android_stage` still gets the right repo checks.
    return switch (recipe.platformType) {
      'web' => ['web'],
      'ios' || 'android' => ['mobile_ui', 'app', 'mobile_test', 'mobile_tests'],
      _ => [],
    };
  }

  /// Same both-conventions fallback as [_reposForRecipe], for the two
  /// direct `manifest.repos[...]` lookups below that don't go through it.
  static RepoConfig? _mobileTestsRepo(ManifestModel manifest) =>
      manifest.repos['mobile_test'] ?? manifest.repos['mobile_tests'];

  // ── Web checks ─────────────────────────────────────────────────────────────

  static List<Future<DoctorCheck>> _webChecks(
    MachineProfile profile,
    ManifestModel manifest,
    ProcessGateway gateway,
  ) {
    final webPath = profile.repoPath(manifest.repos['web']?.relPath ?? '');
    return [
      _checkNodeVersion(minMajor: 22, gateway: gateway),
      _checkBinary(
        id: 'yarn',
        label: 'Yarn on PATH',
        versionCmd: 'yarn --version',
        fixHint: 'Install Yarn: npm install -g yarn',
        fixCommand: 'npm install -g yarn',
        gateway: gateway,
      ),
      _checkFileExists(
        id: 'web_env_dev',
        label: '.env.dev present in web repo',
        path: '$webPath/.env.dev',
        fixHint: 'Copy from .env.dev.example or ask the team',
      ),
      _checkFileExists(
        id: 'web_env_test',
        label: '.env.test present in web repo',
        path: '$webPath/.env.test',
        fixHint: 'Copy from .env.test.example or ask the team',
      ),
      _checkPlaywrightBrowsers(webPath, gateway),
      _checkPortFree(3000),
    ];
  }

  // ── Mobile shared checks (iOS + Android) ─────────────────────────────────

  static List<Future<DoctorCheck>> _mobileSharedChecks(
    MachineProfile profile,
    ManifestModel manifest,
    ProcessGateway gateway,
  ) {
    final testsPath =
        profile.repoPath(_mobileTestsRepo(manifest)?.relPath ?? '');
    return [
      _checkNodeVersion(minMajor: 20, gateway: gateway),
      _checkBinary(
        id: 'npm',
        label: 'npm on PATH',
        versionCmd: 'npm --version',
        fixHint: 'Install Node ≥ 20 from nodejs.org',
        gateway: gateway,
      ),
      _checkFileExists(
        id: 'mobile_env_dev',
        label: '.env.dev present in mobile_tests repo',
        path: '$testsPath/.env.dev',
        fixHint: 'Copy from .env.example and fill in UDID + credentials',
      ),
      _checkAppium('http://127.0.0.1:4723'),
      _checkBinary(
        id: 'flutter',
        label: 'Flutter on PATH (needed for build)',
        versionCmd: 'flutter --version',
        fixHint: 'Add flutter/bin to PATH',
        gateway: gateway,
      ),
      _checkJava(gateway),
    ];
  }

  // ── iOS checks ─────────────────────────────────────────────────────────────

  static List<Future<DoctorCheck>> _iosChecks(
    MachineProfile profile,
    ManifestModel manifest,
    IosBuildTarget target,
    ProcessGateway gateway,
  ) {
    final testsPath =
        profile.repoPath(_mobileTestsRepo(manifest)?.relPath ?? '');
    final envVars = EnvFileParser.loadFile('$testsPath/.env.dev');

    // Simulator UDID and booted-state checks are intentionally absent here:
    // the device is picked at Run time by the RunPicker and injected as
    // IOS_SIMULATOR_UDID at that point — requiring it to be pre-configured
    // in .env.dev was a design flaw (wrong UDID = silent test failure on a
    // device the user never meant to pick). Xcode + simctl availability is
    // enough to know simulators can be used.
    return switch (target) {
      IosBuildTarget.simulator => const [],
      IosBuildTarget.device => [
          _checkEnvVar(
            id: 'ios_device_id',
            label: 'IOS_DEVICE_ID set in .env.dev',
            varName: 'IOS_DEVICE_ID',
            env: envVars,
            fixHint:
                'Add IOS_DEVICE_ID=<udid> to mobile_tests/.env.dev (use Xcode → Devices)',
          ),
          _checkEnvVar(
            id: 'ios_xcode_org',
            label: 'IOS_XCODE_ORG_ID set in .env.dev',
            varName: 'IOS_XCODE_ORG_ID',
            env: envVars,
            fixHint:
                'Add IOS_XCODE_ORG_ID=<team-id> from Apple Developer portal',
          ),
          _checkIosDeviceConnected(
              envVars['IOS_DEVICE_ID'] ?? '', gateway),
          _checkXcodeNotRunning(gateway),
        ],
    };
  }

  // ── Android checks ─────────────────────────────────────────────────────────

  static List<Future<DoctorCheck>> _androidChecks(ProcessGateway gateway) {
    return [
      _checkBinary(
        id: 'adb',
        label: 'adb on PATH',
        versionCmd: 'adb version',
        fixHint: 'Install Android SDK Platform Tools and add to PATH',
        gateway: gateway,
      ),
      _checkAndroidDevice(gateway),
    ];
  }

  // ── Individual checks ─────────────────────────────────────────────────────

  /// Repo directory exists on disk.
  static Future<DoctorCheck> _checkRepoDirExists(
      String repoKey, String absPath) async {
    final exists = Directory(absPath).existsSync();
    return DoctorCheck(
      id: 'repo_exists_$repoKey',
      label: '$repoKey repo found',
      status: exists ? DoctorStatus.pass : DoctorStatus.fail,
      detail: absPath,
      fixHint: exists
          ? null
          : 'Clone the repo into $absPath  or re-run Setup with the correct Projects folder',
    );
  }

  /// Repo is on the expected branch (warns rather than fails — user may be on a feature branch).
  static Future<DoctorCheck> _checkRepoBranch(
    String repoKey,
    String absPath,
    String expectedBranch,
    ProcessGateway gateway,
  ) async {
    if (!Directory(absPath).existsSync()) {
      return DoctorCheck(
        id: 'repo_branch_$repoKey',
        label: '$repoKey on $expectedBranch',
        status: DoctorStatus.fail,
        fixHint: 'Repo not found — fix the exists check first',
      );
    }
    try {
      final branch = await gateway.exec(
        'git branch --show-current',
        workingDirectory: absPath,
      );
      final on = branch.trim() == expectedBranch;
      return DoctorCheck(
        id: 'repo_branch_$repoKey',
        label: '$repoKey on $expectedBranch',
        status: on ? DoctorStatus.pass : DoctorStatus.warn,
        detail: 'current branch: $branch',
        fixHint: on ? null : 'git checkout $expectedBranch',
        fixCommand: on ? null : 'git checkout $expectedBranch',
        fixCwd: on ? null : absPath,
      );
    } catch (e) {
      return DoctorCheck(
        id: 'repo_branch_$repoKey',
        label: '$repoKey on $expectedBranch',
        status: DoctorStatus.warn,
        fixHint: 'Could not read branch — is $absPath a git repo?',
        detail: e.toString(),
      );
    }
  }

  /// Repo has no uncommitted changes — a heads-up, not a blocker: dirty
  /// often just means "I'm mid-edit on this repo right now," which
  /// shouldn't stop Doctor from passing or Run from being enabled.
  static Future<DoctorCheck> _checkRepoClean(
    String repoKey,
    String absPath,
    ProcessGateway gateway,
  ) async {
    if (!Directory(absPath).existsSync()) {
      return DoctorCheck(
        id: 'repo_clean_$repoKey',
        label: '$repoKey working tree clean',
        status: DoctorStatus.fail,
        fixHint: 'Repo not found — fix the exists check first',
      );
    }
    try {
      final output = await gateway.exec(
        'git status --porcelain',
        workingDirectory: absPath,
      );
      final clean = output.trim().isEmpty;
      return DoctorCheck(
        id: 'repo_clean_$repoKey',
        label: '$repoKey working tree clean',
        status: clean ? DoctorStatus.pass : DoctorStatus.warn,
        detail: clean ? null : output.trim().split('\n').take(3).join('\n'),
        fixHint:
            clean ? null : 'Commit or stash changes: git stash',
        fixCommand: clean ? null : 'git stash',
        fixCwd: clean ? null : absPath,
      );
    } catch (e) {
      return DoctorCheck(
        id: 'repo_clean_$repoKey',
        label: '$repoKey working tree clean',
        status: DoctorStatus.warn,
        detail: e.toString(),
      );
    }
  }

  /// Node.js version check — fails if below minMajor.
  static Future<DoctorCheck> _checkNodeVersion({
    required int minMajor,
    required ProcessGateway gateway,
  }) async {
    // Reads nvm.sh straight from its standard install path — deliberately
    // NOT relying on .zshrc/.zprofile to have sourced it correctly, since
    // that's exactly the kind of per-machine shell-config drift that caused
    // this check to fail in the first place (nvm's own `default` alias can
    // point at an uninstalled version, a doubled nvm.sh source can leave
    // stale state, etc.) — this fixCommand is self-contained on purpose.
    // `nvm install <major>` installs the latest release of that major line
    // if missing (else just switches to it); `alias default` makes it stick
    // for future shells too, not just this one subprocess.
    final fixCommand = 'export NVM_DIR="\$HOME/.nvm"; '
        '[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"; '
        'command -v nvm >/dev/null 2>&1 || { '
        'echo "nvm not found — install Node $minMajor+ yourself, e.g. from nodejs.org or via nvm" >&2; exit 1; '
        '}; '
        'nvm install $minMajor && nvm alias default $minMajor && nvm use $minMajor';

    try {
      final raw = await gateway.exec('node --version', ignoreExitCode: true);
      // raw = "v22.3.0"
      final ver = raw.trim().replaceFirst('v', '');
      final major = int.tryParse(ver.split('.').first) ?? 0;
      final ok = major >= minMajor;
      return DoctorCheck(
        id: 'node_version',
        label: 'Node ≥ $minMajor on PATH',
        status: ok ? DoctorStatus.pass : DoctorStatus.fail,
        detail: raw.trim(),
        fixHint: ok
            ? null
            : 'Install Node $minMajor+ from nodejs.org or via nvm',
        fixCommand: ok ? null : fixCommand,
      );
    } catch (_) {
      return DoctorCheck(
        id: 'node_version',
        label: 'Node ≥ $minMajor on PATH',
        status: DoctorStatus.fail,
        fixHint: 'Install Node $minMajor+ from nodejs.org or via nvm',
        fixCommand: fixCommand,
      );
    }
  }

  /// Generic "binary exists" check — runs `versionCmd` and treats any output as a pass.
  static Future<DoctorCheck> _checkBinary({
    required String id,
    required String label,
    required String versionCmd,
    required String fixHint,
    required ProcessGateway gateway,
    // Only set where a single install command is genuinely safe/standard —
    // e.g. yarn via npm. Null for things like "add flutter/bin to PATH",
    // where there's no one command that fixes it on every machine.
    String? fixCommand,
  }) async {
    try {
      final ver = await gateway.exec(versionCmd, ignoreExitCode: true);
      final found = ver.trim().isNotEmpty;
      return DoctorCheck(
        id: id,
        label: label,
        status: found ? DoctorStatus.pass : DoctorStatus.fail,
        detail: ver.trim().split('\n').first,
        fixHint: found ? null : fixHint,
        fixCommand: found ? null : fixCommand,
      );
    } catch (_) {
      return DoctorCheck(
        id: id,
        label: label,
        status: DoctorStatus.fail,
        fixHint: fixHint,
        fixCommand: fixCommand,
      );
    }
  }

  /// Java version — warn (not fail) since it's only needed for Allure reporting.
  static Future<DoctorCheck> _checkJava(ProcessGateway gateway) async {
    try {
      // java -version writes to stderr
      final ver = await gateway.exec(
        'java -version 2>&1',
        ignoreExitCode: true,
      );
      final found = ver.trim().isNotEmpty;
      return DoctorCheck(
        id: 'java',
        label: 'Java on PATH (Allure)',
        status: found ? DoctorStatus.pass : DoctorStatus.warn,
        detail: ver.trim().split('\n').first,
        fixHint:
            found ? null : 'Install Java 11+: brew install openjdk@11',
        fixCommand: found ? null : 'brew install openjdk@11',
      );
    } catch (_) {
      return DoctorCheck(
        id: 'java',
        label: 'Java on PATH (Allure)',
        status: DoctorStatus.warn,
        fixHint: 'Install Java 11+: brew install openjdk@11',
        fixCommand: 'brew install openjdk@11',
      );
    }
  }

  /// File / directory existence check.
  static Future<DoctorCheck> _checkFileExists({
    required String id,
    required String label,
    required String path,
    required String fixHint,
  }) async {
    final exists = File(path).existsSync();
    return DoctorCheck(
      id: id,
      label: label,
      status: exists ? DoctorStatus.pass : DoctorStatus.fail,
      detail: path,
      fixHint: exists ? null : fixHint,
    );
  }

  /// Port availability — warn (Playwright starts its own dev server, so port 3000 busy is a warning).
  static Future<DoctorCheck> _checkPortFree(int port) async {
    try {
      final server = await ServerSocket.bind(
          InternetAddress.loopbackIPv4, port,
          shared: false);
      await server.close();
      return DoctorCheck(
        id: 'port_$port',
        label: 'Port $port free',
        status: DoctorStatus.pass,
      );
    } catch (_) {
      return DoctorCheck(
        id: 'port_$port',
        label: 'Port $port free',
        status: DoctorStatus.warn,
        fixHint: 'Port $port is busy. Kill it: lsof -ti:$port | xargs kill',
        fixCommand: 'lsof -ti:$port | xargs kill',
      );
    }
  }

  /// Playwright Chromium browser is installed on disk (web tests only).
  ///
  /// The check runs `playwright --version` first (fast, binary-presence gate),
  /// then `npx playwright install --dry-run` to ask Playwright itself whether
  /// the browser binary it actually needs is present — this matches exactly
  /// what Playwright checks at `browserType.launch`, so the error the user
  /// sees in test output disappears after the Fix button runs.
  static Future<DoctorCheck> _checkPlaywrightBrowsers(
    String webPath,
    ProcessGateway gateway,
  ) async {
    const id = 'playwright_browsers';
    const label = 'Playwright Chromium installed';

    // 1. Is playwright even available?
    try {
      await gateway.exec('npx playwright --version',
          workingDirectory: webPath, ignoreExitCode: true);
    } catch (_) {
      return const DoctorCheck(
        id: id,
        label: label,
        status: DoctorStatus.fail,
        fixHint: 'Run: yarn playwright install chromium',
        fixCommand: 'yarn playwright install chromium',
      );
    }

    // 2. Check whether chromium is installed.
    //    `playwright install --dry-run` prints what it *would* install;
    //    if output is empty the browsers are already present.
    try {
      // Simpler: just check if the Chromium binary dir exists.
      final out = await gateway.exec(
        'npx playwright install --dry-run chromium 2>&1 || true',
        workingDirectory: webPath,
        ignoreExitCode: true,
      );
      // "Playwright will download…" appears when browsers are missing.
      final missing = out.contains('Playwright will download') ||
          out.contains('Executable doesn');
      return DoctorCheck(
        id: id,
        label: label,
        status: missing ? DoctorStatus.fail : DoctorStatus.pass,
        detail: missing ? 'Chromium not installed' : 'Chromium ready',
        fixHint: missing ? 'Run: yarn playwright install chromium' : null,
        fixCommand: missing ? 'yarn playwright install chromium' : null,
        fixCwd: missing ? webPath : null,
      );
    } catch (e) {
      return DoctorCheck(
        id: id,
        label: label,
        status: DoctorStatus.fail,
        detail: e.toString().split('\n').first,
        fixHint: 'Run: yarn playwright install chromium',
        fixCommand: 'yarn playwright install chromium',
        fixCwd: webPath,
      );
    }
  }

  /// Appium health-check via HTTP GET /status. Shares its HTTP logic with the
  /// in-pipeline re-check in [StepRunner] via [AppiumProbe].
  static Future<DoctorCheck> _checkAppium(String baseUrl) async {
    const id = 'appium';
    const label = 'Appium running';
    const fixHint = 'Start Appium in a separate terminal: appium --port 4723';
    final running = await AppiumProbe.isRunning(baseUrl: baseUrl);
    if (running) {
      return DoctorCheck(
        id: id,
        label: label,
        status: DoctorStatus.pass,
        detail: baseUrl,
      );
    }
    return DoctorCheck(
      id: id,
      label: label,
      status: DoctorStatus.fail,
      fixHint: fixHint,
      detail: 'No response from $baseUrl/status',
      // Appium is a long-running server — launch it detached so the fix
      // button doesn't block waiting for a process that never exits.
      fixCommand: 'appium --port 4723',
      fixIsBackground: true,
    );
  }

  /// Check a required env var is set in the parsed env map.
  static Future<DoctorCheck> _checkEnvVar({
    required String id,
    required String label,
    required String varName,
    required Map<String, String> env,
    required String fixHint,
  }) async {
    final val = env[varName];
    final set = val != null && val.isNotEmpty;
    return DoctorCheck(
      id: id,
      label: label,
      status: set ? DoctorStatus.pass : DoctorStatus.fail,
      detail: set ? '$varName=<set>' : '$varName not set',
      fixHint: set ? null : fixHint,
    );
  }

  /// Real iOS device connected and trusted (devicectl).
  static Future<DoctorCheck> _checkIosDeviceConnected(
    String deviceId,
    ProcessGateway gateway,
  ) async {
    const id = 'ios_device_connected';
    const label = 'iOS device connected';
    if (deviceId.isEmpty) {
      return const DoctorCheck(
        id: id,
        label: label,
        status: DoctorStatus.fail,
        fixHint: 'IOS_DEVICE_ID is not set — see check above',
      );
    }
    try {
      final out = await gateway.exec(
        'xcrun devicectl list devices 2>&1',
        ignoreExitCode: true,
      );
      final found = out.contains(deviceId);
      return DoctorCheck(
        id: id,
        label: label,
        status: found ? DoctorStatus.pass : DoctorStatus.fail,
        detail: found ? 'UDID: $deviceId' : 'Device $deviceId not listed',
        fixHint: found
            ? null
            : 'Connect the device via USB and unlock it; trust this Mac when prompted',
      );
    } catch (e) {
      return DoctorCheck(
        id: id,
        label: label,
        status: DoctorStatus.fail,
        detail: e.toString().split('\n').first,
        fixHint: 'xcrun devicectl failed — requires Xcode 15+',
      );
    }
  }

  /// Xcode must not be running during a device build (can hold signing locks).
  static Future<DoctorCheck> _checkXcodeNotRunning(
      ProcessGateway gateway) async {
    try {
      final out = await gateway.exec(
        'pgrep -x Xcode',
        ignoreExitCode: true,
      );
      final running = out.trim().isNotEmpty;
      return DoctorCheck(
        id: 'xcode_not_running',
        label: 'Xcode not open',
        status: running ? DoctorStatus.warn : DoctorStatus.pass,
        fixHint: running
            ? 'Xcode is open — it may conflict with the build. Quit Xcode.'
            : null,
      );
    } catch (_) {
      return const DoctorCheck(
        id: 'xcode_not_running',
        label: 'Xcode not open',
        status: DoctorStatus.pass,
      );
    }
  }

  /// At least one adb Android device/emulator is connected.
  static Future<DoctorCheck> _checkAndroidDevice(
      ProcessGateway gateway) async {
    try {
      final out = await gateway.exec('adb devices', ignoreExitCode: true);
      // Output: "List of devices attached\n<udid>\tdevice\n..."
      final hasDevice = RegExp(r'\t(device|emulator)').hasMatch(out);
      return DoctorCheck(
        id: 'android_device',
        label: 'Android device / emulator connected',
        status: hasDevice ? DoctorStatus.pass : DoctorStatus.fail,
        detail: hasDevice ? null : out.trim(),
        fixHint: hasDevice
            ? null
            : 'Connect a device via USB (with USB debugging on) or start an emulator',
      );
    } catch (_) {
      return const DoctorCheck(
        id: 'android_device',
        label: 'Android device / emulator connected',
        status: DoctorStatus.fail,
        fixHint: 'adb not found — install Android SDK Platform Tools',
      );
    }
  }
}
