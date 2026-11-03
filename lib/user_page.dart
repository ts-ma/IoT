import 'package:flutter/material.dart';

import 'services/user_session.dart';

/// Create a user, log in, or log out. A user is a folder under the app's
/// PDIoT folder: creating needs a name no folder has yet, logging in needs
/// an existing folder. Opened from the round avatar at the top left.
class UserPage extends StatefulWidget {
  const UserPage({super.key, this.session});

  final UserSession? session;

  @override
  State<UserPage> createState() => _UserPageState();
}

class _UserPageState extends State<UserPage> {
  late final UserSession _session = widget.session ?? userSession;
  final TextEditingController _name = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _offerCreate = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String?> Function(String) action,
      {required bool isLogin}) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _offerCreate = false;
    });
    final error = await action(_name.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
      _offerCreate = isLogin && error != null && error.startsWith('No user');
    });
    if (error == null) {
      _name.clear();
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Logged in as ${_session.username}')));
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _logout() async {
    setState(() => _busy = true);
    await _session.logout();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('User'),
        backgroundColor: scheme.inversePrimary,
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _session,
          builder: (context, _) {
            final name = _session.username;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                Center(
                  child: CircleAvatar(
                    radius: 44,
                    backgroundColor: name == null
                        ? scheme.surfaceContainerHighest
                        : scheme.primary,
                    foregroundColor: name == null
                        ? scheme.onSurfaceVariant
                        : scheme.onPrimary,
                    child: name == null
                        ? const Icon(Icons.person_outline, size: 44)
                        : Text(name.characters.first.toUpperCase(),
                            style: const TextStyle(
                                fontSize: 36, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 12),
                Center(
                  child: Text(name ?? 'Not logged in',
                      key: const ValueKey('current-user'),
                      style: textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                if (name != null) ...[
                  const SizedBox(height: 4),
                  Center(
                    child: Text(
                      _session.profile?.respeckId == null
                          ? 'No RESpeck paired yet (pair it on Home)'
                          : 'RESpeck ${_session.profile!.respeckId}',
                      style: textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _folderCard(context),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _logout,
                    icon: const Icon(Icons.logout),
                    label: const Text('Log out'),
                  ),
                  const SizedBox(height: 24),
                  Text('Switch user', style: textTheme.titleMedium),
                ] else
                  const SizedBox(height: 24),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('user-name-field'),
                  controller: _name,
                  enabled: !_busy,
                  autocorrect: false,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: 'User name',
                    hintText: 'e.g. harry',
                    helperText: 'Letters, digits, "_" or "-"',
                    errorText: _error,
                    errorMaxLines: 3,
                    prefixIcon: const Icon(Icons.badge_outlined),
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _run(_session.login, isLogin: true),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        key: const ValueKey('login-button'),
                        onPressed: _busy
                            ? null
                            : () => _run(_session.login, isLogin: true),
                        icon: const Icon(Icons.login),
                        label: const Text('Log in'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        key: const ValueKey('create-user-button'),
                        onPressed: _busy
                            ? null
                            : () => _run(_session.create, isLogin: false),
                        icon: const Icon(Icons.person_add_alt),
                        label: const Text('Create user'),
                      ),
                    ),
                  ],
                ),
                if (_offerCreate) ...[
                  const SizedBox(height: 8),
                  Text(
                    'New here? Press "Create user" to make "${_name.text.trim()}".',
                    style: textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 24),
                Text(
                  'Each user has a folder${_session.root == null ? '' : ' in ${_session.root!.path}'} '
                  'holding their history, real-time test results, raw sensor '
                  'recordings (raw/) and exports. The app only reads and '
                  'writes the logged-in user\'s folder.',
                  style: textTheme.bodySmall,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _folderCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: ListTile(
        leading: const Icon(Icons.folder_outlined),
        title: const Text('Your folder'),
        subtitle: Text(_session.userDir?.path ?? '–'),
      ),
    );
  }
}
