import 'dart:convert';
import 'package:flutter/material.dart';
import 'api.dart';
/// JSON-based starter editor; server must validate schema and authorization.
class NotificationAdmin extends StatefulWidget {
 final NotificationApi api;
 const NotificationAdmin({super.key,required this.api});
 @override State<NotificationAdmin> createState()=>_AdminState();
}
class _AdminState extends State<NotificationAdmin>{
 final editor=TextEditingController(text:'{}');
 String resource='templates'; String result=''; bool busy=false; int generation=0;
 static const resources=['templates','events','roles','rules','channels','overrides','deliveries','audit'];
 @override void didUpdateWidget(NotificationAdmin old){super.didUpdateWidget(old);if(old.api!=widget.api){generation++;editor.text='{}';result='';busy=false;}}
 Future<void> run(String operation) async {final g=++generation;setState(()=>busy=true);try{final api=widget.api;final path=operation=='preview'?'/v1/admin/templates/preview':'/v1/admin/$resource';final body=operation=='load'?null:Map<String,dynamic>.from(jsonDecode(editor.text));final data=await api.request(operation=='load'?'GET':'POST',path,body:body);if(mounted&&g==generation)setState(()=>result=const JsonEncoder.withIndent('  ').convert(data));}catch(_){if(mounted&&g==generation)setState(()=>result='Request failed or invalid JSON');}finally{if(mounted&&g==generation)setState(()=>busy=false);}}
 @override void dispose(){editor.dispose();super.dispose();}
 @override Widget build(BuildContext context)=>ListView(padding:const EdgeInsets.all(16),children:[DropdownButton<String>(value:resource,items:resources.map((r)=>DropdownMenuItem(value:r,child:Text(r))).toList(),onChanged:busy?null:(v)=>setState((){resource=v!;editor.text='{}';result='';})),TextField(controller:editor,maxLines:12,decoration:const InputDecoration(labelText:'Configuration JSON',border:OutlineInputBorder())),Wrap(spacing:8,children:[OutlinedButton(onPressed:busy?null:()=>run('load'),child:const Text('Load')),FilledButton(onPressed:busy||!['rules','channels','overrides'].contains(resource)?null:()=>run('save'),child:const Text('Save')),OutlinedButton(onPressed:busy?null:()=>run('preview'),child:const Text('Preview template'))]),if(busy)const LinearProgressIndicator(),SelectableText(result)]);
}
