// EVEngine workflow / rpg-classic — tilemap documents (kind `tileset`, `map`).
//
// Two documents, one editor:
//
//   content/tilesets/<id>.json   Tiled-flat atlas + per-GID navigation metadata
//   content/maps/<id>.json       isometric level, directly loadable by the engine
//
// A map references its atlas through the engine's own `tilesets[].source`, so
// rendering, per-GID visuals and walkability cost all come from the atlas file
// with no conversion step. `RpgcValidate` additionally checks that the map's
// tile size, spacing and pick geometry agree with the atlas — drift between the
// two files is an error, not a silent visual bug.
//
// Semantic rules here are the ones the engine does NOT enforce (see
// docs/01-tilemap-editor.md for the full list): GID range, layer data length,
// duplicate ids, spawn presence, atlas/layer agreement, iso pick consistency.

import { Rpgc } from "./rpgc_core.nut"
import { RpgcIso } from "./rpgc_iso.nut"
import { RpgcProject } from "./rpgc_project.nut"
import { RpgcStore } from "./rpgc_store.nut"

export class RpgcTilemap {
}

RpgcTilemap.version <- 1
RpgcTilemap.kinds <- ["tileset", "map"]

// ------------------------------------------------------------- semantic

RpgcTilemap.semanticDiagnostics <- function (document) {
    local schema = Rpgc.asString(Rpgc.get(document, "schema", ""));
    if (schema == "eve.rpgc.tileset") return this.tilesetDiagnostics(document);
    if (schema == "eve.rpgc.map") return this.mapDiagnostics(document);
    return [Rpgc.error("map.unknown-schema",
        "RpgcTilemap cannot validate schema '" + schema + "'", "$", "")];
}

// ---------------------------------------------------------------- atlas

// Every GID's visual, whether the document spells them out (version 1) or
// stores the rule (version 2).  A version-2 document keeps only the atlas
// grid and the ordered size runs, so `region` and `pivot` are recomputed
// here by replaying the same shelf packer the importer used.  Nothing
// per-tile is stored, and it is not held anywhere: the caller gets records
// for as long as it needs them.
RpgcTilemap.tilesOf <- function (doc) {
    local spelled = Rpgc.get(doc, "tiles", null);
    if (spelled != null) return spelled;          // version 1 is explicit

    local runs = Rpgc.get(doc, "runs", []);
    local layout = Rpgc.get(doc, "layout", {});
    local classes = Rpgc.get(doc, "classes", {});
    local names = Rpgc.get(doc, "names", []);
    local width = Rpgc.asInt(Rpgc.get(layout, "width", 0));
    local maxDim = Rpgc.asInt(Rpgc.get(layout, "maxDim", 8192));
    local first = Rpgc.asInt(Rpgc.get(layout, "firstTile", 0));
    local count = Rpgc.asInt(Rpgc.get(doc, "count", 0));
    local tw = Rpgc.asNumber(Rpgc.get(doc, "tileWidth", 0));
    local th = Rpgc.asNumber(Rpgc.get(doc, "tileHeight", 0));
    if (width < 1) return [];

    local out = [];
    local index = 0;
    local x = 0, y = 0, rowH = 0;
    foreach (run in runs) {
        local cell = Rpgc.get(run, "cell", []);
        local w = cell.len() > 0 ? Rpgc.asInt(cell[0]) : 0;
        local h = cell.len() > 1 ? Rpgc.asInt(cell[1]) : 0;
        local klass = Rpgc.asString(Rpgc.get(run, "class", ""));
        local klassRule = (klass in classes) ? classes[klass] : {};
        local pivotRule = Rpgc.asString(Rpgc.get(klassRule, "pivotRule", ""));
        // `pivot` is the region point the engine aligns with the cell
        // origin.  "cell-origin" is [0, 0]; "ground-anchor" moves the
        // sprite's bottom-centre half a cell, so the anchor lands on the
        // cell centre; the "_legacy" spelling is the SBS packs' shipped
        // convention, kept until its half-cell offset is resolved.
        local pivot = [0, 0];
        if (pivotRule == "ground-anchor") {
            pivot = [w / 2.0 - tw / 2.0, h - th / 2.0];
        } else if (pivotRule == "ground-anchor-legacy") {
            pivot = [w / 2.0, h.tofloat()];
        }
        for (local k = 0; k < Rpgc.asInt(Rpgc.get(run, "count", 0)); k += 1) {
            if (x + w > width && x > 0) { y += rowH; x = 0; rowH = 0; }
            if (y + ((rowH > h) ? rowH : h) > maxDim && (x > 0 || y > 0)) {
                x = 0; y = 0; rowH = 0;
            }
            if (index >= first && index < first + count) {
                local gid = index - first + 1;
                out.append({
                    gid = gid,
                    name = (gid - 1 < names.len())
                        ? Rpgc.asString(names[gid - 1]) : "",
                    region = [x, y, w, h],
                    pivot = pivot,
                    footprint = Rpgc.get(klassRule, "footprint", [1, 1]),
                    walkable = Rpgc.get(klassRule, "walkable", true),
                    cost = Rpgc.get(klassRule, "cost", 1.0),
                    sortBias = Rpgc.get(klassRule, "sortBias", 0.0),
                    klass = klass
                });
            }
            x += w;
            if (h > rowH) rowH = h;
            index += 1;
        }
    }
    return out;
}

// GID -> tile record, keyed for O(1) lookup by the editor and the validator.
RpgcTilemap.indexTiles <- function(tileset) {
    local byGid = {};
    foreach (tile in this.tilesOf(tileset)) {
        byGid.rawset(Rpgc.asInt(Rpgc.get(tile, "gid", 0)), tile);
    }
    return byGid;
}

RpgcTilemap.gidRange <- function (tileset) {
    local first = Rpgc.asInt(Rpgc.get(tileset, "firstGid", 1));
    local count = this.tilesOf(tileset).len();
    local range = {};
    range.first <- first;
    range.last <- first + count - 1;
    return range;
}

RpgcTilemap.tilesetDiagnostics <- function (doc) {
    local diagnostics = [];
    if (Rpgc.get(doc, "schema", "") != "eve.rpgc.tileset") {
        diagnostics.append(Rpgc.error("map.schema-mismatch",
            "expected schema eve.rpgc.tileset", "/schema", ""));
    }
    local tiles = this.tilesOf(doc);
    local seen = {};
    local expected = Rpgc.asInt(Rpgc.get(doc, "firstGid", 1));
    for (local i = 0; i < tiles.len(); i += 1) {
        local tile = tiles[i];
        local at = "/tiles/" + i;
        local gid = Rpgc.asInt(Rpgc.get(tile, "gid", 0));
        if (gid < 1) {
            diagnostics.append(Rpgc.error("map.bad-gid",
                "tile gid must be >= 1", at + "/gid", "GID 0 is reserved for empty"));
            continue;
        }
        if (seen.rawin(gid)) {
            diagnostics.append(Rpgc.error("map.duplicate-gid",
                "gid " + gid + " is declared twice", at + "/gid",
                "the runtime keeps only the first match"));
        }
        seen.rawset(gid, true);

        local region = Rpgc.get(tile, "region", []);
        if (region.len() != 4) {
            diagnostics.append(Rpgc.error("map.bad-region",
                "region must be [x, y, w, h]", at + "/region", ""));
        } else if (Rpgc.asNumber(region[2]) <= 0 || Rpgc.asNumber(region[3]) <= 0) {
            diagnostics.append(Rpgc.error("map.bad-region",
                "region width/height must be positive", at + "/region", ""));
        }

        local pivot = Rpgc.get(tile, "pivot", []);
        if (pivot.len() == 0) {
            diagnostics.append(Rpgc.warn("map.missing-pivot",
                "no pivot: the atlas cell origin is used, which is usually wrong"
                + " for a trimmed isometric tile", at + "/pivot",
                "run tools/tile-pipeline or set the pivot inside the trimmed region"));
        } else if (pivot.len() != 2) {
            diagnostics.append(Rpgc.error("map.bad-pivot",
                "pivot must be [x, y]", at + "/pivot", ""));
        }

        local footprint = Rpgc.get(tile, "footprint", []);
        if (footprint.len() != 0 && footprint.len() != 2) {
            diagnostics.append(Rpgc.error("map.bad-footprint",
                "footprint must be [w, h]", at + "/footprint", ""));
        }
    }

    // A version-2 document is a rule, so the rules themselves are what can
    // be wrong: a run may name a class nobody declared, or a cell the
    // packer cannot use.  The per-tile loop above then only re-checks what
    // the replay derived.
    if (Rpgc.asInt(Rpgc.get(doc, "version", 1)) >= 2) {
        local classes = Rpgc.get(doc, "classes", {});
        local runs = Rpgc.get(doc, "runs", []);
        local declared = Rpgc.asInt(Rpgc.get(doc, "count", 0));
        if (declared != tiles.len()) {
            diagnostics.append(Rpgc.error("map.count-mismatch",
                "count " + declared + " does not match the " + tiles.len()
                + " tiles the runs produce", "/count",
                "the count and the runs must describe the same atlas"));
        }
        if (Rpgc.get(doc, "names", []).len() != 0
            && Rpgc.get(doc, "names", []).len() != declared) {
            diagnostics.append(Rpgc.error("map.names-length",
                "names must have one entry per GID", "/names", ""));
        }
        for (local r = 0; r < runs.len(); r += 1) {
            local run = runs[r];
            local at = "/runs/" + r;
            local klass = Rpgc.asString(Rpgc.get(run, "class", ""));
            if (!(klass in classes)) {
                diagnostics.append(Rpgc.error("map.unknown-class",
                    "run class '" + klass + "' is not declared in classes",
                    at + "/class", "declare it in /classes"));
            }
            local cell = Rpgc.get(run, "cell", []);
            if (cell.len() != 2 || Rpgc.asInt(cell[0]) < 1
                || Rpgc.asInt(cell[1]) < 1) {
                diagnostics.append(Rpgc.error("map.bad-run-cell",
                    "cell must be [w, h] with positive sides", at + "/cell", ""));
            }
            if (Rpgc.asInt(Rpgc.get(run, "count", 0)) < 1) {
                diagnostics.append(Rpgc.error("map.bad-run-count",
                    "a run must cover at least one tile", at + "/count", ""));
            }
        }
        foreach (name, klassRule in classes) {
            local rule = Rpgc.asString(Rpgc.get(klassRule, "pivotRule", ""));
            if (rule != "cell-origin" && rule != "ground-anchor"
                && rule != "ground-anchor-legacy") {
                diagnostics.append(Rpgc.error("map.bad-pivot-rule",
                    "unknown pivotRule '" + rule + "'", "/classes/" + name
                    + "/pivotRule", "cell-origin, ground-anchor or"
                    + " ground-anchor-legacy"));
            }
        }
    }
    return diagnostics;
}

// ------------------------------------------------------------------ map

RpgcTilemap.mapDiagnostics <- function (doc) {
    local diagnostics = [];
    if (Rpgc.get(doc, "schema", "") != "eve.rpgc.map") {
        diagnostics.append(Rpgc.error("map.schema-mismatch",
            "expected schema eve.rpgc.map", "/schema", ""));
    }
    local width = Rpgc.asInt(Rpgc.get(doc, "width", 0));
    local height = Rpgc.asInt(Rpgc.get(doc, "height", 0));
    local cfg = RpgcIso.configFromDocument(doc);

    local pick = RpgcIso.pickIsConsistent(cfg);
    if (!pick.ok) {
        diagnostics.append(Rpgc.warn("map.pick-inconsistent", pick.reason,
            "/renderSpacing",
            "use renderSpacing [2, 2] with a 2:1 isometric atlas"));
    }

    local atlas = this.atlasFor(doc);
    if (atlas.found) {
        local atlasDoc = atlas.value;
        if (Rpgc.asInt(Rpgc.get(atlasDoc, "firstGid", 1)) !=
            Rpgc.asInt(Rpgc.get(Rpgc.get(doc, "tilesets", [])[0], "firstgid", 1))) {
            diagnostics.append(Rpgc.error("map.atlas-firstgid",
                "map firstgid does not match the atlas firstGid",
                "/tilesets/0/firstgid", "both must agree or GIDs shift silently"));
        }
        if (Rpgc.asNumber(Rpgc.get(atlasDoc, "tileWidth", 0)) != cfg.tileWidth ||
            Rpgc.asNumber(Rpgc.get(atlasDoc, "tileHeight", 0)) != cfg.tileHeight) {
            diagnostics.append(Rpgc.error("map.atlas-tile-size",
                "map tile size " + cfg.tileWidth + "x" + cfg.tileHeight
                + " does not match the atlas "
                + Rpgc.asNumber(Rpgc.get(atlasDoc, "tileWidth", 0)) + "x"
                + Rpgc.asNumber(Rpgc.get(atlasDoc, "tileHeight", 0)),
                "/tilewidth",
                "the engine uses the map size for the cell and the atlas for UVs"));
        }
    }

    local range = atlas.found ? this.gidRange(atlas.value) : 0;
    local layerIds = {};
    local layers = Rpgc.get(doc, "layers", []);
    local tileLayers = 0;
    local hasSpawn = false;

    for (local i = 0; i < layers.len(); i += 1) {
        local layer = layers[i];
        local at = "/layers/" + i;
        local id = Rpgc.asString(Rpgc.get(layer, "id", ""));
        if (!Rpgc.validId(id)) {
            diagnostics.append(Rpgc.error("map.bad-layer-id",
                "layer id must be a stable id", at + "/id", ""));
        } else if (layerIds.rawin(id)) {
            diagnostics.append(Rpgc.error("map.duplicate-layer",
                "layer id '" + id + "' is used twice", at + "/id", ""));
        } else {
            layerIds.rawset(id, true);
        }

        local kind = Rpgc.asString(Rpgc.get(layer, "type", "tilelayer"));
        if (kind == "objectgroup") {
            local objects = Rpgc.get(layer, "objects", []);
            local names = {};
            for (local j = 0; j < objects.len(); j += 1) {
                local object = objects[j];
                local oat = at + "/objects/" + j;
                local name = Rpgc.asString(Rpgc.get(object, "name", ""));
                if (!Rpgc.validId(name)) {
                    diagnostics.append(Rpgc.error("map.bad-object-name",
                        "object name must be a stable id", oat + "/name", ""));
                } else if (names.rawin(name)) {
                    diagnostics.append(Rpgc.error("map.duplicate-object",
                        "object name '" + name + "' is used twice", oat + "/name",
                        "world state and events address objects by name"));
                } else {
                    names.rawset(name, true);
                }
                if (Rpgc.get(object, "type", "") == "spawn") hasSpawn = true;
                local props = Rpgc.get(object, "properties", []);
                local propNames = {};
                for (local k = 0; k < props.len(); k += 1) {
                    local pname = Rpgc.asString(Rpgc.get(props[k], "name", ""));
                    if (propNames.rawin(pname)) {
                        diagnostics.append(Rpgc.error("map.duplicate-property",
                            "object property '" + pname + "' is declared twice",
                            oat + "/properties/" + k, ""));
                    }
                    propNames.rawset(pname, true);
                }
            }
            continue;
        }

        tileLayers += 1;
        local data = Rpgc.get(layer, "data", []);
        local expectedCount = width * height;
        if (data.len() != expectedCount) {
            diagnostics.append(Rpgc.error("map.layer-size",
                "layer '" + id + "' has " + data.len() + " cells, expected "
                + expectedCount + " (" + width + "x" + height + ")", at + "/data",
                "the engine rejects a mismatched data array at load time"));
            continue;
        }
        if (range == 0) continue;
        local badGids = {};
        local badCount = 0;
        foreach (gid in data) {
            local value = Rpgc.asInt(gid);
            if (value == 0) continue;  // empty cell
            if (value < range.first || value > range.last) {
                if (!badGids.rawin(value)) {
                    badGids.rawset(value, true);
                    badCount += 1;
                }
            }
        }
        if (badCount > 0) {
            local list = "";
            local shown = 0;
            foreach (gid, unused in badGids) {
                if (shown > 0) list += ", ";
                list += gid;
                shown += 1;
                if (shown >= 6) break;
            }
            diagnostics.append(Rpgc.error("map.gid-out-of-range",
                "layer '" + id + "' uses " + badCount + " GID(s) outside the atlas range "
                + range.first + ".." + range.last + " (" + list + ")", at + "/data",
                "the engine only verifies the cell count and would render a debug colour"));
        }
    }

    if (tileLayers == 0) {
        diagnostics.append(Rpgc.error("map.no-tile-layer",
            "a level needs at least one tilelayer", "/layers", ""));
    }
    if (!hasSpawn) {
        diagnostics.append(Rpgc.error("map.no-spawn",
            "no object of type 'spawn': the level has no player start",
            "/layers", "add an objectgroup object with type 'spawn'"));
    }
    diagnostics = this.layerDisciplineDiagnostics(layers, diagnostics);
    return diagnostics;
}

// The layer discipline the map schema cannot express (docs/06-game-design.md
// §1.4). The runtime cannot read a layer's NAME — `TileLayer` carries no name
// field, so a project only ever learns "which layer is the night overlay" by
// replaying `layers[]` and matching ids while validating. That makes these two
// rules load-bearing rather than cosmetic: a map whose base terrain is not the
// first tile layer silently pathfinds against the wrong layer.
RpgcTilemap.layerDisciplineDiagnostics <- function (layers, diagnostics) {
    local terrainAt = -1;
    local terrainLayer = -1;
    local momentLayerValues = {};

    for (local i = 0; i < layers.len(); i += 1) {
        local id = Rpgc.asString(Rpgc.get(layers[i], "id", ""));
        local at = "/layers/" + i;

        if (id == "terrain") {
            if (terrainAt >= 0) {
                diagnostics.append(Rpgc.error("map.duplicate-terrain-layer",
                    "'terrain' is declared twice", at + "/id", ""));
            } else {
                terrainAt = i;
                terrainLayer = Rpgc.asInt(Rpgc.get(layers[i], "layer", -1));
            }
        }

        if (id.len() <= 7 || id.slice(0, 7) != "moment.") continue;
        if (id.len() == 7) {
            diagnostics.append(Rpgc.error("map.empty-moment-layer",
                "a moment layer must be named 'moment.<momentId>'", at + "/id", ""));
            continue;
        }
        // Two moment layers sharing a `layer` value can never be told apart by
        // a consumer that reads the attribute rather than the array position.
        local value = Rpgc.asInt(Rpgc.get(layers[i], "layer", -1));
        if (value < 0) continue;
        if (momentLayerValues.rawin(value)) {
            diagnostics.append(Rpgc.error("map.duplicate-moment-layer-index",
                "moment layers '" + momentLayerValues.rawget(value) + "' and '" + id
                + "' both declare layer " + value, at + "/layer",
                "every moment layer needs its own layer index"));
        } else {
            momentLayerValues.rawset(value, id);
        }
    }

    if (terrainAt < 0) {
        diagnostics.append(Rpgc.error("map.no-terrain-layer",
            "a level needs a tile layer with id 'terrain': it is the base layer, the"
            + " pathfinder's source, and the only layer a moment overlay never replaces",
            "/layers", "rename the ground layer to 'terrain' and give it layer 0"));
    } else if (terrainLayer != 0) {
        diagnostics.append(Rpgc.error("map.terrain-layer-index",
            "the 'terrain' layer declares layer " + terrainLayer + ", not 0",
            "/layers/" + terrainAt + "/layer",
            "the runtime resolves the base layer positionally"));
    }
    return diagnostics;
}

// ------------------------------------------------------------- helpers

// Read the atlas a map points at. `found` is false when the document is not
// on disk, in which case the cross-file checks are skipped and the missing
// reference is reported by `RpgcValidate.validateReferences` instead.
RpgcTilemap.atlasFor <- function (doc) {
    local out = {};
    out.found <- false;
    out.value <- 0;
    out.path <- "";
    local entries = Rpgc.get(doc, "tilesets", []);
    if (entries.len() == 0) return out;
    local source = Rpgc.asString(Rpgc.get(entries[0], "source", ""));
    if (source == "") return out;
    local pointer = RpgcProject.directoryOf("map") + "/";
    local path = Rpgc.normalizePath(pointer + source);
    out.path <- path;
    if (!RpgcStore.exists(path)) return out;
    local read = RpgcStore.readDocument(path);
    if (!read.ok) return out;
    out.found <- true;
    out.value <- read.value;
    return out;
}

RpgcTilemap.atlasReference <- function (doc) {
    local entries = Rpgc.get(doc, "tilesets", []);
    if (entries.len() == 0) return "";
    local source = Rpgc.asString(Rpgc.get(entries[0], "source", ""));
    if (source == "") return "";
    return Rpgc.stem(source);
}

// World-pixel position of a cell, for placing objects and camera targets.
RpgcTilemap.worldOf <- function (doc, tx, ty) {
    local cfg = RpgcIso.configFromDocument(doc);
    local point = {};
    point.x <- RpgcIso.tileToWorldX(cfg, tx, ty);
    point.y <- RpgcIso.tileToWorldY(cfg, tx, ty);
    return point;
}

// Objectgroup layer index, or -1.
RpgcTilemap.objectLayerIndex <- function (doc) {
    local layers = Rpgc.get(doc, "layers", []);
    for (local i = 0; i < layers.len(); i += 1) {
        if (Rpgc.get(layers[i], "type", "") == "objectgroup") return i;
    }
    return -1;
}

// ---------------------------------------------------------- references

RpgcTilemap.references <- function (doc) {
    local out = [];
    local schema = Rpgc.asString(Rpgc.get(doc, "schema", ""));
    if (schema != "eve.rpgc.map") return out;
    local id = this.atlasReference(doc);
    if (id == "") {
        out.append({ kind = "", id = "", path = "/tilesets/0/source" });
    } else {
        out.append({ kind = "tileset", id = id, path = "/tilesets/0/source" });
    }
    return out;
}
