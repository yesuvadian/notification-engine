// Shared fake engine for the notification_admin tests.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:notification_admin/notification_admin.dart';

/// Routes are "METHOD /path-suffix" (query ignored). A handler returns JSON or an [http.Response].
class FakeEngine {
  final calls = <http.Request>[];
  final Map<String, dynamic Function(http.Request)> routes;
  FakeEngine(this.routes);

  MockClient get client => MockClient((r) async {
        calls.add(r);
        for (final e in routes.entries) {
          if (match(r, e.key)) {
            final v = e.value(r);
            if (v is http.Response) return v;
            return http.Response(jsonEncode(v), 200, headers: {'content-type': 'application/json'});
          }
        }
        return http.Response(jsonEncode({'error': 'not_found', 'message': 'No fake for ${r.method} ${r.url.path}'}), 404);
      });

  static bool match(http.Request r, String key) {
    final i = key.indexOf(' ');
    return r.method == key.substring(0, i) && r.url.path.endsWith(key.substring(i + 1));
  }

  List<http.Request> hits(String key) => calls.where((c) => match(c, key)).toList();
  List<Map<String, dynamic>> bodies(String key) =>
      hits(key).map((c) => Map<String, dynamic>.from(jsonDecode(c.body) as Map)).toList();
}

NotificationPlatformApi platformFor(FakeEngine f) => NotificationPlatformApi(
    baseUrl: Uri.parse('https://x.test/functions/v1/notification/'), accessToken: () async => 'admin-jwt', client: f.client);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

Future<void> big(WidgetTester t) async {
  t.view.physicalSize = const Size(1800, 2600);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

/// Taps the dialog's action button with [label] (last match, so the dialog wins over the page).
Future<void> tapText(WidgetTester t, String label) async {
  await t.tap(find.text(label).last);
  await t.pumpAndSettle();
}

http.Response err(int status, String code, String message) =>
    http.Response(jsonEncode({'error': code, 'message': message}), status);
