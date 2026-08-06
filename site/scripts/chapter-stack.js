/* Tessera Observatory v1 -- chapter stack layout.
 *
 * Measures the site header and publishes its height as
 * --header-height so the sticky stages and the snap line clear the
 * wrapping header exactly. The nav wraps to multiple rows at
 * narrow widths, so the height is not a constant; this script is
 * the measurement. Runs on load and resize only.
 *
 * This is layout bookkeeping, not scroll control. It never listens
 * to scroll events and never moves anything. The scrollytelling
 * behavior is pure CSS (styles/components/scrolly.css); without
 * this file the page falls back to the CSS default header height
 * and still works.
 */
(function () {
  'use strict';

  if (typeof window === 'undefined') return;

  function measure() {
    var header = document.querySelector('.site-header');
    if (!header || !header.offsetHeight) return;
    document.documentElement.style.setProperty(
      '--header-height', header.offsetHeight + 'px');
  }

  function init() {
    if (!document.querySelector('.chapter-stack')) return;
    measure();
    window.addEventListener('resize', measure, { passive: true });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
