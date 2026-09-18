// EVEngine workflow / rpg-classic — tilemap editor ViewModel.
//
// Bound to editors/tilemap.editor.json. The first editor of the toolchain, and
// the reference for the other two: it owns no rules of its own, it reads and
// writes a map document through `RpgcTilemap` / `RpgcIso` and refuses to touch
// disk unless `RpgcValidate` accepts the result.
//
// Rendering: the host clears the screen and calls `eve_host_render()` before it
// draws the ImGui panels (src/modules/ui/EditorHost.cpp), so this drawer paints
// the isometric board as a background layer. The inspector is a right-hand
// panel only — there is no ImGui viewport canvas. The board and the visual
// tile picker occupy the main window, sized from the document width/height.

import { Rpgc } from "game:/lib/rpgc_core.nut"
import { RpgcIso } from "game:/lib/rpgc_iso.nut"
import { RpgcStore } from "game:/lib/rpgc_store.nut"
import { RpgcProject } from "game:/lib/rpgc_project.nut"
import { RpgcHost } from "game:/lib/rpgc_host.nut"
import { RpgcTilemap } from "game:/lib/rpgc_tilemap.nut"
import { RpgcValidate } from "game:/lib/rpgc_validate.nut"

// EditorHost registers a ViewModel by looking the name up in the VM root
// (`EditorHost::registerVM`), and this file is a module, so `::TilemapVM` would
// land in the module's private environment and never be found. Publish it on
// the root explicitly.
getroottable().TilemapVM <- {
    // ------------------------------------------------------------- state
    // The panel is bound to a project FOLDER, not to a document that has to be
    // opened: `kind` names the manifest entry whose directory is the list, and
    // `mapList` is that directory's contents as of the last scan. Picking a row
    // loads it (`onChange`), and `pollFolder` keeps the list honest while the
    // editor is up -- an AI writing into content/maps is the normal case here.
    kind = "map",
    folderLabel = "content/maps",
    folderPath = "content/maps",
    folderCount = 0,
    folderTimer = 0.0,
    folderPollSeconds = 1.0,

    mapList = [],
    mapIndex = 0,
    mapId = "",
    mapTitle = "",
    layerList = [],
    layerIndex = 0,
    layer = "",
    tilesetId = "",
    tileList = [],
    tileCaption = "未选图块",
    gidIndex = 0,
    gid = 1,
    tool = "paint",
    tools = ["paint", "erase", "fill", "rect"],
    objectList = [],
    objectIndex = 0,
    objectName = "spawn_1",
    objectType = "spawn",
    newWidth = 20,
    newHeight = 14,
    zoom = 0.35,
    cursorTileX = 0,
    cursorTileY = 0,
    cursor = "0, 0",
    grid = true,
    collision = false,
    status = "ready",
    diagnostics = "",
    dirty = false,
    tileCount = 0,
    originX = 1200.0,
    originY = 64.0,

    inspectorWidth = 380.0,
    pickerHeight = 168.0,
    pickerCols = 12,
    pickerRows = 2,
    pickerPage = 0,
    pickerPageLabel = "图块 0 / 0",
    mouseWasDown = false,

    // The live document plus its render model. `doc` is the single authority;
    // everything else is a projection rebuilt by `rebuild()`.
    doc = 0,
    atlas = 0,
    atlasPath = "",
    atlasTexture = 0,
    atlasTexturePath = "",
    tileRecords = [],
    tileByGid = {},
    pickerSprites = [],
    pickerQuads = [],
    mapSprites = [],
    mapQuads = [],

    // The MCP host never runs load.nut, so the root `mouse` slot that a game
    // relies on does not exist and an unqualified `mouse.getX()` raises "the
    // index 'mouse' does not exist". Module instances are reached through `eve`
    // instead (`eve.Mouse()`, verified to answer in the host). The cursor is
    // authoritative state rather than a value derived every frame from the
    // pointer: the pointer moves it when one exists, and `setCursor` /
    // `moveCursor` move it when one does not. `RpgcIso.pickCell` remains the
    // single pick implementation.
    pointer = 0,
    cursorTo = "0, 0",

    // ------------------------------------------------------------ lifecycle
    // Read `content/maps` and publish it as the panel's list. There is no
    // "open a document" step in this editor: the folder is the list, and the
    // selection is the document, so scanning and selecting is the whole of it.
    loadFolder = function () {
        local folder = RpgcProject.folder(this.kind);
        if (!folder.ok) {
            this.report(folder);
            return;
        }
        local info = folder.value;
        this.folderPath = Rpgc.asString(Rpgc.get(info, "directory", ""));
        this.folderCount = Rpgc.asInt(Rpgc.get(info, "count", 0));
        this.folderLabel = Rpgc.asString(Rpgc.get(info, "label", this.folderPath));
        this.mapList = Rpgc.get(info, "ids", []);
        if (this.mapList.len() == 0) {
            this.doc = 0;
            this.status = "项目文件夹 " + this.folderPath + " 里没有地图";
            return;
        }
        // Keep the cursor where the user left it across a rescan; a row that
        // has been deleted or renamed falls back to the first one.
        this.mapIndex = Rpgc.selectedIndexOf(this.mapList, this.mapId, this.mapIndex);
        if (this.mapIndex < 0) this.mapIndex = 0;
        this.mapId = this.mapList[this.mapIndex];
    },

    // Load whichever row the list has selected. Called by `onChange` (picking a
    // row IS opening it), by `refresh`, and at start-up -- never by a button of
    // its own, which is what "no open-document gesture" means in practice.
    loadSelected = function (editor, widget) {
        if (this.mapList.len() == 0) {
            this.status = "项目文件夹 " + this.folderPath + " 里没有地图";
            return;
        }
        local id = this.resolveMapId();
        local read = RpgcProject.loadById("map", id);
        if (!read.ok) {
            this.report(read);
            return;
        }
        this.doc = read.value;
        this.dirty = false;
        this.rebuild();
        this.frameAll(editor, widget);
        this.status = "载入 map/" + id;
        this.report(Rpgc.ok(true));
    },

    // Rescan the project folder and reload the selected document from disk.
    // The only way to throw away unsaved edits, so it is a deliberate gesture.
    refresh = function (editor, widget) {
        this.loadFolder();
        this.loadSelected(editor, widget);
    },

    // Keep the list equal to what is on disk, on a slow timer.
    //
    // Only the LIST is refreshed here. Re-reading the open document would
    // silently discard unsaved edits, so that happens when the user asks
    // (`refresh`) or when the selected row no longer exists at all -- in which
    // case there is nothing left to edit.
    pollFolder = function (dt) {
        this.folderTimer = Rpgc.numberOf(this.folderTimer) + Rpgc.numberOf(dt);
        if (this.folderTimer < this.folderPollSeconds) return;
        this.folderTimer = 0.0;
        local folder = RpgcProject.folder(this.kind);
        if (!folder.ok) return;
        local info = folder.value;
        this.folderPath = Rpgc.asString(Rpgc.get(info, "directory", this.folderPath));
        this.folderCount = Rpgc.asInt(Rpgc.get(info, "count", this.folderCount));
        this.folderLabel = Rpgc.asString(Rpgc.get(info, "label", this.folderLabel));
        local ids = Rpgc.get(info, "ids", []);
        if (RpgcProject.idsMatch(this.mapList, ids)) return;
        this.mapList = ids;
        if (ids.len() == 0) {
            this.doc = 0;
            this.status = "项目文件夹 " + this.folderPath + " 已没有地图";
            return;
        }
        this.mapIndex = Rpgc.selectedIndexOf(ids, this.mapId, this.mapIndex);
        if (this.mapIndex < 0) this.mapIndex = 0;
        if (ids[this.mapIndex] == this.mapId) {
            this.status = "项目文件夹已变化 (" + ids.len() + " 个地图)";
            return;
        }
        this.mapId = ids[this.mapIndex];
        this.loadSelected("tilemap", "");
        this.status = "所选地图已不在文件夹中，载入 map/" + this.mapId;
    },

    newMap = function (editor, widget) {
        local id = "untitled";
        local doc = {};
        doc.schema <- "eve.rpgc.map";
        doc.version <- 1;
        doc.id <- id;
        doc.title <- "未命名关卡";
        doc.width <- this.newWidth;
        doc.height <- this.newHeight;
        doc.tilewidth <- 128;
        doc.tileheight <- 64;
        doc.orientation <- "isometric";
        doc.renderSpacing <- [2, 2];
        doc.origin <- [this.originX, this.originY];
        doc.autoReload <- true;
        // Must name an atlas that actually ships in content/tilesets: the gate
        // checks the map's tile size and firstgid against it, so a template
        // pointing at a generated file would produce an unsaveable map.
        doc.tilesets <- [{ source = "../tilesets/sbs-overworld.json", firstgid = 1 }];
        local ground = [];
        for (local i = 0; i < this.newWidth * this.newHeight; i += 1) ground.append(3);
        local actors = [{ name = "spawn_1", type = "spawn",
                          x = this.originX, y = this.originY, width = 0, height = 0,
                          properties = [] }];
        // The base tile layer must be called `terrain` and sit at layer 0; the
        // runtime resolves it positionally and the gate enforces both.
        doc.layers <- [
            { id = "terrain", name = "terrain", type = "tilelayer", layer = 0,
              visible = true, data = ground },
            { id = "actors", name = "actors", type = "objectgroup", layer = 2,
              visible = true, objects = actors }
        ];
        this.doc = doc;
        this.dirty = true;
        this.rebuild();
        this.frameAll(editor, widget);
        this.status = "new map " + this.newWidth + "x" + this.newHeight + " (unsaved)";
        this.report(Rpgc.ok(true));
    },

    saveMap = function (editor, widget) {
        if (this.doc == 0) {
            this.status = "nothing to save";
            return;
        }
        local id = Rpgc.asString(Rpgc.get(this.doc, "id", ""));
        local path = RpgcProject.directoryOf("map") + "/" + id + ".json";
        local stale = RpgcStore.checkRevision(path);
        if (!stale.ok) {
            this.report(stale);
            return;
        }
        local result = RpgcValidate.commitDocument(path, this.doc);
        this.report(result);
        if (result.ok) {
            this.dirty = false;
            local info = result.value;
            this.status = "staged " + Rpgc.asString(Rpgc.get(info, "path", path))
                + " (" + Rpgc.asInt(Rpgc.get(info, "bytes", 0)) + " bytes) — run tools/rpgc.py export";
        }
    },

    // --------------------------------------------------------------- tools
    // `stampBrush` is declared `(editor, widget)` like every other command, so
    // the four brush entry points forward their arguments. Calling it as
    // `this.stampBrush()` passes only `this` and raises "wrong number of
    // parameters (1 passed, 3 required)" — the gesture never reached the map.
    paint = function (editor, widget) {
        this.tool = "paint";
        this.stampBrush(editor, widget);
    },

    erase = function (editor, widget) {
        this.tool = "erase";
        this.stampBrush(editor, widget);
    },

    fill = function (editor, widget) {
        this.tool = "fill";
        this.stampBrush(editor, widget);
    },

    rect = function (editor, widget) {
        this.tool = "rect";
        // A rectangle needs two corners; the editor keeps the cursor as the
        // second one and this fills the 3x3 around it, which is enough to show
        // the gesture without a second click state machine in v1.
        this.stampBrush(editor, widget);
    },

    stampBrush = function (editor, widget) {
        local layerIndex = this.tileLayerIndex();
        if (layerIndex < 0) {
            this.status = "no tile layer selected";
            return;
        }
        local gid = this.tool == "erase" ? 0 : this.gid;
        local width = Rpgc.asInt(Rpgc.get(this.doc, "width", 0));
        local height = Rpgc.asInt(Rpgc.get(this.doc, "height", 0));
        local data = Rpgc.get(this.doc, "layers." + layerIndex + ".data", []);
        local x = this.cursorTileX;
        local y = this.cursorTileY;

        if (this.tool == "fill") {
            for (local i = 0; i < data.len(); i += 1) data[i] = gid;
            this.status = "filled layer with GID " + gid;
        } else if (this.tool == "rect") {
            for (local dy = -1; dy <= 1; dy += 1) {
                for (local dx = -1; dx <= 1; dx += 1) {
                    local tx = x + dx;
                    local ty = y + dy;
                    if (tx < 0 || ty < 0 || tx >= width || ty >= height) continue;
                    data[ty * width + tx] = gid;
                }
            }
            this.status = "rect 3x3 at " + x + "," + y;
        } else {
            if (x < 0 || y < 0 || x >= width || y >= height) {
                this.status = "cursor outside the map";
                return;
            }
            data[y * width + x] = gid;
            this.status = this.tool + " GID " + gid + " at " + x + "," + y;
        }
        this.doc.layers[layerIndex].data <- data;
        this.dirty = true;
        this.rebuild();
    },

    // Pointer drag writes a single cell without rebuilding lists. `stampBrush`
    // still rebuilds because fill/rect change many cells and the status line.
    paintCellAtCursor = function () {
        local layerIndex = this.tileLayerIndex();
        if (layerIndex < 0) return;
        local width = Rpgc.asInt(Rpgc.get(this.doc, "width", 0));
        local height = Rpgc.asInt(Rpgc.get(this.doc, "height", 0));
        local x = this.cursorTileX;
        local y = this.cursorTileY;
        if (x < 0 || y < 0 || x >= width || y >= height) return;
        local data = Rpgc.get(this.doc, "layers." + layerIndex + ".data", []);
        local gid = this.tool == "erase" ? 0 : this.gid;
        local at = y * width + x;
        if (at >= data.len() || data[at] == gid) return;
        data[at] = gid;
        this.doc.layers[layerIndex].data <- data;
        this.dirty = true;
        this.status = this.tool + " GID " + gid + " at " + x + "," + y;
    },

    spawnObject = function (editor, widget) {
        local index = RpgcTilemap.objectLayerIndex(this.doc);
        if (index < 0) {
            this.status = "no objectgroup layer";
            return;
        }
        local name = this.objectName;
        if (!Rpgc.validId(name)) {
            this.status = "object name must be a stable id";
            return;
        }
        local objects = Rpgc.get(this.doc, "layers." + index + ".objects", []);
        foreach (object in objects) {
            if (Rpgc.get(object, "name", "") == name) {
                this.status = "object '" + name + "' already exists";
                return;
            }
        }
        local point = RpgcTilemap.worldOf(this.doc, this.cursorTileX, this.cursorTileY);
        objects.append({ name = name, type = this.objectType,
                         x = point.x, y = point.y, width = 0, height = 0,
                         properties = [] });
        this.doc.layers[index].objects <- objects;
        this.dirty = true;
        this.rebuild();
        this.status = "added " + this.objectType + " '" + name + "'";
    },

    removeObject = function (editor, widget) {
        local index = RpgcTilemap.objectLayerIndex(this.doc);
        if (index < 0 || this.objectList.len() == 0) return;
        local objects = Rpgc.get(this.doc, "layers." + index + ".objects", []);
        local name = this.objectList[this.objectIndex];
        local kept = [];
        foreach (object in objects) {
            if (Rpgc.get(object, "name", "") != name) kept.append(object);
        }
        this.doc.layers[index].objects <- kept;
        this.dirty = true;
        this.rebuild();
        this.status = "removed object '" + name + "'";
    },

    resizeMap = function (editor, widget) {
        local width = this.newWidth;
        local height = this.newHeight;
        local oldWidth = Rpgc.asInt(Rpgc.get(this.doc, "width", 0));
        local oldHeight = Rpgc.asInt(Rpgc.get(this.doc, "height", 0));
        local layers = Rpgc.get(this.doc, "layers", []);
        for (local i = 0; i < layers.len(); i += 1) {
            if (Rpgc.get(layers[i], "type", "tilelayer") == "objectgroup") continue;
            local data = Rpgc.get(layers[i], "data", []);
            local grown = [];
            for (local y = 0; y < height; y += 1) {
                for (local x = 0; x < width; x += 1) {
                    if (x < oldWidth && y < oldHeight) grown.append(data[y * oldWidth + x]);
                    else grown.append(0);
                }
            }
            this.doc.layers[i].data <- grown;
        }
        this.doc.width <- width;
        this.doc.height <- height;
        this.dirty = true;
        this.rebuild();
        this.frameAll(editor, widget);
        this.status = "resized to " + width + "x" + height;
    },

    frameAll = function (editor, widget) {
        if (this.doc == 0) return;
        local width = Rpgc.asInt(Rpgc.get(this.doc, "width", 1));
        local height = Rpgc.asInt(Rpgc.get(this.doc, "height", 1));
        local cfg = this.prepareBoardCfg();
        local bounds = RpgcIso.documentBounds(cfg, width, height);
        this.originX = bounds.minX;
        this.originY = bounds.minY;
        local board = this.boardRect();
        local zoom = 0.35;
        if (bounds.width > 1.0 && bounds.height > 1.0 && board.width > 1.0 && board.height > 1.0) {
            local zx = board.width / bounds.width;
            local zy = board.height / bounds.height;
            zoom = zx < zy ? zx : zy;
            zoom = zoom * 0.92;
            if (zoom > 1.5) zoom = 1.5;
            if (zoom < 0.05) zoom = 0.05;
        }
        this.zoom = zoom;
        this.status = "framed " + width + "x" + height
            + " (" + format("%.0f", bounds.width) + "x" + format("%.0f", bounds.height) + " px)";
    },

    toggleGrid = function (editor, widget) {
        this.grid = !this.grid;
    },

    toggleCollision = function (editor, widget) {
        this.collision = !this.collision;
    },

    pickerPrev = function (editor, widget) {
        local pages = this.pickerPageCount();
        if (pages <= 0) return;
        this.pickerPage = (this.pickerPage + pages - 1) % pages;
        this.refreshPickerLabel();
    },

    pickerNext = function (editor, widget) {
        local pages = this.pickerPageCount();
        if (pages <= 0) return;
        this.pickerPage = (this.pickerPage + 1) % pages;
        this.refreshPickerLabel();
    },

    // -------------------------------------------------------------- helpers

    // The host turns a `slider` into a one-element array and a
    // `dropdown`/`listbox` into the selected string (EditorHost.cpp:876-930),
    // so the numeric slots are unwrapped once per frame instead of at every use.
    normalize = function () {
        this.zoom = Rpgc.numberOf(this.zoom);
        this.gid = Rpgc.intOf(this.gid);
        this.newWidth = Rpgc.intOf(this.newWidth);
        this.newHeight = Rpgc.intOf(this.newHeight);
        this.objectIndex = Rpgc.intOf(this.objectIndex);
        this.gidIndex = Rpgc.intOf(this.gidIndex);
        this.layerIndex = Rpgc.intOf(this.layerIndex);
        this.pickerPage = Rpgc.intOf(this.pickerPage);
        this.inspectorWidth = Rpgc.numberOf(this.inspectorWidth);
        this.pickerHeight = Rpgc.numberOf(this.pickerHeight);
    },

    // `mapId` holds the dropdown's selected id; `mapIndex` may hold a listbox
    // label or an index depending on which widget the View used. Accept any of
    // the three so the editor works with either binding.
    resolveMapId = function () {
        local index = Rpgc.selectedIndexOf(this.mapList, this.mapId, this.mapIndex);
        if (index < 0) return "";
        this.mapIndex = index;
        return this.mapList[index];
    },

    tileLayerIndex = function () {
        local layers = Rpgc.get(this.doc, "layers", []);
        local wanted = this.layer;
        for (local i = 0; i < layers.len(); i += 1) {
            if (Rpgc.get(layers[i], "type", "tilelayer") == "objectgroup") continue;
            if (Rpgc.get(layers[i], "id", "") == wanted) return i;
        }
        for (local i = 0; i < layers.len(); i += 1) {
            if (Rpgc.get(layers[i], "type", "tilelayer") != "objectgroup") return i;
        }
        return -1;
    },

    rebuild = function () {
        if (this.doc == 0) return;
        local width = Rpgc.asInt(Rpgc.get(this.doc, "width", 0));
        local height = Rpgc.asInt(Rpgc.get(this.doc, "height", 0));
        this.mapId = Rpgc.asString(Rpgc.get(this.doc, "id", ""));
        this.mapTitle = Rpgc.asString(Rpgc.get(this.doc, "title", this.mapId));

        local layerNames = [];
        local usingLayers = Rpgc.get(this.doc, "layers", []);
        foreach (layer in usingLayers) {
            if (Rpgc.get(layer, "type", "tilelayer") == "objectgroup") continue;
            layerNames.append(Rpgc.asString(Rpgc.get(layer, "id", "")));
        }
        this.layerList = layerNames;
        if (this.layerList.len() > 0 && this.layer == "") this.layer = this.layerList[0];

        local objects = [];
        local index = RpgcTilemap.objectLayerIndex(this.doc);
        if (index >= 0) {
            foreach (object in Rpgc.get(this.doc, "layers." + index + ".objects", [])) {
                objects.append(Rpgc.asString(Rpgc.get(object, "name", "")));
            }
        }
        this.objectList = objects;

        local atlas = RpgcTilemap.atlasFor(this.doc);
        this.atlas = atlas.found ? atlas.value : 0;
        this.atlasPath = atlas.found ? Rpgc.asString(Rpgc.get(atlas, "path", "")) : "";
        this.tileRecords = [];
        this.tileByGid = {};
        if (atlas.found) {
            this.tilesetId = Rpgc.asString(Rpgc.get(atlas.value, "id", ""));
            local tiles = [];
            // Computed, not read: a version-2 atlas stores the packing rule and
            // the size runs, so `tilesOf` replays it into per-GID records.
            foreach (tile in RpgcTilemap.tilesOf(atlas.value)) {
                this.tileRecords.append(tile);
                local gid = Rpgc.asInt(Rpgc.get(tile, "gid", 0));
                this.tileByGid.rawset(gid, tile);
                local label = "" + gid;
                local name = Rpgc.asString(Rpgc.get(tile, "name", ""));
                if (name != "") label += " " + name;
                if (Rpgc.get(tile, "walkable", true) == false) label += " [blocked]";
                tiles.append(label);
            }
            this.tileList = tiles;
        }

        local layerIndex = this.tileLayerIndex();
        this.tileCount = layerIndex >= 0
            ? Rpgc.get(this.doc, "layers." + layerIndex + ".data", []).len() : 0;
        this.refreshCursorLabel();
        this.refreshTileCaption();
        this.refreshPickerLabel();
    },

    // Bounded cursor movement that needs no pointer, so the editor is fully
    // drivable from `eve_host_script` in a headless session.
    moveCursor = function (dx, dy) {
        this.setCursorTile(this.cursorTileX + dx, this.cursorTileY + dy);
    },

    moveLeft = function (editor, widget) { this.moveCursor(-1, 0); },
    moveRight = function (editor, widget) { this.moveCursor(1, 0); },
    moveUp = function (editor, widget) { this.moveCursor(0, -1); },
    moveDown = function (editor, widget) { this.moveCursor(0, 1); },

    // Accepts "x,y" so the value can come straight from an ImGui text field.
    // `Rpgc.intOf` goes through `tofloat()`, which tolerates the spaces a human
    // types after the comma; this Squirrel has no `strip()` to rely on.
    setCursor = function (editor, widget) {
        local parts = Rpgc.split(Rpgc.asString(this.cursorTo), ",");
        if (parts.len() != 2) {
            this.status = "cursor must be 'x,y'";
            return;
        }
        this.setCursorTile(Rpgc.intOf(parts[0]), Rpgc.intOf(parts[1]));
    },

    setCursorTile = function (x, y) {
        local width = Rpgc.asInt(Rpgc.get(this.doc, "width", 0));
        local height = Rpgc.asInt(Rpgc.get(this.doc, "height", 0));
        if (width > 0) {
            if (x < 0) x = 0;
            if (x > width - 1) x = width - 1;
        }
        if (height > 0) {
            if (y < 0) y = 0;
            if (y > height - 1) y = height - 1;
        }
        this.cursorTileX = x;
        this.cursorTileY = y;
        this.refreshCursorLabel();
    },

    refreshCursorLabel = function () {
        local width = Rpgc.asInt(Rpgc.get(this.doc, "width", 0));
        local height = Rpgc.asInt(Rpgc.get(this.doc, "height", 0));
        this.cursor = this.cursorTileX + ", " + this.cursorTileY
            + "  (map " + width + "x" + height + ", cells " + this.tileCount + ")";
    },

    refreshTileCaption = function () {
        local name = "";
        if (this.tileByGid.rawin(this.gid)) {
            name = Rpgc.asString(Rpgc.get(this.tileByGid.rawget(this.gid), "name", ""));
        }
        this.tileCaption = "GID " + this.gid + (name != "" ? "  " + name : "")
            + "  ·  " + this.tool;
    },

    pickerPageSize = function () {
        return this.pickerCols * this.pickerRows;
    },

    pickerPageCount = function () {
        local size = this.pickerPageSize();
        if (size < 1) return 0;
        local n = this.tileRecords.len();
        if (n <= 0) return 0;
        return (n + size - 1) / size;
    },

    refreshPickerLabel = function () {
        local pages = this.pickerPageCount();
        if (pages <= 0) {
            this.pickerPage = 0;
            this.pickerPageLabel = "图块 0 / 0";
            return;
        }
        if (this.pickerPage < 0) this.pickerPage = 0;
        if (this.pickerPage >= pages) this.pickerPage = pages - 1;
        local size = this.pickerPageSize();
        local first = this.pickerPage * size + 1;
        local last = first + size - 1;
        if (last > this.tileRecords.len()) last = this.tileRecords.len();
        this.pickerPageLabel = "图块 " + first + "–" + last
            + " / " + this.tileRecords.len()
            + "  ·  第 " + (this.pickerPage + 1) + "/" + pages + " 页";
    },

    selectGid = function (gid) {
        this.gid = gid;
        local size = this.pickerPageSize();
        for (local i = 0; i < this.tileRecords.len(); i += 1) {
            if (Rpgc.asInt(Rpgc.get(this.tileRecords[i], "gid", 0)) == gid) {
                this.gidIndex = i;
                if (size > 0) this.pickerPage = i / size;
                break;
            }
        }
        this.refreshTileCaption();
        this.refreshPickerLabel();
        this.status = "selected GID " + gid;
    },

    // Resolve the pointer once and keep it for the session. The try/catch is
    // what keeps the drawer alive on a host that has no input module at all:
    // without it the exception would escape into RpgcHost.updateAll once per
    // frame and the cursor would never move.
    resolvePointer = function () {
        if (this.pointer != 0) return this.pointer;
        try {
            this.pointer = eve.Mouse();
        } catch (e) {
            this.pointer = 0;
        }
        return this.pointer;
    },

    windowSize = function () {
        local out = {};
        out.width <- 1280.0;
        out.height <- 800.0;
        try {
            local gfx = eve.Graphics();
            out.width = gfx.getWidth() * 1.0;
            out.height = gfx.getHeight() * 1.0;
        } catch (e) {
        }
        if (out.width < 64.0) out.width = 64.0;
        if (out.height < 64.0) out.height = 64.0;
        return out;
    },

    // Main-window board: the whole drawable minus the inspector strip and the
    // tile picker along the bottom. This is the only place the map is drawn.
    boardRect = function () {
        local win = this.windowSize();
        local out = {};
        out.x <- 0.0;
        out.y <- 0.0;
        out.width <- win.width - this.inspectorWidth;
        out.height <- win.height - this.pickerHeight;
        if (out.width < 64.0) out.width = win.width * 0.65;
        if (out.height < 64.0) out.height = win.height * 0.70;
        return out;
    },

    pickerRect = function () {
        local win = this.windowSize();
        local board = this.boardRect();
        local out = {};
        out.x <- 0.0;
        out.y <- board.height;
        out.width <- board.width;
        out.height <- win.height - board.height;
        if (out.height < 48.0) out.height = this.pickerHeight;
        return out;
    },

    pointInRect = function (x, y, rect) {
        return x >= rect.x && y >= rect.y
            && x < rect.x + rect.width && y < rect.y + rect.height;
    },

    // Iso diamonds tessellate at pitch, not tile size. Maps ship
    // `renderSpacing [2, 2]`, so pitch is 2× tileWidth/Height; drawing the
    // packed 128×64 art into the 128×64 AABB leaves a one-cell gap.
    cellDrawSize = function (cfg, zoom) {
        local out = {};
        out.w <- cfg.pitchX * zoom;
        out.h <- cfg.pitchY * zoom;
        return out;
    },

    prepareBoardCfg = function () {
        local cfg = RpgcIso.configFromDocument(this.doc);
        cfg.originX = cfg.originX - this.originX;
        cfg.originY = cfg.originY - this.originY;
        return cfg;
    },

    makeView = function (rect, cfg, width, height) {
        local view = {};
        view.viewX <- rect.x;
        view.viewY <- rect.y;
        view.viewW <- rect.width;
        view.viewH <- rect.height;
        view.zoom <- this.zoom;
        local bounds = RpgcIso.documentBounds(cfg, width, height);
        view.camX <- (bounds.minX + bounds.maxX) * 0.5;
        view.camY <- (bounds.minY + bounds.maxY) * 0.5;
        return view;
    },

    // Recompute the pick from the current pointer position on the board.
    // With no pointer the cursor simply holds its value; that is the headless
    // case, and it is why the pick is not the only way to move the cursor.
    updateCursor = function () {
        if (this.doc == 0) return;
        local width = Rpgc.asInt(Rpgc.get(this.doc, "width", 1));
        local height = Rpgc.asInt(Rpgc.get(this.doc, "height", 1));
        if (this.pointer == 0) {
            this.refreshCursorLabel();
            return;
        }
        local mx = 0.0;
        local my = 0.0;
        try {
            mx = this.pointer.getX();
            my = this.pointer.getY();
        } catch (e) {
            this.pointer = 0;
            this.refreshCursorLabel();
            return;
        }
        if (!this.pointInRect(mx, my, this.boardRect())) {
            this.refreshCursorLabel();
            return;
        }
        local cfg = this.prepareBoardCfg();
        local view = this.makeView(this.boardRect(), cfg, width, height);
        local cell = RpgcIso.pickCell(cfg, view, mx, my, width, height);
        this.cursorTileX = cell.x;
        this.cursorTileY = cell.y;
        this.cursor = cell.x + ", " + cell.y + (cell.inside ? "" : " (outside)")
            + "  (map " + width + "x" + height + ", cells " + this.tileCount + ")";
    },

    handlePointer = function () {
        if (this.pointer == 0) {
            this.mouseWasDown = false;
            return;
        }
        local down = false;
        local mx = 0.0;
        local my = 0.0;
        try {
            down = this.pointer.isDown(1);
            mx = this.pointer.getX();
            my = this.pointer.getY();
        } catch (e) {
            this.pointer = 0;
            this.mouseWasDown = false;
            return;
        }
        local clicked = down && !this.mouseWasDown;
        this.mouseWasDown = down;
        if (this.pointInRect(mx, my, this.pickerRect())) {
            if (clicked) {
                local gid = this.hitPicker(mx, my);
                if (gid > 0) this.selectGid(gid);
            }
            return;
        }
        if (!this.pointInRect(mx, my, this.boardRect())) return;
        if (this.doc == 0) return;
        if ((this.tool == "paint" || this.tool == "erase") && down) {
            this.paintCellAtCursor();
        }
    },

    hitPicker = function (mx, my) {
        local layout = this.pickerLayout();
        if (layout.cellW <= 0.0) return 0;
        local col = ((mx - layout.x) / (layout.cellW + layout.gap)).tointeger();
        local row = ((my - layout.y) / (layout.cellH + layout.gap)).tointeger();
        if (col < 0 || row < 0 || col >= this.pickerCols || row >= this.pickerRows) return 0;
        local index = this.pickerPage * this.pickerPageSize() + row * this.pickerCols + col;
        if (index < 0 || index >= this.tileRecords.len()) return 0;
        return Rpgc.asInt(Rpgc.get(this.tileRecords[index], "gid", 0));
    },

    pickerLayout = function () {
        local rect = this.pickerRect();
        local pad = 10.0;
        local gap = 4.0;
        local innerW = rect.width - pad * 2.0;
        local innerH = rect.height - pad * 2.0 - 18.0;
        if (innerW < 8.0) innerW = 8.0;
        if (innerH < 8.0) innerH = 8.0;
        local cols = this.pickerCols;
        local rows = this.pickerRows;
        local cellW = (innerW - gap * (cols - 1)) / cols;
        local cellH = (innerH - gap * (rows - 1)) / rows;
        if (cellH > cellW * 0.55) cellH = cellW * 0.55;
        local out = {};
        out.x <- rect.x + pad;
        out.y <- rect.y + pad + 16.0;
        out.cellW <- cellW;
        out.cellH <- cellH;
        out.gap <- gap;
        return out;
    },

    report = function (result) {
        this.diagnostics = Rpgc.summary(result);
        if (!result.ok) {
            local first = Rpgc.firstError(result);
            if (first != null) this.status = "[" + first.path + "] " + first.message;
        }
    },

    // --------------------------------------------------------------- drawer
    update = function (dt) {
        this.normalize();
        this.pollFolder(dt);
        this.resolvePointer();
        this.updateCursor();
        this.handlePointer();
    },

    draw = function () {
        // The MCP host never runs load.nut, so `gfx` / `mouse` / `keyboard`
        // root slots do not exist here; the module instance is resolved from
        // `eve` instead.
        local gfx = eve.Graphics();
        local win = this.windowSize();
        gfx.drawSolidRect(0.0, 0.0, win.width, win.height, 0.07, 0.08, 0.11, 1.0);
        this.ensureAtlasTexture(gfx);
        this.drawBoard(gfx);
        this.drawPicker(gfx);
        this.presentSprites(gfx);
        this.drawBoardOverlay(gfx);
        this.drawPickerOverlay(gfx);
    },

    drawBoard = function (gfx) {
        local board = this.boardRect();
        gfx.drawSolidRect(board.x, board.y, board.width, board.height, 0.07, 0.08, 0.11, 1.0);
        if (this.doc == 0) return;

        local width = Rpgc.asInt(Rpgc.get(this.doc, "width", 1));
        local height = Rpgc.asInt(Rpgc.get(this.doc, "height", 1));
        local cfg = this.prepareBoardCfg();
        local view = this.makeView(board, cfg, width, height);
        local texReady = this.atlasTextureReady();
        local spriteCount = 0;

        local layer = this.tileLayerIndex();
        local data = [];
        if (layer >= 0) data = Rpgc.get(this.doc, "layers." + layer + ".data", []);

        for (local y = 0; y < height; y += 1) {
            for (local x = 0; x < width; x += 1) {
                local gid = 0;
                if (y * width + x < data.len()) gid = Rpgc.asInt(data[y * width + x]);
                local sx = RpgcIso.worldToScreenX(view, RpgcIso.tileToWorldX(cfg, x, y));
                local sy = RpgcIso.worldToScreenY(view, RpgcIso.tileToWorldY(cfg, x, y));
                local cell = this.cellDrawSize(cfg, view.zoom);
                local w = cell.w;
                local h = cell.h;
                if (sx + w < board.x || sx > board.x + board.width) continue;
                if (sy + h < board.y || sy > board.y + board.height) continue;

                local drewSprite = false;
                if (gid != 0 && texReady && this.tileByGid.rawin(gid)) {
                    drewSprite = this.placeTileSprite(this.mapSprites, this.mapQuads,
                        spriteCount, this.atlasTexture, this.tileByGid.rawget(gid),
                        sx, sy, w, h);
                    if (drewSprite) spriteCount += 1;
                }
                if (gid != 0 && !drewSprite) {
                    local c = this.colourOf(gid);
                    gfx.drawSolidRect(sx, sy, w, h, c[0], c[1], c[2], 0.95);
                } else if (gid == 0) {
                    gfx.drawSolidRect(sx, sy, w, h, 0.10, 0.12, 0.16, 0.55);
                }
            }
        }
        this.hideSpritesFrom(this.mapSprites, spriteCount);
    },

    drawBoardOverlay = function (gfx) {
        if (this.doc == 0) return;
        local board = this.boardRect();
        local width = Rpgc.asInt(Rpgc.get(this.doc, "width", 1));
        local height = Rpgc.asInt(Rpgc.get(this.doc, "height", 1));
        local cfg = this.prepareBoardCfg();
        local view = this.makeView(board, cfg, width, height);
        local blocked = {};
        if (this.collision) this.collectBlocked(blocked);

        if (this.grid || this.collision) {
            for (local y = 0; y < height; y += 1) {
                for (local x = 0; x < width; x += 1) {
                    local sx = RpgcIso.worldToScreenX(view, RpgcIso.tileToWorldX(cfg, x, y));
                    local sy = RpgcIso.worldToScreenY(view, RpgcIso.tileToWorldY(cfg, x, y));
                    local cell = this.cellDrawSize(cfg, view.zoom);
                    local w = cell.w;
                    local h = cell.h;
                    if (sx + w < board.x || sx > board.x + board.width) continue;
                    if (sy + h < board.y || sy > board.y + board.height) continue;
                    if (this.collision && blocked.rawin(x + ":" + y)) {
                        gfx.drawSolidRect(sx, sy + h * 0.25, w, h * 0.5, 0.95, 0.25, 0.25, 0.30);
                    }
                    if (this.grid) {
                        gfx.drawSolidRect(sx, sy, w, 1.0, 0.32, 0.40, 0.50, 0.90);
                        gfx.drawSolidRect(sx, sy + h - 1.0, w, 1.0, 0.32, 0.40, 0.50, 0.90);
                        gfx.drawSolidRect(sx, sy, 1.0, h, 0.24, 0.30, 0.38, 0.75);
                        gfx.drawSolidRect(sx + w - 1.0, sy, 1.0, h, 0.24, 0.30, 0.38, 0.75);
                    }
                }
            }
        }

        local cx = RpgcIso.worldToScreenX(view, RpgcIso.tileToWorldX(cfg, this.cursorTileX, this.cursorTileY));
        local cy = RpgcIso.worldToScreenY(view, RpgcIso.tileToWorldY(cfg, this.cursorTileX, this.cursorTileY));
        local cursor = this.cellDrawSize(cfg, view.zoom);
        gfx.drawSolidRect(cx, cy, cursor.w, cursor.h,
                          1.0, 0.85, 0.25, 0.28);

        local index = RpgcTilemap.objectLayerIndex(this.doc);
        if (index >= 0) {
            foreach (object in Rpgc.get(this.doc, "layers." + index + ".objects", [])) {
                local ox = Rpgc.asNumber(Rpgc.get(object, "x", 0)) - this.originX;
                local oy = Rpgc.asNumber(Rpgc.get(object, "y", 0)) - this.originY;
                local sx = RpgcIso.worldToScreenX(view, ox);
                local sy = RpgcIso.worldToScreenY(view, oy);
                local isSpawn = Rpgc.get(object, "type", "") == "spawn";
                gfx.drawSolidRect(sx - 4.0, sy - 4.0, 8.0, 8.0,
                                  isSpawn ? 0.30 : 0.95,
                                  isSpawn ? 0.95 : 0.72,
                                  isSpawn ? 0.45 : 0.22, 1.0);
            }
        }
    },

    drawPicker = function (gfx) {
        local rect = this.pickerRect();
        gfx.drawSolidRect(rect.x, rect.y, rect.width, rect.height, 0.09, 0.10, 0.13, 1.0);
        gfx.drawSolidRect(rect.x, rect.y, rect.width, 1.0, 0.30, 0.72, 0.52, 0.55);
        local layout = this.pickerLayout();
        local texReady = this.atlasTextureReady();
        local pageSize = this.pickerPageSize();
        local start = this.pickerPage * pageSize;
        local spriteCount = 0;
        for (local row = 0; row < this.pickerRows; row += 1) {
            for (local col = 0; col < this.pickerCols; col += 1) {
                local index = start + row * this.pickerCols + col;
                local px = layout.x + col * (layout.cellW + layout.gap);
                local py = layout.y + row * (layout.cellH + layout.gap);
                gfx.drawSolidRect(px, py, layout.cellW, layout.cellH, 0.12, 0.13, 0.17, 1.0);
                if (index >= this.tileRecords.len()) continue;
                local tile = this.tileRecords[index];
                local gid = Rpgc.asInt(Rpgc.get(tile, "gid", 0));
                local drew = false;
                if (texReady) {
                    drew = this.placeTileSprite(this.pickerSprites, this.pickerQuads,
                        spriteCount, this.atlasTexture, tile,
                        px + 1.0, py + 1.0, layout.cellW - 2.0, layout.cellH - 2.0);
                    if (drew) spriteCount += 1;
                }
                if (!drew) {
                    local c = this.colourOf(gid);
                    gfx.drawSolidRect(px + 2.0, py + 2.0, layout.cellW - 4.0, layout.cellH - 4.0,
                                      c[0], c[1], c[2], 1.0);
                }
            }
        }
        this.hideSpritesFrom(this.pickerSprites, spriteCount);
    },

    drawPickerOverlay = function (gfx) {
        local layout = this.pickerLayout();
        local pageSize = this.pickerPageSize();
        local start = this.pickerPage * pageSize;
        for (local row = 0; row < this.pickerRows; row += 1) {
            for (local col = 0; col < this.pickerCols; col += 1) {
                local index = start + row * this.pickerCols + col;
                if (index >= this.tileRecords.len()) continue;
                local gid = Rpgc.asInt(Rpgc.get(this.tileRecords[index], "gid", 0));
                if (gid != this.gid) continue;
                local px = layout.x + col * (layout.cellW + layout.gap);
                local py = layout.y + row * (layout.cellH + layout.gap);
                gfx.drawSolidRect(px, py, layout.cellW, 2.0, 1.0, 0.85, 0.25, 1.0);
                gfx.drawSolidRect(px, py + layout.cellH - 2.0, layout.cellW, 2.0, 1.0, 0.85, 0.25, 1.0);
                gfx.drawSolidRect(px, py, 2.0, layout.cellH, 1.0, 0.85, 0.25, 1.0);
                gfx.drawSolidRect(px + layout.cellW - 2.0, py, 2.0, layout.cellH, 1.0, 0.85, 0.25, 1.0);
            }
        }
    },

    presentSprites = function (gfx) {
        if (this.mapSprites.len() == 0 && this.pickerSprites.len() == 0) return;
        try {
            gfx.renderSprites();
        } catch (e) {
        }
    },

    atlasTextureReady = function () {
        if (this.atlasTexture == 0) return false;
        try {
            return this.atlasTexture.getWidth() > 0 && this.atlasTexture.getHeight() > 0;
        } catch (e) {
            return false;
        }
    },

    ensureAtlasTexture = function (gfx) {
        if (this.atlas == 0 || this.atlasPath == "") {
            this.atlasTexture = 0;
            this.atlasTexturePath = "";
            return;
        }
        local imageName = Rpgc.asString(Rpgc.get(this.atlas, "image", ""));
        if (imageName == "") return;
        local imagePath = Rpgc.resolveFrom(this.atlasPath, imageName);
        if (this.atlasTexture != 0 && this.atlasTexturePath == imagePath) return;
        this.atlasTexture = 0;
        this.atlasTexturePath = "";
        try {
            this.atlasTexture = gfx.newTextureFromFile(imagePath);
            this.atlasTexturePath = imagePath;
        } catch (e) {
            this.atlasTexture = 0;
        }
    },

    ensureSprite = function (sprites, quads, index) {
        while (sprites.len() <= index) {
            try {
                local gfx = eve.Graphics();
                local sprite = gfx.newSprite2D();
                sprite.setReceiveLight(false);
                sprite.setAnchor(0.0, 0.0);
                sprite.setVisible(false);
                sprites.append(sprite);
                quads.append(gfx.newQuad(0, 0, 1, 1));
            } catch (e) {
                return 0;
            }
        }
        return sprites[index];
    },

    placeTileSprite = function (sprites, quads, index, texture, tile, x, y, w, h) {
        local sprite = this.ensureSprite(sprites, quads, index);
        if (sprite == 0) return false;
        local region = Rpgc.get(tile, "region", []);
        if (region.len() != 4) return false;
        local rx = Rpgc.asInt(region[0]);
        local ry = Rpgc.asInt(region[1]);
        local rw = Rpgc.asInt(region[2]);
        local rh = Rpgc.asInt(region[3]);
        if (rw < 1 || rh < 1) return false;
        local quad = quads[index];
        quad.setViewport(rx, ry, rw, rh);
        sprite.setTexture(texture);
        sprite.setQuad(quad);
        sprite.setPosition(x, y);
        sprite.setSize(w, h);
        sprite.setVisible(true);
        return true;
    },

    hideSpritesFrom = function (sprites, from) {
        for (local i = from; i < sprites.len(); i += 1) {
            try { sprites[i].setVisible(false); } catch (e) {}
        }
    },

    collectBlocked = function (out) {
        if (this.atlas == 0) return;
        local width = Rpgc.asInt(Rpgc.get(this.doc, "width", 1));
        local layerIndex = this.tileLayerIndex();
        if (layerIndex < 0) return;
        local data = Rpgc.get(this.doc, "layers." + layerIndex + ".data", []);
        local walkable = {};
        foreach (tile in this.tileRecords) {
            walkable.rawset(Rpgc.asInt(Rpgc.get(tile, "gid", 0)),
                            Rpgc.get(tile, "walkable", true) != false);
        }
        for (local i = 0; i < data.len(); i += 1) {
            local gid = Rpgc.asInt(data[i]);
            local ok = walkable.rawin(gid) ? walkable.rawget(gid) : true;
            if (gid == 0 || !ok) {
                out.rawset((i % width) + ":" + (i / width), true);
            }
        }
    },

    // Deterministic per-GID colour so the board still reads when the atlas
    // image is missing (headless host, or PNG not yet uploaded).
    colours = [
        [0.24, 0.42, 0.22], [0.36, 0.34, 0.24], [0.42, 0.42, 0.46],
        [0.20, 0.34, 0.52], [0.18, 0.38, 0.20], [0.30, 0.30, 0.34],
        [0.55, 0.42, 0.16], [0.42, 0.24, 0.44]
    ],

    colourOf = function (gid) {
        local index = (gid - 1) % this.colours.len();
        if (index < 0) index = 0;
        return this.colours[index];
    },

    status_line = function () {
        return this.mapId + " | layer " + this.layer + " | " + this.tool
            + " gid " + this.gid + " | cursor " + this.cursor
            + (this.dirty ? " | DIRTY" : "");
    },

    onChange = function (widget, value) {
        if (widget == "layer") this.layer = Rpgc.asString(value);
        if (widget == "tool") this.tool = Rpgc.asString(value);
        if (widget == "gid") {
            local text = Rpgc.asString(value);
            if (text != "") {
                this.gid = Rpgc.intOf(text);
            } else {
                this.gid = Rpgc.intOf(value);
            }
            this.refreshTileCaption();
        }
        if (widget == "map") {
            // A dropdown delivers the id; a listbox delivers the label. Both are
            // resolved to an index in `resolveMapId`. Selecting a row loads it
            // immediately -- the panel never waits for a separate open step.
            this.mapId = Rpgc.asString(value);
            this.normalize();
            this.rebuild();
            this.loadSelected("tilemap", "");
            return;
        }
        if (widget == "object") this.objectIndex = Rpgc.intOf(value);
        this.normalize();
        this.rebuild();
    }
};

// The drawer the host pumps every frame.
RpgcHost.register("tilemap", {
    update = function (dt) { TilemapVM.update(dt); },
    draw = function () { TilemapVM.draw(); },
    status = function () { return TilemapVM.status_line(); }
});

// Start-up: scan the project folder and show its first map. No argument, no
// document chooser -- the editor opens onto the game folder's data.
try {
    TilemapVM.loadFolder();
    TilemapVM.loadSelected("tilemap", "");
} catch (e) {
    TilemapVM.status = "" + e;
    if ("log" in eve) eve.log("error", "tilemap: initial folder load: " + e);
}
