import 'dart:async';

/// One decoded RESpeck packet: when it reached the app (phone clock), its
/// sequence number and its samples (x, y, z in g, oldest first; the last one
/// was measured just before the packet was sent, each earlier one 80 ms
/// before the next).
class RespeckPacket {
  const RespeckPacket({
    required this.receivedAt,
    required this.sequence,
    required this.samples,
  });

  final DateTime receivedAt;
  final int sequence;
  final List<({double x, double y, double z})> samples;
}

/// Fan-out of raw RESpeck packets to tools that need the samples with their
/// arrival time (the sensor-to-app delay test). ble.dart only builds a packet
/// when someone is listening, so this costs nothing otherwise.
class RespeckPacketFeed {
  final StreamController<RespeckPacket> _packets =
      StreamController<RespeckPacket>.broadcast();

  Stream<RespeckPacket> get packets => _packets.stream;
  bool get hasListener => _packets.hasListener;

  void add(RespeckPacket packet) => _packets.add(packet);
}

/// App-wide instance, fed by ble.dart.
final RespeckPacketFeed respeckPacketFeed = RespeckPacketFeed();
