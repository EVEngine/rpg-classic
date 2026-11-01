"""Validate multi-document candidates in disposable project copies, never in place."""
from contextlib import contextmanager
from pathlib import Path
import shutil
import tempfile

from .project import Project, fingerprint, inside, read_json
from .runtime import run_headless


def prepare_changes(root, specification, base=None):
    project = Project(root)
    base = Path(base or root).resolve()
    if not isinstance(specification, dict) or specification.get('format') != 'rpgc.change-set' or type(specification.get('version')) is not int or specification.get('version') != 1:
        raise ValueError('expected rpgc.change-set version 1')
    if set(specification) - {'format','version','changes','deletions'}:
        raise ValueError('unknown change-set fields')
    changes, deletions = specification.get('changes', []), specification.get('deletions', [])
    if not isinstance(changes,list) or not isinstance(deletions,list):
        raise ValueError('changes and deletions must be arrays')
    prepared, used = [], set()
    for deleting, entries in ((False,changes),(True,deletions)):
        for entry in entries:
            if not isinstance(entry,dict) or set(entry)-{'path','source','document','expect'} or (deleting and ('source' in entry or 'document' in entry)):
                raise ValueError('invalid change-set entry')
            relative = entry.get('path')
            if not isinstance(relative,str):
                raise ValueError('entry path must be a string')
            path = inside(project.root,relative)
            normalized = path.relative_to(project.root).as_posix()
            if relative != normalized or normalized in used:
                raise ValueError(f'duplicate or noncanonical candidate path: {relative}')
            used.add(normalized)
            matches = [(kind,spec) for kind,spec in project.kinds.items()
                       if path.parent == inside(project.root,spec['directory'])
                       and path.name.endswith(spec.get('extension','.json'))]
            if len(matches)!=1 or path.name.endswith('.baked.json'):
                raise ValueError(f'candidate must target a declared content document: {relative}')
            kind,spec = matches[0]
            current = fingerprint(read_json(path)) if path.exists() else None
            # Explicit null means "must not exist"; omitted expect is permitted for previews.
            if 'expect' in entry and entry['expect'] != current:
                raise ValueError(f'stale candidate source: {relative}')
            item={'path':relative,'kind':kind,'before':current,'delete':deleting}
            if deleting:
                if current is None: raise ValueError(f'cannot delete missing content: {relative}')
            else:
                if ('source' in entry) == ('document' in entry):
                    raise ValueError('candidate requires exactly one source file or inline document')
                if 'document' in entry:
                    document=entry['document']
                else:
                    source=entry['source']
                    if not isinstance(source,str) or not source:
                        raise ValueError('candidate source must be a file path')
                    document=read_json(base/source)
                if not isinstance(document,dict): raise ValueError('candidate must be an object')
                item.update(document=document,after=fingerprint(document))
            prepared.append(item)
    return prepared


def _copy_directory(source,destination):
    # Do not follow links into other trees, even if copytree would permit them.
    for path in source.rglob('*'):
        if path.is_symlink(): raise ValueError(f'symlink in validation inputs: {path}')
    if source.is_symlink(): raise ValueError(f'symlink in validation inputs: {source}')
    shutil.copytree(source,destination,dirs_exist_ok=True)


@contextmanager
def candidate_workspace(root, prepared):
    """Copy validation inputs plus content; changes are discarded on any exit."""
    project=Project(root)
    with tempfile.TemporaryDirectory(prefix='rpgc-candidates-') as directory:
        target=Path(directory)
        for filename in ('workflow.json','config.nut'):
            source=inside(project.root,filename)
            if source.exists(): shutil.copy2(source,target/filename)
        directories={'lib','schema','data'} | {s['directory'] for s in project.kinds.values()}
        for relative in sorted(directories):
            source=inside(project.root,relative)
            if source.exists(): _copy_directory(source,inside(target,relative))
        for change in prepared:
            destination=inside(target,change['path'])
            if change['delete']:
                destination.unlink()
            else:
                import json
                destination.parent.mkdir(parents=True,exist_ok=True)
                destination.write_text(json.dumps(change['document'],ensure_ascii=False,indent=2,allow_nan=False)+'\n',encoding='utf-8')
        yield target


def check_changes(binary,root,specification,base=None,timeout=120):
    prepared=prepare_changes(root,specification,base)
    with candidate_workspace(root,prepared) as workspace:
        report=run_headless(binary,workspace,
            'RpgcToolkitResult <- RpgcValidate.reportJson(RpgcValidate.validateProject());',timeout)
    report['validated']=bool(report.get('ok'))
    report['applied']=False
    report['changes']=[{k:v for k,v in entry.items() if k!='document'} for entry in prepared]
    return report
