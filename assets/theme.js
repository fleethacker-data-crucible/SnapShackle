/* Applies the saved theme before the first paint so the studio never flashes the wrong colours.
   The host's settings file is the source of truth; studio.js re-applies it once settings load.
   'system' follows the Windows light/dark setting and updates live when it changes. */
(() => {
'use strict';
const media = window.matchMedia ? window.matchMedia('(prefers-color-scheme: light)') : null;
let choice = 'dark';
function resolve(value) { return value === 'system' ? (media && media.matches ? 'light' : 'dark') : (value === 'light' ? 'light' : 'dark'); }
function apply(value) {
  choice = ['dark', 'light', 'system'].includes(value) ? value : 'dark';
  const theme = resolve(choice);
  document.documentElement.dataset.theme = theme;
  document.documentElement.dataset.themeChoice = choice;
  const meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.content = theme === 'light' ? '#f6f7fb' : '#0b0e17';
  try { localStorage.setItem('lasso-theme', choice); } catch {}
  return theme;
}
let saved = 'dark';
try { saved = localStorage.getItem('lasso-theme') || 'dark'; } catch {}
apply(saved);
if (media && media.addEventListener) media.addEventListener('change', () => { if (choice === 'system') apply('system'); });
window.LassoTheme = { apply, get choice() { return choice; }, get theme() { return resolve(choice); } };
})();
