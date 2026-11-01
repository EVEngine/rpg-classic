"""Presentation-only map differences, never an alternative content validator."""
from copy import deepcopy
from .project import fingerprint


def map_diff(before, after):
    """Compare native tile coordinates and stable layer/object identities.

    None represents an absent cell/object/map, distinct from the empty GID 0.
    Documents must have passed the project's content gate before use in a UI.
    Full fingerprints additionally expose metadata-only changes.
    """
    def layers(document):
        return {layer['id']: layer for layer in document.get('layers', [])} if document else {}
    left, right = layers(before), layers(after)
    cells, objects = [], []
    for layer_id in sorted(left.keys() | right.keys(), key=lambda value: (type(value).__name__, str(value))):
        old, new = left.get(layer_id, {}), right.get(layer_id, {})
        if old.get('type', 'tilelayer') == 'tilelayer' or new.get('type', 'tilelayer') == 'tilelayer':
            ow, oh = (before['width'], before['height']) if before and 'data' in old else (0, 0)
            nw, nh = (after['width'], after['height']) if after and 'data' in new else (0, 0)
            for y in range(max(oh, nh)):
                for x in range(max(ow, nw)):
                    a = old['data'][y * ow + x] if x < ow and y < oh else None
                    b = new['data'][y * nw + x] if x < nw and y < nh else None
                    if a != b:
                        cells.append({'layerId': layer_id, 'x': x, 'y': y, 'before': a, 'after': b})
        old_objects = {obj['name']: obj for obj in old.get('objects', [])}
        new_objects = {obj['name']: obj for obj in new.get('objects', [])}
        for name in sorted(old_objects.keys() | new_objects.keys()):
            a, b = old_objects.get(name), new_objects.get(name)
            if a != b:
                objects.append({'layerId': layer_id, 'name': name,
                                'before': deepcopy(a), 'after': deepcopy(b)})
    a, b = fingerprint(before) if before is not None else None, fingerprint(after) if after is not None else None
    return {'mapId': (after or before or {}).get('id'), 'beforeFingerprint': a, 'afterFingerprint': b,
            'beforeSize': [before['width'], before['height']] if before else None,
            'afterSize': [after['width'], after['height']] if after else None,
            'cells': cells, 'objects': objects, 'changed': a != b,
            'counts': {'cells': len(cells), 'objects': len(objects)}}
