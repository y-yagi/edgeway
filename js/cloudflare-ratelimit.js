const textDecoder = new TextDecoder("utf-8", { fatal: true });

const isRateLimit = (value) => Boolean(value) && typeof value.limit === "function";

export function rateLimitImports(env, getInstance) {
  const memory = () => new Uint8Array(getInstance().exports.memory.buffer);
  const readCString = (pointer) => {
    const bytes = memory();
    let end = pointer;
    while (bytes[end]) end++;
    return textDecoder.decode(bytes.subarray(pointer, end));
  };
  let pending = new Uint8Array(0);

  const check = new WebAssembly.Suspending(async (bindingPointer, keyPointer) => {
    let result;
    try {
      const bindingName = readCString(bindingPointer);
      const rateLimit = env[bindingName];
      if (isRateLimit(rateLimit)) {
        const { success } = await rateLimit.limit({ key: readCString(keyPointer) });
        result = { success: success !== false };
      } else {
        result = { misconfigured: `no rate limit binding ${bindingName}` };
      }
    } catch (error) {
      result = { error: String(error?.message ?? error) };
    }
    pending = new TextEncoder().encode(JSON.stringify(result));
    return pending.length;
  });

  return {
    edgeway_ratelimit: {
      check,
      take(buffer) {
        memory().set(pending, buffer);
        pending = new Uint8Array(0);
      },
    },
  };
}
