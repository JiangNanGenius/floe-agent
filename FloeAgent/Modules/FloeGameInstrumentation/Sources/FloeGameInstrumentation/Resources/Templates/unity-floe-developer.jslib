/* SPDX-License-Identifier: MPL-2.0 */
/* Unity WebGL push bridge. Place in Assets/Plugins/WebGL/. */
mergeInto(LibraryManager.library, {
  FloeDeveloperAvailable: function () {
    return typeof window !== "undefined" && !!window.FloeDeveloper &&
      typeof window.FloeDeveloper.registerPushed === "function" &&
      typeof window.FloeDeveloper.takeCommands === "function" ? 1 : 0;
  },
  FloeDeveloperRegister: function (jsonPtr) {
    try {
      var text = UTF8ToString(jsonPtr);
      if (window.FloeDeveloper && window.FloeDeveloper.registerPushed) {
        window.FloeDeveloper.registerPushed(JSON.parse(text));
      }
    } catch (error) {}
  },
  FloeDeveloperPublish: function (jsonPtr) {
    try {
      var raw = JSON.parse(UTF8ToString(jsonPtr));
      if (window.FloeDeveloper && window.FloeDeveloper.updatePushed) {
        window.FloeDeveloper.updatePushed({
          "scene.name": raw.scene_name,
          "engine.paused": raw.paused,
          "engine.timescale": raw.time_scale,
          "engine.frames": raw.frames
        });
      }
    } catch (error) {}
  },
  FloeDeveloperTakeCommands: function () {
    try {
      var commands = window.FloeDeveloper ? window.FloeDeveloper.takeCommands() : [];
      var text = JSON.stringify({ items: commands });
      var size = lengthBytesUTF8(text) + 1;
      var pointer = _malloc(size);
      stringToUTF8(text, pointer, size);
      return pointer;
    } catch (error) {
      return 0;
    }
  },
  FloeDeveloperAck: function (id, ok) {
    try {
      if (window.FloeDeveloper) window.FloeDeveloper.ackCommand(id, { ok: ok === 1 });
    } catch (error) {}
  },
  FloeDeveloperFree: function (pointer) {
    if (pointer) _free(pointer);
  }
});
