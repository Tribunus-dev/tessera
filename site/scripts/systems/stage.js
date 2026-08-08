/* StageSystem. Observes which chapter is in front of the reader.
 *
 * IntersectionObserver only: discrete states, no scroll listener,
 * nothing in the scroll path. The scroll implementation stays pure
 * CSS (scrolly.css); this system only reads which stage settled and
 * projects data-active so the presentation can respond.
 */

export const stageSystem = {
  name: 'stage',
  events: ['site:boot', 'stage:seen'],

  init(world) {
    if (!('IntersectionObserver' in window)) return;
    const io = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        const id = entry.target.getAttribute('data-ent');
        const stage = world.get(id, 'stage');
        if (stage) world.emit('stage:seen', { index: stage.index });
      }
    }, { threshold: 0.5 });
    for (const id of world.query('stage')) {
      const el = world.element(id);
      if (el) io.observe(el);
    }
  },

  update(world, events) {
    const seen = events.filter((e) => e.type === 'stage:seen').pop();
    const active = seen ? seen.detail.index : 1;
    for (const id of world.query('stage')) {
      const stage = world.get(id, 'stage');
      stage.active = stage.index === active;
    }
  },

  project(world) {
    for (const id of world.query('stage')) {
      const el = world.element(id);
      const stage = world.get(id, 'stage');
      if (el && stage) {
        el.setAttribute('data-active', stage.active ? 'true' : 'false');
      }
    }
  },
};
