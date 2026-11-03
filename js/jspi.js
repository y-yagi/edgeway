const textDecoder = new TextDecoder("utf-8", { fatal: true });
const textEncoder = new TextEncoder();

// What the wasm side of a JSPI import module needs: C strings read from its
// memory, and a result handed over in two steps, since an import can't return
// a string. A suspending import answers the byte length of its JSON result and
// the wasm side then calls take(buffer) to copy it.
export function jspiHelpers(getInstance) {
  const memory = () => new Uint8Array(getInstance().exports.memory.buffer);
  let pending = new Uint8Array(0);

  const readBytes = (pointer) => {
    const bytes = memory();
    let end = pointer;
    while (bytes[end]) end++;
    return bytes.subarray(pointer, end);
  };

  const readCString = (pointer) => textDecoder.decode(readBytes(pointer));

  const setResult = (result) => {
    pending = textEncoder.encode(JSON.stringify(result));
    return pending.length;
  };

  const take = (buffer) => {
    memory().set(pending, buffer);
    pending = new Uint8Array(0);
  };

  return { readBytes, readCString, setResult, take };
}
