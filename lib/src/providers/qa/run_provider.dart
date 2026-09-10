import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_boilerplate/src/base/dependencyinjection/locator.dart';
import 'package:flutter_boilerplate/src/base/qa/process_gateway.dart';
import 'package:flutter_boilerplate/src/models/qa/device_model.dart';
import 'package:flutter_boilerplate/src/base/qa/run_history_store.dart';
import 'package:flutter_boilerplate/src/base/qa/sleep_guard.dart';
import 'package:flutter_boilerplate/src/base/qa/step_runner.dart';
import 'package:flutter_boilerplate/src/base/utils/common_methods.dart';
import 'package:flutter_boilerplate/src/models/qa/machine_profile_model.dart';
import 'package:flutter_boilerplate/src/models/qa/manifest_model.dart';
import 'package:flutter_boilerplate/src/models/qa/run_model.dart';
import 'package:flutter_boilerplate/src/models/qa/run_record_model.dart';

/// One in-flight (or just-finished-but-not-yet-dismissed) pipeline run.
///
/// Fields here are mutated by [RunProvider] only — treat this as a read
/// model from anywhere else. Kept in [RunProvider]'s registry from the
/// moment [RunProvider.start] creates it until [RunProvider.reset] (or
/// [RunProvider.cancelAndWait]) removes it, which is what lets a finished
/// run's result stay visible in a panel until the user dismisses it — same
/// lifecycle the single-run version had, just per-entry now instead of
/// living directly on the provider.
class RunEntry {
  final String id;
  final String recipeId;
  final String recipeName;
  final DateTime startedAt;

  /// The device this run is bound to (mobile runs) — null for web, or for
  /// any run not yet wired to the device-selection flow. Backs
  /// [RunProvider.isDeviceBusy].
  final String? deviceUdid;

  /// Which project this run belongs to — null for [RunProvider.start] called
  /// directly without going through [RunDispatcher]. Threaded onto
  /// [RunRecord.projectId] at record time — see docs/RUN_EXPERIENCE_REDESIGN.md §9.
  final String? projectId;

  // ── Re-run metadata — all null unless dispatched via [RunDispatcher],
  // which is the only caller that actually knows these. Threaded onto
  // [RunRecord] at record time so a later "Re-run" action can pre-fill the
  // picker flow. See docs/RUN_EXPERIENCE_REDESIGN.md §9.
  final String? scriptDisplayName;
  final String? environmentId;
  final String? platform;
  final String? deviceKind;
  final String? mode;

  final SleepGuard sleepGuard;
  StepRunner? runner;
  final Completer<void> _doneCompleter = Completer<void>();

  RunStatus status = RunStatus.running;
  Duration? duration;

  final List<LogLine> logs = [];
  bool logsTruncated = false;
  String? currentStepName;
  int stepIndex = 0;
  int stepTotal = 0;
  final List<StepResult> stepResults = [];

  RunEntry({
    required this.id,
    required this.recipeId,
    required this.recipeName,
    required this.startedAt,
    this.deviceUdid,
    this.projectId,
    this.scriptDisplayName,
    this.environmentId,
    this.platform,
    this.deviceKind,
    this.mode,
    SleepGuard? sleepGuard,
  }) : sleepGuard = sleepGuard ?? SleepGuard();

  Duration get elapsed => duration ?? DateTime.now().difference(startedAt);
}

/// Live state of every pipeline run this app has in flight (or just
/// finished, until dismissed) — a registry, not a single slot, so multiple
/// surfaces/devices can run concurrently. See
/// docs/RUN_EXPERIENCE_REDESIGN.md §10 for why this is a registry and not a
/// singleton "current run" (the short version: device busy-status and a
/// multi-run progress screen both need to know about *every* active run,
/// not just one).
///
/// Everything that existed before this was a registry (`isRunning`,
/// `status`, `recipeId`, `logs`, ...) is kept as a computed view over the
/// *primary* entry (the most recently started one still in the registry) —
/// today's UI (the single global [RunPanel], per-surface cards) only ever
/// has at most one run active at a time anyway, since the call sites that
/// start a run still gate on the old single-run `isRunning` check. Those
/// getters exist unchanged so none of that UI needed to change; genuinely
/// concurrency-aware code (device busy-status, a future multi-run progress
/// screen) should use [activeRuns] / [isRunningFor] / [isDeviceBusy] instead.
class RunProvider extends ChangeNotifier {
  /// Keep memory bounded on a long WDIO run; the tail is what matters.
  static const int maxLogLines = 5000;

  /// Coalesce notifications — a chatty build can emit hundreds of lines a
  /// second and one rebuild per line would drop frames.
  static const Duration _notifyInterval = Duration(milliseconds: 100);

  Timer? _notifyTimer;

  RunProvider() {
    _history = RunHistoryStore.load();
  }

  // ── Registry ──────────────────────────────────────────────────────────────

  /// Insertion-ordered — iteration order is oldest-started first, so
  /// [_primary] (`.last`) is the most recently started entry.
  final Map<String, RunEntry> _activeRuns = {};

  /// Every run currently in the registry (running, or finished but not yet
  /// dismissed via [reset]).
  List<RunEntry> get activeRuns => List.unmodifiable(_activeRuns.values);

  RunEntry? _entry(String? runId) =>
      runId != null ? _activeRuns[runId] : _primary;

  RunEntry? get _primary =>
      _activeRuns.values.isEmpty ? null : _activeRuns.values.last;

  /// True if any active run is genuinely still running (not just present —
  /// a finished-but-not-yet-dismissed entry doesn't count) for [recipeId].
  /// Correct under concurrency, unlike the legacy [recipeId] check.
  bool isRunningFor(String recipeId) => _activeRuns.values
      .any((r) => r.recipeId == recipeId && r.status == RunStatus.running);

  /// The active run id currently running [recipeId], or null if none — lets
  /// callers target [cancel]/[sendInput] at exactly that run instead of
  /// falling back to the primary one.
  String? runIdFor(String recipeId) => _activeRuns.values
      .where((r) => r.recipeId == recipeId && r.status == RunStatus.running)
      .firstOrNull
      ?.id;

  /// True if [udid] is bound to any currently-running entry — the device
  /// picker (docs/RUN_EXPERIENCE_REDESIGN.md §11) uses this to exclude busy
  /// devices.
  bool isDeviceBusy(String udid) => _activeRuns.values
      .any((r) => r.status == RunStatus.running && r.deviceUdid == udid);

  // ── History ───────────────────────────────────────────────────────────────

  late List<RunRecord> _history;
  List<RunRecord> get history => List.unmodifiable(_history);

  /// Most recent completed run for [recipeId] that has a report to reopen,
  /// or null if none yet. Backs the recipe card's "Reopen last report" link.
  ///
  /// [projectId] scopes the match so two different projects with the same
  /// surface id (e.g. both have a `"web"` surface) don't see each other's
  /// history — omit it only for the legacy single-project screen, which has
  /// no project id to scope by. A record with no `projectId` on file (from
  /// before this fix) still matches when [projectId] is omitted, but not
  /// when one is given — it can't be reliably attributed to one project.
  RunRecord? lastReportFor(String recipeId, {String? projectId}) => _history
      .where((r) =>
          r.recipeId == recipeId &&
          r.hasReport &&
          (projectId == null || r.projectId == projectId))
      .firstOrNull;

  // ── Legacy single-run view (see class doc) ──────────────────────────────

  /// Null when idle (nothing has run, or the panel was dismissed).
  RunStatus? get status => _primary?.status;
  bool get isIdle => _activeRuns.isEmpty;
  bool get isRunning =>
      _activeRuns.values.any((r) => r.status == RunStatus.running);

  String? get recipeId => _primary?.recipeId;
  String? get recipeName => _primary?.recipeName;

  List<LogLine> get logs => List.unmodifiable(_primary?.logs ?? const []);
  bool get logsTruncated => _primary?.logsTruncated ?? false;

  String? get currentStepName => _primary?.currentStepName;
  int get stepIndex => _primary?.stepIndex ?? 0;
  int get stepTotal => _primary?.stepTotal ?? 0;
  List<StepResult> get stepResults =>
      List.unmodifiable(_primary?.stepResults ?? const []);

  DateTime? get startedAt => _primary?.startedAt;
  Duration? get duration => _primary?.duration;

  /// Elapsed time — live while running, final once done.
  Duration get elapsed => _primary?.elapsed ?? Duration.zero;

  // ── Panel minimize state ─────────────────────────────────────────────────
  // Pure UI state (not tied to any one run) — RunPanel is shown by every
  // screen it's embedded in as `Expanded(flex:, child: RunPanel())`, which
  // otherwise permanently reserves that flex share of the screen (running,
  // done, *or* failed) with no way to get at whatever's underneath. Lives
  // here, not as RunPanel's own State, so every embed site can check it in
  // the same `Consumer<RunProvider>` they already have, without RunPanel
  // needing to reach up into its parent's layout.

  bool _minimized = false;
  bool get minimized => _minimized;
  void toggleMinimized() {
    _minimized = !_minimized;
    notifyListeners();
  }

  // ── Start / cancel ────────────────────────────────────────────────────────

  String _newRunId() {
    final rng = Random();
    return '${DateTime.now().microsecondsSinceEpoch}-${rng.nextInt(1 << 32)}';
  }

  Future<String> start({
    required RecipeConfig recipe,
    required MachineProfile profile,
    required ManifestModel manifest,
    required bool syncEnabled,
    required bool buildEnabled,
    IosBuildTarget iosTarget = IosBuildTarget.simulator,
    /// Raw text from the recipe card's optional spec/flags field (Phase 6).
    String specFlags = '',
    /// The device this run is bound to (mobile runs) — see [RunEntry.deviceUdid].
    String? deviceUdid,
    /// Re-run/history metadata — see [RunEntry]'s matching fields. All
    /// optional; only [RunDispatcher] actually knows these today.
    String? projectId,
    String? scriptDisplayName,
    String? environmentId,
    String? platform,
    String? deviceKind,
    String? mode,
  }) async {
    // A fresh run should always show its live output by default — only the
    // user re-minimizing this specific run should hide it again.
    _minimized = false;
    final entry = RunEntry(
      id: _newRunId(),
      recipeId: recipe.id,
      recipeName: recipe.name,
      startedAt: DateTime.now(),
      deviceUdid: deviceUdid,
      projectId: projectId,
      scriptDisplayName: scriptDisplayName,
      environmentId: environmentId,
      platform: platform,
      deviceKind: deviceKind,
      mode: mode,
    );
    entry.stepTotal = recipe.stepsFor(iosTarget: iosTarget).length;
    _activeRuns[entry.id] = entry;
    notifyListeners();

    // Shared gateway (not a fresh ProcessGateway()) so MachineProfile's extra
    // PATH dirs — applied to the locator singleton by QAProvider — reach the
    // pipeline's actual commands, same as Doctor's checks. Safe to share
    // across concurrent runs: ProcessGateway carries no per-call mutable
    // state, only the cached-once PATH resolution and extraPathDirs.
    final runner = StepRunner(gateway: locator<ProcessGateway>());
    entry.runner = runner;
    await entry.sleepGuard.start();

    try {
      final result = await runner.run(
        recipe: recipe,
        profile: profile,
        manifest: manifest,
        syncEnabled: syncEnabled,
        buildEnabled: buildEnabled,
        iosTarget: iosTarget,
        specFlags: specFlags,
        deviceUdid: entry.deviceUdid,
        devicePlatform: _parsePlatform(entry.platform),
        deviceKind: _parseKind(entry.deviceKind),
        onLog: (line) => _appendLog(entry, line),
        onStepStart: (step, index, total) {
          entry.currentStepName = step.name;
          entry.stepIndex = index + 1;
          entry.stepTotal = total;
          _scheduleNotify();
        },
        onStepEnd: (result) {
          entry.stepResults.add(result);
          _scheduleNotify();
        },
      );
      entry.status = result.status;
      entry.duration = result.duration;
    } catch (e) {
      // StepRunner is written not to throw; this is the belt to its braces.
      _appendLog(entry, LogLine('✖ Pipeline error: $e', isError: true));
      entry.status = RunStatus.failed;
      entry.duration = DateTime.now().difference(entry.startedAt);
    } finally {
      entry.runner = null;
      entry.currentStepName = null;
      entry.sleepGuard.stop();
      await _recordHistory(entry, profile);
      _flushNotify();
      entry._doneCompleter.complete();
    }
    return entry.id;
  }

  /// Kill every active run and wait for cleanup (process group, sleep
  /// guard, history write) to finish for all of them. Used by
  /// [AppLifecycleObserver] on quit — a bare [cancel] only targets one run
  /// and returns immediately, before that cleanup has actually run.
  Future<void> cancelAndWait() async {
    final pending = _activeRuns.values
        .where((e) => e.status == RunStatus.running)
        .map((e) => e._doneCompleter.future)
        .toList();
    for (final entry in _activeRuns.values.toList()) {
      _cancelEntry(entry);
    }
    if (pending.isNotEmpty) await Future.wait(pending);
  }

  /// Write this run's full log to disk and append a [RunRecord] — survives
  /// both the 5000-line in-memory cap and the app quitting entirely.
  Future<void> _recordHistory(RunEntry entry, MachineProfile profile) async {
    final logPath = _writeLogFile(entry, profile);
    final record = RunRecord(
      recipeId: entry.recipeId,
      recipeName: entry.recipeName,
      startedAt: entry.startedAt,
      durationMs: (entry.duration ?? Duration.zero).inMilliseconds,
      status: entry.status.name,
      // The report-open step is always last — reaching RunStatus.done means
      // the pipeline ran every step including it, so a fresh report exists.
      hasReport: entry.status == RunStatus.done,
      logPath: logPath,
      projectId: entry.projectId,
      runId: entry.id,
      scriptDisplayName: entry.scriptDisplayName,
      environmentId: entry.environmentId,
      platform: entry.platform,
      deviceKind: entry.deviceKind,
      deviceUdid: entry.deviceUdid,
      mode: entry.mode,
    );

    try {
      await RunHistoryStore.append(record);
      _history = RunHistoryStore.load();
    } catch (e) {
      logger('RunProvider._recordHistory: failed to persist: $e');
    }
  }

  /// Best-effort — a missing docs/ folder (e.g. a widget test, or an
  /// installed .app moved away from a checkout) just means no log is kept.
  String? _writeLogFile(RunEntry entry, MachineProfile profile) {
    try {
      final dir = Directory('${profile.projectsRoot}/automation-testing/docs/run-logs');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final stamp =
          entry.startedAt.toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
      final file = File('${dir.path}/$stamp-${entry.recipeId}.log');
      file.writeAsStringSync(entry.logs.map((l) => l.text).join('\n'));
      return file.path;
    } catch (e) {
      logger('RunProvider._writeLogFile: $e');
      return null;
    }
  }

  /// Kill [runId]'s active step's process group and abort its pipeline — or
  /// the primary (most recently started) run if [runId] is omitted, so
  /// existing zero-arg call sites (`onPressed: run.cancel`) keep working.
  void cancel([String? runId]) {
    final entry = _entry(runId);
    if (entry == null || entry.status != RunStatus.running) return;
    _cancelEntry(entry);
  }

  void _cancelEntry(RunEntry entry) {
    if (entry.status != RunStatus.running) return;
    _appendLog(entry, LogLine('⏹ Cancelling…', isError: true));
    entry.runner?.cancel();
    _flushNotify();
  }

  /// Send [line] to [runId]'s (or the primary run's) current step's stdin —
  /// e.g. an OTP pasted for WDIO's blocking `readline` prompt. Echoed into
  /// that run's log so the panel shows what was sent (never what was
  /// received back — that's the child's problem).
  void sendInput(String line, {String? runId}) {
    final entry = _entry(runId);
    if (entry == null || entry.status != RunStatus.running || line.isEmpty) {
      return;
    }
    _appendLog(entry, LogLine('» $line', isError: false));
    entry.runner?.writeStdin(line);
  }

  /// Dismiss [runId] (or the primary run) — only when it isn't still
  /// running (removing an in-flight run's UI while its process tree is
  /// still alive would orphan it from Cancel; use [cancel] first).
  void reset([String? runId]) {
    final entry = _entry(runId);
    if (entry == null || entry.status == RunStatus.running) return;
    _activeRuns.remove(entry.id);
    _flushNotify();
  }

  // ── Log buffer ────────────────────────────────────────────────────────────

  void _appendLog(RunEntry entry, LogLine line) {
    entry.logs.add(line);
    if (entry.logs.length > maxLogLines) {
      entry.logs.removeRange(0, entry.logs.length - maxLogLines);
      entry.logsTruncated = true;
    }
    _scheduleNotify();
  }

  void _scheduleNotify() {
    if (_notifyTimer != null) return;
    _notifyTimer = Timer(_notifyInterval, _flushNotify);
  }

  void _flushNotify() {
    _notifyTimer?.cancel();
    _notifyTimer = null;
    notifyListeners();
  }

  // ── Device parsing helpers ─────────────────────────────────────────────────
  // RunEntry stores platform/kind as strings (for serialisation to history);
  // these convert them back to the typed enums StepRunner needs.

  static DevicePlatform? _parsePlatform(String? raw) => switch (raw) {
        'ios' => DevicePlatform.ios,
        'android' => DevicePlatform.android,
        _ => null,
      };

  static DeviceKind? _parseKind(String? raw) => switch (raw) {
        'simulator' => DeviceKind.simulator,
        'physical' => DeviceKind.physical,
        _ => null,
      };

  @override
  void dispose() {
    _notifyTimer?.cancel();
    for (final entry in _activeRuns.values) {
      entry.runner?.cancel();
      entry.sleepGuard.stop();
    }
    super.dispose();
  }
}
