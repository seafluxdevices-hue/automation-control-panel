import 'dart:convert';
import 'dart:math';

import 'package:flutter_boilerplate/src/models/qa/machine_profile_model.dart';
import 'package:flutter_boilerplate/src/models/qa/manifest_model.dart';
import 'package:json_annotation/json_annotation.dart';

part 'project_model.g.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Generates a simple UUID-v4-like id without an external package.
String generateProjectId() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant
  String hex(int b) => b.toRadixString(16).padLeft(2, '0');
  final h = bytes.map(hex).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// Safe DateTime parser used by [ScriptEntry.addedAt] — falls back to
/// [DateTime.now()] when the JSON value is absent or malformed.
DateTime _dateOrNow(String? s) =>
    (s == null ? null : DateTime.tryParse(s)) ?? DateTime.now();

/// Serialize [MobileAppId] only when non-null **and** non-empty, matching
/// the original hand-written `if (appId != null && !appId!.isEmpty)` guard.
Map<String, dynamic>? _appIdToJson(MobileAppId? id) =>
    (id == null || id.isEmpty) ? null : id.toJson();

// ── MobileAppId ───────────────────────────────────────────────────────────────

/// The Android applicationId / iOS bundle identifier for one surface.
/// One per [SurfaceConfig] since a surface now already *is* one environment.
@JsonSerializable(includeIfNull: false, explicitToJson: true)
class MobileAppId {
  @JsonKey(name: 'android')
  final String? androidApplicationId;

  @JsonKey(name: 'ios')
  final String? iosBundleId;

  const MobileAppId({this.androidApplicationId, this.iosBundleId});

  bool get isEmpty => androidApplicationId == null && iosBundleId == null;

  MobileAppId copyWith({
    String? androidApplicationId,
    String? iosBundleId,
    bool clearAndroid = false,
    bool clearIos = false,
  }) =>
      MobileAppId(
        androidApplicationId: clearAndroid
            ? null
            : (androidApplicationId ?? this.androidApplicationId),
        iosBundleId: clearIos ? null : (iosBundleId ?? this.iosBundleId),
      );

  factory MobileAppId.fromJson(Map<String, dynamic> json) =>
      _$MobileAppIdFromJson(json);

  Map<String, dynamic> toJson() => _$MobileAppIdToJson(this);
}

// ── RepoEntry ─────────────────────────────────────────────────────────────────

/// One repository inside a project.
@JsonSerializable(includeIfNull: false, explicitToJson: true)
class RepoEntry {
  final String role;    // e.g. "web", "app", "mobile_tests"
  final String label;   // display name, e.g. "Web App"
  final String relPath; // folder under projectsRoot, e.g. "crichq-webapp-nextjs"
  final String branch;  // expected git branch, e.g. "develop"

  const RepoEntry({
    required this.role,
    required this.label,
    required this.relPath,
    this.branch = 'develop',
  });

  String absPath(String projectsRoot) => '$projectsRoot/$relPath';

  RepoEntry copyWith({
    String? role,
    String? label,
    String? relPath,
    String? branch,
  }) =>
      RepoEntry(
        role: role ?? this.role,
        label: label ?? this.label,
        relPath: relPath ?? this.relPath,
        branch: branch ?? this.branch,
      );

  factory RepoEntry.fromJson(Map<String, dynamic> json) =>
      _$RepoEntryFromJson(json);

  Map<String, dynamic> toJson() => _$RepoEntryToJson(this);

  RepoConfig toRepoConfig() => RepoConfig(relPath: relPath, branch: branch);
}

// ── CommandConfig ─────────────────────────────────────────────────────────────

/// One pipeline step stored in the project's global command pool.
@JsonSerializable(includeIfNull: false, explicitToJson: true)
class CommandConfig {
  final String id;
  final String name;
  final String command;

  /// Key into [ProjectConfig.repos].
  final String repoRole;

  final int? timeoutSeconds;
  final bool skipIfNoSync;
  final bool skipIfNoBuild;
  final bool detach;
  final String? envFile;

  /// iOS-only target filter: `"simulator"` | `"device"` | `null` (both).
  final String? target;

  final bool checkAppium;
  final String? specCommand;

  /// Position hint used for sorting / template ordering.
  final int order;

  /// Free-form labels — replaces the old fixed `category` enum plus the
  /// `platform`/`environment` filter fields. Pipeline stage tags (`"test"`,
  /// `"build"`, `"report"`, `"git"`, `"prerequisite"`) drive execution
  /// resolution in [ProjectConfig]; all others are descriptive only.
  final List<String> tags;

  const CommandConfig({
    required this.id,
    required this.name,
    required this.command,
    required this.repoRole,
    this.timeoutSeconds,
    this.skipIfNoSync = false,
    this.skipIfNoBuild = false,
    this.detach = false,
    this.envFile,
    this.target,
    this.checkAppium = false,
    this.specCommand,
    this.order = 0,
    this.tags = const [],
  });

  bool hasTag(String tag) => tags.contains(tag);

  CommandConfig copyWith({
    String? id,
    String? name,
    String? command,
    String? repoRole,
    int? timeoutSeconds,
    bool? skipIfNoSync,
    bool? skipIfNoBuild,
    bool? detach,
    String? envFile,
    String? target,
    bool? checkAppium,
    String? specCommand,
    int? order,
    List<String>? tags,
    bool clearTimeout = false,
    bool clearEnvFile = false,
    bool clearTarget = false,
    bool clearSpecCommand = false,
  }) =>
      CommandConfig(
        id: id ?? this.id,
        name: name ?? this.name,
        command: command ?? this.command,
        repoRole: repoRole ?? this.repoRole,
        timeoutSeconds:
            clearTimeout ? null : (timeoutSeconds ?? this.timeoutSeconds),
        skipIfNoSync: skipIfNoSync ?? this.skipIfNoSync,
        skipIfNoBuild: skipIfNoBuild ?? this.skipIfNoBuild,
        detach: detach ?? this.detach,
        envFile: clearEnvFile ? null : (envFile ?? this.envFile),
        target: clearTarget ? null : (target ?? this.target),
        checkAppium: checkAppium ?? this.checkAppium,
        specCommand:
            clearSpecCommand ? null : (specCommand ?? this.specCommand),
        order: order ?? this.order,
        tags: tags ?? this.tags,
      );

  factory CommandConfig.fromJson(Map<String, dynamic> json) =>
      _$CommandConfigFromJson(json);

  Map<String, dynamic> toJson() => _$CommandConfigToJson(this);

  StepConfig toStepConfig() => StepConfig(
        id: id,
        name: name,
        command: command,
        repo: repoRole,
        timeoutSeconds: timeoutSeconds,
        skipIfNoSync: skipIfNoSync,
        skipIfNoBuild: skipIfNoBuild,
        detach: detach,
        envFile: envFile,
        target: target,
        checkAppium: checkAppium,
        specCommand: specCommand,
      );

  factory CommandConfig.fromStepConfig(StepConfig step, {int order = 0}) =>
      CommandConfig(
        id: step.id,
        name: step.name,
        command: step.command,
        repoRole: step.repo,
        timeoutSeconds: step.timeoutSeconds,
        skipIfNoSync: step.skipIfNoSync,
        skipIfNoBuild: step.skipIfNoBuild,
        detach: step.detach,
        envFile: step.envFile,
        target: step.target,
        checkAppium: step.checkAppium,
        specCommand: step.specCommand,
        order: order,
      );
}

// ── ScriptEntry ───────────────────────────────────────────────────────────────

/// One leaf test script — a file path (mobile) or a `package.json` script
/// name (web). Distinct from [CommandConfig]: a script is *what* to run,
/// not a pipeline step. See docs/RUN_EXPERIENCE_REDESIGN.md §4.
@JsonSerializable(includeIfNull: false, explicitToJson: true)
class ScriptEntry {
  final String id;
  final String path; // mobile: file path; web: package.json script name
  final String? customName; // user-entered; falls back to the filename/script name

  /// Stored as an ISO-8601 string; deserialized with a [DateTime.now()]
  /// fallback via [_dateOrNow] in case old records lack this field.
  @JsonKey(fromJson: _dateOrNow)
  final DateTime addedAt;

  final DateTime? pinnedAt;

  const ScriptEntry({
    required this.id,
    required this.path,
    this.customName,
    required this.addedAt,
    this.pinnedAt,
  });

  bool get isPinned => pinnedAt != null;

  /// What to show in the UI — the user's own name if they gave one, else
  /// derived from [path] (the filename for a mobile file path; unchanged for
  /// a web package.json script name, which has no directory to strip).
  String get displayName {
    final custom = customName;
    if (custom != null && custom.trim().isNotEmpty) return custom;
    final slash = path.lastIndexOf('/');
    return slash == -1 ? path : path.substring(slash + 1);
  }

  ScriptEntry copyWith({
    String? id,
    String? path,
    String? customName,
    DateTime? addedAt,
    DateTime? pinnedAt,
    bool clearCustomName = false,
    bool clearPinnedAt = false,
  }) =>
      ScriptEntry(
        id: id ?? this.id,
        path: path ?? this.path,
        customName: clearCustomName ? null : (customName ?? this.customName),
        addedAt: addedAt ?? this.addedAt,
        pinnedAt: clearPinnedAt ? null : (pinnedAt ?? this.pinnedAt),
      );

  factory ScriptEntry.fromJson(Map<String, dynamic> json) =>
      _$ScriptEntryFromJson(json);

  Map<String, dynamic> toJson() => _$ScriptEntryToJson(this);

  /// Merges [paths] into [existing], skipping duplicates (by path). Returns
  /// the merged list and a count of how many entries were actually added.
  static ({List<ScriptEntry> scripts, int added}) mergeUnique(
    List<ScriptEntry> existing,
    Iterable<String> paths, {
    String? customName,
  }) {
    final seen = existing.map((s) => s.path).toSet();
    final additions = <ScriptEntry>[];
    for (final path in paths) {
      if (!seen.add(path)) continue;
      additions.add(ScriptEntry(
        id: generateProjectId(),
        path: path,
        customName: customName,
        addedAt: DateTime.now(),
      ));
    }
    return (scripts: [...existing, ...additions], added: additions.length);
  }
}

// ── SurfaceConfig ─────────────────────────────────────────────────────────────

/// A surface inside a project — one environment+platform combo (e.g.
/// "Android Dev", "Android Stage"). Surfaces reference commands by id from
/// [ProjectConfig.commands]; they do not own their own command list.
///
/// See docs/PROJECTS_SYSTEM.md for the full architecture.
@JsonSerializable(includeIfNull: false, explicitToJson: true)
class SurfaceConfig {
  final String id;
  final String name;
  final String icon;

  /// Device type — `"ios"` | `"android"` | `"web"` | `null`.
  final String? platformType;

  /// This surface's environment (`"dev"`, `"stage"`, `"prod"`, …), substituted
  /// into `{environment}` placeholders at run time.
  final String? environmentId;

  /// Installed-app identity (mobile only) — serialized via [_appIdToJson] so
  /// an empty [MobileAppId] is omitted from the JSON rather than written as `{}`.
  @JsonKey(toJson: _appIdToJson)
  final MobileAppId? appId;

  /// Ordered [CommandConfig.id] references from [ProjectConfig.commands].
  final List<String> commandIds;

  /// Leaf test scripts for this surface.
  final List<ScriptEntry> scripts;

  final bool runPrerequisites;
  final bool runPull;
  final bool runBuild;
  final String? reportOutputRelPath;

  const SurfaceConfig({
    required this.id,
    required this.name,
    this.icon = '🔧',
    this.platformType,
    this.environmentId,
    this.appId,
    this.commandIds = const [],
    this.scripts = const [],
    this.runPrerequisites = false,
    this.runPull = false,
    this.runBuild = false,
    this.reportOutputRelPath,
  });

  factory SurfaceConfig.autoWeb() => const SurfaceConfig(
      id: 'web', name: 'Web Tests', icon: '🌐', platformType: 'web');

  factory SurfaceConfig.autoMobile() =>
      const SurfaceConfig(id: 'mobile', name: 'Mobile Tests', icon: '📱');

  bool get isIos => platformType == 'ios';
  bool get isAndroid => platformType == 'android';
  bool get isWeb => platformType == 'web';
  bool get isMobile => isIos || isAndroid;

  SurfaceConfig copyWith({
    String? id,
    String? name,
    String? icon,
    String? platformType,
    String? environmentId,
    MobileAppId? appId,
    List<String>? commandIds,
    List<ScriptEntry>? scripts,
    bool? runPrerequisites,
    bool? runPull,
    bool? runBuild,
    String? reportOutputRelPath,
    bool clearEnvironmentId = false,
    bool clearAppId = false,
    bool clearReportOutputRelPath = false,
  }) =>
      SurfaceConfig(
        id: id ?? this.id,
        name: name ?? this.name,
        icon: icon ?? this.icon,
        platformType: platformType ?? this.platformType,
        environmentId:
            clearEnvironmentId ? null : (environmentId ?? this.environmentId),
        appId: clearAppId ? null : (appId ?? this.appId),
        commandIds: commandIds ?? this.commandIds,
        scripts: scripts ?? this.scripts,
        runPrerequisites: runPrerequisites ?? this.runPrerequisites,
        runPull: runPull ?? this.runPull,
        runBuild: runBuild ?? this.runBuild,
        reportOutputRelPath: clearReportOutputRelPath
            ? null
            : (reportOutputRelPath ?? this.reportOutputRelPath),
      );

  /// Custom factory to handle the legacy format where surfaces had an inline
  /// `commands` array instead of a `commandIds` list.
  factory SurfaceConfig.fromJson(Map<String, dynamic> json) {
    if (!json.containsKey('commandIds') && json.containsKey('commands')) {
      // Legacy migration: extract ids from inline command objects.
      final ids = (json['commands'] as List? ?? [])
          .map((c) => (c as Map<String, dynamic>)['id'] as String)
          .toList();
      json = {...json, 'commandIds': ids};
    }
    return _$SurfaceConfigFromJson(json);
  }

  Map<String, dynamic> toJson() => _$SurfaceConfigToJson(this);
}

// ── ProjectConfig ─────────────────────────────────────────────────────────────

/// A complete project configuration.
///
/// ### Command architecture
/// Commands live in [commands] (the global pool). Each [SurfaceConfig] holds
/// an ordered list of [SurfaceConfig.commandIds] that references pool entries.
@JsonSerializable(includeIfNull: false, explicitToJson: true)
class ProjectConfig {
  final String id;
  final String name;

  /// Absolute path to the folder containing all repos.
  final String projectsRoot;

  /// Repo roles this project uses. Keys match [CommandConfig.repoRole].
  final Map<String, RepoEntry> repos;

  /// Global command pool — all commands available to this project.
  final List<CommandConfig> commands;

  final List<SurfaceConfig> surfaces;

  final List<String> extraPathDirs;

  final DateTime? pinnedAt;
  final DateTime? lastOpenedAt;

  const ProjectConfig({
    required this.id,
    required this.name,
    required this.projectsRoot,
    required this.repos,
    this.commands = const [],
    required this.surfaces,
    this.extraPathDirs = const [],
    this.pinnedAt,
    this.lastOpenedAt,
  });

  bool get isPinned => pinnedAt != null;

  ProjectConfig copyWith({
    String? id,
    String? name,
    String? projectsRoot,
    Map<String, RepoEntry>? repos,
    List<CommandConfig>? commands,
    List<SurfaceConfig>? surfaces,
    List<String>? extraPathDirs,
    DateTime? pinnedAt,
    DateTime? lastOpenedAt,
    bool clearPinnedAt = false,
    bool clearLastOpenedAt = false,
  }) =>
      ProjectConfig(
        id: id ?? this.id,
        name: name ?? this.name,
        projectsRoot: projectsRoot ?? this.projectsRoot,
        repos: repos ?? this.repos,
        commands: commands ?? this.commands,
        surfaces: surfaces ?? this.surfaces,
        extraPathDirs: extraPathDirs ?? this.extraPathDirs,
        pinnedAt: clearPinnedAt ? null : (pinnedAt ?? this.pinnedAt),
        lastOpenedAt:
            clearLastOpenedAt ? null : (lastOpenedAt ?? this.lastOpenedAt),
      );

  // ── Adapters to legacy types ───────────────────────────────────────────────

  MachineProfile toProfile() => MachineProfile(
        projectsRoot: projectsRoot,
        extraPathDirs: extraPathDirs,
      );

  ManifestModel toManifestModel() => ManifestModel(
        product: name,
        environment: 'project',
        repos: {
          ...repos
              .map((role, entry) => MapEntry(role, entry.toRepoConfig())),
          '_root': RepoConfig(relPath: '', branch: 'develop'),
        },
        recipes: {
          for (final s in surfaces)
            s.id: RecipeConfig(
              id: s.id,
              name: s.name,
              surface: s.id,
              platformType: s.platformType,
              steps:
                  commandsForSurface(s.id).map((c) => c.toStepConfig()).toList(),
            ),
        },
      );

  // ── Command resolution ─────────────────────────────────────────────────────

  /// Resolve the ordered commands for [surfaceId] from the global pool.
  List<CommandConfig> commandsForSurface(String surfaceId) {
    final surface = surfaceById(surfaceId);
    if (surface == null) return [];
    final pool = {for (final c in commands) c.id: c};
    return surface.commandIds
        .map((id) => pool[id])
        .whereType<CommandConfig>()
        .toList();
  }

  /// Simple recipe for a surface — used by DoctorRunner.
  RecipeConfig simpleRecipeForSurface(String surfaceId) {
    final surface = surfaceById(surfaceId);
    if (surface == null) {
      throw ArgumentError('No surface "$surfaceId" in project "$name"');
    }
    return RecipeConfig(
      id: surfaceId,
      name: surface.name,
      surface: surfaceId,
      platformType: surface.platformType,
      steps:
          commandsForSurface(surfaceId).map((c) => c.toStepConfig()).toList(),
    );
  }

  SurfaceConfig? surfaceById(String id) {
    try {
      return surfaces.firstWhere((s) => s.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Pool commands for [surfaceId], filtered by optional [stageTag] and
  /// [target]. The shared foundation for all tag-based resolvers below.
  List<CommandConfig> _filteredCommandsFor(
    String surfaceId, {
    String? stageTag,
    String? target,
  }) {
    final surface = surfaceById(surfaceId);
    if (surface == null) return [];
    final pool = {for (final c in commands) c.id: c};
    return surface.commandIds
        .map((id) => pool[id])
        .whereType<CommandConfig>()
        .where((c) => stageTag == null || c.hasTag(stageTag))
        .where((c) => c.target == null || c.target == target)
        .toList();
  }

  /// The `test`-tagged command for [surfaceId]/[target] — resolved from the
  /// pool by filtering, not from a pre-assigned slot. First match wins.
  CommandConfig? testCommandFor(String surfaceId, {String? target}) =>
      _filteredCommandsFor(surfaceId, stageTag: 'test', target: target)
          .firstOrNull;

  /// The `report`-tagged command for [surfaceId].
  CommandConfig? reportCommandFor(String surfaceId) =>
      _filteredCommandsFor(surfaceId, stageTag: 'report').firstOrNull;

  /// `build`-tagged commands for [surfaceId]/[target].
  List<CommandConfig> buildInstallCommandsFor(String surfaceId,
          {String? target}) =>
      _filteredCommandsFor(surfaceId, stageTag: 'build', target: target);

  /// Commands tagged `git` or `prerequisite` for [surfaceId] — what
  /// [SurfaceConfig.runPrerequisites] actually runs.
  List<CommandConfig> prerequisiteCommandsFor(String surfaceId) {
    final surface = surfaceById(surfaceId);
    if (surface == null) return [];
    final pool = {for (final c in commands) c.id: c};
    return surface.commandIds
        .map((id) => pool[id])
        .whereType<CommandConfig>()
        .where((c) => c.hasTag('git') || c.hasTag('prerequisite'))
        .toList();
  }

  // ── JSON ──────────────────────────────────────────────────────────────────

  /// Custom factory to handle the legacy format (surfaces had inline
  /// `commands` arrays; no top-level `commands` pool).
  factory ProjectConfig.fromJson(Map<String, dynamic> json) {
    if (!json.containsKey('commands')) {
      // ── Legacy migration ──────────────────────────────────────────────────
      // Collect all commands from all surfaces into a top-level pool (dedup
      // by id), and rewrite each surface to use commandIds instead.
      final pool = <String, Map<String, dynamic>>{};
      final migratedSurfaces = <Map<String, dynamic>>[];

      for (final s in (json['surfaces'] as List? ?? [])) {
        final sMap = s as Map<String, dynamic>;
        final surfaceCmds =
            (sMap['commands'] as List? ?? []).cast<Map<String, dynamic>>();
        for (final cmd in surfaceCmds) {
          pool.putIfAbsent(cmd['id'] as String, () => cmd);
        }
        migratedSurfaces.add({
          ...sMap,
          'commandIds': surfaceCmds.map((c) => c['id'] as String).toList(),
        });
      }

      json = {
        ...json,
        'commands': pool.values.toList(),
        'surfaces': migratedSurfaces,
      };
    }
    return _$ProjectConfigFromJson(json);
  }

  Map<String, dynamic> toJson() => _$ProjectConfigToJson(this);

  String toJsonString({bool pretty = true}) {
    final encoder =
        pretty ? const JsonEncoder.withIndent('  ') : const JsonEncoder();
    return encoder.convert(toJson());
  }

  factory ProjectConfig.fromJsonString(String jsonStr) =>
      ProjectConfig.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
}
