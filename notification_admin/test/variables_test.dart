// Widget tests for the Variables page: platform defaults, the product's own list, copying defaults and mismatches.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notification_admin/notification_admin.dart';

import 'fake.dart';

List<Map<String, dynamic>> defaults() => [
      {'name': 'body', 'type': 'string', 'description': 'Main message text'},
      {'name': 'link', 'type': 'string', 'description': 'Link to open the record'},
      {'name': 'subject', 'type': 'string', 'description': 'Short subject or title line', 'example': 'Water tank'},
    ];

Map<String, dynamic> report({List<String> missing = const ['link'], List<Map<String, dynamic>> problems = const []}) => {
      'variables': [
        {'name': 'body', 'type': 'string', 'source': 'platform', 'events': ['UPKEEP_TASK_DUE v2'], 'matchesPlatform': true},
        {'name': 'flat', 'type': 'string', 'source': 'product', 'description': 'Flat number', 'events': [], 'matchesPlatform': true},
        {'name': 'amount', 'type': 'string', 'source': 'product', 'events': ['X v1'], 'matchesPlatform': false},
      ],
      'missingDefaults': missing,
      'problems': problems,
    };

FakeEngine engine({Map<String, dynamic>? productReport}) => FakeEngine({
      'GET /v1/platform/variables': (_) => defaults(),
      'GET /v1/platform/products/cmm/variables': (_) => productReport ?? report(),
      'POST /v1/platform/products/cmm/variables/defaults': (_) => {'added': 1},
      'PUT /v1/platform/variables/due_date': (_) => {'name': 'due_date', 'type': 'string'},
      'PUT /v1/platform/variables/subject': (_) => {'name': 'subject', 'type': 'string'},
      'PUT /v1/platform/products/cmm/variables/visitor_name': (_) => {'name': 'visitor_name', 'type': 'string', 'source': 'product'},
    });

void main() {
  testWidgets('shows platform defaults and the product list with source, events and type warnings', (t) async {
    await big(t);
    final f = engine();
    await t.pumpWidget(host(VariablesPage(api: platformFor(f), productCode: 'cmm')));
    await t.pumpAndSettle();
    expect(find.text('CMM variables'), findsOneWidget);
    expect(find.byKey(const ValueKey('var-default-subject')), findsOneWidget);
    expect(find.byKey(const ValueKey('var-product-flat')), findsOneWidget);
    expect(find.text('Used by UPKEEP_TASK_DUE v2'), findsOneWidget);
    expect(find.text('Not used by any event yet'), findsOneWidget);
    expect(find.text('Type differs from platform'), findsOneWidget);
    expect(find.text('Example: Water tank'), findsOneWidget);
  });

  testWidgets('without a product only the platform defaults show', (t) async {
    await big(t);
    final f = engine();
    await t.pumpWidget(host(VariablesPage(api: platformFor(f), productCode: '')));
    await t.pumpAndSettle();
    expect(find.text('Platform defaults'), findsOneWidget);
    expect(find.byKey(const ValueKey('var-product-add')), findsNothing);
    expect(f.hits('GET /v1/platform/products/cmm/variables'), isEmpty);
  });

  testWidgets('copies missing defaults to the product', (t) async {
    await big(t);
    final f = engine();
    await t.pumpWidget(host(VariablesPage(api: platformFor(f), productCode: 'cmm')));
    await t.pumpAndSettle();
    expect(find.text('Copy missing defaults (1)'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('var-copy-defaults')));
    await t.pumpAndSettle();
    expect(f.hits('POST /v1/platform/products/cmm/variables/defaults'), hasLength(1));
    expect(find.text('1 default added'), findsOneWidget);
  });

  testWidgets('no copy button when the product has every default', (t) async {
    await big(t);
    await t.pumpWidget(host(VariablesPage(api: platformFor(engine(productReport: report(missing: []))), productCode: 'cmm')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('var-copy-defaults')), findsNothing);
  });

  testWidgets('adds a platform default with a type; bad names are refused in the dialog', (t) async {
    await big(t);
    final f = engine();
    await t.pumpWidget(host(VariablesPage(api: platformFor(f), productCode: 'cmm')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('var-default-add')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('var-name')), 'due-date');
    await t.tap(find.byKey(const ValueKey('var-save')));
    await t.pumpAndSettle();
    expect(find.text('Letters, digits and _ only, starting with a letter'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('var-name')), 'due_date');
    await t.enterText(find.byKey(const ValueKey('var-description')), 'Due date');
    await t.tap(find.byKey(const ValueKey('var-save')));
    await t.pumpAndSettle();
    expect(f.bodies('PUT /v1/platform/variables/due_date').single, {'type': 'string', 'description': 'Due date', 'example': null});
  });

  testWidgets('editing keeps the name and type and saves the wording', (t) async {
    await big(t);
    final f = engine();
    await t.pumpWidget(host(VariablesPage(api: platformFor(f), productCode: 'cmm')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('var-default-subject-edit')));
    await t.pumpAndSettle();
    expect(t.widget<TextField>(find.byKey(const ValueKey('var-name'))).enabled, isFalse);
    expect(find.text('The type cannot change once saved'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('var-example')), 'Lift repair today');
    await t.tap(find.byKey(const ValueKey('var-save')));
    await t.pumpAndSettle();
    expect(f.bodies('PUT /v1/platform/variables/subject').single['example'], 'Lift repair today');
  });

  testWidgets('adds a product variable', (t) async {
    await big(t);
    final f = engine();
    await t.pumpWidget(host(VariablesPage(api: platformFor(f), productCode: 'cmm')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('var-product-add')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('var-name')), 'visitor_name');
    await t.tap(find.byKey(const ValueKey('var-save')));
    await t.pumpAndSettle();
    expect(f.hits('PUT /v1/platform/products/cmm/variables/visitor_name'), hasLength(1));
    expect(find.text('Variable saved'), findsOneWidget);
  });

  testWidgets('lists events that do not match the product variables', (t) async {
    await big(t);
    final f = engine(productReport: report(problems: [
      {'event': 'A v2', 'name': 'due', 'type': 'string', 'expected': null},
      {'event': 'A v2', 'name': 'body', 'type': 'number', 'expected': 'string'},
    ]));
    await t.pumpWidget(host(VariablesPage(api: platformFor(f), productCode: 'cmm')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('var-problems')), findsOneWidget);
    expect(find.text('A v2: data.due is not a cmm variable yet'), findsOneWidget);
    expect(find.text('A v2: data.body is number, the variable is string'), findsOneWidget);
  });

  testWidgets('a type change refused by the engine shows its message', (t) async {
    await big(t);
    final f = engine();
    f.routes['PUT /v1/platform/variables/subject'] = (_) => err(409, 'type_locked', 'subject is string; add a variable with a new name instead');
    await t.pumpWidget(host(VariablesPage(api: platformFor(f), productCode: 'cmm')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('var-default-subject-edit')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('var-save')));
    await t.pumpAndSettle();
    expect(find.text('subject is string; add a variable with a new name instead'), findsOneWidget);
  });
}
