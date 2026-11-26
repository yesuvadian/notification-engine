import 'dart:async';
import 'package:flutter/material.dart';
import 'api.dart';
class NotificationInbox extends StatefulWidget {
  final NotificationApi api; final Future<void> Function(Map<String,dynamic>) onAction;
  const NotificationInbox({super.key,required this.api,required this.onAction});
  @override State<NotificationInbox> createState()=>_InboxState();
}
class _InboxState extends State<NotificationInbox>{
  late Future<List<NotificationItem>> items;
  @override void initState(){super.initState();items=widget.api.inbox();}
  @override void didUpdateWidget(NotificationInbox old){super.didUpdateWidget(old);if(old.api!=widget.api)items=widget.api.inbox();}
  Future<void> refresh() async {setState(()=>items=widget.api.inbox());try{await items;}catch(_){} }
  @override Widget build(BuildContext context)=>FutureBuilder<List<NotificationItem>>(future:items,builder:(context,s){
    if(s.connectionState!=ConnectionState.done)return const Center(child:CircularProgressIndicator());
    if(s.hasError)return Center(child:TextButton(onPressed:refresh,child:const Text('Could not load. Retry')));
    final rows=s.data??[];
    return RefreshIndicator(onRefresh:refresh,child:ListView(physics:const AlwaysScrollableScrollPhysics(),children:[if(rows.isEmpty)const ListTile(title:Text('No notifications')),for(final n in rows) Card(child:ListTile(leading:Icon(n.read?Icons.notifications_none:Icons.notifications_active),title:Text(n.title),subtitle:Text(n.body),onTap:() async {final api=widget.api;try{await api.markRead(n.id);if(!mounted||api!=widget.api)return;await refresh();if(mounted&&api==widget.api&&n.action!=null)await widget.onAction(n.action!);}catch(_){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Notification action failed')));}}))]));
  });
}
class NotificationBell extends StatefulWidget {final NotificationApi api;final VoidCallback onPressed;/// Organization setting `unreadBadge` (MemberSettings.unreadBadge).
final bool showBadge;const NotificationBell({super.key,required this.api,required this.onPressed,this.showBadge=true});@override State<NotificationBell> createState()=>_BellState();}
class _BellState extends State<NotificationBell>{Timer? timer;int? count;int generation=0;Future<void> load() async{final g=++generation;try{final n=await widget.api.unreadCount();if(mounted&&g==generation)setState(()=>count=n);}catch(_){if(mounted&&g==generation)setState(()=>count=null);}}@override void initState(){super.initState();load();timer=Timer.periodic(const Duration(seconds:30),(_)=>load());}@override void didUpdateWidget(NotificationBell old){super.didUpdateWidget(old);if(old.api!=widget.api){count=null;load();}}@override void dispose(){timer?.cancel();super.dispose();}@override Widget build(BuildContext context)=>IconButton(tooltip:'Notifications',onPressed:widget.onPressed,icon:Badge(isLabelVisible:widget.showBadge&&(count??0)>0,label:Text('${count??0}'),child:const Icon(Icons.notifications_outlined)));}
