const listOf = (value) => (value ?? "").split(",").map((item) => item.trim()).filter(Boolean);

export function withHeaders(list, ...names) {
  const have = listOf(list);
  for (const name of names) {
    if (!have.some((existing) => existing.toLowerCase() === name.toLowerCase())) have.push(name);
  }
  return have.join(", ");
}

// A Vary of * already covers every header.
export function addVary(headers, ...names) {
  const have = listOf(headers.get("Vary"));
  if (have.includes("*")) return;
  headers.set("Vary", withHeaders(have.join(", "), ...names));
}
