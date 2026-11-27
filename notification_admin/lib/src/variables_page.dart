import 'package:flutter/material.dart';

import 'common.dart';
import 'platform_api.dart';

const kVariableTypes = ['string', 'number', 'integer', 'boolean', 'object', 'array'];

/// Template variables. They are product level: each product keeps its own list, which starts as a copy of the
/// platform defaults. The engine refuses an event field whose type differs from the product's variable of that
/// name, and adds a new field to the product's list. Types never change once saved; wording can.
class VariablesPage extends StatefulWidget {
  final NotificationPlatformApi api;

  /// Product chosen at console login; empty shows only the platform defaults.
  final String productCode;
  const VariablesPage({super.key, required this.api, required this.productCode});
  @override
  State<VariablesPage> createState() => _VariablesPageState();
}

class _VariablesPageState extends State<VariablesPage> {
  int key = 0;
  bool get hasProduct => widget.productCode.isNotEmpty;

  Future<(List<Json>, Json?)> load() async {
    final defaults = await widget.api.variableDefaults();
    final product = hasProduct ? await widget.api.productVariables(widget.productCode) : null;
    return (defaults, product);
  }

  Future<void> edit({Json? row, required bool platform}) async {
    final r = await showDialog<_VariableInput>(context: context, builder: (_) => _VariableDialog(row: row, platform: platform));
    if (r == null || !mounted) return;
    final ok = await runAction(
        context,
        () => platform
            ? widget.api.saveVariableDefault(r.name, type: r.type, description: r.description, example: r.example)
            : widget.api.saveProductVariable(widget.productCode, r.name, type: r.type, description: r.description, example: r.example),
        done: 'Variable saved');
    if (ok) setState(() => key++);
  }

  Future<void> copyDefaults() async {
    var added = 0;
    final ok = await runAction(context, () async => added = await widget.api.copyVariableDefaults(widget.productCode));
    if (ok && mounted) {
      toast(context, added == 1 ? '1 default added' : '$added defaults added');
      setState(() => key++);
    }
  }

  @override
  Widget build(BuildContext context) => Loaded<(List<Json>, Json?)>(
        key: ValueKey(key),
        load: load,
        builder: (context, data, reload) {
          final (defaults, product) = data;
          return ListView(children: [
            const PageHeader('Template variables',
                subtitle: 'Each product has its own variables, starting from the platform defaults. An event field must have the same '
                    'type as the product variable of that name; new fields are added to the product. Every template can also use '
                    'recipient.name, recipient.id, recipient.locale and organization.name.'),
            if (product != null) ..._product(product),
            _section('Platform defaults', 'Copied to every new product. A product keeps its copy when a default changes later.',
                action: FilledButton.icon(
                    key: const ValueKey('var-default-add'),
                    onPressed: () => edit(platform: true),
                    icon: const Icon(Icons.add),
                    label: const Text('Add default'))),
            for (final v in defaults)
              _VariableTile(v: v, keyPrefix: 'var-default', onEdit: () => edit(row: v, platform: true)),
            const SizedBox(height: 24),
          ]);
        },
      );

  List<Widget> _product(Json report) {
    final vars = List<Json>.from((report['variables'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)));
    final missing = List<String>.from(report['missingDefaults'] as List? ?? []);
    final problems = List<Json>.from((report['problems'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)));
    final pc = widget.productCode;
    return [
      _section('${pc.toUpperCase()} variables', 'What $pc events send in data, and the events that use each one.',
          action: Wrap(spacing: 8, children: [
            if (missing.isNotEmpty)
              OutlinedButton(
                  key: const ValueKey('var-copy-defaults'),
                  onPressed: copyDefaults,
                  child: Text('Copy missing defaults (${missing.length})')),
            FilledButton.icon(
                key: const ValueKey('var-product-add'),
                onPressed: () => edit(platform: false),
                icon: const Icon(Icons.add),
                label: const Text('Add variable')),
          ])),
      if (problems.isNotEmpty)
        Card(
          key: const ValueKey('var-problems'),
          margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          color: Theme.of(context).colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Events that do not match', style: TextStyle(fontWeight: FontWeight.w600)),
              for (final p in problems)
                Text(p['expected'] == null
                    ? '${p['event']}: data.${p['name']} is not a $pc variable yet'
                    : '${p['event']}: data.${p['name']} is ${p['type']}, the variable is ${p['expected']}'),
            ]),
          ),
        ),
      for (final v in vars) _VariableTile(v: v, keyPrefix: 'var-product', onEdit: () => edit(row: v, platform: false)),
      const SizedBox(height: 16),
    ];
  }

  Widget _section(String title, String subtitle, {Widget? action}) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
          if (action != null) action,
        ]),
      );
}

class _VariableTile extends StatelessWidget {
  final Json v;
  final String keyPrefix;
  final VoidCallback onEdit;
  const _VariableTile({required this.v, required this.keyPrefix, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final events = List<String>.from(v['events'] as List? ?? []);
    final source = v['source'] as String?;
    final mismatch = v['matchesPlatform'] == false;
    return Card(
      key: ValueKey('$keyPrefix-${v['name']}'),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        title: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('data.${v['name']}', style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600)),
          statusChip('${v['type']}'),
          if (source != null) statusChip(source == 'platform' ? 'Platform default' : 'Product'),
          if (mismatch) statusChip('Type differs from platform', color: Theme.of(context).colorScheme.error),
        ]),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if ((v['description'] ?? '').toString().isNotEmpty) Text('${v['description']}'),
          if ((v['example'] ?? '').toString().isNotEmpty) Text('Example: ${v['example']}'),
          if (v.containsKey('events')) Text(events.isEmpty ? 'Not used by any event yet' : 'Used by ${events.join(', ')}'),
        ]),
        trailing: IconButton(key: ValueKey('$keyPrefix-${v['name']}-edit'), tooltip: 'Edit wording', icon: const Icon(Icons.edit_outlined), onPressed: onEdit),
      ),
    );
  }
}

class _VariableInput {
  final String name, type;
  final String? description, example;
  _VariableInput(this.name, this.type, this.description, this.example);
}

class _VariableDialog extends StatefulWidget {
  final Json? row;
  final bool platform;
  const _VariableDialog({this.row, required this.platform});
  @override
  State<_VariableDialog> createState() => _VariableDialogState();
}

class _VariableDialogState extends State<_VariableDialog> {
  late final name = TextEditingController(text: widget.row?['name'] as String? ?? '');
  late final description = TextEditingController(text: widget.row?['description'] as String? ?? '');
  late final example = TextEditingController(text: widget.row?['example'] as String? ?? '');
  late String type = widget.row?['type'] as String? ?? 'string';
  String? error;
  bool get editing => widget.row != null;

  void save() {
    final n = name.text.trim();
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,49}$').hasMatch(n)) {
      setState(() => error = 'Letters, digits and _ only, starting with a letter');
      return;
    }
    String? opt(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    Navigator.pop(context, _VariableInput(n, type, opt(description), opt(example)));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(editing ? 'Edit data.${widget.row!['name']}' : (widget.platform ? 'New platform default' : 'New product variable')),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                key: const ValueKey('var-name'),
                controller: name,
                enabled: !editing,
                decoration: InputDecoration(labelText: 'Name (sent as data.<name>)', errorText: error)),
            DropdownButtonFormField<String>(
              key: const ValueKey('var-type'),
              initialValue: type,
              decoration: InputDecoration(labelText: 'Type', helperText: editing ? 'The type cannot change once saved' : null),
              items: [for (final t in kVariableTypes) DropdownMenuItem(value: t, child: Text(t))],
              onChanged: editing ? null : (v) => setState(() => type = v ?? 'string'),
            ),
            TextField(key: const ValueKey('var-description'), controller: description, decoration: const InputDecoration(labelText: 'Description')),
            TextField(key: const ValueKey('var-example'), controller: example, decoration: const InputDecoration(labelText: 'Example value')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('var-save'), onPressed: save, child: const Text('Save')),
        ],
      );
}
