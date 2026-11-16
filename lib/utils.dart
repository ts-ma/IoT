import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';

/// "Lying down on stomach" -> "lyingDownOnStomach" (recording file names).
String sentenceToCamelCase(String sentence) {
  // Split on runs of whitespace and drop empty words, so that leading,
  // trailing or repeated spaces cannot produce an empty word below.
  List<String> words =
      sentence.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

  if (words.isEmpty) {
    return "";
  }

  String camelCase = words[0].toLowerCase(); // first word all lower case

  for (int i = 1; i < words.length; i++) {
    camelCase +=
        words[i][0].toUpperCase() + words[i].substring(1).toLowerCase();
  }

  return camelCase;
}

/// Short message at the bottom of the screen (about 2 s).
void showToast(String s) {
  Fluttertoast.showToast(
      msg: s,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.SNACKBAR,
      timeInSecForIosWeb: 1,
      backgroundColor: Colors.blueGrey,
      textColor: Colors.white,
      fontSize: 16.0);
}

/// The same, shown for longer (about 3.5 s).
void showLongToast(String s) {
  Fluttertoast.showToast(
      msg: s,
      toastLength: Toast.LENGTH_LONG,
      gravity: ToastGravity.SNACKBAR,
      timeInSecForIosWeb: 1,
      backgroundColor: Colors.blueGrey,
      textColor: Colors.white,
      fontSize: 16.0);
}

/// The RESpeck sends each acceleration value as two bytes, combined here into
/// a signed 16-bit integer and scaled to g. [upper] must be read as a signed
/// byte (getInt8) so that the shift below keeps the sign.
double combineAccelBytes(int upper, int lower) {
  int lower2 = lower & 0xFF;
  int value = (upper << 8) | lower2;
  return (value) / 16384.0;
}
