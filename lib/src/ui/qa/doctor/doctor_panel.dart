import 'package:flutter/material.dart';
import 'package:flutter_boilerplate/src/base/dependencyinjection/locator.dart';
import 'package:flutter_boilerplate/src/base/qa/process_gateway.dart';
import 'package:flutter_boilerplate/src/models/qa/doctor_model.dart';
import 'package:flutter_boilerplate/src/models/qa/manifest_model.dart';
import 'package:flutter_boilerplate/src/providers/qa/qa_provider.dart';
import 'package:provider/provider.dart';

/// Collapsible Doctor panel rendered inside a recipe card (Phase 2).
///
/// Shows:
///  • A "Run Doctor" button when no result exists yet.
///  • A loading spinner while checks are in flight.
///  • Expandable list of [DoctorCheck] rows once results arrive.
///  • A "Re-check" button to re-run after the user fixes an issue.
///
/// The panel is self-contained — it reads [QAProvider] via context and
/// dispatches [runDoctor] on its own. The parent card only needs to pass
/// [recipeId] and [iosTarget].
class DoctorPanel extends StatelessWidget {
  final String recipeId;
  final IosBuildTarget iosTarget;

  const DoctorPanel({
    super.key,
    required this.recipeId,
    required this.iosTarget,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<QAProvider>(
      builder: (context, qa, _) {
        final running = qa.isDoctorRunning(recipeId);
        final result = qa.doctorResultFor(recipeId);

        if (running) return _DoctorLoading();
        if (result == null) return _DoctorPrompt(recipeId: recipeId, iosTarget: iosTarget);
        return _DoctorResults(
          result: result,
          recipeId: recipeId,
          iosTarget: iosTarget,
        );
      },
    );
  }
}

// ── Prompt — no result yet ────────────────────────────────────────────────────

class _DoctorPrompt extends StatelessWidget {
  final String recipeId;
  final IosBuildTarget iosTarget;

  const _DoctorPrompt({required this.recipeId, required this.iosTarget});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: OutlinedButton.icon(
        icon: const Icon(Icons.health_and_safety_outlined, size: 16),
        label: const Text('Run Doctor'),
        onPressed: () => context.read<QAProvider>().runDoctor(
              recipeId: recipeId,
              iosTarget: iosTarget,
            ),
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}

// ── Loading ───────────────────────────────────────────────────────────────────

class _DoctorLoading extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            'Running checks…',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}

// ── Results ───────────────────────────────────────────────────────────────────

class _DoctorResults extends StatefulWidget {
  final DoctorResult result;
  final String recipeId;
  final IosBuildTarget iosTarget;

  const _DoctorResults({
    required this.result,
    required this.recipeId,
    required this.iosTarget,
  });

  @override
  State<_DoctorResults> createState() => _DoctorResultsState();
}

class _DoctorResultsState extends State<_DoctorResults> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    // Auto-expand when there are failures or warnings
    _expanded = !widget.result.isRunnable || widget.result.warnings.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final runnable = result.isRunnable;
    final failures = result.failures.length;
    final warnings = result.warnings.length;

    final statusColor = runnable
        ? (warnings > 0
            ? Theme.of(context).colorScheme.tertiary
            : Theme.of(context).colorScheme.primary)
        : Theme.of(context).colorScheme.error;

    final statusIcon = runnable
        ? (warnings > 0 ? Icons.warning_amber_outlined : Icons.check_circle_outline)
        : Icons.cancel_outlined;

    final summary = runnable
        ? (warnings > 0 ? '$warnings warning${warnings > 1 ? 's' : ''}' : 'All checks passed')
        : '$failures failure${failures > 1 ? 's' : ''}';

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Summary row — tap to expand/collapse
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(statusIcon, size: 16, color: statusColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      summary,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: statusColor,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),

          // Expanded check list
          if (_expanded) ...[
            const SizedBox(height: 6),
            ...result.checks.map((c) => _CheckRow(
                  check: c,
                  onFixApplied: () => context.read<QAProvider>().runDoctor(
                        recipeId: widget.recipeId,
                        iosTarget: widget.iosTarget,
                      ),
                )),
          ],

          // Re-check button
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Last checked: ${_formatTime(result.ranAt)}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.refresh, size: 14),
                label: const Text('Re-check'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
                onPressed: () => context.read<QAProvider>().runDoctor(
                      recipeId: widget.recipeId,
                      iosTarget: widget.iosTarget,
                    ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

// ── Individual check row ──────────────────────────────────────────────────────

class _CheckRow extends StatefulWidget {
  final DoctorCheck check;

  /// Called after a fix command finishes so the parent can re-run Doctor.
  final VoidCallback? onFixApplied;

  const _CheckRow({required this.check, this.onFixApplied});

  @override
  State<_CheckRow> createState() => _CheckRowState();
}

class _CheckRowState extends State<_CheckRow> {
  _FixState _fixState = _FixState.idle;
  String? _fixError;

  Future<void> _runFix() async {
    final cmd = widget.check.fixCommand;
    if (cmd == null) return;
    setState(() {
      _fixState = _FixState.running;
      _fixError = null;
    });
    try {
      final gw = locator<ProcessGateway>();
      if (widget.check.fixIsBackground) {
        await gw.detach(cmd, workingDirectory: widget.check.fixCwd);
        // Give the background process a moment to start before re-checking.
        await Future<void>.delayed(const Duration(seconds: 2));
      } else {
        await gw.exec(cmd, workingDirectory: widget.check.fixCwd);
      }
      if (mounted) setState(() => _fixState = _FixState.done);
      widget.onFixApplied?.call();
    } catch (e) {
      if (mounted) {
        setState(() {
          _fixState = _FixState.error;
          _fixError = e.toString().split('\n').first;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final check = widget.check;
    final cs = Theme.of(context).colorScheme;

    final color = switch (check.status) {
      DoctorStatus.pass => cs.primary,
      DoctorStatus.warn => cs.tertiary,
      DoctorStatus.fail => cs.error,
      DoctorStatus.checking => cs.onSurfaceVariant,
    };

    final icon = switch (check.status) {
      DoctorStatus.pass => Icons.check_circle,
      DoctorStatus.warn => Icons.warning_amber,
      DoctorStatus.fail => Icons.cancel,
      DoctorStatus.checking => Icons.hourglass_empty,
    };

    final hasFixButton = check.fixCommand != null &&
        check.status != DoctorStatus.pass &&
        _fixState != _FixState.done;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  check.label,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              // ── Fix button ────────────────────────────────────────────
              if (hasFixButton) ...[
                const SizedBox(width: 8),
                _fixState == _FixState.running
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      )
                    : SizedBox(
                        height: 22,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 0),
                            textStyle: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(fontSize: 11),
                            side: BorderSide(
                              color: check.status == DoctorStatus.fail
                                  ? cs.error
                                  : cs.tertiary,
                            ),
                            foregroundColor: check.status == DoctorStatus.fail
                                ? cs.error
                                : cs.tertiary,
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: _runFix,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.build_outlined,
                                size: 11,
                                color: check.status == DoctorStatus.fail
                                    ? cs.error
                                    : cs.tertiary,
                              ),
                              const SizedBox(width: 3),
                              const Text('Fix'),
                            ],
                          ),
                        ),
                      ),
              ],
            ],
          ),
          // ── Detail line ───────────────────────────────────────────────
          if (check.detail != null)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 2),
              child: Text(
                check.detail!,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontFamily: 'monospace',
                      color: cs.onSurfaceVariant,
                    ),
              ),
            ),
          // ── Fix error ─────────────────────────────────────────────────
          if (_fixState == _FixState.error && _fixError != null)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 2),
              child: Text(
                _fixError!,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: cs.error,
                      fontFamily: 'monospace',
                    ),
              ),
            ),
          // ── Fix hint (shown when there's no Fix button or after error) ─
          if (check.fixHint != null && check.status != DoctorStatus.pass)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 2),
              child: Row(
                children: [
                  Icon(
                    Icons.lightbulb_outline,
                    size: 11,
                    color: cs.tertiary,
                  ),
                  const SizedBox(width: 3),
                  Expanded(
                    child: Text(
                      check.fixHint!,
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: cs.tertiary),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

enum _FixState { idle, running, done, error }
