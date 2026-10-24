// FloeAndroid shared/Sources/FloeBrowser — isolated-world DOM probe source and
// trusted expression builders.
//
// Android mirror of the iOS original `BrowserTaskSession.protocolProbeSource`
// (BrowserTaskSessionStore.swift @ 3fd597b…, see original-snapshot/). The probe
// runs the SAME code on both platforms; only the delivery differs:
//  * iOS: WKUserScript at document start inside a named WKContentWorld +
//    `callAsyncJavaScript(_, arguments:)`.
//  * Android: document-start injection where the WebView build supports it,
//    otherwise re-injection at every page commit; expressions are built here
//    as single evaluateJavascript payloads with every embedded value
//    JSON-escaped. The actuator payload is constructed ONLY from whitelisted,
//    already-admitted typed actions — never from page text or model JSON.
//
// The probe maintains stable per-document node references and a small
// lifecycle/DOM queue, and deliberately exposes no arbitrary JavaScript
// evaluation endpoint (snapshot/perform/status/drainEvents only, exactly the
// original four).

import Foundation

public enum BrowserProbeScript {

    // MARK: - Install source (semantics preserved from the original)

    public static let installSource = #"""
    (() => {
      if (globalThis.__floeProtocol) return;
      let documentID = '';
      let revision = 0;
      let nextRef = 1;
      let lastMutation = performance.now();
      const references = new WeakMap();
      const nodesByRef = new Map();
      const events = [];
      const selector = 'a,button,input,textarea,select,[role],[contenteditable="true"],[onclick],summary,label,h1,h2,h3,p';

      const push = (method, detail = null) => {
        events.push({method, detail, revision});
        if (events.length > 128) events.splice(0, events.length - 128);
      };
      const setDocument = id => {
        if (id && documentID !== id) documentID = id;
      };
      const roots = () => {
        const result = [document];
        const visit = root => {
          let all = [];
          try { all = Array.from(root.querySelectorAll('*')); } catch (_) {}
          for (const el of all) {
            if (el.shadowRoot) { result.push(el.shadowRoot); visit(el.shadowRoot); }
            if ((el.tagName || '').toLowerCase() === 'iframe') {
              try { if (el.contentDocument) { result.push(el.contentDocument); visit(el.contentDocument); } } catch (_) {}
            }
          }
        };
        visit(document);
        return result;
      };
      const visible = el => {
        try {
          const rect = el.getBoundingClientRect();
          const style = getComputedStyle(el);
          return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
        } catch (_) { return false; }
      };
      const ensureRef = el => {
        let ref = references.get(el);
        if (!ref) {
          if (nodesByRef.size >= 2048) {
            for (const [key, node] of nodesByRef) if (!node?.isConnected) nodesByRef.delete(key);
            while (nodesByRef.size >= 2048) nodesByRef.delete(nodesByRef.keys().next().value);
          }
          ref = `n${nextRef++}`;
          references.set(el, ref);
          nodesByRef.set(ref, el);
        }
        return ref;
      };
      const findByRef = ref => {
        const found = nodesByRef.get(ref);
        return found?.isConnected ? found : null;
      };
      const allNodes = () => {
        const seen = new Set();
        const output = [];
        for (const root of roots()) {
          let candidates = [];
          try { candidates = Array.from(root.querySelectorAll(selector)); } catch (_) {}
          for (const el of candidates) {
            if (seen.has(el) || !visible(el)) continue;
            seen.add(el);
            output.push(el);
            if (output.length >= 400) return output;
          }
        }
        return output;
      };
      const serialize = el => {
        const rect = el.getBoundingClientRect();
        const type = (el.type || '').toLowerCase();
        const role = el.getAttribute('role') || (el.tagName || '').toLowerCase();
        const password = type === 'password' || (el.autocomplete || '').toLowerCase() === 'current-password';
        return {
          ref: ensureRef(el), role,
          name: String(el.getAttribute('aria-label') || el.title || '').slice(0, 300),
          text: password ? '' : String(el.innerText || el.textContent || '').trim().slice(0, 500),
          value: password ? null : (el.value == null ? null : String(el.value).slice(0, 500)),
          state: {disabled: !!el.disabled, checked: !!el.checked, selected: !!el.selected},
          bounds: {x:rect.x, y:rect.y, width:rect.width, height:rect.height}
        };
      };
      const snapshot = (id, cursor, limit) => {
        setDocument(id);
        const nodes = allNodes();
        const start = Math.max(0, Number(cursor) || 0);
        const count = Math.min(50, Math.max(1, Number(limit) || 40));
        const end = Math.min(nodes.length, start + count);
        return {
          revision,
          viewportWidth: Math.max(1, Number(window.innerWidth) || 1),
          viewportHeight: Math.max(1, Number(window.innerHeight) || 1),
          nodes: nodes.slice(start, end).map(serialize),
          nextCursor: end < nodes.length ? end : null
        };
      };
      const perform = (operation, target, expectedDocumentID, text, submit, visualFallbackReason) => {
        setDocument(expectedDocumentID);
        if (target.kind === 'element' && target.documentID !== documentID) return {status:'stale'};
        const el = target.kind === 'element'
          ? findByRef(target.ref)
          : document.elementFromPoint(Number(target.x), Number(target.y));
        if (!el || !el.isConnected) return {status:'stale'};
        if (operation === 'click') {
          if (target.kind === 'point' && visualFallbackReason === 'noStructuredTarget') {
            let structured = null;
            try { structured = el.closest(selector); } catch (_) {}
            const structuredTag = String((structured && structured.tagName) || '').toLowerCase();
            // A canvas can be observable as one structured DOM node while
            // containing many visual-only controls. browser.click on the
            // canvas ref cannot address those internal targets, so preserve
            // coordinate fallback for this exact boundary.
            if (structured && visible(structured) && structuredTag !== 'canvas') {
              return {status:'structured', ref:ensureRef(structured)};
            }
          }
          // A fresh screenshot point is already viewport-relative. Scrolling
          // its hit element before dispatch changes the coordinate and was
          // the main source of intermittent misses on long pages.
          if (target.kind === 'element') {
            el.scrollIntoView({block:'center', inline:'center'});
          }
          const rect = el.getBoundingClientRect();
          const x = target.kind === 'point' ? Number(target.x) : rect.x + rect.width / 2;
          const y = target.kind === 'point' ? Number(target.y) : rect.y + rect.height / 2;
          for (const type of ['pointerover','pointerenter','pointerdown','pointerup']) {
            try { el.dispatchEvent(new PointerEvent(type, {bubbles:true, cancelable:true, clientX:x, clientY:y, pointerType:'mouse', isPrimary:true})); } catch (_) {}
          }
          if (target.kind === 'point') {
            // HTMLElement.click() manufactures a click at (0,0), which is
            // unusable for canvas hit-testing. Preserve the evidence-backed
            // viewport coordinates on the actual click event.
            el.dispatchEvent(new MouseEvent('click', {bubbles:true, cancelable:true, clientX:x, clientY:y, view:window}));
          } else {
            el.click();
          }
          return {status:'ok'};
        }
        const tag = (el.tagName || '').toLowerCase();
        const inputType = (el.type || '').toLowerCase();
        if (inputType === 'password' || (el.autocomplete || '').toLowerCase() === 'current-password') return {status:'needsUser'};
        if (!(tag === 'input' || tag === 'textarea' || el.isContentEditable)) return {status:'blocked'};
        el.focus();
        if (el.isContentEditable) {
          el.textContent = text;
        } else {
          const prototype = tag === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
          if (setter) setter.call(el, text); else el.value = text;
        }
        try { el.dispatchEvent(new InputEvent('beforeinput', {bubbles:true, inputType:'insertText', data:text})); } catch (_) {}
        el.dispatchEvent(new Event('input', {bubbles:true}));
        el.dispatchEvent(new Event('change', {bubbles:true}));
        if (submit) {
          el.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', code:'Enter', bubbles:true}));
          if (el.form?.requestSubmit) el.form.requestSubmit();
          el.dispatchEvent(new KeyboardEvent('keyup', {key:'Enter', code:'Enter', bubbles:true}));
        }
        return {status:'ok'};
      };
      const status = (id, query, expectedText) => {
        setDocument(id);
        let selectorFound = false;
        if (query) {
          for (const root of roots()) {
            try { if (root.querySelector(query)) { selectorFound = true; break; } } catch (_) {}
          }
        }
        const bodyText = expectedText ? String(document.body?.innerText || '') : '';
        return {
          readyState: document.readyState,
          selectorFound,
          textFound: !!expectedText && bodyText.includes(expectedText),
          idleMilliseconds: Math.max(0, performance.now() - lastMutation),
          revision
        };
      };
      const drainEvents = id => { setDocument(id); return events.splice(0, events.length); };

      new MutationObserver(records => {
        if (!records.length) return;
        revision += 1;
        lastMutation = performance.now();
        push('DOM.documentUpdated');
      }).observe(document, {subtree:true, childList:true, attributes:true, characterData:true});
      document.addEventListener('DOMContentLoaded', () => push('Page.domContentEventFired'), {once:true});
      addEventListener('load', () => push('Page.loadEventFired'), {once:true});
      addEventListener('hashchange', () => push('Page.navigatedWithinDocument'));
      addEventListener('popstate', () => push('Page.navigatedWithinDocument'));
      globalThis.__floeProtocol = {snapshot, perform, status, drainEvents};
      push('Runtime.executionContextCreated');
    })();
    """#

    // MARK: - Expression builders (trusted inputs only)

    /// JSON string literal escaping for embedding Swift strings into a
    /// JavaScript expression. Guarantees a valid JSON lexeme and additionally
    /// escapes the JS Unicode line separators.
    public static func jsStringLiteral(_ value: String) -> String {
        var literal: String
        if let data = try? JSONEncoder().encode(value), let encoded = String(data: data, encoding: .utf8) {
            literal = encoded
        } else {
            // A String always encodes; this fallback keeps the builder total
            // but errs closed to an empty literal rather than raw text.
            literal = "\"\""
        }
        literal = literal
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return literal
    }

    /// Semantic DOM snapshot expression (bounded page slice; returns JSON).
    public static func observeExpression(documentID: String, cursor: Int, limit: Int) -> String {
        let safeCursor = max(0, cursor)
        let safeLimit = min(50, max(1, limit))
        return """
        (() => { const p = globalThis.__floeProtocol;
          if (!p) return JSON.stringify({revision:0,viewportWidth:Math.max(1,Number(window.innerWidth)||1),viewportHeight:Math.max(1,Number(window.innerHeight)||1),nodes:[],nextCursor:null});
          return JSON.stringify(p.snapshot(\(jsStringLiteral(documentID)), \(safeCursor), \(safeLimit)));
        })()
        """
    }

    /// Wait-condition probe expression.
    public static func statusExpression(documentID: String, selector: String, text: String) -> String {
        """
        (() => { const p = globalThis.__floeProtocol;
          if (!p) return JSON.stringify({readyState:'loading',selectorFound:false,textFound:false,idleMilliseconds:0,revision:0});
          return JSON.stringify(p.status(\(jsStringLiteral(documentID)), \(jsStringLiteral(selector)), \(jsStringLiteral(text))));
        })()
        """
    }

    /// Drain of the probe's in-page event queue (bounded to 128 in-page).
    public static func drainEventsExpression(documentID: String) -> String {
        """
        (() => { const p = globalThis.__floeProtocol;
          return p ? JSON.stringify(p.drainEvents(\(jsStringLiteral(documentID)))) : '[]';
        })()
        """
    }

    /// Viewport scroll. Only finite bounded doubles are embedded; nothing
    /// page-derived reaches this builder.
    public static func scrollExpression(deltaX: Double, deltaY: Double) -> String {
        guard deltaX.isFinite, deltaY.isFinite else { return "void 0" }
        return "window.scrollBy(\(deltaX), \(deltaY)); 'ok'"
    }

    /// Actuator payload for one admitted action. The target object is
    /// constructed from the whitelisted typed enum; `text` is escaped and the
    /// session has already enforced its 16 KiB bound before calling this.
    public static func performExpression(
        operation: String,
        target: BrowserTarget,
        documentID: String,
        text: String,
        submit: Bool,
        visualFallbackReason: String?
    ) -> String {
        let targetLiteral: String
        switch target {
        case .element(let ref, let targetDocumentID):
            targetLiteral = "{\"kind\":\"element\",\"ref\":\(jsStringLiteral(ref)),\"documentID\":\(jsStringLiteral(targetDocumentID))}"
        case .point(let x, let y):
            guard x.isFinite, y.isFinite else { return "'{\"status\":\"blocked\"}'" }
            targetLiteral = "{\"kind\":\"point\",\"x\":\(x),\"y\":\(y)}"
        case .visualText:
            // Visual-text references must be resolved into a point from
            // screenshot evidence BEFORE any actuator payload is built. The
            // session enforces this; the builder refuses the raw form.
            return "'{\"status\":\"blocked\"}'"
        }
        return """
        (() => { const p = globalThis.__floeProtocol;
          if (!p) return JSON.stringify({status:'stale'});
          return JSON.stringify(p.perform(\(jsStringLiteral(operation)), \(targetLiteral), \(jsStringLiteral(documentID)), \(jsStringLiteral(text)), \(submit ? "true" : "false"), \(jsStringLiteral(visualFallbackReason ?? ""))));
        })()
        """
    }
}
