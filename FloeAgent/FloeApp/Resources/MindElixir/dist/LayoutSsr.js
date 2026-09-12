const E = {
  LHS: "lhs",
  RHS: "rhs"
}, v = (s) => `<div class="map-container"><div class="map-canvas">${s}</div></div>`, b = function(s, c = {}) {
  const { direction: a = 2 } = c, l = (e) => {
    const r = {
      id: e.id,
      topic: e.topic,
      direction: e.direction,
      style: e.style,
      tags: e.tags,
      icons: e.icons,
      hyperLink: e.hyperLink,
      expanded: e.expanded,
      image: e.image,
      branchColor: e.branchColor,
      dangerouslySetInnerHTML: e.dangerouslySetInnerHTML,
      note: e.note
    };
    return e.children && e.children.length > 0 && (r.children = e.children.map(l)), r;
  }, h = l(s), g = s.children || [], p = [], m = [];
  if (a === 2) {
    let e = 0, r = 0;
    g.forEach((t) => {
      const o = l(t);
      t.direction === 0 ? (o.direction = 0, p.push(o), e += 1) : t.direction === 1 ? (o.direction = 1, m.push(o), r += 1) : e <= r ? (o.direction = 0, p.push(o), e += 1) : (o.direction = 1, m.push(o), r += 1);
    });
  } else a === 0 ? g.forEach((e) => {
    const r = l(e);
    r.direction = 0, p.push(r);
  }) : g.forEach((e) => {
    const r = l(e);
    r.direction = 1, m.push(r);
  });
  return {
    root: h,
    leftNodes: p,
    rightNodes: m,
    direction: a
  };
}, w = function(s, c = {}) {
  const { className: a = "" } = c, l = (t, o = !1) => {
    const I = `me${t.id}`, j = "me-tpc";
    let S = "";
    if (t.style) {
      const n = [];
      t.style.color && n.push(`color: ${t.style.color}`), t.style.background && n.push(`background: ${t.style.background}`), t.style.fontSize && n.push(`font-size: ${t.style.fontSize}px`), t.style.fontWeight && n.push(`font-weight: ${t.style.fontWeight}`), n.length > 0 && (S = ` style="${n.join("; ")}"`);
    }
    let f = "";
    if (t.dangerouslySetInnerHTML)
      f = t.dangerouslySetInnerHTML;
    else {
      if (f = H(t.topic), t.tags && t.tags.length > 0) {
        const n = t.tags.map((i) => {
          if (typeof i == "string")
            return `<span class="me-tag">${H(i)}</span>`;
          {
            let d = "me-tag";
            i.className && (d += ` ${i.className}`);
            let $ = "";
            if (i.style) {
              const y = Object.entries(i.style).filter(([N, u]) => u != null && u !== "").map(([N, u]) => `${N.replace(/([A-Z])/g, "-$1").toLowerCase()}: ${u}`);
              y.length > 0 && ($ = ` style="${y.join("; ")}"`);
            }
            return `<span class="${d}"${$}>${H(i.text)}</span>`;
          }
        }).join("");
        f += n;
      }
      if (t.icons && t.icons.length > 0) {
        const n = t.icons.map((i) => `<span class="me-icon">${i}</span>`).join("");
        f += n;
      }
      if (t.image) {
        const { url: n, width: i, height: d, fit: $ = "cover" } = t.image, y = c.imageProxy ? c.imageProxy(n) : n;
        f += `<img src="${H(y)}" width="${i}" height="${d}" style="object-fit: ${$}" alt="" />`;
      }
    }
    const T = `<me-tpc class="${j}" data-nodeid="${I}"${S}>${f}</me-tpc>`;
    if (o)
      return `<me-root>${T}</me-root>`;
    let L = "";
    return t.children && t.children.length > 0 && t.expanded !== !1 && (L = `<me-children>${t.children.map((i) => h(i)).join("")}</me-children>`), `<me-wrapper>${`<me-parent>${T}</me-parent>`}${L}</me-wrapper>`;
  }, h = (t) => l(t, !1), g = l(s.root, !0), p = s.leftNodes.map((t) => h(t)).join(""), m = s.rightNodes.map((t) => h(t)).join(""), e = `<me-main class="${E.LHS}">${p}</me-main>`, r = `<me-main class="${E.RHS}">${m}</me-main>`;
  return v(`<me-nodes class="${a}">${e}${g}${r}</me-nodes>`);
};
function H(s) {
  const c = typeof document < "u" ? document.createElement("div") : null;
  return c ? (c.textContent = s, c.innerHTML) : s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}
const C = function(s) {
  return JSON.stringify(s, null, 2);
}, R = function(s, c, a = {}) {
  return {
    nodeData: s,
    layoutResult: c,
    options: {
      direction: c.direction,
      ...a
    },
    timestamp: Date.now()
  };
};
export {
  R as getHydrationData,
  C as getSSRData,
  b as layoutSSR,
  w as renderSSRHTML
};
