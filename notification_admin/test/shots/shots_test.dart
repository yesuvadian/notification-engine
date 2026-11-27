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
  // Screenshots only on request (they need the Linux Flutter font cache below).
  if (Platform.environment['SHOTS'] != '1') {
    test('screenshots', () {}, skip: 'Set SHOTS=1 to render the screenshots');
    return;
  }
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
      {'rule_id': 'r2', 'channel': 'IN_APP', 'template_id': 'msg', 'template_version': 1},
      {'rule_id': 'r3', 'channel': 'IN_APP', 'template_id': 'msg', 'template_version': 1},
    ], rules: [
      ev.dueRule(strategy: 'ALL_USERS_IN_ROLE', role: 'role-uuid-admin'),
      {'id': 'r2', 'event_code': 'UPKEEP_TASK_DONE', 'event_version': 2, 'recipient_strategy': 'RECIPIENTS', 'active': true},
      {'id': 'r3', 'event_code': 'VISITOR_OVERSTAY', 'event_version': 2, 'recipient_strategy': 'ALL_USERS_IN_ROLE', 'role_code': 'role-uuid-treasurer', 'active': false},
    ]);
    f.routes['GET /v1/admin/events'] = (_) => [
          for (final c in ['UPKEEP_TASK_DUE', 'UPKEEP_TASK_OVERDUE', 'UPKEEP_TASK_DONE', 'UPKEEP_TASK_CHECK', 'UPKEEP_TASK_SENT_BACK'])
            {'code': c, 'version': 2, 'module_code': 'UPKEEP'},
          for (final c in ['VISITOR_BLOCKED', 'VISITOR_OVERSTAY']) {'code': c, 'version': 2, 'module_code': 'VISITORS'},
        ];
    await t.pumpWidget(app(OrganizationWorkspace(api: platformFor(f), productCode: 'cmm', organizationId: 'soc1', organizationName: 'Hittop'), k));
    await t.pumpAndSettle();
    await shot(t, k, '3-grouped-collapsed');
    await t.tap(find.text('Upkeep task due'));
    await t.pumpAndSettle();
    await shot(t, k, '4-one-event-open');

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
    await shot(t, k, '5-wording-editor');
  }, skip: Platform.environment['SHOTS'] != '1');
}
