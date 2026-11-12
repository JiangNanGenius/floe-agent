// SPDX-License-Identifier: MPL-2.0
// Pure reads must be observationally read-only for the map presentation too.
// execute() normally re-renders after every command; for GIS that rebuilds the
// map, and disposeMap() can capture a stale on-screen center into liveView.
// Only explicit presentation commands (selection/bookmark/gis.ui.*) redraw.
export function installGISReadOnlyRenderPolicy(engine) {
  const execute = engine.execute.bind(engine), render = engine.render.bind(engine);
  engine.execute = async request => {
    const descriptor = engine.commands.get(request?.command)?.descriptor;
    engine.gisPureRead = Boolean(descriptor && descriptor.access === 'read' && descriptor.sideEffecting !== true);
    try { return await execute(request); } finally { engine.gisPureRead = false; }
  };
  engine.render = async function (...args) {
    if (this.gisPureRead) return;
    return render(...args);
  };
  return engine;
}
