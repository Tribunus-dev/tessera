/* Tessera site -- ECS world.
 *
 * One canonical store. Entities are ids. Components are plain data,
 * stored per component name. Systems are the only mutators: a system
 * transacts component state in update(), and the same system writes
 * the DOM in project(), which runs only after the update phase of a
 * tick completes. State first, projection second, never interleaved.
 *
 * The scheduler is event-driven. emit() queues an event and wakes the
 * loop; the loop drains the queue on the next animation frame, runs
 * the subscribed systems, projects, and goes back to sleep. Nothing
 * polls. Nothing watches scroll.
 */

export class World {
  constructor() {
    this.registry = new Map();  // component name -> { defaults, attrs }
    this.store = new Map();     // component name -> Map(entity id -> data)
    this.elements = new Map();  // entity id -> Element
    this.systems = [];
    this.queue = [];
    this.frame = null;
  }

  /* Declare a component type. defaults seed every instance; attrs
   * maps each field to the data-* attribute hydration reads it
   * from. Re-registration is a bug, not an update. */
  registerComponent(name, { defaults = {}, attrs = {} } = {}) {
    if (this.registry.has(name)) {
      throw new Error(`component re-registered: ${name}`);
    }
    this.registry.set(name, { defaults, attrs });
    this.store.set(name, new Map());
  }

  /* Register an entity id and optionally bind its DOM element. */
  entity(id, element = null) {
    if (element !== null) this.elements.set(id, element);
    return id;
  }

  addComponent(id, name, values = {}) {
    const spec = this.registry.get(name);
    if (!spec) throw new Error(`unknown component: ${name}`);
    const data = Object.assign({}, spec.defaults, values);
    this.store.get(name).set(id, data);
    return data;
  }

  get(id, name) {
    const byName = this.store.get(name);
    return byName ? byName.get(id) : undefined;
  }

  /* All entity ids carrying a component. Stable insertion order. */
  query(name) {
    const byName = this.store.get(name);
    return byName ? Array.from(byName.keys()) : [];
  }

  element(id) {
    return this.elements.get(id);
  }

  system(sys) {
    this.systems.push(sys);
    return sys;
  }

  emit(type, detail = {}) {
    this.queue.push({ type, detail });
    this.wake();
  }

  wake() {
    if (this.frame === null) {
      this.frame = requestAnimationFrame(() => this.tick());
    }
  }

  /* One tick: drain the queue, run subscribed systems (update
   * phase), then project the systems that ran (projection phase). */
  tick() {
    this.frame = null;
    const events = this.queue;
    this.queue = [];
    if (events.length === 0) return;
    const touched = [];
    for (const sys of this.systems) {
      const mine = events.filter((e) => sys.events.includes(e.type));
      if (mine.length === 0) continue;
      sys.update(this, mine);
      touched.push(sys);
    }
    for (const sys of touched) {
      if (sys.project) sys.project(this);
    }
  }

  /* init runs once per system (listener wiring, observer setup),
   * then site:boot kicks the first tick. */
  start() {
    for (const sys of this.systems) {
      if (sys.init) sys.init(this);
    }
    this.emit('site:boot');
  }
}
