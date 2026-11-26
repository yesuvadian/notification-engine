import {test} from 'node:test';import assert from 'node:assert/strict';import {render,merge,path} from '../supabase/functions/notification/parser.mjs';
test('nested and fallback',()=>assert.equal(render('{{data.items[0].name}} {{missing | default:"ok"}}',{data:{items:[{name:'A'}]}}),'A ok'));
test('missing fails',()=>assert.throws(()=>render('{{missing}}',{})));
test('override',()=>assert.deepEqual(merge({design:{icon:'a',color:'b'}},{design:{color:'c'}}),{design:{icon:'a',color:'c'}}));
test('prototype blocked',()=>assert.equal(path({},'constructor'),undefined));
test('condition',()=>assert.equal(render('{{#if data.ok}}yes{{/if}}',{data:{ok:true}}),'yes'));
