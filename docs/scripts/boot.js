/* Tessera site -- ECS boot.
 *
 * The static HTML is complete without this file: every studio mock
 * shows its final state, every stage reads as a plain stacked
 * document. Hydration turns the markup into entities; after boot
 * the JS world is canonical and the DOM is its projection. All
 * presentation that depends on world state is gated behind
 * html[data-ecs="on"], so a script failure leaves the static
 * document, never a broken one.
 *
 * System order is registration order: theme and measure run
 * site-wide; stage and demo match only on the home page and stay
 * quiet everywhere else.
 */

import { World } from './ecs/world.js';
import { hydrate } from './ecs/hydrate.js';
import { themeSystem } from './systems/theme.js';
import { measureSystem } from './systems/measure.js';
import { stageSystem } from './systems/stage.js';
import { demoSystem } from './systems/demo.js';

const world = new World();

/* Component registry. attrs maps each field to the data-* attribute
 * hydration reads it from, so the markup and the world agree. */
world.registerComponent('theme', {
  defaults: { mode: 'dark', stored: false },
  attrs: { mode: 'data-theme' },
});
world.registerComponent('measure', {
  defaults: { height: 64 },
  attrs: {},
});
world.registerComponent('stage', {
  defaults: { index: 0, active: false },
  attrs: { index: 'data-stage-index' },
});
world.registerComponent('demo', {
  defaults: { step: 1 },
  attrs: { step: 'data-demo-step' },
});

world.system(themeSystem);
world.system(measureSystem);
world.system(stageSystem);
world.system(demoSystem);

/* A future selection system ("selection is a constitutional event")
 * registers here when the site grows interactive text selection.
 * Until then there is nothing to select. */

hydrate(world, document);
world.start();
document.documentElement.setAttribute('data-ecs', 'on');
