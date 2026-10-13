// A minimal WASI preview 1 shim: stdout/stderr, args, environment, clocks,
// random. No filesystem (no preopened directories); stdin serves the bytes
// given as the stdin option (a string or Uint8Array), then EOF.
// stdout/stderr go to onStdout/onStderr as decoded text, or, when
// onStdoutBytes/onStderrBytes is given, to it as raw bytes (binary output).
// Any import not implemented here answers ENOSYS.

const ESUCCESS = 0, EBADF = 8, ENOSYS = 52, ESPIPE = 70;

export class WasiExit extends Error {
  constructor(code) {
    super(`exit ${code}`);
    this.code = code;
  }
}

export class WASI {
  // onStdout / onStderr receive decoded text chunks; onStdoutBytes /
  // onStderrBytes, when given, receive Uint8Array chunks (copies) instead.
  constructor({ args = ["main"], env = {}, stdin = new Uint8Array(0), onStdout = () => {}, onStderr = () => {},
                onStdoutBytes = null, onStderrBytes = null } = {}) {
    this.args = args;
    this.stdin = typeof stdin === "string" ? new TextEncoder().encode(stdin) : stdin;
    this.stdinPos = 0;
    this.env = Object.entries(env).map(([k, v]) => `${k}=${v}`);
    this.out = { 1: onStdout, 2: onStderr };
    this.outBytes = { 1: onStdoutBytes, 2: onStderrBytes };
    this.decoders = { 1: new TextDecoder(), 2: new TextDecoder() };
    this.memory = null;
    this.wasiImport = this.#imports();
  }

  // For a reactor module (no _start): hands the shim the memory and runs
  // _initialize, if the module has one. The caller then calls the exports
  // it wants; a proc_exit inside them throws WasiExit.
  initialize(instance) {
    this.memory = instance.exports.memory;
    instance.exports._initialize?.();
  }

  // Runs the module's _start; answers the exit status.
  start(instance) {
    this.memory = instance.exports.memory;
    try {
      instance.exports._start();
      return 0;
    } catch (e) {
      if (e instanceof WasiExit) return e.code;
      throw e;
    } finally {
      for (const fd of [1, 2]) {
        const rest = this.decoders[fd].decode();
        if (rest) this.out[fd](rest);
      }
    }
  }

  // start for a module whose imports may suspend (JSPI): _start is wrapped
  // with WebAssembly.promising, so a WebAssembly.Suspending import can await.
  async startAsync(instance) {
    this.memory = instance.exports.memory;
    try {
      await WebAssembly.promising(instance.exports._start)();
      return 0;
    } catch (e) {
      if (e instanceof WasiExit) return e.code;
      throw e;
    } finally {
      for (const fd of [1, 2]) {
        const rest = this.decoders[fd].decode();
        if (rest) this.out[fd](rest);
      }
    }
  }

  // The memory can grow, so views are made per call.
  get #view() { return new DataView(this.memory.buffer); }
  get #bytes() { return new Uint8Array(this.memory.buffer); }

  #putStrings(strings, ptrs, buf) {
    const enc = new TextEncoder();
    const view = this.#view, bytes = this.#bytes;
    for (const s of strings) {
      const b = enc.encode(s + "\0");
      view.setUint32(ptrs, buf, true);
      bytes.set(b, buf);
      ptrs += 4;
      buf += b.length;
    }
    return ESUCCESS;
  }

  #sizes(strings, countPtr, sizePtr) {
    const enc = new TextEncoder();
    const view = this.#view;
    view.setUint32(countPtr, strings.length, true);
    view.setUint32(sizePtr, strings.reduce((n, s) => n + enc.encode(s).length + 1, 0), true);
    return ESUCCESS;
  }

  #imports() {
    const impl = {
      args_get: (argv, buf) => this.#putStrings(this.args, argv, buf),
      args_sizes_get: (c, s) => this.#sizes(this.args, c, s),
      environ_get: (envp, buf) => this.#putStrings(this.env, envp, buf),
      environ_sizes_get: (c, s) => this.#sizes(this.env, c, s),

      clock_res_get: (_id, out) => {
        this.#view.setBigUint64(out, 1000n, true);
        return ESUCCESS;
      },
      clock_time_get: (id, _precision, out) => {
        const ns = id === 0
          ? BigInt(Date.now()) * 1_000_000n                      // REALTIME
          : BigInt(Math.round(performance.now() * 1e6));         // MONOTONIC etc.
        this.#view.setBigUint64(out, ns, true);
        return ESUCCESS;
      },

      random_get: (buf, len) => {
        // getRandomValues takes at most 65536 bytes per call.
        for (let off = 0; off < len; off += 65536) {
          crypto.getRandomValues(new Uint8Array(this.memory.buffer, buf + off, Math.min(65536, len - off)));
        }
        return ESUCCESS;
      },

      fd_write: (fd, iovs, iovsLen, nwritten) => {
        if (!(fd in this.out)) return EBADF;
        const view = this.#view;
        let total = 0;
        for (let i = 0; i < iovsLen; i++) {
          const ptr = view.getUint32(iovs + i * 8, true);
          const len = view.getUint32(iovs + i * 8 + 4, true);
          const bytes = new Uint8Array(this.memory.buffer, ptr, len);
          if (this.outBytes[fd]) {
            if (len) this.outBytes[fd](bytes.slice());  // the memory is reused
          } else {
            const text = this.decoders[fd].decode(bytes, { stream: true });
            if (text) this.out[fd](text);
          }
          total += len;
        }
        view.setUint32(nwritten, total, true);
        return ESUCCESS;
      },
      fd_read: (fd, iovs, iovsLen, nread) => {
        if (fd !== 0) return EBADF;
        const view = this.#view, bytes = this.#bytes;
        let total = 0;
        for (let i = 0; i < iovsLen && this.stdinPos < this.stdin.length; i++) {
          const ptr = view.getUint32(iovs + i * 8, true);
          const len = view.getUint32(iovs + i * 8 + 4, true);
          const chunk = this.stdin.subarray(this.stdinPos, this.stdinPos + len);
          bytes.set(chunk, ptr);
          this.stdinPos += chunk.length;
          total += chunk.length;
        }
        view.setUint32(nread, total, true);  // 0 = EOF
        return ESUCCESS;
      },
      fd_fdstat_get: (fd, out) => {
        if (fd > 2) return EBADF;
        const view = this.#view;
        view.setUint8(out, 2);                        // filetype: CHARACTER_DEVICE
        view.setUint16(out + 2, 0, true);             // flags
        view.setBigUint64(out + 8, ~0n & 0xffffffffffffffffn, true);   // rights_base
        view.setBigUint64(out + 16, ~0n & 0xffffffffffffffffn, true);  // rights_inheriting
        return ESUCCESS;
      },
      fd_fdstat_set_flags: (fd) => (fd > 2 ? EBADF : ESUCCESS),
      fd_close: (fd) => (fd > 2 ? EBADF : ESUCCESS),
      fd_seek: (fd) => (fd > 2 ? EBADF : ESPIPE),
      fd_pread: (fd) => (fd > 2 ? EBADF : ESPIPE),
      fd_pwrite: (fd) => (fd > 2 ? EBADF : ESPIPE),
      // EBADF from fd 3 tells wasi-libc there are no preopened directories.
      fd_prestat_get: () => EBADF,
      fd_prestat_dir_name: () => EBADF,
      path_open: () => EBADF,
      path_filestat_get: () => EBADF,

      poll_oneoff: () => ENOSYS,
      sched_yield: () => ESUCCESS,
      proc_raise: () => ENOSYS,
      proc_exit: (code) => { throw new WasiExit(code); },
    };
    return new Proxy(impl, {
      get: (target, name) => target[name] ?? ((..._) => ENOSYS),
    });
  }
}
