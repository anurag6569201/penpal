//
//  CodeBlockView.swift
//  penpal
//
//  An embedded "coded" asset that lives *inside* an ink page. It renders a
//  live HTML/CSS/JS block (a graph, a widget, anything the web can draw) and
//  sits behind the handwriting so ink and Penpal replies annotate on top.
//
//  It STAYS behind the ink even while being used: a finger tap makes it the
//  page's active block, and the canvas then redirects touches into it past
//  the ink layer. Nothing moves, so an annotation drawn across the block
//  remains visible while its buttons are being pressed. A pencil approaching
//  the block, or a tap elsewhere, stands it back down.
//
//  In normal mode it is chrome-less — no border, background or shadow — so it
//  reads as part of the page. In the page's *edit mode* it shows a dashed
//  outline plus corner handles and a small toolbar, and can be moved, resized,
//  edited (its code) and deleted. This is the "asset inside the page" model:
//  drop as many as you like and arrange them freely.
//

import UIKit
import WebKit
import SwiftUI

// MARK: - On-page asset (UIKit)

final class CodeBlockView: UIView, UIGestureRecognizerDelegate, WKNavigationDelegate,
                           WKScriptMessageHandler {

    /// Documents loaded with `baseURL: nil` get a NULL origin: WebKit then
    /// refuses storage, denies resource loads ("Couldn't open … Permission
    /// denied") and disables anything needing a secure context. A block that
    /// renders a real simulation needs a real origin, and `https://localhost`
    /// gives it one without touching the network.
    static let contentBaseURL = URL(string: "https://localhost/")

    static let editingBridgeJavaScript = """
    (() => {
      const doc = document;
      const rootEl = doc.documentElement;
      const bodyEl = doc.body;

      // CONTENT ROOT — the ONLY node that is ever serialized back to the note.
      // Every editing surface (toolbars, inspectors) is injected at runtime as
      // a SIBLING of this node, so the app chrome never leaks into the saved
      // HTML. Legacy blocks (whose content sat directly in <body>) get wrapped
      // once here, which round-trips identically.
      let content = doc.getElementById('penpal-content');
      if (!content) {
        content = doc.createElement('div');
        content.id = 'penpal-content';
        while (bodyEl.firstChild) { content.appendChild(bodyEl.firstChild); }
        bodyEl.appendChild(content);
      }

      // KIND — drives which chrome to build.
      const kindEl = content.querySelector('[data-penpal-kind]');
      const kind = (kindEl && kindEl.getAttribute('data-penpal-kind'))
        || (content.querySelector('table') ? 'table'
          : content.querySelector('input[type=checkbox]') ? 'checklist'
          : content.querySelector('.mermaid') ? 'mermaid'
          : content.querySelector('img') ? 'image' : 'code');
      rootEl.setAttribute('data-penpal-kind', kind);

      // MODE — view (clean page) | arrange | studio. CSS hides all chrome in
      // view mode, so out of Arrange the block reads as plain paper.
      let mode = 'view';
      window.penpalSetMode = (m) => {
        mode = m || 'view';
        rootEl.setAttribute('data-penpal-mode', mode);
      };
      rootEl.setAttribute('data-penpal-mode', mode);

      // SINGLE-TAP INLINE EDIT — when the page wakes a block it forwards the
      // tap point here so the very same tap drops a caret into the text the
      // user aimed at (a table cell, a checklist label, a paragraph) and
      // starts editing, with no separate "edit" step. Taps that land on a
      // control (checkbox, button, link) are left alone so they still work.
      const editableAncestor = (node) => {
        let el = (node && node.nodeType === 3) ? node.parentElement : node;
        while (el && el !== content) {
          if (el.isContentEditable) return el;
          el = el.parentElement;
        }
        return null;
      };
      window.penpalBeginEdit = (x, y) => {
        const hit = doc.elementFromPoint(x, y);
        if (!hit) return false;
        // Never hijack a real control — let it do its own thing.
        if (hit.closest('input,button,select,textarea,a,[data-pp-cmd]')) return false;
        const target = editableAncestor(hit);
        if (!target) return false;
        target.focus({ preventScroll: true });
        // Drop the caret exactly where the user tapped when possible.
        const range = doc.caretRangeFromPoint ? doc.caretRangeFromPoint(x, y) : null;
        if (range) {
          const sel = window.getSelection();
          sel.removeAllRanges();
          sel.addRange(range);
        }
        return true;
      };

      // Chrome styles live in <head> and are never persisted.
      const runtimeStyle = doc.createElement('style');
      runtimeStyle.id = 'penpal-runtime-style';
      runtimeStyle.textContent = `
        #penpal-content { min-height: 100%; box-sizing: border-box; }
        /* Editing in place should feel like writing on paper — no browser focus
           ring on cells, list labels or any editable text. */
        #penpal-content [contenteditable]:focus,
        #penpal-content [contenteditable]:focus-visible,
        #penpal-content td:focus, #penpal-content th:focus,
        #penpal-content .penpal-item-text:focus { outline: none; box-shadow: none; }
        /* Media blocks size their content to the frame, so the wrapper must
           carry a definite height for percentage-height children (img). */
        [data-penpal-kind="image"] #penpal-content,
        [data-penpal-kind="mermaid"] #penpal-content { height: 100%; }
        /* Editing chrome only ever appears in the focused Studio. On the page
           the block stays clean — you format in the Studio, which has the room
           to make the controls feel like a real app rather than a cramped bar. */
        .pp-chrome { display: none; }
        [data-penpal-mode="studio"] #penpal-content {
          max-width: 720px; margin: 0 auto; padding: 24px 24px 120px;
        }
        [data-penpal-mode="studio"] .pp-toolbar {
          display: flex; position: sticky; top: 0; z-index: 9999;
          flex-wrap: wrap; gap: 8px; align-items: center;
          padding: 12px 16px; margin: 0;
          background: rgba(250,250,253,0.97);
          -webkit-backdrop-filter: saturate(180%) blur(20px);
          backdrop-filter: saturate(180%) blur(20px);
          border-bottom: 1px solid rgba(80,80,95,0.10);
          font: 600 15px -apple-system, "SF Pro Text", sans-serif;
          -webkit-user-select: none; user-select: none;
        }
        .pp-group {
          display: flex; align-items: center; gap: 2px; padding: 3px;
          border-radius: 12px; background: rgba(120,120,140,0.10);
        }
        .pp-btn {
          min-width: 38px; height: 38px; padding: 0 10px; border: 0;
          border-radius: 10px; background: transparent; color: #3a3a45;
          font-size: 16px; line-height: 1; cursor: pointer;
          display: inline-flex; align-items: center; justify-content: center; gap: 3px;
        }
        .pp-btn:hover { background: rgba(120,120,140,0.12); }
        .pp-btn:active, .pp-btn.pp-on {
          background: #fff; color: #4A4E9E; box-shadow: 0 1px 2px rgba(0,0,0,0.14);
        }
        .pp-btn svg { width: 19px; height: 19px; fill: none; stroke: currentColor;
          stroke-width: 1.9; stroke-linecap: round; stroke-linejoin: round; }
        .pp-btn svg .fill { fill: currentColor; stroke: none; }
        .pp-btn svg text { fill: currentColor; stroke: none; font: 700 8px -apple-system, sans-serif; }
        .pp-chev { width: 12px !important; height: 12px !important; opacity: 0.45; margin-left: -1px; }
        .pp-a { font-weight: 800; }
        .pp-btn .pp-bar { position: absolute; bottom: 6px; width: 17px; height: 3px;
          border-radius: 2px; background: #4A4E9E; }
        .pp-btn[data-pp-pop="fore"] { position: relative; }
        .pp-select {
          height: 38px; border-radius: 11px; padding: 0 12px;
          border: 1px solid rgba(80,80,95,0.16); background: rgba(255,255,255,0.9);
          color: #2a2a33; font: 600 15px -apple-system, sans-serif; cursor: pointer;
        }
        .pp-menu-wrap { position: relative; display: inline-flex; }
        .pp-pop {
          position: absolute; top: 48px; left: 0; z-index: 2147483000; display: none;
          padding: 12px; border-radius: 16px; background: #fff;
          box-shadow: 0 14px 44px rgba(0,0,0,0.18); border: 1px solid rgba(0,0,0,0.06);
        }
        /* Right-side controls open toward the left so the panel can't spill off
           the edge of the sheet and appear clipped. */
        .pp-pop-right { left: auto; right: 0; }
        .pp-pop.pp-open { display: block; }
        .pp-linkrow { display: flex; gap: 8px; align-items: center; }
        .pp-input { width: 210px; height: 36px; border-radius: 10px; padding: 0 12px;
          border: 1px solid rgba(80,80,95,0.22); background: #fff; color: #2a2a33;
          font: 500 15px -apple-system, sans-serif; }
        .pp-apply { height: 36px; padding: 0 16px; border: 0; border-radius: 10px;
          background: #4A4E9E; color: #fff; font: 700 15px -apple-system, sans-serif;
          cursor: pointer; }
        .pp-slider { display: flex; align-items: center; justify-content: space-between;
          gap: 14px; padding: 7px 4px; font-size: 13px; color: #5a5a66; min-width: 232px; }
        .pp-slider span { white-space: nowrap; }
        .pp-slider input[type=range] { flex: 1; accent-color: #4A4E9E; }
        .pp-textarea { width: 320px; height: 172px; border-radius: 12px; padding: 12px;
          border: 1px solid rgba(80,80,95,0.22); background: #fff; color: #2a2a33;
          font: 13px/1.5 ui-monospace, 'SF Mono', monospace; resize: vertical; }
        .pp-progress { display: inline-flex; align-items: center; gap: 8px; margin-left: 6px;
          font: 600 13px -apple-system, sans-serif; color: #6b6b76; }
        .pp-progress-bar { width: 90px; height: 8px; border-radius: 5px;
          background: rgba(120,120,140,0.22); overflow: hidden; }
        .pp-progress-bar > span { display: block; height: 100%; width: 0%;
          background: #4A4E9E; transition: width 0.2s ease; }
        .pp-mermaid-view { display: flex; justify-content: center; align-items: center;
          min-height: 100%; padding: 14px; box-sizing: border-box; }
        .pp-mermaid-view svg { max-width: 100%; height: auto; }
        .pp-build { display: flex; flex-direction: column; gap: 8px; width: 340px;
          max-height: 60vh; overflow: auto; }
        .pp-build-h { font: 700 11px -apple-system, sans-serif; text-transform: uppercase;
          letter-spacing: 0.05em; color: #9a9aa4; margin-top: 6px; }
        .pp-build-row { display: flex; align-items: center; gap: 6px; }
        .pp-in-sm { flex: 1; height: 34px; width: auto; min-width: 0; }
        .pp-build-row .pp-select { height: 34px; }
        .pp-arrow { color: #9a9aa4; }
        .pp-add { background: rgba(74,78,158,0.12); color: #4A4E9E; align-self: flex-start;
          display: inline-flex; align-items: center; gap: 4px; }
        .pp-add svg { width: 15px; height: 15px; fill: none; stroke: currentColor; stroke-width: 2; }
        @media (prefers-color-scheme: dark) {
          .pp-add { background: rgba(139,143,217,0.18); color: #b9bbff; }
        }
        @media (prefers-color-scheme: dark) {
          .pp-textarea { background: rgba(255,255,255,0.06); color: #e9e9f0;
            border-color: rgba(255,255,255,0.14); }
          .pp-slider { color: #b7b7c2; }
        }
        .pp-row { display: flex; gap: 4px; }
        .pp-swatches { display: grid; grid-template-columns: repeat(4, 32px); gap: 10px; }
        .pp-swatch { width: 32px; height: 32px; border-radius: 10px;
          border: 1px solid rgba(0,0,0,0.12); cursor: pointer; padding: 0; }
        .pp-swatch.pp-none {
          background: linear-gradient(135deg, #fff 43%, #e5484d 44%, #e5484d 56%, #fff 57%);
        }
        .pp-custom { margin-top: 12px; display: flex; align-items: center;
          justify-content: space-between; gap: 12px; font-size: 13px; color: #6b6b76; }
        .pp-custom input { width: 32px; height: 32px; border: 0; background: none;
          padding: 0; cursor: pointer; }
        .pp-menu-item { display: block; width: 168px; text-align: left; padding: 10px 12px;
          border: 0; border-radius: 10px; background: transparent; color: #2a2a33;
          font: 600 15px -apple-system, sans-serif; cursor: pointer; }
        .pp-menu-item:hover { background: rgba(74,78,158,0.10); }
        @media (prefers-color-scheme: dark) {
          [data-penpal-mode="studio"] .pp-toolbar { background: rgba(26,26,30,0.97);
            border-color: rgba(255,255,255,0.10); }
          .pp-group { background: rgba(255,255,255,0.06); }
          .pp-btn, .pp-select { color: #e9e9f0; }
          .pp-btn:active, .pp-btn.pp-on { background: rgba(255,255,255,0.14); color: #b9bbff; }
          .pp-select { background: rgba(255,255,255,0.06); border-color: rgba(255,255,255,0.14); }
          .pp-pop { background: #26262c; border-color: rgba(255,255,255,0.10); }
          .pp-menu-item { color: #e9e9f0; }
          .pp-menu-item:hover { background: rgba(255,255,255,0.10); }
          .pp-custom { color: #a9a9b4; }
        }
        /* Attachment block: the empty-state field card and the small overlay
           "replace" control. Both are transient (.pp-attach-ui) chrome. */
        .pp-attach-ui { box-sizing: border-box; }
        .pp-attach-card {
          margin: auto; width: 100%; max-width: 440px; padding: 22px;
          display: flex; flex-direction: column; gap: 12px; box-sizing: border-box;
          border-radius: 16px; background: rgba(99,102,241,.06);
          border: 1.5px dashed rgba(99,102,241,.35); text-align: center;
        }
        .pp-attach-card .pp-at-title { font: 700 18px -apple-system, sans-serif; }
        .pp-attach-card .pp-at-sub { font: 400 13px -apple-system, sans-serif; color: #6b6b76; margin-top: -6px; }
        .pp-attach-card .pp-at-row { display: flex; gap: 8px; }
        .pp-attach-card .pp-at-url {
          flex: 1; height: 40px; border-radius: 10px; padding: 0 12px; min-width: 0;
          border: 1px solid rgba(80,80,95,0.22); background: #fff; color: #2a2a33;
          font: 500 15px -apple-system, sans-serif;
        }
        .pp-attach-card .pp-at-go, .pp-attach-card .pp-at-upload {
          height: 40px; padding: 0 16px; border: 0; border-radius: 10px; cursor: pointer;
          font: 700 15px -apple-system, sans-serif;
        }
        .pp-attach-card .pp-at-go { background: #4A4E9E; color: #fff; }
        .pp-attach-card .pp-at-upload {
          background: rgba(74,78,158,0.12); color: #4A4E9E;
          display: inline-flex; align-items: center; justify-content: center; gap: 6px;
        }
        .pp-attach-replace {
          position: absolute; top: 8px; right: 8px; z-index: 5;
          height: 32px; padding: 0 12px; border: 0; border-radius: 9px; cursor: pointer;
          background: rgba(20,20,25,0.62); color: #fff; backdrop-filter: blur(8px);
          font: 600 13px -apple-system, sans-serif;
        }
        .pp-attach { position: relative; }
        @media (prefers-color-scheme: dark) {
          .pp-attach-card .pp-at-url { background: rgba(255,255,255,0.08); color: #ececf0;
            border-color: rgba(255,255,255,0.16); }
          .pp-attach-card .pp-at-sub { color: #a9a9b4; }
        }
      `;
      doc.head.appendChild(runtimeStyle);

      let timer = null;
      let selectedCell = null;
      // Mermaid keeps its SOURCE as the source of truth — the rendered SVG is
      // disposable chrome we never persist, or the diagram would ossify.
      let mermaidSource = '';
      let mermaidTheme = 'neutral';
      let mermaidCaptured = false;
      // Structured model for the visual builder (flowcharts). Persisted next to
      // the source so the builder round-trips.
      let mermaidModel = null;
      const editable = () => {
        content.querySelectorAll(
          '[data-penpal-editable], td, th, .penpal-item-text'
        ).forEach(el => {
          el.setAttribute('contenteditable', 'true');
          el.style.webkitUserSelect = 'text';
          el.style.userSelect = 'text';
        });
      };
      // What actually gets saved. For most blocks it's the content root; for
      // mermaid we emit a clean <pre> holding just the source + theme.
      const serialize = () => {
        if (kind === 'mermaid') {
          const pre = doc.createElement('pre');
          pre.className = 'mermaid';
          pre.setAttribute('data-penpal-kind', 'mermaid');
          if (mermaidTheme && mermaidTheme !== 'neutral') pre.setAttribute('data-theme', mermaidTheme);
          if (mermaidModel) pre.setAttribute('data-model', JSON.stringify(mermaidModel));
          pre.textContent = mermaidSource || '';
          return pre.outerHTML;
        }
        // Transient UI (attachment input fields / replace buttons) is chrome,
        // never content — strip it so only the chosen media is persisted.
        if (content.querySelector('.pp-attach-ui')) {
          const clone = content.cloneNode(true);
          clone.querySelectorAll('.pp-attach-ui').forEach(el => el.remove());
          return clone.innerHTML;
        }
        return content.innerHTML;
      };
      const commit = () => {
        clearTimeout(timer);
        timer = setTimeout(() => {
          window.webkit.messageHandlers.penpalBlockChanged.postMessage({ html: serialize() });
        }, 180);
      };
      const immediateCommit = () => {
        clearTimeout(timer);
        window.webkit.messageHandlers.penpalBlockChanged.postMessage({ html: serialize() });
      };
      doc.addEventListener('focusin', event => {
        if (event.target.matches && event.target.matches('td,th')) selectedCell = event.target;
      }, true);
      doc.addEventListener('input', event => {
        if (content.contains(event.target)) commit();
      }, true);
      doc.addEventListener('change', event => {
        if (event.target.matches && event.target.matches('input[type=checkbox]')) {
          event.target.toggleAttribute('checked', event.target.checked);
        }
        if (content.contains(event.target)) immediateCommit();
      }, true);

      window.penpalBlockCommand = command => {
        const [kind, operation] = command.split(':');
        if (kind === 'table') {
          const table = document.querySelector('table');
          if (!table) return;
          const rows = Array.from(table.rows);
          const columnCount = Math.max(1, ...rows.map(row => row.cells.length));
          if (operation === 'addRow') {
            const body = table.tBodies[0] || table.createTBody();
            const selectedRow = selectedCell?.closest('tr');
            const insertAt = selectedRow?.parentElement === body
              ? selectedRow.sectionRowIndex + 1 : body.rows.length;
            const row = body.insertRow(insertAt);
            for (let index = 0; index < columnCount; index++) {
              row.insertCell().textContent = '';
            }
          } else if (operation === 'removeRow') {
            const body = table.tBodies[0];
            if (body && body.rows.length > 1) {
              const selectedRow = selectedCell?.closest('tr');
              const index = selectedRow?.parentElement === body
                ? selectedRow.sectionRowIndex : body.rows.length - 1;
              body.deleteRow(index);
              selectedCell = null;
            }
          } else if (operation === 'addColumn') {
            const selectedIndex = selectedCell?.cellIndex ?? columnCount - 1;
            rows.forEach(row => {
              const cell = row.parentElement?.tagName === 'THEAD'
                ? document.createElement('th') : document.createElement('td');
              cell.textContent = '';
              row.insertBefore(cell, row.cells[selectedIndex + 1] || null);
            });
          } else if (operation === 'removeColumn') {
            const selectedIndex = selectedCell?.cellIndex ?? columnCount - 1;
            if (columnCount > 1) rows.forEach(row => {
              if (row.cells[selectedIndex]) row.deleteCell(selectedIndex);
            });
            selectedCell = null;
          } else if (operation === 'toggleHeader') {
            let head = table.tHead;
            if (head) {
              const old = head.rows[0];
              const replacement = document.createElement('tr');
              Array.from(old.cells).forEach(cell => {
                const next = document.createElement('td');
                next.innerHTML = cell.innerHTML;
                replacement.appendChild(next);
              });
              table.tBodies[0].insertBefore(replacement, table.tBodies[0].firstChild);
              head.remove();
            } else {
              const body = table.tBodies[0];
              const old = body?.rows[0];
              if (old) {
                head = table.createTHead();
                const replacement = document.createElement('tr');
                Array.from(old.cells).forEach(cell => {
                  const next = document.createElement('th');
                  next.innerHTML = cell.innerHTML;
                  replacement.appendChild(next);
                });
                head.appendChild(replacement);
                old.remove();
              }
            }
          } else if (operation.startsWith('align')) {
            const alignment = operation.replace('align', '').toLowerCase();
            (selectedCell ? [selectedCell] : Array.from(table.querySelectorAll('td,th')))
              .forEach(cell => cell.style.textAlign = alignment);
          } else if (operation === 'merge' && selectedCell) {
            const next = selectedCell.nextElementSibling;
            if (next) {
              selectedCell.colSpan = (selectedCell.colSpan || 1) + (next.colSpan || 1);
              selectedCell.innerHTML += next.innerHTML ? ' ' + next.innerHTML : '';
              next.remove();
            }
          } else if (operation === 'split' && selectedCell && selectedCell.colSpan > 1) {
            selectedCell.colSpan -= 1;
            selectedCell.parentElement.insertBefore(
              document.createElement(selectedCell.tagName.toLowerCase()),
              selectedCell.nextSibling
            );
          } else if (operation === 'clear') {
            table.querySelectorAll('td,th').forEach(cell => cell.textContent = '');
          }
        } else if (kind === 'checklist') {
          const list = document.querySelector('.list');
          if (!list) return;
          if (operation === 'add') {
            const item = document.createElement('div');
            item.className = 'item';
            item.innerHTML =
              '<input type="checkbox"><span class="penpal-item-text" contenteditable="true">New item</span>';
            list.appendChild(item);
          } else if (operation === 'remove' && list.lastElementChild) {
            list.lastElementChild.remove();
          } else if (operation === 'clearCompleted') {
            list.querySelectorAll('input:checked').forEach(input => input.closest('.item, label')?.remove());
          } else if (operation === 'uncheck') {
            list.querySelectorAll('input').forEach(input => {
              input.checked = false; input.removeAttribute('checked');
            });
          }
        } else if (kind === 'text') {
          const text = document.querySelector('[data-penpal-editable]');
          if (!text) return;
          if (operation === 'body') text.style.fontSize = '16px';
          if (operation === 'heading') text.style.fontSize = '24px';
          if (operation === 'callout') {
            text.style.borderLeft = '4px solid #4A4E9E';
            text.style.paddingLeft = '14px';
          }
          if (operation === 'left') text.style.textAlign = 'left';
          if (operation === 'center') text.style.textAlign = 'center';
        } else if (kind === 'image') {
          const image = document.querySelector('img');
          if (!image) return;
          if (operation === 'fit') image.style.objectFit = 'contain';
          if (operation === 'fill') image.style.objectFit = 'cover';
          const current = Number(image.dataset.rotation || 0);
          if (operation === 'rotateLeft') image.dataset.rotation = current - 90;
          if (operation === 'rotateRight') image.dataset.rotation = current + 90;
          image.style.transform = `rotate(${image.dataset.rotation || current}deg)`;
        } else if (kind === 'attachment') {
          const root = document.querySelector('.pp-attach')
            || document.querySelector('[data-penpal-kind="attachment"]');
          if (!root) return;
          if (operation === 'clear') {
            root.querySelectorAll('figure').forEach(el => el.remove());
            renderAttach();
          }
          if (operation === 'fit') root.classList.remove('pp-fill');
          if (operation === 'fill') root.classList.add('pp-fill');
        }
        editable();
        immediateCommit();
      };

      // ---- In-web rich-text app chrome (text blocks) ----
      const richTarget = () =>
        content.querySelector('[data-penpal-editable]') || content;

      // Track the last selection INSIDE the editable, so a control that steals
      // focus (a <select>, the link field, a colour picker) can still apply to
      // the text the user had selected. Without this, tapping a select on iOS
      // clears the selection and every command would no-op.
      let lastRange = null;
      doc.addEventListener('selectionchange', () => {
        const sel = doc.getSelection();
        if (sel && sel.rangeCount && content.contains(sel.anchorNode)) {
          lastRange = sel.getRangeAt(0).cloneRange();
        }
      });
      const withSelection = (fn) => {
        const sel = doc.getSelection();
        if (lastRange) {
          try { sel.removeAllRanges(); sel.addRange(lastRange); } catch (e) {}
        }
        fn();
        immediateCommit();
      };
      const exec = (command, value) =>
        withSelection(() => doc.execCommand(command, false, value === undefined ? null : value));
      // Colour / font commands need CSS styling on in WebKit to apply reliably.
      const styledExec = (command, value) => withSelection(() => {
        doc.execCommand('styleWithCSS', false, true);
        doc.execCommand(command, false, value);
        doc.execCommand('styleWithCSS', false, false);
      });
      const colorExec = styledExec;
      // execCommand('fontSize') only speaks 1–7, so tag the run then rewrite it
      // to a real px size — this lets us offer proper point sizes.
      const setFontSizePx = (px) => withSelection(() => {
        doc.execCommand('fontSize', false, '7');
        richTarget().querySelectorAll('font[size="7"]').forEach(node => {
          node.removeAttribute('size');
          node.style.fontSize = px;
        });
      });
      // Background is a property of the whole text card, not the selection.
      const applyBackground = (color) => {
        const target = richTarget();
        if (!target) return;
        if (color === 'transparent') {
          target.style.background = '';
          target.style.borderRadius = '';
        } else {
          target.style.background = color;
          target.style.borderRadius = '12px';
        }
        immediateCommit();
      };
      const ICON = {
        bullet: '<svg viewBox="0 0 24 24"><circle class="fill" cx="4" cy="6" r="1.5"/><circle class="fill" cx="4" cy="12" r="1.5"/><circle class="fill" cx="4" cy="18" r="1.5"/><line x1="9" y1="6" x2="20" y2="6"/><line x1="9" y1="12" x2="20" y2="12"/><line x1="9" y1="18" x2="20" y2="18"/></svg>',
        number: '<svg viewBox="0 0 24 24"><text x="1" y="8">1</text><text x="1" y="14.5">2</text><text x="1" y="21">3</text><line x1="9" y1="6" x2="20" y2="6"/><line x1="9" y1="12" x2="20" y2="12"/><line x1="9" y1="18" x2="20" y2="18"/></svg>',
        alignLeft: '<svg viewBox="0 0 24 24"><line x1="4" y1="6" x2="20" y2="6"/><line x1="4" y1="12" x2="14" y2="12"/><line x1="4" y1="18" x2="18" y2="18"/></svg>',
        alignCenter: '<svg viewBox="0 0 24 24"><line x1="4" y1="6" x2="20" y2="6"/><line x1="7" y1="12" x2="17" y2="12"/><line x1="5" y1="18" x2="19" y2="18"/></svg>',
        alignRight: '<svg viewBox="0 0 24 24"><line x1="4" y1="6" x2="20" y2="6"/><line x1="10" y1="12" x2="20" y2="12"/><line x1="6" y1="18" x2="20" y2="18"/></svg>',
        link: '<svg viewBox="0 0 24 24"><path d="M10 14a4 4 0 0 0 5.66 0l3-3a4 4 0 0 0-5.66-5.66l-1.5 1.5"/><path d="M14 10a4 4 0 0 0-5.66 0l-3 3a4 4 0 0 0 5.66 5.66l1.5-1.5"/></svg>',
        marker: '<svg viewBox="0 0 24 24"><path d="M4 21h16"/><path d="M12 3l6 6-7 7H6l-1-4z"/></svg>',
        callout: '<svg viewBox="0 0 24 24"><rect x="4" y="5" width="16" height="14" rx="3"/><line x1="8" y1="10" x2="16" y2="10"/><line x1="8" y1="14" x2="13" y2="14"/></svg>',
        bg: '<svg viewBox="0 0 24 24"><path d="M5 11l7-7 6 6-7 7a2.5 2.5 0 0 1-3.5 0l-2.5-2.5a2.5 2.5 0 0 1 0-3.5z"/><path d="M12 4l1.5-1.5"/><path class="fill" d="M19 15c1 1.6 2 2.7 2 3.8a2 2 0 1 1-4 0c0-1.1 1-2.2 2-3.8z"/></svg>',
        clear: '<svg viewBox="0 0 24 24"><path d="M8 8l10 10"/><path d="M6.5 15.5L15 7a2.5 2.5 0 0 1 3.5 3.5L14 15"/><line x1="6" y1="21" x2="20" y2="21"/></svg>',
        chev: '<svg class="pp-chev" viewBox="0 0 24 24"><path d="M6 9l6 6 6-6"/></svg>',
        photo: '<svg viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="14" rx="2"/><circle class="fill" cx="8.5" cy="10" r="1.4"/><path d="M4 17l5-5 4 4 3-3 4 4"/></svg>',
        fit: '<svg viewBox="0 0 24 24"><path d="M9 4H5a1 1 0 0 0-1 1v4M15 4h4a1 1 0 0 1 1 1v4M9 20H5a1 1 0 0 1-1-1v-4M15 20h4a1 1 0 0 0 1-1v-4"/></svg>',
        fill: '<svg viewBox="0 0 24 24"><path d="M4 9V5a1 1 0 0 1 1-1h4M20 9V5a1 1 0 0 0-1-1h-4M4 15v4a1 1 0 0 0 1 1h4M20 15v4a1 1 0 0 1-1 1h-4"/></svg>',
        rotL: '<svg viewBox="0 0 24 24"><path d="M4 8a8 8 0 1 1-1 4"/><path d="M4 4v4h4"/></svg>',
        rotR: '<svg viewBox="0 0 24 24"><path d="M20 8a8 8 0 1 0 1 4"/><path d="M20 4v4h-4"/></svg>',
        flipH: '<svg viewBox="0 0 24 24"><path d="M12 3v18"/><path d="M8 7l-4 5 4 5z"/><path d="M16 7l4 5-4 5z"/></svg>',
        flipV: '<svg viewBox="0 0 24 24"><path d="M3 12h18"/><path d="M7 8l5-4 5 4z"/><path d="M7 16l5 4 5-4z"/></svg>',
        adjust: '<svg viewBox="0 0 24 24"><line x1="4" y1="7" x2="20" y2="7"/><circle class="fill" cx="9" cy="7" r="2.4"/><line x1="4" y1="17" x2="20" y2="17"/><circle class="fill" cx="15" cy="17" r="2.4"/></svg>',
        frame: '<svg viewBox="0 0 24 24"><rect x="4" y="4" width="16" height="16" rx="4"/></svg>',
        reset: '<svg viewBox="0 0 24 24"><path d="M4 10a8 8 0 1 1 .5 5"/><path d="M4 5v5h5"/></svg>',
        rowAdd: '<svg viewBox="0 0 24 24"><rect x="4" y="5" width="16" height="6" rx="1"/><line x1="12" y1="15" x2="12" y2="21"/><line x1="9" y1="18" x2="15" y2="18"/></svg>',
        rowDel: '<svg viewBox="0 0 24 24"><rect x="4" y="5" width="16" height="6" rx="1"/><line x1="9" y1="18" x2="15" y2="18"/></svg>',
        colAdd: '<svg viewBox="0 0 24 24"><rect x="5" y="4" width="6" height="16" rx="1"/><line x1="18" y1="9" x2="18" y2="15"/><line x1="15" y1="12" x2="21" y2="12"/></svg>',
        colDel: '<svg viewBox="0 0 24 24"><rect x="5" y="4" width="6" height="16" rx="1"/><line x1="15" y1="12" x2="21" y2="12"/></svg>',
        header: '<svg viewBox="0 0 24 24"><rect x="4" y="5" width="16" height="14" rx="1"/><rect class="fill" x="4" y="5" width="16" height="4"/></svg>',
        bucket: '<svg viewBox="0 0 24 24"><path d="M5 11l7-7 6 6-7 7a2.5 2.5 0 0 1-3.5 0l-2.5-2.5a2.5 2.5 0 0 1 0-3.5z"/><path class="fill" d="M19 15c1 1.6 2 2.7 2 3.8a2 2 0 1 1-4 0c0-1.1 1-2.2 2-3.8z"/></svg>',
        stripe: '<svg viewBox="0 0 24 24"><rect x="4" y="5" width="16" height="14" rx="1"/><rect class="fill" x="4" y="9" width="16" height="3"/><rect class="fill" x="4" y="15" width="16" height="3"/></svg>',
        grid: '<svg viewBox="0 0 24 24"><rect x="4" y="4" width="16" height="16" rx="1"/><line x1="4" y1="12" x2="20" y2="12"/><line x1="12" y1="4" x2="12" y2="20"/></svg>',
        merge: '<svg viewBox="0 0 24 24"><path d="M8 6H5v12h3"/><path d="M16 6h3v12h-3"/><line x1="9" y1="12" x2="15" y2="12"/><path d="M13 10l2 2-2 2"/></svg>',
        split: '<svg viewBox="0 0 24 24"><rect x="4" y="5" width="16" height="14" rx="1"/><line x1="12" y1="5" x2="12" y2="19"/></svg>',
        plus: '<svg viewBox="0 0 24 24"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>',
        minus: '<svg viewBox="0 0 24 24"><line x1="5" y1="12" x2="19" y2="12"/></svg>',
        circle: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"/></svg>',
        broom: '<svg viewBox="0 0 24 24"><path d="M19 5l-7 7"/><path d="M8 20l-3-3 4-4 3 3-4 4z"/><path d="M11 13l3 3"/></svg>',
        drop: '<svg viewBox="0 0 24 24"><path class="fill" d="M12 3s6 6.5 6 10a6 6 0 1 1-12 0c0-3.5 6-10 6-10z"/></svg>',
        code: '<svg viewBox="0 0 24 24"><path d="M9 8l-4 4 4 4"/><path d="M15 8l4 4-4 4"/></svg>',
        build: '<svg viewBox="0 0 24 24"><rect x="3" y="4" width="7" height="5" rx="1"/><rect x="14" y="15" width="7" height="5" rx="1"/><path d="M6.5 9v4a2 2 0 0 0 2 2h9"/></svg>',
      };
      const buildTextChrome = () => {
        const bar = doc.createElement('div');
        bar.className = 'pp-chrome pp-toolbar';
        bar.setAttribute('data-pp-for', 'text');
        bar.innerHTML = `
          <select class="pp-select" data-pp-block title="Paragraph style">
            <option value="p">Body</option>
            <option value="h1">Title</option>
            <option value="h2">Heading</option>
            <option value="h3">Subhead</option>
            <option value="blockquote">Quote</option>
            <option value="pre">Code</option>
          </select>
          <select class="pp-select" data-pp-font title="Font">
            <option value="">Font</option>
            <option value="-apple-system, sans-serif">System</option>
            <option value="Georgia, 'Times New Roman', serif">Serif</option>
            <option value="'SF Pro Rounded', ui-rounded, sans-serif">Rounded</option>
            <option value="'Snell Roundhand', 'Bradley Hand', cursive">Handwritten</option>
            <option value="ui-monospace, 'SF Mono', monospace">Mono</option>
          </select>
          <select class="pp-select" data-pp-size title="Text size">
            <option value="">Size</option>
            <option value="13px">13</option>
            <option value="15px">15</option>
            <option value="17px">17</option>
            <option value="20px">20</option>
            <option value="24px">24</option>
            <option value="30px">30</option>
            <option value="40px">40</option>
          </select>
          <div class="pp-group">
            <button class="pp-btn" data-pp-exec="bold" title="Bold" style="font-weight:800">B</button>
            <button class="pp-btn" data-pp-exec="italic" title="Italic" style="font-style:italic;font-family:Georgia,serif">I</button>
            <button class="pp-btn" data-pp-exec="underline" title="Underline" style="text-decoration:underline">U</button>
            <button class="pp-btn" data-pp-exec="strikeThrough" title="Strikethrough" style="text-decoration:line-through">S</button>
          </div>
          <div class="pp-group">
            <button class="pp-btn" data-pp-exec="insertUnorderedList" title="Bulleted list">${ICON.bullet}</button>
            <button class="pp-btn" data-pp-exec="insertOrderedList" title="Numbered list">${ICON.number}</button>
          </div>
          <div class="pp-menu-wrap">
            <button class="pp-btn" data-pp-pop="align" title="Alignment">${ICON.alignLeft}${ICON.chev}</button>
            <div class="pp-pop" data-pp-panel="align">
              <div class="pp-row">
                <button class="pp-btn" data-pp-exec="justifyLeft" title="Left">${ICON.alignLeft}</button>
                <button class="pp-btn" data-pp-exec="justifyCenter" title="Center">${ICON.alignCenter}</button>
                <button class="pp-btn" data-pp-exec="justifyRight" title="Right">${ICON.alignRight}</button>
              </div>
            </div>
          </div>
          <div class="pp-menu-wrap">
            <button class="pp-btn" data-pp-pop="fore" title="Text colour"><span class="pp-a">A</span><span class="pp-bar"></span></button>
            <div class="pp-pop pp-pop-right" data-pp-panel="fore">
              <div class="pp-swatches" data-pp-fore-swatches></div>
              <label class="pp-custom">Custom colour<input type="color" data-pp-fore></label>
            </div>
          </div>
          <div class="pp-menu-wrap">
            <button class="pp-btn" data-pp-pop="back" title="Highlight">${ICON.marker}</button>
            <div class="pp-pop pp-pop-right" data-pp-panel="back">
              <div class="pp-swatches" data-pp-back-swatches></div>
              <label class="pp-custom">Custom colour<input type="color" data-pp-back></label>
            </div>
          </div>
          <div class="pp-menu-wrap">
            <button class="pp-btn" data-pp-pop="bg" title="Block background">${ICON.bg}</button>
            <div class="pp-pop pp-pop-right" data-pp-panel="bg">
              <div class="pp-swatches" data-pp-bg-swatches></div>
              <label class="pp-custom">Custom colour<input type="color" data-pp-bg></label>
            </div>
          </div>
          <div class="pp-menu-wrap">
            <button class="pp-btn" data-pp-pop="link" title="Add link">${ICON.link}</button>
            <div class="pp-pop pp-pop-right" data-pp-panel="link">
              <div class="pp-linkrow">
                <input type="url" class="pp-input" data-pp-link-input placeholder="https://…"
                       autocapitalize="off" autocorrect="off" spellcheck="false">
                <button class="pp-apply" data-pp-link-apply>Add</button>
              </div>
            </div>
          </div>
          <div class="pp-menu-wrap">
            <button class="pp-btn" data-pp-pop="callout" title="Callout">${ICON.callout}${ICON.chev}</button>
            <div class="pp-pop pp-pop-right" data-pp-panel="callout">
              <button class="pp-menu-item" data-pp-preset="plain">Plain paragraph</button>
              <button class="pp-menu-item" data-pp-preset="note">Note</button>
              <button class="pp-menu-item" data-pp-preset="tip">Tip</button>
              <button class="pp-menu-item" data-pp-preset="warn">Warning</button>
              <button class="pp-menu-item" data-pp-preset="quote">Quote</button>
            </div>
          </div>
          <button class="pp-btn" data-pp-clear title="Clear formatting">${ICON.clear}</button>
        `;
        bodyEl.insertBefore(bar, content);

        // Curated palettes — a proper picker rather than a single tiny square.
        const foreColors = ['#252530', '#4A4E9E', '#2563eb', '#0f766e',
                            '#b45309', '#b91c1c', '#7c3aed', '#6b7280'];
        const backColors = ['#FFE08A', '#BBF7D0', '#BFDBFE', '#FBCFE8',
                            '#FED7AA', '#E9D5FF', '#FEF08A', '__none__'];
        // Background is transparent by default, so "None" comes first.
        const bgColors = ['__none__', '#FFF7ED', '#EEF2FF', '#ECFDF5', '#FEF2F2',
                          '#F5F3FF', '#F1F5F9', '#FEF9C3'];
        const fillSwatches = (host, colors, apply) => {
          if (!host) return;
          colors.forEach(color => {
            const swatch = doc.createElement('button');
            swatch.className = 'pp-swatch' + (color === '__none__' ? ' pp-none' : '');
            swatch.title = color === '__none__' ? 'None' : color;
            if (color !== '__none__') swatch.style.background = color;
            swatch.addEventListener('click', () => {
              apply(color === '__none__' ? 'transparent' : color);
              closePops();
            });
            host.appendChild(swatch);
          });
        };
        fillSwatches(bar.querySelector('[data-pp-fore-swatches]'), foreColors,
                     color => colorExec('foreColor', color));
        fillSwatches(bar.querySelector('[data-pp-back-swatches]'), backColors,
                     color => colorExec('hiliteColor', color));
        fillSwatches(bar.querySelector('[data-pp-bg-swatches]'), bgColors,
                     color => applyBackground(color));

        const closePops = () =>
          bar.querySelectorAll('.pp-pop.pp-open').forEach(p => p.classList.remove('pp-open'));

        // Preserve the current text selection when a control is pressed. The
        // link/colour text inputs are deliberately excluded so they can focus.
        bar.addEventListener('pointerdown', event => {
          if (event.target.closest('[data-pp-exec],[data-pp-clear],[data-pp-preset],[data-pp-pop],[data-pp-link-apply],.pp-swatch')) {
            event.preventDefault();
          }
        });
        bar.addEventListener('click', event => {
          const popBtn = event.target.closest('[data-pp-pop]');
          if (popBtn) {
            const name = popBtn.getAttribute('data-pp-pop');
            const panel = bar.querySelector('.pp-pop[data-pp-panel="' + name + '"]');
            const willOpen = panel && !panel.classList.contains('pp-open');
            closePops();
            if (willOpen) panel.classList.add('pp-open');
            return;
          }
          const ex = event.target.closest('[data-pp-exec]');
          if (ex) {
            exec(ex.getAttribute('data-pp-exec'));
            if (ex.closest('.pp-pop')) closePops();
            return;
          }
          const clear = event.target.closest('[data-pp-clear]');
          if (clear) { exec('removeFormat'); return; }
          const preset = event.target.closest('[data-pp-preset]');
          if (preset) {
            const target = richTarget();
            if (target) {
              target.classList.remove('callout-note', 'callout-tip', 'callout-warn', 'callout-quote');
              const kindName = preset.getAttribute('data-pp-preset');
              if (kindName !== 'plain') target.classList.add('callout-' + kindName);
              immediateCommit();
            }
            closePops();
          }
        });
        // Dismiss any open popover when tapping elsewhere.
        doc.addEventListener('pointerdown', event => {
          if (!event.target.closest('.pp-toolbar')) closePops();
        }, true);

        const blockSel = bar.querySelector('[data-pp-block]');
        if (blockSel) blockSel.addEventListener('change', event => exec('formatBlock', event.target.value));
        const fontSel = bar.querySelector('[data-pp-font]');
        if (fontSel) fontSel.addEventListener('change', event => {
          if (event.target.value) colorExec('fontName', event.target.value);
        });
        const sizeSel = bar.querySelector('[data-pp-size]');
        if (sizeSel) sizeSel.addEventListener('change', event => {
          if (event.target.value) setFontSizePx(event.target.value);
        });
        const fore = bar.querySelector('input[data-pp-fore]');
        if (fore) fore.addEventListener('input', event => colorExec('foreColor', event.target.value));
        const back = bar.querySelector('input[data-pp-back]');
        if (back) back.addEventListener('input', event => colorExec('hiliteColor', event.target.value));
        const bg = bar.querySelector('input[data-pp-bg]');
        if (bg) bg.addEventListener('input', event => applyBackground(event.target.value));
        const linkInput = bar.querySelector('[data-pp-link-input]');
        const linkApply = bar.querySelector('[data-pp-link-apply]');
        if (linkApply) linkApply.addEventListener('click', () => {
          const url = ((linkInput && linkInput.value) || '').trim();
          if (url) exec('createLink', url);
          if (linkInput) linkInput.value = '';
          closePops();
        });
      };
      // ---- Shared chrome framework (used by image / table / checklist / mermaid) ----
      const makeBar = (html) => {
        const bar = doc.createElement('div');
        bar.className = 'pp-chrome pp-toolbar';
        bar.innerHTML = html;
        bodyEl.insertBefore(bar, content);
        return bar;
      };
      // Popover open/close + selection-preserving taps. Returns closePops().
      const wireChrome = (bar) => {
        const closePops = () =>
          bar.querySelectorAll('.pp-pop.pp-open').forEach(p => p.classList.remove('pp-open'));
        bar.addEventListener('pointerdown', event => {
          const t = event.target;
          if (t.closest('.pp-btn, .pp-swatch, .pp-menu-item, .pp-apply') &&
              !t.closest('input, select, textarea')) {
            event.preventDefault();
          }
        });
        bar.addEventListener('click', event => {
          const popBtn = event.target.closest('[data-pp-pop]');
          if (!popBtn) return;
          const name = popBtn.getAttribute('data-pp-pop');
          const panel = bar.querySelector('.pp-pop[data-pp-panel="' + name + '"]');
          const willOpen = panel && !panel.classList.contains('pp-open');
          closePops();
          if (willOpen) panel.classList.add('pp-open');
        });
        doc.addEventListener('pointerdown', event => {
          if (!event.target.closest('.pp-toolbar')) closePops();
        }, true);
        return closePops;
      };
      const swatchesInto = (host, colors, apply, closePops) => {
        if (!host) return;
        colors.forEach(color => {
          const s = doc.createElement('button');
          s.className = 'pp-swatch' + (color === '__none__' ? ' pp-none' : '');
          s.title = color === '__none__' ? 'None' : color;
          if (color !== '__none__') s.style.background = color;
          s.addEventListener('click', () => {
            apply(color === '__none__' ? 'transparent' : color);
            if (closePops) closePops();
          });
          host.appendChild(s);
        });
      };
      const slider = (label, key, min, max, val) =>
        '<label class="pp-slider"><span>' + label + '</span>' +
        '<input type="range" min="' + min + '" max="' + max + '" value="' + val +
        '" data-pp-slider="' + key + '"></label>';

      // ---- Image editor ----
      const buildImageChrome = () => {
        const img = content.querySelector('img');
        if (!img) return;
        const D = img.dataset;
        const n = (k, d) => (D[k] !== undefined ? parseFloat(D[k]) : d);
        let state = {
          brightness: n('brightness', 100), contrast: n('contrast', 100),
          saturate: n('saturate', 100), sepia: n('sepia', 0),
          grayscale: n('grayscale', 0), blur: n('blur', 0),
          rotation: n('rotation', 0), flipH: D.fliph === '1', flipV: D.flipv === '1',
          radius: n('radius', 0),
        };
        const render = () => {
          img.style.filter = 'brightness(' + state.brightness + '%) contrast(' + state.contrast +
            '%) saturate(' + state.saturate + '%) sepia(' + state.sepia + '%) grayscale(' +
            state.grayscale + '%) blur(' + state.blur + 'px)';
          img.style.transform = 'rotate(' + state.rotation + 'deg) scaleX(' +
            (state.flipH ? -1 : 1) + ') scaleY(' + (state.flipV ? -1 : 1) + ')';
          img.style.borderRadius = state.radius + 'px';
          D.brightness = state.brightness; D.contrast = state.contrast; D.saturate = state.saturate;
          D.sepia = state.sepia; D.grayscale = state.grayscale; D.blur = state.blur;
          D.rotation = state.rotation; D.fliph = state.flipH ? '1' : '0';
          D.flipv = state.flipV ? '1' : '0'; D.radius = state.radius;
        };
        const commitRender = () => { render(); immediateCommit(); };
        const bar = makeBar(
          '<label class="pp-btn" title="Replace image">' + ICON.photo +
            '<input type="file" accept="image/*" data-pp-file hidden></label>' +
          '<div class="pp-group">' +
            '<button class="pp-btn" data-pp-op="fit" title="Fit">' + ICON.fit + '</button>' +
            '<button class="pp-btn" data-pp-op="fill" title="Fill">' + ICON.fill + '</button>' +
          '</div>' +
          '<div class="pp-group">' +
            '<button class="pp-btn" data-pp-op="rotL" title="Rotate left">' + ICON.rotL + '</button>' +
            '<button class="pp-btn" data-pp-op="rotR" title="Rotate right">' + ICON.rotR + '</button>' +
            '<button class="pp-btn" data-pp-op="flipH" title="Flip horizontal">' + ICON.flipH + '</button>' +
            '<button class="pp-btn" data-pp-op="flipV" title="Flip vertical">' + ICON.flipV + '</button>' +
          '</div>' +
          '<div class="pp-menu-wrap">' +
            '<button class="pp-btn" data-pp-pop="adjust" title="Adjust">' + ICON.adjust + ICON.chev + '</button>' +
            '<div class="pp-pop" data-pp-panel="adjust">' +
              slider('Brightness', 'brightness', 0, 200, state.brightness) +
              slider('Contrast', 'contrast', 0, 200, state.contrast) +
              slider('Saturation', 'saturate', 0, 200, state.saturate) +
              slider('Warmth', 'sepia', 0, 100, state.sepia) +
              slider('Grayscale', 'grayscale', 0, 100, state.grayscale) +
              slider('Blur', 'blur', 0, 20, state.blur) +
            '</div>' +
          '</div>' +
          '<div class="pp-menu-wrap">' +
            '<button class="pp-btn" data-pp-pop="frame" title="Frame">' + ICON.frame + ICON.chev + '</button>' +
            '<div class="pp-pop pp-pop-right" data-pp-panel="frame">' +
              slider('Corner radius', 'radius', 0, 80, state.radius) +
            '</div>' +
          '</div>' +
          '<button class="pp-btn" data-pp-op="reset" title="Reset all">' + ICON.reset + '</button>'
        );
        wireChrome(bar);
        const file = bar.querySelector('[data-pp-file]');
        if (file) file.addEventListener('change', event => {
          const f = event.target.files && event.target.files[0];
          if (!f) return;
          const reader = new FileReader();
          reader.onload = () => { img.src = reader.result; immediateCommit(); };
          reader.readAsDataURL(f);
        });
        bar.addEventListener('click', event => {
          const op = event.target.closest('[data-pp-op]');
          if (!op) return;
          const o = op.getAttribute('data-pp-op');
          if (o === 'fit') img.style.objectFit = 'contain';
          else if (o === 'fill') img.style.objectFit = 'cover';
          else if (o === 'rotL') state.rotation -= 90;
          else if (o === 'rotR') state.rotation += 90;
          else if (o === 'flipH') state.flipH = !state.flipH;
          else if (o === 'flipV') state.flipV = !state.flipV;
          else if (o === 'reset') {
            state = { brightness: 100, contrast: 100, saturate: 100, sepia: 0,
                      grayscale: 0, blur: 0, rotation: 0, flipH: false, flipV: false, radius: 0 };
            img.style.objectFit = 'contain';
          }
          commitRender();
        });
        bar.querySelectorAll('[data-pp-slider]').forEach(sl => {
          sl.addEventListener('input', event => {
            state[event.target.getAttribute('data-pp-slider')] = parseFloat(event.target.value);
            commitRender();
          });
        });
        render();
      };

      // ---- Table editor ----
      const buildTableChrome = () => {
        const table = content.querySelector('table');
        if (!table) return;
        const applyCell = (fn) => { if (selectedCell) { fn(selectedCell); immediateCommit(); } };
        const cellFore = ['#252530', '#4A4E9E', '#b91c1c', '#0f766e',
                          '#b45309', '#2563eb', '#7c3aed', '__none__'];
        const cellFill = ['__none__', '#EEF2FF', '#ECFDF5', '#FEF2F2',
                          '#FEF9C3', '#F1F5F9', '#FCE7F3', '#E9D5FF'];
        const bar = makeBar(
          '<div class="pp-group">' +
            '<button class="pp-btn" data-pp-cmd="table:addRow" title="Add row">' + ICON.rowAdd + '</button>' +
            '<button class="pp-btn" data-pp-cmd="table:removeRow" title="Remove row">' + ICON.rowDel + '</button>' +
            '<button class="pp-btn" data-pp-cmd="table:addColumn" title="Add column">' + ICON.colAdd + '</button>' +
            '<button class="pp-btn" data-pp-cmd="table:removeColumn" title="Remove column">' + ICON.colDel + '</button>' +
          '</div>' +
          '<button class="pp-btn" data-pp-cmd="table:toggleHeader" title="Toggle header row">' + ICON.header + '</button>' +
          '<div class="pp-group">' +
            '<button class="pp-btn" data-pp-cmd="table:alignLeft" title="Align left">' + ICON.alignLeft + '</button>' +
            '<button class="pp-btn" data-pp-cmd="table:alignCenter" title="Align center">' + ICON.alignCenter + '</button>' +
            '<button class="pp-btn" data-pp-cmd="table:alignRight" title="Align right">' + ICON.alignRight + '</button>' +
          '</div>' +
          '<button class="pp-btn" data-pp-op="bold" title="Bold cell" style="font-weight:800">B</button>' +
          '<div class="pp-menu-wrap">' +
            '<button class="pp-btn" data-pp-pop="cellText" title="Cell text colour"><span class="pp-a">A</span><span class="pp-bar"></span></button>' +
            '<div class="pp-pop pp-pop-right" data-pp-panel="cellText"><div class="pp-swatches" data-fore></div></div>' +
          '</div>' +
          '<div class="pp-menu-wrap">' +
            '<button class="pp-btn" data-pp-pop="cellFill" title="Cell fill">' + ICON.bucket + '</button>' +
            '<div class="pp-pop pp-pop-right" data-pp-panel="cellFill"><div class="pp-swatches" data-fill></div></div>' +
          '</div>' +
          '<div class="pp-group">' +
            '<button class="pp-btn" data-pp-op="stripe" title="Zebra striping">' + ICON.stripe + '</button>' +
            '<button class="pp-btn" data-pp-op="borders" title="Toggle borders">' + ICON.grid + '</button>' +
          '</div>' +
          '<button class="pp-btn" data-pp-cmd="table:merge" title="Merge with next">' + ICON.merge + '</button>' +
          '<button class="pp-btn" data-pp-cmd="table:split" title="Split cell">' + ICON.split + '</button>' +
          '<button class="pp-btn" data-pp-cmd="table:clear" title="Clear contents">' + ICON.clear + '</button>'
        );
        const closePops = wireChrome(bar);
        swatchesInto(bar.querySelector('[data-fore]'), cellFore,
                     c => applyCell(cell => cell.style.color = c === 'transparent' ? '' : c), closePops);
        swatchesInto(bar.querySelector('[data-fill]'), cellFill,
                     c => applyCell(cell => cell.style.background = c === 'transparent' ? '' : c), closePops);
        bar.addEventListener('click', event => {
          const cmd = event.target.closest('[data-pp-cmd]');
          if (cmd) { window.penpalBlockCommand(cmd.getAttribute('data-pp-cmd')); return; }
          const op = event.target.closest('[data-pp-op]');
          if (!op) return;
          const o = op.getAttribute('data-pp-op');
          if (o === 'bold') applyCell(cell => cell.style.fontWeight = cell.style.fontWeight === '700' ? '' : '700');
          else if (o === 'stripe') { table.classList.toggle('pp-striped'); immediateCommit(); }
          else if (o === 'borders') { table.classList.toggle('pp-noborder'); immediateCommit(); }
        });
      };

      // ---- Checklist / task app ----
      const buildChecklistChrome = () => {
        const list = content.querySelector('.list');
        if (!list) return;
        const accentColors = ['#4A4E9E', '#2563eb', '#0f766e', '#b45309',
                              '#b91c1c', '#7c3aed', '#0891b2', '#db2777'];
        const bar = makeBar(
          '<button class="pp-btn" data-pp-cmd="checklist:add" title="Add item">' + ICON.plus + ' Add</button>' +
          '<button class="pp-btn" data-pp-cmd="checklist:remove" title="Remove last item">' + ICON.minus + '</button>' +
          '<button class="pp-btn" data-pp-cmd="checklist:uncheck" title="Uncheck all">' + ICON.circle + '</button>' +
          '<button class="pp-btn" data-pp-cmd="checklist:clearCompleted" title="Clear completed">' + ICON.broom + '</button>' +
          '<div class="pp-menu-wrap">' +
            '<button class="pp-btn" data-pp-pop="accent" title="Accent colour">' + ICON.drop + ICON.chev + '</button>' +
            '<div class="pp-pop pp-pop-right" data-pp-panel="accent"><div class="pp-swatches" data-accent></div></div>' +
          '</div>' +
          '<span class="pp-progress"><span class="pp-progress-bar"><span data-bar></span></span><span data-count></span></span>'
        );
        const closePops = wireChrome(bar);
        const applyAccent = (color) => {
          list.style.setProperty('--pp-accent', color);
          list.setAttribute('data-accent', color);
          list.querySelectorAll('input[type=checkbox]').forEach(i => i.style.accentColor = color);
          immediateCommit();
        };
        swatchesInto(bar.querySelector('[data-accent]'), accentColors, applyAccent, closePops);
        const updateProgress = () => {
          const boxes = list.querySelectorAll('input[type=checkbox]');
          const done = list.querySelectorAll('input[type=checkbox]:checked').length;
          const fill = bar.querySelector('[data-bar]');
          if (fill) fill.style.width = (boxes.length ? Math.round(done / boxes.length * 100) : 0) + '%';
          const count = bar.querySelector('[data-count]');
          if (count) count.textContent = done + ' / ' + boxes.length;
        };
        bar.addEventListener('click', event => {
          const cmd = event.target.closest('[data-pp-cmd]');
          if (!cmd) return;
          window.penpalBlockCommand(cmd.getAttribute('data-pp-cmd'));
          const accent = list.getAttribute('data-accent');
          if (accent) list.querySelectorAll('input[type=checkbox]').forEach(i => i.style.accentColor = accent);
          updateProgress();
        });
        content.addEventListener('change', updateProgress, true);
        updateProgress();
      };

      // ---- Mermaid diagram studio ----
      const MERMAID_TEMPLATES = {
        flowchart: 'flowchart LR\\n  A[Idea] --> B[Build]\\n  B --> C[Learn]\\n  C --> A',
        sequence: 'sequenceDiagram\\n  Alice->>Bob: Hello Bob\\n  Bob-->>Alice: Hi Alice',
        gantt: 'gantt\\n  title Plan\\n  dateFormat  YYYY-MM-DD\\n  section Phase\\n  Design :a1, 2024-01-01, 7d\\n  Build  :after a1, 10d',
        pie: 'pie title Share\\n  "A" : 45\\n  "B" : 30\\n  "C" : 25',
        mindmap: 'mindmap\\n  root((Idea))\\n    Research\\n    Design\\n    Build',
        class: 'classDiagram\\n  class Animal\\n  Animal : +int age\\n  Animal : +run()\\n  Animal <|-- Dog',
      };
      const renderMermaid = () => {
        const pre = content.querySelector('.mermaid, [data-penpal-kind="mermaid"]');
        if (!pre) return;
        if (!mermaidCaptured) {
          mermaidSource = (pre.textContent || '').trim() ||
            'flowchart LR\\n  A[Idea] --> B[Build]';
          mermaidTheme = pre.getAttribute('data-theme') || 'neutral';
          const savedModel = pre.getAttribute('data-model');
          if (savedModel) { try { mermaidModel = JSON.parse(savedModel); } catch (e) {} }
          mermaidCaptured = true;
        }
        let view = content.querySelector('.pp-mermaid-view');
        if (!view) { view = doc.createElement('div'); view.className = 'pp-mermaid-view'; pre.after(view); }
        pre.style.display = 'none';
        const go = () => {
          try {
            window.mermaid.initialize({ startOnLoad: false, theme: mermaidTheme });
            window.mermaid.render('ppm' + Date.now(), mermaidSource)
              .then(res => { view.innerHTML = res.svg; })
              .catch(() => { view.textContent = 'Diagram error — check the source.'; });
          } catch (e) { view.textContent = 'Diagram error — check the source.'; }
        };
        if (window.mermaid) { go(); return; }
        if (doc.getElementById('pp-mermaid-lib')) { return; }
        const s = doc.createElement('script');
        s.id = 'pp-mermaid-lib';
        s.src = 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js';
        s.onload = go;
        doc.head.appendChild(s);
      };
      // --- Visual flowchart builder: turn UI edits into mermaid source. ---
      const escAttr = (s) => (s || '').replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
      const wrapShape = (shape, text) => {
        const t = text || '';
        switch (shape) {
          case 'round': return '(' + t + ')';
          case 'stadium': return '([' + t + '])';
          case 'circle': return '((' + t + '))';
          case 'diamond': return '{' + t + '}';
          case 'hex': return '{{' + t + '}}';
          default: return '[' + t + ']';
        }
      };
      const generateSource = (model) => {
        let out = 'flowchart ' + (model.dir || 'LR') + '\\n';
        model.nodes.forEach(nd => { out += '  ' + nd.id + wrapShape(nd.shape, nd.text) + '\\n'; });
        model.links.forEach(lk => {
          out += '  ' + lk.from + ' -->' + (lk.label ? '|' + lk.label + '|' : '') + ' ' + lk.to + '\\n';
        });
        return out.trim();
      };
      const parseNodeToken = (tok) => {
        const m = (tok || '').trim().match(/^([A-Za-z0-9_]+)\\s*([\\s\\S]*)$/);
        if (!m) return null;
        const id = m[1]; const rest = m[2]; let text = null; let shape = 'rect';
        const pair = (o, c, s) => { if (rest.startsWith(o) && rest.endsWith(c)) { text = rest.slice(o.length, rest.length - c.length); shape = s; return true; } return false; };
        if (rest) {
          pair('((', '))', 'circle') || pair('([', '])', 'stadium') || pair('{{', '}}', 'hex') ||
          pair('[', ']', 'rect') || pair('(', ')', 'round') || pair('{', '}', 'diamond');
        }
        return { id, text, shape };
      };
      const parseFlowchart = (src) => {
        const lines = (src || '').split(/\\r?\\n/).map(l => l.trim()).filter(Boolean);
        if (!lines.length) return null;
        const model = { dir: 'LR', nodes: [], links: [] };
        const byId = {};
        const addNode = (tok) => {
          const n = parseNodeToken(tok);
          if (!n) return null;
          if (!byId[n.id]) { byId[n.id] = { id: n.id, text: n.text != null ? n.text : n.id, shape: n.shape }; model.nodes.push(byId[n.id]); }
          else if (n.text != null) { byId[n.id].text = n.text; byId[n.id].shape = n.shape; }
          return n.id;
        };
        lines.forEach(line => {
          const dm = line.match(/^flowchart\\s+(LR|RL|TB|TD|BT)/i);
          if (dm) { const d = dm[1].toUpperCase(); model.dir = d === 'TD' ? 'TB' : d; return; }
          if (/--/.test(line)) {
            const em = line.match(/^(.+?)\\s*--+>?\\s*(?:\\|([^|]*)\\|)?\\s*(.+)$/);
            if (em) { const f = addNode(em[1]); const t = addNode(em[3]); if (f && t) model.links.push({ from: f, to: t, label: (em[2] || '').trim() }); return; }
          }
          addNode(line);
        });
        return model.nodes.length ? model : null;
      };

      const buildMermaidChrome = () => {
        const bar = makeBar(
          '<div class="pp-menu-wrap">' +
            '<button class="pp-btn" data-pp-pop="build">' + ICON.build + ' Build ' + ICON.chev + '</button>' +
            '<div class="pp-pop" data-pp-panel="build"></div>' +
          '</div>' +
          '<div class="pp-menu-wrap">' +
            '<button class="pp-btn" data-pp-pop="tpl">Templates ' + ICON.chev + '</button>' +
            '<div class="pp-pop" data-pp-panel="tpl">' +
              '<button class="pp-menu-item" data-tpl="flowchart">Flowchart</button>' +
              '<button class="pp-menu-item" data-tpl="sequence">Sequence</button>' +
              '<button class="pp-menu-item" data-tpl="gantt">Gantt</button>' +
              '<button class="pp-menu-item" data-tpl="pie">Pie</button>' +
              '<button class="pp-menu-item" data-tpl="mindmap">Mindmap</button>' +
              '<button class="pp-menu-item" data-tpl="class">Class</button>' +
            '</div>' +
          '</div>' +
          '<select class="pp-select" data-theme-sel title="Theme">' +
            '<option value="neutral">Neutral</option>' +
            '<option value="default">Default</option>' +
            '<option value="dark">Dark</option>' +
            '<option value="forest">Forest</option>' +
            '<option value="base">Base</option>' +
          '</select>' +
          '<div class="pp-menu-wrap">' +
            '<button class="pp-btn" data-pp-pop="src">' + ICON.code + ' Source</button>' +
            '<div class="pp-pop pp-pop-right" data-pp-panel="src">' +
              '<textarea class="pp-textarea" data-src-input spellcheck="false"></textarea>' +
              '<div style="margin-top:8px;text-align:right"><button class="pp-apply" data-src-apply>Apply</button></div>' +
            '</div>' +
          '</div>' +
          '<button class="pp-btn" data-pp-op="rerender" title="Reload diagram">' + ICON.reset + '</button>'
        );
        const closePops = wireChrome(bar);
        const srcInput = bar.querySelector('[data-src-input]');
        const themeSel = bar.querySelector('[data-theme-sel]');
        if (themeSel) themeSel.value = mermaidTheme;
        const buildPanel = bar.querySelector('[data-pp-panel="build"]');

        const shapes = [['rect', 'Rectangle'], ['round', 'Rounded'], ['stadium', 'Stadium'],
                        ['circle', 'Circle'], ['diamond', 'Diamond'], ['hex', 'Hexagon']];
        const ensureModel = () => {
          if (!mermaidModel) mermaidModel = parseFlowchart(mermaidSource) ||
            { dir: 'LR', nodes: [{ id: 'N1', text: 'Start', shape: 'rect' }], links: [] };
        };
        const genId = () => { let i = 1; while (mermaidModel.nodes.some(n => n.id === 'N' + i)) i++; return 'N' + i; };
        const applyModel = () => { mermaidSource = generateSource(mermaidModel); renderMermaid(); immediateCommit(); };
        const renderBuildPanel = () => {
          ensureModel();
          const m = mermaidModel;
          const nodeOpts = (sel) => m.nodes.map(n =>
            '<option value="' + n.id + '"' + (n.id === sel ? ' selected' : '') + '>' + escAttr(n.text || n.id) + '</option>').join('');
          let html = '<div class="pp-build">';
          html += '<div class="pp-build-row"><span class="pp-build-h">Direction</span>' +
            '<select class="pp-select" data-role="dir">' +
              ['LR', 'RL', 'TB', 'BT'].map(d => '<option value="' + d + '"' + (d === m.dir ? ' selected' : '') + '>' + d + '</option>').join('') +
            '</select></div>';
          html += '<div class="pp-build-h">Nodes</div>';
          m.nodes.forEach((n, i) => {
            html += '<div class="pp-build-row" data-node="' + i + '">' +
              '<input class="pp-input pp-in-sm" data-role="nodeText" value="' + escAttr(n.text) + '" placeholder="Label">' +
              '<select class="pp-select" data-role="nodeShape">' +
                shapes.map(s => '<option value="' + s[0] + '"' + (s[0] === n.shape ? ' selected' : '') + '>' + s[1] + '</option>').join('') +
              '</select>' +
              '<button class="pp-btn" data-role="delNode" title="Delete node">' + ICON.minus + '</button>' +
            '</div>';
          });
          html += '<button class="pp-apply pp-add" data-role="addNode">' + ICON.plus + ' Add node</button>';
          html += '<div class="pp-build-h">Connections</div>';
          m.links.forEach((l, i) => {
            html += '<div class="pp-build-row" data-link="' + i + '">' +
              '<select class="pp-select" data-role="linkFrom">' + nodeOpts(l.from) + '</select>' +
              '<span class="pp-arrow">&rarr;</span>' +
              '<select class="pp-select" data-role="linkTo">' + nodeOpts(l.to) + '</select>' +
              '<input class="pp-input pp-in-sm" data-role="linkLabel" value="' + escAttr(l.label || '') + '" placeholder="Label">' +
              '<button class="pp-btn" data-role="delLink" title="Delete connection">' + ICON.minus + '</button>' +
            '</div>';
          });
          html += '<button class="pp-apply pp-add" data-role="addLink">' + ICON.plus + ' Add connection</button>';
          html += '</div>';
          buildPanel.innerHTML = html;
        };

        buildPanel.addEventListener('input', event => {
          const role = event.target.getAttribute('data-role');
          const nodeRow = event.target.closest('[data-node]');
          if (nodeRow && role === 'nodeText') { mermaidModel.nodes[+nodeRow.dataset.node].text = event.target.value; applyModel(); return; }
          const linkRow = event.target.closest('[data-link]');
          if (linkRow && role === 'linkLabel') { mermaidModel.links[+linkRow.dataset.link].label = event.target.value; applyModel(); return; }
        });
        buildPanel.addEventListener('change', event => {
          const role = event.target.getAttribute('data-role');
          if (role === 'dir') { mermaidModel.dir = event.target.value; applyModel(); return; }
          const nodeRow = event.target.closest('[data-node]');
          if (nodeRow && role === 'nodeShape') { mermaidModel.nodes[+nodeRow.dataset.node].shape = event.target.value; applyModel(); return; }
          const linkRow = event.target.closest('[data-link]');
          if (linkRow && role === 'linkFrom') { mermaidModel.links[+linkRow.dataset.link].from = event.target.value; applyModel(); return; }
          if (linkRow && role === 'linkTo') { mermaidModel.links[+linkRow.dataset.link].to = event.target.value; applyModel(); return; }
        });
        buildPanel.addEventListener('click', event => {
          const btn = event.target.closest('[data-role]');
          if (!btn) return;
          const role = btn.getAttribute('data-role');
          if (role === 'addNode') { mermaidModel.nodes.push({ id: genId(), text: 'Node', shape: 'rect' }); applyModel(); renderBuildPanel(); }
          else if (role === 'delNode') { const i = +btn.closest('[data-node]').dataset.node; const id = mermaidModel.nodes[i].id; mermaidModel.nodes.splice(i, 1); mermaidModel.links = mermaidModel.links.filter(l => l.from !== id && l.to !== id); applyModel(); renderBuildPanel(); }
          else if (role === 'addLink') { if (mermaidModel.nodes.length) { const a = mermaidModel.nodes[0].id; const b = mermaidModel.nodes[mermaidModel.nodes.length > 1 ? 1 : 0].id; mermaidModel.links.push({ from: a, to: b, label: '' }); applyModel(); renderBuildPanel(); } }
          else if (role === 'delLink') { const i = +btn.closest('[data-link]').dataset.link; mermaidModel.links.splice(i, 1); applyModel(); renderBuildPanel(); }
        });

        bar.querySelectorAll('[data-tpl]').forEach(btn => btn.addEventListener('click', () => {
          mermaidSource = MERMAID_TEMPLATES[btn.getAttribute('data-tpl')];
          mermaidModel = parseFlowchart(mermaidSource);
          if (srcInput) srcInput.value = mermaidSource;
          renderMermaid(); immediateCommit(); closePops();
        }));
        if (themeSel) themeSel.addEventListener('change', event => {
          mermaidTheme = event.target.value; renderMermaid(); immediateCommit();
        });
        bar.addEventListener('click', event => {
          if (event.target.closest('[data-pp-pop="build"]')) renderBuildPanel();
          if (event.target.closest('[data-pp-pop="src"]') && srcInput) srcInput.value = mermaidSource;
          if (event.target.closest('[data-src-apply]')) {
            mermaidSource = srcInput ? srcInput.value : mermaidSource;
            mermaidModel = parseFlowchart(mermaidSource);
            renderMermaid(); immediateCommit(); closePops();
          }
          if (event.target.closest('[data-pp-op="rerender"]')) renderMermaid();
        });
      };

      // ---- Attachment block: a flexible media card ----
      const attachRoot = () => content.querySelector('.pp-attach')
        || content.querySelector('[data-penpal-kind="attachment"]') || content;
      const escAttr2 = (s) => String(s == null ? '' : s)
        .replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

      const youtubeId = (url) => {
        const m = url.match(/(?:youtube\\.com\\/(?:watch\\?v=|embed\\/|shorts\\/|live\\/)|youtu\\.be\\/)([\\w-]{11})/);
        return m ? m[1] : null;
      };
      const urlMediaType = (url) => {
        const u = url.split(/[?#]/)[0].toLowerCase();
        if (/\\.(png|jpe?g|gif|webp|svg|avif|bmp|heic)$/.test(u)) return 'image';
        if (/\\.(mp4|webm|mov|m4v|ogv)$/.test(u)) return 'video';
        if (/\\.(mp3|wav|m4a|aac|oga|ogg|flac)$/.test(u)) return 'audio';
        return null;
      };
      const mediaMarkup = (type, src, name) => {
        if (type === 'image') return '<img src="' + escAttr2(src) + '" alt="' + escAttr2(name) + '">';
        if (type === 'video') return '<video src="' + escAttr2(src) + '" controls playsinline></video>';
        if (type === 'audio') return '<audio src="' + escAttr2(src) + '" controls></audio>';
        if (type === 'youtube') return '<iframe src="https://www.youtube.com/embed/' + escAttr2(src) + '" '
          + 'allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" '
          + 'allowfullscreen></iframe>';
        return '<a class="pp-link" href="' + escAttr2(src) + '" target="_blank" rel="noopener">'
          + '<span class="pp-link-ic">🔗</span><span class="pp-link-t">' + escAttr2(name || src) + '</span></a>';
      };
      const setAttachment = (type, src, name) => {
        const root = attachRoot();
        root.querySelectorAll('.pp-attach-ui').forEach(el => el.remove());
        const fig = doc.createElement('figure');
        fig.innerHTML = mediaMarkup(type, src, name);
        root.querySelectorAll('figure').forEach(el => el.remove());
        root.appendChild(fig);
        immediateCommit();
        renderAttach();
      };
      const embedURL = (raw) => {
        let url = (raw || '').trim();
        if (!url) return;
        if (!/^https?:\\/\\//i.test(url) && !url.startsWith('data:')) url = 'https://' + url;
        const yt = youtubeId(url);
        if (yt) return setAttachment('youtube', yt, '');
        const t = urlMediaType(url);
        if (t) return setAttachment(t, url, '');
        setAttachment('link', url, url);
      };
      const readAttachFile = (file) => {
        if (!file) return;
        const reader = new FileReader();
        reader.onload = () => {
          const mt = file.type || '';
          const type = mt.startsWith('image/') ? 'image'
            : mt.startsWith('video/') ? 'video'
            : mt.startsWith('audio/') ? 'audio' : 'link';
          setAttachment(type, reader.result, file.name);
        };
        reader.readAsDataURL(file);
      };
      const renderAttach = () => {
        const root = attachRoot();
        root.querySelectorAll('.pp-attach-ui').forEach(el => el.remove());
        // Only the empty state shows on-page fields; once media is embedded the
        // card disappears (Replace/Clear lives in the block menu & Studio) so
        // the attachment reads clean on the page.
        if (root.querySelector('figure')) return;
        const ui = doc.createElement('div');
        ui.className = 'pp-attach-ui';
        ui.style.cssText = 'flex:1;display:flex;';
        ui.innerHTML =
          '<div class="pp-attach-card">' +
            '<div class="pp-at-title">Add attachment</div>' +
            '<div class="pp-at-sub">Image, video, audio, a YouTube link, a live image URL, or any link.</div>' +
            '<div class="pp-at-row">' +
              '<input class="pp-at-url" type="url" inputmode="url" placeholder="Paste a link and press Enter" data-attach-url>' +
              '<button class="pp-at-go" data-attach-embed>Embed</button>' +
            '</div>' +
            '<label class="pp-at-upload">Upload from device' +
              '<input type="file" accept="image/*,video/*,audio/*" hidden data-attach-file></label>' +
          '</div>';
        root.appendChild(ui);
      };
      const buildAttachment = () => { renderAttach(); };

      // Attachment field interactions (event-delegated so they survive
      // re-render). File/URL commits build the media and persist it.
      doc.addEventListener('click', event => {
        if (kind !== 'attachment') return;
        if (event.target.closest('[data-attach-embed]')) {
          const inp = attachRoot().querySelector('[data-attach-url]');
          embedURL(inp && inp.value);
        }
      });
      doc.addEventListener('change', event => {
        if (kind === 'attachment' && event.target.matches('[data-attach-file]')) {
          readAttachFile(event.target.files && event.target.files[0]);
        }
      }, true);
      doc.addEventListener('keydown', event => {
        if (kind === 'attachment' && event.key === 'Enter' && event.target.matches('[data-attach-url]')) {
          event.preventDefault();
          embedURL(event.target.value);
        }
      });

      // ---- Dispatch by kind ----
      if (kind === 'text') buildTextChrome();
      else if (kind === 'image') buildImageChrome();
      else if (kind === 'table') buildTableChrome();
      else if (kind === 'checklist') buildChecklistChrome();
      else if (kind === 'mermaid') { renderMermaid(); buildMermaidChrome(); }
      else if (kind === 'attachment') buildAttachment();

      editable();
    })();
    """

    private(set) var block: CodeBlock

    private let webView: WKWebView
    private let outline = CAShapeLayer()
    /// Quiet "accepting input" ring shown while the block is active.
    private let activeRing = CAShapeLayer()
    private var handles: [UIView] = []
    private let toolbar = UIStackView()
    private lazy var contextButton = makeMenuButton(
        system: block.resolvedKind.toolbarIcon,
        menu: makeContextMenu()
    )

    /// Fired when geometry changes (move/resize finished) so the note persists.
    var onChange: ((CodeBlock) -> Void)?
    /// Fired when the user taps the block's edit-code button.
    var onEditCode: ((CodeBlockView) -> Void)?
    /// Fired when the user taps the block's delete button.
    var onDelete: ((CodeBlockView) -> Void)?
    var onDuplicate: ((CodeBlockView) -> Void)?
    var onBringForward: ((CodeBlockView) -> Void)?
    var onSendBackward: ((CodeBlockView) -> Void)?

    private var isEditing = false
    private let minSize = CGSize(width: 80, height: 60)
    private let handleSize: CGFloat = 24

    /// TAP-ACTIVATE — "the Pencil writes, the hand operates — on request".
    ///
    /// A block can render a live thing: a simulation, a slider, a submit
    /// button. But it must never swallow touches while the user is just
    /// writing, and it usually sits BELOW the ink so annotations stay on top —
    /// which also puts its controls out of reach. So a block has two states:
    ///
    ///   * inactive (default) -> asleep below the ink and COMPLETELY
    ///                           transparent to touches: the Pencil inks over
    ///                           it like plain paper, and a finger tap is
    ///                           noticed by the page's own tap recognizer
    ///                           (MagicPaperView), which wakes the block.
    ///   * active             -> raised above the ink by the owner, and its
    ///                           web content receives touches, so its buttons
    ///                           and controls actually work. A pencil landing
    ///                           on it is caught by the page's pencil
    ///                           recognizer, which puts it back to sleep.
    ///
    /// Touch-type routing deliberately does NOT happen in `hitTest`:
    /// `event.allTouches` is unreliable at touch-down, and misreading a
    /// pencil as a finger made strokes that started on a block vanish.
    /// Gesture recognizers see the real `UITouch.type`, so the page-level
    /// recognizers decide; the block just claims all or nothing.
    ///
    /// While a finger is down on an ACTIVE block, `onFingerActive` suspends
    /// the canvas's drawing gesture — otherwise PencilKit claims the touch
    /// and draws a stroke instead of letting the button press land.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            applyInteractionState()
        }
    }

    /// Fired when a finger touch starts / ends on a live block, so the owner
    /// can stop the ink canvas competing for that touch.
    var onFingerActive: ((Bool) -> Void)?

    /// Zero-duration press used purely as a SIGNAL that a finger is on the
    /// block. It never consumes the touch (`cancelsTouchesInView = false`),
    /// so the web content still receives the full sequence.
    private lazy var fingerGuard: UILongPressGestureRecognizer = {
        let g = UILongPressGestureRecognizer(target: self,
                                             action: #selector(handleFingerGuard(_:)))
        g.minimumPressDuration = 0
        g.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        g.cancelsTouchesInView = false
        g.delaysTouchesBegan = false
        g.delaysTouchesEnded = false
        g.delegate = self
        return g
    }()

    private lazy var bodyPan: UIPanGestureRecognizer = {
        let p = UIPanGestureRecognizer(target: self, action: #selector(handleBodyPan(_:)))
        p.delegate = self
        return p
    }()

    // MARK: Init

    init(block: CodeBlock) {
        self.block = block
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // A block is meant to RUN — be explicit rather than relying on the
        // default, which has changed across WebKit versions.
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.addUserScript(WKUserScript(
            source: Self.editingBridgeJavaScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: block.frame)
        config.userContentController.add(self, name: "penpalBlockChanged")
        setup()
        webView.navigationDelegate = self
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "penpalBlockChanged")
    }

    private func setup() {
        backgroundColor = .clear
        clipsToBounds = false

        // Touch routing is decided in `hitTest` (see `isActive`), not by making
        // the web content permanently passive: in normal mode a finger may
        // operate it while the Pencil passes through to the ink canvas, and in
        // edit mode our own move/resize gestures win outright.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isUserInteractionEnabled = false
        webView.clipsToBounds = true
        webView.layer.cornerRadius = 6
        webView.layer.cornerCurve = .continuous
        // Let a programmatic focus (from a single tap that wakes the block)
        // raise the keyboard, instead of demanding a second, "real" tap.
        Self.allowKeyboardWithoutUserInteraction()
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
        addSubview(webView)

        // Live ring (normal mode, active only). Below the ink visually, like
        // the block itself — it marks the block, it doesn't float over ink.
        activeRing.fillColor = UIColor.clear.cgColor
        activeRing.strokeColor = UIColor.tintColor.withAlphaComponent(0.55).cgColor
        activeRing.lineWidth = 2
        activeRing.isHidden = true
        layer.addSublayer(activeRing)

        // Dashed selection outline (edit mode only).
        outline.fillColor = UIColor.clear.cgColor
        outline.strokeColor = UIColor.tintColor.withAlphaComponent(0.9).cgColor
        outline.lineWidth = 1.5
        outline.lineDashPattern = [6, 4]
        outline.isHidden = true
        layer.addSublayer(outline)

        // Four corner resize handles (edit mode only).
        for corner in 0..<4 {
            let h = UIView()
            h.tag = corner
            h.backgroundColor = .systemBackground
            h.layer.borderColor = UIColor.tintColor.cgColor
            h.layer.borderWidth = 2
            h.layer.cornerRadius = handleSize / 2
            h.isHidden = true
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleResize(_:)))
            h.addGestureRecognizer(pan)
            addSubview(h)
            handles.append(h)
        }

        // Floating toolbar above the block (edit mode only).
        toolbar.axis = .horizontal
        toolbar.spacing = 8
        toolbar.alignment = .center
        toolbar.isLayoutMarginsRelativeArrangement = true
        toolbar.directionalLayoutMargins = .init(top: 6, leading: 10, bottom: 6, trailing: 10)
        toolbar.backgroundColor = UIColor.secondarySystemBackground
        toolbar.layer.cornerRadius = 16
        toolbar.layer.cornerCurve = .continuous
        toolbar.layer.shadowColor = UIColor.black.cgColor
        toolbar.layer.shadowOpacity = 0.12
        toolbar.layer.shadowRadius = 6
        toolbar.layer.shadowOffset = CGSize(width: 0, height: 2)
        toolbar.isHidden = true
        toolbar.addArrangedSubview(contextButton)
        toolbar.addArrangedSubview(makeToolButton(system: "pencil",
                                                  action: #selector(tapEditCode)))
        toolbar.addArrangedSubview(makeToolButton(system: "plus.square.on.square",
                                                  action: #selector(tapDuplicate)))
        toolbar.addArrangedSubview(makeMenuButton(
            system: "square.2.layers.3d",
            menu: UIMenu(children: [
                UIAction(title: "Bring Forward", image: UIImage(systemName: "square.2.layers.3d.top.filled")) {
                    [weak self] _ in guard let self else { return }; self.onBringForward?(self)
                },
                UIAction(title: "Send Backward", image: UIImage(systemName: "square.2.layers.3d.bottom.filled")) {
                    [weak self] _ in guard let self else { return }; self.onSendBackward?(self)
                },
            ])
        ))
        toolbar.addArrangedSubview(makeToolButton(system: "trash",
                                                  action: #selector(tapDelete),
                                                  destructive: true))
        addSubview(toolbar)

        addGestureRecognizer(bodyPan)
        addGestureRecognizer(fingerGuard)
        // Safe default before the owner configures editing / live state:
        // no stray drags, no touch capture.
        applyInteractionState()
    }

    /// The web process can be killed under memory pressure (the device logs
    /// `WebProcessProxy::didBecomeUnresponsive` / `mach_vm_allocate failed`
    /// first). The block then renders its last frame but is DEAD — it looks
    /// perfectly fine and simply ignores every tap, which is indistinguishable
    /// from a touch-routing bug. Reload so it comes back by itself.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reload()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyBlockMode()
    }

    /// WKWebView won't raise the keyboard for a *programmatic* focus unless it
    /// believes the user is interacting — which breaks our single-tap inline
    /// edit (the tap that wakes a block can't reach the web content, so we
    /// focus in code). This flips WebKit's private `WKContentView` focus hook
    /// to always report interaction. It runs once and fails soft: if the
    /// selector ever disappears, editing simply falls back to a second tap.
    private static let allowKeyboard: Void = {
        guard let cls = NSClassFromString("WKContentView") else { return }
        let sel = NSSelectorFromString(
            "_elementDidFocus:userIsInteracting:blurPreviousNode:activityStateChanges:userObject:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        typealias Orig = @convention(c)
            (AnyObject, Selector, UnsafeRawPointer, Bool, Bool, Bool, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Orig.self)
        let block: @convention(block)
            (AnyObject, UnsafeRawPointer, Bool, Bool, Bool, AnyObject?) -> Void = {
                me, node, _, blur, changes, userObject in
                original(me, sel, node, true, blur, changes, userObject)
            }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }()

    private static func allowKeyboardWithoutUserInteraction() { _ = allowKeyboard }

    @objc private func handleFingerGuard(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            onFingerActive?(true)
        case .ended, .cancelled, .failed:
            onFingerActive?(false)
        default:
            break
        }
    }

    private func makeToolButton(system: String, action: Selector, destructive: Bool = false) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: system)
        config.baseForegroundColor = destructive ? .systemRed : .tintColor
        config.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        config.contentInsets = .init(top: 4, leading: 6, bottom: 4, trailing: 6)
        let b = UIButton(configuration: config)
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    private func makeMenuButton(system: String, menu: UIMenu) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: system)
        config.baseForegroundColor = .tintColor
        config.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        config.contentInsets = .init(top: 4, leading: 6, bottom: 4, trailing: 6)
        let button = UIButton(configuration: config)
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        return button
    }

    private func action(_ title: String, system: String,
                        command: String) -> UIAction {
        UIAction(title: title, image: UIImage(systemName: system)) { [weak self] _ in
            self?.runBlockCommand(command)
        }
    }

    private func makeContextMenu() -> UIMenu {
        switch block.resolvedKind {
        case .table:
            return UIMenu(title: "Table", children: [
                action("Add Row", system: "rectangle.split.1x2", command: "table:addRow"),
                action("Remove Row", system: "minus.rectangle", command: "table:removeRow"),
                action("Add Column", system: "rectangle.split.2x1", command: "table:addColumn"),
                action("Remove Column", system: "minus.rectangle", command: "table:removeColumn"),
                action("Toggle Header", system: "bold", command: "table:toggleHeader"),
                UIMenu(title: "Cell Alignment", image: UIImage(systemName: "text.alignleft"),
                       children: [
                        action("Left", system: "text.alignleft", command: "table:alignLeft"),
                        action("Center", system: "text.aligncenter", command: "table:alignCenter"),
                        action("Right", system: "text.alignright", command: "table:alignRight"),
                       ]),
                action("Merge With Next Cell", system: "rectangle.2.swap", command: "table:merge"),
                action("Split Cell", system: "rectangle.split.2x1", command: "table:split"),
                action("Clear Table", system: "eraser", command: "table:clear"),
            ])
        case .checklist:
            return UIMenu(title: "Checklist", children: [
                action("Add Item", system: "plus", command: "checklist:add"),
                action("Remove Last Item", system: "minus", command: "checklist:remove"),
                action("Clear Completed", system: "checkmark.circle", command: "checklist:clearCompleted"),
                action("Uncheck All", system: "circle", command: "checklist:uncheck"),
            ])
        case .text:
            return UIMenu(title: "Text", children: [
                action("Body Style", system: "textformat", command: "text:body"),
                action("Heading Style", system: "textformat.size.larger", command: "text:heading"),
                action("Callout Style", system: "quote.bubble", command: "text:callout"),
                action("Align Left", system: "text.alignleft", command: "text:left"),
                action("Align Center", system: "text.aligncenter", command: "text:center"),
            ])
        case .image:
            return UIMenu(title: "Image", children: [
                action("Fit", system: "arrow.down.right.and.arrow.up.left", command: "image:fit"),
                action("Fill", system: "arrow.up.left.and.arrow.down.right", command: "image:fill"),
                action("Rotate Left", system: "rotate.left", command: "image:rotateLeft"),
                action("Rotate Right", system: "rotate.right", command: "image:rotateRight"),
            ])
        case .attachment:
            return UIMenu(title: "Attachment", children: [
                action("Replace / Clear", system: "arrow.triangle.2.circlepath", command: "attachment:clear"),
                action("Fit", system: "arrow.down.right.and.arrow.up.left", command: "attachment:fit"),
                action("Fill", system: "arrow.up.left.and.arrow.down.right", command: "attachment:fill"),
            ])
        case .mermaid:
            return UIMenu(title: "Diagram", children: [
                UIAction(title: "Edit Mermaid Source", image: UIImage(systemName: "pencil")) {
                    [weak self] _ in guard let self else { return }; self.onEditCode?(self)
                },
                UIAction(title: "Reload Diagram", image: UIImage(systemName: "arrow.clockwise")) {
                    [weak self] _ in self?.reload()
                },
            ])
        case .web:
            return UIMenu(title: "Web Block", children: [
                UIAction(title: "Edit Source", image: UIImage(systemName: "pencil")) {
                    [weak self] _ in guard let self else { return }; self.onEditCode?(self)
                },
                UIAction(title: "Reload", image: UIImage(systemName: "arrow.clockwise")) {
                    [weak self] _ in self?.reload()
                },
            ])
        case .code:
            return UIMenu(title: "Code Block", children: [
                UIAction(title: "Edit Source", image: UIImage(systemName: "pencil")) {
                    [weak self] _ in guard let self else { return }; self.onEditCode?(self)
                },
                UIAction(title: "Run / Reload", image: UIImage(systemName: "play")) {
                    [weak self] _ in self?.reload()
                },
            ])
        }
    }

    // MARK: Content

    func reload() {
        webView.loadHTMLString(CodedPaper.blockDocument(from: block.html),
                               baseURL: Self.contentBaseURL)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "penpalBlockChanged",
              let body = message.body as? [String: Any],
              let html = body["html"] as? String,
              !html.isEmpty,
              html != block.html else { return }
        block.html = html
        if block.kind == nil { block.kind = block.resolvedKind }
        onChange?(block)
    }

    private func runBlockCommand(_ command: String) {
        webView.evaluateJavaScript("window.penpalBlockCommand('\(command)')") {
            [weak self] _, error in
            if error != nil { self?.reload() }
        }
    }

    /// Apply an edited model (new code and/or geometry) and re-render.
    func apply(_ newBlock: CodeBlock) {
        let htmlChanged = newBlock.html != block.html
        let kindChanged = newBlock.resolvedKind != block.resolvedKind
        block = newBlock
        frame = newBlock.frame
        if kindChanged {
            contextButton.configuration?.image = UIImage(systemName: block.resolvedKind.toolbarIcon)
            contextButton.menu = makeContextMenu()
        }
        setNeedsLayout()
        if htmlChanged { reload() }
    }

    // MARK: Edit mode

    func setEditing(_ editing: Bool) {
        isEditing = editing
        outline.isHidden = !editing
        toolbar.isHidden = !editing
        handles.forEach { $0.isHidden = !editing }
        applyInteractionState()
        setNeedsLayout()
    }

    /// Who may receive touches right now. The view itself always accepts them
    /// so `hitTest` can route by touch type; what changes is who is behind it.
    private func applyInteractionState() {
        isUserInteractionEnabled = true
        // Move/resize must not fire from a stray finger drag on a live block.
        bodyPan.isEnabled = isEditing
        // A finger operating the ACTIVE block suspends the canvas's drawing
        // gesture, so the touch never turns into a stray ink dot.
        fingerGuard.isEnabled = !isEditing && isActive
        // While editing, the block is an OBJECT being arranged (move/resize),
        // not a running widget — the web content must not swallow the drag.
        // Rich formatting happens in the Studio, not on the page. Inactive
        // blocks are inert too: content only runs once activated.
        webView.isUserInteractionEnabled = !isEditing && isActive
        applyBlockMode()
        updateActiveHighlight()
    }

    /// Tell the web runtime which editing surface to present. Chrome is fully
    /// hidden in "view" so out of Arrange the block reads as plain paper.
    private func applyBlockMode() {
        let mode = isEditing ? "arrange" : "view"
        webView.evaluateJavaScript(
            "window.penpalSetMode && window.penpalSetMode('\(mode)')",
            completionHandler: nil)
    }

    /// Drop the caret into the editable text the user tapped and start editing
    /// inline — so waking a block and editing it are a single tap, no trip to
    /// the Studio for a quick change. `point` is in this view's coordinates;
    /// taps on real controls (checkboxes, buttons) are ignored by the runtime.
    func beginInlineEdit(at point: CGPoint) {
        guard !isEditing else { return }
        let p = convert(point, to: webView)
        let js = "window.penpalBeginEdit && window.penpalBeginEdit(\(p.x), \(p.y))"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// "This block is live — a tap here presses IT, not the page."
    ///
    /// Deliberately NOT a lift shadow: an active block no longer rises above
    /// the ink (that would hide the very annotation drawn on it), so anything
    /// suggesting elevation would be a lie. A thin tinted ring reads as
    /// "focused / accepting input" without implying the block moved, and sits
    /// inside the bounds so it never overlaps neighbouring writing.
    private func updateActiveHighlight() {
        // No active ring: an awake block should read as an integral part of the
        // paper, not a selected "component". Distinction comes from the content
        // itself; only Arrange mode shows chrome (the dashed outline + handles).
        activeRing.isHidden = true
    }

    // The toolbar sits above the block and the resize handles straddle the
    // corners — both extend outside `bounds`, where the default hit-test would
    // return nil. Extend the touch area to cover them while editing so the
    // edit-code / delete buttons and every handle are actually tappable.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, isUserInteractionEnabled else { return nil }

        if isEditing {
            if let hit = super.hitTest(point, with: event) { return hit }
            for sub in ([toolbar] as [UIView]) + handles where !sub.isHidden {
                let p = sub.convert(point, from: self)
                if let hit = sub.hitTest(p, with: event) { return hit }
            }
            return nil
        }

        // Normal mode the block is ALWAYS below the ink and never claims a
        // touch through the ordinary front-to-back hit-test — not even when
        // active. Raising it would hide the annotation drawn on top of it,
        // which is the whole point of a block living on a page.
        //
        // Touches reach an active block by REDIRECTION instead: the canvas
        // (see BlockRoutingCanvasView) sends touches landing inside the
        // active block's frame straight here, via `interactiveHit`.
        // Visual order and touch order are simply two different things.
        return nil
    }

    /// Entry point for the canvas's redirect: resolve a point (in this view's
    /// coordinates) to the web content, bypassing z-order entirely.
    func interactiveHit(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isActive, !isEditing, !isHidden else { return nil }
        guard bounds.contains(point) else { return nil }
        return webView.hitTest(convert(point, to: webView), with: event) ?? webView
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        guard isEditing else { return false }
        if !toolbar.isHidden, toolbar.frame.contains(point) { return true }
        for h in handles where !h.isHidden && h.frame.contains(point) { return true }
        return false
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        webView.frame = bounds
        outline.frame = bounds
        outline.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                                    cornerRadius: 6).cgPath
        updateActiveHighlight()

        let s = handleSize
        let positions = [
            CGPoint(x: 0, y: 0),                                  // TL
            CGPoint(x: bounds.width, y: 0),                       // TR
            CGPoint(x: 0, y: bounds.height),                      // BL
            CGPoint(x: bounds.width, y: bounds.height),           // BR
        ]
        for (i, h) in handles.enumerated() {
            h.frame = CGRect(x: positions[i].x - s / 2,
                             y: positions[i].y - s / 2,
                             width: s, height: s)
        }

        // Size the toolbar to its content so the buttons never clip.
        let fit = toolbar.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize,
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .fittingSizeLevel)
        let tw = max(fit.width, 72)
        let th = max(fit.height, 32)
        toolbar.frame = CGRect(x: 0, y: -(th + 8), width: tw, height: th)
    }

    // MARK: Gestures

    @objc private func handleBodyPan(_ g: UIPanGestureRecognizer) {
        guard isEditing else { return }
        let t = g.translation(in: superview)
        var f = frame
        f.origin.x += t.x
        f.origin.y = max(0, f.origin.y + t.y)
        f.origin.x = max(0, f.origin.x)
        frame = f
        g.setTranslation(.zero, in: superview)
        if g.state == .ended || g.state == .cancelled { commitGeometry() }
    }

    @objc private func handleResize(_ g: UIPanGestureRecognizer) {
        guard isEditing, let corner = g.view?.tag else { return }
        let t = g.translation(in: superview)
        var f = frame
        switch corner {
        case 0: // top-left
            f.origin.x += t.x; f.origin.y += t.y
            f.size.width -= t.x; f.size.height -= t.y
        case 1: // top-right
            f.origin.y += t.y
            f.size.width += t.x; f.size.height -= t.y
        case 2: // bottom-left
            f.origin.x += t.x
            f.size.width -= t.x; f.size.height += t.y
        default: // bottom-right
            f.size.width += t.x; f.size.height += t.y
        }
        // Enforce a minimum without letting the anchored edge drift.
        if f.size.width < minSize.width {
            if corner == 0 || corner == 2 { f.origin.x = frame.maxX - minSize.width }
            f.size.width = minSize.width
        }
        if f.size.height < minSize.height {
            if corner == 0 || corner == 1 { f.origin.y = frame.maxY - minSize.height }
            f.size.height = minSize.height
        }
        f.origin.x = max(0, f.origin.x)
        f.origin.y = max(0, f.origin.y)
        frame = f
        setNeedsLayout()
        g.setTranslation(.zero, in: superview)
        if g.state == .ended || g.state == .cancelled { commitGeometry() }
    }

    private func commitGeometry() {
        block.x = frame.origin.x
        block.y = frame.origin.y
        block.width = frame.size.width
        block.height = frame.size.height
        onChange?(block)
    }

    @objc private func tapEditCode() { onEditCode?(self) }
    @objc private func tapDuplicate() { onDuplicate?(self) }
    @objc private func tapDelete() { onDelete?(self) }

    // Body pan must ignore touches that land on a handle or a control, so
    // resizing and the toolbar buttons win over dragging the whole block.
    /// The finger signal must never block the web content's own gestures —
    /// it only observes.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g == fingerGuard || other == fingerGuard
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if g == fingerGuard { return touch.type == .direct }
        guard g == bodyPan else { return true }
        if let v = touch.view {
            if handles.contains(v) { return false }
            if v is UIControl { return false }
            if v.isDescendant(of: toolbar) { return false }
        }
        return true
    }
}

private extension PageBlockKind {
    var toolbarIcon: String {
        switch self {
        case .code: "chevron.left.forwardslash.chevron.right"
        case .mermaid: "point.3.connected.trianglepath.dotted"
        case .text: "text.quote"
        case .table: "tablecells"
        case .checklist: "checklist"
        case .image: "photo"
        case .web: "globe"
        case .attachment: "paperclip"
        }
    }
}

// MARK: - Code editor sheet (SwiftUI)

/// Presented from the page's edit mode to edit a single block's source.
/// Mirrors `CodedPaperView`'s paper/code toggle: preview the rendered block
/// or edit its HTML/CSS/JS.
struct CodeBlockEditorView: View {
    let block: CodeBlock
    let onSave: (CodeBlock) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var html: String
    @State private var mode: Mode = .code

    private enum Mode: String, CaseIterable { case code, preview }

    init(block: CodeBlock, onSave: @escaping (CodeBlock) -> Void) {
        self.block = block
        self.onSave = onSave
        _html = State(initialValue: block.html)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .code:
                    TextEditor(text: $html)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        .padding(.horizontal, 8)
                case .preview:
                    BlockPreview(html: html)
                        .background(Color(.secondarySystemBackground))
                }
            }
            .navigationTitle("Code Block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Mode", selection: $mode) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right").tag(Mode.code)
                        Image(systemName: "eye").tag(Mode.preview)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        var updated = block
                        updated.html = html
                        onSave(updated)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct BlockPreview: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastHTML = "" }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        web.loadHTMLString(CodedPaper.blockDocument(from: html),
                           baseURL: CodeBlockView.contentBaseURL)
    }
}
