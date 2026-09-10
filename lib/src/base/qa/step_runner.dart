import 'dart:async';
import 'dart:io';

import 'package:flutter_boilerplate/src/base/qa/appium_probe.dart';
import 'package:flutter_boilerplate/src/base/qa/device_probe.dart';
import 'package:flutter_boilerplate/src/base/qa/env_file_parser.dart';
import 'package:flutter_boilerplate/src/base/qa/process_gateway.dart';
import 'package:flutter_boilerplate/src/models/qa/device_model.dart';
import 'package:flutter_boilerplate/src/models/qa/machine_profile_model.dart';
import 'package:flutter_boilerplate/src/models/qa/manifest_model.dart';
import 'package:flutter_boilerplate/src/models/qa/run_model.dart';

/// Interprets a recipe's [StepConfig] list and executes it step by step.
///
/// The manifest is the source of truth — this class contains no per-recipe
/// branching. Adding a step means editing YAML, not this file.
///
/// Contract:
///   • Steps run strictly in order; the first terminal outcome aborts the rest.
///   • `skip_if_no_sync` / `skip_if_no_build` steps are reported as
///     [StepOutcome.skipped], not silently dropped.
///   • `env_file` vars are merged into that step's environment only.
///   • `detach: true` steps are fire-and-forget (the pipeline moves on).
///   • Never throws — I/O problems come back as a failed [StepResult].
class StepRunner {
  final ProcessGateway _gateway;

  /// Seam for tests — real runs always hit [AppiumProbe.isRunning].
  final Future<bool> Function() _isAppiumRunning;

  StepRunner({ProcessGateway? gateway, Future<bool> Function()? isAppiumRunning})
      : _gateway = gateway ?? ProcessGateway(),
        _isAppiumRunning = isAppiumRunning ?? AppiumProbe.isRunning;

  ProcessHandle? _current;
  bool _cancelled = false;

  /// Kill the running step and abort the pipeline.
  void cancel() {
    _cancelled = true;
    _current?.kill();
  }

  /// Forward a line of UI input to the running step's stdin — e.g. an OTP
  /// pasted for WDIO's `readline` prompt. A no-op if no step is running or
  /// the running step never reads stdin (harmless either way).
  void writeStdin(String line) => _current?.writeStdin(line);

  Future<PipelineResult> run({
    required RecipeConfig recipe,
    required MachineProfile profile,
    required ManifestModel manifest,
    required bool syncEnabled,
    required bool buildEnabled,
    IosBuildTarget iosTarget = IosBuildTarget.simulator,
    /// Raw text from the recipe card's optional spec/flags field (Phase 6).
    /// Empty/blank means "run everything" — the normal, unfiltered `command`.
    String specFlags = '',
    /// The device/simulator UDID picked by RunPicker at run time.  When set,
    /// it is injected into every step's env as IOS_SIMULATOR_UDID (simulator)
    /// / IOS_DEVICE_ID (physical iOS) / ANDROID_DEVICE_ID (Android),
    /// overriding whatever the .env.dev file says — so the test runner always
    /// gets the device the user actually chose, not whatever was last saved.
    String? deviceUdid,
    DevicePlatform? devicePlatform,
    DeviceKind? deviceKind,
    required void Function(LogLine line) onLog,
    required void Function(StepConfig step, int index, int total) onStepStart,
    required void Function(StepResult result) onStepEnd,
  }) async {
    _cancelled = false;
    final startedAt = DateTime.now();
    final steps = recipe.stepsFor(iosTarget: iosTarget);
    final results = <StepResult>[];
    final trimmedSpecFlags = specFlags.trim();

    // ── Build runtime device env overrides ──────────────────────────────────
    // The device was picked at Run time (RunPicker); inject its UDID into env
    // so WebdriverIO / Appium / any tool that reads UDID from env always gets
    // the device the user actually chose rather than whatever was in .env.dev.
    // These are overlaid after .env.dev is loaded in _runStep so they win.
    final Map<String, String> deviceEnv = {};
    if (deviceUdid != null && deviceUdid.isNotEmpty) {
      if (devicePlatform == DevicePlatform.ios) {
        if (deviceKind == DeviceKind.simulator) {
          deviceEnv['IOS_SIMULATOR_UDID'] = deviceUdid;
        } else {
          deviceEnv['IOS_DEVICE_ID'] = deviceUdid;
        }
      } else if (devicePlatform == DevicePlatform.android) {
        deviceEnv['ANDROID_DEVICE_ID'] = deviceUdid;
      }
    }

    // ── Auto-boot iOS simulator if needed ────────────────────────────────────
    // Doctor no longer checks for this because the device is picked at Run
    // time. Boot it automatically here instead of making the user do it.
    if (deviceUdid != null &&
        devicePlatform == DevicePlatform.ios &&
        deviceKind == DeviceKind.simulator) {
      try {
        final sims = await DeviceProbe.listIosSimulators();
        final sim = sims.where((s) => s.udid == deviceUdid).firstOrNull;
        if (sim != null && !sim.booted) {
          onLog(LogLine('  booting simulator $deviceUdid…', isError: false));
          await _gateway.exec('xcrun simctl boot $deviceUdid',
              ignoreExitCode: true);
          onLog(LogLine('  simulator booted', isError: false));
        }
      } catch (_) {
        // Best-effort — if boot fails the test itself will fail with a
        // clear "device not found" message, not a silent wrong-UDID error.
      }
    }

    onLog(LogLine(
      '▶ ${recipe.name} — ${steps.length} steps '
      '(sync: ${syncEnabled ? 'on' : 'off'}, '
      'build: ${buildEnabled ? 'on' : 'off'}'
      '${recipe.isIos ? ', target: ${iosTarget.label}' : ''})',
      isError: false,
    ));

    await _writeRunContext(
      profile: profile,
      manifest: manifest,
      recipe: recipe,
      status: 'running',
      startedAt: startedAt,
      syncEnabled: syncEnabled,
      buildEnabled: buildEnabled,
      steps: results,
    );

    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      onStepStart(step, i, steps.length);

      final result = await _runStep(
        step: step,
        profile: profile,
        manifest: manifest,
        syncEnabled: syncEnabled,
        buildEnabled: buildEnabled,
        specFlags: trimmedSpecFlags,
        deviceEnvOverrides: deviceEnv,
        onLog: onLog,
      );

      results.add(result);
      onStepEnd(result);

      if (result.outcome.isTerminal) break;
    }

    final status = _statusFrom(results);
    final duration = DateTime.now().difference(startedAt);

    onLog(LogLine(
      status == RunStatus.done
          ? '✔ ${recipe.name} finished in ${_fmt(duration)}'
          : '✖ ${recipe.name} ${status.name} after ${_fmt(duration)}',
      isError: status != RunStatus.done,
    ));

    await _writeRunContext(
      profile: profile,
      manifest: manifest,
      recipe: recipe,
      status: status.name,
      startedAt: startedAt,
      duration: duration,
      syncEnabled: syncEnabled,
      buildEnabled: buildEnabled,
      steps: results,
    );

    return PipelineResult(
      recipeId: recipe.id,
      status: status,
      steps: results,
      startedAt: startedAt,
      duration: duration,
    );
  }

  // ── One step ──────────────────────────────────────────────────────────────

  Future<StepResult> _runStep({
    required StepConfig step,
    required MachineProfile profile,
    required ManifestModel manifest,
    required bool syncEnabled,
    required bool buildEnabled,
    required String specFlags,
    /// Device env vars picked at Run time — merged on top of .env.dev so the
    /// chosen UDID always wins (e.g. IOS_SIMULATOR_UDID, ANDROID_DEVICE_ID).
    Map<String, String> deviceEnvOverrides = const {},
    required void Function(LogLine line) onLog,
  }) async {
    final began = DateTime.now();
    Duration elapsed() => DateTime.now().difference(began);

    if (_cancelled) {
      return StepResult(
        step: step,
        outcome: StepOutcome.cancelled,
        duration: elapsed(),
        note: 'Cancelled before start',
      );
    }

    // ── Skip flags ──
    if (step.skipIfNoSync && !syncEnabled) {
      onLog(LogLine('⤼ ${step.name} — skipped (Sync off)', isError: false));
      return StepResult(
        step: step,
        outcome: StepOutcome.skipped,
        duration: elapsed(),
        note: 'Sync toggle off',
      );
    }
    if (step.skipIfNoBuild && !buildEnabled) {
      onLog(LogLine('⤼ ${step.name} — skipped (Build+Install off)',
          isError: false));
      return StepResult(
        step: step,
        outcome: StepOutcome.skipped,
        duration: elapsed(),
        note: 'Build+Install toggle off',
      );
    }

    // ── Resolve cwd ──
    final relPath = manifest.repos[step.repo]?.relPath;
    if (relPath == null || relPath.isEmpty) {
      final note = 'Unknown repo "${step.repo}" — check manifest repos:';
      onLog(LogLine('✖ ${step.name} — $note', isError: true));
      return StepResult(
          step: step,
          outcome: StepOutcome.failed,
          duration: elapsed(),
          note: note);
    }

    final cwd = profile.repoPath(relPath);
    if (!Directory(cwd).existsSync()) {
      final note = 'Directory not found: $cwd';
      onLog(LogLine('✖ ${step.name} — $note', isError: true));
      return StepResult(
          step: step,
          outcome: StepOutcome.failed,
          duration: elapsed(),
          note: note);
    }

    // ── env_file injection ──
    Map<String, String>? env;
    if (step.envFile != null) {
      final envPath = '${profile.projectsRoot}/${step.envFile}';
      env = EnvFileParser.loadFile(envPath);
      if (env.isEmpty) {
        // Doctor already blocks on a missing .env.dev; warn and let the shell
        // fail loudly on the unresolved ${VAR} rather than guessing here.
        onLog(LogLine('⚠ ${step.name} — no vars read from $envPath',
            isError: true));
      } else {
        onLog(LogLine('  env: ${env.length} vars from ${step.envFile}',
            isError: false));
      }
    }

    // ── Device env overrides (runtime-picked UDID wins over .env.dev) ──────
    // Merge after .env.dev so IOS_SIMULATOR_UDID / ANDROID_DEVICE_ID from the
    // RunPicker always beats whatever was statically saved in the file.
    if (deviceEnvOverrides.isNotEmpty) {
      env = {...?env, ...deviceEnvOverrides};
      for (final kv in deviceEnvOverrides.entries) {
        onLog(LogLine('  env override: ${kv.key}=${kv.value}', isError: false));
      }
    }

    // ── Appium re-check ──
    // Doctor already required this before Run was enabled, but Build+Install
    // can run for minutes first — someone may have quit Appium since.
    if (step.checkAppium && !await _isAppiumRunning()) {
      const note = 'Appium is not responding at ${AppiumProbe.defaultBaseUrl}';
      onLog(LogLine('✖ ${step.name} — $note', isError: true));
      return StepResult(
        step: step,
        outcome: StepOutcome.failed,
        duration: elapsed(),
        note: note,
      );
    }

    // ── Spec filter (Phase 6) ──
    // Only the step declaring spec_command supports a filter; everything else
    // (sync, install, build, report) ignores whatever the user typed.
    final command = (specFlags.isNotEmpty && step.specCommand != null)
        ? step.specCommand!.replaceAll('{flags}', specFlags)
        : step.command;
    if (specFlags.isNotEmpty && step.specCommand != null) {
      onLog(LogLine('  spec filter: $specFlags', isError: false));
    }

    onLog(LogLine('\n\$ $command   [${step.repo}]', isError: false));

    // ── Detached (allure open) ──
    if (step.detach) {
      try {
        await _gateway.detach(command, workingDirectory: cwd, extraEnv: env);
        onLog(LogLine('  launched detached', isError: false));
        return StepResult(
            step: step, outcome: StepOutcome.success, duration: elapsed());
      } catch (e) {
        onLog(LogLine('✖ ${step.name} — $e', isError: true));
        return StepResult(
            step: step,
            outcome: StepOutcome.failed,
            duration: elapsed(),
            note: e.toString());
      }
    }

    // ── Streamed ──
    final handle = ProcessHandle();
    _current = handle;

    var timedOut = false;
    Timer? timer;
    if (step.timeoutSeconds != null) {
      timer = Timer(Duration(seconds: step.timeoutSeconds!), () {
        timedOut = true;
        onLog(LogLine('⏱ ${step.name} — timeout after ${step.timeoutSeconds}s, killing',
            isError: true));
        handle.kill();
      });
    }

    try {
      await for (final line in _gateway.stream(
        command,
        workingDirectory: cwd,
        extraEnv: env,
        handle: handle,
      )) {
        onLog(line);
      }
    } catch (e) {
      timer?.cancel();
      _current = null;
      onLog(LogLine('✖ ${step.name} — $e', isError: true));
      return StepResult(
          step: step,
          outcome: StepOutcome.failed,
          duration: elapsed(),
          note: e.toString());
    }

    timer?.cancel();
    _current = null;

    final exit = handle.exitCode;

    if (_cancelled) {
      return StepResult(
        step: step,
        outcome: StepOutcome.cancelled,
        exitCode: exit,
        duration: elapsed(),
        note: 'Cancelled by user',
      );
    }
    if (timedOut) {
      return StepResult(
        step: step,
        outcome: StepOutcome.timedOut,
        exitCode: exit,
        duration: elapsed(),
        note: 'Exceeded ${step.timeoutSeconds}s',
      );
    }
    if (exit != 0) {
      onLog(LogLine('✖ ${step.name} — exit $exit', isError: true));
      return StepResult(
        step: step,
        outcome: StepOutcome.failed,
        exitCode: exit,
        duration: elapsed(),
        note: 'Exit code $exit',
      );
    }

    onLog(LogLine('✔ ${step.name} — ${_fmt(elapsed())}', isError: false));
    return StepResult(
      step: step,
      outcome: StepOutcome.success,
      exitCode: exit,
      duration: elapsed(),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static RunStatus _statusFrom(List<StepResult> results) {
    for (final r in results) {
      if (r.outcome == StepOutcome.cancelled) return RunStatus.cancelled;
      if (r.outcome.isTerminal) return RunStatus.failed;
    }
    return RunStatus.done;
  }

  static String _fmt(Duration d) {
    if (d.inMinutes < 1) return '${d.inSeconds}s';
    return '${d.inMinutes}m ${d.inSeconds % 60}s';
  }

  // ── docs/RUN_CONTEXT.md ───────────────────────────────────────────────────

  /// Writes a snapshot a future session can read to see what happened last run.
  ///
  /// ponytail: the control-center repo's own path is derived by name from the
  /// Projects root rather than plumbed through the manifest. Silently skipped
  /// if that docs/ folder isn't there (e.g. widget tests, installed .app).
  /// Add a `self:` repo entry to centurion.yaml if the folder ever moves.
  Future<void> _writeRunContext({
    required MachineProfile profile,
    required ManifestModel manifest,
    required RecipeConfig recipe,
    required String status,
    required DateTime startedAt,
    required bool syncEnabled,
    required bool buildEnabled,
    required List<StepResult> steps,
    Duration? duration,
  }) async {
    final docsDir = Directory('${profile.projectsRoot}/automation-testing/docs');
    if (!docsDir.existsSync()) return;

    final shaRows = <String>[];
    for (final entry in manifest.repos.entries) {
      final path = profile.repoPath(entry.value.relPath);
      if (!Directory(path).existsSync()) {
        shaRows.add('| ${entry.value.relPath} | — | not found |');
        continue;
      }
      final branch = await _gitOrDash(path, 'git branch --show-current');
      final sha = await _gitOrDash(path, 'git rev-parse --short HEAD');
      shaRows.add('| ${entry.value.relPath} | $branch | $sha |');
    }

    final stepRows = steps.isEmpty
        ? ['| — | — | — |']
        : steps
            .map((s) =>
                '| ${s.step.id} | ${s.outcome.name} | ${_fmt(s.duration)}'
                '${s.note != null ? ' — ${s.note}' : ''} |')
            .toList();

    final report = steps.any((s) =>
            s.step.detach && s.outcome == StepOutcome.success)
        ? 'Allure report opened by `${steps.firstWhere((s) => s.step.detach).step.command}`'
        : 'No report opened.';

    final content = '''
# Run Context

Auto-updated by the QA Control Center before and after each pipeline run.
A future session reads this to understand what happened last time and whether re-running makes sense.

*Written by `StepRunner._writeRunContext` — do not edit by hand.*

---

## Last run

| Field | Value |
|---|---|
| Surface | ${recipe.name} (`${recipe.id}`) |
| Environment | ${manifest.environment} |
| Status | $status |
| Started | ${startedAt.toIso8601String()} |
| Duration | ${duration == null ? 'in progress' : _fmt(duration)} |
| Sync enabled | $syncEnabled |
| Build+Install enabled | $buildEnabled |

## Repo SHAs at run time

| Repo | Branch | SHA |
|---|---|---|
${shaRows.join('\n')}

## Step log

| Step | Outcome | Duration |
|---|---|---|
${stepRows.join('\n')}

## Report location

$report
''';

    try {
      File('${docsDir.path}/RUN_CONTEXT.md').writeAsStringSync(content);
    } catch (_) {
      // Never let a context-file write break a pipeline run.
    }
  }

  Future<String> _gitOrDash(String cwd, String cmd) async {
    try {
      final out = await _gateway.exec(cmd, workingDirectory: cwd, ignoreExitCode: true);
      return out.isEmpty ? '—' : out;
    } catch (_) {
      return '—';
    }
  }
}
