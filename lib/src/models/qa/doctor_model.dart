// Result types for the Doctor health checks (Phase 2).

enum DoctorStatus {
  /// Check passed — all good.
  pass,

  /// Non-blocking issue — tests can still run but something may be degraded.
  warn,

  /// Blocking issue — Run button stays disabled until this is fixed.
  fail,

  /// Check is currently running.
  checking,
}

/// A single Doctor check result.
class DoctorCheck {
  final String id;
  final String label;
  final DoctorStatus status;

  /// One-line hint shown when status is [DoctorStatus.warn] or [DoctorStatus.fail].
  final String? fixHint;

  /// Optional detail (e.g. the actual version found, or stderr output).
  final String? detail;

  /// A real, runnable shell command that fixes this check — set only where
  /// one genuinely exists unambiguously (e.g. `git checkout develop`,
  /// `git stash`). Null for anything needing human judgment (which Node
  /// version manager to use, which secrets go in a missing `.env` file,
  /// "add to PATH" — there's no one safe command for those), in which case
  /// the UI falls back to letting the user type + run their own.
  final String? fixCommand;

  /// Absolute working directory [fixCommand] should run in — the repo path
  /// for per-repo checks (git branch/dirty), null for machine-global fixes
  /// (installing a tool) where cwd doesn't matter.
  final String? fixCwd;

  /// When true the fix must be launched in the background (detached) rather
  /// than awaited — e.g. starting Appium, which blocks until it is killed.
  final bool fixIsBackground;

  const DoctorCheck({
    required this.id,
    required this.label,
    required this.status,
    this.fixHint,
    this.detail,
    this.fixCommand,
    this.fixCwd,
    this.fixIsBackground = false,
  });

  bool get isBlocking => status == DoctorStatus.fail;
  bool get isPassing => status == DoctorStatus.pass;

  DoctorCheck copyWith({
    DoctorStatus? status,
    String? fixHint,
    String? detail,
    String? fixCommand,
    String? fixCwd,
    bool? fixIsBackground,
  }) {
    return DoctorCheck(
      id: id,
      label: label,
      status: status ?? this.status,
      fixHint: fixHint ?? this.fixHint,
      detail: detail ?? this.detail,
      fixCommand: fixCommand ?? this.fixCommand,
      fixCwd: fixCwd ?? this.fixCwd,
      fixIsBackground: fixIsBackground ?? this.fixIsBackground,
    );
  }
}

/// Aggregated Doctor result for one recipe.
class DoctorResult {
  final String recipeId;
  final List<DoctorCheck> checks;
  final DateTime ranAt;

  const DoctorResult({
    required this.recipeId,
    required this.checks,
    required this.ranAt,
  });

  /// True when every check is [DoctorStatus.pass] or [DoctorStatus.warn]
  /// (no blocking failures).
  bool get isRunnable => checks.every((c) => !c.isBlocking);

  List<DoctorCheck> get failures =>
      checks.where((c) => c.status == DoctorStatus.fail).toList();

  List<DoctorCheck> get warnings =>
      checks.where((c) => c.status == DoctorStatus.warn).toList();
}
