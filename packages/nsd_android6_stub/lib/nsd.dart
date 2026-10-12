import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

enum IpLookupType { any, ipv4, ipv6 }

class Service {
  Service({
    required this.name,
    required this.type,
    required this.port,
    this.host,
    this.txt,
    this.addresses,
  });

  final String name;
  final String type;
  final int? port;
  final String? host;
  final Map<String, Uint8List>? txt;
  final List<InternetAddress>? addresses;
}

class Discovery extends ChangeNotifier {
  final List<Service> services = [];
}

class Registration {
  Registration(this.service);

  final Service service;
}

Future<Registration> register(Service service) async => Registration(service);

Future<void> unregister(Registration registration) async {}

Future<Discovery> startDiscovery(
  String serviceType, {
  bool autoResolve = true,
  IpLookupType? ipLookupType,
}) async => Discovery();

Future<void> stopDiscovery(Discovery discovery) async {}

Future<Service> resolve(Service service) async => service;
