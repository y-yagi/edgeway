import assert from "node:assert/strict";
import { jspiHelpers } from "../../js/jspi.js";

let count = 0;
function test(name, fn) {
  fn();
  count++;
  console.log(`ok   js jspi ${name}`);
}

const memory = new WebAssembly.Memory({ initial: 1 });
const bytes = new Uint8Array(memory.buffer);
const helpers = jspiHelpers(() => ({ exports: { memory } }));

test("readCString reads up to the NUL", () => {
  bytes.set(new TextEncoder().encode("héllo\0rest"), 16);
  assert.equal(helpers.readCString(16), "héllo");
});

test("readBytes keeps bytes that are not UTF-8", () => {
  bytes.set([0xff, 0xfe, 0], 32);
  assert.deepEqual([...helpers.readBytes(32)], [0xff, 0xfe]);
});

test("a result is its byte length, copied once by take", () => {
  const length = helpers.setResult({ value: "é" });
  assert.equal(length, new TextEncoder().encode('{"value":"é"}').length);
  helpers.take(100);
  assert.equal(new TextDecoder().decode(bytes.subarray(100, 100 + length)), '{"value":"é"}');
  bytes.fill(0, 100, 100 + length);
  helpers.take(100);
  assert.equal(bytes[100], 0);
});

console.log(`${count} js jspi tests`);
