/* Tessera Observatory v1 -- transitions orchestrator.
 *
 * Drives the scrollytelling frame on the home page. The frame is a
 * fixed element that fills the viewport. The page's normal scroll
 * position drives a timeline variable; each section's translation
 * is a function of that timeline.
 *
 * Timeline model:
 *   timeline = scrollY / innerHeight  (units of "viewport heights scrolled")
 *   For section i (0-indexed), at timeline = i the section is centered
 *   in the frame. At timeline = i - 1 the section is just below the
 *   frame. At timeline = i + 1 the section is just above the frame.
 *   Translation: translateY = (i - timeline) * 100vh
 *
 * Snap model:
 *   On scroll-end (no scroll for 180ms), if the page is between
 *   section centers, animate window.scrollTo to the nearest 100vh
 *   snap point. The user settles on a section "at rest" rather than
 *   in a transition. The body scroll-snap-style experience, with
 *   no browser scrollbar visible.
 *
 * Reduced motion: the scrolly frame collapses to normal flow in CSS;
 * the JS exits early.
 *
 * The header height is measured at startup and on resize; the CSS
 * variable --header-height on the root keeps the section top offset
 * matched to the visible header.
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

  var N = sections.length;
  var ticking = false;
  var snapTimeout = null;
  var SNAP_DELAY = 180;

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
    for (i = 0; i < N; i++) {
      var translateY = (i - timeline) * 100;
      sections[i].style.transform = 'translate3d(0,' + translateY + 'vh,0)';
    }
  }

  function scheduleSnap() {
    if (snapTimeout) clearTimeout(snapTimeout);
    snapTimeout = setTimeout(doSnap, SNAP_DELAY);
  }

  function doSnap() {
    var vh = window.innerHeight || 1;
    var scrollY = window.scrollY;
    var scrollyEnd = (N - 1) * vh;
    // Only snap within the scrolly range. Past the end, the user is
    // in the secondary-nav and footer area; the snap does not fire.
    if (scrollY < -10 || scrollY > scrollyEnd + 10) return;
    var nearest = Math.round(scrollY / vh) * vh;
    if (Math.abs(scrollY - nearest) > 5) {
      window.scrollTo({ top: nearest, behavior: 'smooth' });
    }
  }

  function onScroll() {
    if (!ticking) {
      ticking = true;
      requestAnimationFrame(update);
    }
    scheduleSnap();
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
