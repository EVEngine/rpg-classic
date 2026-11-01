"""Compile authoring graphs and guarded quest stages to existing event candidates.

No alternative event runner is introduced. Dialogue nodes retain external
references, whose playback remains the application's responsibility.
"""
from copy import deepcopy
import re
import json


def _id(value, label):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', value):
        raise ValueError(f'{label} must be a stable identifier')
    return value


def compile_story(graph):
    """Compile a finite DAG to one eve.rpgc.event; branches inline continuations.

    Nodes are {id,action,next?}, {id,condition,then,else}, or {id,end:true}.
    Cycles, dangling/unreachable nodes and exponential expansion are refused.
    The authoritative event gate must still check every generated action.
    """
    if not isinstance(graph, dict) or graph.get('format') != 'rpgc.story-graph' or type(graph.get('version')) is not int or graph.get('version') != 1:
        raise ValueError('expected rpgc.story-graph version 1')
    if set(graph) - {'format','version','id','title','entry','nodes','trigger','repeatable'}:
        raise ValueError('unknown story graph fields')
    identifier = _id(graph.get('id'), 'id')
    nodes = graph.get('nodes')
    if not isinstance(nodes, list) or not 1 <= len(nodes) <= 512:
        raise ValueError('story requires 1..512 nodes')
    by_id = {}
    for node in nodes:
        if not isinstance(node, dict):
            raise ValueError('story node must be an object')
        name = _id(node.get('id'), 'node id')
        if name in by_id:
            raise ValueError(f'duplicate node: {name}')
        modes = sum((key in node) for key in ('action', 'condition', 'end'))
        if modes != 1:
            raise ValueError(f'node {name} requires exactly one action, condition or end')
        allowed = ({'id','action','next'} if 'action' in node else
                   {'id','condition','then','else'} if 'condition' in node else {'id','end'})
        if set(node) - allowed:
            raise ValueError(f'unknown node fields: {name}')
        if 'action' in node and (not isinstance(node['action'], dict) or not isinstance(node['action'].get('kind'), str)):
            raise ValueError(f'invalid action: {name}')
        if 'action' in node and node['action']['kind'] in ('branch','parallel'):
            raise ValueError('story actions must be flat; use graph condition nodes for branching')
        if 'condition' in node and not isinstance(node['condition'], dict):
            raise ValueError(f'invalid condition: {name}')
        if 'end' in node and node['end'] is not True:
            raise ValueError('end must be true')
        by_id[name] = node
    entry = graph.get('entry')
    if entry not in by_id:
        raise ValueError('entry node is missing')
    colors, reached = {}, set()

    def children(node):
        if 'action' in node:
            return [node['next']] if 'next' in node else []
        if 'condition' in node:
            if 'then' not in node or 'else' not in node:
                raise ValueError(f'branch requires then and else: {node["id"]}')
            return [node['then'], node['else']]
        return []

    def visit(name):
        if not isinstance(name, str) or name not in by_id:
            raise ValueError(f'dangling story edge: {name}')
        if colors.get(name) == 1:
            raise ValueError(f'story cycle: {name}')
        if colors.get(name) == 2:
            return
        colors[name] = 1
        reached.add(name)
        for target in children(by_id[name]):
            visit(target)
        colors[name] = 2
    visit(entry)
    if reached != set(by_id):
        raise ValueError('unreachable story nodes: ' + ', '.join(sorted(set(by_id) - reached)))
    budget = 0

    def expand(name, depth):
        nonlocal budget
        node = by_id[name]
        if 'end' in node:
            return []
        budget += 1
        if budget > 512:
            raise ValueError('expanded story exceeds 512 steps')
        if 'action' in node:
            tail = expand(node['next'], depth) if 'next' in node else []
            return [deepcopy(node['action'])] + tail
        if depth >= 2:
            raise ValueError('story branch nesting exceeds the current event target')
        yes, no = expand(node['then'], depth + 1), expand(node['else'], depth + 1)
        if not yes:
            raise ValueError('compiled branch then must contain at least one step')
        return [{'kind':'branch', 'condition':deepcopy(node['condition']), 'then':yes, 'else':no}]
    steps = expand(entry, 1)
    if not steps:
        raise ValueError('story must produce at least one event step')
    result = {'schema':'eve.rpgc.event','version':1,'id':identifier,'steps':steps,
              'trigger':deepcopy(graph.get('trigger', {'kind':'manual'})),
              'repeatable':graph.get('repeatable', False)}
    if 'title' in graph:
        result['title'] = graph['title']
    return result


def compile_quest(document):
    """Compile linear, explicitly triggered stages guarded by one world variable.

    This adapts to set_variable/branch, not the separate engine Quest API.
    Each stage may advance once; applications dispatch the declared triggers.
    """
    if not isinstance(document, dict) or document.get('format') != 'rpgc.quest-plan' or type(document.get('version')) is not int or document.get('version') != 1:
        raise ValueError('expected rpgc.quest-plan version 1')
    if set(document) - {'format','version','id','title','stages'}:
        raise ValueError('unknown quest plan fields')
    identifier = _id(document.get('id'), 'quest id')
    stages = document.get('stages')
    if not isinstance(stages, list) or not 1 <= len(stages) <= 128:
        raise ValueError('quest requires 1..128 ordered stages')
    variable = f'quest.{identifier}.stage'
    events, used, triggers = [], set(), set()
    for index, stage in enumerate(stages):
        if not isinstance(stage, dict):
            raise ValueError('quest stage must be an object')
        if set(stage) - {'id','title','trigger','steps','condition'}:
            raise ValueError('unknown quest stage fields')
        name = _id(stage.get('id'), 'stage id')
        if name in used:
            raise ValueError(f'duplicate quest stage: {name}')
        used.add(name)
        actions = stage.get('steps')
        if not isinstance(actions, list) or not 1 <= len(actions) <= 510 or not all(isinstance(s,dict) and isinstance(s.get('kind'),str) for s in actions):
            raise ValueError('stage requires 1..510 action steps')
        if any(s['kind'] in ('branch','parallel') for s in actions):
            raise ValueError('quest stage actions must be flat for the current event target')
        if any(s['kind']=='set_variable' and s.get('name','').startswith(f'quest.{identifier}.') for s in actions):
            raise ValueError('quest progress namespace is reserved for the compiler')
        trigger = stage.get('trigger')
        if not isinstance(trigger, dict) or not isinstance(trigger.get('kind'), str):
            raise ValueError('each stage requires an explicit event trigger')
        trigger_fields = {'manual':set(), 'game_started':set(), 'map_entered':{'mapId'},
                          'portal_entered':{'mapId','targetMap'},
                          'object_interacted':{'mapId','objectName'}, 'quest_completed':{'questId'}}
        allowed = trigger_fields.get(trigger['kind'])
        if allowed is None or set(trigger)-({'kind'}|allowed):
            raise ValueError('quest trigger contains unknown or irrelevant fields')
        trigger_key = json.dumps(trigger,sort_keys=True,allow_nan=False)
        if trigger.get('kind') != 'manual' and trigger_key in triggers:
            raise ValueError('duplicate automatic stage trigger could advance multiple stages in one dispatch')
        triggers.add(trigger_key)
        steps = deepcopy(actions) + [{'kind':'set_variable','name':variable,'op':'set','value':index+1}]
        guard={'kind':'variable','name':variable,'compare':'eq','value':index}
        if 'condition' in stage:
            if not isinstance(stage['condition'],dict): raise ValueError('stage condition must be an object')
            # The current target allows only one container level. Compute AND
            # with a reset scratch counter and three sequential top-level branches.
            eligible=f'quest.{identifier}.{name}.eligible'
            if stage['condition'].get('name')==eligible:
                raise ValueError('condition cannot read compiler scratch state')
            add={'kind':'set_variable','name':eligible,'op':'add','value':1}
            event_steps=[{'kind':'set_variable','name':eligible,'op':'set','value':0},
                         {'kind':'branch','condition':guard,'then':[deepcopy(add)]},
                         {'kind':'branch','condition':deepcopy(stage['condition']),'then':[deepcopy(add)]},
                         {'kind':'branch','condition':{'kind':'variable','name':eligible,'compare':'eq','value':2},'then':steps}]
        else:
            event_steps=[{'kind':'branch','condition':guard,'then':steps}]
        event = {'schema':'eve.rpgc.event','version':1,'id':f'{identifier}.{name}',
                 'title':stage.get('title', name),'repeatable':True,'trigger':deepcopy(trigger),
                 'steps':event_steps}
        events.append(event)
    return {'format':'rpgc.quest-candidates','version':1,'id':identifier,
            'variable':variable,'initialValue':0,'completedValue':len(stages),
            'events':events,'validated':False}
