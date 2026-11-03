import 'package:flutter/material.dart';

import '../activity_catalog.dart';
import '../services/user_session.dart';
import '../settings.dart';
import '../user_page.dart';

// Widgets shared by every tab, so the app looks the same everywhere.

/// Top-left of every tab: the round user avatar (opens the User page) and a
/// gear (opens Settings). Use with `leadingWidth: TabLeading.width`.
class TabLeading extends StatelessWidget {
  const TabLeading({super.key, this.session});

  final UserSession? session;

  static const double width = 104;

  @override
  Widget build(BuildContext context) {
    final s = session ?? userSession;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final name = s.username;
        return Row(
          children: [
            const SizedBox(width: 8),
            Tooltip(
              message: name == null ? 'Log in' : 'User: $name',
              child: InkWell(
                key: const ValueKey('user-button'),
                customBorder: const CircleBorder(),
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => UserPage(session: s))),
                child: CircleAvatar(
                  radius: 19,
                  backgroundColor: name == null
                      ? scheme.surfaceContainerHighest
                      : scheme.primary,
                  foregroundColor:
                      name == null ? scheme.onSurfaceVariant : scheme.onPrimary,
                  child: name == null
                      ? const Icon(Icons.person_outline, size: 22)
                      : Text(name.characters.first.toUpperCase(),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 18)),
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('settings-button'),
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => SettingsPage(session: s))),
            ),
          ],
        );
      },
    );
  }
}

/// AppBar used by every tab: user + gear on the left, the title, and the
/// tab's own actions on the right.
PreferredSizeWidget tabAppBar(BuildContext context, String title,
    {List<Widget>? actions, UserSession? session}) {
  return AppBar(
    leadingWidth: TabLeading.width,
    leading: TabLeading(session: session),
    automaticallyImplyLeading: false,
    title: Text(title),
    centerTitle: true,
    backgroundColor: Theme.of(context).colorScheme.inversePrimary,
    actions: actions,
  );
}

/// A titled card used for the sections of every page.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// Icon + label for buttons. A plain Row keeps the button's runtime type
/// (e.g. ElevatedButton) unchanged, which the widget tests rely on.
class IconLabel extends StatelessWidget {
  const IconLabel(this.icon, this.label, {super.key});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 6),
        Flexible(child: Text(label)),
      ],
    );
  }
}

/// Small coloured pill, e.g. "Static" or "REC".
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text,
          style:
              TextStyle(color: c, fontWeight: FontWeight.w600, fontSize: 12)),
    );
  }
}

/// Large icon, readable class name and a confidence bar.
class PredictionDisplay extends StatelessWidget {
  const PredictionDisplay({
    super.key,
    required this.label,
    required this.confidence,
    required this.confidenceText,
    this.labelKey,
    this.confidenceKey,
  });

  final String label;
  final double confidence;
  final String confidenceText;
  final Key? labelKey;
  final Key? confidenceKey;

  @override
  Widget build(BuildContext context) {
    final info = labelInfo(label);
    final textTheme = Theme.of(context).textTheme;
    final low = confidence < 0.5;
    return Row(
      children: [
        LabelAvatar(label, radius: 30),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                info.displayName,
                key: labelKey,
                style: textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: confidence.clamp(0.0, 1.0),
                  minHeight: 8,
                  color: info.color,
                  backgroundColor: info.color.withValues(alpha: 0.15),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(confidenceText,
                      key: confidenceKey, style: textTheme.bodySmall),
                  if (low) ...[
                    const SizedBox(width: 8),
                    Text('· uncertain',
                        style: textTheme.bodySmall
                            ?.copyWith(color: Colors.amber.shade800)),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Centered icon + message (+ optional button) for empty and error states.
class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
          if (actionLabel != null) ...[
            const SizedBox(height: 12),
            FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}

/// Shown by tabs that need a logged-in user.
class LoginPrompt extends StatelessWidget {
  const LoginPrompt({super.key, this.what = 'see your data', this.session});

  final String what;
  final UserSession? session;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: MessageView(
        icon: Icons.account_circle_outlined,
        text: 'Log in or create a user to $what.\n'
            'Each user\'s data is kept in their own folder.',
        actionLabel: 'Log in / create user',
        onAction: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => UserPage(session: session))),
      ),
    );
  }
}
