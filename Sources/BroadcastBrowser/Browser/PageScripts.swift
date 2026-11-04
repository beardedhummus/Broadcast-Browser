import Foundation

/// JavaScript injected into every tab (main frame).
enum PageScripts {
    /// JSON-encodes a Swift string into a JavaScript string literal.
    static func literal(_ string: String) -> String {
        if let data = try? JSONEncoder().encode(string), let json = String(data: data, encoding: .utf8) {
            return json
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        }
        return "\"\""
    }

    static func core(css: String) -> String {
        coreTemplate.replacingOccurrences(of: "__BB_CSS__", with: literal(css))
    }

    static func customJS(_ code: String) -> String {
        """
        (function () {
          try {
        \(code)
          } catch (e) { console.error('[Broadcast Browser] custom script error', e); }
        })();
        """
    }

    private static let coreTemplate = #"""
    (function () {
      if (window.__bb) { return; }
      var STYLE_ID = '__bb_custom_style';
      var css = __BB_CSS__;
      var post = function (msg) {
        try { window.webkit.messageHandlers.bb.postMessage(msg); } catch (e) {}
      };
      var bb = {};
      Object.defineProperty(window, '__bb', { value: bb, configurable: false, enumerable: false, writable: false });

      // ---- Style injection -------------------------------------------------
      function styleParent() { return document.head || document.documentElement; }
      function ensureStyle(moveToEnd) {
        var parent = styleParent();
        if (!parent) { return; }
        var el = document.getElementById(STYLE_ID);
        if (!el) {
          el = document.createElement('style');
          el.id = STYLE_ID;
          el.setAttribute('data-broadcast-browser', '');
        }
        if (el.textContent !== css) { el.textContent = css; }
        if (!el.isConnected || (moveToEnd && parent.lastElementChild !== el)) { parent.appendChild(el); }
      }
      ensureStyle(true);
      var queued = false;
      var observer = new MutationObserver(function () {
        if (queued) { return; }
        var el = document.getElementById(STYLE_ID);
        if (el && el.isConnected) { return; }
        queued = true;
        setTimeout(function () { queued = false; ensureStyle(true); }, 0);
      });
      function observe() {
        try {
          observer.observe(document.documentElement, { childList: true });
          if (document.head) { observer.observe(document.head, { childList: true }); }
        } catch (e) {}
      }
      observe();
      document.addEventListener('DOMContentLoaded', function () { ensureStyle(true); observe(); });
      window.addEventListener('load', function () { ensureStyle(true); });
      bb.setCSS = function (text) { css = text; ensureStyle(true); return true; };

      // ---- Selectors -------------------------------------------------------
      function esc(s) {
        return (window.CSS && CSS.escape) ? CSS.escape(s) : String(s).replace(/([^a-zA-Z0-9_-])/g, '\\$1');
      }
      function isUnique(sel) {
        try { return document.querySelectorAll(sel).length === 1; } catch (e) { return false; }
      }
      function goodId(id) {
        return !!id && /^[A-Za-z][\w-]*$/.test(id) && !/\d{4,}/.test(id) && id.length < 64;
      }
      function stableClasses(el) {
        return Array.prototype.filter.call(el.classList || [], function (c) {
          return c.length < 40 && !/^(css|sc|jsx|svelte|emotion|tw)-/i.test(c) && !/[0-9a-f]{6,}/i.test(c) &&
            !/\d{4,}/.test(c) && c.charAt(0) !== '_' && c.indexOf(':') < 0 && c.indexOf('[') < 0;
        });
      }
      function classSelector(el) {
        var cls = stableClasses(el).slice(0, 3);
        return el.tagName.toLowerCase() + (cls.length ? '.' + cls.map(esc).join('.') : '');
      }
      function uniqueSelector(el) {
        if (!el || el.nodeType !== 1) { return ''; }
        if (goodId(el.id) && isUnique('#' + esc(el.id))) { return '#' + esc(el.id); }
        var parts = [];
        var cur = el;
        while (cur && cur.nodeType === 1 && cur !== document.documentElement) {
          if (cur !== el && goodId(cur.id) && isUnique('#' + esc(cur.id))) {
            parts.unshift('#' + esc(cur.id));
            return parts.join(' > ');
          }
          var part = cur.tagName.toLowerCase();
          var cls = stableClasses(cur).slice(0, 2);
          if (cls.length) { part += '.' + cls.map(esc).join('.'); }
          var parent = cur.parentElement;
          if (parent) {
            var tag = cur.tagName;
            var same = Array.prototype.filter.call(parent.children, function (c) { return c.tagName === tag; });
            if (same.length > 1) { part += ':nth-of-type(' + (same.indexOf(cur) + 1) + ')'; }
          }
          parts.unshift(part);
          var sel = parts.join(' > ');
          if (isUnique(sel)) { return sel; }
          cur = parent;
        }
        return parts.join(' > ');
      }

      // ---- Element info ----------------------------------------------------
      var PROPS = ['font-family', 'font-size', 'font-weight', 'font-style', 'color', 'background-color',
        'line-height', 'letter-spacing', 'text-align', 'text-transform', 'text-shadow', 'opacity',
        'display', 'padding', 'margin', 'border-radius', 'width', 'height'];
      function rectOf(el) {
        var r = el.getBoundingClientRect();
        return { x: r.left, y: r.top, w: r.width, h: r.height };
      }
      function labelOf(el) {
        var s = el.tagName.toLowerCase();
        if (el.id) { s += '#' + el.id; }
        var c = stableClasses(el).slice(0, 2);
        if (c.length) { s += '.' + c.join('.'); }
        var r = el.getBoundingClientRect();
        return s + '  ' + Math.round(r.width) + '×' + Math.round(r.height);
      }
      function info(el, sel) {
        var cs = getComputedStyle(el);
        var style = {};
        PROPS.forEach(function (p) { style[p] = cs.getPropertyValue(p); });
        var csel = classSelector(el);
        var count = 0;
        try { count = document.querySelectorAll(csel).length; } catch (e) {}
        return {
          selector: sel, classSelector: csel, matchCount: count,
          tag: el.tagName.toLowerCase(), id: el.id || '',
          classes: Array.prototype.slice.call(el.classList || []),
          text: (el.innerText || el.textContent || '').trim().slice(0, 120),
          rect: rectOf(el), style: style, label: labelOf(el)
        };
      }

      // ---- Picker ------------------------------------------------------------
      var picking = false, hoverEl = null, selectedEl = null;
      function swallow(e) {
        e.preventDefault(); e.stopPropagation();
        if (e.stopImmediatePropagation) { e.stopImmediatePropagation(); }
      }
      function selectEl(el) {
        selectedEl = el;
        var i = info(el, uniqueSelector(el));
        post({ type: 'select', info: i });
        return i;
      }
      function onMove(e) {
        if (!picking) { return; }
        var el = e.target;
        if (!el || el.nodeType !== 1 || el === hoverEl) { return; }
        hoverEl = el;
        post({ type: 'hover', rect: rectOf(el), label: labelOf(el) });
      }
      function onClick(e) {
        if (!picking) { return; }
        swallow(e);
        var el = e.target;
        if (el && el.nodeType === 1) { selectEl(el); }
        bb.stopPicking();
      }
      function onBlock(e) { if (picking) { swallow(e); } }
      function onKey(e) {
        if (picking && e.key === 'Escape') { swallow(e); bb.stopPicking(); }
      }
      var BLOCKED = ['mousedown', 'mouseup', 'pointerdown', 'pointerup', 'dblclick', 'contextmenu', 'auxclick'];
      bb.startPicking = function () {
        if (picking) { return true; }
        picking = true;
        hoverEl = null;
        window.addEventListener('mousemove', onMove, true);
        window.addEventListener('click', onClick, true);
        BLOCKED.forEach(function (t) { window.addEventListener(t, onBlock, true); });
        window.addEventListener('keydown', onKey, true);
        return true;
      };
      bb.stopPicking = function () {
        if (!picking) { return true; }
        picking = false;
        window.removeEventListener('mousemove', onMove, true);
        window.removeEventListener('click', onClick, true);
        BLOCKED.forEach(function (t) { window.removeEventListener(t, onBlock, true); });
        window.removeEventListener('keydown', onKey, true);
        post({ type: 'pickEnd' });
        return true;
      };
      bb.select = function (sel) {
        try {
          var el = document.querySelector(sel);
          if (!el) { return false; }
          selectedEl = el;
          post({ type: 'select', info: info(el, sel) });
          return true;
        } catch (e) { return false; }
      };
      bb.selectParent = function () {
        if (selectedEl && selectedEl.parentElement && selectedEl.parentElement !== document.documentElement) {
          selectEl(selectedEl.parentElement);
          return true;
        }
        return false;
      };
      bb.selectAtPoint = function (x, y) {
        var el = document.elementFromPoint(x, y);
        if (el) { selectEl(el); return true; }
        return false;
      };
      bb.refreshSelection = function () {
        if (selectedEl && selectedEl.isConnected) { post({ type: 'select', info: info(selectedEl, uniqueSelector(selectedEl)) }); }
      };
      bb.clearSelection = function () { selectedEl = null; post({ type: 'clear' }); return true; };
      bb.matchRects = function (sel) {
        try { return Array.prototype.slice.call(document.querySelectorAll(sel), 0, 300).map(rectOf); }
        catch (e) { return []; }
      };
      var rectQueued = false;
      function onViewportChange() {
        if (rectQueued) { return; }
        rectQueued = true;
        setTimeout(function () {
          rectQueued = false;
          if (selectedEl && selectedEl.isConnected) { post({ type: 'selRect', rect: rectOf(selectedEl) }); }
        }, 40);
      }
      window.addEventListener('scroll', onViewportChange, true);
      window.addEventListener('resize', onViewportChange, true);

      // ---- Input from the canvas view in the main window ----------------------
      // Scrolling: dispatch a wheel event, then scroll the nearest scrollable box.
      bb.wheel = function (x, y, dx, dy) {
        var el = document.elementFromPoint(x, y) || document.scrollingElement || document.documentElement;
        var ev = new WheelEvent('wheel', { deltaX: dx, deltaY: dy, deltaMode: 0, clientX: x, clientY: y, bubbles: true, cancelable: true });
        if (el && !el.dispatchEvent(ev)) { return true; }
        var node = el;
        while (node && node !== document.body && node !== document.documentElement) {
          var cs = getComputedStyle(node);
          var canY = dy !== 0 && /(auto|scroll|overlay)/.test(cs.overflowY) && node.scrollHeight > node.clientHeight + 1 &&
            ((dy > 0 && node.scrollTop + node.clientHeight < node.scrollHeight - 1) || (dy < 0 && node.scrollTop > 0));
          var canX = dx !== 0 && /(auto|scroll|overlay)/.test(cs.overflowX) && node.scrollWidth > node.clientWidth + 1 &&
            ((dx > 0 && node.scrollLeft + node.clientWidth < node.scrollWidth - 1) || (dx < 0 && node.scrollLeft > 0));
          if (canX || canY) { node.scrollBy(dx, dy); return true; }
          node = node.parentElement;
        }
        window.scrollBy(dx, dy);
        return true;
      };

      // <select> lists: the native popup would open next to the off-screen
      // canvas window, so the app shows its own menu instead.
      var selectCounter = 0;
      document.addEventListener('mousedown', function (e) {
        if (picking) { return; }
        var el = e.target && e.target.closest ? e.target.closest('select') : null;
        if (!el || el.disabled || el.multiple || el.size > 1) { return; }
        e.preventDefault();
        el.focus();
        var id = el.getAttribute('data-bb-select');
        if (!id) { id = 's' + (++selectCounter); el.setAttribute('data-bb-select', id); }
        var options = Array.prototype.map.call(el.options, function (o, i) {
          var group = o.parentElement && o.parentElement.tagName === 'OPTGROUP' ? o.parentElement.label : '';
          return { i: i, label: o.label || o.text, disabled: o.disabled, group: group };
        });
        post({ type: 'selectMenu', id: id, options: options, selected: el.selectedIndex, rect: rectOf(el) });
      }, true);
      bb.chooseOption = function (id, index) {
        var el = document.querySelector('select[data-bb-select="' + id + '"]');
        if (!el) { return false; }
        el.selectedIndex = index;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      };

      // Hover: mouseover/out, mouseenter/leave and mousemove at a point, the way
      // a real pointer would produce them.
      var hoverTarget = null;
      function chain(el) {
        var list = [];
        while (el) { list.push(el); el = el.parentElement; }
        return list;
      }
      bb.hover = function (x, y) {
        var el = (x < 0 || y < 0) ? null : document.elementFromPoint(x, y);
        var init = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, view: window };
        if (el !== hoverTarget) {
          var oldChain = chain(hoverTarget), newChain = chain(el);
          if (hoverTarget) {
            hoverTarget.dispatchEvent(new PointerEvent('pointerout', Object.assign({ relatedTarget: el }, init)));
            hoverTarget.dispatchEvent(new MouseEvent('mouseout', Object.assign({ relatedTarget: el }, init)));
          }
          oldChain.forEach(function (node) {
            if (newChain.indexOf(node) < 0) {
              node.dispatchEvent(new PointerEvent('pointerleave', { bubbles: false, clientX: x, clientY: y, relatedTarget: el }));
              node.dispatchEvent(new MouseEvent('mouseleave', { bubbles: false, clientX: x, clientY: y, relatedTarget: el }));
            }
          });
          if (el) {
            el.dispatchEvent(new PointerEvent('pointerover', Object.assign({ relatedTarget: hoverTarget }, init)));
            el.dispatchEvent(new MouseEvent('mouseover', Object.assign({ relatedTarget: hoverTarget }, init)));
          }
          newChain.slice().reverse().forEach(function (node) {
            if (oldChain.indexOf(node) < 0) {
              node.dispatchEvent(new PointerEvent('pointerenter', { bubbles: false, clientX: x, clientY: y, relatedTarget: hoverTarget }));
              node.dispatchEvent(new MouseEvent('mouseenter', { bubbles: false, clientX: x, clientY: y, relatedTarget: hoverTarget }));
            }
          });
          hoverTarget = el;
        }
        if (el) {
          el.dispatchEvent(new PointerEvent('pointermove', init));
          el.dispatchEvent(new MouseEvent('mousemove', init));
        }
        return true;
      };

      // Mouse cursor shape under the pointer.
      var lastCursor = '';
      function cursorFor(el) {
        if (!el || el.nodeType !== 1) { return 'default'; }
        var c = getComputedStyle(el).cursor;
        if (c && c !== 'auto') { return c; }
        if (el.isContentEditable || /^(INPUT|TEXTAREA)$/.test(el.tagName)) { return 'text'; }
        if (el.closest && el.closest('a[href], button, [role=button], select, summary, label[for]')) { return 'pointer'; }
        return 'default';
      }
      window.addEventListener('mousemove', function (e) {
        var c = picking ? 'crosshair' : cursorFor(e.target);
        if (c !== lastCursor) { lastCursor = c; post({ type: 'cursor', value: c }); }
      }, true);

      // What's under the pointer, for the app's right-click menu.
      bb.contextInfo = function (x, y) {
        var el = document.elementFromPoint(x, y);
        var a = el && el.closest ? el.closest('a[href]') : null;
        var img = el && el.tagName === 'IMG' ? (el.currentSrc || el.src) : '';
        var editable = !!(el && (el.isContentEditable || /^(INPUT|TEXTAREA)$/.test(el.tagName)));
        return { link: a ? a.href : '', image: img || '', selection: String(window.getSelection() || '').slice(0, 500), editable: editable };
      };

      // ---- Misc --------------------------------------------------------------
      bb.favicon = function () {
        var l = document.querySelector('link[rel~="icon"], link[rel="shortcut icon"], link[rel="apple-touch-icon"]');
        if (l && l.href) { return l.href; }
        return location.protocol.indexOf('http') === 0 ? location.origin + '/favicon.ico' : '';
      };
      bb.viewport = function () {
        return { w: window.innerWidth, h: window.innerHeight, dpr: window.devicePixelRatio, sx: window.scrollX, sy: window.scrollY };
      };
    })();
    """#
}
