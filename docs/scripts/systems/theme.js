/* ThemeSystem. The world owns dark/light state; the DOM is its
 * projection. Replaces the old scripts/theme.js.
 *
 * Priority: stored localStorage > OS preference > default dark
 * (Observatory: dark is the default; light is opt-in).
 *
 * The pre-paint inline script in <head> resolves and applies
 * [data-theme] synchronously, so hydration reads the resolved value
 * back as the initial component state and this system never
 * repaints. Toggle clicks and OS changes flow through the event
 * queue like everything else.
 */

const STORAGE_KEY = 'tessera-theme';

function readStored() {
  try { return localStorage.getItem(STORAGE_KEY); } catch (e) { return null; }
}

export const themeSystem = {
  name: 'theme',
  events: ['site:boot', 'theme:toggle', 'theme:os'],

  init(world) {
    const theme = world.get('root', 'theme');
    if (theme) theme.stored = readStored() !== null;

    const btn = document.querySelector('[data-theme-toggle]');
    if (btn) {
      btn.addEventListener('click', () => world.emit('theme:toggle'));
    }
    try {
      window.matchMedia('(prefers-color-scheme: light)')
        .addEventListener('change', (e) => world.emit('theme:os', { light: e.matches }));
    } catch (e) {}
  },

  update(world, events) {
    const theme = world.get('root', 'theme');
    if (!theme) return;
    for (const ev of events) {
      if (ev.type === 'theme:toggle') {
        theme.mode = theme.mode === 'light' ? 'dark' : 'light';
        theme.stored = true;
      }
      if (ev.type === 'theme:os' && !theme.stored) {
        theme.mode = ev.detail.light ? 'light' : 'dark';
      }
    }
  },

  project(world) {
    const theme = world.get('root', 'theme');
    const root = world.element('root');
    if (!theme || !root) return;
    root.setAttribute('data-theme', theme.mode);
    try { root.style.colorScheme = theme.mode; } catch (e) {}
    if (theme.stored) {
      try { localStorage.setItem(STORAGE_KEY, theme.mode); } catch (e) {}
    }
    const btn = document.querySelector('[data-theme-toggle]');
    if (btn) {
      btn.setAttribute('aria-pressed', theme.mode === 'light' ? 'true' : 'false');
      const label = btn.querySelector('.theme-toggle-label');
      if (label) label.textContent = theme.mode === 'light' ? 'Light' : 'Dark';
    }
  },
};
