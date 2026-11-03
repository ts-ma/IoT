import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

// App-wide preferences store (settings, last logged-in user).
final SharedPreferencesAsync asyncPrefs = SharedPreferencesAsync();

// The RESpeck paired by the logged-in user (from their profile.json, see
// services/user_session.dart). Null when nobody is logged in or not paired.
String? respeckUUID;
String? fwString;
bool respeckConnected = false;

// The platform folder that holds the app's PDIoT/ root folder: the app's
// Downloads folder on Android, its Documents folder on iOS. Null until main()
// has resolved it, and can stay null if the platform provides no suitable
// directory, so every use must be null checked.
Directory? storageFolder;

// Read later from pubspec.yaml
String appVersionName = "0.0.0";
int appVersionCode = 0;
