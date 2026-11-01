"""Orthogonal, normalized blob, and closed two-terrain map brushes.

Masks use N=1, E=2, S=4, W=8 in tile coordinates (north is y-1).
Only membership in terrainGids establishes connectivity. v1/blob8 leave empty
and unrelated neighbors unchanged. transition8 requires a closed two-material
read neighborhood and erases back to its lower-priority material. The engine remains authoritative
for whether the resulting GIDs exist in the map's tileset.
"""
from copy import deepcopy
import hashlib

from .authoring import _cell, _integer, _layer, _map


FORMAT = 'rpgc.terrain-rules'
DIRECTIONS = ((0, -1, 1), (1, 0, 2), (0, 1, 4), (-1, 0, 8))


def _validate_v1(rules):
    """Return an independent normalized rules object (all masks are GID lists).

    terrainGids may include older terrain variants which the brush recognizes
    and replaces. Every output variant must also be a member of terrainGids.
    """
    if not isinstance(rules, dict) or set(rules) != {'format', 'version', 'terrainGids', 'masks'}:
        raise ValueError('terrain rules require exactly format, version, terrainGids, masks')
    if rules['format'] != FORMAT or type(rules['version']) is not int or rules['version'] != 1:
        raise ValueError('expected rpgc.terrain-rules version 1')
    gids = rules['terrainGids']
    if not isinstance(gids, list) or not gids:
        raise ValueError('terrainGids must be a nonempty array of positive integers')
    for gid in gids:
        _integer(gid, 'terrain GID', 1)
    if len(set(gids)) != len(gids):
        raise ValueError('terrainGids contains duplicate GIDs')
    masks = rules['masks']
    if not isinstance(masks, dict) or set(masks) != {str(i) for i in range(16)}:
        raise ValueError('masks must define all canonical keys "0" through "15"')
    normalized = {}
    for mask in range(16):
        value = masks[str(mask)]
        variants = value if isinstance(value, list) else [value]
        if not variants:
            raise ValueError(f'mask {mask} requires at least one GID')
        for gid in variants:
            _integer(gid, f'mask {mask} GID', 1)
            if gid not in gids:
                raise ValueError(f'mask {mask} GID {gid} is absent from terrainGids')
        if len(set(variants)) != len(variants):
            raise ValueError(f'mask {mask} has duplicate variant GIDs')
        normalized[str(mask)] = list(variants)
    return {'format': FORMAT, 'version': 1, 'terrainGids': list(gids), 'masks': normalized}


def _variant(variants, seed, x, y, mask):
    # Coordinate hashing means repainting or reversing the input cell order does
    # not reroll unrelated cells. Unlike hash(), this is stable across processes.
    key = f'rpgc.terrain.v1:{seed}:{x}:{y}:{mask}'.encode('ascii')
    index = int.from_bytes(hashlib.sha256(key).digest()[:8], 'big') % len(variants)
    return variants[index]


def _autotile_v1(document, layer_id, cells, rules, erase=False, seed=0):
    """Paint/erase cells, then reconnect their four-neighbor terrain frontier.

    Painting accepts only empty cells (GID 0) or this terrain. Erasing accepts
    only this terrain or empty cells. A foreign tile causes the whole operation
    to fail, even if other selected cells are safe. Inputs are never mutated.
    Missing cells beyond map edges are disconnected. Variant selection is stable
    for the same seed/coordinate/mask. Output is a candidate for RpgcValidate.
    """
    width, height = _map(document)
    normalized = validate_rules(rules)
    if type(erase) is not bool:
        raise ValueError('erase must be a boolean')
    _integer(seed, 'seed')
    if not isinstance(cells, (list, tuple)):
        raise ValueError('cells must be an array of [x, y] pairs')
    source = _layer(document, layer_id)['data']
    terrain = set(normalized['terrainGids'])
    selected = set()
    for cell in cells:
        if not isinstance(cell, (list, tuple)) or len(cell) != 2:
            raise ValueError('each cell must be [x, y]')
        x, y = cell
        index = _cell(x, y, width, height)
        gid = source[index]
        if type(gid) is not int or gid < 0:
            raise ValueError(f'cell ({x}, {y}) has an invalid GID')
        if gid != 0 and gid not in terrain:
            raise ValueError(f'cell ({x}, {y}) contains foreign GID {gid}; refusing to overwrite')
        selected.add((x, y))
    result = deepcopy(document)
    data = _layer(result, layer_id)['data']
    frontier = set(selected)
    for x, y in selected:
        data[y * width + x] = 0 if erase else normalized['terrainGids'][0]
        for dx, dy, _ in DIRECTIONS:
            nx, ny = x + dx, y + dy
            if 0 <= nx < width and 0 <= ny < height:
                frontier.add((nx, ny))
    # Compute all masks from the post-paint topology. Replacement GIDs always
    # remain terrain members, so output variant selection cannot alter topology.
    for x, y in sorted(frontier):
        index = y * width + x
        if type(data[index]) is not int or data[index] not in terrain:
            continue
        mask = 0
        for dx, dy, bit in DIRECTIONS:
            nx, ny = x + dx, y + dy
            if 0 <= nx < width and 0 <= ny < height:
                neighbor = data[ny * width + nx]
                if type(neighbor) is int and neighbor in terrain:
                    mask |= bit
        data[index] = _variant(normalized['masks'][str(mask)], seed, x, y, mask)
    return result


# Bit order deliberately retains the v1 orthogonal bits. This is a 47-mask
# blob protocol, not RPG Maker's 48-subtile asset format.
DIAGONALS = ((1, -1, 16, 1 | 2), (1, 1, 32, 2 | 4),
             (-1, 1, 64, 4 | 8), (-1, -1, 128, 8 | 1))
EIGHT_DIRECTIONS = DIRECTIONS + tuple((x, y, bit) for x, y, bit, _ in DIAGONALS)


def normalize_blob_mask(mask):
    """Discard diagonal connections without both adjacent orthogonal edges."""
    _integer(mask, 'blob mask')
    if mask > 255:
        raise ValueError('blob mask must be in [0, 255]')
    for _, _, bit, edges in DIAGONALS:
        if mask & edges != edges:
            mask &= ~bit
    return mask


BLOB_MASKS = tuple(sorted({normalize_blob_mask(mask) for mask in range(256)}))


def _blob_table(value):
    if not isinstance(value, dict) or set(value) != {'terrainGids', 'masks'}:
        raise ValueError('terrain requires exactly terrainGids and masks')
    gids = value['terrainGids']
    if not isinstance(gids, list) or not gids:
        raise ValueError('terrainGids must be a nonempty array')
    for gid in gids:
        _integer(gid, 'terrain GID', 1)
    if len(set(gids)) != len(gids):
        raise ValueError('terrainGids contains duplicate GIDs')
    masks = value['masks']
    if not isinstance(masks, dict) or set(masks) != {str(i) for i in BLOB_MASKS}:
        raise ValueError('masks must define exactly all 47 canonical normalized blob masks')
    normalized = {}
    for mask in BLOB_MASKS:
        variants = masks[str(mask)]
        variants = variants if isinstance(variants, list) else [variants]
        if not variants:
            raise ValueError(f'mask {mask} requires at least one GID')
        for gid in variants:
            _integer(gid, f'mask {mask} GID', 1)
            if gid not in gids:
                raise ValueError(f'mask {mask} GID is absent from terrainGids')
        if len(set(variants)) != len(variants):
            raise ValueError(f'mask {mask} has duplicate variant GIDs')
        normalized[str(mask)] = list(variants)
    return {'terrainGids': list(gids), 'masks': normalized}


def validate_rules(rules):
    """Validate v1 orthogonal or v2 blob/two-terrain sidecar rules.

    v2 blob8 uses {format,version,mode,terrainGids,masks}. transition8 uses
    {format,version,mode,terrains,priority}, with exactly two named terrain
    tables. Priority is highest first: painting may replace lower terrain,
    never higher. Each table defines its own 47 same-terrain connection masks;
    authored boundary variants supply the explicit two-material transition.
    Its affected/read neighborhood must contain only those two materials;
    void borders are rejected and map edges extend the center material.
    Disjoint GID ownership prevents ambiguous reconstruction from a flat map.
    """
    if not isinstance(rules, dict):
        raise ValueError('terrain rules must be an object')
    version = rules.get('version')
    if type(version) is not int or version not in (1, 2):
        raise ValueError('expected rpgc.terrain-rules version 1 or 2')
    if version == 1:
        return _validate_v1(rules)
    if rules.get('format') != FORMAT:
        raise ValueError('expected rpgc.terrain-rules format')
    mode = rules.get('mode')
    if mode == 'blob8':
        if set(rules) != {'format', 'version', 'mode', 'terrainGids', 'masks'}:
            raise ValueError('blob8 fields must be format, version, mode, terrainGids, masks')
        table = _blob_table({key: rules[key] for key in ('terrainGids', 'masks')})
        return {'format': FORMAT, 'version': 2, 'mode': mode, **table}
    if mode != 'transition8' or set(rules) != {'format', 'version', 'mode', 'terrains', 'priority'}:
        raise ValueError('expected transition8 fields format, version, mode, terrains, priority')
    terrains = rules['terrains']
    if not isinstance(terrains, dict) or len(terrains) != 2:
        raise ValueError('transition8 requires exactly two terrains')
    for name in terrains:
        if not isinstance(name, str) or not name or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-' for c in name):
            raise ValueError('terrain IDs must be nonempty stable ASCII names')
    priority = rules['priority']
    if not isinstance(priority, list) or len(priority) != 2 or any(not isinstance(x, str) for x in priority) or set(priority) != set(terrains):
        raise ValueError('priority must list both terrain IDs once, highest first')
    normalized = {name: _blob_table(table) for name, table in terrains.items()}
    first, second = (set(normalized[name]['terrainGids']) for name in priority)
    if first & second:
        raise ValueError('terrain GID ownership conflicts between terrains')
    return {'format': FORMAT, 'version': 2, 'mode': mode,
            'terrains': normalized, 'priority': list(priority)}


def autotile_map(document, layer_id, cells, rules, erase=False, seed=0, terrain_id=None):
    """Produce a deep-copied ordinary map candidate; never mutate any input.

    v1 remains byte-for-byte compatible. v2 blob8 needs no terrain_id;
    transition8 requires one of its two IDs. Empty/unrelated neighbors stay
    untouched. Both materials reconnect after edits. Out-of-map neighbors
    disconnect, and diagonal-only contacts cannot form an inner corner.
    transition8 requires all affected cells and their in-bounds neighbors to
    contain one of its two terrains after painting. Void/third-terrain borders
    fail explicitly; out-of-map cells extend the center material. Erase restores
    the lower-priority terrain rather than introducing a third (empty) material.
    Selected foreign GIDs and priority conflicts abort the entire operation.
    Erasing never removes another terrain, regardless of priority.
    """
    normalized = validate_rules(rules)
    if normalized['version'] == 1:
        if terrain_id is not None:
            raise ValueError('terrain_id is only supported by transition8')
        return _autotile_v1(document, layer_id, cells, normalized, erase, seed)
    transition = normalized['mode'] == 'transition8'
    width, height = _map(document)
    if type(erase) is not bool:
        raise ValueError('erase must be a boolean')
    _integer(seed, 'seed')
    if not isinstance(cells, (list, tuple)):
        raise ValueError('cells must be an array of [x, y] pairs')
    if normalized['mode'] == 'blob8':
        if terrain_id is not None:
            raise ValueError('terrain_id is only supported by transition8')
        target = 'terrain'
        terrains = {target: normalized}
        priority = [target]
    else:
        terrains = normalized['terrains']
        if not isinstance(terrain_id, str) or terrain_id not in terrains:
            raise ValueError('transition8 requires a registered terrain_id')
        target = terrain_id
        priority = normalized['priority']
    owner = {gid: name for name, table in terrains.items() for gid in table['terrainGids']}
    source = _layer(document, layer_id)['data']
    selected = set()
    for cell in cells:
        if not isinstance(cell, (tuple, list)) or len(cell) != 2:
            raise ValueError('each cell must be [x, y]')
        x, y = cell
        gid = source[_cell(x, y, width, height)]
        if type(gid) is not int or gid < 0:
            raise ValueError(f'cell ({x}, {y}) has an invalid GID')
        if gid != 0:
            previous = owner.get(gid)
            if previous is None:
                raise ValueError(f'cell ({x}, {y}) contains foreign GID {gid}; refusing to overwrite')
            if previous != target and (erase or priority.index(previous) < priority.index(target)):
                raise ValueError(f'cell ({x}, {y}) conflicts with terrain {previous} priority/erase ownership')
        selected.add((x, y))
    result = deepcopy(document)
    data = _layer(result, layer_id)['data']
    frontier = set(selected)
    for x, y in selected:
        replacement = terrains[priority[-1]]['terrainGids'][0] if transition else 0
        data[y * width + x] = replacement if erase else terrains[target]['terrainGids'][0]
        for dx, dy, _ in EIGHT_DIRECTIONS:
            nx, ny = x + dx, y + dy
            if 0 <= nx < width and 0 <= ny < height:
                frontier.add((nx, ny))
    if transition:
        required = set(frontier)
        for x, y in frontier:
            for dx, dy, _ in EIGHT_DIRECTIONS:
                nx, ny = x + dx, y + dy
                if 0 <= nx < width and 0 <= ny < height:
                    required.add((nx, ny))
        for x, y in required:
            gid = data[y * width + x]
            if type(gid) is not int or gid not in owner:
                raise ValueError(f'transition neighborhood ({x}, {y}) must contain one of the two terrains; void/foreign boundaries need separate rules')
    # Freeze semantic ownership before output variants are chosen.
    topology = [owner.get(gid) if type(gid) is int else None for gid in data]
    for x, y in sorted(frontier):
        name = topology[y * width + x]
        if name is None:
            continue
        mask = 0
        for dx, dy, bit in EIGHT_DIRECTIONS:
            nx, ny = x + dx, y + dy
            inside = 0 <= nx < width and 0 <= ny < height
            if (inside and topology[ny * width + nx] == name) or (transition and not inside):
                mask |= bit
        mask = normalize_blob_mask(mask)
        data[y * width + x] = _variant(terrains[name]['masks'][str(mask)], seed, x, y, mask)
    return result
