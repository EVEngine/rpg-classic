"""Generate reviewable content rename change-sets from an authoritative VM graph."""
from copy import deepcopy
import os
from pathlib import Path
import re

from .project import Project, fingerprint, inside, patch_document, pointer_tokens


def rename_changes(root, graph, kind, old_id, new_id):
    """Update exact ID/path references only; refuse ambiguous graph locations.

    The graph must come from rpgc graph. This only plans changes; check-changes
    must validate the combined result against the current project before use.
    """
    if not isinstance(new_id,str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*',new_id) or new_id==old_id:
        raise ValueError('new_id must be a different stable document identifier')
    if not isinstance(graph,dict) or graph.get('ok') is not True or not isinstance(graph.get('edges'),list) or not isinstance(graph.get('nodes'),list):
        raise ValueError('expected successful authoritative graph report')
    project=Project(root)
    entries=project.documents()
    indexed={f"{e['kind']}/{e['id']}":e for e in entries}
    if len(indexed)!=len(entries): raise ValueError('duplicate project document IDs')
    if {n.get('id') for n in graph['nodes']} != set(indexed):
        raise ValueError('graph inventory differs from current project; regenerate graph')
    target=f'{kind}/{old_id}'
    if target not in indexed: raise ValueError('rename source does not exist')
    if f'{kind}/{new_id}' in indexed: raise ValueError('rename target already exists')
    original=indexed[target]
    spec=project.kinds[kind]
    new_path=f"{spec['directory']}/{new_id}{spec.get('extension','.json')}"
    if inside(project.root,new_path).exists(): raise ValueError('rename target file already exists')
    candidates={original['path']:deepcopy(original['document'])}
    for edge in graph['edges']:
        if edge.get('target')!=target: continue
        source=indexed.get(edge.get('source'))
        if source is None: raise ValueError('graph contains unknown source')
        pointer=edge.get('path')
        tokens=pointer_tokens(pointer)
        value=source['document']
        try:
            for token in tokens:
                value=value[int(token)] if isinstance(value,list) else value[token]
        except (KeyError,ValueError,IndexError,TypeError) as error:
            raise ValueError(f'graph pointer is not an editable reference: {pointer}') from error
        if value==old_id:
            replacement=new_id
        elif isinstance(value,str):
            # Map tileset sources are document-relative paths, not IDs.
            linked=(project.root/source['path']).parent/value
            if linked.resolve()!=inside(project.root,original['path']):
                raise ValueError(f'graph reference has changed or is not directly editable: {source["path"]}{pointer}')
            replacement=os.path.relpath(inside(project.root,new_path),(project.root/source['path']).parent).replace(os.sep,'/')
        else:
            raise ValueError(f'non-string reference requires a specialized adapter: {pointer}')
        document=candidates.setdefault(source['path'],deepcopy(source['document']))
        candidates[source['path']]=patch_document(document,[{'op':'replace','path':pointer,'value':replacement}])
    candidates[original['path']]['id']=new_id
    by_path={e['path']:e for e in entries}
    changes=[]
    for path,document in sorted(candidates.items()):
        changes.append({'path':new_path if path==original['path'] else path,
                        'expect':None if path==original['path'] else by_path[path]['fingerprint'],
                        'document':document})
    return {'format':'rpgc.change-set','version':1,'changes':changes,
            'deletions':[{'path':original['path'],'expect':fingerprint(original['document'])}]}
