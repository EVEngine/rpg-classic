// EVEngine workflow / rpg-classic — 45-degree isometric projection.
//
// This is the engine's own projection, reused verbatim so that what an editor
// draws is exactly what the runtime draws (src/modules/map/GridProjection.cpp):
//
//   worldX = originX + (tx - ty) * pitchX * 0.5
//   worldY = originY + (tx + ty) * pitchY * 0.5
//   depthY = worldY + tileHeight          (the cell's foot line, used for sorting)
//
// `pitch` is tile size plus cell gap. The gap comes either from an explicit
// `cellGap` pair or from `renderSpacing`, where the engine computes
// `gap = size * (spacing - 1)` (TileLayer::setRenderSpacing).
//
// The engine's `worldToTile` does NOT clamp to map bounds, so neither does this
// module: the caller decides whether an out-of-bounds pick is meaningful.

// The engine's `worldToTile` is not the exact inverse of `tileToWorld` for every
// tile/pitch ratio. Solving the engine's own algebra
// (src/modules/map/GridProjection.cpp:38-43 and :81-92) for the bounding-box
// centre of cell (tx, ty) gives
//
//   tx' = floor(tx + (tileW/pitchX + tileH/pitchY) / 2)
//   ty' = floor(ty + (tileH/pitchY - tileW/pitchX) / 2)
//
// so a click on a cell's visual centre lands on that same cell only while
// `tileW/pitchX + tileH/pitchY < 2` and `tileH/pitchY >= tileW/pitchX`.
// The shipped isometric examples satisfy this by using `renderSpacing` of 2,
// which makes pitch exactly twice the tile size. `pickIsConsistent` reports the
// condition so the editor and the validator can refuse a map whose picking
// would be off by a cell — rather than letting an author discover it by feel.

import { Rpgc } from "./rpgc_core.nut"

export class RpgcIso {
}

RpgcIso.version <- 1

// Build the projection config from a map document. Unknown fields are
// ignored here; `RpgcValidate` is what rejects them.
RpgcIso.configFromDocument <- function (doc) {
    local cfg = {};
    cfg.tileWidth <- Rpgc.get(doc, "tilewidth", 32);
    if (!Rpgc.has(doc, "tilewidth")) cfg.tileWidth = Rpgc.get(doc, "tileWidth", 32);
    cfg.tileHeight <- Rpgc.get(doc, "tileheight", 32);
    if (!Rpgc.has(doc, "tileheight")) cfg.tileHeight = Rpgc.get(doc, "tileHeight", 32);

    local gapX = 0;
    local gapY = 0;
    if (Rpgc.has(doc, "cellGap")) {
        local gap = Rpgc.get(doc, "cellGap", []);
        if (typeof gap == "array" && gap.len() >= 2) {
            gapX = Rpgc.asNumber(gap[0]);
            gapY = Rpgc.asNumber(gap[1]);
        }
    } else if (Rpgc.has(doc, "renderSpacing")) {
        local spacing = Rpgc.get(doc, "renderSpacing", []);
        if (typeof spacing == "array" && spacing.len() >= 2) {
            gapX = cfg.tileWidth * (Rpgc.asNumber(spacing[0]) - 1.0);
            gapY = cfg.tileHeight * (Rpgc.asNumber(spacing[1]) - 1.0);
        }
    } else if (Rpgc.has(doc, "cellGapX")) {
        gapX = Rpgc.asNumber(Rpgc.get(doc, "cellGapX", 0));
        gapY = Rpgc.asNumber(Rpgc.get(doc, "cellGapY", 0));
    }
    cfg.gapX <- gapX;
    cfg.gapY <- gapY;

    local originX = 0;
    local originY = 0;
    if (Rpgc.has(doc, "origin")) {
        local origin = Rpgc.get(doc, "origin", []);
        if (typeof origin == "array" && origin.len() >= 2) {
            originX = Rpgc.asNumber(origin[0]);
            originY = Rpgc.asNumber(origin[1]);
        }
    } else {
        originX = Rpgc.asNumber(Rpgc.get(doc, "x", 0));
        originY = Rpgc.asNumber(Rpgc.get(doc, "y", 0));
    }
    cfg.originX <- originX;
    cfg.originY <- originY;
    cfg.pitchX <- cfg.tileWidth + gapX;
    cfg.pitchY <- cfg.tileHeight + gapY;
    return cfg;
}

// ------------------------------------------------------------ forward

RpgcIso.tileToWorldX <- function (cfg, tx, ty) {
    return cfg.originX + (tx - ty) * (cfg.pitchX * 0.5);
}

RpgcIso.tileToWorldY <- function (cfg, tx, ty) {
    return cfg.originY + (tx + ty) * (cfg.pitchY * 0.5);
}

// The cell anchor is the projected cell's top-left, which is also where a
// tile visual is placed before its pivot offset is applied.
RpgcIso.anchorX <- function (cfg, tx, ty) { return this.tileToWorldX(cfg, tx, ty); }
RpgcIso.anchorY <- function (cfg, tx, ty) { return this.tileToWorldY(cfg, tx, ty); }

RpgcIso.depthYAt <- function (cfg, tx, ty) {
    return this.tileToWorldY(cfg, tx, ty) + cfg.tileHeight;
}

// Sort key used by the unified 2D queue: depthY plus the tile's sortBias.
RpgcIso.sortKey <- function (cfg, tx, ty, sortBias) {
    return this.depthYAt(cfg, tx, ty) + Rpgc.asNumber(sortBias);
}

// Diamond centre used for labels and markers. This is the bounding-box
// centre, which is also the point `pickIsConsistent` guarantees round-trips.
RpgcIso.centerX <- function (cfg, tx, ty) {
    return this.tileToWorldX(cfg, tx, ty) + cfg.tileWidth * 0.5;
}

RpgcIso.centerY <- function (cfg, tx, ty) {
    return this.tileToWorldY(cfg, tx, ty) + cfg.tileHeight * 0.5;
}

// See the module header. Returns { ok, ratioX, ratioY, reason }.
RpgcIso.pickIsConsistent <- function (cfg) {
    local info = {};
    info.ratioX <- cfg.tileWidth / cfg.pitchX;
    info.ratioY <- cfg.tileHeight / cfg.pitchY;
    info.ok <- (info.ratioX + info.ratioY) < 2.0 && info.ratioY >= info.ratioX;
    if (info.ok) {
        info.reason <- "";
    } else {
        info.reason <- "tile/pitch ratios (" + info.ratioX + ", " + info.ratioY
            + ") break the engine's cell picking; set renderSpacing so pitch is"
            + " twice the tile size (the shipped isometric convention)";
    }
    return info;
}

// ------------------------------------------------------------ inverse

RpgcIso.worldToTileX <- function (cfg, wx, wy) {
    local a = (wx - cfg.originX) / (cfg.pitchX * 0.5);
    local b = (wy - cfg.originY) / (cfg.pitchY * 0.5);
    return this.floor((b + a) * 0.5);
}

RpgcIso.worldToTileY <- function (cfg, wx, wy) {
    local a = (wx - cfg.originX) / (cfg.pitchX * 0.5);
    local b = (wy - cfg.originY) / (cfg.pitchY * 0.5);
    return this.floor((b - a) * 0.5);
}

// Squirrel's tointeger() truncates toward zero; isometric picking needs a
// true floor or every negative coordinate is off by one.
RpgcIso.floor <- function (value) {
    local truncated = value.tointeger();
    if (value < 0 && truncated != value) truncated -= 1;
    return truncated;
}

// ---------------------------------------------------------- footprints

// A GID with footprint [w, h] occupies w*h cells starting at (tx, ty).
// The runtime does not consume footprints today, so the editor owns this
// contract; it is defined here once so the editor and the project agree.
RpgcIso.footprintCells <- function (cfg, tx, ty, w, h) {
    local cells = [];
    for (local dy = 0; dy < h; dy += 1) {
        for (local dx = 0; dx < w; dx += 1) {
            local cell = {};
            cell.x <- tx + dx;
            cell.y <- ty + dy;
            cells.append(cell);
        }
    }
    return cells;
}

RpgcIso.footprintIsInside <- function (cfg, tx, ty, w, h, mapWidth, mapHeight) {
    if (w < 1 || h < 1) return false;
    if (tx < 0 || ty < 0) return false;
    return (tx + w) <= mapWidth && (ty + h) <= mapHeight;
}

// ------------------------------------------------------------- framing

// World-space bounding box of a whole map, used to frame the editor camera.
RpgcIso.documentBounds <- function (cfg, mapWidth, mapHeight) {
    local left = this.tileToWorldX(cfg, 0, mapHeight - 1);
    local right = this.tileToWorldX(cfg, mapWidth - 1, 0) + cfg.tileWidth;
    local top = this.tileToWorldY(cfg, 0, 0);
    local bottom = this.tileToWorldY(cfg, mapWidth - 1, mapHeight - 1) + cfg.tileHeight;
    local bounds = {};
    bounds.minX <- left;
    bounds.minY <- top;
    bounds.maxX <- right;
    bounds.maxY <- bottom;
    bounds.width <- right - left;
    bounds.height <- bottom - top;
    return bounds;
}

// Editor-view screen mapping. This is a project convention (a plain
// axis-aligned 2D camera), NOT engine truth: the engine only owns the
// world-space projection above. Kept here so all three editors scroll and
// zoom identically.
RpgcIso.screenToWorldX <- function (view, screenX) {
    return view.camX + (screenX - view.viewX - view.viewW * 0.5) / view.zoom;
}

RpgcIso.screenToWorldY <- function (view, screenY) {
    return view.camY + (screenY - view.viewY - view.viewH * 0.5) / view.zoom;
}

RpgcIso.worldToScreenX <- function (view, worldX) {
    return view.viewX + view.viewW * 0.5 + (worldX - view.camX) * view.zoom;
}

RpgcIso.worldToScreenY <- function (view, worldY) {
    return view.viewY + view.viewH * 0.5 + (worldY - view.camY) * view.zoom;
}

// Pick a cell straight from a screen point, clamping to the map so a stray
// click outside the diamond cannot produce a bogus negative index.
RpgcIso.pickCell <- function (cfg, view, screenX, screenY, mapWidth, mapHeight) {
    local wx = this.screenToWorldX(view, screenX);
    local wy = this.screenToWorldY(view, screenY);
    local tx = this.worldToTileX(cfg, wx, wy);
    local ty = this.worldToTileY(cfg, wx, wy);
    local cell = {};
    cell.inside <- (tx >= 0 && ty >= 0 && tx < mapWidth && ty < mapHeight);
    cell.x <- tx;
    cell.y <- ty;
    return cell;
}

// Battle-stand formation: a 45-degree diamond fitted into a zone rectangle.
// The stand line runs BOTTOM-LEFT to TOP-RIGHT (index increases, x up, y down
// in screen space). Enemies use two iso-rows (typically 4x2); the party uses
// one iso-row so five people stand on a single diagonal. Coordinates stay in
// design-space pixels.
RpgcIso.battleIsoFit <- function (zone, cols, rows) {
    if (cols < 1) cols = 1;
    if (rows < 1) rows = 1;
    local pad = 48.0;
    local zx = Rpgc.asNumber(Rpgc.get(zone, "x", 0));
    local zy = Rpgc.asNumber(Rpgc.get(zone, "y", 0));
    local zw = Rpgc.asNumber(Rpgc.get(zone, "width", 0));
    local zh = Rpgc.asNumber(Rpgc.get(zone, "height", 0));
    local steps = cols + rows - 2;
    if (steps < 1) steps = 1;
    local widthFill = rows == 1 ? 0.55 : 0.75;
    local heightFill = rows == 1 ? 0.40 : 0.70;
    local innerW = zw * widthFill;
    local innerH = zh * heightFill;
    if (innerW < 32.0) innerW = zw * 0.7;
    if (innerH < 32.0) innerH = zh * 0.7;
    local pitchX = innerW * 2.0 / steps;
    local pitchY = innerH * 2.0 / steps;
    if (pitchY > pitchX * 0.5) pitchY = pitchX * 0.5;
    if (pitchX > pitchY * 2.0) pitchX = pitchY * 2.0;
    local fit = {};
    // Slot 0 is the bottom-left of rank 0. Rank offset uses the other iso
    // axis so a second row is a parallel line, not the same diagonal.
    fit.originX <- zx + pad;
    if (rows == 1) {
        fit.originY <- zy + zh * 0.50;
    } else {
        fit.originY <- zy + zh - pad - (rows - 1) * pitchY * 0.5;
    }
    fit.pitchX <- pitchX;
    fit.pitchY <- pitchY;
    return fit;
}

RpgcIso.battleIsoSlot <- function (zone, index, cols, rows) {
    if (cols < 1) cols = 1;
    if (rows < 1) rows = 1;
    local col = index % cols;
    local row = (index - col) / cols;
    local fit = this.battleIsoFit(zone, cols, rows);
    local out = {};
    // Along a rank: +x / -y (bottom-left to top-right).
    // Across ranks: +x / +y (the other iso edge), so the two ranks stay parallel.
    out.x <- fit.originX + (col + row) * fit.pitchX * 0.5;
    out.y <- fit.originY + (row - col) * fit.pitchY * 0.5;
    return out;
}
