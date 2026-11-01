"""Spreadsheet-friendly typed CSV exchange; imports produce guarded change-sets."""
import csv
from io import StringIO
import json

from .project import Project, pointer_tokens, patch_document, parse_json

META = ['_path','_id','_fingerprint']
RESERVED = {'id','schema','version'}


def _fields(fields):
    if not isinstance(fields,list) or not fields or len(fields)!=len(set(fields)):
        raise ValueError('fields must be a nonempty unique list of JSON pointers')
    tokens=[]
    for field in fields:
        parts=pointer_tokens(field)
        if not parts or parts[0] in RESERVED:
            raise ValueError('database exchange cannot edit root/id/schema/version')
        if any(parts[:len(other)]==other or other[:len(parts)]==parts for other in tokens):
            raise ValueError('overlapping database fields are ambiguous')
        tokens.append(parts)
    return tokens


def _value(document, parts):
    value=document
    for part in parts:
        if isinstance(value,dict):
            if part not in value: return False,None
            value=value[part]
        elif isinstance(value,list):
            if not part.isascii() or not part.isdigit() or (len(part)>1 and part.startswith('0')) or int(part)>=len(value):
                return False,None
            value=value[int(part)]
        else:
            return False,None
    return True,value


def export_csv(root, kind, fields):
    """Cells contain JSON literals: strings are quoted, numbers retain types.

    Empty cell means missing/no edit. Explicit null is a JSON null value.
    Metadata stays plain text and must be retained by the spreadsheet editor.
    """
    tokens=_fields(fields)
    project=Project(root)
    output=StringIO(newline='')
    writer=csv.writer(output,lineterminator='\n')
    writer.writerow(META+fields)
    for entry in project.documents(kind):
        row=[entry['path'],entry['id'],entry['fingerprint']]
        for parts in tokens:
            exists,value=_value(entry['document'],parts)
            row.append(json.dumps(value,ensure_ascii=False,separators=(',',':'),allow_nan=False) if exists else '')
        writer.writerow(row)
    return output.getvalue()


def import_csv(root, kind, text):
    """Refuse stale/duplicate rows; preserve omitted fields and documents.

    Values may replace existing fields or add final object members. Adding
    array positions or missing intermediate objects is deliberately refused.
    """
    project=Project(root)
    entries={e['path']:e for e in project.documents(kind)}
    reader=csv.reader(StringIO(text.lstrip('\ufeff'),newline=''),strict=True)
    try:
        header=next(reader)
    except StopIteration as error:
        raise ValueError('CSV requires a header') from error
    if header[:3]!=META:
        raise ValueError('CSV metadata columns must be _path,_id,_fingerprint in order')
    fields=header[3:]; tokens=_fields(fields)
    changes,seen=[],set()
    for number,row in enumerate(reader,2):
        if not row: continue
        if len(row)!=len(header): raise ValueError(f'CSV row {number} has wrong column count')
        path,identifier,revision=row[:3]
        if path not in entries or path in seen:
            raise ValueError(f'CSV row {number}: unknown/duplicate document path')
        seen.add(path); entry=entries[path]
        if identifier!=entry['id'] or revision!=entry['fingerprint']:
            raise ValueError(f'CSV row {number}: stale fingerprint or changed identity')
        operations=[]
        for pointer,parts,cell in zip(fields,tokens,row[3:]):
            if cell=='': continue
            try:
                value=parse_json(cell)
            except ValueError as error:
                raise ValueError(f'CSV row {number} {pointer}: use a JSON literal ({error})') from error
            exists,current=_value(entry['document'],parts)
            # Compare serialized values to preserve boolean/number distinctions.
            if exists and json.dumps(current,sort_keys=True,allow_nan=False)==json.dumps(value,sort_keys=True,allow_nan=False):
                continue
            if not exists:
                parent_exists,parent=_value(entry['document'],parts[:-1])
                if not parent_exists or not isinstance(parent,dict):
                    raise ValueError(f'CSV row {number}: cannot insert array position or missing parent at {pointer}')
            operations.append({'op':'replace' if exists else 'add','path':pointer,'value':value})
        if operations:
            candidate=patch_document(entry['document'],operations,revision)
            changes.append({'path':path,'expect':revision,'document':candidate})
    return {'format':'rpgc.change-set','version':1,'changes':changes,'deletions':[]}
