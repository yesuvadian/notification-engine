import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:notification_sdk/notification_sdk.dart';

import 'common.dart';
import 'platform_api.dart';

/// Renders `{{path}}` and `{{path | formatter}}` against sample data for the live preview.
/// Missing variables are shown as ⟨path⟩ and reported in [PreviewResult.missing].
class PreviewResult {
  final String text;
  final List<String> missing;
  const PreviewResult(this.text, this.missing);
}

PreviewResult renderPreview(String template, Map<String, dynamic> data) {
  final missing = <String>[];
  final out = template.replaceAllMapped(RegExp(r'{{\s*([\w.\[\]]+)\s*(?:\|\s*(\w+)(?::"([^"]*)")?)?\s*}}'), (m) {
    final path = m.group(1)!, f = m.group(2), arg = m.group(3);
    dynamic v = data;
    for (final k in path.split('.')) {
      v = v is Map ? v[k] : null;
    }
    if (v == null && f == 'default') return arg ?? '';
    if (v == null) {
      missing.add(path);
      return '⟨$path⟩';
    }
    switch (f) {
      case 'uppercase':
        return '$v'.toUpperCase();
      case 'lowercase':
        return '$v'.toLowerCase();
      case 'number':
        final n = num.tryParse('$v');
        if (n == null) return '$v';
        final s = n.toStringAsFixed(n % 1 == 0 ? 0 : 2);
        return s.replaceAllMapped(RegExp(r'(\d)(?=(\d\d)+\d(\.|$))'), (x) => '${x[1]},'); // Indian grouping
      default:
        return '$v';
    }
  });
  return PreviewResult(out, missing);
}

/// SMS length and segment count (GSM 160 / 153 per segment).
String smsInfo(String text) {
  final n = text.length, seg = n <= 160 ? 1 : (n / 153).ceil();
  return '$n characters · $seg SMS segment${seg > 1 ? 's' : ''}';
}

/// Fields each channel's content has, in the order the designer shows them.
const channelFields = {
  'IN_APP': ['title', 'body'],
  'SMS': ['body', 'msg91_template_id', 'dlt_template_id'],
  'WHATSAPP': ['template_name', 'language', 'params'],
  'PUSH': ['title', 'body', 'route'],
};

/// D5 / B7: template designer.
///
/// * [TemplateDesigner.platform] edits the platform template: saving creates or updates the draft version,
///   Publish makes it the version new organizations start on.
/// * [TemplateDesigner.override] edits one organization's override of the version it is pinned to: only the
///   fields changed are stored; Reset to platform removes the override.
class TemplateDesigner extends StatefulWidget {
  final NotificationPlatformApi? platformApi;
  final NotificationApi? orgApi;
  final Json template;
  final int? baseVersion;
  final String? eventCode;
  final String initialChannel;

  const TemplateDesigner.platform({super.key, required NotificationPlatformApi api, required this.template, this.initialChannel = 'IN_APP'})
      : platformApi = api,
        orgApi = null,
        baseVersion = null,
        eventCode = null;

  const TemplateDesigner.override(
      {super.key, required NotificationApi api, required this.template, required int this.baseVersion, this.eventCode, this.initialChannel = 'IN_APP'})
      : orgApi = api,
        platformApi = null;

  bool get isOverride => orgApi != null;

  @override
  State<TemplateDesigner> createState() => TemplateDesignerState();
}

class TemplateDesignerState extends State<TemplateDesigner> {
  late String channel = widget.initialChannel;
  final controllers = <String, TextEditingController>{};
  final sample = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert({
    'recipient': {'name': 'Anita Rao'},
    'data': {'amount': 12500, 'flat': 'B-402', 'reference': 'RC-2291'}
  }));
  Json base = {};
  Json? current;
  List<Json> variables = [];
  bool loading = true, busy = false;
  TextEditingController? focused;

  @override
  void initState() {
    super.initState();
    load();
  }

  List<Json> get versions => (widget.template['versions'] as List? ?? []).map((v) => Map<String, dynamic>.from(v as Map)).toList();

  Future<void> load() async {
    setState(() => loading = true);
    try {
      if (widget.isOverride) {
        final eff = await widget.orgApi!.effectiveTemplate(widget.template['id'] as String, channel);
        base = Map<String, dynamic>.from(eff['master']['content'] as Map);
        current = eff['override'] == null ? null : Map<String, dynamic>.from(eff['override'] as Map);
        final effective = Map<String, dynamic>.from(eff['effective'] as Map);
        _fill(effective);
        if (widget.eventCode != null && variables.isEmpty) {
          try {
            variables = await widget.orgApi!.eventVariables(widget.eventCode!);
          } catch (_) {}
        }
      } else {
        final draft = versions.where((v) => v['channel'] == channel && v['status'] == 'DRAFT').toList();
        final published = versions.where((v) => v['channel'] == channel && v['status'] == 'PUBLISHED').toList()
          ..sort((a, b) => (b['version'] as int).compareTo(a['version'] as int));
        final src = draft.isNotEmpty ? draft.first : (published.isNotEmpty ? published.first : null);
        base = src == null ? {} : Map<String, dynamic>.from(src['content'] as Map);
        _fill(base);
      }
    } catch (e) {
      base = {};
      _fill({});
      if (mounted) toast(context, errorText(e));
    }
    if (mounted) setState(() => loading = false);
  }

  void _fill(Json content) {
    for (final f in channelFields[channel]!) {
      final v = content[f];
      final text = v == null ? '' : (v is String ? v : jsonEncode(v));
      (controllers[f] ??= TextEditingController()).text = text;
    }
  }

  Json content() {
    final c = <String, dynamic>{};
    for (final f in channelFields[channel]!) {
      final t = controllers[f]!.text;
      if (t.trim().isEmpty) continue;
      if (f == 'params') {
        try {
          c[f] = jsonDecode(t);
          continue;
        } catch (_) {}
      }
      c[f] = t;
    }
    return c;
  }

  /// Only the fields that differ from the platform version (what an override stores).
  Json patch() {
    final c = content(), p = <String, dynamic>{};
    for (final e in c.entries) {
      if (jsonEncode(base[e.key]) != jsonEncode(e.value)) p[e.key] = e.value;
    }
    return p;
  }

  void insertVariable(String path) {
    final c = focused ?? controllers[channelFields[channel]!.contains('body') ? 'body' : channelFields[channel]!.first]!;
    final sel = c.selection;
    final t = '{{$path}}';
    final start = sel.isValid ? sel.start : c.text.length, end = sel.isValid ? sel.end : c.text.length;
    c.value = TextEditingValue(text: c.text.replaceRange(start, end, t), selection: TextSelection.collapsed(offset: start + t.length));
    setState(() {});
  }

  Future<void> saveDraft() async {
    setState(() => busy = true);
    await runAction(context, () async {
      final saved = await widget.platformApi!.saveDraft(widget.template['id'] as String, channel, content());
      final list = <dynamic>[...?(widget.template['versions'] as List?)];
      list.removeWhere((v) => (v as Map)['channel'] == channel && v['version'] == saved['version']);
      list.add(saved);
      widget.template['versions'] = list;
    }, done: 'Draft saved');
    if (mounted) setState(() => busy = false);
  }

  Future<void> publish() async {
    final draft = versions.where((v) => v['status'] == 'DRAFT').map((v) => v['version'] as int).toSet();
    if (draft.isEmpty) {
      toast(context, 'Save a draft first');
      return;
    }
    final v = draft.first;
    if (!await confirm(context,
        title: 'Publish v$v?',
        message: 'New organizations start on v$v. Existing organizations stay on their version until you upgrade them.',
        action: 'Publish')) {
      return;
    }
    if (!mounted) return;
    await runAction(context, () async {
      await widget.platformApi!.publishVersion(widget.template['id'] as String, v);
      for (final x in (widget.template['versions'] as List)) {
        if ((x as Map)['version'] == v) x['status'] = 'PUBLISHED';
      }
    }, done: 'v$v published');
    if (mounted) setState(() {});
  }

  Future<void> publishOverride() async {
    final p = patch();
    if (p.isEmpty) {
      toast(context, 'Nothing changed from the platform template');
      return;
    }
    await runAction(context, () => widget.orgApi!.publishOverride(widget.template['id'] as String, widget.baseVersion!, channel, p),
        done: 'Override published');
    await load();
  }

  Future<void> resetOverride() async {
    if (current == null) return;
    if (!await confirm(context, title: 'Reset to platform?', message: 'The organization goes back to the platform template.', action: 'Reset')) return;
    if (!mounted) return;
    await runAction(context, () => widget.orgApi!.resetOverride(current!['id'] as String), done: 'Override removed');
    await load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    Map<String, dynamic> data;
    String? sampleError;
    try {
      data = Map<String, dynamic>.from(jsonDecode(sample.text) as Map);
    } catch (_) {
      data = {};
      sampleError = 'Sample data is not valid JSON';
    }
    final previewTitle = renderPreview(controllers['title']?.text ?? '', data);
    final previewBody = renderPreview(controllers['body']?.text ?? controllers['params']?.text ?? '', data);
    final missing = {...previewTitle.missing, ...previewBody.missing};
    final vars = variables.isNotEmpty
        ? variables.map((v) => v['path'] as String).toList()
        : ['recipient.name', 'data.amount', 'data.reference', 'data.flat'];

    final editor = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final f in channelFields[channel]!)
        Focus(
          onFocusChange: (has) {
            if (has) focused = controllers[f];
          },
          child: TextField(
            key: ValueKey('field-$f'),
            controller: controllers[f],
            maxLines: f == 'body' || f == 'params' ? 4 : 1,
            decoration: InputDecoration(labelText: f),
            onChanged: (_) => setState(() {}),
          ),
        ),
      if (channel == 'SMS') Padding(padding: const EdgeInsets.only(top: 4), child: Text(smsInfo(previewBody.text), key: const ValueKey('sms-info'))),
      const SizedBox(height: 8),
      const Text('Insert variable'),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final v in vars) ActionChip(key: ValueKey('var-$v'), label: Text('{{$v}}'), onPressed: () => insertVariable(v)),
      ]),
      const SizedBox(height: 12),
      Wrap(spacing: 8, children: widget.isOverride
          ? [
              if (current != null) OutlinedButton(onPressed: busy ? null : resetOverride, child: const Text('Reset to platform')),
              FilledButton(onPressed: busy ? null : publishOverride, child: const Text('Publish override')),
            ]
          : [
              OutlinedButton(onPressed: busy ? null : saveDraft, child: const Text('Save draft')),
              FilledButton(onPressed: busy ? null : publish, child: const Text('Publish')),
            ]),
    ]);

    final preview = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Live preview · sample data'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (previewTitle.text.isNotEmpty) Text(previewTitle.text, key: const ValueKey('preview-title'), style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(previewBody.text, key: const ValueKey('preview-body')),
          ]),
        ),
      ),
      if (sampleError != null) Text(sampleError, style: const TextStyle(color: Colors.red)),
      if (missing.isEmpty && sampleError == null) const Text('All variables resolve', key: ValueKey('vars-ok')),
      if (missing.isNotEmpty) Text('Missing: ${missing.join(', ')}', key: const ValueKey('vars-missing'), style: const TextStyle(color: Colors.red)),
      TextField(
          key: const ValueKey('sample'),
          controller: sample,
          maxLines: 6,
          decoration: const InputDecoration(labelText: 'Sample data (from the event schema)'),
          onChanged: (_) => setState(() {})),
    ]);

    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(
          widget.isOverride
              ? 'Override for this organization on v${widget.baseVersion}. Only changed fields are stored; the rest follows the platform version.'
              : 'Editing the platform template. Saving updates the draft; publishing sets the version new organizations start on.',
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 8),
      SegmentedButton<String>(
        segments: [for (final c in kChannels) ButtonSegment(value: c, label: Text(chLabel(c)))],
        selected: {channel},
        onSelectionChanged: (s) {
          channel = s.first;
          load();
        },
      ),
      if (widget.isOverride && current != null)
        Padding(padding: const EdgeInsets.only(top: 8), child: statusChip('Override v${current!['version']} published', color: Colors.orange)),
      const SizedBox(height: 12),
      LayoutBuilder(
          builder: (context, c) => c.maxWidth > 760
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: editor),
                  const SizedBox(width: 16),
                  Expanded(child: preview),
                ])
              : Column(children: [editor, const SizedBox(height: 16), preview])),
    ]);
  }
}
