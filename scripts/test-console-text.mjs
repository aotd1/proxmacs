import test from 'node:test';
import assert from 'node:assert/strict';
import { textKeys, typeKeys } from '../web/src/views/vm/consoleText.ts';

test('preserves password whitespace and punctuation, never appends Enter', () => {
 const text = ' A!@#$%^&*()_+-=[]{};:\'",.<>/?\\|`~  ';
 assert.deepEqual(textKeys(text, false), Array.from(text, c => c.codePointAt(0)));
});
test('Unicode code points are not split into UTF-16 surrogate keys', () => {
 assert.deepEqual(textKeys('éЯ😀', false), [233,0x0100042f,0x0101f600]);
});
test('line breaks and tabs require opt-in, CRLF is one Enter', () => {
 assert.throws(() => textKeys('a\r\nb\tc', false));
 assert.deepEqual(textKeys('a\r\nb\tc\r', true), [97,0xff0d,98,0xff09,99,0xff0d]);
});
test('rejects entire invalid payload before sending', () => {
 for (const value of ['', 'a\x00b', 'a\x1bb', '\x7f', '\ud800', 'x'.repeat(4097)]) assert.throws(() => textKeys(value,true));
 assert.equal(textKeys('x'.repeat(4096),false).length,4096);
});
test('cancellation releases current key, stops immediately, never replays', async () => {
 const control = new AbortController(); const events=[];
 const sent=await typeKeys([65,66,67],(key,down)=>{events.push([key,down]);if(down)control.abort();},control.signal,()=>{},1);
 assert.equal(sent,1);assert.deepEqual(events,[[65,true],[65,false]]);
 assert.equal(await typeKeys([68],()=>assert.fail('sent after cancel'),control.signal,()=>{},1),0);
});
test('transport error still attempts key release', async () => {
 const events=[];
 await assert.rejects(typeKeys([65],(key,down)=>{events.push([key,down]);if(down)throw Error('closed');},new AbortController().signal,()=>{},1));
 assert.deepEqual(events,[[65,true],[65,false]]);
});
test('normal completion reports progress without a submit key', async () => {
 const events=[], progress=[];
 assert.equal(await typeKeys([65,66],(key,down)=>events.push([key,down]),new AbortController().signal,n=>progress.push(n),1),2);
 assert.deepEqual(events,[[65,true],[65,false],[66,true],[66,false]]);assert.deepEqual(progress,[1,2]);
});
