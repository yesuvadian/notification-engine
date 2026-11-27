// Not part of CI: renders screenshots of the Notifications tab with real fonts. Run with SHOTS=1.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notification_admin/notification_admin.dart';

import '../events_tab_test.dart' as ev;
import '../fake.dart';

Future<void> loadFont(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    l.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
  }
  await l.load();
}

Future<void> shot(WidgetTester t, GlobalKey key, String name) async {
  await t.runAsync(() async {
    final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final img = await b.toImage(pixelRatio: 1);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    File('/mnt/project-files/notification-engine/screens/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

void main() {
  const fonts = '/opt/f338/flutter/bin/cache/artifacts/material_fonts';
  setUpAll(() async {
    await loadFont('Roboto', ['$fonts/Roboto-Regular.ttf', '$fonts/Roboto-Medium.ttf', '$fonts/Roboto-Bold.ttf']);
    await loadFont('MaterialIcons', ['$fonts/MaterialIcons-Regular.otf']);
    await loadFont('monospace', ['$fonts/Roboto-Regular.ttf']);
  });

  Widget app(Widget child, GlobalKey key) => RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(colorSchemeSeed: const Color(0xFF2D5B9A), fontFamily: 'Roboto'),
          home: Scaffold(appBar: AppBar(title: const Text('Hittop')), body: child),
        ),
      );

  testWidgets('screens', (t) async {
    t.view.physicalSize = const Size(1500, 1250);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final k = GlobalKey();
    final f = ev.engine(overrides: [
      {'id': 'ov1', 'template_id': 'due', 'channel': 'SMS', 'status': 'PUBLISHED', 'version': 1},
    ], bindings: [
      {'rule_id': 'r1', 'channel': 'IN_APP', 'template_id': 'due', 'template_version': 1},
      {'rule_id': 'r1', 'channel': 'SMS', 'template_id': 'due', 'template_version': 1},
    ], rules: [ev.dueRule(strategy: 'ALL_USERS_IN_ROLE', role: 'role-uuid-admin')]);
    await t.pumpWidget(app(OrganizationWorkspace(api: platformFor(f), productCode: 'cmm', organizationId: 'soc1', organizationName: 'Hittop'), k));
    await t.pumpAndSettle();
    await shot(t, k, '1-notifications-tab');

    f.routes['GET /v1/admin/templates/due/effective'] = (_) => {
          'master': {'content': {'title': 'Upkeep due · {{data.reference}}', 'body': '{{data.task_title}} at {{data.place}} is due {{data.due_date}}.'}},
          'override': null,
          'effective': {'title': 'Upkeep due · {{data.reference}}', 'body': '{{data.task_title}} at {{data.place}} is due {{data.due_date}}.'},
        };
    f.routes['GET /v1/admin/events/UPKEEP_TASK_DUE/variables'] = (_) => {
          'variables': [
            for (final v in ['subject', 'body', 'reference', 'task_title', 'place', 'due_date', 'status']) {'path': 'data.$v', 'type': 'string'},
            {'path': 'recipient.name', 'type': 'string'},
            {'path': 'organization.name', 'type': 'string'},
          ]
        };
    await t.tap(find.byKey(const ValueKey('wording-UPKEEP_TASK_DUE-IN_APP')));
    await t.pumpAndSettle();
    await shot(t, k, '2-wording-editor');
  }, skip: Platform.environment['SHOTS'] != '1');
}
