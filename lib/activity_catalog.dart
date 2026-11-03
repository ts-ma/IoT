import 'package:flutter/material.dart';

// Single source of truth for how model class names are presented to people.
//
// The models output camelCase class names (see the *_meta.json files). Those
// names are what is stored in the history database and exported to CSV, so
// they never change; this file only maps them to a readable name, an icon, a
// colour and the coursework group they belong to. Every screen uses these
// helpers, so the app is visually consistent and a renamed label only has to
// be changed here.

/// The groups used by the Coursework 3 marking scheme. Accuracy is averaged
/// per class within each group, so the app reports results the same way.
enum LabelGroup { staticActivity, dynamicActivity, social }

extension LabelGroupText on LabelGroup {
  String get title => switch (this) {
        LabelGroup.staticActivity => 'Static activities',
        LabelGroup.dynamicActivity => 'Dynamic activities',
        LabelGroup.social => 'Social signals',
      };

  String get shortTitle => switch (this) {
        LabelGroup.staticActivity => 'Static',
        LabelGroup.dynamicActivity => 'Dynamic',
        LabelGroup.social => 'Social',
      };
}

class LabelInfo {
  const LabelInfo(
    this.label,
    this.displayName,
    this.icon,
    this.color,
    this.group,
  );

  /// Class name exactly as output by the model, e.g. "normalWalking".
  final String label;

  /// Name shown in the UI, e.g. "Walking".
  final String displayName;
  final IconData icon;
  final Color color;
  final LabelGroup group;
}

/// Seconds of real time represented by one prediction. A model classifies a
/// window every `step_samples` new samples at 12.5 Hz, so consecutive
/// predictions are that far apart and each stands for that much activity.
/// Both bundled models use a 25-sample step (2 s). main() updates the HAR
/// value from the loaded model's metadata, so a retrained model with a
/// different step still reports correct durations.
double harPredictionSeconds = 25 / 12.5;
const double socialPredictionSeconds = 25 / 12.5;

/// HAR classes in model output order (harry_har_cnn_meta.json).
const List<String> harClassOrder = [
  'sittingStanding',
  'lyingBack',
  'lyingLeft',
  'lyingRight',
  'lyingStomach',
  'normalWalking',
  'shuffleWalking',
  'ascending',
  'descending',
  'running',
  'miscMovement',
];

/// Social classes in model output order (harry_social_rnn_meta.json).
const List<String> socialClassOrder = [
  'breathingNormally',
  'coughing',
  'hyperventilation',
  'other',
];

const Map<String, LabelInfo> _catalog = {
  // Static activities
  'sittingStanding': LabelInfo('sittingStanding', 'Sitting / Standing',
      Icons.chair_alt, Color(0xFF5C6BC0), LabelGroup.staticActivity),
  'lyingBack': LabelInfo('lyingBack', 'Lying on Back', Icons.airline_seat_flat,
      Color(0xFF26A69A), LabelGroup.staticActivity),
  'lyingLeft': LabelInfo('lyingLeft', 'Lying on Left Side', Icons.hotel,
      Color(0xFF42A5F5), LabelGroup.staticActivity),
  'lyingRight': LabelInfo('lyingRight', 'Lying on Right Side',
      Icons.airline_seat_individual_suite, Color(0xFF7E57C2),
      LabelGroup.staticActivity),
  'lyingStomach': LabelInfo('lyingStomach', 'Lying on Stomach',
      Icons.airline_seat_flat_angled, Color(0xFF8D6E63),
      LabelGroup.staticActivity),
  // Dynamic activities
  'normalWalking': LabelInfo('normalWalking', 'Walking', Icons.directions_walk,
      Color(0xFF66BB6A), LabelGroup.dynamicActivity),
  'shuffleWalking': LabelInfo('shuffleWalking', 'Shuffle Walking',
      Icons.elderly, Color(0xFF9CCC65), LabelGroup.dynamicActivity),
  'ascending': LabelInfo('ascending', 'Ascending Stairs', Icons.trending_up,
      Color(0xFFFFA726), LabelGroup.dynamicActivity),
  'descending': LabelInfo('descending', 'Descending Stairs',
      Icons.trending_down, Color(0xFFFF7043), LabelGroup.dynamicActivity),
  'running': LabelInfo('running', 'Running', Icons.directions_run,
      Color(0xFFEF5350), LabelGroup.dynamicActivity),
  'miscMovement': LabelInfo('miscMovement', 'Misc. Movement',
      Icons.accessibility_new, Color(0xFFAB47BC), LabelGroup.dynamicActivity),
  // Social signals
  'breathingNormally': LabelInfo('breathingNormally', 'Normal Breathing',
      Icons.air, Color(0xFF29B6F6), LabelGroup.social),
  'coughing': LabelInfo('coughing', 'Coughing', Icons.sick, Color(0xFFEC407A),
      LabelGroup.social),
  'hyperventilation': LabelInfo('hyperventilation', 'Hyperventilating',
      Icons.speed, Color(0xFFFFCA28), LabelGroup.social),
  'other': LabelInfo('other', 'Other Social Signals', Icons.record_voice_over,
      Color(0xFF78909C), LabelGroup.social),
};

/// Display information for a model label. Unknown labels (e.g. from a future
/// model with different classes) fall back to the raw label so nothing is
/// ever hidden from the user.
LabelInfo labelInfo(String label) =>
    _catalog[label] ??
    LabelInfo(label, label, Icons.help_outline, const Color(0xFF9E9E9E),
        LabelGroup.dynamicActivity);

String displayName(String label) => labelInfo(label).displayName;

bool isKnownLabel(String label) => _catalog.containsKey(label);

/// "1 h 05 min", "12 min 30 s", "8 s".
String formatDuration(Duration d) {
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60);
  final seconds = d.inSeconds.remainder(60);
  if (hours > 0) {
    return '$hours h ${minutes.toString().padLeft(2, '0')} min';
  }
  if (minutes > 0) {
    return '$minutes min ${seconds.toString().padLeft(2, '0')} s';
  }
  return '$seconds s';
}

/// Duration represented by [count] consecutive predictions; HAR by default.
Duration durationForPredictions(int count, {double? secondsEach}) =>
    Duration(
        milliseconds:
            (count * (secondsEach ?? harPredictionSeconds) * 1000).round());

/// Small round icon in the label's colour, used in lists and cards.
class LabelAvatar extends StatelessWidget {
  const LabelAvatar(this.label, {super.key, this.radius = 20});

  final String label;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final info = labelInfo(label);
    return CircleAvatar(
      radius: radius,
      backgroundColor: info.color.withValues(alpha: 0.18),
      child: Icon(info.icon, color: info.color, size: radius * 1.1),
    );
  }
}
