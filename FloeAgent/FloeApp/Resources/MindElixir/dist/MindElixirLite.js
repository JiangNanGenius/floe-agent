const Vn = 0, zn = 1, Fn = 2, Gn = 3, ot = {
  name: "Latte",
  type: "light",
  palette: ["#dd7878", "#ea76cb", "#8839ef", "#e64553", "#fe640b", "#df8e1d", "#40a02b", "#209fb5", "#1e66f5", "#7287fd"],
  cssVar: {
    "--node-gap-x": "30px",
    "--node-gap-y": "10px",
    "--main-gap-x": "65px",
    "--main-gap-y": "45px",
    "--root-radius": "30px",
    "--main-radius": "20px",
    "--root-color": "#ffffff",
    "--root-bgcolor": "#4c4f69",
    "--root-border-color": "rgba(0, 0, 0, 0)",
    "--main-border": "",
    // you can customize, it will fallback to 2px solid main-color
    "--main-color": "#444446",
    "--main-bgcolor": "#ffffff",
    "--main-bgcolor-transparent": "rgba(255, 255, 255, 0.8)",
    "--topic-padding": "3px",
    "--color": "#777777",
    "--bgcolor": "#f6f6f6",
    "--selected": "#4dc4ff",
    "--accent-color": "#e64553",
    "--panel-color": "#444446",
    "--panel-bgcolor": "#ffffff",
    "--panel-border-color": "#eaeaea",
    "--map-padding": "50px 80px"
  }
}, st = {
  name: "Dark",
  type: "dark",
  palette: ["#848FA0", "#748BE9", "#D2F9FE", "#4145A5", "#789AFA", "#706CF4", "#EF987F", "#775DD5", "#FCEECF", "#DA7FBC"],
  cssVar: {
    "--node-gap-x": "30px",
    "--node-gap-y": "10px",
    "--main-gap-x": "65px",
    "--main-gap-y": "45px",
    "--root-radius": "30px",
    "--main-radius": "20px",
    "--root-color": "#ffffff",
    "--root-bgcolor": "#2d3748",
    "--root-border-color": "rgba(255, 255, 255, 0.1)",
    "--main-border": "",
    "--main-color": "#ffffff",
    "--main-bgcolor": "#4c4f69",
    "--main-bgcolor-transparent": "rgba(76, 79, 105, 0.8)",
    "--topic-padding": "3px",
    "--color": "#cccccc",
    "--bgcolor": "#252526",
    "--selected": "#4dc4ff",
    "--accent-color": "#789AFA",
    "--panel-color": "#ffffff",
    "--panel-bgcolor": "#2d3748",
    "--panel-border-color": "#696969",
    "--map-padding": "50px 80px"
  }
};
function Bt(t) {
  return t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");
}
const U = function(t, e) {
  if (e.id === t)
    return e;
  if (e.children && e.children.length) {
    for (let n = 0; n < e.children.length; n++) {
      const o = U(t, e.children[n]);
      if (o) return o;
    }
    return null;
  } else
    return null;
}, ct = (t, e) => {
  if (t.parent = e, t.children)
    for (let n = 0; n < t.children.length; n++)
      ct(t.children[n], t);
}, bt = (t, e, n) => {
  t.expanded = e, t.children && t.children.forEach((o) => {
    bt(o, e);
  });
};
function K(t, e, n, o) {
  const i = n - t, s = o - e, c = Math.atan2(s, i) * 180 / Math.PI, l = 12, d = 30, f = (c + 180 - d) * Math.PI / 180, a = (c + 180 + d) * Math.PI / 180;
  return {
    x1: n + Math.cos(f) * l,
    y1: o + Math.sin(f) * l,
    x2: n + Math.cos(a) * l,
    y2: o + Math.sin(a) * l
  };
}
function X() {
  return ((/* @__PURE__ */ new Date()).getTime().toString(16) + Math.random().toString(16).substring(2)).substring(2, 18);
}
const Yt = function() {
  const t = X();
  return {
    topic: this.newTopicName,
    id: t
  };
};
function it(t) {
  return JSON.parse(
    JSON.stringify(t, (n, o) => {
      if (n !== "parent")
        return o;
    })
  );
}
const H = (t, e) => {
  let n = 0, o = 0;
  for (; e && e !== t; )
    n += e.offsetLeft, o += e.offsetTop, e = e.offsetParent;
  return { offsetLeft: n, offsetTop: o };
}, L = (t, e) => {
  for (const n in e)
    t.setAttribute(n, e[n]);
}, tt = (t) => t ? t.tagName === "ME-TPC" : !1, lt = (t) => {
  const e = /translate3d\(([^,]+),\s*([^,]+)/, n = t.match(e);
  return n ? { x: parseFloat(n[1]), y: parseFloat(n[2]) } : { x: 0, y: 0 };
}, vt = function(t) {
  for (let e = 0; e < t.length; e++) {
    const { dom: n, evt: o, func: i } = t[e];
    n.addEventListener(o, i);
  }
  return function() {
    for (let n = 0; n < t.length; n++) {
      const { dom: o, evt: i, func: s } = t[n];
      o.removeEventListener(i, s);
    }
  };
}, ft = (t, e) => {
  const n = t.x - e.x, o = t.y - e.y;
  return Math.sqrt(n * n + o * o);
}, ut = function(t, e) {
  if (!e)
    return J(t), t;
  let n = t.querySelector(".insert-preview");
  const o = `insert-preview ${e} show`;
  return n || (n = document.createElement("div"), t.appendChild(n)), n.className = o, t;
}, J = function(t) {
  if (!t) return;
  const e = t.querySelectorAll(".insert-preview");
  for (const n of e || [])
    n.remove();
}, G = function(t, e) {
  for (const n of e) {
    const o = n.parentElement.parentElement.contains(t);
    if (!(t && t.tagName === "ME-TPC" && t !== n && !o && t.nodeObj.parent)) return !1;
  }
  return !0;
}, Rt = function(t) {
  const e = document.createElement("div");
  return e.className = "mind-elixir-ghost", t.container.appendChild(e), e;
};
class Xt {
  mind;
  isMoving = !1;
  interval = null;
  speed = 20;
  constructor(e) {
    this.mind = e;
  }
  move(e, n) {
    this.isMoving || (this.isMoving = !0, this.interval = setInterval(() => {
      this.mind.move(e * this.speed * this.mind.scaleVal, n * this.speed * this.mind.scaleVal);
    }, 100));
  }
  stop() {
    this.isMoving = !1, this.interval && (clearInterval(this.interval), this.interval = null);
  }
}
function Vt(t) {
  return {
    isDragging: !1,
    insertType: null,
    meet: null,
    ghost: Rt(t),
    edgeMoveController: new Xt(t),
    startX: 0,
    startY: 0,
    pointerId: null
  };
}
const zt = 5;
function pt(t, e, n, o = !1) {
  if (t.spacePressed) return !1;
  const i = n.target;
  if (i?.tagName !== "ME-TPC" || !i.nodeObj.parent) return !1;
  if (e.startX = n.clientX, e.startY = n.clientY, e.pointerId = n.pointerId, t.dragged = t.currentNodes, o) {
    xt(t, e);
    const s = t.container.getBoundingClientRect();
    wt(e.ghost, n.clientX - s.x, n.clientY - s.y);
  }
  return !0;
}
function wt(t, e, n) {
  t.style.transform = `translate(${e - 10}px, ${n - 10}px)`, t.style.display = "block";
}
function xt(t, e) {
  const { dragged: n } = t;
  if (!n) return;
  const o = document.activeElement;
  o && o.isContentEditable && o.blur(), e.isDragging = !0, n.length > 1 ? e.ghost.innerHTML = n.length + "" : e.ghost.innerHTML = n[0].innerHTML;
  for (const i of n)
    i.parentElement.parentElement.style.opacity = "0.5";
  t.panHelper.clear();
}
function Ft(t, e, n) {
  const { dragged: o } = t;
  if (!o || e.pointerId !== n.pointerId) return;
  const i = n.clientX - e.startX, s = n.clientY - e.startY, r = Math.sqrt(i * i + s * s);
  if (!e.isDragging && r > zt && xt(t, e), !e.isDragging) return;
  const c = t.container.getBoundingClientRect();
  wt(e.ghost, n.clientX - c.x, n.clientY - c.y), n.clientX < c.x + 50 ? e.edgeMoveController.move(1, 0) : n.clientX > c.x + c.width - 50 ? e.edgeMoveController.move(-1, 0) : n.clientY < c.y + 50 ? e.edgeMoveController.move(0, 1) : n.clientY > c.y + c.height - 50 ? e.edgeMoveController.move(0, -1) : e.edgeMoveController.stop(), J(e.meet);
  const l = 12 * t.scaleVal;
  if (t.direction === 3) {
    const f = document.elementFromPoint(n.clientX - l, n.clientY);
    if (G(f, o)) {
      e.meet = f;
      const a = f.getBoundingClientRect();
      n.clientX > a.x + a.width ? e.insertType = "after" : e.insertType = "in";
    } else {
      const a = document.elementFromPoint(n.clientX + l, n.clientY);
      if (G(a, o)) {
        e.meet = a;
        const u = a.getBoundingClientRect();
        n.clientX < u.x ? e.insertType = "before" : e.insertType = "in";
      } else
        e.insertType = null, e.meet = null;
    }
    e.meet && ut(e.meet, e.insertType);
    return;
  }
  const d = document.elementFromPoint(n.clientX, n.clientY - l);
  if (G(d, o)) {
    e.meet = d;
    const f = d.getBoundingClientRect(), a = f.y;
    n.clientY > a + f.height ? e.insertType = "after" : e.insertType = "in";
  } else {
    const f = document.elementFromPoint(n.clientX, n.clientY + l);
    if (G(f, o)) {
      e.meet = f;
      const u = f.getBoundingClientRect().y;
      n.clientY < u ? e.insertType = "before" : e.insertType = "in";
    } else
      e.insertType = null, e.meet = null;
  }
  e.meet && ut(e.meet, e.insertType);
}
function Gt(t, e, n) {
  const { dragged: o } = t;
  if (!(!o || e.pointerId !== n.pointerId)) {
    e.edgeMoveController.stop();
    for (const i of o)
      i.parentElement.parentElement.style.opacity = "1";
    e.ghost.style.display = "none", e.ghost.innerHTML = "", e.isDragging && e.meet && (J(e.meet), e.insertType === "before" ? t.moveNodeBefore(o, e.meet) : e.insertType === "after" ? t.moveNodeAfter(o, e.meet) : e.insertType === "in" && t.moveNodeIn(o, e.meet)), t.dragged = null, e.isDragging = !1, e.insertType = null, e.meet = null, e.pointerId = null;
  }
}
function gt(t, e) {
  const { dragged: n } = t;
  if (n) {
    e.edgeMoveController.stop();
    for (const o of n)
      o.parentElement.parentElement.style.opacity = "1";
    e.meet && J(e.meet), e.ghost.style.display = "none", e.ghost.innerHTML = "", t.dragged = null, e.isDragging = !1, e.insertType = null, e.meet = null, e.pointerId = null;
  }
}
const O = {
  LHS: "lhs",
  RHS: "rhs",
  DOWN: "down"
}, jt = function() {
  this.nodes.innerHTML = "", this.nodes.className = this.direction === 3 ? "down" : "";
  const t = this.createTopic(this.nodeData);
  Et.call(this, t, this.nodeData), t.draggable = !1;
  const e = document.createElement("me-root");
  e.appendChild(t);
  const n = this.nodeData.children || [];
  if (this.direction === 2) {
    let o = 0, i = 0;
    n.map((s) => {
      s.direction === 0 ? o += 1 : s.direction === 1 ? i += 1 : o <= i ? (s.direction = 0, o += 1) : (s.direction = 1, i += 1);
    });
  }
  _t(this, n, e);
}, _t = function(t, e, n) {
  if (t.direction === 3) {
    const s = document.createElement("me-main");
    s.className = O.DOWN;
    for (let r = 0; r < e.length; r++) {
      const { grp: c } = t.createWrapper(e[r]);
      s.appendChild(c);
    }
    t.nodes.appendChild(n), t.nodes.appendChild(s), t.nodes.appendChild(t.lines), t.nodes.appendChild(t.labelContainer);
    return;
  }
  const o = document.createElement("me-main");
  o.className = O.LHS;
  const i = document.createElement("me-main");
  i.className = O.RHS;
  for (let s = 0; s < e.length; s++) {
    const r = e[s], { grp: c } = t.createWrapper(r);
    t.direction === 2 ? r.direction === 0 ? o.appendChild(c) : i.appendChild(c) : t.direction === 0 ? o.appendChild(c) : i.appendChild(c);
  }
  t.nodes.appendChild(o), t.nodes.appendChild(n), t.nodes.appendChild(i), t.nodes.appendChild(t.lines), t.nodes.appendChild(t.labelContainer);
}, qt = function(t, e) {
  const n = document.createElement("me-children");
  for (let o = 0; o < e.length; o++) {
    const i = e[o], { grp: s } = t.createWrapper(i);
    n.appendChild(s);
  }
  return n;
}, Ct = function(t, e) {
  const o = (this?.el ? this.el : e || document).querySelector(`[data-nodeid="me${t}"]`);
  if (!o) throw new Error(`FindEle: Node ${t} not found, maybe it's collapsed.`);
  return o;
}, Et = function(t, e) {
  if (t.innerHTML = "", e.style) {
    const n = e.style;
    for (const o in n)
      t.style[o] = n[o];
  }
  if (e.dangerouslySetInnerHTML) {
    t.innerHTML = e.dangerouslySetInnerHTML;
    return;
  }
  if (e.image) {
    const n = e.image;
    if (n.url && n.width && n.height) {
      const o = document.createElement("img");
      o.src = this.imageProxy ? this.imageProxy(n.url) : n.url, o.style.width = n.width + "px", o.style.height = n.height + "px", n.fit && (o.style.objectFit = n.fit), t.appendChild(o), t.image = o;
    }
  } else t.image && (t.image = void 0);
  {
    const n = document.createElement("span");
    n.className = "text", this.markdown ? n.innerHTML = this.markdown(e.topic, e) : n.textContent = e.topic, t.appendChild(n), t.text = n;
  }
  if (e.hyperLink) {
    const n = document.createElement("a");
    n.className = "hyper-link", n.target = "_blank", n.innerText = "🔗", n.href = e.hyperLink, t.appendChild(n), t.link = n;
  } else t.link && (t.link = void 0);
  if (e.icons && e.icons.length) {
    const n = document.createElement("span");
    n.className = "icons", n.innerHTML = e.icons.map((o) => `<span>${Bt(o)}</span>`).join(""), t.appendChild(n), t.icons = n;
  } else t.icons && (t.icons = void 0);
  if (e.tags && e.tags.length) {
    const n = document.createElement("div");
    n.className = "tags", e.tags.forEach((o) => {
      const i = document.createElement("span");
      typeof o == "string" ? i.textContent = o : (i.textContent = o.text, o.className && (i.className = o.className), o.style && Object.assign(i.style, o.style)), n.appendChild(i);
    }), t.appendChild(n), t.tags = n;
  } else t.tags && (t.tags = void 0);
}, Ut = function(t, e) {
  const n = document.createElement("me-wrapper"), { p: o, tpc: i } = this.createParent(t);
  if (n.appendChild(o), !e && t.children && t.children.length > 0) {
    const s = te(t.expanded);
    if (o.appendChild(s), t.expanded !== !1) {
      const r = qt(this, t.children);
      n.appendChild(r);
    }
  }
  return { grp: n, top: o, tpc: i };
}, Kt = function(t) {
  const e = document.createElement("me-parent"), n = this.createTopic(t);
  return Et.call(this, n, t), e.appendChild(n), { p: e, tpc: n };
}, Jt = function(t) {
  const e = document.createElement("me-children");
  return e.append(...t), e;
}, Zt = function(t) {
  const e = document.createElement("me-tpc");
  return e.nodeObj = t, e.dataset.nodeid = "me" + t.id, e;
};
function St(t) {
  const e = document.createRange();
  e.selectNodeContents(t);
  const n = window.getSelection();
  n && (n.removeAllRanges(), n.addRange(e));
}
const Qt = function(t) {
  if (!t) return;
  const e = document.createElement("div"), n = t.nodeObj, o = n.topic, { offsetLeft: i, offsetTop: s } = H(this.nodes, t);
  this.nodes.appendChild(e), e.id = "input-box", e.textContent = o, e.contentEditable = "plaintext-only", e.spellcheck = !1;
  const r = getComputedStyle(t);
  e.style.cssText = `
  left: ${i}px;
  top: ${s}px;
  min-width:${t.offsetWidth - 8}px;
  color:${r.color};
  font-size:${r.fontSize};
  padding:${r.padding};
  margin:${r.margin}; 
  background-color:${r.backgroundColor !== "rgba(0, 0, 0, 0)" && r.backgroundColor};
  border: ${r.border};
  border-radius:${r.borderRadius}; `, this.direction === 0 && (e.style.right = "0"), t.style.opacity = "0", St(e), this.bus.fire("operation", {
    name: "beginEdit",
    obj: t.nodeObj
  }), e.addEventListener("keydown", (c) => {
    if (c.stopPropagation(), c.isComposing) return;
    const l = c.key;
    if (l === "Enter" || l === "Tab") {
      if (c.shiftKey) return;
      c.preventDefault(), e.blur(), this.container.focus();
    } else l === "Escape" && (c.preventDefault(), e.textContent = o, e.blur(), this.container.focus());
  }), e.addEventListener("blur", () => {
    if (!e) return;
    t.style.opacity = "1";
    const c = e.innerText?.trim() || "";
    e.remove(), !(c === o || c === "") && (n.topic = c, this.markdown ? t.text.innerHTML = this.markdown(n.topic, n) : t.text.textContent = c, this.linkDiv(), this.bus.fire("operation", {
      name: "finishEdit",
      obj: n,
      origin: o
    }));
  });
}, te = function(t) {
  const e = document.createElement("me-epd");
  return e.expanded = t !== !1, e.className = t !== !1 ? "minus" : "", e;
}, ee = function(t) {
  const n = t.parentElement.parentElement.lastElementChild;
  n?.tagName === "svg" && n?.remove();
};
function ne(t) {
  return {
    nodeData: t.isFocusMode ? t.nodeDataBackup : t.nodeData,
    arrows: t.arrows,
    summaries: t.summaries,
    direction: t.direction,
    theme: t.theme,
    compact: t.compact,
    meta: t.meta
  };
}
const oe = function(t, e = !1) {
  const n = this.container, o = t.getBoundingClientRect(), i = n.getBoundingClientRect();
  if (e || o.top > i.bottom - 50 || o.bottom < i.top + 50 || o.left > i.right - 50 || o.right < i.left + 50) {
    const r = o.left + o.width / 2, c = o.top + o.height / 2, l = i.left + i.width / 2, d = i.top + i.height / 2, f = r - l, a = c - d;
    this.move(-f, -a, !0);
  }
}, se = function(t, e, n) {
  this.clearSelection(), this.scrollIntoView(t), this.selection?.select(t), e && this.bus.fire("selectNewNode", t.nodeObj);
}, ie = function(t) {
  this.selection?.select(t);
}, re = function(t) {
  this.selection?.deselect(t);
}, ce = function() {
  this.unselectNodes(this.currentNodes), this.unselectSummary(), this.unselectArrow();
}, Tt = function(t) {
  return JSON.stringify(t, (e, n) => {
    if (!(e === "parent" && typeof n != "string"))
      return n;
  });
}, le = function() {
  const t = ne(this);
  return Tt(t);
}, ae = function() {
  return JSON.parse(this.getDataString());
}, he = function() {
  this.editable = !0;
}, de = function() {
  this.editable = !1;
}, fe = function(t, e = { x: 0, y: 0 }) {
  if (t < this.scaleMin && t < this.scaleVal || t > this.scaleMax && t > this.scaleVal) return;
  const n = this.container.getBoundingClientRect(), o = e.x ? e.x - n.left - n.width / 2 : 0, i = e.y ? e.y - n.top - n.height / 2 : 0, { dx: s, dy: r } = at(this), c = this.map.style.transform, { x: l, y: d } = lt(c), f = l - s, a = d - r, u = this.scaleVal, g = (-o + f) * (1 - t / u), p = (-i + a) * (1 - t / u);
  this.map.style.transform = `translate3d(${l - g}px, ${d - p}px, 0) scale(${t})`, this.scaleVal = t, this.bus.fire("scale", t);
}, ue = function() {
  const t = this.nodes.offsetHeight / this.container.offsetHeight, e = this.nodes.offsetWidth / this.container.offsetWidth, n = 1 / Math.max(1, Math.max(t, e));
  this.scaleVal = n;
  const { dx: o, dy: i } = at(this, !0);
  this.map.style.transform = `translate3d(${o}px, ${i}px, 0) scale(${n})`, this.bus.fire("scale", n);
}, pe = function(t, e, n = !1) {
  const { map: o, scaleVal: i, bus: s, container: r, nodes: c } = this;
  if (n && o.style.transition === "transform 0.3s")
    return !1;
  const l = o.style.transform;
  let { x: d, y: f } = lt(l);
  const a = r.getBoundingClientRect(), u = c.getBoundingClientRect(), g = (a.left + a.right) / 2, p = (a.top + a.bottom) / 2;
  return t > 0 ? t = Math.min(t, Math.max(0, g - u.left)) : t < 0 && (t = Math.max(t, Math.min(0, g - u.right))), e > 0 ? e = Math.min(e, Math.max(0, p - u.top)) : e < 0 && (e = Math.max(e, Math.min(0, p - u.bottom))), t === 0 && e === 0 ? !1 : (d += t, f += e, n && (o.style.transition = "transform 0.3s", setTimeout(() => {
    o.style.transition = "none";
  }, 300)), o.style.transform = `translate3d(${d}px, ${f}px, 0) scale(${i})`, s.fire("move", { dx: t, dy: e }), !0);
}, at = (t, e = !1) => {
  const { container: n, map: o, nodes: i } = t;
  let s, r;
  if (t.alignment === "nodes" || e || t.direction === 3)
    s = (n.offsetWidth - i.offsetWidth) / 2, r = (n.offsetHeight - i.offsetHeight) / 2, o.style.transformOrigin = "50% 50%";
  else {
    const c = o.querySelector("me-root"), l = c.offsetTop, d = c.offsetLeft, f = c.offsetWidth, a = c.offsetHeight;
    s = n.offsetWidth / 2 - d - f / 2, r = n.offsetHeight / 2 - l - a / 2, o.style.transformOrigin = `${d + f / 2}px 50%`;
  }
  return { dx: s, dy: r };
}, ge = function() {
  const { map: t, container: e } = this, { dx: n, dy: o } = at(this);
  e.scrollTop = 0, e.scrollLeft = 0, t.style.transform = `translate3d(${n}px, ${o}px, 0) scale(${this.scaleVal})`;
}, me = function(t) {
  t(this);
}, ye = function(t) {
  t.nodeObj.parent && (this.clearSelection(), this.tempDirection === null && (this.tempDirection = this.direction), this.isFocusMode || (this.nodeDataBackup = this.nodeData, this.isFocusMode = !0), this.nodeData = t.nodeObj, this.initRight(), this.toCenter());
}, be = function() {
  this.isFocusMode = !1, this.tempDirection !== null && (this.nodeData = this.nodeDataBackup, this.direction = this.tempDirection, this.tempDirection = null, this.refresh(), this.toCenter());
}, ve = function() {
  this.direction = 0, this.refresh(), this.toCenter(), this.bus.fire("changeDirection", this.direction);
}, we = function() {
  this.direction = 1, this.refresh(), this.toCenter(), this.bus.fire("changeDirection", this.direction);
}, xe = function() {
  this.direction = 2, this.refresh(), this.toCenter(), this.bus.fire("changeDirection", this.direction);
}, Ce = function() {
  this.direction = 3, this.refresh(), this.toCenter(), this.bus.fire("changeDirection", this.direction);
}, Ee = function(t, e) {
  const n = t.nodeObj;
  typeof e == "boolean" ? n.expanded = e : n.expanded !== !1 ? n.expanded = !1 : n.expanded = !0;
  const o = t.getBoundingClientRect(), i = {
    x: o.left,
    y: o.top
  }, s = t.parentNode, r = s.children[1];
  if (r.expanded = n.expanded, r.className = n.expanded ? "minus" : "", ee(t), n.expanded) {
    const a = this.createChildren(
      n.children.map((u) => this.createWrapper(u).grp)
    );
    s.parentNode.appendChild(a);
  } else
    s.parentNode.children[1].remove();
  this.linkDiv(t.closest("me-main > me-wrapper"));
  const c = t.getBoundingClientRect(), l = {
    x: c.left,
    y: c.top
  }, d = i.x - l.x, f = i.y - l.y;
  this.move(d, f), this.bus.fire("expandNode", n);
}, Se = function(t, e) {
  const n = t.nodeObj, o = t.getBoundingClientRect(), i = {
    x: o.left,
    y: o.top
  };
  bt(n, e ?? !n.expanded), this.refresh();
  const s = this.findEle(n.id).getBoundingClientRect(), r = {
    x: s.left,
    y: s.top
  }, c = i.x - r.x, l = i.y - r.y;
  this.move(c, l);
}, Te = function(t) {
  this.clearSelection(), t && (t = JSON.parse(JSON.stringify(t)), this.nodeData = t.nodeData, this.arrows = t.arrows || [], this.summaries = t.summaries || [], t.meta && (this.meta = t.meta)), ct(this.nodeData), this.layout(), this.linkDiv();
}, De = /* @__PURE__ */ Object.freeze(/* @__PURE__ */ Object.defineProperty({
  __proto__: null,
  cancelFocus: be,
  clearSelection: ce,
  disableEdit: de,
  enableEdit: he,
  expandNode: Ee,
  expandNodeAll: Se,
  focusNode: ye,
  getData: ae,
  getDataString: le,
  initDown: Ce,
  initLeft: ve,
  initRight: we,
  initSide: xe,
  install: me,
  move: pe,
  refresh: Te,
  scale: fe,
  scaleFit: ue,
  scrollIntoView: oe,
  selectNode: se,
  selectNodes: ie,
  stringifyData: Tt,
  toCenter: ge,
  unselectNodes: re
}, Symbol.toStringTag, { value: "Module" })), Me = 40, Le = 10, Pe = ({ deltaMode: t, deltaY: e, viewportHeight: n }) => t === WheelEvent.DOM_DELTA_LINE ? e * Me : t === WheelEvent.DOM_DELTA_PAGE ? e * n : e, $e = ({ deltaMode: t, deltaY: e, scaleSensitivity: n, viewportHeight: o }) => {
  const s = -Pe({ deltaMode: t, deltaY: e, viewportHeight: o }) / Le * n;
  return Math.max(-n, Math.min(n, s));
}, Ne = (t, e, n) => {
  e !== 0 && t.scale(t.scaleVal + e, n);
}, ke = (t, e) => {
  const n = $e({
    deltaMode: e.deltaMode,
    deltaY: e.deltaY,
    scaleSensitivity: t.scaleSensitivity,
    viewportHeight: t.container.clientHeight || window.innerHeight
  });
  Ne(t, n, { x: e.clientX, y: e.clientY });
};
function Ae(t) {
  const { panHelper: e, container: n } = t;
  let o = null;
  t.spacePressed = !1;
  const i = {
    lastTap: 0,
    lastTapTarget: null,
    DOUBLE_CLICK_THRESHOLD: 300,
    detect(h, m) {
      if (h.button !== 0) {
        this.clear();
        return;
      }
      const x = (/* @__PURE__ */ new Date()).getTime(), E = x - this.lastTap, D = E < this.DOUBLE_CLICK_THRESHOLD && E > 0 && this.lastTapTarget === h.target;
      this.lastTap = x, this.lastTapTarget = h.target, D && m(h);
    },
    clear() {
      this.lastTap = 0, this.lastTapTarget = null;
    }
  }, s = {
    Idle: 0,
    Pinch: 1,
    DragWait: 2,
    Drag: 3,
    Pan: 4,
    BoxSelect: 5
  };
  t.ptState = s.Idle;
  const r = {
    lastDistance: null,
    activePointers: /* @__PURE__ */ new Map(),
    handlePointerDown(h) {
      if (h.pointerType !== "touch") return !1;
      if (this.activePointers.set(h.pointerId, { x: h.clientX, y: h.clientY }), this.activePointers.size >= 2) {
        const [m, x] = Array.from(this.activePointers.values());
        return this.lastDistance = ft(m, x), !0;
      }
      return !1;
    },
    handlePointerMove(h) {
      if (h.pointerType !== "touch" || !this.activePointers.has(h.pointerId)) return !1;
      if (this.activePointers.set(h.pointerId, { x: h.clientX, y: h.clientY }), this.activePointers.size >= 2) {
        const [m, x] = Array.from(this.activePointers.values()), E = ft(m, x);
        if (this.lastDistance !== null && this.lastDistance > 0) {
          const D = E / this.lastDistance;
          t.scale(t.scaleVal * D, {
            x: (m.x + x.x) / 2,
            y: (m.y + x.y) / 2
          });
        }
        return this.lastDistance = E, !0;
      }
      return !1;
    },
    handlePointerUp(h) {
      h.pointerType === "touch" && (this.activePointers.delete(h.pointerId), this.activePointers.size < 2 && (this.lastDistance = null));
    },
    clear() {
      this.activePointers.clear(), this.lastDistance = null;
    }
  }, c = Vt(t), l = {
    timer: null,
    startPos: null,
    pointerId: null,
    DURATION: 500,
    MOVE_THRESHOLD: 10,
    clear() {
      this.timer !== null && (clearTimeout(this.timer), this.timer = null, this.startPos = null, this.pointerId = null);
    },
    start(h, m) {
      this.timer = window.setTimeout(() => {
        m(h), this.timer = null, this.startPos = null, this.pointerId = null;
      }, this.DURATION), this.startPos = { x: h.clientX, y: h.clientY }, this.pointerId = h.pointerId;
    },
    handleMove(h) {
      if (this.timer !== null && this.startPos !== null && h.pointerId === this.pointerId) {
        const m = h.clientX - this.startPos.x, x = h.clientY - this.startPos.y;
        Math.sqrt(m * m + x * x) > this.MOVE_THRESHOLD && this.clear();
      }
    }
  }, d = (h, m) => {
    if (h.closest("#input-box")) return !1;
    const x = h.closest(".svg-label"), E = h.closest(".topiclinks, .summary"), D = x ? { type: x.dataset.type, element: document.getElementById(x.dataset.svgId) } : E ? { type: E.classList.contains("topiclinks") ? "arrow" : "summary", element: h.closest("g") } : null;
    if (!D?.type || !D?.element) return !1;
    const { type: P, element: T } = D;
    return t.clearSelection(), P === "arrow" ? m ? t.editArrowLabel(T) : t.selectArrow(T) : m ? t.editSummary(T) : t.selectSummary(T), !0;
  }, f = (h) => {
    if (h.pointerType === "mouse" && h.button !== 0) return;
    if (t.helper1?.moved) {
      t.helper1.clear();
      return;
    }
    if (t.helper2?.moved) {
      t.helper2.clear();
      return;
    }
    if (e.moved) {
      e.clear();
      return;
    }
    if (c?.isDragging)
      return;
    const m = h.target;
    m.tagName === "ME-EPD" && (h.ctrlKey || h.metaKey ? t.expandNodeAll(m.previousSibling) : t.expandNode(m.previousSibling));
  }, a = (h) => {
    if (!t.editable) return;
    const m = h.target;
    if (tt(m)) {
      t.selectNode(m), t.beginEdit(m);
      return;
    }
    d(m, !0);
  }, u = (h) => {
    if (h.pointerType === "touch" && r.handlePointerDown(h)) {
      t.ptState = s.Pinch, l.clear(), e.clear(), (c.isDragging || c.pointerId !== null) && gt(t, c);
      return;
    }
    if (t.ptState === s.Pinch) return;
    const m = h.target;
    if (t.editable && m.className === "map-container" && h.button === 0 && h.pointerType === "mouse") {
      t.ptState = s.BoxSelect;
      return;
    }
    if (e.handlePointerDown(h), e.mousedown && (t.ptState = s.Pan), h.button === 0 || h.pointerType === "touch")
      if (tt(m)) {
        t.selection?.cancel();
        const E = t.currentNodes || [];
        if (h.ctrlKey || h.metaKey || t.mobileMultiSelect ? E.includes(m) ? o = m : ((t.currentArrow || t.currentSummary) && t.clearSelection(), t.selection?.select(m)) : E.includes(m) || t.selectNode(m), !t.editable) return;
        h.pointerType === "touch" ? (t.ptState = s.DragWait, l.start(h, (P) => {
          pt(t, c, P, !0) && (t.ptState = s.Drag, m.setPointerCapture(P.pointerId));
        })) : pt(t, c, h, !1) && (t.ptState = s.Drag, m.setPointerCapture(h.pointerId));
      } else
        d(m, !1);
  }, g = (h) => {
    switch (t.ptState) {
      case s.Pinch:
        r.handlePointerMove(h);
        break;
      case s.DragWait:
        l.handleMove(h), l.timer === null && (t.ptState = s.Pan, e.handlePointerMove(h));
        break;
      case s.Drag:
        Ft(t, c, h);
        break;
      case s.Pan:
        e.handlePointerMove(h);
        break;
    }
  }, p = (h) => {
    h.preventDefault(), window.removeEventListener("contextmenu", p, !0);
  }, b = (h) => {
    h.pointerType === "touch" && r.handlePointerUp(h);
    const m = c.isDragging, x = e.moved;
    switch (t.ptState) {
      case s.DragWait:
        l.clear();
        break;
      case s.Drag:
        Gt(t, c, h);
        break;
      case s.Pan:
        e.handlePointerUp(h), e.moved && h.button === 2 && h.pointerType === "mouse" && (window.addEventListener("contextmenu", p, { capture: !0, once: !0 }), setTimeout(() => window.removeEventListener("contextmenu", p, !0), 300));
        break;
    }
    i.detect(h, a), (t.ptState !== s.Pinch || r.activePointers.size < 2) && (t.ptState = s.Idle), o && (!m && !x && t.selection?.deselect(o), o = null);
  }, y = () => {
    r.clear(), l.clear(), e.clear(), i.clear(), (c.isDragging || c.pointerId !== null) && gt(t, c), t.ptState = s.Idle, o = null;
  }, w = (h) => {
    h.preventDefault(), h.button === 2 && t.editable && setTimeout(() => {
      if (t.panHelper.moved || t.ptState !== s.Idle && t.ptState !== s.Pan) return;
      const m = h.target;
      tt(m) && !m.classList.contains("selected") && t.selectNode(m), t.bus.fire("showContextMenu", h);
    }, 200);
  }, v = (h) => {
    if (h.ctrlKey || h.metaKey)
      return h.stopPropagation(), h.preventDefault(), ke(t, h);
    (h.shiftKey ? t.move(-h.deltaY, 0) : t.move(-h.deltaX, -h.deltaY)) && (h.stopPropagation(), h.preventDefault());
  }, C = (h) => {
    h.code === "Space" && (t.spacePressed = !0, t.container.classList.add("space-pressed"));
  }, S = (h) => {
    h.code === "Space" && (t.spacePressed = !1, t.container.classList.remove("space-pressed"));
  };
  return vt([
    { dom: n, evt: "pointerdown", func: u },
    { dom: n, evt: "pointermove", func: g },
    { dom: n, evt: "pointerup", func: b },
    { dom: n, evt: "pointercancel", func: y },
    { dom: n, evt: "click", func: f },
    { dom: n, evt: "contextmenu", func: w },
    { dom: n, evt: "wheel", func: typeof t.handleWheel == "function" ? t.handleWheel : v },
    { dom: n, evt: "blur", func: y },
    { dom: n, evt: "keydown", func: C },
    { dom: n, evt: "keyup", func: S }
  ]);
}
function He() {
  return {
    handlers: {},
    addListener: function(t, e) {
      this.handlers[t] === void 0 && (this.handlers[t] = []), this.handlers[t].push(e);
    },
    fire: function(t, ...e) {
      if (this.handlers[t] instanceof Array) {
        const n = this.handlers[t];
        for (let o = 0; o < n.length; o++)
          n[o](...e);
      }
    },
    removeListener: function(t, e) {
      if (!this.handlers[t]) return;
      const n = this.handlers[t];
      if (!e)
        n.length = 0;
      else if (n.length)
        for (let o = 0; o < n.length; o++)
          n[o] === e && this.handlers[t].splice(o, 1);
    }
  };
}
const I = "http://www.w3.org/2000/svg", Z = function(t) {
  const e = t.clientWidth, n = t.clientHeight, o = t.dataset, i = Number(o.x), s = Number(o.y), r = o.anchor;
  let c = i;
  r === "middle" ? c = i - e / 2 : r === "end" && (c = i - e), t.style.left = `${c}px`, t.style.top = `${s - n / 2}px`, t.style.visibility = "visible";
}, q = function(t, e, n, o) {
  const { anchor: i = "middle", color: s, dataType: r, svgId: c } = o, l = document.createElement("div");
  l.className = "svg-label", l.style.color = s || "#666";
  const d = "label-" + c;
  return l.id = d, l.innerHTML = t, l.dataset.type = r, l.dataset.svgId = c, l.dataset.x = e.toString(), l.dataset.y = n.toString(), l.dataset.anchor = i, l;
}, Dt = function(t, e, n) {
  const o = document.createElementNS(I, "path");
  return L(o, {
    d: t,
    stroke: e || "#666",
    fill: "none",
    "stroke-width": n
  }), o;
}, V = function(t) {
  const e = document.createElementNS(I, "svg");
  return e.setAttribute("class", t), e.setAttribute("overflow", "visible"), e;
}, mt = function() {
  const t = document.createElementNS(I, "line");
  return t.setAttribute("stroke", "#4dc4ff"), t.setAttribute("fill", "none"), t.setAttribute("stroke-width", "2"), t.setAttribute("opacity", "0.45"), t;
}, Oe = function(t, e, n, o) {
  const i = document.createElementNS(I, "g");
  return [
    {
      name: "line",
      d: t
    },
    {
      name: "arrow1",
      d: e
    },
    {
      name: "arrow2",
      d: n
    }
  ].forEach((r, c) => {
    const l = r.d, d = document.createElementNS(I, "path"), f = {
      d: l,
      stroke: o?.stroke || "rgb(227, 125, 116)",
      fill: "none",
      "stroke-width": String(o?.strokeWidth || "2")
    };
    o?.opacity !== void 0 && (f.opacity = String(o.opacity)), L(d, f), c === 0 && d.setAttribute("stroke-dasharray", o?.strokeDasharray || "8,2");
    const a = document.createElementNS(I, "path");
    L(a, {
      d: l,
      stroke: "transparent",
      fill: "none",
      "stroke-width": "15"
    }), i.appendChild(a), i.appendChild(d), i[r.name] = d;
  }), i;
}, Mt = function(t, e, n) {
  if (!e) return;
  const o = n.label;
  e.style.opacity = "0";
  const i = e.cloneNode(!0);
  t.nodes.appendChild(i), i.id = "input-box", i.textContent = o, i.contentEditable = "plaintext-only", i.spellcheck = !1, i.style.cssText = `
    left:${e.style.left};
    top:${e.style.top}; 
    max-width: 200px;
  `, St(i), t.scrollIntoView(i), i.addEventListener("keydown", (s) => {
    if (s.stopPropagation(), s.isComposing) return;
    const r = s.key;
    if (r === "Enter" || r === "Tab") {
      if (s.shiftKey) return;
      s.preventDefault(), i.blur(), t.container.focus();
    }
  }), i.addEventListener("blur", () => {
    if (!i) return;
    const s = i.innerText?.trim() || "";
    s === "" ? n.label = o : n.label = s, e.style.opacity = "1", i.remove(), s !== o && (t.markdown ? e.innerHTML = t.markdown(n.label, n) : e.textContent = n.label, Z(e), "parent" in n ? t.bus.fire("operation", {
      name: "finishEditSummary",
      obj: n
    }) : t.bus.fire("operation", {
      name: "finishEditArrowLabel",
      obj: n
    }));
  });
}, Ie = function(t) {
  const e = this.map.querySelector("me-root"), n = e.offsetTop, o = e.offsetLeft, i = e.offsetWidth, s = e.offsetHeight, r = this.map.querySelectorAll("me-main > me-wrapper");
  this.lines.innerHTML = "";
  for (let c = 0; c < r.length; c++) {
    const l = r[c], d = l.querySelector("me-tpc"), { offsetLeft: f, offsetTop: a } = H(this.nodes, d), u = d.offsetWidth, g = d.offsetHeight, p = l.parentNode.className, b = this.generateMainBranch({
      pT: n,
      pL: o,
      pW: i,
      pH: s,
      cT: a,
      cL: f,
      cW: u,
      cH: g,
      direction: p,
      containerHeight: this.nodes.offsetHeight,
      containerWidth: this.nodes.offsetWidth
    }), y = this.theme.palette, w = d.nodeObj.branchColor || y[c % y.length];
    if (d.style.borderColor = w, this.lines.appendChild(Dt(b, w, "3")), t && t !== l)
      continue;
    const v = V("subLines"), C = l.lastChild;
    C.tagName === "svg" && C.remove(), l.appendChild(v), Lt(this, v, w, l, p, !0);
  }
  this.labelContainer.innerHTML = "", this.renderArrow(), this.renderSummary(), this.bus.fire("linkDiv");
}, Lt = function(t, e, n, o, i, s) {
  const r = o.firstChild, c = o.children[1].children;
  if (c.length === 0) return;
  const l = r.offsetTop, d = r.offsetLeft, f = r.offsetWidth, a = r.offsetHeight;
  for (let u = 0; u < c.length; u++) {
    const g = c[u], p = g.firstChild, b = p.offsetTop, y = p.offsetLeft, w = p.offsetWidth, v = p.offsetHeight, C = p.firstChild.nodeObj.branchColor || n, S = t.generateSubBranch({ pT: l, pL: d, pW: f, pH: a, cT: b, cL: y, cW: w, cH: v, direction: i, isFirst: s });
    e.appendChild(Dt(S, C, "2"));
    const M = p.children[1];
    if (M) {
      if (!M.expanded) continue;
    } else
      continue;
    Lt(t, e, C, g, i);
  }
}, We = '<?xml version="1.0" standalone="no"?><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"><svg t="1750169394918" class="icon" viewBox="0 0 1024 1024" version="1.1" xmlns="http://www.w3.org/2000/svg" p-id="2021" xmlns:xlink="http://www.w3.org/1999/xlink" width="200" height="200"><path d="M851.91168 328.45312c-59.97056 0-108.6208 48.47104-108.91264 108.36992l-137.92768 38.4a109.14304 109.14304 0 0 0-63.46752-46.58688l1.39264-137.11872c47.29344-11.86816 82.31936-54.66624 82.31936-105.64096 0-60.15488-48.76288-108.91776-108.91776-108.91776s-108.91776 48.76288-108.91776 108.91776c0 49.18784 32.60928 90.75712 77.38368 104.27392l-1.41312 138.87488a109.19936 109.19936 0 0 0-63.50336 48.55808l-138.93632-39.48544 0.01024-0.72704c0-60.15488-48.76288-108.91776-108.91776-108.91776s-108.91776 48.75776-108.91776 108.91776c0 60.15488 48.76288 108.91264 108.91776 108.91264 39.3984 0 73.91232-20.92032 93.03552-52.2496l139.19232 39.552-0.00512 0.2304c0 25.8304 9.00096 49.5616 24.02816 68.23424l-90.14272 132.63872a108.7488 108.7488 0 0 0-34.2528-5.504c-60.15488 0-108.91776 48.768-108.91776 108.91776 0 60.16 48.76288 108.91776 108.91776 108.91776 60.16 0 108.92288-48.75776 108.92288-108.91776 0-27.14624-9.9328-51.968-26.36288-71.04l89.04704-131.03104a108.544 108.544 0 0 0 37.6832 6.70208 108.672 108.672 0 0 0 36.48512-6.272l93.13792 132.57216a108.48256 108.48256 0 0 0-24.69888 69.0688c0 60.16 48.768 108.92288 108.91776 108.92288 60.16 0 108.91776-48.76288 108.91776-108.92288 0-60.14976-48.75776-108.91776-108.91776-108.91776a108.80512 108.80512 0 0 0-36.69504 6.3488l-93.07136-132.48a108.48768 108.48768 0 0 0 24.79616-72.22784l136.09984-37.888c18.99008 31.93856 53.84192 53.3504 93.69088 53.3504 60.16 0 108.92288-48.75776 108.92288-108.91264-0.00512-60.15488-48.77312-108.92288-108.92288-108.92288z" p-id="2022"></path></svg>', Be = '<?xml version="1.0" standalone="no"?><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"><svg t="1750169375313" class="icon" viewBox="0 0 1024 1024" version="1.1" xmlns="http://www.w3.org/2000/svg" p-id="1775" xmlns:xlink="http://www.w3.org/1999/xlink" width="200" height="200"><path d="M639 463.30000001L639 285.1c0-36.90000001-26.4-68.5-61.3-68.5l-150.2 0c-1.5 0-3 0.1-4.5 0.3-10.2-38.7-45.5-67.3-87.5-67.3-50 0-90.5 40.5-90.5 90.5s40.5 90.5 90.5 90.5c42 0 77.3-28.6 87.5-67.39999999 1.4 0.3 2.9 0.4 4.5 0.39999999L577.7 263.6c6.8 0 14.3 8.9 14.3 21.49999999l0 427.00000001c0 12.7-7.40000001 21.5-14.30000001 21.5l-150.19999999 0c-1.5 0-3 0.2-4.5 0.4-10.2-38.8-45.5-67.3-87.5-67.3-50 0-90.5 40.5-90.5 90.4 0 49.9 40.5 90.6 90.5 90.59999999 42 0 77.3-28.6 87.5-67.39999999 1.4 0.2 2.9 0.4 4.49999999 0.4L577.7 780.7c34.80000001 0 61.3-31.6 61.3-68.50000001L639 510.3l79.1 0c10.4 38.5 45.49999999 67 87.4 67 50 0 90.5-40.5 90.5-90.5s-40.5-90.5-90.5-90.5c-41.79999999 0-77.00000001 28.4-87.4 67L639 463.30000001z" fill="currentColor" p-id="1776"></path></svg>', Ye = '<?xml version="1.0" standalone="no"?><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"><svg t="1750169667709" class="icon" viewBox="0 0 1024 1024" version="1.1" xmlns="http://www.w3.org/2000/svg" p-id="3037" xmlns:xlink="http://www.w3.org/1999/xlink" width="200" height="200"><path d="M385 560.69999999L385 738.9c0 36.90000001 26.4 68.5 61.3 68.5l150.2 0c1.5 0 3-0.1 4.5-0.3 10.2 38.7 45.5 67.3 87.5 67.3 50 0 90.5-40.5 90.5-90.5s-40.5-90.5-90.5-90.5c-42 0-77.3 28.6-87.5 67.39999999-1.4-0.3-2.9-0.4-4.5-0.39999999L446.3 760.4c-6.8 0-14.3-8.9-14.3-21.49999999l0-427.00000001c0-12.7 7.40000001-21.5 14.30000001-21.5l150.19999999 0c1.5 0 3-0.2 4.5-0.4 10.2 38.8 45.5 67.3 87.5 67.3 50 0 90.5-40.5 90.5-90.4 0-49.9-40.5-90.6-90.5-90.59999999-42 0-77.3 28.6-87.5 67.39999999-1.4-0.2-2.9-0.4-4.49999999-0.4L446.3 243.3c-34.80000001 0-61.3 31.6-61.3 68.50000001L385 513.7l-79.1 0c-10.4-38.5-45.49999999-67-87.4-67-50 0-90.5 40.5-90.5 90.5s40.5 90.5 90.5 90.5c41.79999999 0 77.00000001-28.4 87.4-67L385 560.69999999z" fill="currentColor" p-id="3038"></path></svg>', Re = '<?xml version="1.0" standalone="no"?><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"><svg t="1750169402629" class="icon" viewBox="0 0 1024 1024" version="1.1" xmlns="http://www.w3.org/2000/svg" p-id="2170" xmlns:xlink="http://www.w3.org/1999/xlink" width="200" height="200"><path d="M639.328 416c8.032 0 16.096-3.008 22.304-9.056l202.624-197.184-0.8 143.808c-0.096 17.696 14.144 32.096 31.808 32.192 0.064 0 0.128 0 0.192 0 17.6 0 31.904-14.208 32-31.808l1.248-222.208c0-0.672-0.352-1.248-0.384-1.92 0.032-0.512 0.288-0.896 0.288-1.408 0.032-17.664-14.272-32-31.968-32.032L671.552 96l-0.032 0c-17.664 0-31.968 14.304-32 31.968C639.488 145.632 653.824 160 671.488 160l151.872 0.224-206.368 200.8c-12.672 12.32-12.928 32.608-0.64 45.248C622.656 412.736 630.976 416 639.328 416z" p-id="2171"></path><path d="M896.032 639.552 896.032 639.552c-17.696 0-32 14.304-32.032 31.968l-0.224 151.872-200.832-206.4c-12.32-12.64-32.576-12.96-45.248-0.64-12.672 12.352-12.928 32.608-0.64 45.248l197.184 202.624-143.808-0.8c-0.064 0-0.128 0-0.192 0-17.6 0-31.904 14.208-32 31.808-0.096 17.696 14.144 32.096 31.808 32.192l222.24 1.248c0.064 0 0.128 0 0.192 0 0.64 0 1.12-0.32 1.76-0.352 0.512 0.032 0.896 0.288 1.408 0.288l0.032 0c17.664 0 31.968-14.304 32-31.968L928 671.584C928.032 653.952 913.728 639.584 896.032 639.552z" p-id="2172"></path><path d="M209.76 159.744l143.808 0.8c0.064 0 0.128 0 0.192 0 17.6 0 31.904-14.208 32-31.808 0.096-17.696-14.144-32.096-31.808-32.192L131.68 95.328c-0.064 0-0.128 0-0.192 0-0.672 0-1.248 0.352-1.888 0.384-0.448 0-0.8-0.256-1.248-0.256 0 0-0.032 0-0.032 0-17.664 0-31.968 14.304-32 31.968L96 352.448c-0.032 17.664 14.272 32 31.968 32.032 0 0 0.032 0 0.032 0 17.664 0 31.968-14.304 32-31.968l0.224-151.936 200.832 206.4c6.272 6.464 14.624 9.696 22.944 9.696 8.032 0 16.096-3.008 22.304-9.056 12.672-12.32 12.96-32.608 0.64-45.248L209.76 159.744z" p-id="2173"></path><path d="M362.368 617.056l-202.624 197.184 0.8-143.808c0.096-17.696-14.144-32.096-31.808-32.192-0.064 0-0.128 0-0.192 0-17.6 0-31.904 14.208-32 31.808l-1.248 222.24c0 0.704 0.352 1.312 0.384 2.016 0 0.448-0.256 0.832-0.256 1.312-0.032 17.664 14.272 32 31.968 32.032L352.448 928c0 0 0.032 0 0.032 0 17.664 0 31.968-14.304 32-31.968s-14.272-32-31.968-32.032l-151.936-0.224 206.4-200.832c12.672-12.352 12.96-32.608 0.64-45.248S375.008 604.704 362.368 617.056z" p-id="2174"></path></svg>', Xe = '<?xml version="1.0" standalone="no"?><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"><svg t="1750169573443" class="icon" viewBox="0 0 1024 1024" version="1.1" xmlns="http://www.w3.org/2000/svg" p-id="2883" xmlns:xlink="http://www.w3.org/1999/xlink" width="200" height="200"><path d="M514.133333 488.533333m-106.666666 0a106.666667 106.666667 0 1 0 213.333333 0 106.666667 106.666667 0 1 0-213.333333 0Z" fill="currentColor" p-id="2884"></path><path d="M512 64C264.533333 64 64 264.533333 64 512c0 236.8 183.466667 428.8 416 445.866667v-134.4c-53.333333-59.733333-200.533333-230.4-200.533333-334.933334 0-130.133333 104.533333-234.666667 234.666666-234.666666s234.666667 104.533333 234.666667 234.666666c0 61.866667-49.066667 153.6-145.066667 270.933334l-59.733333 68.266666V960C776.533333 942.933333 960 748.8 960 512c0-247.466667-200.533333-448-448-448z" fill="currentColor" p-id="2885"></path></svg>', Ve = '<?xml version="1.0" standalone="no"?><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"><svg t="1750169419447" class="icon" viewBox="0 0 1024 1024" version="1.1" xmlns="http://www.w3.org/2000/svg" p-id="2480" xmlns:xlink="http://www.w3.org/1999/xlink" width="200" height="200"><path d="M863.328 482.56l-317.344-1.12L545.984 162.816c0-17.664-14.336-32-32-32s-32 14.336-32 32l0 318.4L159.616 480.064c-0.032 0-0.064 0-0.096 0-17.632 0-31.936 14.24-32 31.904C127.424 529.632 141.728 544 159.392 544.064l322.592 1.152 0 319.168c0 17.696 14.336 32 32 32s32-14.304 32-32l0-318.944 317.088 1.12c0.064 0 0.096 0 0.128 0 17.632 0 31.936-14.24 32-31.904C895.264 496.992 880.96 482.624 863.328 482.56z" p-id="2481"></path></svg>', ze = '<?xml version="1.0" standalone="no"?><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"><svg t="1750169426515" class="icon" viewBox="0 0 1024 1024" version="1.1" xmlns="http://www.w3.org/2000/svg" p-id="2730" xmlns:xlink="http://www.w3.org/1999/xlink" width="200" height="200"><path d="M863.744 544 163.424 544c-17.664 0-32-14.336-32-32s14.336-32 32-32l700.32 0c17.696 0 32 14.336 32 32S881.44 544 863.744 544z" p-id="2731"></path></svg>', Fe = {
  side: We,
  left: Be,
  right: Ye,
  full: Re,
  living: Xe,
  zoomin: Ve,
  zoomout: ze
}, B = (t, e) => {
  const n = document.createElement("span");
  return n.id = t, n.innerHTML = Fe[e], n;
};
function Ge(t) {
  const e = document.createElement("div"), n = B("fullscreen", "full"), o = B("toCenter", "living"), i = B("zoomout", "zoomout"), s = B("zoomin", "zoomin");
  e.appendChild(n), e.appendChild(o), e.appendChild(i), e.appendChild(s), e.className = "mind-elixir-toolbar rb";
  let r = null;
  const c = () => {
    const d = t.container.getBoundingClientRect(), f = lt(t.map.style.transform), a = d.width / 2, u = d.height / 2, g = (a - f.x) / t.scaleVal, p = (u - f.y) / t.scaleVal;
    r = {
      containerRect: d,
      currentTransform: f,
      mapCenterX: g,
      mapCenterY: p
    };
  }, l = () => {
    if (r) {
      const d = t.container.getBoundingClientRect(), f = d.width / 2, a = d.height / 2, u = f - r.mapCenterX * t.scaleVal, g = a - r.mapCenterY * t.scaleVal, p = u - r.currentTransform.x, b = g - r.currentTransform.y;
      t.move(p, b);
    }
  };
  return t.el.addEventListener("fullscreenchange", l), n.onclick = () => {
    c(), document.fullscreenElement !== t.el ? t.el.requestFullscreen() : document.exitFullscreen();
  }, o.onclick = () => {
    t.toCenter();
  }, i.onclick = () => {
    t.scale(t.scaleVal - t.scaleSensitivity);
  }, s.onclick = () => {
    t.scale(t.scaleVal + t.scaleSensitivity);
  }, e;
}
function je(t) {
  const e = document.createElement("div"), n = B("tbltl", "left"), o = B("tbltr", "right"), i = B("tblts", "side");
  return e.appendChild(n), e.appendChild(o), e.appendChild(i), e.className = "mind-elixir-toolbar lt", n.onclick = () => {
    t.initLeft();
  }, o.onclick = () => {
    t.initRight();
  }, i.onclick = () => {
    t.initSide();
  }, e;
}
function _e(t) {
  t.container.append(Ge(t)), t.container.append(je(t));
}
const Pt = function(t, e, n, o, i = 8) {
  if (t === n) return `M ${t} ${e} V ${o}`;
  const s = (e + o) / 2, r = n > t ? 1 : -1, c = Math.min(i, Math.abs(n - t) / 2, Math.abs(s - e), Math.abs(o - s));
  return `M ${t} ${e} V ${s - c} Q ${t} ${s} ${t + r * c} ${s} H ${n - r * c} Q ${n} ${s} ${n} ${s + c} V ${o}`;
};
function $t({ pT: t, pL: e, pW: n, pH: o, cT: i, cL: s, cW: r, cH: c, direction: l, containerHeight: d, containerWidth: f }) {
  if (l === O.DOWN) {
    const w = e + n / 2, v = s + r / 2, C = t + o;
    return Pt(w, C, v, i);
  }
  let a = e + n / 2;
  const u = t + o / 2;
  let g;
  l === O.LHS ? g = s + r : g = s;
  const p = i + c / 2, y = (1 - Math.abs(p - u) / d) * 0.25 * (n / 2);
  return l === O.LHS ? a = a - n / 10 - y : a = a + n / 10 + y, `M ${a} ${u} Q ${a} ${p} ${g} ${p}`;
}
function Nt({ pT: t, pL: e, pW: n, pH: o, cT: i, cL: s, cW: r, cH: c, direction: l, isFirst: d }) {
  if (l === O.DOWN) {
    const v = e + n / 2, C = t + o, S = s + r / 2;
    return Pt(v, C, S, i);
  }
  const f = parseInt(this.container.style.getPropertyValue("--node-gap-x"));
  let a = 0, u = 0;
  d ? a = t + o / 2 : a = t + o;
  const g = i + c;
  let p = 0, b = 0, y = 0;
  const w = Math.abs(a - g) / 300 * f;
  return l === O.LHS ? (y = e, p = y + f, b = y - f, u = s + f, `M ${p} ${a} C ${y} ${a} ${y + w} ${g} ${b} ${g} H ${u}`) : (y = e + n, p = y - f, b = y + f, u = s + r - f, `M ${p} ${a} C ${y} ${a} ${y - w} ${g} ${b} ${g} H ${u}`);
}
const qe = function(t, e = !0) {
  this.theme = t, this.generateMainBranch = this.theme.generateMainBranch || $t, this.generateSubBranch = this.theme.generateSubBranch || Nt;
  const o = {
    ...(this.theme.type === "dark" ? st : ot).cssVar,
    ...this.theme.cssVar
  };
  this.compact && (o["--node-gap-x"] = "15px", o["--node-gap-y"] = "2px", o["--main-gap-x"] = "30px", o["--main-gap-y"] = "6px");
  const i = Object.keys(o);
  for (let s = 0; s < i.length; s++) {
    const r = i[s];
    this.container.style.setProperty(r, o[r]);
  }
  e && this.refresh();
}, Ue = function(t) {
  this.compact = t, this.theme && this.changeTheme(this.theme);
}, Ke = function(t) {
  return {
    dom: t,
    moved: !1,
    // differentiate click and move
    sessionMoved: !1,
    // whether the current drag session actually moved
    pointerdown: !1,
    lastX: 0,
    lastY: 0,
    handlePointerMove(e) {
      if (this.pointerdown) {
        this.moved = !0, this.sessionMoved = !0;
        const n = e.clientX - this.lastX, o = e.clientY - this.lastY;
        this.lastX = e.clientX, this.lastY = e.clientY, this.cb && this.cb(n, o);
      }
    },
    handlePointerDown(e) {
      e.button === 0 && (this.pointerdown = !0, this.sessionMoved = !1, this.lastX = e.clientX, this.lastY = e.clientY, this.dom.setPointerCapture(e.pointerId));
    },
    handleClear(e) {
      const n = this.pointerdown && this.sessionMoved;
      this.pointerdown = !1, this.sessionMoved = !1, e.pointerId !== void 0 && this.dom.releasePointerCapture(e.pointerId), n && this.onEnd && this.onEnd();
    },
    cb: null,
    onEnd: null,
    init(e, n, o) {
      this.cb = n, this.onEnd = o || null, this.handleClear = this.handleClear.bind(this), this.handlePointerMove = this.handlePointerMove.bind(this), this.handlePointerDown = this.handlePointerDown.bind(this), this.destroy = vt([
        { dom: e, evt: "pointermove", func: this.handlePointerMove },
        { dom: e, evt: "pointerleave", func: this.handleClear },
        { dom: e, evt: "pointerup", func: this.handleClear },
        { dom: this.dom, evt: "pointerdown", func: this.handlePointerDown }
      ]);
    },
    destroy: null,
    clear() {
      this.moved = !1, this.pointerdown = !1;
    }
  };
}, yt = {
  create: Ke
}, kt = "#4dc4ff";
function At(t, e, n, o, i, s, r, c) {
  return {
    x: t / 8 + n * 3 / 8 + i * 3 / 8 + r / 8,
    y: e / 8 + o * 3 / 8 + s * 3 / 8 + c / 8
  };
}
function Je(t, e, n) {
  t && (t.dataset.x = e.toString(), t.dataset.y = n.toString(), Z(t));
}
function Y(t, e, n, o, i) {
  L(t, {
    x1: e + "",
    y1: n + "",
    x2: o + "",
    y2: i + ""
  });
}
function rt(t, e, n, o, i, s, r, c, l, d) {
  const f = `M ${e} ${n} C ${o} ${i} ${s} ${r} ${c} ${l}`;
  t.line.setAttribute("d", f);
  const a = d.style || {};
  t.line.setAttribute("stroke", a.stroke || "rgb(227, 125, 116)"), t.line.setAttribute("stroke-width", String(a.strokeWidth || "2")), t.line.setAttribute("stroke-dasharray", a.strokeDasharray || "8,2"), a.opacity !== void 0 && a.opacity !== null && a.opacity !== "" ? t.line.setAttribute("opacity", String(a.opacity)) : t.line.removeAttribute("opacity");
  const u = t.querySelectorAll('path[stroke="transparent"]');
  u.length > 0 && u[0].setAttribute("d", f);
  const g = K(s, r, c, l);
  if (g) {
    const w = `M ${g.x1} ${g.y1} L ${c} ${l} L ${g.x2} ${g.y2}`;
    t.arrow1.setAttribute("d", w), u.length > 1 && u[1].setAttribute("d", w), t.arrow1.setAttribute("stroke", a.stroke || "rgb(227, 125, 116)"), t.arrow1.setAttribute("stroke-width", String(a.strokeWidth || "2")), a.opacity !== void 0 && a.opacity !== null && a.opacity !== "" ? t.arrow1.setAttribute("opacity", String(a.opacity)) : t.arrow1.removeAttribute("opacity");
  }
  if (d.bidirectional) {
    const w = K(o, i, e, n);
    if (w) {
      const v = `M ${w.x1} ${w.y1} L ${e} ${n} L ${w.x2} ${w.y2}`;
      t.arrow2.setAttribute("d", v), u.length > 2 && u[2].setAttribute("d", v);
    }
  } else
    t.arrow2.setAttribute("d", ""), u.length > 2 && u[2].setAttribute("d", "");
  t.arrow2.setAttribute("stroke", a.stroke || "rgb(227, 125, 116)"), t.arrow2.setAttribute("stroke-width", String(a.strokeWidth || "2")), a.opacity !== void 0 && a.opacity !== null && a.opacity !== "" ? t.arrow2.setAttribute("opacity", String(a.opacity)) : t.arrow2.removeAttribute("opacity");
  const { x: p, y: b } = At(e, n, o, i, s, r, c, l);
  t.labelEl && Je(t.labelEl, p, b);
  const y = t.labelEl;
  y && (y.style.color = a.labelColor || "rgb(235, 95, 82)"), sn(t);
}
function R(t, e, n) {
  const { offsetLeft: o, offsetTop: i } = H(t.nodes, e), s = e.offsetWidth, r = e.offsetHeight, c = o + s / 2, l = i + r / 2, d = c + n.x, f = l + n.y;
  return {
    w: s,
    h: r,
    cx: c,
    cy: l,
    ctrlX: d,
    ctrlY: f
  };
}
function W(t) {
  const e = t.w / 2, n = t.h / 2, o = t.ctrlX - t.cx, i = t.ctrlY - t.cy, s = Math.hypot(o, i);
  if (s === 0 || e === 0 && n === 0)
    return { x: t.cx, y: t.cy };
  const r = o / s, c = i / s, l = Math.min(e / Math.abs(r), n / Math.abs(c));
  return { x: t.cx + r * l, y: t.cy + c * l };
}
const Ht = function(t, e, n) {
  const o = H(t.nodes, e), i = H(t.nodes, n), s = o.offsetLeft + e.offsetWidth / 2, r = o.offsetTop + e.offsetHeight / 2, c = i.offsetLeft + n.offsetWidth / 2, l = i.offsetTop + n.offsetHeight / 2, d = c - s, f = l - r, a = Math.sqrt(d * d + f * f), u = Math.max(50, Math.min(200, a * 0.3)), g = Math.abs(d), p = Math.abs(f);
  let b, y;
  if (a < 150) {
    const v = e.closest("me-main"), C = v ? v.className === "lhs" ? -1 : 1 : d > 0 ? -1 : 1;
    b = { x: 200 * C, y: 0 }, y = { x: 200 * C, y: 0 };
  } else if (g > p * 1.5) {
    const v = d > 0 ? e.offsetWidth / 2 : -e.offsetWidth / 2, C = d > 0 ? -n.offsetWidth / 2 : n.offsetWidth / 2;
    b = { x: v + (d > 0 ? u : -u), y: 0 }, y = { x: C + (d > 0 ? -u : u), y: 0 };
  } else if (p > g * 1.5) {
    const v = f > 0 ? e.offsetHeight / 2 : -e.offsetHeight / 2, C = f > 0 ? -n.offsetHeight / 2 : n.offsetHeight / 2;
    b = { x: 0, y: v + (f > 0 ? u : -u) }, y = { x: 0, y: C + (f > 0 ? -u : u) };
  } else {
    const v = Math.atan2(f, d), C = e.offsetWidth / 2 * Math.cos(v), S = e.offsetHeight / 2 * Math.sin(v), M = -(n.offsetWidth / 2) * Math.cos(v), h = -(n.offsetHeight / 2) * Math.sin(v), m = u * 0.7 * (d > 0 ? 1 : -1), x = u * 0.7 * (f > 0 ? 1 : -1);
    b = { x: C + m, y: S + x }, y = { x: M - m, y: h - x };
  }
  return {
    delta1: { x: Math.round(b.x), y: Math.round(b.y) },
    delta2: { x: Math.round(y.x), y: Math.round(y.y) }
  };
}, ht = function(t, e, n, o, i) {
  if (!e || !n)
    return;
  if (!o.delta1 || !o.delta2) {
    const E = Ht(t, e, n);
    o.delta1 = E.delta1, o.delta2 = E.delta2;
  }
  const s = R(t, e, o.delta1), r = R(t, n, o.delta2), { x: c, y: l } = W(s), { ctrlX: d, ctrlY: f } = s, { ctrlX: a, ctrlY: u } = r, { x: g, y: p } = W(r), b = K(a, u, g, p);
  if (!b) return;
  const y = `M ${b.x1} ${b.y1} L ${g} ${p} L ${b.x2} ${b.y2}`;
  let w = "";
  if (o.bidirectional) {
    const E = K(d, f, c, l);
    if (!E) return;
    w = `M ${E.x1} ${E.y1} L ${c} ${l} L ${E.x2} ${E.y2}`;
  }
  const v = Oe(`M ${c} ${l} C ${d} ${f} ${a} ${u} ${g} ${p}`, y, w, o.style), { x: C, y: S } = At(c, l, d, f, a, u, g, p), M = o.style?.labelColor || "rgb(235, 95, 82)", h = "a-" + o.id;
  v.id = h;
  const m = t.markdown ? t.markdown(o.label, o) : o.label, x = q(m, C, S, {
    anchor: "middle",
    color: M,
    dataType: "arrow",
    svgId: h
  });
  v.labelEl = x, v.arrowObj = o, v.dataset.linkid = o.id, t.labelContainer.appendChild(x), t.arrowSvg.appendChild(v), Z(x), i || (t.arrows.push(o), t.currentArrow = v, It(t, o, s, r));
}, Ze = function(t, e, n = {}) {
  const o = {
    id: X(),
    label: "Custom Link",
    from: t.nodeObj.id,
    to: e.nodeObj.id,
    ...n
  };
  ht(this, t, e, o), this.bus.fire("operation", {
    name: "createArrow",
    obj: o
  });
}, Qe = function(t) {
  Q(this);
  const e = { ...t, id: X() };
  ht(this, this.findEle(e.from), this.findEle(e.to), e), this.bus.fire("operation", {
    name: "createArrow",
    obj: e
  });
}, tn = function(t) {
  let e;
  if (t ? e = t : e = this.currentArrow, !e) return;
  Q(this);
  const n = e.arrowObj.id;
  this.arrows = this.arrows.filter((o) => o.id !== n), e.labelEl?.remove(), e.remove(), this.bus.fire("operation", {
    name: "removeArrow",
    obj: {
      id: n
    }
  });
}, en = function(t) {
  this.currentArrow = t;
  const e = t.arrowObj, n = this.findEle(e.from), o = this.findEle(e.to), i = R(this, n, e.delta1), s = R(this, o, e.delta2);
  this.editable ? It(this, e, i, s) : Ot(t, kt), this.bus.fire("selectArrow", e);
}, nn = function() {
  Q(this), this.currentArrow = null, this.bus.fire("unselectArrow");
}, et = function(t, e) {
  const n = document.createElementNS(I, "path");
  return L(n, {
    d: t,
    stroke: e,
    fill: "none",
    "stroke-width": "6",
    "stroke-linecap": "round",
    "stroke-linejoin": "round"
  }), n;
}, Ot = function(t, e) {
  const n = document.createElementNS(I, "g");
  n.setAttribute("class", "arrow-highlight"), n.setAttribute("opacity", "0.45");
  const o = et(t.line.getAttribute("d"), e);
  n.appendChild(o);
  const i = et(t.arrow1.getAttribute("d"), e);
  if (n.appendChild(i), t.arrow2.getAttribute("d")) {
    const s = et(t.arrow2.getAttribute("d"), e);
    n.appendChild(s);
  }
  t.insertBefore(n, t.firstChild);
}, on = function(t) {
  const e = t.querySelector(".arrow-highlight");
  e && e.remove();
}, sn = function(t) {
  const e = t.querySelector(".arrow-highlight");
  if (!e) return;
  const n = e.querySelectorAll("path");
  n.length >= 1 && n[0].setAttribute("d", t.line.getAttribute("d")), n.length >= 2 && n[1].setAttribute("d", t.arrow1.getAttribute("d")), n.length >= 3 && t.arrow2.getAttribute("d") && n[2].setAttribute("d", t.arrow2.getAttribute("d"));
}, Q = function(t) {
  t.helper1?.destroy(), t.helper2?.destroy(), t.linkController.style.display = "none", t.P2.style.display = "none", t.P3.style.display = "none", t.currentArrow && on(t.currentArrow);
}, It = function(t, e, n, o) {
  const { linkController: i, P2: s, P3: r, line1: c, line2: l, nodes: d, map: f, currentArrow: a, bus: u } = t;
  if (!a) return;
  i.style.display = "initial", s.style.display = "initial", r.style.display = "initial", d.appendChild(i), d.appendChild(s), d.appendChild(r), Ot(a, kt);
  let { x: g, y: p } = W(n), { ctrlX: b, ctrlY: y } = n, { ctrlX: w, ctrlY: v } = o, { x: C, y: S } = W(o);
  s.style.cssText = `top:${y}px;left:${b}px;`, r.style.cssText = `top:${v}px;left:${w}px;`, Y(c, g, p, b, y), Y(l, w, v, C, S), t.helper1 = yt.create(s), t.helper2 = yt.create(r);
  let M = it(e);
  const h = () => {
    u.fire("operation", {
      name: "reshapeArrow",
      obj: e,
      origin: M
    }), M = it(e);
  };
  t.helper1.init(
    f,
    (m, x) => {
      b = b + m / t.scaleVal, y = y + x / t.scaleVal;
      const E = W({ ...n, ctrlX: b, ctrlY: y });
      g = E.x, p = E.y, s.style.top = y + "px", s.style.left = b + "px", rt(a, g, p, b, y, w, v, C, S, e), Y(c, g, p, b, y), e.delta1.x = Math.round(b - n.cx), e.delta1.y = Math.round(y - n.cy), u.fire("updateArrowDelta", e);
    },
    h
  ), t.helper2.init(
    f,
    (m, x) => {
      w = w + m / t.scaleVal, v = v + x / t.scaleVal;
      const E = W({ ...o, ctrlX: w, ctrlY: v });
      C = E.x, S = E.y, r.style.top = v + "px", r.style.left = w + "px", rt(a, g, p, b, y, w, v, C, S, e), Y(l, w, v, C, S), e.delta2.x = Math.round(w - o.cx), e.delta2.y = Math.round(v - o.cy), u.fire("updateArrowDelta", e);
    },
    h
  );
};
function rn() {
  this.arrowSvg.innerHTML = "", this.labelContainer.querySelectorAll('.svg-label[data-type="arrow"]').forEach((e) => e.remove());
  for (let e = 0; e < this.arrows.length; e++) {
    const n = this.arrows[e];
    try {
      ht(this, this.findEle(n.from), this.findEle(n.to), n, !0);
    } catch {
    }
  }
  this.nodes.appendChild(this.arrowSvg);
}
function cn(t) {
  Q(this), t && t.labelEl && Mt(this, t.labelEl, t.arrowObj);
}
function ln() {
  this.arrows = this.arrows.filter((t) => U(t.from, this.nodeData) && U(t.to, this.nodeData));
}
const an = function(t, e) {
  const n = it(t);
  n.style && e.style && (e.style = Object.assign({}, n.style, e.style)), Object.assign(t, e);
  const o = this.arrowSvg.querySelector(`g[data-linkid="${t.id}"]`);
  if (o) {
    if (e.label !== void 0 && o.labelEl) {
      const r = this.markdown ? this.markdown(t.label, t) : t.label;
      o.labelEl.innerHTML = r;
    }
    const i = this.findEle(t.from), s = this.findEle(t.to);
    if (i && s) {
      if (!t.delta1 || !t.delta2) {
        const y = Ht(this, i, s);
        t.delta1 = t.delta1 || y.delta1, t.delta2 = t.delta2 || y.delta2;
      }
      const r = R(this, i, t.delta1), c = R(this, s, t.delta2), { x: l, y: d } = W(r), { ctrlX: f, ctrlY: a } = r, { ctrlX: u, ctrlY: g } = c, { x: p, y: b } = W(c);
      rt(o, l, d, f, a, u, g, p, b, t), this.currentArrow?.arrowObj?.id === t.id && (this.P2.style.cssText = `top:${a}px;left:${f}px;`, this.P3.style.cssText = `top:${g}px;left:${u}px;`, Y(this.line1, l, d, f, a), Y(this.line2, u, g, p, b));
    }
  }
  this.bus.fire("operation", {
    name: "reshapeArrow",
    obj: t,
    origin: n
  });
}, hn = /* @__PURE__ */ Object.freeze(/* @__PURE__ */ Object.defineProperty({
  __proto__: null,
  createArrow: Ze,
  createArrowFrom: Qe,
  editArrowLabel: cn,
  removeArrow: tn,
  renderArrow: rn,
  reshapeArrow: an,
  selectArrow: en,
  tidyArrow: ln,
  unselectArrow: nn
}, Symbol.toStringTag, { value: "Module" })), dn = function(t) {
  if (t.length === 0) throw new Error("No selected node.");
  if (t.length === 1) {
    const l = t[0].nodeObj, d = t[0].nodeObj.parent;
    if (!d) throw new Error("Can not select root node.");
    const f = d.children.findIndex((a) => l === a);
    return {
      parent: d.id,
      start: f,
      end: f
    };
  }
  let e = 0;
  const n = t.map((l) => {
    let d = l.nodeObj;
    const f = [];
    for (; d.parent; ) {
      const a = d.parent, g = a.children?.indexOf(d);
      d = a, f.unshift({ node: d, index: g });
    }
    return f.length > e && (e = f.length), f;
  });
  let o = 0;
  t: for (; o < e; o++) {
    const l = n[0][o]?.node;
    for (let d = 1; d < n.length; d++)
      if (n[d][o]?.node !== l)
        break t;
  }
  if (!o) throw new Error("Can not select root node.");
  const i = n.map((l) => l[o - 1].index).sort((l, d) => l - d), s = i[0] || 0, r = i[i.length - 1] || 0, c = n[0][o - 1].node;
  if (!c.parent) throw new Error("Please select nodes in the same main topic.");
  return {
    parent: c.id,
    start: s,
    end: r
  };
}, fn = function(t) {
  const e = document.createElementNS(I, "g");
  return e.setAttribute("id", t), e;
}, nt = function(t, e) {
  const n = document.createElementNS(I, "path");
  return L(n, {
    d: t,
    stroke: e || "#666",
    fill: "none",
    "stroke-linecap": "round",
    "stroke-width": "2"
  }), n;
}, un = (t) => t.parentElement.parentElement, Wt = function(t, e) {
  const n = t.summaries.findIndex((o) => o.id === e);
  return n === -1 ? !1 : (t.summaries.splice(n, 1), t.nodes.querySelector("#s-" + e)?.remove(), t.nodes.querySelector("#label-s-" + e)?.remove(), !0);
}, pn = function(t, { parent: e, start: n }) {
  const o = t.findEle(e), i = o.nodeObj;
  let s;
  return i.parent ? s = o.closest("me-main").className : s = t.findEle(i.children[n].id).closest("me-main").className, s;
}, dt = function(t, e) {
  const { id: n, label: o, parent: i, start: s, end: r, style: c } = e, { nodes: l, theme: d, summarySvg: f } = t, u = t.findEle(i).nodeObj, g = pn(t, e);
  let p = 1 / 0, b = 0, y = 0, w = 0, v = 0, C = 1 / 0, S = 0;
  for (let T = s; T <= r; T++) {
    const N = u.children?.[T];
    if (!N)
      return null;
    const k = un(t.findEle(N.id)), { offsetLeft: A, offsetTop: z } = H(l, k), F = s === r ? 10 : 20;
    T === s && (y = z + F), T === r && (w = z + k.offsetHeight - F), T === s && (C = A + F), T === r && (S = A + k.offsetWidth - F), z + k.offsetHeight > v && (v = z + k.offsetHeight), A < p && (p = A), k.offsetWidth + A > b && (b = k.offsetWidth + A);
  }
  let M, h;
  const m = c?.stroke || d.cssVar["--color"], x = c?.labelColor || d.cssVar["--color"], E = "s-" + n, D = t.markdown ? t.markdown(o, e) : o;
  if (g === O.DOWN) {
    const T = v + 10, N = (C + S) / 2;
    M = nt(`M ${C} ${T - 10} c 0 5 5 10 10 10 L ${S - 10} ${T} c 5 0 10 -5 10 -10 M ${N} ${T} v 10`, m), h = q(D, N, T + 20, { anchor: "middle", color: x, dataType: "summary", svgId: E });
  } else {
    const T = u.parent ? 10 : 0, N = y + T, k = w + T, A = (N + k) / 2;
    g === O.LHS ? (M = nt(`M ${p + 10} ${N} c -5 0 -10 5 -10 10 L ${p} ${k - 10} c 0 5 5 10 10 10 M ${p} ${A} h -10`, m), h = q(D, p - 20, A, { anchor: "end", color: x, dataType: "summary", svgId: E })) : (M = nt(`M ${b - 10} ${N} c 5 0 10 5 10 10 L ${b} ${k - 10} c 0 5 -5 10 -10 10 M ${b} ${A} h 10`, m), h = q(D, b + 20, A, { anchor: "start", color: x, dataType: "summary", svgId: E }));
  }
  const P = fn(E);
  return P.appendChild(M), t.labelContainer.appendChild(h), Z(h), P.summaryObj = e, P.labelEl = h, f.appendChild(P), P;
}, gn = function(t = {}) {
  if (!this.currentNodes) return;
  const { currentNodes: e, summaries: n, bus: o } = this, { parent: i, start: s, end: r } = dn(e), c = { id: X(), parent: i, start: s, end: r, label: "summary", style: t.style }, l = dt(this, c);
  n.push(c), this.editSummary(l), o.fire("operation", {
    name: "createSummary",
    obj: c
  });
}, mn = function(t) {
  const e = X(), n = { ...t, id: e };
  dt(this, n), this.summaries.push(n), this.bus.fire("operation", {
    name: "createSummary",
    obj: n
  });
}, yn = function(t) {
  Wt(this, t) && this.bus.fire("operation", {
    name: "removeSummary",
    obj: { id: t }
  });
}, bn = function(t) {
  const e = t.labelEl;
  e && e.classList.add("selected"), this.currentSummary = t, this.bus.fire("selectSummary", t.summaryObj);
}, vn = function() {
  this.currentSummary?.labelEl?.classList.remove("selected"), this.currentSummary = null, this.bus.fire("unselectSummary");
}, wn = function() {
  this.summarySvg.innerHTML = "";
  const t = [];
  this.summaries.forEach((e) => {
    try {
      dt(this, e) === null && t.push(e.id);
    } catch {
    }
  }), t.forEach((e) => Wt(this, e)), this.nodes.insertAdjacentElement("beforeend", this.summarySvg);
}, xn = function(t) {
  t && t.labelEl && Mt(this, t.labelEl, t.summaryObj);
}, Cn = /* @__PURE__ */ Object.freeze(/* @__PURE__ */ Object.defineProperty({
  __proto__: null,
  createSummary: gn,
  createSummaryFrom: mn,
  editSummary: xn,
  removeSummary: yn,
  renderSummary: wn,
  selectSummary: bn,
  unselectSummary: vn
}, Symbol.toStringTag, { value: "Module" })), $ = "http://www.w3.org/2000/svg";
function En(t, e) {
  const n = document.createElementNS($, "svg");
  return L(n, {
    version: "1.1",
    xmlns: $,
    height: t,
    width: e
  }), n;
}
function Sn(t, e) {
  return (parseInt(t) - parseInt(e)) / 2;
}
function Tn(t, e, n, o) {
  const i = document.createElementNS($, "g");
  let s = "";
  return t.text ? s = t.text.textContent : s = t.childNodes[0].textContent, s.split(`
`).forEach((c, l) => {
    const d = document.createElementNS($, "text");
    L(d, {
      x: n + parseInt(e.paddingLeft) + "",
      y: o + parseInt(e.paddingTop) + Sn(e.lineHeight, e.fontSize) * (l + 1) + parseFloat(e.fontSize) * (l + 1) + "",
      "text-anchor": "start",
      "font-family": e.fontFamily,
      "font-size": `${e.fontSize}`,
      "font-weight": `${e.fontWeight}`,
      fill: `${e.color}`
    }), d.innerHTML = c, i.appendChild(d);
  }), i;
}
function Dn(t, e, n, o) {
  let i = "";
  t.nodeObj?.dangerouslySetInnerHTML ? i = t.nodeObj.dangerouslySetInnerHTML : t.text ? i = t.text.textContent : i = t.childNodes[0].textContent;
  const s = document.createElementNS($, "foreignObject");
  L(s, {
    x: n + parseInt(e.paddingLeft) + "",
    y: o + parseInt(e.paddingTop) + "",
    width: e.width,
    height: e.height
  });
  const r = document.createElement("div");
  return L(r, {
    xmlns: "http://www.w3.org/1999/xhtml",
    style: `font-family: ${e.fontFamily}; font-size: ${e.fontSize}; font-weight: ${e.fontWeight}; color: ${e.color}; white-space: pre-wrap;`
  }), r.innerHTML = i, s.appendChild(r), s;
}
function Mn(t, e) {
  const n = getComputedStyle(e), { offsetLeft: o, offsetTop: i } = H(t.nodes, e), s = document.createElementNS($, "rect");
  return L(s, {
    x: o + "",
    y: i + "",
    rx: n.borderRadius,
    ry: n.borderRadius,
    width: n.width,
    height: n.height,
    fill: n.backgroundColor,
    stroke: n.borderColor,
    "stroke-width": n.borderWidth
  }), s;
}
function j(t, e, n = !1) {
  const o = getComputedStyle(e), { offsetLeft: i, offsetTop: s } = H(t.nodes, e), r = document.createElementNS($, "rect");
  L(r, {
    x: i + "",
    y: s + "",
    rx: o.borderRadius,
    ry: o.borderRadius,
    width: o.width,
    height: o.height,
    fill: o.backgroundColor,
    stroke: o.borderColor,
    "stroke-width": o.borderWidth
  });
  const c = document.createElementNS($, "g");
  c.appendChild(r);
  let l;
  return n ? l = Dn(e, o, i, s) : l = Tn(e, o, i, s), c.appendChild(l), c;
}
function Ln(t, e) {
  const n = getComputedStyle(e), { offsetLeft: o, offsetTop: i } = H(t.nodes, e), s = document.createElementNS($, "a"), r = document.createElementNS($, "text");
  return L(r, {
    x: o + "",
    y: i + parseInt(n.fontSize) + "",
    "text-anchor": "start",
    "font-family": n.fontFamily,
    "font-size": `${n.fontSize}`,
    "font-weight": `${n.fontWeight}`,
    fill: `${n.color}`
  }), r.innerHTML = e.textContent, s.appendChild(r), s.setAttribute("href", e.href), s;
}
function Pn(t, e) {
  const n = getComputedStyle(e), { offsetLeft: o, offsetTop: i } = H(t.nodes, e), s = document.createElementNS($, "image");
  return L(s, {
    x: o + "",
    y: i + "",
    width: n.width + "",
    height: n.height + "",
    href: e.src
  }), s;
}
const _ = 100, $n = '<?xml version="1.0" standalone="no"?><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">', Nn = (t, e = !1) => {
  const n = t.nodes, o = n.offsetHeight + _ * 2, i = n.offsetWidth + _ * 2, s = En(o + "px", i + "px"), r = document.createElementNS($, "svg"), c = document.createElementNS($, "rect");
  L(c, {
    x: "0",
    y: "0",
    width: `${i}`,
    height: `${o}`,
    fill: t.theme.cssVar["--bgcolor"]
  }), s.appendChild(c), n.querySelectorAll(".subLines").forEach((a) => {
    const u = a.cloneNode(!0), { offsetLeft: g, offsetTop: p } = H(n, a.parentElement);
    u.setAttribute("x", `${g}`), u.setAttribute("y", `${p}`), r.appendChild(u);
  });
  const l = n.querySelector(".lines")?.cloneNode(!0);
  l && r.appendChild(l);
  const d = n.querySelector(".topiclinks")?.cloneNode(!0);
  d && r.appendChild(d);
  const f = n.querySelector(".summary")?.cloneNode(!0);
  return f && r.appendChild(f), n.querySelectorAll("me-tpc").forEach((a) => {
    a.nodeObj.dangerouslySetInnerHTML ? r.appendChild(j(t, a, !e)) : (r.appendChild(Mn(t, a)), r.appendChild(j(t, a.text, !e)));
  }), n.querySelectorAll(".tags > span").forEach((a) => {
    r.appendChild(j(t, a));
  }), n.querySelectorAll(".icons > span").forEach((a) => {
    r.appendChild(j(t, a));
  }), n.querySelectorAll(".hyper-link").forEach((a) => {
    r.appendChild(Ln(t, a));
  }), n.querySelectorAll("img").forEach((a) => {
    r.appendChild(Pn(t, a));
  }), L(r, {
    x: _ + "",
    y: _ + "",
    overflow: "visible"
  }), s.appendChild(r), s;
}, kn = (t, e) => (e && t.insertAdjacentHTML("afterbegin", "<style>" + e + "</style>"), $n + t.outerHTML);
function An(t) {
  return new Promise((e, n) => {
    const o = new FileReader();
    o.onload = (i) => {
      e(i.target.result);
    }, o.onerror = (i) => {
      n(i);
    }, o.readAsDataURL(t);
  });
}
const Hn = function(t = !1, e) {
  const n = Nn(this, t), o = kn(n, e);
  return new Blob([o], { type: "image/svg+xml" });
}, On = async function(t = !1, e) {
  const n = this.exportSvg(t, e), o = await An(n);
  return new Promise((i, s) => {
    const r = new Image();
    r.setAttribute("crossOrigin", "anonymous"), r.onload = () => {
      const c = document.createElement("canvas");
      c.width = r.width, c.height = r.height, c.getContext("2d").drawImage(r, 0, 0), c.toBlob(i, "image/png", 1);
    }, r.src = o, r.onerror = s;
  });
}, In = /* @__PURE__ */ Object.freeze(/* @__PURE__ */ Object.defineProperty({
  __proto__: null,
  exportPng: On,
  exportSvg: Hn
}, Symbol.toStringTag, { value: "Module" })), Wn = {}, Bn = {
  getObjById: U,
  generateNewObj: Yt,
  layout: jt,
  linkDiv: Ie,
  editTopic: Qt,
  createWrapper: Ut,
  createParent: Kt,
  createChildren: Jt,
  createTopic: Zt,
  findEle: Ct,
  changeTheme: qe,
  changeCompact: Ue,
  ...De,
  ...Wn,
  ...hn,
  ...Cn,
  ...In,
  init(t) {
    if (t = JSON.parse(JSON.stringify(t)), !t || !t.nodeData) return new Error("MindElixir: `data` is required");
    t.direction !== void 0 && (this.direction = t.direction), t.compact !== void 0 && (this.compact = t.compact), this.changeTheme(t.theme || this.theme, !1), t.meta && (this.meta = t.meta), this.nodeData = t.nodeData, ct(this.nodeData), this.arrows = t.arrows || [], this.summaries = t.summaries || [], this.tidyArrow(), this.toolBar && _e(this), this.layout(), this.linkDiv(), this.toCenter();
  },
  destroy() {
    this.disposable.forEach((t) => t()), this.el && (this.el.innerHTML = ""), this.el = void 0, this.nodeData = void 0, this.arrows = void 0, this.summaries = void 0, this.currentArrow = void 0, this.currentNodes = void 0, this.currentSummary = void 0, this.theme = void 0, this.direction = void 0, this.bus = void 0, this.container = void 0, this.map = void 0, this.lines = void 0, this.linkController = void 0, this.arrowSvg = void 0, this.P2 = void 0, this.P3 = void 0, this.line1 = void 0, this.line2 = void 0, this.nodes = void 0, this.selection?.destroy(), this.selection = void 0;
  },
  /**
   * @public
   * @param {boolean} enable
   */
  enableMobileMultiSelect(t) {
    this.mobileMultiSelect = t;
  }
}, Yn = "5.15.1";
function Rn(t) {
  return {
    x: 0,
    y: 0,
    moved: !1,
    // differentiate click and move
    mousedown: !1,
    handlePointerDown(e) {
      this.moved = !1;
      const n = e.target, o = t.mouseSelectionButton === 0 ? 2 : 0, i = t.spacePressed && e.button === 0 && e.pointerType === "mouse", s = !t.editable || e.button === o && e.pointerType === "mouse" || e.pointerType === "touch";
      !i && !s || (this.x = e.clientX, this.y = e.clientY, n.className !== "circle" && n.contentEditable !== "plaintext-only" && (this.mousedown = !0, n.setPointerCapture(e.pointerId)));
    },
    handlePointerMove(e) {
      if (!this.mousedown || e.target.contentEditable === "plaintext-only" && !t.spacePressed) return !1;
      const n = e.clientX - this.x, o = e.clientY - this.y;
      return this.x = e.clientX, this.y = e.clientY, this.moved = !0, t.move(n, o), !0;
    },
    handlePointerUp(e) {
      if (!this.mousedown) return;
      const n = e.target;
      n.hasPointerCapture && n.hasPointerCapture(e.pointerId) && n.releasePointerCapture(e.pointerId), this.mousedown = !1;
    },
    clear() {
      this.mousedown = !1, this.moved = !1;
    }
  };
}
class Xn {
  static LEFT = 0;
  static RIGHT = 1;
  static SIDE = 2;
  static DOWN = 3;
  static THEME = ot;
  static DARK_THEME = st;
  /**
   * @memberof MindElixir
   * @static
   */
  static version = Yn;
  /**
   * @function
   * @memberof MindElixir
   * @static
   * @name E
   * @param {string} id Node id.
   * @return {TargetElement} Target element.
   * @example
   * E('bd4313fbac40284b')
   */
  static E = Ct;
  /**
   * @function new
   * @memberof MindElixir
   * @static
   * @param {String} topic root topic
   */
  static new = (e) => ({
    nodeData: {
      id: X(),
      topic: e || "new topic",
      children: []
    }
  });
  // #endregion GENERATED
  get currentNode() {
    return this.currentNodes[this.currentNodes.length - 1];
  }
  constructor({
    el: e,
    direction: n,
    editable: o,
    contextMenu: i,
    toolBar: s,
    keypress: r,
    mouseSelectionButton: c,
    selectionContainer: l,
    before: d,
    newTopicName: f,
    allowUndo: a,
    generateMainBranch: u,
    generateSubBranch: g,
    overflowHidden: p,
    compact: b,
    theme: y,
    alignment: w,
    scaleSensitivity: v,
    scaleMax: C,
    scaleMin: S,
    handleWheel: M,
    markdown: h,
    imageProxy: m,
    pasteHandler: x,
    mobileMultiSelect: E
  }) {
    let D = null;
    const P = Object.prototype.toString.call(e);
    if (P === "[object HTMLDivElement]" ? D = e : P === "[object String]" && (D = document.querySelector(e)), !D) throw new Error("MindElixir: el is not a valid element");
    D.style.position = "relative", D.innerHTML = "", this.el = D, this.disposable = [], this.before = d || {}, this.newTopicName = f || "New Node", this.contextMenu = i ?? !0, this.toolBar = s ?? !0, this.keypress = r ?? !0, this.mouseSelectionButton = c ?? 0, this.direction = n ?? 1, this.editable = o ?? !0, this.allowUndo = a ?? !0, this.scaleSensitivity = v ?? 0.1, this.scaleMax = C ?? 1.4, this.scaleMin = S ?? 0.2, this.generateMainBranch = u || $t, this.generateSubBranch = g || Nt, this.overflowHidden = p ?? !1, this.compact = b ?? !1, this.alignment = w ?? "root", this.handleWheel = M ?? !0, this.markdown = h || void 0, this.imageProxy = m || void 0, this.currentNodes = [], this.currentArrow = null, this.scaleVal = 1, this.tempDirection = null, this.mobileMultiSelect = E ?? !1, this.panHelper = Rn(this), this.bus = He(), this.container = document.createElement("div"), this.selectionContainer = l || this.container, this.container.className = "map-container";
    const T = window.matchMedia("(prefers-color-scheme: dark)");
    this.theme = y || (T.matches ? st : ot);
    const N = document.createElement("div");
    N.className = "map-canvas", this.map = N, this.container.setAttribute("tabindex", "0"), this.container.appendChild(this.map), this.el.appendChild(this.container), this.nodes = document.createElement("me-nodes"), this.lines = V("lines"), this.summarySvg = V("summary"), this.linkController = V("linkcontroller"), this.P2 = document.createElement("div"), this.P3 = document.createElement("div"), this.P2.className = this.P3.className = "circle", this.P2.style.display = this.P3.style.display = "none", this.line1 = mt(), this.line2 = mt(), this.linkController.appendChild(this.line1), this.linkController.appendChild(this.line2), this.arrowSvg = V("topiclinks"), this.labelContainer = document.createElement("div"), this.labelContainer.className = "label-container", this.map.appendChild(this.nodes), this.overflowHidden ? this.container.style.overflow = "hidden" : this.disposable.push(Ae(this)), x && (this.pasteHandler = x);
  }
}
Object.assign(Xn.prototype, Bn);
export {
  st as DARK_THEME,
  Gn as DOWN,
  Vn as LEFT,
  zn as RIGHT,
  Fn as SIDE,
  ot as THEME,
  Xn as default
};
