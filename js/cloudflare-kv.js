import { jspiHelpers } from "./jspi.js";

export const MIN_EXPIRATION_TTL = 60;

export function putOptions(expiresIn) {
  if (!(expiresIn > 0)) return undefined;
  return { expirationTtl: Math.max(expiresIn, MIN_EXPIRATION_TTL) };
}

// An R2 bucket also has get, put and delete; only a KV namespace has getWithMetadata.
export const isKvNamespace = (value) => Boolean(value) && ["get", "put", "delete", "getWithMetadata"].every((name) => typeof value[name] === "function");

export function kvImports(env, getInstance) {
  const { readCString, setResult, take } = jspiHelpers(getInstance);

  const namespaceOf = (bindingName) => {
    const namespace = env[bindingName];
    if (!isKvNamespace(namespace)) throw new Error(`no KV binding ${bindingName}`);
    return namespace;
  };

  const suspending = (operation) => new WebAssembly.Suspending(async (bindingPointer, keyPointer, ...rest) => {
    let result;
    try {
      const namespace = namespaceOf(readCString(bindingPointer));
      result = await operation(namespace, readCString(keyPointer), ...rest);
    } catch (error) {
      result = { error: String(error?.message ?? error) };
    }
    return setResult(result);
  });

  return {
    edgeway_kv: {
      get: suspending(async (namespace, key) => ({ value: await namespace.get(key, "text") })),
      put: suspending(async (namespace, key, textPointer, expiresIn) => {
        await namespace.put(key, readCString(textPointer), putOptions(expiresIn));
        return { ok: true };
      }),
      delete: suspending(async (namespace, key) => {
        await namespace.delete(key);
        return { ok: true };
      }),
      take,
    },
  };
}
