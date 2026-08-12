/* DemoSystem. The guided-tour state machine.
 *
 * One component (demo) on the home entity; its step follows the
 * active stage. Projects data-demo-step on the chapter stack and
 * data-live on the active stage's studio mock, so the mock's
 * choreography keys off world state instead of ad-hoc class
 * toggling. On pages without a demo the system matches nothing and
 * stays quiet.
 */

export const demoSystem = {
  name: 'demo',
  events: ['site:boot', 'stage:seen'],

  update(world, events) {
    const demo = world.get('home', 'demo');
    if (!demo) return;
    const seen = events.filter((e) => e.type === 'stage:seen').pop();
    if (seen) demo.step = seen.detail.index;
  },

  project(world) {
    const demo = world.get('home', 'demo');
    const stack = world.element('home');
    if (!demo || !stack) return;
    stack.setAttribute('data-demo-step', String(demo.step));
    for (const mock of stack.querySelectorAll('.studio-mock')) {
      const stageEl = mock.closest('.stage');
      const id = stageEl ? stageEl.getAttribute('data-ent') : null;
      const stage = id ? world.get(id, 'stage') : undefined;
      mock.setAttribute('data-live', stage && stage.active ? 'true' : 'false');
    }
  },
};
