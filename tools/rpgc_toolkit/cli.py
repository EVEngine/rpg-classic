"""CLI adapter. Candidate commands print raw JSON suitable for the existing stage gate."""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

from .project import Project, encounter_report, inside, patch_document, read_json


def add_parser(sub):
    parser = sub.add_parser("toolkit", help="reusable offline authoring, audit and build tools")
    parser.set_defaults(offline=True, func=run)
    commands = parser.add_subparsers(dest="tool", required=True)
    commands.add_parser("doctor", help="inspect manifest/content and asset readiness (not engine validation)")
    catalog = commands.add_parser("catalog", help="query all declared content kinds")
    catalog.add_argument("--kind")
    catalog.add_argument("--query")
    schema = commands.add_parser("schema", help="read the authoritative Eve Schema descriptor")
    schema.add_argument("kind")
    clone = commands.add_parser("clone", help="clone a document into a candidate JSON")
    clone.add_argument("path")
    clone.add_argument("new_id")
    clone.add_argument("--title")
    patch = commands.add_parser("patch", help="apply add/remove/replace/test JSON patch to a candidate")
    patch.add_argument("path")
    patch.add_argument("operations", help="JSON patch file")
    patch.add_argument("--expect", help="expected canonical SHA-256 from catalog")
    maps = commands.add_parser("map", help="produce map-edit candidates")
    maps.add_argument("operation", choices=("paint", "fill", "resize"))
    maps.add_argument("path")
    maps.add_argument("--layer", help="layer name or integer id")
    maps.add_argument("--cells", help="JSON file with [[x,y],...] for paint")
    maps.add_argument("--x", type=int)
    maps.add_argument("--y", type=int)
    maps.add_argument("--gid", type=int, default=0)
    maps.add_argument("--width", type=int)
    maps.add_argument("--height", type=int)
    event = commands.add_parser("event", help="event analysis and step editing")
    event.add_argument("operation", choices=("analyze", "insert", "replace", "remove", "move"))
    event.add_argument("path")
    event.add_argument("--index", type=int)
    event.add_argument("--step", help="JSON file containing one event step")
    event.add_argument("--destination", type=int)
    strings = commands.add_parser("strings", help="extract or apply source-checked document translations")
    strings.add_argument("operation", choices=("extract", "apply"))
    strings.add_argument("path")
    strings.add_argument("--catalog", help="JSON {sources:{pointer:text},translations:{pointer:text}}")
    commands.add_parser("assets", help="audit referenced images and generate hashes")
    commands.add_parser("balance", help="authored encounter stat totals, without simulating combat")
    bundle = commands.add_parser("bundle", help="build a reproducible source distribution (not an executable)")
    bundle.add_argument("output")
    verify = commands.add_parser("verify-bundle", help="verify all archive members against their hashes")
    verify.add_argument("path")
    story = commands.add_parser("story", help="compile an acyclic story graph to an event candidate")
    story.add_argument("source")
    quest = commands.add_parser("quest", help="compile guarded quest stages to event candidates")
    quest.add_argument("source")
    migrate = commands.add_parser("migrate-save", help="produce a lossless inventory ID migration candidate")
    migrate.add_argument("source")
    migrate.add_argument("mapping", help="JSON {items:{old:new},slots:{old:new}}")
    migrate.add_argument("--expect")
    animation = commands.add_parser("import-animation", help="derive an animation candidate from a PNG grid")
    animation.add_argument("image")
    animation.add_argument("id")
    animation.add_argument("--image-reference", required=True, help="path relative to the final animation document")
    animation.add_argument("--frame-width", required=True, type=int)
    animation.add_argument("--frame-height", required=True, type=int)
    animation.add_argument("--clips", required=True, help="JSON array of named clips")
    animation.add_argument("--margin", type=int, default=0)
    animation.add_argument("--spacing", type=int, default=0)
    animation.add_argument("--title")
    audio = commands.add_parser("audio", help="inspect PCM WAV or trim a half-open range of frames")
    audio.add_argument("operation", choices=("inspect", "trim"))
    audio.add_argument("source")
    audio.add_argument("--output")
    audio.add_argument("--start", type=int)
    audio.add_argument("--end", type=int)
    rename = commands.add_parser("rename", help="plan a content rename using a fresh authoritative graph")
    rename.add_argument("kind")
    rename.add_argument("old_id")
    rename.add_argument("new_id")
    rename.add_argument("--graph", required=True)
    package = commands.add_parser("package", help="assemble source + a supplied SDK and platform launcher")
    package.add_argument("output")
    package.add_argument("--sdk", required=True)
    package.add_argument("--platform", required=True, choices=("linux","macos","windows"))
    verify_package = commands.add_parser("verify-package", help="verify a platform package manifest and files")
    verify_package.add_argument("path")
    terrain = commands.add_parser("terrain", help="paint/erase v1 four-neighbor or v2 blob/transition candidates")
    terrain.add_argument("path")
    terrain.add_argument("--layer", required=True)
    terrain.add_argument("--cells", required=True)
    terrain.add_argument("--rules", required=True)
    terrain.add_argument("--terrain-id", help="selected material for v2 transition8 rules")
    terrain.add_argument("--change-set", action="store_true", help="emit guarded changes plus edit statistics")
    terrain.add_argument("--erase", action="store_true")
    terrain.add_argument("--seed", type=int, default=0)
    templates = commands.add_parser("template", help="expand database/object templates and report three-way instance conflicts")
    templates.add_argument("operation", choices=("expand", "update", "objects", "objects-update", "check"))
    templates.add_argument("source", help="expansion/update request JSON or generated report for check")
    templates.add_argument("--timeout", type=float, default=120)
    database = commands.add_parser("database", help="typed CSV database exchange without writing project content")
    database.add_argument("operation", choices=("export","import"))
    database.add_argument("kind")
    database.add_argument("--fields", nargs="+", help="JSON pointers for export")
    database.add_argument("--source", help="CSV source for import")
    preflight = commands.add_parser("preflight", help="run a fixed, fail-closed project readiness profile")
    preflight.add_argument("--profile", choices=("quick","release"), default="quick")
    preflight.add_argument("--profile-file", help="strict JSON profile; no shell commands")
    return parser


def _required(args, *names):
    for name in names:
        if getattr(args, name) is None:
            raise ValueError(f"--{name.replace('_', '-')} is required for {args.operation}")


def execute(args):
    from . import authoring
    from .assets import audit_assets
    from .build import build_bundle, verify_bundle

    root = Path(args.root).resolve()
    if args.tool == "template":
        from .templates import expand_template, plan_instances, update_instances, check_templates
        request = read_json(args.source)
        if args.operation == "objects":
            from .templates import instantiate_object_group
            if not isinstance(request,dict) or set(request)-{"mapPath","layer","template","instanceId","nameMap","worldOffset"} or not {"mapPath","layer","template","instanceId","nameMap"}<=set(request):
                raise ValueError("invalid object group request")
            return instantiate_object_group(root,request["mapPath"],request["layer"],request["template"],
                                            request["instanceId"],request["nameMap"],request.get("worldOffset",[0,0]))
        if args.operation == "check":
            from rpgc import find_engine
            if not isinstance(request,dict) or request.get("conflicts") or request.get("ok") is not True:
                raise ValueError("resolve all template update conflicts before candidate validation")
            return check_templates(find_engine(args.eve),root,request,args.timeout)
        if args.operation == "objects-update":
            from .templates import update_object_groups
            if (not isinstance(request,dict) or
                    set(request)-{"templates","instances","previousTemplates"} or
                    not {"templates","instances"}<=set(request) or
                    not isinstance(request["instances"],list)):
                raise ValueError("object group update requires templates, instances and optional previousTemplates")
            return update_object_groups(root,request["templates"],request["instances"],
                                        previous_templates=request.get("previousTemplates"))
        if not isinstance(request,dict) or set(request)!={"templates","instances"} or not isinstance(request["instances"],list):
            raise ValueError("template request requires exactly templates and instances")
        if args.operation == "update":
            return update_instances(root,request["templates"],request["instances"])
        instances=[]
        for row in request["instances"]:
            if not isinstance(row,dict) or set(row)-{"path","templateId","instanceId","parameters","overrides","references"} or not {"path","templateId","instanceId"}<=set(row):
                raise ValueError("invalid template expansion request")
            instance=expand_template(request["templates"],row["templateId"],row["instanceId"],
                                     row.get("parameters"),row.get("overrides"),row.get("references"))
            instance["path"]=row["path"]
            instance["sidecar"]["path"]=row["path"]
            instances.append(instance)
        return {"ok":True,"validated":False,"applied":False,"conflicts":[],"instances":instances,
                "changeSet":plan_instances(root,instances)}
    if args.tool == "database":
        from .database import export_csv, import_csv
        if args.operation == "export":
            _required(args,"fields")
            return export_csv(root,args.kind,args.fields)
        _required(args,"source")
        return import_csv(root,args.kind,Path(args.source).read_text(encoding="utf-8-sig"))
    if args.tool == "terrain":
        from .terrain import autotile_map
        document = read_json(inside(root,args.path))
        candidate = autotile_map(document,args.layer,read_json(args.cells),read_json(args.rules),
                                 args.erase,args.seed,args.terrain_id)
        if not args.change_set:
            return candidate
        from .authoring import _layer
        from .project import fingerprint
        old, new = _layer(document,args.layer)['data'], _layer(candidate,args.layer)['data']
        changed = [[i % document['width'], i // document['width']] for i,(a,b) in enumerate(zip(old,new)) if a!=b]
        bounds = None if not changed else {"minX":min(p[0] for p in changed),"minY":min(p[1] for p in changed),
                                           "maxX":max(p[0] for p in changed),"maxY":max(p[1] for p in changed)}
        return {"ok":True,"applied":False,"validated":False,"changedCells":len(changed),"bounds":bounds,
                "changeSet":{"format":"rpgc.change-set","version":1,"changes":[{
                    "path":args.path,"expect":fingerprint(document),"document":candidate}],"deletions":[]}}
    if args.tool == "preflight":
        from .pipeline import run_preflight, load_profile
        profile = load_profile(Path(args.profile_file)) if args.profile_file else args.profile
        binary = None
        if args.eve or args.profile_file or args.profile == "release":
            from rpgc import find_engine
            try:
                binary = find_engine(args.eve)
            except SystemExit:
                pass  # profile reports missing required SDK as a failed check
        return run_preflight(root,binary,profile)
    if args.tool == "package":
        from .packaging import package_project
        return package_project(root, Path(args.sdk), Path(args.output), args.platform)
    if args.tool == "verify-package":
        from .packaging import verify_package
        return verify_package(Path(args.path))
    if args.tool == "verify-bundle":
        return verify_bundle(Path(args.path))
    if args.tool == "bundle":
        return build_bundle(root, Path(args.output))
    if args.tool == "assets":
        return audit_assets(root)
    if args.tool == "story":
        from .narrative import compile_story
        return compile_story(read_json(args.source))
    if args.tool == "quest":
        from .narrative import compile_quest
        return compile_quest(read_json(args.source))
    if args.tool == "migrate-save":
        from .saves import migrate_inventory
        mapping = read_json(args.mapping)
        if not isinstance(mapping, dict) or set(mapping) - {"items", "slots"}:
            raise ValueError("mapping requires items/slots objects")
        return migrate_inventory(read_json(args.source), mapping.get("items"), mapping.get("slots"), args.expect)
    if args.tool == "import-animation":
        from .importers import animation_candidate
        return animation_candidate(Path(args.image), document_id=args.id,
            image_reference=args.image_reference, frame_width=args.frame_width,
            frame_height=args.frame_height, clips=read_json(args.clips),
            margin=args.margin, spacing=args.spacing, title=args.title)
    if args.tool == "audio":
        from .importers import inspect_wav, trim_wav
        if args.operation == "inspect":
            return inspect_wav(Path(args.source))
        _required(args, "output", "start", "end")
        return trim_wav(Path(args.source), Path(args.output), args.start, args.end, project_root=root)
    if args.tool == "rename":
        from .refactor import rename_changes
        return rename_changes(root, read_json(args.graph), args.kind, args.old_id, args.new_id)
    project = Project(root)
    if args.tool == "doctor":
        catalog = project.catalog()
        assets = audit_assets(root)
        return {"ok": assets["ok"], "engineValidated": False,
                "kinds": sorted(project.kinds), "documents": catalog["count"],
                "assets": assets, "next": "rpgc validate; rpgc selftest (requires eve)"}
    if args.tool == "catalog":
        return project.catalog(args.kind, args.query)
    if args.tool == "schema":
        return project.schema(args.kind)
    if args.tool == "balance":
        return encounter_report(project)
    document = read_json(inside(root, args.path))
    if args.tool == "clone":
        return authoring.clone_document(document, args.new_id, args.title)
    if args.tool == "patch":
        return patch_document(document, read_json(args.operations), args.expect)
    if args.tool == "map":
        if args.operation == "resize":
            _required(args, "width", "height")
            return authoring.resize_map(document, args.width, args.height, args.gid)
        _required(args, "layer")
        layer = args.layer
        if args.operation == "paint":
            _required(args, "cells")
            return authoring.paint_map(document, layer, read_json(args.cells), args.gid)
        _required(args, "x", "y")
        return authoring.fill_map(document, layer, args.x, args.y, args.gid)
    if args.tool == "event":
        if args.operation == "analyze":
            return authoring.analyze_event(document)
        _required(args, "index")
        if args.operation in ("insert", "replace"):
            _required(args, "step")
        if args.operation == "move":
            _required(args, "destination")
        step = read_json(args.step) if args.step else None
        return authoring.edit_event(document, args.operation, args.index, step, args.destination)
    if args.tool == "strings":
        if args.operation == "extract":
            sources = authoring.extract_strings(document)
            return {"sources": sources, "translations": dict(sources)}
        _required(args, "catalog")
        catalog = read_json(args.catalog)
        if not isinstance(catalog, dict) or not isinstance(catalog.get("sources"), dict) or not isinstance(catalog.get("translations"), dict):
            raise ValueError("translation catalog requires sources and translations objects")
        return authoring.apply_strings(document, catalog["translations"], catalog["sources"])
    raise ValueError(f"unknown tool: {args.tool}")


def run(args):
    try:
        result = execute(args)
        if args.tool == "database" and args.operation == "export":
            sys.stdout.write(result)
        else:
            print(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False))
        return 1 if isinstance(result, dict) and result.get("ok") is False else 0
    except (ValueError, OSError, KeyError, TypeError, csv.Error) as error:
        print(json.dumps({"ok": False, "diagnostics": [{"severity": "error",
              "code": "toolkit.failed", "path": getattr(args, "path", ""),
              "message": str(error)}]}, ensure_ascii=False), file=sys.stderr)
        return 1
