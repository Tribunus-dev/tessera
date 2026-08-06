/* Tessera Observatory v1 -- transitions orchestrator.
 *
 * Drives the scrollytelling frame on the home page. The frame is a
 * fixed element that fills the viewport. The page's normal scroll
 * position drives a timeline variable; each section's translation
 * is a linear function of that timeline.
 *
 * Timeline model:
 *   timeline = scrollY / innerHeight  (units of "viewport heights scrolled")
 *   For section i (0-indexed), at timeline = i the section is centered
 *   in the frame. At timeline = i - 1 the section is just below the
 *   frame. At timeline = i + 1 the section is just above the frame.
 *   Translation: translateY = (i - timeline) * 100vh
 *
 * When all N sections have been walked (timeline >= N - 1), the user
 * continues to scroll through the sentinel. The fixed frame's last
 * section is at translateY = -100vh (fully out); the user is now in
 * the secondary-nav and footer territory.
 *
 * prefers-reduced-motion: reduce -- the scrolly-frame CSS collapses
 * the structure into normal document flow, so the JS exits early.
 *
 * The header height is measured at startup and on resize. The CSS
 * variable --header-height is set on the root element so the
 * .scrolly-section positioning matches the visible header.
 *
 * The driver is also a hook for future view transitions (hero morph
 * across navigation). For now it only handles the scrolly frame.
 */
(function () {
  'use strict';

  if (typeof window === 'undefined') return;

  var prefersReduce = window.matchMedia &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (prefersReduce) return;

  var frame = document.querySelector('.scrolly-frame');
  if (!frame) return;

  var sections = frame.querySelectorAll('.scrolly-section');
  if (sections.length < 2) return;

  var ticking = false;

  function measureHeader() {
    var header = document.querySelector('.site-header');
    if (!header) return;
    var h = header.offsetHeight || 64;
    document.documentElement.style.setProperty('--header-height', h + 'px');
  }

  function update() {
    ticking = false;
    var vh = window.innerHeight || 1;
    var timeline = window.scrollY / vh;
    var i;
    for (i = 0; i < sections.length; i++) {
      var translateY = (i - timeline) * 100;
      // Use translate3d to keep the layer composited; will-change is
      // applied to the section on first update so the browser
      // promotes it.
      sections[i].style.transform = 'translate3d(0,' + translateY + 'vh,0)';
      sections[i].style.willChange = 'transform';
    }
  }

  function onScroll() {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(update);
  }

  function init() {
    measureHeader();
    update();
    window.addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', function () {
      measureHeader();
      onScroll();
    }, { passive: true });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
