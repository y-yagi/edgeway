// X-D1-Bookmark is "BINDING=bookmark, ..."; clients resend it whole.
import { addVary } from "./headers.js";

export const BOOKMARK_HEADER = "X-D1-Bookmark";

const isRead = (request) => request?.method === "GET" || request?.method === "HEAD";

// A bookmark is opaque and D1's: one that does not look like D1's is dropped,
// as D1 itself would keep a high-sorting garbage value as the latest bookmark.
const BINDING_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;
const BOOKMARK = /^[0-9a-f-]{1,128}$/;

export function parseBookmarks(value) {
  const bookmarks = {};
  for (const pair of (value ?? "").split(",")) {
    const separator = pair.indexOf("=");
    const name = pair.slice(0, separator).trim();
    const bookmark = pair.slice(separator + 1).trim();
    if (separator > 0 && BINDING_NAME.test(name) && BOOKMARK.test(bookmark)) bookmarks[name] = bookmark;
  }
  return bookmarks;
}

export class D1Sessions {
  constructor(env, request, names = []) {
    this.env = env;
    this.names = new Set(names);
    this.readRequest = isRead(request);
    this.bookmarks = parseBookmarks(request?.headers.get(BOOKMARK_HEADER));
    this.sessions = new Map();
  }

  uses(name) {
    return this.names.has(name);
  }

  database(name) {
    const binding = this.env[name];
    if (!binding || !this.names.has(name)) return binding;
    if (!this.sessions.has(name)) this.sessions.set(name, this.start(binding, name));
    return this.sessions.get(name);
  }

  start(binding, name) {
    return binding.withSession(this.startPoint(name));
  }

  startPoint(name) {
    if (!this.readRequest) return "first-primary";
    return this.bookmarks[name] ?? "first-unconstrained";
  }

  header() {
    const pairs = [];
    for (const name of this.names) {
      const bookmark = this.sessions.get(name)?.getBookmark() ?? this.bookmarks[name];
      if (bookmark) pairs.push(`${name}=${bookmark}`);
    }
    return pairs.join(", ");
  }

  annotate(response) {
    const value = this.header();
    if (value) response.headers.set(BOOKMARK_HEADER, value);
    if (this.names.size > 0) addVary(response.headers, BOOKMARK_HEADER);
    return response;
  }
}
