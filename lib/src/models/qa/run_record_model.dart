import 'package:json_annotation/json_annotation.dart';

part 'run_record_model.g.dart';

/// One completed (or cancelled/failed) pipeline run, persisted so the History
/// panel survives an app restart. Deliberately thin — enough to show "what
/// happened last time" and to re-open its Allure report / log file, not a
/// full audit trail.
@JsonSerializable(includeIfNull: false, explicitToJson: true)
class RunRecord {
  final String recipeId;
  final String recipeName;
  final DateTime startedAt;
  final int durationMs;

  /// [RunStatus.name] — kept as a plain string so this model doesn't need to
  /// import run_model.dart just for one enum.
  final String status;

  /// True when the pipeline reached its final (detached) report-open step.
  @JsonKey(defaultValue: false)
  final bool hasReport;

  /// Path to this run's full log. Null if the write failed or was skipped.
  final String? logPath;

  /// Which project this run belongs to — null for runs recorded before this
  /// field existed. Fixes the cross-project run-history mixing bug where two
  /// projects with the same surface id (e.g. `"web"`) showed each other's
  /// history. See docs/RUN_EXPERIENCE_REDESIGN.md §9.
  final String? projectId;

  /// The run id [RunProvider.start] returned — same identity
  /// [ReportArchive.runId] uses, so the two can be joined.
  final String? runId;

  // ── Re-run metadata ────────────────────────────────────────────────────────

  /// [ScriptEntry.displayName] at run time — plain text, not a live reference.
  final String? scriptDisplayName;
  final String? environmentId;

  /// `"android"` | `"ios"` | null (web, or not applicable).
  final String? platform;

  /// `"simulator"` | `"physical"` | null.
  final String? deviceKind;
  final String? deviceUdid;

  /// `"run"` | `"pullAndRun"` | `"buildAndRun"` | null.
  final String? mode;

  const RunRecord({
    required this.recipeId,
    required this.recipeName,
    required this.startedAt,
    required this.durationMs,
    required this.status,
    this.hasReport = false,
    this.logPath,
    this.projectId,
    this.runId,
    this.scriptDisplayName,
    this.environmentId,
    this.platform,
    this.deviceKind,
    this.deviceUdid,
    this.mode,
  });

  Duration get duration => Duration(milliseconds: durationMs);

  /// True if there's enough on file to re-open the run picker pre-filled.
  bool get hasRerunInfo => environmentId != null;

  factory RunRecord.fromJson(Map<String, dynamic> json) =>
      _$RunRecordFromJson(json);

  Map<String, dynamic> toJson() => _$RunRecordToJson(this);
}
