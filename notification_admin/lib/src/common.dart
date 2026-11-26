import 'package:flutter/material.dart';
import 'package:notification_sdk/notification_sdk.dart';

const kChannels = ['IN_APP', 'SMS', 'WHATSAPP', 'PUSH'];
const kExternalChannels = ['SMS', 'WHATSAPP', 'PUSH'];

String chLabel(String c) => const {'IN_APP': 'In-app', 'SMS': 'SMS', 'WHATSAPP': 'WhatsApp', 'PUSH': 'Push'}[c] ?? c;

/// Message for a failed request, using the engine's error message when there is one.
String errorText(Object e) {
  if (e is NotificationApiException) return e.message ?? 'Request failed (${e.status}${e.code == null ? '' : ' ${e.code}'})';
  return 'Request failed';
}

void toast(BuildContext context, String text) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// Runs [action], shows [done] or the error, and returns whether it worked.
Future<bool> runAction(BuildContext context, Future<void> Function() action, {String? done}) async {
  try {
    await action();
    if (done != null && context.mounted) toast(context, done);
    return true;
  } catch (e) {
    if (context.mounted) toast(context, errorText(e));
    return false;
  }
}

Widget channelChip(String c, {bool on = true}) => Padding(
      padding: const EdgeInsets.only(right: 4, bottom: 4),
      child: Chip(
          label: Text(chLabel(c)),
          visualDensity: VisualDensity.compact,
          backgroundColor: on ? null : Colors.transparent),
    );

Widget statusChip(String text, {Color? color}) => Chip(
      label: Text(text, style: TextStyle(color: color)),
      side: color == null ? null : BorderSide(color: color),
      visualDensity: VisualDensity.compact,
    );

/// Page header in the style of the existing super admin screens: title, optional subtitle, actions.
class PageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  const PageHeader(this.title, {super.key, this.subtitle, this.actions = const []});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              if (subtitle != null)
                Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(subtitle!, style: Theme.of(context).textTheme.bodySmall)),
            ]),
          ),
          ...actions,
        ]),
      );
}

/// Loads [load] and builds the result; shows a spinner, and a retry button on error.
class Loaded<T> extends StatefulWidget {
  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data, Future<void> Function() reload) builder;
  const Loaded({super.key, required this.load, required this.builder});
  @override
  State<Loaded<T>> createState() => _LoadedState<T>();
}

class _LoadedState<T> extends State<Loaded<T>> {
  late Future<T> future;
  T? last;
  bool hasLast = false;
  @override
  void initState() {
    super.initState();
    future = widget.load();
  }

  Future<void> reload() async {
    final f = widget.load();
    setState(() {
      future = f;
    });
    try {
      await f;
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
        future: future,
        builder: (context, s) {
          // While reloading, keep showing the previous data so forms and scroll position stay put.
          if (s.connectionState != ConnectionState.done) {
            return hasLast ? widget.builder(context, last as T, reload) : const Center(child: CircularProgressIndicator());
          }
          if (s.hasError) {
            return Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(errorText(s.error!)),
              TextButton(onPressed: reload, child: const Text('Retry')),
            ]));
          }
          last = s.data as T;
          hasLast = true;
          return widget.builder(context, last as T, reload);
        },
      );
}

/// Asks for a required reason; returns null when cancelled.
Future<String?> askReason(BuildContext context, {required String title, required String message, required String confirm}) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(message),
        const SizedBox(height: 12),
        TextField(controller: c, decoration: const InputDecoration(labelText: 'Reason (required)')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
            onPressed: () {
              if (c.text.trim().isNotEmpty) Navigator.pop(ctx, c.text.trim());
            },
            child: Text(confirm)),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, {required String title, required String message, required String action}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    ) ==
    true;
