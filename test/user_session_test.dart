import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdiot/globals.dart';
import 'package:pdiot/har.dart';
import 'package:pdiot/models/prediction_record.dart';
import 'package:pdiot/services/prediction_history_writer.dart';
import 'package:pdiot/services/prediction_repository.dart';
import 'package:pdiot/services/user_session.dart';
import 'package:pdiot/user_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory storage;
  late UserSession session;

  setUp(() async {
    storage = await Directory.systemTemp.createTemp('pdiot_users_');
    session =
        UserSession(storage: () async => storage, rememberLastUser: false);
    await session.init();
  });

  tearDown(() async {
    if (await storage.exists()) await storage.delete(recursive: true);
  });

  test('names: letters, digits, _ and - only, 1-32 characters', () {
    expect(validateUserName('harry_2503795'), isNull);
    expect(validateUserName('a-b'), isNull);
    expect(validateUserName(''), isNotNull);
    expect(validateUserName('has space'), isNotNull);
    expect(validateUserName('../escape'), isNotNull);
    expect(validateUserName('x' * 33), isNotNull);
  });

  test('create makes <root>/<user>/raw and profile.json, then logs in',
      () async {
    expect(session.root!.path, p.join(storage.path, 'PDIoT'));
    expect(await session.create('harry'), isNull);
    expect(session.username, 'harry');
    expect(
        await Directory(p.join(storage.path, 'PDIoT', 'harry', 'raw')).exists(),
        isTrue);
    final profile = jsonDecode(
        await File(p.join(storage.path, 'PDIoT', 'harry', 'profile.json'))
            .readAsString());
    expect(profile['username'], 'harry');
    expect(session.databasePath, p.join(session.userDir!.path, 'history.db'));
    expect(session.rawDir!.path, p.join(session.userDir!.path, 'raw'));
  });

  test('a name is unique if no folder has it, ignoring case', () async {
    expect(await session.create('Harry'), isNull);
    await session.logout();
    expect(await session.create('harry'), contains('already exists'));
    expect(await session.create('bad name'), contains('letters'));
    expect(session.loggedIn, isFalse);
  });

  test('log in needs an existing folder and suggests creating otherwise',
      () async {
    expect(await session.login('nobody'), contains('create the user'));
    expect(session.loggedIn, isFalse);
    // A folder made by hand (e.g. copied over USB) is a valid user too.
    await Directory(p.join(session.root!.path, 'manual')).create();
    expect(await session.login('MANUAL'), isNull);
    expect(session.username, 'manual'); // the folder name is the identity
  });

  test('pairing is saved per user and restored at log in', () async {
    await session.create('a');
    await session.setRespeck(' E0:3B:AB:69:5A:1C ');
    expect(respeckUUID, 'E0:3B:AB:69:5A:1C');
    await session.create('b');
    expect(respeckUUID, isNull);
    await session.login('a');
    expect(session.profile!.respeckId, 'E0:3B:AB:69:5A:1C');
    expect(respeckUUID, 'E0:3B:AB:69:5A:1C');
    await session.setRespeck(null);
    expect(respeckUUID, isNull);
    await session.logout();
    expect(() => session.setRespeck('x'), throwsStateError);
  });

  test('the app is told before the user changes, not on the same user',
      () async {
    var calls = 0;
    session.onBeforeSwitch = () async => calls++;
    await session.create('a');
    expect(calls, 1);
    await session.login('a');
    expect(calls, 1);
    await session.create('b');
    expect(calls, 2);
    await session.logout();
    expect(calls, 3);
    await session.logout(); // nobody logged in: nothing to prepare
    expect(calls, 3);
  });

  test('each user writes to and reads from their own history database',
      () async {
    sqfliteFfiInit();
    Future<PredictionRepository> open() => PredictionRepository.open(
        databasePath: session.databasePath!, factory: databaseFactoryFfi);
    final writer = PredictionHistoryWriter(openRepository: open);
    session.onBeforeSwitch = writer.reopen;
    await session.create('a');
    writer.capture(const HarPrediction('running', 0.9));
    await writer.flush();
    await session.create('b');
    writer.capture(const HarPrediction('lyingBack', 0.9));
    writer.capture(const HarPrediction('lyingBack', 0.9));
    await writer.flush();
    await writer.shutdown();
    writer.dispose();

    Future<List<String>> labels(String user) async {
      final repo = await PredictionRepository.open(
          databasePath: p.join(session.root!.path, user, 'history.db'),
          factory: databaseFactoryFfi);
      final rows = await repo.query(
          start: DateTime.utc(2020),
          end: DateTime.utc(2100),
          taskType: PredictionTaskType.har);
      await repo.close();
      return rows.map((r) => r.label).toList();
    }

    expect(await labels('a'), ['running']);
    expect(await labels('b'), ['lyingBack', 'lyingBack']);
  });

  test('without a storage folder nothing can be created', () async {
    final none =
        UserSession(storage: () async => null, rememberLastUser: false);
    await none.init();
    expect(await none.create('a'), contains('No storage'));
    expect(await none.login('a'), contains('No storage'));
    await expectLater(none.openRepository(), throwsStateError);
  });

  testWidgets('User page: create, log out, failed log in guides to create',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: UserPage(session: session)));
    expect(find.text('Not logged in'), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('user-name-field')), 'ghost');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('login-button')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.textContaining('No user "ghost"'), findsOneWidget);
    expect(find.textContaining('Press "Create user"'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('create-user-button')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(session.username, 'ghost');
    expect(tester.widget<Text>(find.byKey(const ValueKey('current-user'))).data,
        'ghost');

    await tester.runAsync(() async {
      await tester.tap(find.text('Log out'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(session.loggedIn, isFalse);
    expect(find.text('Not logged in'), findsOneWidget);
  });
}
