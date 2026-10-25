/* SnapShackle icon set: Lucide 1.54.0 (the version Lazarette uses), bundled so the studio stays offline.
 * Icons: https://lucide.dev  Source: https://github.com/lucide-icons/lucide/tree/1.54.0/icons
 *
 * ISC License
 *
 * Copyright (c) 2026 Lucide Icons and Contributors
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 * ---
 *
 * The following Lucide icons are derived from the Feather project:
 *
 * airplay, alert-circle, alert-octagon, alert-triangle, aperture, arrow-down-circle, arrow-down-left, arrow-down-right, arrow-down, arrow-left-circle, arrow-left, arrow-right-circle, arrow-right, arrow-up-circle, arrow-up-left, arrow-up-right, arrow-up, at-sign, calendar, cast, check, chevron-down, chevron-left, chevron-right, chevron-up, chevrons-down, chevrons-left, chevrons-right, chevrons-up, circle, clipboard, clock, code, columns, command, compass, corner-down-left, corner-down-right, corner-left-down, corner-left-up, corner-right-down, corner-right-up, corner-up-left, corner-up-right, crosshair, database, divide-circle, divide-square, dollar-sign, download, external-link, feather, frown, hash, headphones, help-circle, info, italic, key, layout, life-buoy, link-2, link, loader, lock, log-in, log-out, maximize, meh, minimize, minimize-2, minus-circle, minus-square, minus, monitor, moon, more-horizontal, more-vertical, move, music, navigation-2, navigation, octagon, pause-circle, percent, plus-circle, plus-square, plus, power, radio, rss, search, server, share, shopping-bag, sidebar, smartphone, smile, square, table-2, tablet, target, terminal, trash-2, trash, triangle, tv, type, upload, x-circle, x-octagon, x-square, x, zoom-in, zoom-out
 *
 * The MIT License (MIT) (for the icons listed above)
 *
 * Copyright (c) 2013-present Cole Bemis
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
(() => {
'use strict';
const PATHS = {
  "region": "<path d=\"M3 7V5a2 2 0 0 1 2-2h2\"/> <path d=\"M17 3h2a2 2 0 0 1 2 2v2\"/> <path d=\"M21 17v2a2 2 0 0 1-2 2h-2\"/> <path d=\"M7 21H5a2 2 0 0 1-2-2v-2\"/> <path d=\"M7 12h10\"/>",
  "desktop": "<rect width=\"20\" height=\"14\" x=\"2\" y=\"3\" rx=\"2\"/> <line x1=\"8\" x2=\"16\" y1=\"21\" y2=\"21\"/> <line x1=\"12\" x2=\"12\" y1=\"17\" y2=\"21\"/>",
  "record": "<circle cx=\"12\" cy=\"12\" r=\"1\"/> <circle cx=\"12\" cy=\"12\" r=\"10\"/>",
  "stop": "<rect width=\"18\" height=\"18\" x=\"3\" y=\"3\" rx=\"2\"/>",
  "gif": "<rect width=\"18\" height=\"18\" x=\"3\" y=\"3\" rx=\"2\"/> <path d=\"M7 3v18\"/> <path d=\"M3 7.5h4\"/> <path d=\"M3 12h18\"/> <path d=\"M3 16.5h4\"/> <path d=\"M17 3v18\"/> <path d=\"M17 7.5h4\"/> <path d=\"M17 16.5h4\"/>",
  "help": "<circle cx=\"12\" cy=\"12\" r=\"10\"/> <path d=\"M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3\"/> <path d=\"M12 17h.01\"/>",
  "refresh": "<path d=\"M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8\"/> <path d=\"M21 3v5h-5\"/> <path d=\"M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16\"/> <path d=\"M8 16H3v5\"/>",
  "window": "<rect x=\"2\" y=\"4\" width=\"20\" height=\"16\" rx=\"2\"/> <path d=\"M10 4v4\"/> <path d=\"M2 8h20\"/> <path d=\"M6 4v4\"/>",
  "browser": "<circle cx=\"12\" cy=\"12\" r=\"10\"/> <path d=\"M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20\"/> <path d=\"M2 12h20\"/>",
  "open": "<path d=\"M10.3 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v10l-3.1-3.1a2 2 0 0 0-2.814.014L6 21\"/> <path d=\"m14 19.5 3-3 3 3\"/> <path d=\"M17 22v-5.5\"/> <circle cx=\"9\" cy=\"9\" r=\"2\"/>",
  "copy": "<rect width=\"14\" height=\"14\" x=\"8\" y=\"8\" rx=\"2\" ry=\"2\"/> <path d=\"M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2\"/>",
  "download": "<path d=\"M12 15V3\"/> <path d=\"M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4\"/> <path d=\"m7 10 5 5 5-5\"/>",
  "select": "<path d=\"M4.037 4.688a.495.495 0 0 1 .651-.651l16 6.5a.5.5 0 0 1-.063.947l-6.124 1.58a2 2 0 0 0-1.438 1.435l-1.579 6.126a.5.5 0 0 1-.947.063z\"/>",
  "arrow": "<path d=\"M13 5H19V11\"/> <path d=\"M19 5L5 19\"/>",
  "rectangle": "<rect width=\"18\" height=\"18\" x=\"3\" y=\"3\" rx=\"2\"/>",
  "ellipse": "<circle cx=\"12\" cy=\"12\" r=\"10\"/>",
  "line": "<path d=\"M22 2 2 22\"/>",
  "pen": "<path d=\"M13 21h8\"/> <path d=\"M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z\"/>",
  "highlight": "<path d=\"m9 11-6 6v3h9l3-3\"/> <path d=\"m22 12-4.6 4.6a2 2 0 0 1-2.8 0l-5.2-5.2a2 2 0 0 1 0-2.8L14 4\"/>",
  "text": "<path d=\"M12 4v16\"/> <path d=\"M4 7V5a1 1 0 0 1 1-1h14a1 1 0 0 1 1 1v2\"/> <path d=\"M9 20h6\"/>",
  "step": "<path d=\"M11 5h10\"/> <path d=\"M11 12h10\"/> <path d=\"M11 19h10\"/> <path d=\"M4 4h1v5\"/> <path d=\"M4 9h2\"/> <path d=\"M6.5 20H3.4c0-1 2.6-1.925 2.6-3.5a1.5 1.5 0 0 0-2.6-1.02\"/>",
  "crop": "<path d=\"M6 2v14a2 2 0 0 0 2 2h14\"/> <path d=\"M18 22V8a2 2 0 0 0-2-2H2\"/>",
  "redact": "<path d=\"M5 3a2 2 0 0 0-2 2\"/> <path d=\"M19 3a2 2 0 0 1 2 2\"/> <path d=\"M21 19a2 2 0 0 1-2 2\"/> <path d=\"M5 21a2 2 0 0 1-2-2\"/> <path d=\"M9 3h1\"/> <path d=\"M9 21h1\"/> <path d=\"M14 3h1\"/> <path d=\"M14 21h1\"/> <path d=\"M3 9v1\"/> <path d=\"M21 9v1\"/> <path d=\"M3 14v1\"/> <path d=\"M21 14v1\"/>",
  "pixelate": "<rect width=\"18\" height=\"18\" x=\"3\" y=\"3\" rx=\"2\"/> <path d=\"M3 9h18\"/> <path d=\"M3 15h18\"/> <path d=\"M9 3v18\"/> <path d=\"M15 3v18\"/>",
  "blur": "<path d=\"M12 22a7 7 0 0 0 7-7c0-2-1-3.9-3-5.5s-3.5-4-4-6.5c-.5 2.5-2 4.9-4 6.5C6 11.1 5 13 5 15a7 7 0 0 0 7 7z\"/>",
  "undo": "<path d=\"M9 14 4 9l5-5\"/> <path d=\"M4 9h10.5a5.5 5.5 0 0 1 5.5 5.5a5.5 5.5 0 0 1-5.5 5.5H11\"/>",
  "redo": "<path d=\"m15 14 5-5-5-5\"/> <path d=\"M20 9H9.5A5.5 5.5 0 0 0 4 14.5A5.5 5.5 0 0 0 9.5 20H13\"/>",
  "delete": "<path d=\"M10 11v6\"/> <path d=\"M14 11v6\"/> <path d=\"M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6\"/> <path d=\"M3 6h18\"/> <path d=\"M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2\"/>",
  "duplicate": "<line x1=\"15\" x2=\"15\" y1=\"12\" y2=\"18\"/> <line x1=\"12\" x2=\"18\" y1=\"15\" y2=\"15\"/> <rect width=\"14\" height=\"14\" x=\"8\" y=\"8\" rx=\"2\" ry=\"2\"/> <path d=\"M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2\"/>",
  "forward": "<rect x=\"8\" y=\"8\" width=\"8\" height=\"8\" rx=\"2\"/> <path d=\"M4 10a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2\"/> <path d=\"M14 20a2 2 0 0 0 2 2h4a2 2 0 0 0 2-2v-4a2 2 0 0 0-2-2\"/>",
  "backward": "<rect x=\"14\" y=\"14\" width=\"8\" height=\"8\" rx=\"2\"/> <rect x=\"2\" y=\"2\" width=\"8\" height=\"8\" rx=\"2\"/> <path d=\"M7 14v1a2 2 0 0 0 2 2h1\"/> <path d=\"M14 7h1a2 2 0 0 1 2 2v1\"/>",
  "edit": "<path d=\"M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z\"/> <path d=\"m15 5 4 4\"/>",
  "fit": "<path d=\"M8 3H5a2 2 0 0 0-2 2v3\"/> <path d=\"M21 8V5a2 2 0 0 0-2-2h-3\"/> <path d=\"M3 16v3a2 2 0 0 0 2 2h3\"/> <path d=\"M16 21h3a2 2 0 0 0 2-2v-3\"/>",
  "sun": "<circle cx=\"12\" cy=\"12\" r=\"4\"/> <path d=\"M12 2v2\"/> <path d=\"M12 20v2\"/> <path d=\"m4.93 4.93 1.41 1.41\"/> <path d=\"m17.66 17.66 1.41 1.41\"/> <path d=\"M2 12h2\"/> <path d=\"M20 12h2\"/> <path d=\"m6.34 17.66-1.41 1.41\"/> <path d=\"m19.07 4.93-1.41 1.41\"/>",
  "moon": "<path d=\"M20.985 12.486a9 9 0 1 1-9.473-9.472c.405-.022.617.46.402.803a6 6 0 0 0 8.268 8.268c.344-.215.825-.004.803.401\"/>",
  "search": "<path d=\"m21 21-4.34-4.34\"/> <circle cx=\"11\" cy=\"11\" r=\"8\"/>",
  "library": "<path d=\"m16 6 4 14\"/> <path d=\"M12 6v14\"/> <path d=\"M8 8v12\"/> <path d=\"M4 4v16\"/>",
  "layers": "<path d=\"M12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83z\"/> <path d=\"M2 12a1 1 0 0 0 .58.91l8.6 3.91a2 2 0 0 0 1.65 0l8.58-3.9A1 1 0 0 0 22 12\"/> <path d=\"M2 17a1 1 0 0 0 .58.91l8.6 3.91a2 2 0 0 0 1.65 0l8.58-3.9A1 1 0 0 0 22 17\"/>",
  "workflows": "<rect width=\"8\" height=\"8\" x=\"3\" y=\"3\" rx=\"2\"/> <path d=\"M7 11v4a2 2 0 0 0 2 2h4\"/> <rect width=\"8\" height=\"8\" x=\"13\" y=\"13\" rx=\"2\"/>",
  "save": "<path d=\"M15.2 3a2 2 0 0 1 1.4.6l3.8 3.8a2 2 0 0 1 .6 1.4V19a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z\"/> <path d=\"M17 21v-7a1 1 0 0 0-1-1H8a1 1 0 0 0-1 1v7\"/> <path d=\"M7 3v4a1 1 0 0 0 1 1h7\"/>",
  "folder": "<path d=\"m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2\"/>",
  "plus": "<path d=\"M5 12h14\"/> <path d=\"M12 5v14\"/>",
  "scroll": "<path d=\"M15 12h-5\"/> <path d=\"M15 8h-5\"/> <path d=\"M19 17V5a2 2 0 0 0-2-2H4\"/> <path d=\"M8 21h12a2 2 0 0 0 2-2v-1a1 1 0 0 0-1-1H11a1 1 0 0 0-1 1v1a2 2 0 1 1-4 0V5a2 2 0 1 0-4 0v2a1 1 0 0 0 1 1h3\"/>",
  "ocr": "<path d=\"M3 7V5a2 2 0 0 1 2-2h2\"/> <path d=\"M17 3h2a2 2 0 0 1 2 2v2\"/> <path d=\"M21 17v2a2 2 0 0 1-2 2h-2\"/> <path d=\"M7 21H5a2 2 0 0 1-2-2v-2\"/> <path d=\"M7 8h8\"/> <path d=\"M7 12h10\"/> <path d=\"M7 16h6\"/>",
  "shield": "<path d=\"M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z\"/> <path d=\"M12 8v4\"/> <path d=\"M12 16h.01\"/>",
  "shieldCheck": "<path d=\"M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z\"/> <path d=\"m9 12 2 2 4-4\"/>",
  "settings": "<path d=\"M9.671 4.136a2.34 2.34 0 0 1 4.659 0 2.34 2.34 0 0 0 3.319 1.915 2.34 2.34 0 0 1 2.33 4.033 2.34 2.34 0 0 0 0 3.831 2.34 2.34 0 0 1-2.33 4.033 2.34 2.34 0 0 0-3.319 1.915 2.34 2.34 0 0 1-4.659 0 2.34 2.34 0 0 0-3.32-1.915 2.34 2.34 0 0 1-2.33-4.033 2.34 2.34 0 0 0 0-3.831A2.34 2.34 0 0 1 6.35 6.051a2.34 2.34 0 0 0 3.319-1.915\"/> <circle cx=\"12\" cy=\"12\" r=\"3\"/>",
  "activity": "<path d=\"M22 12h-2.48a2 2 0 0 0-1.93 1.46l-2.35 8.36a.25.25 0 0 1-.48 0L9.24 2.18a.25.25 0 0 0-.48 0l-2.35 8.36A2 2 0 0 1 4.49 12H2\"/>",
  "close": "<path d=\"M18 6 6 18\"/> <path d=\"m6 6 12 12\"/>",
  "timer": "<line x1=\"10\" x2=\"14\" y1=\"2\" y2=\"2\"/> <line x1=\"12\" x2=\"15\" y1=\"14\" y2=\"11\"/> <circle cx=\"12\" cy=\"14\" r=\"8\"/>",
  "keyboard": "<path d=\"M10 8h.01\"/> <path d=\"M12 12h.01\"/> <path d=\"M14 8h.01\"/> <path d=\"M16 12h.01\"/> <path d=\"M18 8h.01\"/> <path d=\"M6 8h.01\"/> <path d=\"M7 16h10\"/> <path d=\"M8 12h.01\"/> <rect width=\"20\" height=\"16\" x=\"2\" y=\"4\" rx=\"2\"/>",
  "imageDown": "<path d=\"M10.3 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v10l-3.1-3.1a2 2 0 0 0-2.814.014L6 21\"/> <path d=\"m14 19 3 3v-5.5\"/> <path d=\"m17 22 3-3\"/> <circle cx=\"9\" cy=\"9\" r=\"2\"/>",
  "file": "<path d=\"M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z\"/> <path d=\"M14 2v5a1 1 0 0 0 1 1h5\"/> <path d=\"M10 12a1 1 0 0 0-1 1v1a1 1 0 0 1-1 1 1 1 0 0 1 1 1v1a1 1 0 0 0 1 1\"/> <path d=\"M14 18a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1 1 1 0 0 1-1-1v-1a1 1 0 0 0-1-1\"/>",
  "blank": "<path d=\"M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z\"/> <path d=\"M14 2v5a1 1 0 0 0 1 1h5\"/>",
  "eraser": "<path d=\"M21 21H8a2 2 0 0 1-1.42-.587l-3.994-3.999a2 2 0 0 1 0-2.828l10-10a2 2 0 0 1 2.829 0l5.999 6a2 2 0 0 1 0 2.828L12.834 21\"/> <path d=\"m5.082 11.09 8.828 8.828\"/>",
  "power": "<path d=\"M12 2v10\"/> <path d=\"M18.4 6.6a9 9 0 1 1-12.77.04\"/>",
  "sparkles": "<path d=\"M11.017 2.814a1 1 0 0 1 1.966 0l1.051 5.558a2 2 0 0 0 1.594 1.594l5.558 1.051a1 1 0 0 1 0 1.966l-5.558 1.051a2 2 0 0 0-1.594 1.594l-1.051 5.558a1 1 0 0 1-1.966 0l-1.051-5.558a2 2 0 0 0-1.594-1.594l-5.558-1.051a1 1 0 0 1 0-1.966l5.558-1.051a2 2 0 0 0 1.594-1.594z\"/> <path d=\"M20 2v4\"/> <path d=\"M22 4h-4\"/> <circle cx=\"4\" cy=\"20\" r=\"2\"/>",
};
// Returns an inline SVG string for a named icon (empty string for unknown names).
function icon(name, size = 16, extra = '') {
  const body = PATHS[name];
  if (!body) return '';
  return `<svg class="icon ${extra}" xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">${body}</svg>`;
}
// Fills every element that has data-icon="name" (keeps any text already inside, after the icon).
function hydrate(root = document) {
  for (const el of root.querySelectorAll('[data-icon]')) {
    if (el.querySelector(':scope > svg.icon')) continue;
    el.insertAdjacentHTML('afterbegin', icon(el.dataset.icon, Number(el.dataset.iconSize) || 16));
  }
}
window.SnapShackleIcons = { icon, hydrate, names: Object.keys(PATHS) };
if (document.readyState !== 'loading') hydrate(); else document.addEventListener('DOMContentLoaded', () => hydrate());
})();
