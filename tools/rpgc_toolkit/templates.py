"""Database and map-object templates with three-way updates (authoring only).

No runtime templates, event fragments, interpolation, inferred reference
rewrites, or writes to content. Database arrays merge atomically. Returned
change sets must pass check_templates/check_changes before external commit.
Sidecars are caller-owned JSON artifacts, never content documents.
"""
from copy import deepcopy
import re

from .project import Project, fingerprint, inside, read_json, pointer_tokens
from .changes import prepare_changes, check_changes

SCHEMAS = {'eve.rpgc.' + kind for kind in ('item', 'enemy', 'skill', 'effect', 'party')}
_MISSING = object()


def _id(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]*', value):
        raise ValueError('expected stable ID')
    return value


def _object(value, fields, label):
    if not isinstance(value, dict) or set(value) - set(fields):
        raise ValueError('unknown fields or invalid ' + label)


def _equal(a, b):
    return a is b if a is _MISSING or b is _MISSING else fingerprint(a) == fingerprint(b)


def _paths(paths):
    if not isinstance(paths, list):
        raise ValueError('pointers must be an array')
    parsed = []
    for path in paths:
        parts = pointer_tokens(path)
        if not parts or parts[0] in {'id', 'schema', 'version'}:
            raise ValueError('root and document identity pointers are reserved')
        if any(parts[:len(old)] == old or old[:len(parts)] == parts for old in parsed):
            raise ValueError('duplicate or overlapping pointers')
        parsed.append(parts)
    return parsed


def _locate(document, pointer):
    parts = pointer_tokens(pointer)
    node = document
    for part in parts[:-1]:
        node = _member(node, part)
    return node, parts[-1]


def _member(node, key):
    if isinstance(node, dict) and key in node:
        return node[key]
    if isinstance(node, list) and re.fullmatch(r'0|[1-9][0-9]*', key) and int(key) < len(node):
        return node[int(key)]
    raise ValueError('pointer must address an existing member: ' + key)


def _set(document, pointer, value):
    parent, key = _locate(document, pointer)
    _member(parent, key)
    parent[int(key) if isinstance(parent, list) else key] = deepcopy(value)


def _overlay(base, overlay):
    result = deepcopy(base)
    for key, value in overlay.items():
        result[key] = _overlay(result[key], value) if key in result and isinstance(result[key], dict) and isinstance(value, dict) else deepcopy(value)
    return result


def resolve_template(templates, template_id):
    """Resolve a list of unique templates; child document fields overlay base.

    Declaration maps inherit by name. A child may change parameter defaults but
    cannot change a parameter's type/pointers. Allowed overrides and reference
    pointers inherit unchanged unless explicitly replaced by the child.
    """
    if not isinstance(templates, list) or len(templates) > 256:
        raise ValueError('templates must be an array')
    catalog = {}
    for template in templates:
        _object(template, {'format', 'version', 'id', 'revision', 'base', 'document', 'parameters', 'allowedOverrides', 'referencePointers'}, 'template')
        if template.get('format') != 'rpgc.template' or type(template.get('version')) is not int or template['version'] != 1:
            raise ValueError('expected rpgc.template version 1')
        identifier = _id(template.get('id'))
        if identifier in catalog:
            raise ValueError('duplicate template ID: ' + identifier)
        if type(template.get('revision')) is not int or template['revision'] < 1:
            raise ValueError('template revision must be a positive integer')
        catalog[identifier] = template
    def visit(identifier, stack):
        if len(stack) > 64:
            raise ValueError('template inheritance depth exceeds 64')
        if identifier in stack:
            raise ValueError('template inheritance cycle: ' + ' -> '.join(stack + [identifier]))
        if identifier not in catalog:
            raise ValueError('unknown base/template ID: ' + str(identifier))
        template = catalog[identifier]
        parent = template.get('base')
        if parent is not None:
            _id(parent)
            result = visit(parent, stack + [identifier])
        else:
            result = {'document': {}, 'parameters': {}, 'allowedOverrides': [], 'referencePointers': [], 'lineage': []}
        document = template.get('document', {})
        if not isinstance(document, dict):
            raise ValueError('template document must be an object')
        result['document'] = _overlay(result['document'], document)
        parameters = template.get('parameters', {})
        if not isinstance(parameters, dict):
            raise ValueError('parameters must be an object')
        for name, definition in parameters.items():
            _id(name)
            _object(definition, {'type', 'default', 'pointers'}, 'parameter')
            if definition.get('type') not in {'string', 'integer', 'number', 'boolean', 'id'}:
                raise ValueError('unknown parameter type')
            if not definition.get('pointers'):
                raise ValueError('parameter requires target pointers')
            _paths(definition['pointers'])
            if 'default' in definition:
                _typed(definition['default'], definition['type'])
            if name in result['parameters'] and any(result['parameters'][name][key] != definition[key] for key in ('type', 'pointers')):
                raise ValueError('inherited parameter type/pointers cannot change')
            result['parameters'][name] = deepcopy(definition)
        for key in ('allowedOverrides', 'referencePointers'):
            if key in template:
                _paths(template[key])
                result[key] = deepcopy(template[key])
        result['lineage'].append({'id': identifier, 'revision': template['revision'], 'fingerprint': fingerprint(template)})
        return result
    # Reject cycles even in an unused catalog branch, never silently accept a bad library.
    for identifier in catalog:
        visit(identifier, [])
    result = visit(_id(template_id), [])
    document = result['document']
    if document.get('schema') not in SCHEMAS:
        raise ValueError('first version supports only database document templates')
    all_targets = [p for definition in result['parameters'].values() for p in definition['pointers']] + result['referencePointers']
    _paths(all_targets)
    for path in all_targets + result['allowedOverrides']:
        parent, key = _locate(document, path)
        _member(parent, key)
    return result


def _typed(value, kind):
    fingerprint(value)  # JSON serializability and finite-number guard.
    if kind == 'id':
        _id(value)
    elif not ((kind == 'string' and type(value) is str) or
              (kind == 'integer' and type(value) is int) or
              (kind == 'number' and type(value) in (int, float)) or
              (kind == 'boolean' and type(value) is bool)):
        raise ValueError('parameter requires ' + kind)


def expand_template(templates, template_id, instance_id, parameters=None, overrides=None, references=None):
    """Pure expansion. references is {declaredPointer: {from: ID, to: ID}}.

    Overrides replace only exactly declared pointers, never their siblings.
    Expanded base excludes manual overrides for subsequent three-way merging.
    """
    resolved = resolve_template(templates, template_id)
    parameters = {} if parameters is None else deepcopy(parameters)
    overrides = {} if overrides is None else overrides
    references = {} if references is None else deepcopy(references)
    if not all(isinstance(value, dict) for value in (parameters, overrides, references)):
        raise ValueError('parameters/overrides/references must be objects')
    if set(parameters) - set(resolved['parameters']):
        raise ValueError('unknown template parameter')
    document = deepcopy(resolved['document'])
    document['id'] = _id(instance_id)
    for name, definition in resolved['parameters'].items():
        if name not in parameters:
            if 'default' not in definition:
                raise ValueError('missing required parameter: ' + name)
            parameters[name] = deepcopy(definition['default'])
        _typed(parameters[name], definition['type'])
        for path in definition['pointers']:
            _set(document, path, parameters[name])
    for path, mapping in references.items():
        if not isinstance(path, str):
            raise ValueError('reference pointer must be a string')
        if path not in resolved['referencePointers']:
            raise ValueError('undeclared reference rewrite: ' + path)
        _object(mapping, {'from', 'to'}, 'reference mapping')
        _id(mapping.get('from')); _id(mapping.get('to'))
        parent, key = _locate(document, path)
        if _member(parent, key) != mapping['from']:
            raise ValueError('reference source no longer matches: ' + path)
        _set(document, path, mapping['to'])
    expanded = deepcopy(document)
    for path, value in overrides.items():
        if not isinstance(path, str):
            raise ValueError('override pointer must be a string')
        if path not in resolved['allowedOverrides']:
            raise ValueError('override pointer not allowed: ' + path)
        _set(document, path, value)
    fingerprint(document)
    sidecar = {'format': 'rpgc.template-instance', 'version': 1, 'templateId': template_id,
               'templateRevision': resolved['lineage'][-1]['revision'], 'lineage': resolved['lineage'],
               'instanceId': instance_id, 'parameters': parameters, 'references': references,
               'allowedOverrides': resolved['allowedOverrides'], 'expandedBase': expanded,
               'baseFingerprint': fingerprint(expanded)}
    return {'document': document, 'sidecar': sidecar}


def plan_instances(root, instances):
    """Each instance is {path, document, sidecar}; return guarded change-set.

    Existing IDs may only be updated in their current path. New IDs and paths
    must be unique across both the batch and project. Source is recorded in the
    sidecar by attaching path before external sidecar persistence.
    """
    project = Project(root)
    existing = project.documents()
    identifiers = {}
    for entry in existing:
        key = (entry['document'].get('schema'), entry['id'])
        if key in identifiers:
            raise ValueError('duplicate existing document ID')
        identifiers[key] = entry['path']
    if not isinstance(instances, list):
        raise ValueError('instances must be an array')
    changes, seen = [], set()
    for instance in instances:
        _object(instance, {'path', 'document', 'sidecar'}, 'instance')
        if set(instance) != {'path', 'document', 'sidecar'} or not isinstance(instance['document'], dict) or not isinstance(instance['path'], str):
            raise ValueError('instance requires path, document and sidecar')
        document, path = instance['document'], instance['path']
        sidecar = _sidecar(instance['sidecar'])
        if document.get('id') != sidecar['instanceId'] or document.get('schema') != sidecar['expandedBase'].get('schema'):
            raise ValueError('instance identity differs from sidecar')
        key = (document.get('schema'), document['id'])
        if key in seen or (key in identifiers and identifiers[key] != path):
            raise ValueError('duplicate instance ID or conflicting existing identity')
        seen.add(key)
        target = inside(project.root, path)
        current = read_json(target) if target.exists() else None
        if current is not None and (current.get('id'), current.get('schema')) != (document['id'], document['schema']):
            raise ValueError('candidate cannot replace another document identity')
        changes.append({'path': path, 'document': deepcopy(document), 'expect': fingerprint(current) if current is not None else None})
    specification = {'format': 'rpgc.change-set', 'version': 1, 'changes': changes, 'deletions': []}
    prepare_changes(root, specification)
    return specification


def _sidecar(value):
    fields = {'format', 'version', 'templateId', 'templateRevision', 'lineage', 'instanceId', 'parameters', 'references', 'allowedOverrides', 'expandedBase', 'baseFingerprint', 'path'}
    _object(value, fields, 'instance sidecar')
    required = fields - {'path'}
    if required - set(value) or value['format'] != 'rpgc.template-instance' or type(value['version']) is not int or value['version'] != 1:
        raise ValueError('invalid template instance sidecar')
    _id(value['templateId']); _id(value['instanceId'])
    base = value['expandedBase']
    if not isinstance(base, dict) or base.get('id') != value['instanceId'] or base.get('schema') not in SCHEMAS or fingerprint(base) != value['baseFingerprint']:
        raise ValueError('sidecar expanded base fingerprint/identity mismatch')
    _paths(value['allowedOverrides'])
    if not isinstance(value['parameters'], dict) or not isinstance(value['references'], dict):
        raise ValueError('sidecar parameters/references must be objects')
    lineage = value['lineage']
    if not isinstance(lineage, list) or not lineage or len(lineage) > 65:
        raise ValueError('invalid sidecar lineage')
    seen = set()
    for entry in lineage:
        _object(entry, {'id', 'revision', 'fingerprint'}, 'lineage entry')
        identifier = _id(entry.get('id'))
        if identifier in seen or type(entry.get('revision')) is not int or entry['revision'] < 1 or not isinstance(entry.get('fingerprint'), str) or not re.fullmatch('[0-9a-f]{64}', entry['fingerprint']):
            raise ValueError('invalid sidecar lineage entry')
        seen.add(identifier)
    if lineage[-1]['id'] != value['templateId'] or type(value['templateRevision']) is not int or lineage[-1]['revision'] != value['templateRevision']:
        raise ValueError('sidecar template revision does not match lineage')
    return value


def _pointer(path, key):
    return path + '/' + key.replace('~', '~0').replace('/', '~1')


def _merge(old, new, instance, path, conflicts):
    if _equal(instance, old):
        return deepcopy(new) if new is not _MISSING else _MISSING
    if _equal(new, old) or _equal(new, instance):
        return deepcopy(instance) if instance is not _MISSING else _MISSING
    if all(isinstance(v, dict) for v in (old, new, instance)):
        result = {}
        for key in sorted(set(old) | set(new) | set(instance)):
            merged = _merge(old.get(key, _MISSING), new.get(key, _MISSING), instance.get(key, _MISSING), _pointer(path, key), conflicts)
            if merged is not _MISSING:
                result[key] = merged
        return result
    conflicts.append({'pointer': path, **{name: {'exists': value is not _MISSING, 'value': None if value is _MISSING else deepcopy(value)} for name, value in [('baseOld', old), ('baseNew', new), ('instance', instance)]}})
    return deepcopy(instance) if instance is not _MISSING else _MISSING


def update_instances(root, templates, instances):
    """instances: list of {path, sidecar}; reread actual project instances.

    Includes all supplied affected instances (including inherited-base changes).
    Conflicted documents remain review candidates, excluded from changeSet;
    check_templates refuses the entire report until conflicts are resolved.
    Caller must supply their complete sidecar inventory to locate all instances.
    """
    if not isinstance(instances, list):
        raise ValueError('instances must be an array')
    results, conflicts, affected, clean = [], [], [], []
    snapshots = {}
    for record in instances:
        _object(record, {'path', 'sidecar'}, 'update record')
        if set(record) != {'path', 'sidecar'} or not isinstance(record['path'], str):
            raise ValueError('update record requires path and sidecar')
        path, old = record['path'], _sidecar(record['sidecar'])
        if 'path' in old and old['path'] != path:
            raise ValueError('instance source path differs from sidecar')
        current = read_json(inside(root, path))
        snapshots[path] = fingerprint(current)
        if not isinstance(current, dict) or current.get('id') != old['instanceId']:
            raise ValueError('instance identity changed')
        expanded = expand_template(templates, old['templateId'], old['instanceId'], old['parameters'], references=old['references'])
        local = []
        candidate = _merge(old['expandedBase'], expanded['document'], current, '', local)
        # Manual edits are allowed only under declared override subtrees.
        def manual(a, b, pointer=''):
            if _equal(a, b):
                return
            if pointer in old['allowedOverrides']:
                allowed = expanded['sidecar']['allowedOverrides']
                if not any(pointer == path or pointer.startswith(path + '/') for path in allowed):
                    if not any(item['pointer'] == pointer for item in local):
                        local.append({'pointer': pointer, 'reason': 'override-permission-removed'})
                return
            if isinstance(a, dict) and isinstance(b, dict):
                for key in sorted(set(a) | set(b)):
                    manual(a.get(key, _MISSING), b.get(key, _MISSING), _pointer(pointer, key))
            elif isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
                for index, (before, after) in enumerate(zip(a, b)):
                    manual(before, after, _pointer(pointer, str(index)))
            else:
                raise ValueError('manual edit outside allowed override pointers: ' + pointer)
        manual(old['expandedBase'], current)
        if old['lineage'] != expanded['sidecar']['lineage']:
            affected.append(path)
        expanded['sidecar']['path'] = path
        result = {'path': path, 'document': candidate, 'sidecar': expanded['sidecar']}
        results.append(result)
        conflicts.extend({'path': path, **item} for item in local)
        if not local:
            clean.append(result)
    # Check duplicate paths/IDs across conflicted candidates too.
    plan_instances(root, results)
    specification = plan_instances(root, clean)
    for change in specification['changes']:
        change['expect'] = snapshots[change['path']]
    prepare_changes(root, specification)
    return {'ok': not conflicts, 'validated': False, 'applied': False, 'affected': affected,
            'conflicts': conflicts, 'instances': results, 'changeSet': specification}


def check_templates(binary, root, report, timeout=120):
    """Invoke the existing isolated project-wide authoritative candidate gate."""
    if not isinstance(report, dict) or report.get('conflicts') or report.get('ok') is not True:
        raise ValueError('resolve all template update conflicts before candidate validation')
    return check_changes(binary, root, report['changeSet'], timeout=timeout)


def _expand_object_group(template, instance_id, name_map, world_offset):
    import math
    _object(template, {'format', 'version', 'id', 'revision', 'coordinateSpace', 'objects', 'nameReferences'}, 'object-group template')
    if template.get('format') != 'rpgc.object-group-template' or type(template.get('version')) is not int or template['version'] != 1:
        raise ValueError('expected rpgc.object-group-template version 1')
    _id(template.get('id')); _id(instance_id)
    if type(template.get('revision')) is not int or template['revision'] < 1 or template.get('coordinateSpace') != 'world':
        raise ValueError('object-group template needs positive revision and explicit world coordinateSpace')
    objects = deepcopy(template.get('objects'))
    if not isinstance(objects, list) or not objects or len(objects) > 4096:
        raise ValueError('object template needs 1..4096 objects')
    def coordinate(value):
        if type(value) not in (int, float) or not math.isfinite(value):
            raise ValueError('world coordinates/offset must be finite numbers')
        return value
    if not isinstance(world_offset, (list, tuple)) or len(world_offset) != 2:
        raise ValueError('world offset must be [x,y]')
    dx, dy = [coordinate(value) for value in world_offset]
    sources = {}
    for obj in objects:
        if not isinstance(obj, dict):
            raise ValueError('template object must be an object')
        name = _id(obj.get('name'))
        if name in sources:
            raise ValueError('duplicate template object name')
        sources[name] = obj
        coordinate(obj.get('x')); coordinate(obj.get('y'))
    if not isinstance(name_map, dict) or set(name_map) != set(sources):
        raise ValueError('name_map must explicitly map every source object name')
    targets = [_id(value) for value in name_map.values()]
    if len(set(targets)) != len(targets):
        raise ValueError('mapped object names must be unique')
    references = template.get('nameReferences', [])
    if not isinstance(references, list):
        raise ValueError('nameReferences must be an array')
    paths = {}
    for reference in references:
        _object(reference, {'object', 'pointer'}, 'object name reference')
        name = reference.get('object'); pointer = reference.get('pointer')
        if name not in sources:
            raise ValueError('name reference source is not a template object')
        tokens = pointer_tokens(pointer)
        if not tokens or tokens[0] in {'name', 'x', 'y', 'type'}:
            raise ValueError('name reference must target a payload property')
        paths.setdefault(name, []).append(pointer)
        _paths(paths[name])
        parent, key = _locate(sources[name], pointer)
        value = _member(parent, key)
        if not isinstance(value, str) or value not in name_map:
            raise ValueError('name reference must identify a source object name')
        _set(sources[name], pointer, name_map[value])
    for name, obj in sources.items():
        obj['name'] = name_map[name]
        obj['x'] = coordinate(obj['x'] + dx); obj['y'] = coordinate(obj['y'] + dy)
    return objects, [dx, dy]


def instantiate_object_group(root, map_path, layer, template, instance_id, name_map, world_offset=(0, 0)):
    """Static object-group instantiation into a normal map candidate.

    Objects use native map world coordinates; offset is [worldX, worldY], never
    tile coordinates. name_map must map every source name exactly once. Only
    declared nameReferences ({object, pointer}) are rewritten; other strings
    are untouched. This v1 API does NOT update existing object-group instances.
    Its v1 sidecar can be upgraded by update_object_groups with the original
    template supplied for verified baseline reconstruction.
    """
    objects, offset = _expand_object_group(template, instance_id, name_map, world_offset)
    dx, dy = offset
    targets = [obj['name'] for obj in objects]
    if type(layer) not in (str, int) or layer == '':
        raise ValueError('objectgroup selector must be a name or id')
    project = Project(root)
    entries = [entry for entry in project.documents('map') if entry['path'] == map_path]
    if len(entries) != 1:
        raise ValueError('map_path must select exactly one declared map document')
    entry = entries[0]; document = deepcopy(entry['document'])
    if document.get('schema') != 'eve.rpgc.map' or not isinstance(document.get('layers'), list):
        raise ValueError('expected a map with layers')
    selected, used = [], set()
    for candidate in document['layers']:
        if not isinstance(candidate, dict):
            raise ValueError('map layer must be an object')
        if candidate.get('type') != 'objectgroup':
            continue
        if not isinstance(candidate.get('objects'), list):
            raise ValueError('map objectgroup requires objects array')
        if layer in (candidate.get('id'), candidate.get('name')):
            selected.append(candidate)
        for obj in candidate['objects']:
            if not isinstance(obj, dict) or not isinstance(obj.get('name'), str):
                raise ValueError('map object requires a name')
            if obj['name'] in used:
                raise ValueError('existing map has duplicate object names')
            used.add(obj['name'])
    if len(selected) != 1:
        raise ValueError('layer must identify exactly one objectgroup by name or id')
    if used.intersection(targets):
        raise ValueError('mapped object name already exists in map; static instantiation never replaces objects')
    selected[0]['objects'].extend(objects)
    specification = {'format': 'rpgc.change-set', 'version': 1, 'changes': [
        {'path': map_path, 'document': document, 'expect': entry['fingerprint']}], 'deletions': []}
    prepare_changes(root, specification)
    sidecar = {'format': 'rpgc.object-group-instance', 'version': 1, 'staticInstantiation': True,
               'templateId': template['id'], 'templateRevision': template['revision'], 'templateFingerprint': fingerprint(template),
               'instanceId': instance_id, 'path': map_path, 'layer': layer, 'nameMap': deepcopy(name_map),
               'coordinateSpace': 'world', 'worldOffset': [dx, dy], 'sourceFingerprint': entry['fingerprint'],
               'expandedObjects': deepcopy(objects)}
    return {'ok': True, 'validated': False, 'applied': False, 'conflicts': [],
            'instances': [{'path': map_path, 'document': document, 'sidecar': sidecar}], 'changeSet': specification}


def _group_catalog(templates):
    if not isinstance(templates, list) or len(templates) > 256:
        raise ValueError('object-group templates must be an array of at most 256 entries')
    result = {}
    for template in templates:
        if not isinstance(template, dict):
            raise ValueError('object-group template must be an object')
        identifier = _id(template.get('id'))
        if identifier in result:
            raise ValueError('duplicate object-group template ID')
        objects = template.get('objects')
        if not isinstance(objects, list):
            raise ValueError('object-group template requires objects')
        names = {_id(obj.get('name')): _id(obj.get('name')) for obj in objects if isinstance(obj, dict)}
        _expand_object_group(template, 'validation', names, (0, 0))
        result[identifier] = deepcopy(template)
    return result


def _group_fingerprint(sidecar):
    # Internal consistency, not authentication. Protect metadata as well as the
    # expansion so accidental mapping/offset edits cannot redirect ownership.
    return fingerprint({key: sidecar[key] for key in (
        'templateId', 'templateRevision', 'templateFingerprint', 'instanceId',
        'path', 'layer', 'nameMap', 'coordinateSpace', 'worldOffset', 'expandedObjects')})


def _group_sidecar(value, previous):
    fields = {'format','version','staticInstantiation','templateId','templateRevision',
              'templateFingerprint','instanceId','path','layer','nameMap','coordinateSpace',
              'worldOffset','sourceFingerprint','expandedObjects'}
    _object(value, fields | {'baseFingerprint'}, 'object-group instance sidecar')
    version = value.get('version')
    if type(version) is not int or version not in (1, 2) or set(value) != fields | ({'baseFingerprint'} if version == 2 else set()):
        raise ValueError('invalid object-group instance sidecar fields/version')
    if value['format'] != 'rpgc.object-group-instance' or value['coordinateSpace'] != 'world' or value['staticInstantiation'] is not (version == 1):
        raise ValueError('invalid object-group instance format/coordinate space')
    _id(value['templateId']); _id(value['instanceId'])
    if type(value['templateRevision']) is not int or value['templateRevision'] < 1:
        raise ValueError('invalid template revision')
    for field in ('templateFingerprint','sourceFingerprint'):
        if not isinstance(value[field], str) or not re.fullmatch('[0-9a-f]{64}', value[field]):
            raise ValueError('invalid sidecar ' + field)
    if not isinstance(value['path'], str) or type(value['layer']) not in (str, int) or value['layer'] == '':
        raise ValueError('invalid sidecar map/layer')
    mapping = value['nameMap']
    if not isinstance(mapping, dict) or not mapping:
        raise ValueError('sidecar nameMap must be nonempty')
    for name, target in mapping.items():
        _id(name); _id(target)
    if len(set(mapping.values())) != len(mapping):
        raise ValueError('sidecar nameMap contains collisions')
    objects = value['expandedObjects']
    # Validate object shape/finite coordinates using the same expansion rules.
    probe = {'format':'rpgc.object-group-template','version':1,'id':'baseline',
             'revision':1,'coordinateSpace':'world','objects':objects}
    _expand_object_group(probe, value['instanceId'], {name:name for name in mapping.values()}, (0,0))
    offset = value['worldOffset']
    _expand_object_group(probe, value['instanceId'], {name:name for name in mapping.values()}, offset)
    if version == 1:
        old = previous.get(value['templateId'])
        if old is None or old['revision'] != value['templateRevision'] or fingerprint(old) != value['templateFingerprint']:
            raise ValueError('v1 static sidecar requires the matching previous template')
        expanded, _ = _expand_object_group(old, value['instanceId'], mapping, offset)
        if not _equal(expanded, objects):
            raise ValueError('v1 sidecar expansion differs from verified previous template')
    elif value['baseFingerprint'] != _group_fingerprint(value):
        raise ValueError('object-group baseline fingerprint mismatch')
    return deepcopy(value)


def _group_layer(document, selector):
    if not isinstance(document,dict) or document.get('schema') != 'eve.rpgc.map' or not isinstance(document.get('layers'),list):
        raise ValueError('expected map document with layers')
    groups = []
    names = {}
    for index, layer in enumerate(document.get('layers', [])):
        if not isinstance(layer,dict):
            raise ValueError('map layer must be an object')
        if layer.get('type') != 'objectgroup':
            continue
        if not isinstance(layer.get('objects'), list):
            raise ValueError('objectgroup requires objects array')
        if selector in (layer.get('id'), layer.get('name')):
            groups.append(index)
        for obj in layer['objects']:
            if not isinstance(obj, dict) or not isinstance(obj.get('name'), str) or obj['name'] in names:
                raise ValueError('map has malformed or duplicate object names')
            names[obj['name']] = (index, obj)
    if len(groups) != 1:
        raise ValueError('sidecar layer no longer uniquely identifies an objectgroup')
    return groups[0], names


def _merge_group_object(old, new, current, pointer, conflicts):
    # Tiled properties have stable names, unlike ordinary positional arrays.
    # Treat distinct named properties as distinct fields while keeping their
    # original order; all other arrays retain the existing atomic merge rule.
    if not all(isinstance(obj, dict) for obj in (old, new, current)):
        return _merge(old, new, current, pointer, conflicts)
    converted = []
    orders = []
    for obj in (old, new, current):
        copy = deepcopy(obj)
        if 'properties' in copy:
            properties = copy['properties']
            if not isinstance(properties, list) or any(not isinstance(row, dict) or not isinstance(row.get('name'), str) for row in properties):
                raise ValueError('object properties must be named rows')
            names = [row['name'] for row in properties]
            if len(set(names)) != len(names):
                raise ValueError('object properties contain duplicate names')
            copy['properties'] = {row['name']:row for row in properties}
            orders.append(names)
        else:
            orders.append([])
        converted.append(copy)
    merged = _merge(*converted, pointer, conflicts)
    if 'properties' in merged:
        order = list(dict.fromkeys(orders[2] + orders[1] + orders[0]))
        merged['properties'] = [merged['properties'][name] for name in order if name in merged['properties']]
    return merged


def update_object_groups(root, templates, instances, previous_templates=None):
    """Three-way update object groups into guarded whole-map candidates.

    records: {path,sidecar,nameMap?,worldOffset?,renames?}. nameMap, when present,
    maps every NEW source name. renames explicitly maps OLD source names to NEW
    source names; no rename inference or undeclared external-reference rewrites.
    Missing current objects are manual deletions; moved objects conflict.
    v1 sidecars require previous_templates to reconstruct the trusted baseline.
    v2 baseFingerprint protects internal consistency, not authenticity.

    A conflict excludes the entire map, including clean sibling instances, from
    changeSet. Returned sidecars are proposed baselines only: publish them only
    after check_templates and successful guarded commit of their whole map.
    No source files are written. Current maps are snapshotted once per batch.
    """
    catalog = _group_catalog(templates)
    previous = _group_catalog([] if previous_templates is None else previous_templates)
    if not isinstance(instances, list) or len(instances) > 4096:
        raise ValueError('instances must be an array of at most 4096 entries')
    project = Project(root)
    maps = {entry['path']:entry for entry in project.documents('map')}
    candidates, records, ownership, used_ids = {}, [], {}, set()
    operations, owned_by = {}, {}
    for record in instances:
        _object(record, {'path','sidecar','nameMap','worldOffset','renames'}, 'object-group update record')
        if not {'path','sidecar'} <= set(record) or not isinstance(record['path'], str):
            raise ValueError('object-group update record requires path and sidecar')
        path = record['path']; old = _group_sidecar(record['sidecar'], previous)
        if old['path'] != path or path not in maps:
            raise ValueError('sidecar path must match an existing declared map')
        key = (path, old['instanceId'])
        if key in used_ids:
            raise ValueError('duplicate object-group instance in batch')
        used_ids.add(key)
        if old['templateId'] not in catalog:
            raise ValueError('new template missing for object-group instance')
        document = maps[path]['document']
        group, current_names = _group_layer(document, old['layer'])
        if path not in candidates:
            candidates[path] = deepcopy(document)
            ownership[path] = set()
            owned_by[path] = {}
            operations[path] = {}
        old_targets = set(old['nameMap'].values())
        if old_targets & ownership[path]:
            raise ValueError('object-group sidecars claim overlapping objects')
        ownership[path].update(old_targets)
        owned_by[path].update({name:old['instanceId'] for name in old_targets})
        template = catalog[old['templateId']]
        if template['revision'] < old['templateRevision'] or (template['revision'] == old['templateRevision'] and fingerprint(template) != old['templateFingerprint']):
            raise ValueError('template changes require an increased revision')
        new_sources = {obj['name'] for obj in template['objects']}
        renames = record.get('renames', {})
        if not isinstance(renames, dict):
            raise ValueError('renames must map old source names to new source names')
        for source, target in renames.items():
            _id(source); _id(target)
            if source not in old['nameMap'] or target not in new_sources or source == target:
                raise ValueError('rename must identify an old and a distinct new source object')
            if source in new_sources or target in old['nameMap']:
                raise ValueError('rename cannot collide with retained source identities')
        if len(set(renames.values())) != len(renames):
            raise ValueError('rename mappings collide')
        logical = {source:renames.get(source,source) for source in old['nameMap']}
        inherited = {new:old['nameMap'][source] for source,new in logical.items() if new in new_sources}
        mapping = record.get('nameMap', inherited)
        expanded, offset = _expand_object_group(template, old['instanceId'], mapping, record.get('worldOffset',old['worldOffset']))
        new_by_name = {obj['name']:obj for obj in expanded}
        old_by_name = {obj['name']:obj for obj in old['expandedObjects']}
        local, updates, additions = [], {}, []
        handled = set()
        for source, old_target in old['nameMap'].items():
            new_source = logical[source]
            new_target = mapping.get(new_source) if new_source in new_sources else None
            new = new_by_name[new_target] if new_target is not None else _MISSING
            current_entry = current_names.get(old_target)
            current = current_entry[1] if current_entry is not None else _MISSING
            if current_entry is not None and current_entry[0] != group:
                local.append({'object':old_target,'pointer':'','reason':'object-moved-to-another-layer'})
                handled.add(new_source)
                continue
            object_conflicts = []
            merged = _merge_group_object(old_by_name[old_target], new, current, '', object_conflicts)
            local.extend({'object':old_target,**item} for item in object_conflicts)
            updates[old_target] = merged
            handled.add(new_source)
        for source in sorted(new_sources - handled):
            additions.append(deepcopy(new_by_name[mapping[source]]))
        planned = operations[path].setdefault(group, {'updates':{},'additions':[]})
        planned['updates'].update(updates)
        planned['additions'].extend(additions)
        sidecar = {'format':'rpgc.object-group-instance','version':2,'staticInstantiation':False,
                   'templateId':template['id'],'templateRevision':template['revision'],
                   'templateFingerprint':fingerprint(template),'instanceId':old['instanceId'],
                   'path':path,'layer':old['layer'],'nameMap':deepcopy(mapping),
                   'coordinateSpace':'world','worldOffset':offset,
                   'sourceFingerprint':maps[path]['fingerprint'],'expandedObjects':deepcopy(expanded)}
        sidecar['baseFingerprint'] = _group_fingerprint(sidecar)
        records.append({'path':path,'instanceId':old['instanceId'],'sidecar':sidecar,
                        'conflicts':local,'affected':old['templateFingerprint'] != fingerprint(template) or old['nameMap'] != mapping or old['worldOffset'] != offset})
    # Reserve every original owner's namespace before applying any operation.
    # A sibling deleting/renaming away a name does not authorize taking it over.
    for row in records:
        for name in row['sidecar']['nameMap'].values():
            owner = owned_by[row['path']].get(name)
            if owner is not None and owner != row['instanceId']:
                row['conflicts'].append({'object':name,'pointer':'/name','reason':'object-name-owned-by-another-instance'})
    for path, groups in operations.items():
        for group, plan in groups.items():
            original = maps[path]['document']['layers'][group]['objects']
            candidates[path]['layers'][group]['objects'] = [
                plan['updates'].get(obj['name'], deepcopy(obj)) for obj in original
                if plan['updates'].get(obj['name'], obj) is not _MISSING]
            candidates[path]['layers'][group]['objects'].extend(plan['additions'])
    conflicts = [{'path':row['path'],'instanceId':row['instanceId'],**issue}
                 for row in records for issue in row['conflicts']]
    # Name collisions include unrelated map objects and other batch instances.
    # Keep them visible as review conflicts; never emit a commit for that map.
    for path, document in candidates.items():
        names = set()
        for layer in document['layers']:
            for obj in layer.get('objects', []):
                name = obj.get('name')
                if not isinstance(name,str) or name in names:
                    conflicts.append({'path':path,'instanceId':None,'object':name,'pointer':'/name','reason':'object-name-collision'})
                names.add(name)
    blocked = {item['path'] for item in conflicts}
    specification = {'format':'rpgc.change-set','version':1,'changes':[
        {'path':path,'document':deepcopy(document),'expect':maps[path]['fingerprint']}
        for path,document in sorted(candidates.items()) if path not in blocked], 'deletions':[]}
    prepare_changes(root, specification)
    return {'ok':not conflicts,'validated':False,'applied':False,
            'affected':sorted({row['path'] for row in records if row['affected']}),
            'conflicts':conflicts,'instances':[
                {'path':row['path'],'instanceId':row['instanceId'],'document':deepcopy(candidates[row['path']]),
                 'sidecar':row['sidecar'],'sidecarStatus':'proposed-conflicted' if row['path'] in blocked else 'proposed-uncommitted'}
                for row in records], 'changeSet':specification}
