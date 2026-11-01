"""Side-effect-free authoring operations producing candidates for the engine gate.

These checks protect the operations themselves; they are not content validation.
All returned documents must still pass RpgcValidate before being committed.
"""
from collections import Counter, deque
from copy import deepcopy
import math


def _integer(value, label, minimum=0):
    if type(value) is not int or value < minimum:
        raise ValueError(f"{label} must be an integer >= {minimum}")
    return value


def _map(document):
    if not isinstance(document, dict) or document.get("schema") != "eve.rpgc.map":
        raise ValueError("expected an eve.rpgc.map document")
    width = _integer(document.get("width"), "width", 1)
    height = _integer(document.get("height"), "height", 1)
    if not isinstance(document.get("layers"), list):
        raise ValueError("map layers must be an array")
    for layer in document["layers"]:
        if not isinstance(layer, dict):
            raise ValueError("map layer must be an object")
        if layer.get("type", "tilelayer") == "tilelayer":
            if not isinstance(layer.get("data"), list) or len(layer["data"]) != width * height:
                raise ValueError(f"layer {layer.get('id')} data size does not match map")
    return width, height


def _layer(document, layer_id):
    if not isinstance(layer_id, (str, int)) or isinstance(layer_id, bool):
        raise ValueError("layer selector must be a name or id")
    matches = [x for x in document["layers"]
               if any(value is not None and str(value) == str(layer_id)
                      for value in (x.get("id"), x.get("name")))]
    if len(matches) != 1 or matches[0].get("type", "tilelayer") != "tilelayer":
        raise ValueError("layer name or id must identify exactly one tile layer")
    return matches[0]


def _cell(x, y, width, height):
    _integer(x, "x")
    _integer(y, "y")
    if x >= width or y >= height:
        raise ValueError(f"cell ({x}, {y}) is outside {width}x{height}")
    return y * width + x


def paint_map(document, layer_id, cells, gid):
    """Paint an iterable of [x,y] cells without changing the input."""
    width, height = _map(document)
    _integer(gid, "gid")
    result = deepcopy(document)
    layer = _layer(result, layer_id)
    for cell in cells:
        if not isinstance(cell, (list, tuple)) or len(cell) != 2:
            raise ValueError("each cell must be [x, y]")
        layer["data"][_cell(*cell, width, height)] = gid
    return result


def fill_map(document, layer_id, x, y, gid):
    """Four-connected flood fill of the seed's GID (including empty GID 0)."""
    width, height = _map(document)
    _integer(gid, "gid")
    index = _cell(x, y, width, height)
    result = deepcopy(document)
    data = _layer(result, layer_id)["data"]
    old = data[index]
    if old == gid:
        return result
    queue = deque([(x, y)])
    data[index] = gid
    while queue:
        cx, cy = queue.popleft()
        for nx, ny in ((cx-1, cy), (cx+1, cy), (cx, cy-1), (cx, cy+1)):
            if 0 <= nx < width and 0 <= ny < height and data[ny*width+nx] == old:
                data[ny*width+nx] = gid
                queue.append((nx, ny))
    return result


def resize_map(document, width, height, fill_gid=0):
    """Keep the top-left overlap, pad all tile layers, reject orphaned objects.

    Object anchors stay in world pixels. Bounds use the map's existing isometric
    pitch/origin and floor picking, as in RpgcIso.worldToTileX/Y.
    """
    old_width, old_height = _map(document)
    _integer(width, "width", 1)
    _integer(height, "height", 1)
    _integer(fill_gid, "fill_gid")
    # Prevent unbounded allocation; the actual schema remains authoritative.
    if width * height > 512 * 512:
        raise ValueError("resize allocation exceeds 262144 cells per layer")
    result = deepcopy(document)
    for layer in result["layers"]:
        if "width" in layer:
            layer["width"] = width
        if "height" in layer:
            layer["height"] = height
        if layer.get("type", "tilelayer") == "tilelayer":
            old = layer["data"]
            data = [fill_gid] * (width * height)
            for y in range(min(old_height, height)):
                count = min(old_width, width)
                data[y*width:y*width+count] = old[y*old_width:y*old_width+count]
            layer["data"] = data
        elif layer.get("type") == "objectgroup":
            try:
                px = document["tilewidth"] * document["renderSpacing"][0]
                py = document["tileheight"] * document["renderSpacing"][1]
                ox, oy = document["origin"]
                if px <= 0 or py <= 0:
                    raise ValueError("map pitch must be positive")
                for obj in layer.get("objects", []):
                    a, b = (obj["x"]-ox)/(px/2), (obj["y"]-oy)/(py/2)
                    tx, ty = math.floor((b+a)/2), math.floor((b-a)/2)
                    if not (0 <= tx < width and 0 <= ty < height):
                        raise ValueError(f"resize would strand object {obj.get('name')!r} at cell ({tx}, {ty})")
            except (KeyError, TypeError, IndexError, ZeroDivisionError) as exc:
                raise ValueError("object bounds require valid map pitch/origin/coordinates") from exc
    result["width"], result["height"] = width, height
    return result


def _event(document):
    if not isinstance(document, dict) or document.get("schema") != "eve.rpgc.event" or not isinstance(document.get("steps"), list):
        raise ValueError("expected an eve.rpgc.event document with steps")


def edit_event(document, operation, index, step=None, destination=None):
    """Edit top-level steps. move destination is the final zero-based index."""
    _event(document)
    _integer(index, "index")
    result = deepcopy(document)
    steps = result["steps"]
    if operation not in ("insert", "replace", "remove", "move"):
        raise ValueError("operation must be insert, replace, remove, or move")
    limit = len(steps) if operation == "insert" else len(steps)-1
    if index > limit:
        raise ValueError("event step index out of bounds")
    if operation in ("insert", "replace"):
        if not isinstance(step, dict) or not isinstance(step.get("kind"), str):
            raise ValueError("step must be an object with kind; engine validates its fields")
        if operation == "insert":
            steps.insert(index, deepcopy(step))
        else:
            steps[index] = deepcopy(step)
    elif operation == "remove":
        steps.pop(index)
    else:
        _integer(destination, "destination")
        if destination >= len(steps):
            raise ValueError("event destination index out of bounds")
        steps.insert(destination, steps.pop(index))
    return result


def analyze_event(document):
    """Inspect nested steps; report content references without executing them."""
    _event(document)
    counts, references, variables = Counter(), [], set()
    maximum = 0

    def walk(steps, pointer, depth):
        nonlocal maximum
        if not isinstance(steps, list):
            raise ValueError(f"{pointer} must be an array")
        for i, step in enumerate(steps):
            at = f"{pointer}/{i}"
            if not isinstance(step, dict) or not isinstance(step.get("kind"), str):
                raise ValueError(f"{at} must be a step object with kind")
            maximum = max(maximum, depth)
            counts[step["kind"]] += 1
            for key in ("reference", "mapId", "anim", "actorId", "objectName"):
                if key in step:
                    references.append({"path": f"{at}/{key}", "field": key, "value": step[key]})
            if step["kind"] == "set_variable" and isinstance(step.get("name"), str):
                variables.add(step["name"])
            condition = step.get("condition", {})
            if isinstance(condition, dict) and condition.get("kind") in ("switch", "variable") and isinstance(condition.get("name"), str):
                variables.add(condition["name"])
            for key in ("then", "else", "steps"):
                if key in step:
                    walk(step[key], f"{at}/{key}", depth+1)
    walk(document["steps"], "/steps", 1)
    return {"steps": sum(counts.values()), "kinds": dict(sorted(counts.items())), "references": references,
            "variables": sorted(variables), "maxDepth": maximum}


def _escape(value):
    return str(value).replace("~", "~0").replace("/", "~1")


def extract_strings(document):
    """Extract explicit display fields as RFC 6901 pointers; never IDs/references.

    Array indexes are stable only while structure is unchanged. Pass the original
    extracted sources to apply_strings to reject stale translation catalogs.
    """
    if not isinstance(document, dict):
        raise ValueError("document must be an object")
    strings = {}
    def walk(value, path):
        if isinstance(value, dict):
            for key, child in value.items():
                at = path + "/" + _escape(key)
                if isinstance(child, str) and (key in ("title", "description", "displayName", "text") or
                        (key == "value" and value.get("name") == "speaker" and "/properties/" in path)):
                    strings[at] = child
                elif isinstance(child, (dict, list)):
                    walk(child, at)
        elif isinstance(value, list):
            for i, child in enumerate(value):
                walk(child, path + "/" + str(i))
    walk(document, "")
    return strings


def apply_strings(document, translations, sources=None):
    """Apply a partial pointer→translation catalog, rejecting unknown/stale keys."""
    available = extract_strings(document)
    if not isinstance(translations, dict) or (sources is not None and not isinstance(sources, dict)):
        raise ValueError("translations and sources must be objects")
    result = deepcopy(document)
    for pointer, value in translations.items():
        if pointer not in available or not isinstance(value, str):
            raise ValueError(f"unknown display string or non-string translation: {pointer}")
        if sources is not None:
            if pointer not in sources:
                raise ValueError(f"missing source string: {pointer}")
            if sources[pointer] != available[pointer]:
                raise ValueError(f"stale source string: {pointer}")
        parts = [p.replace("~1", "/").replace("~0", "~") for p in pointer[1:].split("/")]
        target = result
        for part in parts[:-1]:
            target = target[int(part)] if isinstance(target, list) else target[part]
        target[parts[-1]] = value
    return result


def clone_document(document, new_id, title=None):
    """Clone one document; references stay intact and must pass the engine gate."""
    if not isinstance(document, dict) or not isinstance(new_id, str) or not new_id.strip():
        raise ValueError("document must be an object and new_id a nonempty string")
    if title is not None and not isinstance(title, str):
        raise ValueError("title must be a string")
    result = deepcopy(document)
    result["id"] = new_id
    if title is not None:
        result["title"] = title
    return result
