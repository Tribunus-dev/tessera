/* MeasureSystem. Publishes the site header's measured height as
 * --header-height. Replaces the old scripts/chapter-stack.js.
 *
 * The nav wraps at narrow widths, so no CSS constant covers the
 * header height; the home page's snap line, stage height, and
 * stage top offset all read this variable. The measurement runs on
 * boot and on resize - two discrete events, no polling.
 */

export const measureSystem = {
  name: 'measure',
  events: ['site:boot', 'viewport:resize'],

  init(world) {
    window.addEventListener('resize', () => world.emit('viewport:resize'));
  },

  update(world) {
    const m = world.get('site-header', 'measure');
    const el = world.element('site-header');
    if (!m || !el) return;
    m.height = el.offsetHeight;
  },

  project(world) {
    const m = world.get('site-header', 'measure');
    if (!m) return;
    document.documentElement.style.setProperty('--header-height', `${m.height}px`);
  },
};
