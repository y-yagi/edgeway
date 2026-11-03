import { jspiHelpers } from "./jspi.js";

const isRateLimit = (value) => Boolean(value) && typeof value.limit === "function";

export function rateLimitImports(env, getInstance) {
  const { readCString, setResult, take } = jspiHelpers(getInstance);

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
    return setResult(result);
  });

  return {
    edgeway_ratelimit: {
      check,
      take,
    },
  };
}
