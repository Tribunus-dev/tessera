/* Tessera site -- hydration.
 *
 * The static HTML is the initial evidence. Every [data-ent] element
 * becomes an entity; the components it declares in data-has are
 * attached, each field read from the data-* attribute named in the
 * registry. After boot the JS world is canonical and the DOM is its
 * projection; before boot, and without JS, the static document is
 * the whole experience.
 */

function parseValue(raw) {
  if (raw === 'true') return true;
  if (raw === 'false') return false;
  if (/^-?\d+(\.\d+)?$/.test(raw)) return Number(raw);
  return raw;
}

export function hydrate(world, doc = document) {
  for (const el of doc.querySelectorAll('[data-ent]')) {
    const id = el.getAttribute('data-ent');
    world.entity(id, el);
    const declared = (el.getAttribute('data-has') || '').split(/\s+/);
    for (const name of declared) {
      if (!name) continue;
      const spec = world.registry.get(name);
      if (!spec) {
        console.warn(`hydrate: undeclared component "${name}" on ${id}`);
        continue;
      }
      const values = {};
      for (const [field, attr] of Object.entries(spec.attrs)) {
        if (el.hasAttribute(attr)) {
          values[field] = parseValue(el.getAttribute(attr));
        }
      }
      world.addComponent(id, name, values);
    }
  }
}
