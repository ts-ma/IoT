import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../globals.dart';
import 'prediction_repository.dart';

// Users and per-user storage.
//
// Every user is a folder directly under the app's root folder:
//
//   <storage>/PDIoT/<username>/
//       profile.json            user name, creation time, paired RESpeck
//       history.db              every saved activity and social result
//       realtime_trials.json    real-time test trials
//       raw/                    raw sensor CSVs (real-time test, free recording)
//       exports/                CSV exports (daily summary, real-time results)
//       performance/            performance logs (Performance tab)
//
// <storage> is the app's external Downloads folder on Android (reachable over
// USB) and the app's Documents folder on iOS (visible in the Files app). A
// user exists exactly when its folder exists: creating checks that no folder
// with that name is there yet, logging in checks that it is. No passwords.

/// Name of the app's main folder inside the platform storage folder.
const String rootFolderName = 'PDIoT';

/// 1–32 letters, digits, '_' or '-': safe as a folder name on every phone.
final RegExp _validName = RegExp(r'^[A-Za-z0-9_-]{1,32}$');

/// Why a user name cannot be created, or null if it is fine.
String? validateUserName(String name) {
  if (name.isEmpty) return 'Enter a user name';
  if (name.length > 32) return 'Use at most 32 characters';
  if (!_validName.hasMatch(name)) {
    return 'Use only letters, digits, "_" or "-" (no spaces)';
  }
  return null;
}

class UserProfile {
  UserProfile(
      {required this.username, required this.createdAt, this.respeckId});

  final String username;
  final DateTime createdAt;

  /// Paired RESpeck: the BLE id on Android, the advertised id on iOS (both
  /// are what the QR code on the sensor contains). Null until paired.
  String? respeckId;

  Map<String, Object?> toJson() => {
        'username': username,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'respeckId': respeckId,
      };

  factory UserProfile.fromJson(Map<String, dynamic> json, String folderName) =>
      UserProfile(
        username: (json['username'] as String?) ?? folderName,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now().toUtc(),
        respeckId: json['respeckId'] as String?,
      );
}

/// The logged-in user and where their files live. Listeners are notified on
/// log in, log out and pairing changes.
class UserSession extends ChangeNotifier {
  UserSession(
      {Future<Directory?> Function()? storage, this.rememberLastUser = true})
      : _storage = storage ?? (() async => storageFolder);

  final Future<Directory?> Function() _storage;

  /// Store the last user in shared preferences and log them in again at
  /// start-up (tests turn this off).
  final bool rememberLastUser;

  Directory? _root;
  UserProfile? _profile;

  /// Runs before the logged-in user changes (log in as someone else, log
  /// out): the app stops recordings, disconnects the sensor and closes the
  /// previous user's database here, so nothing is written to the wrong folder.
  Future<void> Function()? onBeforeSwitch;

  /// `<storage>/PDIoT`, or null if the platform gave no storage folder.
  Directory? get root => _root;
  UserProfile? get profile => _profile;
  String? get username => _profile?.username;
  bool get loggedIn => _profile != null;

  Directory? get userDir => _root == null || _profile == null
      ? null
      : Directory(p.join(_root!.path, _profile!.username));

  Directory? _sub(String name) =>
      userDir == null ? null : Directory(p.join(userDir!.path, name));

  Directory? get rawDir => _sub('raw');
  Directory? get exportsDir => _sub('exports');
  Directory? get performanceDir => _sub('performance');
  String? get databasePath =>
      userDir == null ? null : p.join(userDir!.path, 'history.db');
  File? get latencyFile => userDir == null
      ? null
      : File(p.join(userDir!.path, 'latency_tests.json'));
  File? get trialsFile => userDir == null
      ? null
      : File(p.join(userDir!.path, 'realtime_trials.json'));

  /// Resolves the root folder and logs the last user in again if their folder
  /// still exists. Safe to call more than once.
  Future<void> init() async {
    final base = await _storage();
    if (base == null) return;
    _root = Directory(p.join(base.path, rootFolderName));
    try {
      await _root!.create(recursive: true);
    } catch (e) {
      debugPrint('Could not create ${_root!.path}: $e');
    }
    if (!rememberLastUser) return;
    try {
      final last = await asyncPrefs.getString('current_user');
      if (last != null && await _existingFolder(last) != null) {
        await login(last);
      }
    } catch (e) {
      debugPrint('Could not restore the last user: $e');
    }
  }

  /// The folder name of an existing user matching [name] ignoring case (so
  /// "Harry" and "harry" cannot both exist, whatever the file system), or null.
  Future<String?> _existingFolder(String name) async {
    final root = _root;
    if (root == null || !await root.exists()) return null;
    final wanted = name.toLowerCase();
    await for (final e in root.list(followLinks: false)) {
      if (e is Directory && p.basename(e.path).toLowerCase() == wanted) {
        return p.basename(e.path);
      }
    }
    return null;
  }

  /// Creates `<root>/<name>/` (and `raw/`) and logs the new user in. Returns
  /// an error message for the screen, or null on success.
  Future<String?> create(String rawName) async {
    final name = rawName.trim();
    final invalid = validateUserName(name);
    if (invalid != null) return invalid;
    final root = _root;
    if (root == null) return 'No storage folder on this phone';
    final existing = await _existingFolder(name);
    if (existing != null) {
      return 'User "$existing" already exists. Log in instead, or choose '
          'another name.';
    }
    try {
      final dir = Directory(p.join(root.path, name));
      await Directory(p.join(dir.path, 'raw')).create(recursive: true);
      final profile =
          UserProfile(username: name, createdAt: DateTime.now().toUtc());
      await _writeProfile(dir, profile);
    } catch (e) {
      debugPrint('Could not create user $name: $e');
      return 'Could not create the user folder';
    }
    return login(name);
  }

  /// Logs in an existing user. Returns an error message, or null on success.
  Future<String?> login(String rawName) async {
    final name = rawName.trim();
    if (name.isEmpty) return 'Enter your user name';
    if (_root == null) return 'No storage folder on this phone';
    final folder = await _existingFolder(name);
    if (folder == null) {
      return 'No user "$name" on this phone. Check the spelling, or create '
          'the user first.';
    }
    if (_profile?.username != folder) await _beforeSwitch();
    final dir = Directory(p.join(_root!.path, folder));
    UserProfile profile;
    try {
      final file = File(p.join(dir.path, 'profile.json'));
      profile = await file.exists()
          ? UserProfile.fromJson(
              jsonDecode(await file.readAsString()) as Map<String, dynamic>,
              folder)
          : UserProfile(username: folder, createdAt: DateTime.now().toUtc());
    } catch (e) {
      debugPrint('Unreadable profile for $folder, starting a new one: $e');
      profile =
          UserProfile(username: folder, createdAt: DateTime.now().toUtc());
    }
    // The folder name is the identity, whatever the profile says.
    _profile = UserProfile(
        username: folder,
        createdAt: profile.createdAt,
        respeckId: profile.respeckId);
    respeckUUID = _profile!.respeckId;
    try {
      await Directory(p.join(dir.path, 'raw')).create(recursive: true);
    } catch (_) {}
    if (rememberLastUser) {
      try {
        await asyncPrefs.setString('current_user', folder);
      } catch (_) {}
    }
    notifyListeners();
    return null;
  }

  Future<void> _beforeSwitch() async {
    try {
      await onBeforeSwitch?.call();
    } catch (e) {
      debugPrint('Preparing the user switch failed: $e');
    }
  }

  Future<void> logout() async {
    if (_profile == null) return;
    await _beforeSwitch();
    _profile = null;
    respeckUUID = null;
    if (rememberLastUser) {
      try {
        await asyncPrefs.remove('current_user');
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Pairs (or with null, forgets) the RESpeck for the logged-in user.
  Future<void> setRespeck(String? id) async {
    final profile = _profile;
    final dir = userDir;
    if (profile == null || dir == null) {
      throw StateError('Log in before pairing a sensor');
    }
    final clean = id?.trim();
    profile.respeckId = (clean == null || clean.isEmpty) ? null : clean;
    respeckUUID = profile.respeckId;
    await _writeProfile(dir, profile);
    notifyListeners();
  }

  static Future<void> _writeProfile(Directory dir, UserProfile profile) async {
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'profile.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert(profile.toJson()),
        flush: true);
  }

  /// Opens the logged-in user's history database (each page owns and closes
  /// the connection it opens). Throws if nobody is logged in.
  Future<PredictionRepository> openRepository() {
    final path = databasePath;
    if (path == null) {
      return Future.error(StateError('Log in to read or save history'));
    }
    return PredictionRepository.open(databasePath: path);
  }

  /// A file in [dir] (created if needed), e.g. an export.
  static Future<File> fileIn(Directory dir, String name) async {
    await dir.create(recursive: true);
    return File(p.join(dir.path, name));
  }
}

/// App-wide instance.
final UserSession userSession = UserSession();
