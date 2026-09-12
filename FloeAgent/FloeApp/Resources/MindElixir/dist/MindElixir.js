const ss = 0, is = 1, rs = 2, ls = 3, me = {
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
}, ye = {
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
function be(e) {
  return e.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");
}
const ce = function(e, t) {
  if (t.id === e)
    return t;
  if (t.children && t.children.length) {
    for (let n = 0; n < t.children.length; n++) {
      const o = ce(e, t.children[n]);
      if (o) return o;
    }
    return null;
  } else
    return null;
}, Y = (e, t) => {
  if (e.parent = t, e.children)
    for (let n = 0; n < e.children.length; n++)
      Y(e.children[n], e);
}, z = (e, t, n) => {
  if (e.expanded = t, e.children)
    if (n === void 0 || n > 0) {
      const o = n !== void 0 ? n - 1 : void 0;
      e.children.forEach((s) => {
        z(s, t, o);
      });
    } else
      e.children.forEach((o) => {
        z(o, !1);
      });
};
function we(e) {
  if (e.id = X(), e.children)
    for (let t = 0; t < e.children.length; t++)
      we(e.children[t]);
}
function ae(e, t, n, o) {
  const s = n - e, i = o - t, l = Math.atan2(i, s) * 180 / Math.PI, a = 12, c = 30, h = (l + 180 - c) * Math.PI / 180, d = (l + 180 + c) * Math.PI / 180;
  return {
    x1: n + Math.cos(h) * a,
    y1: o + Math.sin(h) * a,
    x2: n + Math.cos(d) * a,
    y2: o + Math.sin(d) * a
  };
}
function X() {
  return ((/* @__PURE__ */ new Date()).getTime().toString(16) + Math.random().toString(16).substring(2)).substring(2, 18);
}
const Et = function() {
  const e = X();
  return {
    topic: this.newTopicName,
    id: e
  };
};
function G(e) {
  return JSON.parse(
    JSON.stringify(e, (n, o) => {
      if (n !== "parent")
        return o;
    })
  );
}
const $ = (e, t) => {
  let n = 0, o = 0;
  for (; t && t !== e; )
    n += t.offsetLeft, o += t.offsetTop, t = t.offsetParent;
  return { offsetLeft: n, offsetTop: o };
}, _ = (e, t) => {
  for (const n in t)
    e.setAttribute(n, t[n]);
}, re = (e) => e ? e.tagName === "ME-TPC" : !1, Ee = (e) => {
  const t = new Set(e.map((n) => n.nodeObj));
  return e.filter((n) => n.nodeObj.parent).filter((n) => {
    let o = n.nodeObj.parent;
    for (; o; ) {
      if (t.has(o)) return !1;
      o = o.parent;
    }
    return !0;
  });
}, Ce = (e) => {
  const t = /translate3d\(([^,]+),\s*([^,]+)/, n = e.match(t);
  return n ? { x: parseFloat(n[1]), y: parseFloat(n[2]) } : { x: 0, y: 0 };
}, Ge = function(e) {
  for (let t = 0; t < e.length; t++) {
    const { dom: n, evt: o, func: s } = e[t];
    n.addEventListener(o, s);
  }
  return function() {
    for (let n = 0; n < e.length; n++) {
      const { dom: o, evt: s, func: i } = e[n];
      o.removeEventListener(s, i);
    }
  };
}, ke = (e, t) => {
  const n = e.x - t.x, o = e.y - t.y;
  return Math.sqrt(n * n + o * o);
}, Ae = function(e, t) {
  if (!t)
    return de(e), e;
  let n = e.querySelector(".insert-preview");
  const o = `insert-preview ${t} show`;
  return n || (n = document.createElement("div"), e.appendChild(n)), n.className = o, e;
}, de = function(e) {
  if (!e) return;
  const t = e.querySelectorAll(".insert-preview");
  for (const n of t || [])
    n.remove();
}, te = function(e, t) {
  for (const n of t) {
    const o = n.parentElement.parentElement.contains(e);
    if (!(e && e.tagName === "ME-TPC" && e !== n && !o && e.nodeObj.parent)) return !1;
  }
  return !0;
}, Ct = function(e) {
  const t = document.createElement("div");
  return t.className = "mind-elixir-ghost", e.container.appendChild(t), t;
};
class St {
  mind;
  isMoving = !1;
  interval = null;
  speed = 20;
  constructor(t) {
    this.mind = t;
  }
  move(t, n) {
    this.isMoving || (this.isMoving = !0, this.interval = setInterval(() => {
      this.mind.move(t * this.speed * this.mind.scaleVal, n * this.speed * this.mind.scaleVal);
    }, 100));
  }
  stop() {
    this.isMoving = !1, this.interval && (clearInterval(this.interval), this.interval = null);
  }
}
function Nt(e) {
  return {
    isDragging: !1,
    insertType: null,
    meet: null,
    ghost: Ct(e),
    edgeMoveController: new St(e),
    startX: 0,
    startY: 0,
    pointerId: null
  };
}
const Tt = 5;
function Pe(e, t, n, o = !1) {
  if (e.spacePressed) return !1;
  const s = n.target;
  if (s?.tagName !== "ME-TPC" || !s.nodeObj.parent) return !1;
  if (t.startX = n.clientX, t.startY = n.clientY, t.pointerId = n.pointerId, e.dragged = e.currentNodes, o) {
    Ue(e, t);
    const i = e.container.getBoundingClientRect();
    qe(t.ghost, n.clientX - i.x, n.clientY - i.y);
  }
  return !0;
}
function qe(e, t, n) {
  e.style.transform = `translate(${t - 10}px, ${n - 10}px)`, e.style.display = "block";
}
function Ue(e, t) {
  const { dragged: n } = e;
  if (!n) return;
  const o = document.activeElement;
  o && o.isContentEditable && o.blur(), t.isDragging = !0, n.length > 1 ? t.ghost.innerHTML = n.length + "" : t.ghost.innerHTML = n[0].innerHTML;
  for (const s of n)
    s.parentElement.parentElement.style.opacity = "0.5";
  e.panHelper.clear();
}
function Dt(e, t, n) {
  const { dragged: o } = e;
  if (!o || t.pointerId !== n.pointerId) return;
  const s = n.clientX - t.startX, i = n.clientY - t.startY, r = Math.sqrt(s * s + i * i);
  if (!t.isDragging && r > Tt && Ue(e, t), !t.isDragging) return;
  const l = e.container.getBoundingClientRect();
  qe(t.ghost, n.clientX - l.x, n.clientY - l.y), n.clientX < l.x + 50 ? t.edgeMoveController.move(1, 0) : n.clientX > l.x + l.width - 50 ? t.edgeMoveController.move(-1, 0) : n.clientY < l.y + 50 ? t.edgeMoveController.move(0, 1) : n.clientY > l.y + l.height - 50 ? t.edgeMoveController.move(0, -1) : t.edgeMoveController.stop(), de(t.meet);
  const a = 12 * e.scaleVal;
  if (e.direction === 3) {
    const h = document.elementFromPoint(n.clientX - a, n.clientY);
    if (te(h, o)) {
      t.meet = h;
      const d = h.getBoundingClientRect();
      n.clientX > d.x + d.width ? t.insertType = "after" : t.insertType = "in";
    } else {
      const d = document.elementFromPoint(n.clientX + a, n.clientY);
      if (te(d, o)) {
        t.meet = d;
        const u = d.getBoundingClientRect();
        n.clientX < u.x ? t.insertType = "before" : t.insertType = "in";
      } else
        t.insertType = null, t.meet = null;
    }
    t.meet && Ae(t.meet, t.insertType);
    return;
  }
  const c = document.elementFromPoint(n.clientX, n.clientY - a);
  if (te(c, o)) {
    t.meet = c;
    const h = c.getBoundingClientRect(), d = h.y;
    n.clientY > d + h.height ? t.insertType = "after" : t.insertType = "in";
  } else {
    const h = document.elementFromPoint(n.clientX, n.clientY + a);
    if (te(h, o)) {
      t.meet = h;
      const u = h.getBoundingClientRect().y;
      n.clientY < u ? t.insertType = "before" : t.insertType = "in";
    } else
      t.insertType = null, t.meet = null;
  }
  t.meet && Ae(t.meet, t.insertType);
}
function Mt(e, t, n) {
  const { dragged: o } = e;
  if (!(!o || t.pointerId !== n.pointerId)) {
    t.edgeMoveController.stop();
    for (const s of o)
      s.parentElement.parentElement.style.opacity = "1";
    t.ghost.style.display = "none", t.ghost.innerHTML = "", t.isDragging && t.meet && (de(t.meet), t.insertType === "before" ? e.moveNodeBefore(o, t.meet) : t.insertType === "after" ? e.moveNodeAfter(o, t.meet) : t.insertType === "in" && e.moveNodeIn(o, t.meet)), e.dragged = null, t.isDragging = !1, t.insertType = null, t.meet = null, t.pointerId = null;
  }
}
function Oe(e, t) {
  const { dragged: n } = e;
  if (n) {
    t.edgeMoveController.stop();
    for (const o of n)
      o.parentElement.parentElement.style.opacity = "1";
    t.meet && de(t.meet), t.ghost.style.display = "none", t.ghost.innerHTML = "", e.dragged = null, t.isDragging = !1, t.insertType = null, t.meet = null, t.pointerId = null;
  }
}
function _t(e) {
  return () => {
  };
}
const L = {
  LHS: "lhs",
  RHS: "rhs",
  DOWN: "down"
}, Lt = function() {
  this.nodes.innerHTML = "", this.nodes.className = this.direction === 3 ? "down" : "";
  const e = this.createTopic(this.nodeData);
  Se.call(this, e, this.nodeData), e.draggable = !1;
  const t = document.createElement("me-root");
  t.appendChild(e);
  const n = this.nodeData.children || [];
  if (this.direction === 2) {
    let o = 0, s = 0;
    n.map((i) => {
      i.direction === 0 ? o += 1 : i.direction === 1 ? s += 1 : o <= s ? (i.direction = 0, o += 1) : (i.direction = 1, s += 1);
    });
  }
  kt(this, n, t);
}, kt = function(e, t, n) {
  if (e.direction === 3) {
    const i = document.createElement("me-main");
    i.className = L.DOWN;
    for (let r = 0; r < t.length; r++) {
      const { grp: l } = e.createWrapper(t[r]);
      i.appendChild(l);
    }
    e.nodes.appendChild(n), e.nodes.appendChild(i), e.nodes.appendChild(e.lines), e.nodes.appendChild(e.labelContainer);
    return;
  }
  const o = document.createElement("me-main");
  o.className = L.LHS;
  const s = document.createElement("me-main");
  s.className = L.RHS;
  for (let i = 0; i < t.length; i++) {
    const r = t[i], { grp: l } = e.createWrapper(r);
    e.direction === 2 ? r.direction === 0 ? o.appendChild(l) : s.appendChild(l) : e.direction === 0 ? o.appendChild(l) : s.appendChild(l);
  }
  e.nodes.appendChild(o), e.nodes.appendChild(n), e.nodes.appendChild(s), e.nodes.appendChild(e.lines), e.nodes.appendChild(e.labelContainer);
}, At = function(e, t) {
  const n = document.createElement("me-children");
  for (let o = 0; o < t.length; o++) {
    const s = t[o], { grp: i } = e.createWrapper(s);
    n.appendChild(i);
  }
  return n;
}, Je = function(e, t) {
  const o = (this?.el ? this.el : t || document).querySelector(`[data-nodeid="me${e}"]`);
  if (!o) throw new Error(`FindEle: Node ${e} not found, maybe it's collapsed.`);
  return o;
}, Se = function(e, t) {
  if (e.innerHTML = "", t.style) {
    const n = t.style;
    for (const o in n)
      e.style[o] = n[o];
  }
  if (t.dangerouslySetInnerHTML) {
    e.innerHTML = t.dangerouslySetInnerHTML;
    return;
  }
  if (t.image) {
    const n = t.image;
    if (n.url && n.width && n.height) {
      const o = document.createElement("img");
      o.src = this.imageProxy ? this.imageProxy(n.url) : n.url, o.style.width = n.width + "px", o.style.height = n.height + "px", n.fit && (o.style.objectFit = n.fit), e.appendChild(o), e.image = o;
    }
  } else e.image && (e.image = void 0);
  {
    const n = document.createElement("span");
    n.className = "text", this.markdown ? n.innerHTML = this.markdown(t.topic, t) : n.textContent = t.topic, e.appendChild(n), e.text = n;
  }
  if (t.hyperLink) {
    const n = document.createElement("a");
    n.className = "hyper-link", n.target = "_blank", n.innerText = "🔗", n.href = t.hyperLink, e.appendChild(n), e.link = n;
  } else e.link && (e.link = void 0);
  if (t.icons && t.icons.length) {
    const n = document.createElement("span");
    n.className = "icons", n.innerHTML = t.icons.map((o) => `<span>${be(o)}</span>`).join(""), e.appendChild(n), e.icons = n;
  } else e.icons && (e.icons = void 0);
  if (t.tags && t.tags.length) {
    const n = document.createElement("div");
    n.className = "tags", t.tags.forEach((o) => {
      const s = document.createElement("span");
      typeof o == "string" ? s.textContent = o : (s.textContent = o.text, o.className && (s.className = o.className), o.style && Object.assign(s.style, o.style)), n.appendChild(s);
    }), e.appendChild(n), e.tags = n;
  } else e.tags && (e.tags = void 0);
}, Pt = function(e, t) {
  const n = document.createElement("me-wrapper"), { p: o, tpc: s } = this.createParent(e);
  if (n.appendChild(o), !t && e.children && e.children.length > 0) {
    const i = Ne(e.expanded);
    if (o.appendChild(i), e.expanded !== !1) {
      const r = At(this, e.children);
      n.appendChild(r);
    }
  }
  return { grp: n, top: o, tpc: s };
}, Ot = function(e) {
  const t = document.createElement("me-parent"), n = this.createTopic(e);
  return Se.call(this, n, e), t.appendChild(n), { p: t, tpc: n };
}, $t = function(e) {
  const t = document.createElement("me-children");
  return t.append(...e), t;
}, Ht = function(e) {
  const t = document.createElement("me-tpc");
  return t.nodeObj = e, t.dataset.nodeid = "me" + e.id, t;
};
function Ze(e) {
  const t = document.createRange();
  t.selectNodeContents(e);
  const n = window.getSelection();
  n && (n.removeAllRanges(), n.addRange(t));
}
const It = function(e) {
  if (!e) return;
  const t = document.createElement("div"), n = e.nodeObj, o = n.topic, { offsetLeft: s, offsetTop: i } = $(this.nodes, e);
  this.nodes.appendChild(t), t.id = "input-box", t.textContent = o, t.contentEditable = "plaintext-only", t.spellcheck = !1;
  const r = getComputedStyle(e);
  t.style.cssText = `
  left: ${s}px;
  top: ${i}px;
  min-width:${e.offsetWidth - 8}px;
  color:${r.color};
  font-size:${r.fontSize};
  padding:${r.padding};
  margin:${r.margin}; 
  background-color:${r.backgroundColor !== "rgba(0, 0, 0, 0)" && r.backgroundColor};
  border: ${r.border};
  border-radius:${r.borderRadius}; `, this.direction === 0 && (t.style.right = "0"), e.style.opacity = "0", Ze(t), this.bus.fire("operation", {
    name: "beginEdit",
    obj: e.nodeObj
  }), t.addEventListener("keydown", (l) => {
    if (l.stopPropagation(), l.isComposing) return;
    const a = l.key;
    if (a === "Enter" || a === "Tab") {
      if (l.shiftKey) return;
      l.preventDefault(), t.blur(), this.container.focus();
    } else a === "Escape" && (l.preventDefault(), t.textContent = o, t.blur(), this.container.focus());
  }), t.addEventListener("blur", () => {
    if (!t) return;
    e.style.opacity = "1";
    const l = t.innerText?.trim() || "";
    t.remove(), !(l === o || l === "") && (n.topic = l, this.markdown ? e.text.innerHTML = this.markdown(n.topic, n) : e.text.textContent = l, this.linkDiv(), this.bus.fire("operation", {
      name: "finishEdit",
      obj: n,
      origin: o
    }));
  });
}, Ne = function(e) {
  const t = document.createElement("me-epd");
  return t.expanded = e !== !1, t.className = e !== !1 ? "minus" : "", t;
}, he = (e) => {
  const t = e.parent?.children, n = t?.indexOf(e) ?? 0;
  return { siblings: t, index: n };
};
function Qe(e) {
  const { siblings: t, index: n } = he(e);
  return t === void 0 ? 0 : (t.splice(n, 1), t.length);
}
function jt(e, t, n) {
  const { siblings: o, index: s } = he(n);
  o !== void 0 && (t === "before" ? o.splice(s, 0, e) : o.splice(s + 1, 0, e));
}
function Rt(e, t) {
  const { siblings: n, index: o } = he(e);
  n !== void 0 && (n[o] = t, t.children = [e]);
}
function Bt(e, t, n) {
  if (Qe(t), n.parent?.parent || (t.direction = n.direction), e === "in")
    n.children ? n.children.push(t) : n.children = [t];
  else {
    t.direction !== void 0 && (t.direction = n.direction);
    const { siblings: o, index: s } = he(n);
    if (o === void 0) return;
    e === "before" ? o.splice(s, 0, t) : o.splice(s + 1, 0, t);
  }
}
const Wt = function({ map: e, direction: t }, n) {
  if (t === 0)
    return 0;
  if (t === 1)
    return 1;
  if (t === 3)
    return 3;
  if (t === 2) {
    const o = e.querySelector(".lhs")?.childElementCount || 0, s = e.querySelector(".rhs")?.childElementCount || 0;
    return o <= s ? (n.direction = 0, 0) : (n.direction = 1, 1);
  }
}, et = function(e, t, n) {
  const o = n.children[0].children[0], s = t.parentElement;
  if (s.tagName === "ME-PARENT") {
    if (J(o), s.children[1])
      s.nextSibling.appendChild(n);
    else {
      const i = e.createChildren([n]);
      s.appendChild(Ne(!0)), s.insertAdjacentElement("afterend", i);
    }
    e.linkDiv(n.offsetParent);
  } else if (s.tagName === "ME-ROOT") {
    const i = Wt(e, o.nodeObj);
    i === 3 ? e.container.querySelector("me-main.down")?.appendChild(n) : i === 0 ? e.container.querySelector(".lhs")?.appendChild(n) : e.container.querySelector(".rhs")?.appendChild(n), e.linkDiv();
  }
}, Yt = function(e, t) {
  const n = e.parentNode;
  if (t === 0) {
    const o = n.parentNode.parentNode;
    o.tagName !== "ME-MAIN" && (o.previousSibling.children[1].remove(), o.remove());
  }
  n.parentNode.remove();
}, tt = {
  before: "beforebegin",
  after: "afterend"
}, J = function(e) {
  const n = e.parentElement.parentElement.lastElementChild;
  n?.tagName === "svg" && n?.remove();
}, Xt = function(e, t) {
  const n = e.nodeObj, o = G(n);
  o.style && t.style && (t.style = Object.assign(o.style, t.style));
  const s = Object.assign(n, t);
  Se.call(this, e, s), this.linkDiv(), this.bus.fire("operation", {
    name: "reshapeNode",
    obj: s,
    origin: o
  });
}, Te = function(e, t, n) {
  if (!t) return null;
  const o = t.nodeObj;
  o.expanded === !1 && (e.expandNode(t, !0), t = e.findEle(o.id));
  const s = n || e.generateNewObj();
  o.children ? o.children.push(s) : o.children = [s], Y(e.nodeData);
  const { grp: i, top: r } = e.createWrapper(s);
  return et(e, t, i), { newTop: r, newNodeObj: s };
}, Ft = function(e, t, n) {
  const o = t || this.currentNode;
  if (!o) return;
  const s = o.nodeObj;
  if (s.parent) {
    if (!s.parent?.parent && this.direction === 2) {
      const c = this.map.querySelector(".lhs")?.childElementCount || 0, h = this.map.querySelector(".rhs")?.childElementCount || 0;
      if (!c || !h) {
        this.addChild(this.findEle(s.parent.id), n);
        return;
      }
    }
  } else {
    this.addChild();
    return;
  }
  const i = n || this.generateNewObj();
  if (!s.parent?.parent) {
    const c = o.closest("me-main").className === L.LHS ? 0 : 1;
    i.direction = c;
  }
  jt(i, e, s), Y(this.nodeData);
  const r = o.parentElement, { grp: l, top: a } = this.createWrapper(i);
  r.parentElement.insertAdjacentElement(tt[e], l), this.linkDiv(l.offsetParent), n || this.editTopic(a.firstChild), this.bus.fire("operation", {
    name: "insertSibling",
    type: e,
    obj: i
  }), this.selectNode(a.firstChild, !0);
}, Kt = function(e, t) {
  const n = e || this.currentNode;
  if (!n) return;
  J(n);
  const o = n.nodeObj;
  if (!o.parent)
    return;
  const s = t || this.generateNewObj();
  if (!o.parent?.parent) {
    const c = n.closest("me-main").className === L.LHS ? 0 : 1;
    s.direction = c;
  }
  Rt(o, s), Y(this.nodeData);
  const i = n.parentElement.parentElement, { grp: r, top: l } = this.createWrapper(s, !0);
  l.appendChild(Ne(!0)), i.insertAdjacentElement("afterend", r);
  const a = this.createChildren([i]);
  l.insertAdjacentElement("afterend", a), this.linkDiv(), t || this.editTopic(l.firstChild), this.bus.fire("operation", {
    name: "insertParent",
    obj: s
  }), this.selectNode(l.firstChild, !0);
}, Vt = function(e, t) {
  const n = e || this.currentNode;
  if (!n) return;
  const o = Te(this, n, t);
  if (!o) return;
  const { newTop: s, newNodeObj: i } = o;
  this.bus.fire("operation", {
    name: "addChild",
    obj: i
  }), t || this.editTopic(s.firstChild), this.selectNode(s.firstChild, !0);
}, zt = function(e, t) {
  const n = G(e.nodeObj);
  we(n);
  const o = Te(this, t, n);
  if (!o) return;
  const { newNodeObj: s } = o;
  this.bus.fire("operation", {
    name: "copyNode",
    obj: s
  }), this.selectNode(this.findEle(s.id));
}, Gt = function(e, t) {
  const n = [];
  for (let o = 0; o < e.length; o++) {
    const s = e[o], i = G(s.nodeObj);
    we(i);
    const r = Te(this, t, i);
    if (!r) return;
    const { newNodeObj: l } = r;
    n.push(l);
  }
  this.bus.fire("operation", {
    name: "copyNodes",
    objs: n
  }), this.unselectNodes(this.currentNodes), this.selectNodes(n.map((o) => this.findEle(o.id)));
}, nt = function(e, t, n) {
  const o = t.parent?.children;
  if (o === void 0) return;
  const s = e.direction === 2 && !t.parent?.parent, i = (a) => !s || a.direction === t.direction;
  let r, l = !1;
  for (const a of o)
    if (i(a)) {
      if (a === t) {
        if (n === -1) return r ? { to: r, type: "before" } : void 0;
        l = !0;
        continue;
      }
      if (l) return { to: a, type: "after" };
      r = a;
    }
}, qt = function(e) {
  const t = e || this.currentNode;
  if (!t) return;
  const n = t.nodeObj;
  if (!n.parent) return;
  const o = nt(this, n, -1);
  o && Z([t], o.type, this.findEle(o.to.id), this);
}, Ut = function(e) {
  const t = e || this.currentNode;
  if (!t) return;
  const n = t.nodeObj;
  if (!n.parent) return;
  const o = nt(this, n, 1);
  o && Z([t], o.type, this.findEle(o.to.id), this);
}, Jt = function(e) {
  if (e = Ee(e), e.length === 0) return;
  for (const n of e) {
    const o = n.nodeObj, s = Qe(o);
    Yt(n, s);
  }
  const t = e[e.length - 1];
  this.selectNode(this.findEle(t.nodeObj.parent.id)), this.linkDiv(), this.bus.fire("operation", {
    name: "removeNodes",
    objs: e.map((n) => n.nodeObj)
  });
}, Z = (e, t, n, o) => {
  e = Ee(e);
  let s = n.nodeObj;
  t === "in" && s.expanded === !1 && (o.expandNode(n, !0), n = o.findEle(s.id), s = n.nodeObj), t === "after" && (e = e.reverse());
  const i = /* @__PURE__ */ new Set();
  for (const l of e) {
    const a = l.nodeObj;
    if (Bt(t, a, s), Y(o.nodeData), t === "in") {
      const h = l.parentElement.parentElement, d = h.parentElement;
      et(o, n, h), i.add(d);
    } else {
      J(l);
      const c = l.parentElement.parentNode;
      i.add(c.parentElement), n.parentElement.parentNode.insertAdjacentElement(tt[t], c);
    }
  }
  for (const l of i)
    l.childElementCount === 0 && l.tagName !== "ME-MAIN" && (l.previousSibling.children[1].remove(), l.remove());
  o.linkDiv(), o.scrollIntoView(e[e.length - 1]);
  const r = t === "before" ? "moveNodeBefore" : t === "after" ? "moveNodeAfter" : "moveNodeIn";
  o.bus.fire("operation", {
    name: r,
    objs: e.map((l) => l.nodeObj),
    toObj: s
  });
}, Zt = function(e, t) {
  Z(e, "in", t, this);
}, Qt = function(e, t) {
  Z(e, "before", t, this);
}, en = function(e, t) {
  Z(e, "after", t, this);
}, tn = function(e) {
  const t = e || this.currentNode;
  t && (t.nodeObj.dangerouslySetInnerHTML || this.editTopic(t));
}, nn = function(e, t) {
  e.text.textContent = t, e.nodeObj.topic = t, this.linkDiv();
}, ot = /* @__PURE__ */ Object.freeze(/* @__PURE__ */ Object.defineProperty({
  __proto__: null,
  addChild: Vt,
  beginEdit: tn,
  copyNode: zt,
  copyNodes: Gt,
  insertParent: Kt,
  insertSibling: Ft,
  moveDownNode: Ut,
  moveNodeAfter: en,
  moveNodeBefore: Qt,
  moveNodeIn: Zt,
  moveUpNode: qt,
  removeNodes: Jt,
  reshapeNode: Xt,
  rmSubline: J,
  setNodeTopic: nn
}, Symbol.toStringTag, { value: "Module" }));
function on(e) {
  return {
    nodeData: e.isFocusMode ? e.nodeDataBackup : e.nodeData,
    arrows: e.arrows,
    summaries: e.summaries,
    direction: e.direction,
    theme: e.theme,
    compact: e.compact,
    meta: e.meta
  };
}
const sn = function(e, t = !1) {
  const n = this.container, o = e.getBoundingClientRect(), s = n.getBoundingClientRect();
  if (t || o.top > s.bottom - 50 || o.bottom < s.top + 50 || o.left > s.right - 50 || o.right < s.left + 50) {
    const r = o.left + o.width / 2, l = o.top + o.height / 2, a = s.left + s.width / 2, c = s.top + s.height / 2, h = r - a, d = l - c;
    this.move(-h, -d, !0);
  }
}, rn = function(e, t, n) {
  this.clearSelection(), this.scrollIntoView(e), this.selection?.select(e), t && this.bus.fire("selectNewNode", e.nodeObj);
}, ln = function(e) {
  this.selection?.select(e);
}, cn = function(e) {
  this.selection?.deselect(e);
}, an = function() {
  this.unselectNodes(this.currentNodes), this.unselectSummary(), this.unselectArrow();
}, De = function(e) {
  return JSON.stringify(e, (t, n) => {
    if (!(t === "parent" && typeof n != "string"))
      return n;
  });
}, dn = function() {
  const e = on(this);
  return De(e);
}, hn = function() {
  return JSON.parse(this.getDataString());
}, fn = function() {
  this.editable = !0;
}, un = function() {
  this.editable = !1;
}, pn = function(e, t = { x: 0, y: 0 }) {
  if (e < this.scaleMin && e < this.scaleVal || e > this.scaleMax && e > this.scaleVal) return;
  const n = this.container.getBoundingClientRect(), o = t.x ? t.x - n.left - n.width / 2 : 0, s = t.y ? t.y - n.top - n.height / 2 : 0, { dx: i, dy: r } = Me(this), l = this.map.style.transform, { x: a, y: c } = Ce(l), h = a - i, d = c - r, u = this.scaleVal, p = (-o + h) * (1 - e / u), m = (-s + d) * (1 - e / u);
  this.map.style.transform = `translate3d(${a - p}px, ${c - m}px, 0) scale(${e})`, this.scaleVal = e, this.bus.fire("scale", e);
}, gn = function() {
  const e = this.nodes.offsetHeight / this.container.offsetHeight, t = this.nodes.offsetWidth / this.container.offsetWidth, n = 1 / Math.max(1, Math.max(e, t));
  this.scaleVal = n;
  const { dx: o, dy: s } = Me(this, !0);
  this.map.style.transform = `translate3d(${o}px, ${s}px, 0) scale(${n})`, this.bus.fire("scale", n);
}, mn = function(e, t, n = !1) {
  const { map: o, scaleVal: s, bus: i, container: r, nodes: l } = this;
  if (n && o.style.transition === "transform 0.3s")
    return !1;
  const a = o.style.transform;
  let { x: c, y: h } = Ce(a);
  const d = r.getBoundingClientRect(), u = l.getBoundingClientRect(), p = (d.left + d.right) / 2, m = (d.top + d.bottom) / 2;
  return e > 0 ? e = Math.min(e, Math.max(0, p - u.left)) : e < 0 && (e = Math.max(e, Math.min(0, p - u.right))), t > 0 ? t = Math.min(t, Math.max(0, m - u.top)) : t < 0 && (t = Math.max(t, Math.min(0, m - u.bottom))), e === 0 && t === 0 ? !1 : (c += e, h += t, n && (o.style.transition = "transform 0.3s", setTimeout(() => {
    o.style.transition = "none";
  }, 300)), o.style.transform = `translate3d(${c}px, ${h}px, 0) scale(${s})`, i.fire("move", { dx: e, dy: t }), !0);
}, Me = (e, t = !1) => {
  const { container: n, map: o, nodes: s } = e;
  let i, r;
  if (e.alignment === "nodes" || t || e.direction === 3)
    i = (n.offsetWidth - s.offsetWidth) / 2, r = (n.offsetHeight - s.offsetHeight) / 2, o.style.transformOrigin = "50% 50%";
  else {
    const l = o.querySelector("me-root"), a = l.offsetTop, c = l.offsetLeft, h = l.offsetWidth, d = l.offsetHeight;
    i = n.offsetWidth / 2 - c - h / 2, r = n.offsetHeight / 2 - a - d / 2, o.style.transformOrigin = `${c + h / 2}px 50%`;
  }
  return { dx: i, dy: r };
}, yn = function() {
  const { map: e, container: t } = this, { dx: n, dy: o } = Me(this);
  t.scrollTop = 0, t.scrollLeft = 0, e.style.transform = `translate3d(${n}px, ${o}px, 0) scale(${this.scaleVal})`;
}, bn = function(e) {
  e(this);
}, vn = function(e) {
  e.nodeObj.parent && (this.clearSelection(), this.tempDirection === null && (this.tempDirection = this.direction), this.isFocusMode || (this.nodeDataBackup = this.nodeData, this.isFocusMode = !0), this.nodeData = e.nodeObj, this.initRight(), this.toCenter());
}, xn = function() {
  this.isFocusMode = !1, this.tempDirection !== null && (this.nodeData = this.nodeDataBackup, this.direction = this.tempDirection, this.tempDirection = null, this.refresh(), this.toCenter());
}, wn = function() {
  this.direction = 0, this.refresh(), this.toCenter(), this.bus.fire("changeDirection", this.direction);
}, En = function() {
  this.direction = 1, this.refresh(), this.toCenter(), this.bus.fire("changeDirection", this.direction);
}, Cn = function() {
  this.direction = 2, this.refresh(), this.toCenter(), this.bus.fire("changeDirection", this.direction);
}, Sn = function() {
  this.direction = 3, this.refresh(), this.toCenter(), this.bus.fire("changeDirection", this.direction);
}, Nn = function(e, t) {
  const n = e.nodeObj;
  typeof t == "boolean" ? n.expanded = t : n.expanded !== !1 ? n.expanded = !1 : n.expanded = !0;
  const o = e.getBoundingClientRect(), s = {
    x: o.left,
    y: o.top
  }, i = e.parentNode, r = i.children[1];
  if (r.expanded = n.expanded, r.className = n.expanded ? "minus" : "", J(e), n.expanded) {
    const d = this.createChildren(
      n.children.map((u) => this.createWrapper(u).grp)
    );
    i.parentNode.appendChild(d);
  } else
    i.parentNode.children[1].remove();
  this.linkDiv(e.closest("me-main > me-wrapper"));
  const l = e.getBoundingClientRect(), a = {
    x: l.left,
    y: l.top
  }, c = s.x - a.x, h = s.y - a.y;
  this.move(c, h), this.bus.fire("expandNode", n);
}, Tn = function(e, t) {
  const n = e.nodeObj, o = e.getBoundingClientRect(), s = {
    x: o.left,
    y: o.top
  };
  z(n, t ?? !n.expanded), this.refresh();
  const i = this.findEle(n.id).getBoundingClientRect(), r = {
    x: i.left,
    y: i.top
  }, l = s.x - r.x, a = s.y - r.y;
  this.move(l, a);
}, Dn = function(e) {
  this.clearSelection(), e && (e = JSON.parse(JSON.stringify(e)), this.nodeData = e.nodeData, this.arrows = e.arrows || [], this.summaries = e.summaries || [], e.meta && (this.meta = e.meta)), Y(this.nodeData), this.layout(), this.linkDiv();
}, Mn = /* @__PURE__ */ Object.freeze(/* @__PURE__ */ Object.defineProperty({
  __proto__: null,
  cancelFocus: xn,
  clearSelection: an,
  disableEdit: un,
  enableEdit: fn,
  expandNode: Nn,
  expandNodeAll: Tn,
  focusNode: vn,
  getData: hn,
  getDataString: dn,
  initDown: Sn,
  initLeft: wn,
  initRight: En,
  initSide: Cn,
  install: bn,
  move: mn,
  refresh: Dn,
  scale: pn,
  scaleFit: gn,
  scrollIntoView: sn,
  selectNode: rn,
  selectNodes: ln,
  stringifyData: De,
  toCenter: yn,
  unselectNodes: cn
}, Symbol.toStringTag, { value: "Module" })), $e = "MIND-ELIXIR-WAIT-COPY", _n = 40, Ln = 10, kn = ({ deltaMode: e, deltaY: t, viewportHeight: n }) => e === WheelEvent.DOM_DELTA_LINE ? t * _n : e === WheelEvent.DOM_DELTA_PAGE ? t * n : t, An = ({ deltaMode: e, deltaY: t, scaleSensitivity: n, viewportHeight: o }) => {
  const i = -kn({ deltaMode: e, deltaY: t, viewportHeight: o }) / Ln * n;
  return Math.max(-n, Math.min(n, i));
}, st = (e, t, n) => {
  t !== 0 && e.scale(e.scaleVal + t, n);
}, Pn = (e, t) => {
  const n = e.map.querySelectorAll(`.${t}>me-wrapper>me-parent>me-tpc`);
  n.length !== 0 && e.selectNode(n[Math.ceil(n.length / 2) - 1]);
}, it = (e) => {
  e.selectNode(e.map.querySelector("me-root>me-tpc"));
}, rt = function(e, t) {
  const n = t.parentElement.parentElement.parentElement.previousSibling;
  if (n) {
    const o = n.firstChild;
    e.selectNode(o);
  }
}, lt = function(e, t) {
  const n = t.parentElement.nextSibling;
  if (n && n.firstChild) {
    const o = n.firstChild.firstChild.firstChild;
    e.selectNode(o);
  }
}, He = function(e, t) {
  const n = e.currentNode || e.currentNodes?.[0];
  if (!n) return;
  const o = n.nodeObj, s = n.offsetParent.offsetParent.parentElement;
  o.parent ? s.className === t ? lt(e, n) : o.parent?.parent ? rt(e, n) : it(e) : Pn(e, t);
}, ne = function(e, t) {
  const n = e.currentNode;
  if (!n || !n.nodeObj.parent) return;
  const s = t + "Sibling", i = n.parentElement.parentElement[s];
  i ? e.selectNode(i.firstChild.firstChild) : e.selectNode(n);
}, On = function(e, t) {
  const n = t.nodeObj;
  n.parent && (n.parent.parent ? rt(e, t) : it(e));
}, $n = function(e, t) {
  if (t.nodeObj.parent)
    lt(e, t);
  else {
    const o = e.map.querySelectorAll(".down>me-wrapper>me-parent>me-tpc");
    if (o.length === 0) return;
    e.selectNode(o[Math.ceil(o.length / 2) - 1]);
  }
}, Ie = function(e, t, n) {
  const o = t === "in" ? e.scaleSensitivity : -e.scaleSensitivity;
  st(e, o, n);
}, Hn = (e, t) => {
  const n = An({
    deltaMode: t.deltaMode,
    deltaY: t.deltaY,
    scaleSensitivity: e.scaleSensitivity,
    viewportHeight: e.container.clientHeight || window.innerHeight
  });
  st(e, n, { x: t.clientX, y: t.clientY });
};
function In(e, t) {
  t = t === !0 ? {} : t;
  const n = () => {
    e.currentArrow ? e.removeArrow() : e.currentSummary ? e.removeSummary(e.currentSummary.summaryObj.id) : e.currentNodes && e.removeNodes(e.currentNodes);
  };
  let o = !1, s = null;
  const i = () => {
    o = !1, s && (clearTimeout(s), s = null), e.container.removeEventListener("keydown", r);
  }, r = (c) => {
    if (["Control", "Meta", "Shift", "Alt"].includes(c.key)) return;
    const h = e.nodeData;
    if (!h.children?.length) {
      i();
      return;
    }
    let d = !0;
    if (c.key === "0")
      for (const u of h.children)
        z(u, !1);
    else if (c.key === "=")
      for (const u of h.children)
        z(u, !0);
    else if (["1", "2", "3", "4", "5", "6", "7", "8", "9"].includes(c.key))
      for (const u of h.children)
        z(u, !0, Number(c.key) - 1);
    else
      d = !1;
    d && (e.refresh(), e.toCenter()), i();
  }, l = {
    Enter: (c) => {
      c.shiftKey ? e.insertSibling("before") : c.ctrlKey || c.metaKey ? e.insertParent() : e.insertSibling("after");
    },
    Tab: () => {
      e.addChild();
    },
    F1: () => {
      e.toCenter();
    },
    F2: () => {
      e.currentSummary ? e.editSummary(e.currentSummary) : e.currentArrow ? e.editArrowLabel(e.currentArrow) : e.beginEdit();
    },
    ArrowUp: (c) => {
      if (c.altKey)
        e.moveUpNode();
      else {
        if (c.metaKey || c.ctrlKey)
          return e.initSide();
        if (e.direction === 3) {
          const h = e.currentNode || e.currentNodes?.[0];
          h && On(e, h);
        } else
          ne(e, "previous");
      }
    },
    ArrowDown: (c) => {
      if (c.altKey)
        e.moveDownNode();
      else if (e.direction === 3) {
        const h = e.currentNode || e.currentNodes?.[0];
        h && $n(e, h);
      } else
        ne(e, "next");
    },
    ArrowLeft: (c) => {
      if (c.metaKey || c.ctrlKey)
        return e.initLeft();
      e.direction === 3 ? ne(e, "previous") : He(e, L.LHS);
    },
    ArrowRight: (c) => {
      if (c.metaKey || c.ctrlKey)
        return e.initRight();
      e.direction === 3 ? ne(e, "next") : He(e, L.RHS);
    },
    PageUp: () => e.moveUpNode(),
    PageDown: () => {
      e.moveDownNode();
    },
    "=": (c) => {
      (c.metaKey || c.ctrlKey) && Ie(e, "in");
    },
    "-": (c) => {
      (c.metaKey || c.ctrlKey) && Ie(e, "out");
    },
    0: (c) => {
      if (c.metaKey || c.ctrlKey) {
        if (o)
          return;
        e.scale(1);
      }
    },
    k: (c) => {
      (c.metaKey || c.ctrlKey) && (i(), o = !0, s = window.setTimeout(() => {
        s = null, i();
      }, 2e3), e.container.addEventListener("keydown", r));
    },
    Delete: n,
    Backspace: n,
    ...t
  };
  e.container.onkeydown = (c) => {
    if ((c.ctrlKey || c.metaKey) && ["c", "v", "x"].includes(c.key) || c.preventDefault(), !e.editable) return;
    const d = l[c.key];
    d && d(c);
  };
  const a = (c) => {
    if (c.target instanceof HTMLElement && c.target.id === "input-box" || e.currentNodes.length === 0) return !1;
    if (c.clipboardData) {
      const h = Ee(e.currentNodes).map((u) => u.nodeObj), d = De({
        magic: $e,
        data: h
      });
      return c.clipboardData.setData("text/plain", d), c.preventDefault(), !0;
    }
    return !1;
  };
  e.container.addEventListener("copy", a), e.container.addEventListener("cut", (c) => {
    a(c) && n();
  }), e.container.addEventListener("paste", (c) => {
    const h = c.clipboardData?.getData("text/plain");
    if (h)
      try {
        const d = JSON.parse(h);
        if (d && d.magic === $e && Array.isArray(d.data)) {
          const u = d.data, p = u.map((m) => ({ nodeObj: m }));
          u.length > 0 && e.currentNode && (e.copyNodes(p, e.currentNode), c.preventDefault());
          return;
        }
      } catch {
      }
    e.pasteHandler && e.pasteHandler(c);
  });
}
function jn(e) {
  const { panHelper: t, container: n } = e;
  let o = null;
  e.spacePressed = !1;
  const s = {
    lastTap: 0,
    lastTapTarget: null,
    DOUBLE_CLICK_THRESHOLD: 300,
    detect(f, b) {
      if (f.button !== 0) {
        this.clear();
        return;
      }
      const w = (/* @__PURE__ */ new Date()).getTime(), E = w - this.lastTap, S = E < this.DOUBLE_CLICK_THRESHOLD && E > 0 && this.lastTapTarget === f.target;
      this.lastTap = w, this.lastTapTarget = f.target, S && b(f);
    },
    clear() {
      this.lastTap = 0, this.lastTapTarget = null;
    }
  }, i = {
    Idle: 0,
    Pinch: 1,
    DragWait: 2,
    Drag: 3,
    Pan: 4,
    BoxSelect: 5
  };
  e.ptState = i.Idle;
  const r = {
    lastDistance: null,
    activePointers: /* @__PURE__ */ new Map(),
    handlePointerDown(f) {
      if (f.pointerType !== "touch") return !1;
      if (this.activePointers.set(f.pointerId, { x: f.clientX, y: f.clientY }), this.activePointers.size >= 2) {
        const [b, w] = Array.from(this.activePointers.values());
        return this.lastDistance = ke(b, w), !0;
      }
      return !1;
    },
    handlePointerMove(f) {
      if (f.pointerType !== "touch" || !this.activePointers.has(f.pointerId)) return !1;
      if (this.activePointers.set(f.pointerId, { x: f.clientX, y: f.clientY }), this.activePointers.size >= 2) {
        const [b, w] = Array.from(this.activePointers.values()), E = ke(b, w);
        if (this.lastDistance !== null && this.lastDistance > 0) {
          const S = E / this.lastDistance;
          e.scale(e.scaleVal * S, {
            x: (b.x + w.x) / 2,
            y: (b.y + w.y) / 2
          });
        }
        return this.lastDistance = E, !0;
      }
      return !1;
    },
    handlePointerUp(f) {
      f.pointerType === "touch" && (this.activePointers.delete(f.pointerId), this.activePointers.size < 2 && (this.lastDistance = null));
    },
    clear() {
      this.activePointers.clear(), this.lastDistance = null;
    }
  }, l = Nt(e), a = {
    timer: null,
    startPos: null,
    pointerId: null,
    DURATION: 500,
    MOVE_THRESHOLD: 10,
    clear() {
      this.timer !== null && (clearTimeout(this.timer), this.timer = null, this.startPos = null, this.pointerId = null);
    },
    start(f, b) {
      this.timer = window.setTimeout(() => {
        b(f), this.timer = null, this.startPos = null, this.pointerId = null;
      }, this.DURATION), this.startPos = { x: f.clientX, y: f.clientY }, this.pointerId = f.pointerId;
    },
    handleMove(f) {
      if (this.timer !== null && this.startPos !== null && f.pointerId === this.pointerId) {
        const b = f.clientX - this.startPos.x, w = f.clientY - this.startPos.y;
        Math.sqrt(b * b + w * w) > this.MOVE_THRESHOLD && this.clear();
      }
    }
  }, c = (f, b) => {
    if (f.closest("#input-box")) return !1;
    const w = f.closest(".svg-label"), E = f.closest(".topiclinks, .summary"), S = w ? { type: w.dataset.type, element: document.getElementById(w.dataset.svgId) } : E ? { type: E.classList.contains("topiclinks") ? "arrow" : "summary", element: f.closest("g") } : null;
    if (!S?.type || !S?.element) return !1;
    const { type: M, element: N } = S;
    return e.clearSelection(), M === "arrow" ? b ? e.editArrowLabel(N) : e.selectArrow(N) : b ? e.editSummary(N) : e.selectSummary(N), !0;
  }, h = (f) => {
    if (f.pointerType === "mouse" && f.button !== 0) return;
    if (e.helper1?.moved) {
      e.helper1.clear();
      return;
    }
    if (e.helper2?.moved) {
      e.helper2.clear();
      return;
    }
    if (t.moved) {
      t.clear();
      return;
    }
    if (l?.isDragging)
      return;
    const b = f.target;
    b.tagName === "ME-EPD" && (f.ctrlKey || f.metaKey ? e.expandNodeAll(b.previousSibling) : e.expandNode(b.previousSibling));
  }, d = (f) => {
    if (!e.editable) return;
    const b = f.target;
    if (re(b)) {
      e.selectNode(b), e.beginEdit(b);
      return;
    }
    c(b, !0);
  }, u = (f) => {
    if (f.pointerType === "touch" && r.handlePointerDown(f)) {
      e.ptState = i.Pinch, a.clear(), t.clear(), (l.isDragging || l.pointerId !== null) && Oe(e, l);
      return;
    }
    if (e.ptState === i.Pinch) return;
    const b = f.target;
    if (e.editable && b.className === "map-container" && f.button === 0 && f.pointerType === "mouse") {
      e.ptState = i.BoxSelect;
      return;
    }
    if (t.handlePointerDown(f), t.mousedown && (e.ptState = i.Pan), f.button === 0 || f.pointerType === "touch")
      if (re(b)) {
        e.selection?.cancel();
        const E = e.currentNodes || [];
        if (f.ctrlKey || f.metaKey || e.mobileMultiSelect ? E.includes(b) ? o = b : ((e.currentArrow || e.currentSummary) && e.clearSelection(), e.selection?.select(b)) : E.includes(b) || e.selectNode(b), !e.editable) return;
        f.pointerType === "touch" ? (e.ptState = i.DragWait, a.start(f, (M) => {
          Pe(e, l, M, !0) && (e.ptState = i.Drag, b.setPointerCapture(M.pointerId));
        })) : Pe(e, l, f, !1) && (e.ptState = i.Drag, b.setPointerCapture(f.pointerId));
      } else
        c(b, !1);
  }, p = (f) => {
    switch (e.ptState) {
      case i.Pinch:
        r.handlePointerMove(f);
        break;
      case i.DragWait:
        a.handleMove(f), a.timer === null && (e.ptState = i.Pan, t.handlePointerMove(f));
        break;
      case i.Drag:
        Dt(e, l, f);
        break;
      case i.Pan:
        t.handlePointerMove(f);
        break;
    }
  }, m = (f) => {
    f.preventDefault(), window.removeEventListener("contextmenu", m, !0);
  }, x = (f) => {
    f.pointerType === "touch" && r.handlePointerUp(f);
    const b = l.isDragging, w = t.moved;
    switch (e.ptState) {
      case i.DragWait:
        a.clear();
        break;
      case i.Drag:
        Mt(e, l, f);
        break;
      case i.Pan:
        t.handlePointerUp(f), t.moved && f.button === 2 && f.pointerType === "mouse" && (window.addEventListener("contextmenu", m, { capture: !0, once: !0 }), setTimeout(() => window.removeEventListener("contextmenu", m, !0), 300));
        break;
    }
    s.detect(f, d), (e.ptState !== i.Pinch || r.activePointers.size < 2) && (e.ptState = i.Idle), o && (!b && !w && e.selection?.deselect(o), o = null);
  }, y = () => {
    r.clear(), a.clear(), t.clear(), s.clear(), (l.isDragging || l.pointerId !== null) && Oe(e, l), e.ptState = i.Idle, o = null;
  }, g = (f) => {
    f.preventDefault(), f.button === 2 && e.editable && setTimeout(() => {
      if (e.panHelper.moved || e.ptState !== i.Idle && e.ptState !== i.Pan) return;
      const b = f.target;
      re(b) && !b.classList.contains("selected") && e.selectNode(b), e.bus.fire("showContextMenu", f);
    }, 200);
  }, v = (f) => {
    if (f.ctrlKey || f.metaKey)
      return f.stopPropagation(), f.preventDefault(), Hn(e, f);
    (f.shiftKey ? e.move(-f.deltaY, 0) : e.move(-f.deltaX, -f.deltaY)) && (f.stopPropagation(), f.preventDefault());
  }, C = (f) => {
    f.code === "Space" && (e.spacePressed = !0, e.container.classList.add("space-pressed"));
  }, T = (f) => {
    f.code === "Space" && (e.spacePressed = !1, e.container.classList.remove("space-pressed"));
  };
  return Ge([
    { dom: n, evt: "pointerdown", func: u },
    { dom: n, evt: "pointermove", func: p },
    { dom: n, evt: "pointerup", func: x },
    { dom: n, evt: "pointercancel", func: y },
    { dom: n, evt: "click", func: h },
    { dom: n, evt: "contextmenu", func: g },
    { dom: n, evt: "wheel", func: typeof e.handleWheel == "function" ? e.handleWheel : v },
    { dom: n, evt: "blur", func: y },
    { dom: n, evt: "keydown", func: C },
    { dom: n, evt: "keyup", func: T }
  ]);
}
function Rn() {
  return {
    handlers: {},
    addListener: function(e, t) {
      this.handlers[e] === void 0 && (this.handlers[e] = []), this.handlers[e].push(t);
    },
    fire: function(e, ...t) {
      if (this.handlers[e] instanceof Array) {
        const n = this.handlers[e];
        for (let o = 0; o < n.length; o++)
          n[o](...t);
      }
    },
    removeListener: function(e, t) {
      if (!this.handlers[e]) return;
      const n = this.handlers[e];
      if (!t)
        n.length = 0;
      else if (n.length)
        for (let o = 0; o < n.length; o++)
          n[o] === t && this.handlers[e].splice(o, 1);
    }
  };
}
const H = "http://www.w3.org/2000/svg", fe = function(e) {
  const t = e.clientWidth, n = e.clientHeight, o = e.dataset, s = Number(o.x), i = Number(o.y), r = o.anchor;
  let l = s;
  r === "middle" ? l = s - t / 2 : r === "end" && (l = s - t), e.style.left = `${l}px`, e.style.top = `${i - n / 2}px`, e.style.visibility = "visible";
}, le = function(e, t, n, o) {
  const { anchor: s = "middle", color: i, dataType: r, svgId: l } = o, a = document.createElement("div");
  a.className = "svg-label", a.style.color = i || "#666";
  const c = "label-" + l;
  return a.id = c, a.innerHTML = e, a.dataset.type = r, a.dataset.svgId = l, a.dataset.x = t.toString(), a.dataset.y = n.toString(), a.dataset.anchor = s, a;
}, ct = function(e, t, n) {
  const o = document.createElementNS(H, "path");
  return _(o, {
    d: e,
    stroke: t || "#666",
    fill: "none",
    "stroke-width": n
  }), o;
}, U = function(e) {
  const t = document.createElementNS(H, "svg");
  return t.setAttribute("class", e), t.setAttribute("overflow", "visible"), t;
}, je = function() {
  const e = document.createElementNS(H, "line");
  return e.setAttribute("stroke", "#4dc4ff"), e.setAttribute("fill", "none"), e.setAttribute("stroke-width", "2"), e.setAttribute("opacity", "0.45"), e;
}, Bn = function(e, t, n, o) {
  const s = document.createElementNS(H, "g");
  return [
    {
      name: "line",
      d: e
    },
    {
      name: "arrow1",
      d: t
    },
    {
      name: "arrow2",
      d: n
    }
  ].forEach((r, l) => {
    const a = r.d, c = document.createElementNS(H, "path"), h = {
      d: a,
      stroke: o?.stroke || "rgb(227, 125, 116)",
      fill: "none",
      "stroke-width": String(o?.strokeWidth || "2")
    };
    o?.opacity !== void 0 && (h.opacity = String(o.opacity)), _(c, h), l === 0 && c.setAttribute("stroke-dasharray", o?.strokeDasharray || "8,2");
    const d = document.createElementNS(H, "path");
    _(d, {
      d: a,
      stroke: "transparent",
      fill: "none",
      "stroke-width": "15"
    }), s.appendChild(d), s.appendChild(c), s[r.name] = c;
  }), s;
}, at = function(e, t, n) {
  if (!t) return;
  const o = n.label;
  t.style.opacity = "0";
  const s = t.cloneNode(!0);
  e.nodes.appendChild(s), s.id = "input-box", s.textContent = o, s.contentEditable = "plaintext-only", s.spellcheck = !1, s.style.cssText = `
    left:${t.style.left};
    top:${t.style.top}; 
    max-width: 200px;
  `, Ze(s), e.scrollIntoView(s), s.addEventListener("keydown", (i) => {
    if (i.stopPropagation(), i.isComposing) return;
    const r = i.key;
    if (r === "Enter" || r === "Tab") {
      if (i.shiftKey) return;
      i.preventDefault(), s.blur(), e.container.focus();
    }
  }), s.addEventListener("blur", () => {
    if (!s) return;
    const i = s.innerText?.trim() || "";
    i === "" ? n.label = o : n.label = i, t.style.opacity = "1", s.remove(), i !== o && (e.markdown ? t.innerHTML = e.markdown(n.label, n) : t.textContent = n.label, fe(t), "parent" in n ? e.bus.fire("operation", {
      name: "finishEditSummary",
      obj: n
    }) : e.bus.fire("operation", {
      name: "finishEditArrowLabel",
      obj: n
    }));
  });
}, Wn = function(e) {
  const t = this.map.querySelector("me-root"), n = t.offsetTop, o = t.offsetLeft, s = t.offsetWidth, i = t.offsetHeight, r = this.map.querySelectorAll("me-main > me-wrapper");
  this.lines.innerHTML = "";
  for (let l = 0; l < r.length; l++) {
    const a = r[l], c = a.querySelector("me-tpc"), { offsetLeft: h, offsetTop: d } = $(this.nodes, c), u = c.offsetWidth, p = c.offsetHeight, m = a.parentNode.className, x = this.generateMainBranch({
      pT: n,
      pL: o,
      pW: s,
      pH: i,
      cT: d,
      cL: h,
      cW: u,
      cH: p,
      direction: m,
      containerHeight: this.nodes.offsetHeight,
      containerWidth: this.nodes.offsetWidth
    }), y = this.theme.palette, g = c.nodeObj.branchColor || y[l % y.length];
    if (c.style.borderColor = g, this.lines.appendChild(ct(x, g, "3")), e && e !== a)
      continue;
    const v = U("subLines"), C = a.lastChild;
    C.tagName === "svg" && C.remove(), a.appendChild(v), dt(this, v, g, a, m, !0);
  }
  this.labelContainer.innerHTML = "", this.renderArrow(), this.renderSummary(), this.bus.fire("linkDiv");
}, dt = function(e, t, n, o, s, i) {
  const r = o.firstChild, l = o.children[1].children;
  if (l.length === 0) return;
  const a = r.offsetTop, c = r.offsetLeft, h = r.offsetWidth, d = r.offsetHeight;
  for (let u = 0; u < l.length; u++) {
    const p = l[u], m = p.firstChild, x = m.offsetTop, y = m.offsetLeft, g = m.offsetWidth, v = m.offsetHeight, C = m.firstChild.nodeObj.branchColor || n, T = e.generateSubBranch({ pT: a, pL: c, pW: h, pH: d, cT: x, cL: y, cW: g, cH: v, direction: s, isFirst: i });
    t.appendChild(ct(T, C, "2"));
    const D = m.children[1];
    if (D) {
      if (!D.expanded) continue;
    } else
      continue;
    dt(e, t, C, p, s);
  }
}, Yn = {
  addChild: "Add child",
  addParent: "Add parent",
  addSibling: "Add sibling",
  removeNode: "Remove node",
  focus: "Focus Mode",
  cancelFocus: "Cancel Focus Mode",
  moveUp: "Move up",
  moveDown: "Move down",
  link: "Link",
  linkBidirectional: "Bidirectional Link",
  clickTips: "Please click the target node",
  summary: "Summary"
};
function Xn(e, t) {
  const n = {
    focus: !0,
    link: !0,
    locale: Yn
  };
  t = t === !0 ? n : Object.assign(n, t);
  const o = (f) => {
    const b = document.createElement("div");
    return b.innerText = f, b.className = "tips", b;
  }, s = (f, b, w) => {
    const E = document.createElement("li");
    return E.id = f, E.innerHTML = `<span>${be(b)}</span><span ${w ? 'class="key"' : ""}>${be(w)}</span>`, E;
  }, i = t.locale, r = s("cm-add_child", i.addChild, "Tab"), l = s("cm-add_parent", i.addParent, "Ctrl + Enter"), a = s("cm-add_sibling", i.addSibling, "Enter"), c = s("cm-remove_child", i.removeNode, "Delete"), h = s("cm-fucus", i.focus, ""), d = s("cm-unfucus", i.cancelFocus, ""), u = s("cm-up", i.moveUp, "PgUp"), p = s("cm-down", i.moveDown, "Pgdn"), m = s("cm-link", i.link, ""), x = s("cm-link-bidirectional", i.linkBidirectional, ""), y = s("cm-summary", i.summary, ""), g = document.createElement("ul");
  if (g.className = "menu-list", g.appendChild(r), g.appendChild(l), g.appendChild(a), g.appendChild(c), t.focus && (g.appendChild(h), g.appendChild(d)), g.appendChild(u), g.appendChild(p), g.appendChild(y), t.link && (g.appendChild(m), g.appendChild(x)), t && t.extend)
    for (let f = 0; f < t.extend.length; f++) {
      const b = t.extend[f], w = s(b.name, b.name, b.key || "");
      g.appendChild(w), w.onclick = (E) => {
        b.onclick(E);
      };
    }
  const v = document.createElement("div");
  v.className = "context-menu", v.appendChild(g), v.hidden = !0, e.container.append(v);
  let C = !0;
  const T = (f) => {
    const b = f.target;
    if (re(b)) {
      b.parentElement.tagName === "ME-ROOT" ? C = !0 : C = !1, C ? (h.className = "disabled", u.className = "disabled", p.className = "disabled", l.className = "disabled", a.className = "disabled", c.className = "disabled") : (h.className = "", u.className = "", p.className = "", l.className = "", a.className = "", c.className = ""), v.hidden = !1, g.style.top = "", g.style.bottom = "", g.style.left = "", g.style.right = "";
      const w = g.offsetHeight, E = g.offsetWidth, S = g.getBoundingClientRect(), M = f.clientY - S.top, N = f.clientX - S.left;
      w + M > window.innerHeight ? (g.style.top = "", g.style.bottom = "0px") : (g.style.bottom = "", g.style.top = M + 15 + "px"), E + N > window.innerWidth ? (g.style.left = "", g.style.right = "0px") : (g.style.right = "", g.style.left = N + 10 + "px");
    }
  };
  e.bus.addListener("showContextMenu", T), v.onclick = (f) => {
    f.target === v && (v.hidden = !0);
  }, r.onclick = () => {
    e.addChild(), v.hidden = !0;
  }, l.onclick = () => {
    e.insertParent(), v.hidden = !0;
  }, a.onclick = () => {
    C || (e.insertSibling("after"), v.hidden = !0);
  }, c.onclick = () => {
    C || (e.removeNodes(e.currentNodes || []), v.hidden = !0);
  }, h.onclick = () => {
    C || (e.focusNode(e.currentNode), v.hidden = !0);
  }, d.onclick = () => {
    e.cancelFocus(), v.hidden = !0;
  }, u.onclick = () => {
    C || (e.moveUpNode(), v.hidden = !0);
  }, p.onclick = () => {
    C || (e.moveDownNode(), v.hidden = !0);
  };
  const D = (f) => {
    v.hidden = !0;
    const b = e.currentNode, w = o(i.clickTips);
    e.container.appendChild(w), e.map.addEventListener(
      "click",
      (E) => {
        E.preventDefault(), w.remove();
        const S = E.target;
        (S.parentElement.tagName === "ME-PARENT" || S.parentElement.tagName === "ME-ROOT") && e.createArrow(b, S, f);
      },
      {
        once: !0
      }
    );
  };
  return m.onclick = () => D(), x.onclick = () => D({ bidirectional: !0 }), y.onclick = () => {
    v.hidden = !0, e.createSummary(), e.unselectNodes(e.currentNodes);
  }, () => {
    r.onclick = null, l.onclick = null, a.onclick = null, c.onclick = null, h.onclick = null, d.onclick = null, u.onclick = null, p.onclick = null, m.onclick = null, y.onclick = null, v.onclick = null, e.container.oncontextmenu = null;
  };
}
const Fn = function(e) {
  return ["createSummary", "removeSummary", "finishEditSummary"].includes(e.name) ? {
    type: "summary",
    value: e.obj.id
  } : ["createArrow", "removeArrow", "finishEditArrowLabel", "reshapeArrow"].includes(e.name) ? {
    type: "arrow",
    value: e.obj.id
  } : ["removeNodes", "copyNodes", "moveNodeBefore", "moveNodeAfter", "moveNodeIn"].includes(e.name) ? {
    type: "nodes",
    value: e.objs.map((t) => t.id)
  } : {
    type: "nodes",
    value: [e.obj.id]
  };
};
function Kn(e) {
  let t = [], n = -1, o = e.getData(), s = [];
  e.undo = function() {
    if (n > -1) {
      const a = t[n];
      o = a.prev, e.refresh(a.prev);
      try {
        a.currentTarget.type === "nodes" && (a.operation === "removeNodes" ? e.selectNodes(a.currentTarget.value.map((c) => this.findEle(c))) : e.selectNodes(a.currentSelected.map((c) => this.findEle(c))));
      } catch {
      } finally {
        n--;
      }
    }
  }, e.redo = function() {
    if (n < t.length - 1) {
      n++;
      const a = t[n];
      o = a.next, e.refresh(a.next);
      try {
        a.currentTarget.type === "nodes" && (a.operation === "removeNodes" ? e.selectNodes(a.currentSelected.map((c) => this.findEle(c))) : e.selectNodes(a.currentTarget.value.map((c) => this.findEle(c))));
      } catch {
      }
    }
  }, e.clearHistory = function() {
    t = [], n = -1, o = e.getData(), e.clearSelection();
  };
  const i = function(a) {
    if (a.name === "beginEdit") return;
    t = t.slice(0, n + 1);
    const c = e.getData(), h = {
      prev: o,
      operation: a.name,
      currentSelected: s.map((d) => d.id),
      currentTarget: Fn(a),
      next: c
    };
    t.push(h), o = c, n = t.length - 1;
  }, r = function(a) {
    if (!e.editable || !a.metaKey && !a.ctrlKey) return;
    const c = a.key.toLowerCase();
    c === "z" ? a.shiftKey ? e.redo() : e.undo() : c === "y" && e.redo();
  }, l = function() {
    s = e.currentNodes.map((a) => a.nodeObj);
  };
  return e.bus.addListener("operation", i), e.bus.addListener("selectNodes", l), e.bus.addListener("unselectNodes", l), e.container.addEventListener("keydown", r), () => {
    e.bus.removeListener("operation", i), e.bus.removeListener("selectNodes", l), e.bus.removeListener("unselectNodes", l), e.container.removeEventListener("keydown", r);
  };
}
const Vn = '<?xml version="1.0" standalone="no"?><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"><svg t="1750169394918" class="icon" viewBox="0 0 1024 1024" version="1.1" xmlns="http://www.w3.org/2000/svg" p-id="2021" xmlns:xlink="http://www.w3.org/1999/xlink" width="200" height="200"><path d="M851.91168 328.45312c-59.97056 0-108.6208 48.47104-108.91264 108.36992l-137.92768 38.4a109.14304 109.14304 0 0 0-63.46752-46.58688l1.39264-137.11872c47.29344-11.86816 82.31936-54.66624 82.31936-105.64096 0-60.15488-48.76288-108.91776-108.91776-108.91776s-108.91776 48.76288-108.91776 108.91776c0 49.18784 32.60928 90.75712 77.38368 104.27392l-1.41312 138.87488a109.19936 109.19936 0 0 0-63.50336 48.55808l-138.93632-39.48544 0.01024-0.72704c0-60.15488-48.76288-108.91776-108.91776-108.91776s-108.91776 48.75776-108.91776 108.91776c0 60.15488 48.76288 108.91264 108.91776 108.91264 39.3984 0 73.91232-20.92032 93.03552-52.2496l139.19232 39.552-0.00512 0.2304c0 25.8304 9.00096 49.5616 24.02816 68.23424l-90.14272 132.63872a108.7488 108.7488 0 0 0-34.2528-5.504c-60.15488 0-108.91776 48.768-108.91776 108.91776 0 60.16 48.76288 108.91776 108.91776 108.91776 60.16 0 108.92288-48.75776 108.92288-108.91776 0-27.14624-9.9328-51.968-26.36288-71.04l89.04704-131.03104a108.544 108.544 0 0 0 37.6832 6.70208 108.672 108.672 0 0 0 36.48512-6.272l93.13792 132.57216a108.48256 108.48256 0 0 0-24.69888 69.0688c0 60.16 48.768 108.92288 108.91776 108.92288 60.16 0 108.91776-48.76288 108.91776-108.92288 0-60.14976-48.75776-108.91776-108.91776-108.91776a108.80512 108.80512 0 0 0-36.69504 6.3488l-93.07136-132.48a108.48768 108.48768 0 0 0 24.79616-72.22784l136.09984-37.888c18.99008 31.93856 53.84192 53.3504 93.69088 53.3504 60.16 0 108.92288-48.75776 108.92288-108.91264-0.00512-60.15488-48.77312-108.92288-108.92288-108.92288z" p-id="2022"></path></svg>', zn = '<?xml version="1.0" standalone="no"?><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"><svg t="1750169375313" class="icon" viewBox="0 0 1024 1024" version="1.1" xmlns="http://www.w3.org/2000/svg" p-id="1775" xmlns:xlink="http://www.w3.org/1999/xlink" width="200" height="200"><path d="M639 463.30000001L639 285.1c0-36.90000001-26.4-68.5-61.3-68.5l-150.2 0c-1.5 0-3 0.1-4.5 0.3-10.2-38.7-45.5-67.3-87.5-67.3-50 0-90.5 40.5-90.5 90.5s40.5 90.5 90.5 90.5c42 0 77.3-28.6 87.5-67.39999999 1.4 0.3 2.9 0.4 4.5 0.39999999L577.7 263.6c6.8 0 14.3 8.9 14.3 21.49999999l0 427.00000001c0 12.7-7.40000001 21.5-14.30000001 21.5l-150.19999999 0c-1.5 0-3 0.2-4.5 0.4-10.2-38.8-45.5-67.3-87.5-67.3-50 0-90.5 40.5-90.5 90.4 0 49.9 40.5 90.6 90.5 90.59999999 42 0 77.3-28.6 87.5-67.39999999 1.4 0.2 2.9 0.4 4.49999999 0.4L577.7 780.7c34.80000001 0 61.3-31.6 61.3-68.50000001L639 510.3l79.1 0c10.4 38.5 45.49999999 67 87.4 67 50 0 90.5-40.5 90.5-90.5s-40.5-90.5-90.5-90.5c-41.79999999 0-77.00000001 28.4-87.4 67L639 463.30000001z" fill="currentColor" p-id="1776"></path></svg>', Gn = '<?xml version="1.0" standalone="no"?><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"><svg t="1750169667709" class="icon" viewBox="0 0 1024 1024" version="1.1" xmlns="http://www.w3.org/2000/svg" p-id="3037" xmlns:xlink="http://www.w3.org/1999/xlink" width="200" height="200"><path d="M385 560.69999999L385 738.9c0 36.90000001 26.4 68.5 61.3 68.5l150.2 0c1.5 0 3-0.1 4.5-0.3 10.2 38.7 45.5 67.3 87.5 67.3 50 0 90.5-40.5 90.5-90.5s-40.5-90.5-90.5-90.5c-42 0-77.3 28.6-87.5 67.39999999-1.4-0.3-2.9-0.4-4.5-0.39999999L446.3 760.4c-6.8 0-14.3-8.9-14.3-21.49999999l0-427.00000001c0-12.7 7.40000001-21.5 14.30000001-21.5l150.19999999 0c1.5 0 3-0.2 4.5-0.4 10.2 38.8 45.5 67.3 87.5 67.3 50 0 90.5-40.5 90.5-90.4 0-49.9-40.5-90.6-90.5-90.59999999-42 0-77.3 28.6-87.5 67.39999999-1.4-0.2-2.9-0.4-4.49999999-0.4L446.3 243.3c-34.80000001 0-61.3 31.6-61.3 68.50000001L385 513.7l-79.1 0c-10.4-38.5-45.49999999-67-87.4-67-50 0-90.5 40.5-90.5 90.5s40.5 90.5 90.5 90.5c41.79999999 0 77.00000001-28.4 87.4-67L385 560.69999999z" fill="currentColor" p-id="3038"></path></svg>', qn = '<?xml version="1.0" standalone="no"?><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"><svg t="1750169402629" class="icon" viewBox="0 0 1024 1024" version="1.1" xmlns="http://www.w3.org/2000/svg" p-id="2170" xmlns:xlink="http://www.w3.org/1999/xlink" width="200" height="200"><path d="M639.328 416c8.032 0 16.096-3.008 22.304-9.056l202.624-197.184-0.8 143.808c-0.096 17.696 14.144 32.096 31.808 32.192 0.064 0 0.128 0 0.192 0 17.6 0 31.904-14.208 32-31.808l1.248-222.208c0-0.672-0.352-1.248-0.384-1.92 0.032-0.512 0.288-0.896 0.288-1.408 0.032-17.664-14.272-32-31.968-32.032L671.552 96l-0.032 0c-17.664 0-31.968 14.304-32 31.968C639.488 145.632 653.824 160 671.488 160l151.872 0.224-206.368 200.8c-12.672 12.32-12.928 32.608-0.64 45.248C622.656 412.736 630.976 416 639.328 416z" p-id="2171"></path><path d="M896.032 639.552 896.032 639.552c-17.696 0-32 14.304-32.032 31.968l-0.224 151.872-200.832-206.4c-12.32-12.64-32.576-12.96-45.248-0.64-12.672 12.352-12.928 32.608-0.64 45.248l197.184 202.624-143.808-0.8c-0.064 0-0.128 0-0.192 0-17.6 0-31.904 14.208-32 31.808-0.096 17.696 14.144 32.096 31.808 32.192l222.24 1.248c0.064 0 0.128 0 0.192 0 0.64 0 1.12-0.32 1.76-0.352 0.512 0.032 0.896 0.288 1.408 0.288l0.032 0c17.664 0 31.968-14.304 32-31.968L928 671.584C928.032 653.952 913.728 639.584 896.032 639.552z" p-id="2172"></path><path d="M209.76 159.744l143.808 0.8c0.064 0 0.128 0 0.192 0 17.6 0 31.904-14.208 32-31.808 0.096-17.696-14.144-32.096-31.808-32.192L131.68 95.328c-0.064 0-0.128 0-0.192 0-0.672 0-1.248 0.352-1.888 0.384-0.448 0-0.8-0.256-1.248-0.256 0 0-0.032 0-0.032 0-17.664 0-31.968 14.304-32 31.968L96 352.448c-0.032 17.664 14.272 32 31.968 32.032 0 0 0.032 0 0.032 0 17.664 0 31.968-14.304 32-31.968l0.224-151.936 200.832 206.4c6.272 6.464 14.624 9.696 22.944 9.696 8.032 0 16.096-3.008 22.304-9.056 12.672-12.32 12.96-32.608 0.64-45.248L209.76 159.744z" p-id="2173"></path><path d="M362.368 617.056l-202.624 197.184 0.8-143.808c0.096-17.696-14.144-32.096-31.808-32.192-0.064 0-0.128 0-0.192 0-17.6 0-31.904 14.208-32 31.808l-1.248 222.24c0 0.704 0.352 1.312 0.384 2.016 0 0.448-0.256 0.832-0.256 1.312-0.032 17.664 14.272 32 31.968 32.032L352.448 928c0 0 0.032 0 0.032 0 17.664 0 31.968-14.304 32-31.968s-14.272-32-31.968-32.032l-151.936-0.224 206.4-200.832c12.672-12.352 12.96-32.608 0.64-45.248S375.008 604.704 362.368 617.056z" p-id="2174"></path></svg>', Un = '<?xml version="1.0" standalone="no"?><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"><svg t="1750169573443" class="icon" viewBox="0 0 1024 1024" version="1.1" xmlns="http://www.w3.org/2000/svg" p-id="2883" xmlns:xlink="http://www.w3.org/1999/xlink" width="200" height="200"><path d="M514.133333 488.533333m-106.666666 0a106.666667 106.666667 0 1 0 213.333333 0 106.666667 106.666667 0 1 0-213.333333 0Z" fill="currentColor" p-id="2884"></path><path d="M512 64C264.533333 64 64 264.533333 64 512c0 236.8 183.466667 428.8 416 445.866667v-134.4c-53.333333-59.733333-200.533333-230.4-200.533333-334.933334 0-130.133333 104.533333-234.666667 234.666666-234.666666s234.666667 104.533333 234.666667 234.666666c0 61.866667-49.066667 153.6-145.066667 270.933334l-59.733333 68.266666V960C776.533333 942.933333 960 748.8 960 512c0-247.466667-200.533333-448-448-448z" fill="currentColor" p-id="2885"></path></svg>', Jn = '<?xml version="1.0" standalone="no"?><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"><svg t="1750169419447" class="icon" viewBox="0 0 1024 1024" version="1.1" xmlns="http://www.w3.org/2000/svg" p-id="2480" xmlns:xlink="http://www.w3.org/1999/xlink" width="200" height="200"><path d="M863.328 482.56l-317.344-1.12L545.984 162.816c0-17.664-14.336-32-32-32s-32 14.336-32 32l0 318.4L159.616 480.064c-0.032 0-0.064 0-0.096 0-17.632 0-31.936 14.24-32 31.904C127.424 529.632 141.728 544 159.392 544.064l322.592 1.152 0 319.168c0 17.696 14.336 32 32 32s32-14.304 32-32l0-318.944 317.088 1.12c0.064 0 0.096 0 0.128 0 17.632 0 31.936-14.24 32-31.904C895.264 496.992 880.96 482.624 863.328 482.56z" p-id="2481"></path></svg>', Zn = '<?xml version="1.0" standalone="no"?><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"><svg t="1750169426515" class="icon" viewBox="0 0 1024 1024" version="1.1" xmlns="http://www.w3.org/2000/svg" p-id="2730" xmlns:xlink="http://www.w3.org/1999/xlink" width="200" height="200"><path d="M863.744 544 163.424 544c-17.664 0-32-14.336-32-32s14.336-32 32-32l700.32 0c17.696 0 32 14.336 32 32S881.44 544 863.744 544z" p-id="2731"></path></svg>', Qn = {
  side: Vn,
  left: zn,
  right: Gn,
  full: qn,
  living: Un,
  zoomin: Jn,
  zoomout: Zn
}, W = (e, t) => {
  const n = document.createElement("span");
  return n.id = e, n.innerHTML = Qn[t], n;
};
function eo(e) {
  const t = document.createElement("div"), n = W("fullscreen", "full"), o = W("toCenter", "living"), s = W("zoomout", "zoomout"), i = W("zoomin", "zoomin");
  t.appendChild(n), t.appendChild(o), t.appendChild(s), t.appendChild(i), t.className = "mind-elixir-toolbar rb";
  let r = null;
  const l = () => {
    const c = e.container.getBoundingClientRect(), h = Ce(e.map.style.transform), d = c.width / 2, u = c.height / 2, p = (d - h.x) / e.scaleVal, m = (u - h.y) / e.scaleVal;
    r = {
      containerRect: c,
      currentTransform: h,
      mapCenterX: p,
      mapCenterY: m
    };
  }, a = () => {
    if (r) {
      const c = e.container.getBoundingClientRect(), h = c.width / 2, d = c.height / 2, u = h - r.mapCenterX * e.scaleVal, p = d - r.mapCenterY * e.scaleVal, m = u - r.currentTransform.x, x = p - r.currentTransform.y;
      e.move(m, x);
    }
  };
  return e.el.addEventListener("fullscreenchange", a), n.onclick = () => {
    l(), document.fullscreenElement !== e.el ? e.el.requestFullscreen() : document.exitFullscreen();
  }, o.onclick = () => {
    e.toCenter();
  }, s.onclick = () => {
    e.scale(e.scaleVal - e.scaleSensitivity);
  }, i.onclick = () => {
    e.scale(e.scaleVal + e.scaleSensitivity);
  }, t;
}
function to(e) {
  const t = document.createElement("div"), n = W("tbltl", "left"), o = W("tbltr", "right"), s = W("tblts", "side");
  return t.appendChild(n), t.appendChild(o), t.appendChild(s), t.className = "mind-elixir-toolbar lt", n.onclick = () => {
    e.initLeft();
  }, o.onclick = () => {
    e.initRight();
  }, s.onclick = () => {
    e.initSide();
  }, t;
}
function no(e) {
  e.container.append(eo(e)), e.container.append(to(e));
}
class oo {
  _listeners = /* @__PURE__ */ new Map();
  addEventListener(t, n) {
    const o = this._listeners.get(t) ?? /* @__PURE__ */ new Set();
    return this._listeners.set(t, o), o.add(n), this;
  }
  removeEventListener(t, n) {
    return this._listeners.get(t)?.delete(n), this;
  }
  dispatchEvent(t, ...n) {
    let o = !0;
    for (const s of this._listeners.get(t) ?? [])
      o = s(...n) !== !1 && o;
    return o;
  }
  unbindAllListeners() {
    this._listeners.clear();
  }
  // Let's also support on, off and emit like node
  on = this.addEventListener;
  off = this.removeEventListener;
  emit = this.dispatchEvent;
}
const Re = (e, t = "px") => typeof e == "number" ? e + t : e, j = ({ style: e }, t, n) => {
  if (typeof t == "object")
    for (const [o, s] of Object.entries(t))
      s !== void 0 && (e[o] = Re(s));
  else n !== void 0 && (e[t] = Re(n));
}, Be = (e = 0, t = 0, n = 0, o = 0) => {
  const s = { x: e, y: t, width: n, height: o, top: t, left: e, right: e + n, bottom: t + o };
  return { ...s, toJSON: () => JSON.stringify(s) };
}, so = (e) => {
  let t, n = -1, o = !1;
  return {
    next: (...s) => {
      t = s, o || (o = !0, n = requestAnimationFrame(() => {
        e(...t), o = !1;
      }));
    },
    cancel: () => {
      cancelAnimationFrame(n), o = !1;
    }
  };
}, We = (e, t, n = "touch") => {
  switch (n) {
    case "center": {
      const o = t.left + t.width / 2, s = t.top + t.height / 2;
      return o >= e.left && o <= e.right && s >= e.top && s <= e.bottom;
    }
    case "cover":
      return t.left >= e.left && t.top >= e.top && t.right <= e.right && t.bottom <= e.bottom;
    case "touch":
      return e.right >= t.left && e.left <= t.right && e.bottom >= t.top && e.top <= t.bottom;
  }
}, io = () => matchMedia("(hover: none), (pointer: coarse)").matches, ro = () => "safari" in window, ve = (e) => Array.isArray(e) ? e : [e], ht = (e) => (t, n, o, s = {}) => {
  (t instanceof HTMLCollection || t instanceof NodeList) && (t = Array.from(t)), n = ve(n), t = ve(t);
  for (const i of t)
    if (i)
      for (const r of n)
        i[e](r, o, { capture: !1, ...s });
}, F = ht("addEventListener"), I = ht("removeEventListener"), oe = (e) => {
  const { clientX: t, clientY: n, target: o } = e.touches?.[0] ?? e;
  return { x: t, y: n, target: o };
}, K = (e, t = document) => ve(e).map((n) => typeof n == "string" ? Array.from(t.querySelectorAll(n)) : n instanceof Element ? n : null).flat().filter(Boolean), lo = (e, t) => t.some((n) => typeof n == "number" ? e.button === n : typeof n == "object" ? n.button !== e.button ? !1 : n.modifiers.every((o) => {
  switch (o) {
    case "alt":
      return e.altKey;
    case "ctrl":
      return e.ctrlKey || e.metaKey;
    case "shift":
      return e.shiftKey;
  }
}) : !1), { abs: B, max: Ye, min: Xe, ceil: Fe } = Math, Ke = (e = []) => ({
  stored: e,
  selected: [],
  touched: [],
  changed: { added: [], removed: [] }
});
class co extends oo {
  static version = "mind-elixir-fork";
  // Options
  _options;
  // Selection store
  _selection = Ke();
  // Area element and clipping element
  _area;
  _clippingElement;
  // Target container (element) and boundary (cached)
  _targetElement;
  _targetBoundary;
  _targetBoundaryScrolled = !0;
  _targetRect;
  _selectables = [];
  _latestElement;
  // Dynamically constructed area rect
  _areaLocation = { y1: 0, x2: 0, y2: 0, x1: 0 };
  _areaRect = Be();
  // If a single click is being performed, it's a single-click until the user dragged the mouse
  _singleClick = !0;
  _frame;
  // Required data for scrolling
  _scrollAvailable = !0;
  _scrollingActive = !1;
  _scrollSpeed = { x: 0, y: 0 };
  _scrollDelta = { x: 0, y: 0 };
  constructor(t) {
    super(), this._options = {
      selectionAreaClass: "selection-area",
      selectionContainerClass: void 0,
      selectables: [],
      document: window.document,
      startAreas: ["html"],
      boundaries: ["html"],
      container: "body",
      mindElixirInstance: void 0,
      // 添加默认值
      ...t,
      behaviour: {
        overlap: "invert",
        intersect: "touch",
        triggers: [0],
        ...t.behaviour,
        startThreshold: t.behaviour?.startThreshold ? typeof t.behaviour.startThreshold == "number" ? t.behaviour.startThreshold : { x: 10, y: 10, ...t.behaviour.startThreshold } : { x: 10, y: 10 },
        scrolling: {
          speedDivider: 10,
          ...t.behaviour?.scrolling,
          startScrollMargins: {
            x: 0,
            y: 0,
            ...t.behaviour?.scrolling?.startScrollMargins
          }
        }
      },
      features: {
        range: !0,
        touch: !0,
        deselectOnBlur: !1,
        ...t.features,
        singleTap: {
          allow: !0,
          intersect: "native",
          ...t.features?.singleTap
        }
      }
    };
    for (const i of Object.getOwnPropertyNames(Object.getPrototypeOf(this)))
      typeof this[i] == "function" && (this[i] = this[i].bind(this));
    const { document: n, selectionAreaClass: o, selectionContainerClass: s } = this._options;
    this._area = n.createElement("div"), this._clippingElement = n.createElement("div"), this._clippingElement.appendChild(this._area), this._area.classList.add(o), s && this._clippingElement.classList.add(s), j(this._area, {
      willChange: "top, left, bottom, right, width, height",
      top: 0,
      left: 0,
      position: "fixed"
    }), j(this._clippingElement, {
      overflow: "hidden",
      position: "fixed",
      transform: "translate3d(0, 0, 0)",
      // https://stackoverflow.com/a/38268846
      pointerEvents: "none",
      zIndex: "1"
    }), this._frame = so((i) => {
      this._recalculateSelectionAreaRect(), this._updateElementSelection(), this._emitEvent("move", i), this._redrawSelectionArea();
    }), this.enable();
  }
  _toggleStartEvents(t = !0) {
    const { document: n } = this._options;
    (t ? F : I)(n, "pointerdown", this._onTapStart);
  }
  _onTapStart(t, n = !1) {
    const { x: o, y: s, target: i } = oe(t), { document: r, startAreas: l, boundaries: a, behaviour: c, features: h } = this._options, d = i.getBoundingClientRect();
    if (!lo(t, c.triggers))
      return;
    const u = K(l, r), p = K(a, r);
    this._targetElement = p.find((g) => We(g.getBoundingClientRect(), d));
    const m = t.composedPath(), x = u.find((g) => m.includes(g));
    if (this._targetBoundary = p.find((g) => m.includes(g)), !this._targetElement || !x || !this._targetBoundary || !n && this._emitEvent("beforestart", t) === !1)
      return;
    this._areaLocation = { x1: o, y1: s, x2: 0, y2: 0 };
    const y = r.scrollingElement ?? r.body;
    this._scrollDelta = { x: y.scrollLeft, y: y.scrollTop }, this._singleClick = !0, this.clearSelection(!1, !0), F(r, ["pointermove"], this._delayedTapMove, { passive: !1 }), F(r, ["pointerup", "pointercancel"], this._onTapStop), F(r, "scroll", this._onScroll), h.deselectOnBlur && (this._targetBoundaryScrolled = !1, F(this._targetBoundary, "scroll", this._onStartAreaScroll));
  }
  _onSingleTap(t) {
    const {
      singleTap: { intersect: n },
      range: o
    } = this._options.features, s = oe(t);
    let i;
    if (n === "native")
      i = s.target;
    else if (n === "touch") {
      this.resolveSelectables();
      const { x: l, y: a } = s;
      i = this._selectables.find((c) => {
        const { right: h, left: d, top: u, bottom: p } = c.getBoundingClientRect();
        return l < h && l > d && a < p && a > u;
      });
    }
    if (!i)
      return;
    for (this.resolveSelectables(); !this._selectables.includes(i); )
      if (i.parentElement)
        i = i.parentElement;
      else {
        this._targetBoundaryScrolled || this.clearSelection();
        return;
      }
    const { stored: r } = this._selection;
    if (this._emitEvent("start", t), t.shiftKey && o && this._latestElement) {
      const l = this._latestElement, [a, c] = l.compareDocumentPosition(i) & 4 ? [i, l] : [l, i], h = [
        ...this._selectables.filter((d) => d.compareDocumentPosition(a) & 4 && d.compareDocumentPosition(c) & 2),
        a,
        c
      ];
      this.select(h), this._latestElement = l;
    } else r.includes(i) && (r.length === 1 || t.ctrlKey || r.every((l) => this._selection.stored.includes(l))) ? this.deselect(i) : (this.select(i), this._latestElement = i);
  }
  _delayedTapMove(t) {
    const {
      container: n,
      document: o,
      behaviour: { startThreshold: s }
    } = this._options, { x1: i, y1: r } = this._areaLocation, { x: l, y: a } = oe(t);
    if (
      // Single number for both coordinates
      typeof s == "number" && B(l + a - (i + r)) >= s || // Different x and y threshold
      typeof s == "object" && B(l - i) >= s.x || B(a - r) >= s.y
    ) {
      if (I(o, ["pointermove"], this._delayedTapMove, { passive: !1 }), this._emitEvent("beforedrag", t) === !1) {
        I(o, ["pointerup", "pointercancel"], this._onTapStop);
        return;
      }
      F(o, ["pointermove"], this._onTapMove, { passive: !1 }), j(this._area, "display", "block"), K(n, o)[0].appendChild(this._clippingElement), this.resolveSelectables(), this._singleClick = !1, this._targetRect = this._targetElement.getBoundingClientRect(), this._scrollAvailable = this._targetElement.scrollHeight !== this._targetElement.clientHeight || this._targetElement.scrollWidth !== this._targetElement.clientWidth, this._scrollAvailable && (this._selectables = this._selectables.filter((c) => this._targetElement.contains(c))), this._setupSelectionArea(), this._emitEvent("start", t), this._onTapMove(t);
    }
    this._handleMoveEvent(t);
  }
  _setupSelectionArea() {
    const { _clippingElement: t, _targetElement: n, _area: o } = this, s = this._targetRect = n.getBoundingClientRect();
    this._scrollAvailable ? (j(t, {
      top: s.top,
      left: s.left,
      width: s.width,
      height: s.height
    }), j(o, {
      marginTop: -s.top,
      marginLeft: -s.left
    })) : (j(t, {
      top: 0,
      left: 0,
      width: "100%",
      height: "100%"
    }), j(o, {
      marginTop: 0,
      marginLeft: 0
    }));
  }
  _onTapMove(t) {
    const { _scrollSpeed: n, _areaLocation: o, _options: s, _frame: i } = this, { speedDivider: r } = s.behaviour.scrolling, { x: l, y: a } = oe(t);
    if (o.x2 = l, o.y2 = a, this._scrollAvailable && !this._scrollingActive && (n.y || n.x)) {
      this._scrollingActive = !0;
      const c = () => {
        if (!n.x && !n.y) {
          this._scrollingActive = !1;
          return;
        }
        const h = this._options.mindElixirInstance;
        if (h && h.move) {
          const d = n.x ? Fe(n.x / r) : 0, u = n.y ? Fe(n.y / r) : 0;
          (d || u) && (h.move(-d, -u), o.x1 -= d, o.y1 -= u);
        }
        i.next(t), requestAnimationFrame(c);
      };
      requestAnimationFrame(c);
    } else
      i.next(t);
    this._handleMoveEvent(t);
  }
  _handleMoveEvent(t) {
    const { features: n } = this._options;
    (n.touch && io() || this._scrollAvailable && ro()) && t.preventDefault();
  }
  _onScroll() {
    const {
      _scrollDelta: t,
      _options: { document: n }
    } = this, { scrollTop: o, scrollLeft: s } = n.scrollingElement ?? n.body;
    this._areaLocation.x1 += t.x - s, this._areaLocation.y1 += t.y - o, t.x = s, t.y = o, this._setupSelectionArea(), this._frame.next(null);
  }
  _onStartAreaScroll() {
    this._targetBoundaryScrolled = !0, I(this._targetElement, "scroll", this._onStartAreaScroll);
  }
  _recalculateSelectionAreaRect() {
    const { _scrollSpeed: t, _areaLocation: n, _targetElement: o, _options: s } = this, i = this._targetRect, { x1: r, y1: l } = n;
    let { x2: a, y2: c } = n;
    const {
      behaviour: {
        scrolling: { startScrollMargins: h }
      }
    } = s;
    a < i.left + h.x ? (t.x = -B(i.left - a + h.x), a = a < i.left ? i.left : a) : a > i.right - h.x ? (t.x = B(i.left + i.width - a - h.x), a = a > i.right ? i.right : a) : t.x = 0, c < i.top + h.y ? (t.y = -B(i.top - c + h.y), c = c < i.top ? i.top : c) : c > i.bottom - h.y ? (t.y = B(i.top + i.height - c - h.y), c = c > i.bottom ? i.bottom : c) : t.y = 0;
    const d = Xe(r, a), u = Xe(l, c), p = Ye(r, a), m = Ye(l, c);
    this._areaRect = Be(d, u, p - d, m - u);
  }
  _redrawSelectionArea() {
    const { x: t, y: n, width: o, height: s } = this._areaRect, { style: i } = this._area;
    i.left = `${t}px`, i.top = `${n}px`, i.width = `${o}px`, i.height = `${s}px`;
  }
  _onTapStop(t, n) {
    const { document: o, features: s } = this._options, { _singleClick: i } = this;
    I(this._targetElement, "scroll", this._onStartAreaScroll), I(o, ["pointermove"], this._delayedTapMove), I(o, ["pointermove"], this._onTapMove), I(o, ["pointerup", "pointercancel"], this._onTapStop), I(o, "scroll", this._onScroll), this._keepSelection(), t && i && s.singleTap.allow ? this._onSingleTap(t) : !i && !n && (this._updateElementSelection(), this._emitEvent("stop", t)), this._scrollSpeed.x = 0, this._scrollSpeed.y = 0, this._clippingElement.remove(), this._frame?.cancel(), j(this._area, "display", "none");
  }
  _updateElementSelection() {
    const { _selectables: t, _options: n, _selection: o, _areaRect: s } = this, { stored: i, selected: r, touched: l } = o, { intersect: a, overlap: c } = n.behaviour, h = c === "invert", d = [], u = [], p = [];
    for (let x = 0; x < t.length; x++) {
      const y = t[x];
      if (We(s, y.getBoundingClientRect(), a)) {
        if (r.includes(y))
          i.includes(y) && !l.includes(y) && l.push(y);
        else if (h && i.includes(y)) {
          p.push(y);
          continue;
        } else
          u.push(y);
        d.push(y);
      }
    }
    h && u.push(...i.filter((x) => !r.includes(x)));
    const m = c === "keep";
    for (let x = 0; x < r.length; x++) {
      const y = r[x];
      !d.includes(y) && !// Check if the user wants to keep previously selected elements, e.g.,
      // not make them part of the current selection as soon as they're touched.
      (m && i.includes(y)) && p.push(y);
    }
    o.selected = d, o.changed = { added: u, removed: p }, this._latestElement = void 0;
  }
  _emitEvent(t, n) {
    return this.emit(t, {
      event: n,
      store: this._selection,
      selection: this
    });
  }
  _keepSelection() {
    const { _options: t, _selection: n } = this, { selected: o, changed: s, touched: i, stored: r } = n, l = o.filter((a) => !r.includes(a));
    switch (t.behaviour.overlap) {
      case "drop": {
        n.stored = [
          ...l,
          ...r.filter((a) => !i.includes(a))
          // Elements not touched
        ];
        break;
      }
      case "invert": {
        n.stored = [
          ...l,
          ...r.filter((a) => !s.removed.includes(a))
          // Elements not removed from selection
        ];
        break;
      }
      case "keep": {
        n.stored = [
          ...r,
          ...o.filter((a) => !r.includes(a))
          // Newly added
        ];
        break;
      }
    }
  }
  /**
   * Manually triggers the start of a selection
   * @param evt A PointerEvent-like object
   * @param silent If beforestart should be fired
   */
  trigger(t, n = !0) {
    this._onTapStart(t, n);
  }
  /**
   * Can be used if during a selection elements have been added
   * Will update everything that can be selected
   */
  resolveSelectables() {
    this._selectables = K(this._options.selectables, this._options.document);
  }
  /**
   * Same as deselecting, but for all elements currently selected
   * @param includeStored If the store should also get cleared
   * @param quiet If move / stop events should be fired
   */
  clearSelection(t = !0, n = !1) {
    const { selected: o, stored: s, changed: i } = this._selection;
    i.added = [], i.removed.push(...o, ...t ? s : []), n || (this._emitEvent("move", null), this._emitEvent("stop", null)), this._selection = Ke(t ? [] : s);
  }
  /**
   * @returns {Array} Selected elements
   */
  getSelection() {
    return this._selection.stored;
  }
  /**
   * @returns {HTMLElement} The selection area element
   */
  getSelectionArea() {
    return this._area;
  }
  /**
   * @returns {Element[]} Available selectable elements for current selection
   */
  getSelectables() {
    return this._selectables;
  }
  /**
   * Set the location of the selection area
   * @param location A partial AreaLocation object
   */
  setAreaLocation(t) {
    Object.assign(this._areaLocation, t), this._redrawSelectionArea();
  }
  /**
   * @returns {AreaLocation} The current location of the selection area
   */
  getAreaLocation() {
    return this._areaLocation;
  }
  /**
   * Cancel the current selection process, pass true to fire a stop event after cancel
   * @param keepEvent If a stop event should be fired
   */
  cancel(t = !1) {
    this._onTapStop(null, !t);
  }
  /**
   * Unbinds all events and removes the area-element.
   */
  destroy() {
    this.cancel(), this.disable(), this._clippingElement.remove(), super.unbindAllListeners();
  }
  /**
   * Enable selecting elements
   */
  enable = this._toggleStartEvents;
  /**
   * Disable selecting elements
   */
  disable = this._toggleStartEvents.bind(this, !1);
  /**
   * Adds elements to the selection
   * @param query CSS Query, can be an array of queries
   * @param quiet If this should not trigger the move event
   */
  select(t, n = !1) {
    const { changed: o, selected: s, stored: i } = this._selection, r = K(t, this._options.document).filter((l) => !s.includes(l) && !i.includes(l));
    return i.push(...r), s.push(...r), o.added.push(...r), o.removed = [], this._latestElement = void 0, n || (this._emitEvent("move", null), this._emitEvent("stop", null)), r;
  }
  /**
   * Removes a particular element from the selection
   * @param query CSS Query, can be an array of queries
   * @param quiet If this should not trigger the move event
   */
  deselect(t, n = !1) {
    const { selected: o, stored: s, changed: i } = this._selection, r = K(t, this._options.document).filter((l) => o.includes(l) || s.includes(l));
    this._selection.stored = s.filter((l) => !r.includes(l)), this._selection.selected = o.filter((l) => !r.includes(l)), this._selection.changed.added = [], this._selection.changed.removed.push(...r.filter((l) => !i.removed.includes(l))), this._latestElement = void 0, n || (this._emitEvent("move", null), this._emitEvent("stop", null));
  }
}
function ao(e) {
  const t = e.mouseSelectionButton === 2 ? [2] : [0], n = new co({
    selectables: [".map-container me-tpc"],
    boundaries: [e.container],
    container: e.selectionContainer,
    mindElixirInstance: e,
    // 传递 MindElixir 实例
    features: {
      touch: !1,
      singleTap: {
        allow: !1
      }
    },
    behaviour: {
      triggers: t,
      // Scroll configuration.
      scrolling: {
        // On scrollable areas the number on px per frame is devided by this amount.
        // Default is 10 to provide a enjoyable scroll experience.
        speedDivider: 10,
        startScrollMargins: { x: 50, y: 50 }
      }
    }
  }).on("beforestart", ({ event: o }) => {
    if (!e.editable || e.spacePressed || e.ptState !== 5) return !1;
    const s = o.target;
    if (s.id === "input-box" || s.className === "circle" || s.className !== "map-container")
      return !1;
    !o.ctrlKey && !o.metaKey && e.clearSelection();
    const i = n.getSelectionArea();
    return i.style.background = "#4f90f22d", i.style.border = "1px solid #4f90f2", i.style.borderRadius = "3px", i.parentElement && (i.parentElement.style.zIndex = "9999"), !0;
  }).on(
    "move",
    ({
      store: {
        changed: { added: o, removed: s }
      }
    }) => {
      if (o.length > 0 || s.length > 0, o.length > 0) {
        const i = o.filter((r) => !e.currentNodes?.includes(r));
        if (i.length > 0) {
          for (const r of i)
            r.className = "selected";
          e.currentNodes = [...e.currentNodes || [], ...i], e.bus.fire(
            "selectNodes",
            i.map((r) => r.nodeObj)
          );
        }
      }
      if (s.length > 0) {
        const i = s.filter((r) => e.currentNodes?.includes(r));
        if (i.length > 0) {
          for (const r of i)
            r.classList.remove("selected");
          e.currentNodes = (e.currentNodes || []).filter((r) => !i.includes(r)), e.bus.fire(
            "unselectNodes",
            i.map((r) => r.nodeObj)
          );
        }
      }
    }
  );
  e.selection = n;
}
const ft = function(e, t, n, o, s = 8) {
  if (e === n) return `M ${e} ${t} V ${o}`;
  const i = (t + o) / 2, r = n > e ? 1 : -1, l = Math.min(s, Math.abs(n - e) / 2, Math.abs(i - t), Math.abs(o - i));
  return `M ${e} ${t} V ${i - l} Q ${e} ${i} ${e + r * l} ${i} H ${n - r * l} Q ${n} ${i} ${n} ${i + l} V ${o}`;
};
function ut({ pT: e, pL: t, pW: n, pH: o, cT: s, cL: i, cW: r, cH: l, direction: a, containerHeight: c, containerWidth: h }) {
  if (a === L.DOWN) {
    const g = t + n / 2, v = i + r / 2, C = e + o;
    return ft(g, C, v, s);
  }
  let d = t + n / 2;
  const u = e + o / 2;
  let p;
  a === L.LHS ? p = i + r : p = i;
  const m = s + l / 2, y = (1 - Math.abs(m - u) / c) * 0.25 * (n / 2);
  return a === L.LHS ? d = d - n / 10 - y : d = d + n / 10 + y, `M ${d} ${u} Q ${d} ${m} ${p} ${m}`;
}
function pt({ pT: e, pL: t, pW: n, pH: o, cT: s, cL: i, cW: r, cH: l, direction: a, isFirst: c }) {
  if (a === L.DOWN) {
    const v = t + n / 2, C = e + o, T = i + r / 2;
    return ft(v, C, T, s);
  }
  const h = parseInt(this.container.style.getPropertyValue("--node-gap-x"));
  let d = 0, u = 0;
  c ? d = e + o / 2 : d = e + o;
  const p = s + l;
  let m = 0, x = 0, y = 0;
  const g = Math.abs(d - p) / 300 * h;
  return a === L.LHS ? (y = t, m = y + h, x = y - h, u = i + h, `M ${m} ${d} C ${y} ${d} ${y + g} ${p} ${x} ${p} H ${u}`) : (y = t + n, m = y - h, x = y + h, u = i + r - h, `M ${m} ${d} C ${y} ${d} ${y - g} ${p} ${x} ${p} H ${u}`);
}
const ho = function(e, t = !0) {
  this.theme = e, this.generateMainBranch = this.theme.generateMainBranch || ut, this.generateSubBranch = this.theme.generateSubBranch || pt;
  const o = {
    ...(this.theme.type === "dark" ? ye : me).cssVar,
    ...this.theme.cssVar
  };
  this.compact && (o["--node-gap-x"] = "15px", o["--node-gap-y"] = "2px", o["--main-gap-x"] = "30px", o["--main-gap-y"] = "6px");
  const s = Object.keys(o);
  for (let i = 0; i < s.length; i++) {
    const r = s[i];
    this.container.style.setProperty(r, o[r]);
  }
  t && this.refresh();
}, fo = function(e) {
  this.compact = e, this.theme && this.changeTheme(this.theme);
}, uo = function(e) {
  return {
    dom: e,
    moved: !1,
    // differentiate click and move
    sessionMoved: !1,
    // whether the current drag session actually moved
    pointerdown: !1,
    lastX: 0,
    lastY: 0,
    handlePointerMove(t) {
      if (this.pointerdown) {
        this.moved = !0, this.sessionMoved = !0;
        const n = t.clientX - this.lastX, o = t.clientY - this.lastY;
        this.lastX = t.clientX, this.lastY = t.clientY, this.cb && this.cb(n, o);
      }
    },
    handlePointerDown(t) {
      t.button === 0 && (this.pointerdown = !0, this.sessionMoved = !1, this.lastX = t.clientX, this.lastY = t.clientY, this.dom.setPointerCapture(t.pointerId));
    },
    handleClear(t) {
      const n = this.pointerdown && this.sessionMoved;
      this.pointerdown = !1, this.sessionMoved = !1, t.pointerId !== void 0 && this.dom.releasePointerCapture(t.pointerId), n && this.onEnd && this.onEnd();
    },
    cb: null,
    onEnd: null,
    init(t, n, o) {
      this.cb = n, this.onEnd = o || null, this.handleClear = this.handleClear.bind(this), this.handlePointerMove = this.handlePointerMove.bind(this), this.handlePointerDown = this.handlePointerDown.bind(this), this.destroy = Ge([
        { dom: t, evt: "pointermove", func: this.handlePointerMove },
        { dom: t, evt: "pointerleave", func: this.handleClear },
        { dom: t, evt: "pointerup", func: this.handleClear },
        { dom: this.dom, evt: "pointerdown", func: this.handlePointerDown }
      ]);
    },
    destroy: null,
    clear() {
      this.moved = !1, this.pointerdown = !1;
    }
  };
}, Ve = {
  create: uo
}, gt = "#4dc4ff";
function mt(e, t, n, o, s, i, r, l) {
  return {
    x: e / 8 + n * 3 / 8 + s * 3 / 8 + r / 8,
    y: t / 8 + o * 3 / 8 + i * 3 / 8 + l / 8
  };
}
function po(e, t, n) {
  e && (e.dataset.x = t.toString(), e.dataset.y = n.toString(), fe(e));
}
function V(e, t, n, o, s) {
  _(e, {
    x1: t + "",
    y1: n + "",
    x2: o + "",
    y2: s + ""
  });
}
function xe(e, t, n, o, s, i, r, l, a, c) {
  const h = `M ${t} ${n} C ${o} ${s} ${i} ${r} ${l} ${a}`;
  e.line.setAttribute("d", h);
  const d = c.style || {};
  e.line.setAttribute("stroke", d.stroke || "rgb(227, 125, 116)"), e.line.setAttribute("stroke-width", String(d.strokeWidth || "2")), e.line.setAttribute("stroke-dasharray", d.strokeDasharray || "8,2"), d.opacity !== void 0 && d.opacity !== null && d.opacity !== "" ? e.line.setAttribute("opacity", String(d.opacity)) : e.line.removeAttribute("opacity");
  const u = e.querySelectorAll('path[stroke="transparent"]');
  u.length > 0 && u[0].setAttribute("d", h);
  const p = ae(i, r, l, a);
  if (p) {
    const g = `M ${p.x1} ${p.y1} L ${l} ${a} L ${p.x2} ${p.y2}`;
    e.arrow1.setAttribute("d", g), u.length > 1 && u[1].setAttribute("d", g), e.arrow1.setAttribute("stroke", d.stroke || "rgb(227, 125, 116)"), e.arrow1.setAttribute("stroke-width", String(d.strokeWidth || "2")), d.opacity !== void 0 && d.opacity !== null && d.opacity !== "" ? e.arrow1.setAttribute("opacity", String(d.opacity)) : e.arrow1.removeAttribute("opacity");
  }
  if (c.bidirectional) {
    const g = ae(o, s, t, n);
    if (g) {
      const v = `M ${g.x1} ${g.y1} L ${t} ${n} L ${g.x2} ${g.y2}`;
      e.arrow2.setAttribute("d", v), u.length > 2 && u[2].setAttribute("d", v);
    }
  } else
    e.arrow2.setAttribute("d", ""), u.length > 2 && u[2].setAttribute("d", "");
  e.arrow2.setAttribute("stroke", d.stroke || "rgb(227, 125, 116)"), e.arrow2.setAttribute("stroke-width", String(d.strokeWidth || "2")), d.opacity !== void 0 && d.opacity !== null && d.opacity !== "" ? e.arrow2.setAttribute("opacity", String(d.opacity)) : e.arrow2.removeAttribute("opacity");
  const { x: m, y: x } = mt(t, n, o, s, i, r, l, a);
  e.labelEl && po(e.labelEl, m, x);
  const y = e.labelEl;
  y && (y.style.color = d.labelColor || "rgb(235, 95, 82)"), wo(e);
}
function q(e, t, n) {
  const { offsetLeft: o, offsetTop: s } = $(e.nodes, t), i = t.offsetWidth, r = t.offsetHeight, l = o + i / 2, a = s + r / 2, c = l + n.x, h = a + n.y;
  return {
    w: i,
    h: r,
    cx: l,
    cy: a,
    ctrlX: c,
    ctrlY: h
  };
}
function R(e) {
  const t = e.w / 2, n = e.h / 2, o = e.ctrlX - e.cx, s = e.ctrlY - e.cy, i = Math.hypot(o, s);
  if (i === 0 || t === 0 && n === 0)
    return { x: e.cx, y: e.cy };
  const r = o / i, l = s / i, a = Math.min(t / Math.abs(r), n / Math.abs(l));
  return { x: e.cx + r * a, y: e.cy + l * a };
}
const yt = function(e, t, n) {
  const o = $(e.nodes, t), s = $(e.nodes, n), i = o.offsetLeft + t.offsetWidth / 2, r = o.offsetTop + t.offsetHeight / 2, l = s.offsetLeft + n.offsetWidth / 2, a = s.offsetTop + n.offsetHeight / 2, c = l - i, h = a - r, d = Math.sqrt(c * c + h * h), u = Math.max(50, Math.min(200, d * 0.3)), p = Math.abs(c), m = Math.abs(h);
  let x, y;
  if (d < 150) {
    const v = t.closest("me-main"), C = v ? v.className === "lhs" ? -1 : 1 : c > 0 ? -1 : 1;
    x = { x: 200 * C, y: 0 }, y = { x: 200 * C, y: 0 };
  } else if (p > m * 1.5) {
    const v = c > 0 ? t.offsetWidth / 2 : -t.offsetWidth / 2, C = c > 0 ? -n.offsetWidth / 2 : n.offsetWidth / 2;
    x = { x: v + (c > 0 ? u : -u), y: 0 }, y = { x: C + (c > 0 ? -u : u), y: 0 };
  } else if (m > p * 1.5) {
    const v = h > 0 ? t.offsetHeight / 2 : -t.offsetHeight / 2, C = h > 0 ? -n.offsetHeight / 2 : n.offsetHeight / 2;
    x = { x: 0, y: v + (h > 0 ? u : -u) }, y = { x: 0, y: C + (h > 0 ? -u : u) };
  } else {
    const v = Math.atan2(h, c), C = t.offsetWidth / 2 * Math.cos(v), T = t.offsetHeight / 2 * Math.sin(v), D = -(n.offsetWidth / 2) * Math.cos(v), f = -(n.offsetHeight / 2) * Math.sin(v), b = u * 0.7 * (c > 0 ? 1 : -1), w = u * 0.7 * (h > 0 ? 1 : -1);
    x = { x: C + b, y: T + w }, y = { x: D - b, y: f - w };
  }
  return {
    delta1: { x: Math.round(x.x), y: Math.round(x.y) },
    delta2: { x: Math.round(y.x), y: Math.round(y.y) }
  };
}, _e = function(e, t, n, o, s) {
  if (!t || !n)
    return;
  if (!o.delta1 || !o.delta2) {
    const E = yt(e, t, n);
    o.delta1 = E.delta1, o.delta2 = E.delta2;
  }
  const i = q(e, t, o.delta1), r = q(e, n, o.delta2), { x: l, y: a } = R(i), { ctrlX: c, ctrlY: h } = i, { ctrlX: d, ctrlY: u } = r, { x: p, y: m } = R(r), x = ae(d, u, p, m);
  if (!x) return;
  const y = `M ${x.x1} ${x.y1} L ${p} ${m} L ${x.x2} ${x.y2}`;
  let g = "";
  if (o.bidirectional) {
    const E = ae(c, h, l, a);
    if (!E) return;
    g = `M ${E.x1} ${E.y1} L ${l} ${a} L ${E.x2} ${E.y2}`;
  }
  const v = Bn(`M ${l} ${a} C ${c} ${h} ${d} ${u} ${p} ${m}`, y, g, o.style), { x: C, y: T } = mt(l, a, c, h, d, u, p, m), D = o.style?.labelColor || "rgb(235, 95, 82)", f = "a-" + o.id;
  v.id = f;
  const b = e.markdown ? e.markdown(o.label, o) : o.label, w = le(b, C, T, {
    anchor: "middle",
    color: D,
    dataType: "arrow",
    svgId: f
  });
  v.labelEl = w, v.arrowObj = o, v.dataset.linkid = o.id, e.labelContainer.appendChild(w), e.arrowSvg.appendChild(v), fe(w), s || (e.arrows.push(o), e.currentArrow = v, vt(e, o, i, r));
}, go = function(e, t, n = {}) {
  const o = {
    id: X(),
    label: "Custom Link",
    from: e.nodeObj.id,
    to: t.nodeObj.id,
    ...n
  };
  _e(this, e, t, o), this.bus.fire("operation", {
    name: "createArrow",
    obj: o
  });
}, mo = function(e) {
  ue(this);
  const t = { ...e, id: X() };
  _e(this, this.findEle(t.from), this.findEle(t.to), t), this.bus.fire("operation", {
    name: "createArrow",
    obj: t
  });
}, yo = function(e) {
  let t;
  if (e ? t = e : t = this.currentArrow, !t) return;
  ue(this);
  const n = t.arrowObj.id;
  this.arrows = this.arrows.filter((o) => o.id !== n), t.labelEl?.remove(), t.remove(), this.bus.fire("operation", {
    name: "removeArrow",
    obj: {
      id: n
    }
  });
}, bo = function(e) {
  this.currentArrow = e;
  const t = e.arrowObj, n = this.findEle(t.from), o = this.findEle(t.to), s = q(this, n, t.delta1), i = q(this, o, t.delta2);
  this.editable ? vt(this, t, s, i) : bt(e, gt), this.bus.fire("selectArrow", t);
}, vo = function() {
  ue(this), this.currentArrow = null, this.bus.fire("unselectArrow");
}, pe = function(e, t) {
  const n = document.createElementNS(H, "path");
  return _(n, {
    d: e,
    stroke: t,
    fill: "none",
    "stroke-width": "6",
    "stroke-linecap": "round",
    "stroke-linejoin": "round"
  }), n;
}, bt = function(e, t) {
  const n = document.createElementNS(H, "g");
  n.setAttribute("class", "arrow-highlight"), n.setAttribute("opacity", "0.45");
  const o = pe(e.line.getAttribute("d"), t);
  n.appendChild(o);
  const s = pe(e.arrow1.getAttribute("d"), t);
  if (n.appendChild(s), e.arrow2.getAttribute("d")) {
    const i = pe(e.arrow2.getAttribute("d"), t);
    n.appendChild(i);
  }
  e.insertBefore(n, e.firstChild);
}, xo = function(e) {
  const t = e.querySelector(".arrow-highlight");
  t && t.remove();
}, wo = function(e) {
  const t = e.querySelector(".arrow-highlight");
  if (!t) return;
  const n = t.querySelectorAll("path");
  n.length >= 1 && n[0].setAttribute("d", e.line.getAttribute("d")), n.length >= 2 && n[1].setAttribute("d", e.arrow1.getAttribute("d")), n.length >= 3 && e.arrow2.getAttribute("d") && n[2].setAttribute("d", e.arrow2.getAttribute("d"));
}, ue = function(e) {
  e.helper1?.destroy(), e.helper2?.destroy(), e.linkController.style.display = "none", e.P2.style.display = "none", e.P3.style.display = "none", e.currentArrow && xo(e.currentArrow);
}, vt = function(e, t, n, o) {
  const { linkController: s, P2: i, P3: r, line1: l, line2: a, nodes: c, map: h, currentArrow: d, bus: u } = e;
  if (!d) return;
  s.style.display = "initial", i.style.display = "initial", r.style.display = "initial", c.appendChild(s), c.appendChild(i), c.appendChild(r), bt(d, gt);
  let { x: p, y: m } = R(n), { ctrlX: x, ctrlY: y } = n, { ctrlX: g, ctrlY: v } = o, { x: C, y: T } = R(o);
  i.style.cssText = `top:${y}px;left:${x}px;`, r.style.cssText = `top:${v}px;left:${g}px;`, V(l, p, m, x, y), V(a, g, v, C, T), e.helper1 = Ve.create(i), e.helper2 = Ve.create(r);
  let D = G(t);
  const f = () => {
    u.fire("operation", {
      name: "reshapeArrow",
      obj: t,
      origin: D
    }), D = G(t);
  };
  e.helper1.init(
    h,
    (b, w) => {
      x = x + b / e.scaleVal, y = y + w / e.scaleVal;
      const E = R({ ...n, ctrlX: x, ctrlY: y });
      p = E.x, m = E.y, i.style.top = y + "px", i.style.left = x + "px", xe(d, p, m, x, y, g, v, C, T, t), V(l, p, m, x, y), t.delta1.x = Math.round(x - n.cx), t.delta1.y = Math.round(y - n.cy), u.fire("updateArrowDelta", t);
    },
    f
  ), e.helper2.init(
    h,
    (b, w) => {
      g = g + b / e.scaleVal, v = v + w / e.scaleVal;
      const E = R({ ...o, ctrlX: g, ctrlY: v });
      C = E.x, T = E.y, r.style.top = v + "px", r.style.left = g + "px", xe(d, p, m, x, y, g, v, C, T, t), V(a, g, v, C, T), t.delta2.x = Math.round(g - o.cx), t.delta2.y = Math.round(v - o.cy), u.fire("updateArrowDelta", t);
    },
    f
  );
};
function Eo() {
  this.arrowSvg.innerHTML = "", this.labelContainer.querySelectorAll('.svg-label[data-type="arrow"]').forEach((t) => t.remove());
  for (let t = 0; t < this.arrows.length; t++) {
    const n = this.arrows[t];
    try {
      _e(this, this.findEle(n.from), this.findEle(n.to), n, !0);
    } catch {
    }
  }
  this.nodes.appendChild(this.arrowSvg);
}
function Co(e) {
  ue(this), e && e.labelEl && at(this, e.labelEl, e.arrowObj);
}
function So() {
  this.arrows = this.arrows.filter((e) => ce(e.from, this.nodeData) && ce(e.to, this.nodeData));
}
const No = function(e, t) {
  const n = G(e);
  n.style && t.style && (t.style = Object.assign({}, n.style, t.style)), Object.assign(e, t);
  const o = this.arrowSvg.querySelector(`g[data-linkid="${e.id}"]`);
  if (o) {
    if (t.label !== void 0 && o.labelEl) {
      const r = this.markdown ? this.markdown(e.label, e) : e.label;
      o.labelEl.innerHTML = r;
    }
    const s = this.findEle(e.from), i = this.findEle(e.to);
    if (s && i) {
      if (!e.delta1 || !e.delta2) {
        const y = yt(this, s, i);
        e.delta1 = e.delta1 || y.delta1, e.delta2 = e.delta2 || y.delta2;
      }
      const r = q(this, s, e.delta1), l = q(this, i, e.delta2), { x: a, y: c } = R(r), { ctrlX: h, ctrlY: d } = r, { ctrlX: u, ctrlY: p } = l, { x: m, y: x } = R(l);
      xe(o, a, c, h, d, u, p, m, x, e), this.currentArrow?.arrowObj?.id === e.id && (this.P2.style.cssText = `top:${d}px;left:${h}px;`, this.P3.style.cssText = `top:${p}px;left:${u}px;`, V(this.line1, a, c, h, d), V(this.line2, u, p, m, x));
    }
  }
  this.bus.fire("operation", {
    name: "reshapeArrow",
    obj: e,
    origin: n
  });
}, To = /* @__PURE__ */ Object.freeze(/* @__PURE__ */ Object.defineProperty({
  __proto__: null,
  createArrow: go,
  createArrowFrom: mo,
  editArrowLabel: Co,
  removeArrow: yo,
  renderArrow: Eo,
  reshapeArrow: No,
  selectArrow: bo,
  tidyArrow: So,
  unselectArrow: vo
}, Symbol.toStringTag, { value: "Module" })), Do = function(e) {
  if (e.length === 0) throw new Error("No selected node.");
  if (e.length === 1) {
    const a = e[0].nodeObj, c = e[0].nodeObj.parent;
    if (!c) throw new Error("Can not select root node.");
    const h = c.children.findIndex((d) => a === d);
    return {
      parent: c.id,
      start: h,
      end: h
    };
  }
  let t = 0;
  const n = e.map((a) => {
    let c = a.nodeObj;
    const h = [];
    for (; c.parent; ) {
      const d = c.parent, p = d.children?.indexOf(c);
      c = d, h.unshift({ node: c, index: p });
    }
    return h.length > t && (t = h.length), h;
  });
  let o = 0;
  e: for (; o < t; o++) {
    const a = n[0][o]?.node;
    for (let c = 1; c < n.length; c++)
      if (n[c][o]?.node !== a)
        break e;
  }
  if (!o) throw new Error("Can not select root node.");
  const s = n.map((a) => a[o - 1].index).sort((a, c) => a - c), i = s[0] || 0, r = s[s.length - 1] || 0, l = n[0][o - 1].node;
  if (!l.parent) throw new Error("Please select nodes in the same main topic.");
  return {
    parent: l.id,
    start: i,
    end: r
  };
}, Mo = function(e) {
  const t = document.createElementNS(H, "g");
  return t.setAttribute("id", e), t;
}, ge = function(e, t) {
  const n = document.createElementNS(H, "path");
  return _(n, {
    d: e,
    stroke: t || "#666",
    fill: "none",
    "stroke-linecap": "round",
    "stroke-width": "2"
  }), n;
}, _o = (e) => e.parentElement.parentElement, xt = function(e, t) {
  const n = e.summaries.findIndex((o) => o.id === t);
  return n === -1 ? !1 : (e.summaries.splice(n, 1), e.nodes.querySelector("#s-" + t)?.remove(), e.nodes.querySelector("#label-s-" + t)?.remove(), !0);
}, Lo = function(e, { parent: t, start: n }) {
  const o = e.findEle(t), s = o.nodeObj;
  let i;
  return s.parent ? i = o.closest("me-main").className : i = e.findEle(s.children[n].id).closest("me-main").className, i;
}, Le = function(e, t) {
  const { id: n, label: o, parent: s, start: i, end: r, style: l } = t, { nodes: a, theme: c, summarySvg: h } = e, u = e.findEle(s).nodeObj, p = Lo(e, t);
  let m = 1 / 0, x = 0, y = 0, g = 0, v = 0, C = 1 / 0, T = 0;
  for (let N = i; N <= r; N++) {
    const A = u.children?.[N];
    if (!A)
      return null;
    const P = _o(e.findEle(A.id)), { offsetLeft: O, offsetTop: Q } = $(a, P), ee = i === r ? 10 : 20;
    N === i && (y = Q + ee), N === r && (g = Q + P.offsetHeight - ee), N === i && (C = O + ee), N === r && (T = O + P.offsetWidth - ee), Q + P.offsetHeight > v && (v = Q + P.offsetHeight), O < m && (m = O), P.offsetWidth + O > x && (x = P.offsetWidth + O);
  }
  let D, f;
  const b = l?.stroke || c.cssVar["--color"], w = l?.labelColor || c.cssVar["--color"], E = "s-" + n, S = e.markdown ? e.markdown(o, t) : o;
  if (p === L.DOWN) {
    const N = v + 10, A = (C + T) / 2;
    D = ge(`M ${C} ${N - 10} c 0 5 5 10 10 10 L ${T - 10} ${N} c 5 0 10 -5 10 -10 M ${A} ${N} v 10`, b), f = le(S, A, N + 20, { anchor: "middle", color: w, dataType: "summary", svgId: E });
  } else {
    const N = u.parent ? 10 : 0, A = y + N, P = g + N, O = (A + P) / 2;
    p === L.LHS ? (D = ge(`M ${m + 10} ${A} c -5 0 -10 5 -10 10 L ${m} ${P - 10} c 0 5 5 10 10 10 M ${m} ${O} h -10`, b), f = le(S, m - 20, O, { anchor: "end", color: w, dataType: "summary", svgId: E })) : (D = ge(`M ${x - 10} ${A} c 5 0 10 5 10 10 L ${x} ${P - 10} c 0 5 -5 10 -10 10 M ${x} ${O} h 10`, b), f = le(S, x + 20, O, { anchor: "start", color: w, dataType: "summary", svgId: E }));
  }
  const M = Mo(E);
  return M.appendChild(D), e.labelContainer.appendChild(f), fe(f), M.summaryObj = t, M.labelEl = f, h.appendChild(M), M;
}, ko = function(e = {}) {
  if (!this.currentNodes) return;
  const { currentNodes: t, summaries: n, bus: o } = this, { parent: s, start: i, end: r } = Do(t), l = { id: X(), parent: s, start: i, end: r, label: "summary", style: e.style }, a = Le(this, l);
  n.push(l), this.editSummary(a), o.fire("operation", {
    name: "createSummary",
    obj: l
  });
}, Ao = function(e) {
  const t = X(), n = { ...e, id: t };
  Le(this, n), this.summaries.push(n), this.bus.fire("operation", {
    name: "createSummary",
    obj: n
  });
}, Po = function(e) {
  xt(this, e) && this.bus.fire("operation", {
    name: "removeSummary",
    obj: { id: e }
  });
}, Oo = function(e) {
  const t = e.labelEl;
  t && t.classList.add("selected"), this.currentSummary = e, this.bus.fire("selectSummary", e.summaryObj);
}, $o = function() {
  this.currentSummary?.labelEl?.classList.remove("selected"), this.currentSummary = null, this.bus.fire("unselectSummary");
}, Ho = function() {
  this.summarySvg.innerHTML = "";
  const e = [];
  this.summaries.forEach((t) => {
    try {
      Le(this, t) === null && e.push(t.id);
    } catch {
    }
  }), e.forEach((t) => xt(this, t)), this.nodes.insertAdjacentElement("beforeend", this.summarySvg);
}, Io = function(e) {
  e && e.labelEl && at(this, e.labelEl, e.summaryObj);
}, jo = /* @__PURE__ */ Object.freeze(/* @__PURE__ */ Object.defineProperty({
  __proto__: null,
  createSummary: ko,
  createSummaryFrom: Ao,
  editSummary: Io,
  removeSummary: Po,
  renderSummary: Ho,
  selectSummary: Oo,
  unselectSummary: $o
}, Symbol.toStringTag, { value: "Module" })), k = "http://www.w3.org/2000/svg";
function Ro(e, t) {
  const n = document.createElementNS(k, "svg");
  return _(n, {
    version: "1.1",
    xmlns: k,
    height: e,
    width: t
  }), n;
}
function Bo(e, t) {
  return (parseInt(e) - parseInt(t)) / 2;
}
function Wo(e, t, n, o) {
  const s = document.createElementNS(k, "g");
  let i = "";
  return e.text ? i = e.text.textContent : i = e.childNodes[0].textContent, i.split(`
`).forEach((l, a) => {
    const c = document.createElementNS(k, "text");
    _(c, {
      x: n + parseInt(t.paddingLeft) + "",
      y: o + parseInt(t.paddingTop) + Bo(t.lineHeight, t.fontSize) * (a + 1) + parseFloat(t.fontSize) * (a + 1) + "",
      "text-anchor": "start",
      "font-family": t.fontFamily,
      "font-size": `${t.fontSize}`,
      "font-weight": `${t.fontWeight}`,
      fill: `${t.color}`
    }), c.innerHTML = l, s.appendChild(c);
  }), s;
}
function Yo(e, t, n, o) {
  let s = "";
  e.nodeObj?.dangerouslySetInnerHTML ? s = e.nodeObj.dangerouslySetInnerHTML : e.text ? s = e.text.textContent : s = e.childNodes[0].textContent;
  const i = document.createElementNS(k, "foreignObject");
  _(i, {
    x: n + parseInt(t.paddingLeft) + "",
    y: o + parseInt(t.paddingTop) + "",
    width: t.width,
    height: t.height
  });
  const r = document.createElement("div");
  return _(r, {
    xmlns: "http://www.w3.org/1999/xhtml",
    style: `font-family: ${t.fontFamily}; font-size: ${t.fontSize}; font-weight: ${t.fontWeight}; color: ${t.color}; white-space: pre-wrap;`
  }), r.innerHTML = s, i.appendChild(r), i;
}
function Xo(e, t) {
  const n = getComputedStyle(t), { offsetLeft: o, offsetTop: s } = $(e.nodes, t), i = document.createElementNS(k, "rect");
  return _(i, {
    x: o + "",
    y: s + "",
    rx: n.borderRadius,
    ry: n.borderRadius,
    width: n.width,
    height: n.height,
    fill: n.backgroundColor,
    stroke: n.borderColor,
    "stroke-width": n.borderWidth
  }), i;
}
function se(e, t, n = !1) {
  const o = getComputedStyle(t), { offsetLeft: s, offsetTop: i } = $(e.nodes, t), r = document.createElementNS(k, "rect");
  _(r, {
    x: s + "",
    y: i + "",
    rx: o.borderRadius,
    ry: o.borderRadius,
    width: o.width,
    height: o.height,
    fill: o.backgroundColor,
    stroke: o.borderColor,
    "stroke-width": o.borderWidth
  });
  const l = document.createElementNS(k, "g");
  l.appendChild(r);
  let a;
  return n ? a = Yo(t, o, s, i) : a = Wo(t, o, s, i), l.appendChild(a), l;
}
function Fo(e, t) {
  const n = getComputedStyle(t), { offsetLeft: o, offsetTop: s } = $(e.nodes, t), i = document.createElementNS(k, "a"), r = document.createElementNS(k, "text");
  return _(r, {
    x: o + "",
    y: s + parseInt(n.fontSize) + "",
    "text-anchor": "start",
    "font-family": n.fontFamily,
    "font-size": `${n.fontSize}`,
    "font-weight": `${n.fontWeight}`,
    fill: `${n.color}`
  }), r.innerHTML = t.textContent, i.appendChild(r), i.setAttribute("href", t.href), i;
}
function Ko(e, t) {
  const n = getComputedStyle(t), { offsetLeft: o, offsetTop: s } = $(e.nodes, t), i = document.createElementNS(k, "image");
  return _(i, {
    x: o + "",
    y: s + "",
    width: n.width + "",
    height: n.height + "",
    href: t.src
  }), i;
}
const ie = 100, Vo = '<?xml version="1.0" standalone="no"?><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">', zo = (e, t = !1) => {
  const n = e.nodes, o = n.offsetHeight + ie * 2, s = n.offsetWidth + ie * 2, i = Ro(o + "px", s + "px"), r = document.createElementNS(k, "svg"), l = document.createElementNS(k, "rect");
  _(l, {
    x: "0",
    y: "0",
    width: `${s}`,
    height: `${o}`,
    fill: e.theme.cssVar["--bgcolor"]
  }), i.appendChild(l), n.querySelectorAll(".subLines").forEach((d) => {
    const u = d.cloneNode(!0), { offsetLeft: p, offsetTop: m } = $(n, d.parentElement);
    u.setAttribute("x", `${p}`), u.setAttribute("y", `${m}`), r.appendChild(u);
  });
  const a = n.querySelector(".lines")?.cloneNode(!0);
  a && r.appendChild(a);
  const c = n.querySelector(".topiclinks")?.cloneNode(!0);
  c && r.appendChild(c);
  const h = n.querySelector(".summary")?.cloneNode(!0);
  return h && r.appendChild(h), n.querySelectorAll("me-tpc").forEach((d) => {
    d.nodeObj.dangerouslySetInnerHTML ? r.appendChild(se(e, d, !t)) : (r.appendChild(Xo(e, d)), r.appendChild(se(e, d.text, !t)));
  }), n.querySelectorAll(".tags > span").forEach((d) => {
    r.appendChild(se(e, d));
  }), n.querySelectorAll(".icons > span").forEach((d) => {
    r.appendChild(se(e, d));
  }), n.querySelectorAll(".hyper-link").forEach((d) => {
    r.appendChild(Fo(e, d));
  }), n.querySelectorAll("img").forEach((d) => {
    r.appendChild(Ko(e, d));
  }), _(r, {
    x: ie + "",
    y: ie + "",
    overflow: "visible"
  }), i.appendChild(r), i;
}, Go = (e, t) => (t && e.insertAdjacentHTML("afterbegin", "<style>" + t + "</style>"), Vo + e.outerHTML);
function qo(e) {
  return new Promise((t, n) => {
    const o = new FileReader();
    o.onload = (s) => {
      t(s.target.result);
    }, o.onerror = (s) => {
      n(s);
    }, o.readAsDataURL(e);
  });
}
const Uo = function(e = !1, t) {
  const n = zo(this, e), o = Go(n, t);
  return new Blob([o], { type: "image/svg+xml" });
}, Jo = async function(e = !1, t) {
  const n = this.exportSvg(e, t), o = await qo(n);
  return new Promise((s, i) => {
    const r = new Image();
    r.setAttribute("crossOrigin", "anonymous"), r.onload = () => {
      const l = document.createElement("canvas");
      l.width = r.width, l.height = r.height, l.getContext("2d").drawImage(r, 0, 0), l.toBlob(s, "image/png", 1);
    }, r.src = o, r.onerror = i;
  });
}, Zo = /* @__PURE__ */ Object.freeze(/* @__PURE__ */ Object.defineProperty({
  __proto__: null,
  exportPng: Jo,
  exportSvg: Uo
}, Symbol.toStringTag, { value: "Module" }));
function Qo(e, t) {
  return async function(...n) {
    const o = this.before[t];
    o && !await o.apply(this, n) || e.apply(this, n);
  };
}
const ze = Object.keys(ot), wt = {};
for (let e = 0; e < ze.length; e++) {
  const t = ze[e];
  wt[t] = Qo(ot[t], t);
}
const es = {
  getObjById: ce,
  generateNewObj: Et,
  layout: Lt,
  linkDiv: Wn,
  editTopic: It,
  createWrapper: Pt,
  createParent: Ot,
  createChildren: $t,
  createTopic: Ht,
  findEle: Je,
  changeTheme: ho,
  changeCompact: fo,
  ...Mn,
  ...wt,
  ...To,
  ...jo,
  ...Zo,
  init(e) {
    if (e = JSON.parse(JSON.stringify(e)), !e || !e.nodeData) return new Error("MindElixir: `data` is required");
    e.direction !== void 0 && (this.direction = e.direction), e.compact !== void 0 && (this.compact = e.compact), this.changeTheme(e.theme || this.theme, !1), e.meta && (this.meta = e.meta), this.nodeData = e.nodeData, Y(this.nodeData), this.arrows = e.arrows || [], this.summaries = e.summaries || [], this.tidyArrow(), this.toolBar && no(this), this.keypress && In(this, this.keypress), ao(this), this.disposable.push(_t()), this.contextMenu && this.disposable.push(Xn(this, this.contextMenu)), this.allowUndo && this.disposable.push(Kn(this)), this.layout(), this.linkDiv(), this.toCenter();
  },
  destroy() {
    this.disposable.forEach((e) => e()), this.el && (this.el.innerHTML = ""), this.el = void 0, this.nodeData = void 0, this.arrows = void 0, this.summaries = void 0, this.currentArrow = void 0, this.currentNodes = void 0, this.currentSummary = void 0, this.theme = void 0, this.direction = void 0, this.bus = void 0, this.container = void 0, this.map = void 0, this.lines = void 0, this.linkController = void 0, this.arrowSvg = void 0, this.P2 = void 0, this.P3 = void 0, this.line1 = void 0, this.line2 = void 0, this.nodes = void 0, this.selection?.destroy(), this.selection = void 0;
  },
  /**
   * @public
   * @param {boolean} enable
   */
  enableMobileMultiSelect(e) {
    this.mobileMultiSelect = e;
  }
}, ts = "5.15.1";
function ns(e) {
  return {
    x: 0,
    y: 0,
    moved: !1,
    // differentiate click and move
    mousedown: !1,
    handlePointerDown(t) {
      this.moved = !1;
      const n = t.target, o = e.mouseSelectionButton === 0 ? 2 : 0, s = e.spacePressed && t.button === 0 && t.pointerType === "mouse", i = !e.editable || t.button === o && t.pointerType === "mouse" || t.pointerType === "touch";
      !s && !i || (this.x = t.clientX, this.y = t.clientY, n.className !== "circle" && n.contentEditable !== "plaintext-only" && (this.mousedown = !0, n.setPointerCapture(t.pointerId)));
    },
    handlePointerMove(t) {
      if (!this.mousedown || t.target.contentEditable === "plaintext-only" && !e.spacePressed) return !1;
      const n = t.clientX - this.x, o = t.clientY - this.y;
      return this.x = t.clientX, this.y = t.clientY, this.moved = !0, e.move(n, o), !0;
    },
    handlePointerUp(t) {
      if (!this.mousedown) return;
      const n = t.target;
      n.hasPointerCapture && n.hasPointerCapture(t.pointerId) && n.releasePointerCapture(t.pointerId), this.mousedown = !1;
    },
    clear() {
      this.mousedown = !1, this.moved = !1;
    }
  };
}
class os {
  static LEFT = 0;
  static RIGHT = 1;
  static SIDE = 2;
  static DOWN = 3;
  static THEME = me;
  static DARK_THEME = ye;
  /**
   * @memberof MindElixir
   * @static
   */
  static version = ts;
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
  static E = Je;
  /**
   * @function new
   * @memberof MindElixir
   * @static
   * @param {String} topic root topic
   */
  static new = (t) => ({
    nodeData: {
      id: X(),
      topic: t || "new topic",
      children: []
    }
  });
  // #endregion GENERATED
  get currentNode() {
    return this.currentNodes[this.currentNodes.length - 1];
  }
  constructor({
    el: t,
    direction: n,
    editable: o,
    contextMenu: s,
    toolBar: i,
    keypress: r,
    mouseSelectionButton: l,
    selectionContainer: a,
    before: c,
    newTopicName: h,
    allowUndo: d,
    generateMainBranch: u,
    generateSubBranch: p,
    overflowHidden: m,
    compact: x,
    theme: y,
    alignment: g,
    scaleSensitivity: v,
    scaleMax: C,
    scaleMin: T,
    handleWheel: D,
    markdown: f,
    imageProxy: b,
    pasteHandler: w,
    mobileMultiSelect: E
  }) {
    let S = null;
    const M = Object.prototype.toString.call(t);
    if (M === "[object HTMLDivElement]" ? S = t : M === "[object String]" && (S = document.querySelector(t)), !S) throw new Error("MindElixir: el is not a valid element");
    S.style.position = "relative", S.innerHTML = "", this.el = S, this.disposable = [], this.before = c || {}, this.newTopicName = h || "New Node", this.contextMenu = s ?? !0, this.toolBar = i ?? !0, this.keypress = r ?? !0, this.mouseSelectionButton = l ?? 0, this.direction = n ?? 1, this.editable = o ?? !0, this.allowUndo = d ?? !0, this.scaleSensitivity = v ?? 0.1, this.scaleMax = C ?? 1.4, this.scaleMin = T ?? 0.2, this.generateMainBranch = u || ut, this.generateSubBranch = p || pt, this.overflowHidden = m ?? !1, this.compact = x ?? !1, this.alignment = g ?? "root", this.handleWheel = D ?? !0, this.markdown = f || void 0, this.imageProxy = b || void 0, this.currentNodes = [], this.currentArrow = null, this.scaleVal = 1, this.tempDirection = null, this.mobileMultiSelect = E ?? !1, this.panHelper = ns(this), this.bus = Rn(), this.container = document.createElement("div"), this.selectionContainer = a || this.container, this.container.className = "map-container";
    const N = window.matchMedia("(prefers-color-scheme: dark)");
    this.theme = y || (N.matches ? ye : me);
    const A = document.createElement("div");
    A.className = "map-canvas", this.map = A, this.container.setAttribute("tabindex", "0"), this.container.appendChild(this.map), this.el.appendChild(this.container), this.nodes = document.createElement("me-nodes"), this.lines = U("lines"), this.summarySvg = U("summary"), this.linkController = U("linkcontroller"), this.P2 = document.createElement("div"), this.P3 = document.createElement("div"), this.P2.className = this.P3.className = "circle", this.P2.style.display = this.P3.style.display = "none", this.line1 = je(), this.line2 = je(), this.linkController.appendChild(this.line1), this.linkController.appendChild(this.line2), this.arrowSvg = U("topiclinks"), this.labelContainer = document.createElement("div"), this.labelContainer.className = "label-container", this.map.appendChild(this.nodes), this.overflowHidden ? this.container.style.overflow = "hidden" : this.disposable.push(jn(this)), w && (this.pasteHandler = w);
  }
}
Object.assign(os.prototype, es);
export {
  ye as DARK_THEME,
  ls as DOWN,
  ss as LEFT,
  is as RIGHT,
  rs as SIDE,
  me as THEME,
  os as default
};
