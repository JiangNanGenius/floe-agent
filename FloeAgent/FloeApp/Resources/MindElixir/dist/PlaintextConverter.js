class S {
  node;
  children = [];
  // slots[i] represents elements that appear *before* children[i]
  // slots[children.length] represents elements that appear *after* all children
  slots;
  constructor(o) {
    this.node = o;
    const d = o.children?.length ?? 0;
    this.slots = Array.from({ length: d + 1 }, () => []);
  }
}
function j(l) {
  const { nodeData: o, arrows: d = [], summaries: n = [] } = l, r = /* @__PURE__ */ new Map();
  function e(t) {
    const s = new S(t);
    return r.set(t.id, s), t.children && (s.children = t.children.map(e)), s;
  }
  const i = e(o), c = [], h = /* @__PURE__ */ new Set();
  for (const t of d) {
    h.add(t.from), h.add(t.to);
    const s = t.metadata, p = s?.parentId, g = s?.index ?? 1 / 0;
    if (!p) {
      c.push(t);
      continue;
    }
    const y = r.get(p);
    if (y) {
      const $ = Math.min(g, y.children.length);
      y.slots[$].push({ type: "arrow", arrow: t });
    } else
      c.push(t);
  }
  for (const t of n) {
    const s = r.get(t.parent);
    if (s) {
      const p = Math.min(t.end + 1, s.children.length);
      s.slots[p].push({ type: "summary", summary: t });
    }
  }
  function a(t) {
    return r.get(t)?.node.metadata?.refId ?? t;
  }
  const u = [];
  function f(t, s) {
    const p = "  ".repeat(s), g = "  ".repeat(s + 1), y = t.node.metadata, $ = [t.node.topic], C = y?.refId ?? (h.has(t.node.id) ? t.node.id : void 0);
    C && $.push(`[^${C}]`), t.node.style && Object.keys(t.node.style).length > 0 && $.push(JSON.stringify(t.node.style)), u.push(`${p}- ${$.join(" ")}`);
    for (let w = 0; w <= t.children.length; w++) {
      for (const N of t.slots[w])
        if (N.type === "arrow") {
          const m = N.arrow, b = m.bidirectional ? `<-${m.label ?? ""}->` : `>-${m.label ?? ""}->`, x = m.delta1 ? ` (${m.delta1.x},${m.delta1.y})` : "", M = m.delta2 ? ` (${m.delta2.x},${m.delta2.y})` : "";
          u.push(`${g}- > [^${a(m.from)}]${x} ${b}${M} [^${a(m.to)}]`);
        } else if (N.type === "summary") {
          const m = N.summary, b = m.end - m.start + 1, x = b === t.children.length ? "" : `:${b} `;
          u.push(`${g}- }${x}${m.label}`);
        }
      w < t.children.length && f(t.children[w], s + 1);
    }
  }
  f(i, 0);
  for (const t of c) {
    const s = t.bidirectional ? `<-${t.label ?? ""}->` : `>-${t.label ?? ""}->`, p = t.delta1 ? ` (${t.delta1.x},${t.delta1.y})` : "", g = t.delta2 ? ` (${t.delta2.x},${t.delta2.y})` : "";
    u.push(`- > [^${a(t.from)}]${p} ${s}${g} [^${a(t.to)}]`);
  }
  return u.join(`
`) + `
`;
}
function I() {
  return ((/* @__PURE__ */ new Date()).getTime().toString(16) + Math.random().toString(16).substring(2)).substring(2, 18);
}
const k = `- Root Node
  - Child Node 1
    - Child Node 1-1 {"color": "#e87a90", "fontSize": "18px"}
    - Child Node 1-2
    - Child Node 1-3
    - }:2 Summary of first two nodes
  - Child Node 2
    - Child Node 2-1 [^node-2-1]
    - Child Node 2-2 [^id2]
    - Child Node 2-3
    - > [^node-2-1] <-Bidirectional Link-> [^id2]
  - Child Node 3
    - Child Node 3-1 [^id3]
    - Child Node 3-2 [^id4]
    - Child Node 3-3 [^id5] {"fontFamily": "Arial", "fontWeight": "bold"}
    - > [^id3] >-Unidirectional Link-> [^id4]
  - Child Node 4
    - Child Node 4-1 [^id6]
    - Child Node 4-2 [^id7]
    - Child Node 4-3 [^id8]
    - } Summary of all previous nodes
    - Child Node 4-4
- > [^node-2-1] <-Link position is not restricted, as long as the id can be found during rendering-> [^id8]

`;
function A(l, o = "Root") {
  const d = l.split(`
`).filter((a) => a.trim());
  if (d.length === 0)
    throw new Error("Failed to parse plaintext: no root node found");
  const n = {
    arrowLines: [],
    nodeIdMap: /* @__PURE__ */ new Map()
  }, r = [], e = [], i = [];
  for (const a of d) {
    const u = v(a), f = T(a);
    for (; e.length > 0 && e[e.length - 1].indent >= u; )
      e.pop();
    const t = e.length > 0 ? e[e.length - 1].node : null, s = t ? t.children ??= [] : i;
    if (f.type === "arrow") {
      n.arrowLines.push({
        content: f.content,
        parentId: t?.id ?? null,
        index: s.length
      });
      continue;
    }
    if (f.type === "summary") {
      const y = O(f.content, s, t?.id ?? "");
      y && r.push(y);
      continue;
    }
    const p = I(), g = {
      topic: f.topic,
      id: p
    };
    f.style && (g.style = f.style), f.refId && (n.nodeIdMap.set(f.refId, p), g.metadata = { refId: f.refId }), s.push(g), e.push({ indent: u, node: g });
  }
  if (i.length === 0)
    throw new Error("Failed to parse plaintext: no root node found");
  let c;
  i.length === 1 ? c = i[0] : c = {
    topic: o,
    id: I(),
    children: i
  };
  const h = n.arrowLines.map(({ content: a, parentId: u, index: f }) => {
    const t = R(a, n);
    return t && (t.metadata = { parentId: u, index: f }), t;
  }).filter((a) => a !== null);
  return {
    nodeData: c,
    arrows: h.length > 0 ? h : void 0,
    summaries: r.length > 0 ? r : void 0
  };
}
function v(l) {
  const o = l.match(/^(\s*)/);
  return o ? o[1].length : 0;
}
function L(l) {
  try {
    const o = l.trim().startsWith("{") ? l : `{${l}}`;
    return JSON.parse(o);
  } catch {
    return null;
  }
}
function T(l) {
  const d = l.trim().replace(/^-\s*/, "");
  if (d.startsWith(">"))
    return {
      type: "arrow",
      topic: "",
      content: d.substring(1).trim()
    };
  if (d.startsWith("}"))
    return {
      type: "summary",
      topic: "",
      content: d.substring(1).trim()
    };
  let n = d, r, e;
  const i = n.match(/\s*(\{[^}]+\})\s*$/);
  if (i) {
    const h = L(i[1]);
    h && (e = h, n = n.substring(0, n.length - i[0].length).trim());
  }
  const c = n.match(/\s*\[\^([\w-]+)\]\s*$/);
  return c && (r = c[1], n = n.substring(0, n.length - c[0].length).trim()), {
    type: "node",
    topic: n,
    content: n,
    refId: r,
    style: e
  };
}
function R(l, o) {
  const d = l.match(
    /\[\^([\w-]+)\](?:\s*\(([\d.-]+),([\d.-]+)\))?\s*<-([^-]*)->(?:\s*\(([\d.-]+),([\d.-]+)\))?\s*\[\^([\w-]+)\]/
  );
  if (d) {
    const r = d[1], e = d[2], i = d[3], c = d[4].trim(), h = d[5], a = d[6], u = d[7];
    return {
      id: I(),
      label: c,
      from: o.nodeIdMap.get(r) || r,
      to: o.nodeIdMap.get(u) || u,
      delta1: e && i ? { x: Number(e), y: Number(i) } : void 0,
      delta2: h && a ? { x: Number(h), y: Number(a) } : void 0,
      bidirectional: !0
    };
  }
  const n = l.match(/\[\^([\w-]+)\](?:\s*\(([\d.-]+),([\d.-]+)\))?\s*>-([^-]*)->(?:\s*\(([\d.-]+),([\d.-]+)\))?\s*\[\^([\w-]+)\]/);
  if (n) {
    const r = n[1], e = n[2], i = n[3], c = n[4].trim(), h = n[5], a = n[6], u = n[7];
    return {
      id: I(),
      label: c,
      from: o.nodeIdMap.get(r) || r,
      to: o.nodeIdMap.get(u) || u,
      delta1: e && i ? { x: Number(e), y: Number(i) } : void 0,
      delta2: h && a ? { x: Number(h), y: Number(a) } : void 0
    };
  }
  return null;
}
function O(l, o, d) {
  const n = l.match(/^:(\d+)\s+(.*)/);
  let r, e;
  if (n ? (r = parseInt(n[1], 10), e = n[2]) : (r = o.length, e = l.trim()), o.length === 0 || r === 0)
    return null;
  const i = o.slice(-r), c = o.indexOf(i[0]), h = o.indexOf(i[i.length - 1]);
  return {
    id: I(),
    label: e,
    parent: d,
    start: c,
    end: h
  };
}
export {
  j as mindElixirToPlaintext,
  k as plaintextExample,
  A as plaintextToMindElixir
};
