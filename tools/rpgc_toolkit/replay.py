"""Record and replay real RpgcBattle commands without duplicating combat rules."""
from __future__ import annotations

from copy import deepcopy
import hashlib
import json

from .runtime import run_headless, simulation_source

SCHEMA = 'rpgc.battle-tape'


def _literal(value):
    return json.dumps(json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False),
                      ensure_ascii=False)


def validate_tape(tape, max_orders=512):
    if not isinstance(tape, dict) or tape.get('schema') != SCHEMA or type(tape.get('version')) is not int or tape['version'] != 1:
        raise ValueError('expected rpgc.battle-tape version 1')
    if set(tape) - {'schema', 'version', 'party', 'encounter', 'seed', 'orders', 'expected'}:
        raise ValueError('unknown tape fields')
    simulation_source(tape.get('party'), tape.get('encounter'), tape.get('seed'), 1, max_orders)
    orders = tape.get('orders')
    if not isinstance(orders, list) or len(orders) > max_orders:
        raise ValueError('orders must be an array within max_orders budget')
    for index, order in enumerate(orders):
        if not isinstance(order, dict) or set(order) != {'actor', 'skill', 'target'}:
            raise ValueError(f'order {index} requires exactly actor, skill, target')
        for key, value in order.items():
            if not isinstance(value, str) or any(ord(c) < 32 for c in value) or (key == 'actor' and not value):
                raise ValueError(f'order {index}: invalid {key}')
    expected = tape.get('expected')
    if expected is not None:
        if not isinstance(expected, dict) or set(expected) != {'fingerprint', 'steps'}:
            raise ValueError('expected requires fingerprint and steps')
        if not isinstance(expected['steps'], list) or len(expected['steps']) != len(orders):
            raise ValueError('expected steps must match order count')
        for value in [expected['fingerprint']] + expected['steps']:
            if not isinstance(value, str) or len(value) != 64 or any(c not in '0123456789abcdef' for c in value):
                raise ValueError('expected fingerprints must be SHA-256 hex strings')
    return deepcopy(tape)


# The VM owns turn progression, AI selection, readiness, targets, damage and RNG.
# Snapshot before settlement (which rolls drops and therefore consumes RNG).
_COMMON = '''local diagnostics = []; local rows = []; local recorded = [];
local initialEvents = []; local finalState = null; local reward = null; local success = true;
local snapshot = function(fight) {
    local report = RpgcJson.parse(RpgcBattle.reportJson(fight)).value;
    report.rng <- fight.rng; report.turnIndex <- fight.turnIndex;
    report.order <- fight.order; report.runtime <- [];
    foreach (u in fight.units) report.runtime.append({id=u.id, resources=u.resources,
        cooldowns=u.cooldowns, effects=u.effects, guarding=u.guarding, turns=u.turns, broken=u.broken});
    return RpgcJson.parse(RpgcJson.encodeCompact(report)).value;
};
local fail = function(code, message, index) {
    diagnostics.append({severity="error", code=code, path="/orders/" + index, message=message});
};
local config = RpgcBattle.loadProject(tape.party, tape.encounter, "");
if (!config.ok) {
    success = false; foreach (d in config.diagnostics) diagnostics.append(d);
} else {
    config.value.seed <- tape.seed;
    local made = RpgcBattle.newFight(config.value);
    if (!made.ok) {
        success = false; foreach (d in made.diagnostics) diagnostics.append(d);
    } else {
        local fight = made.value;
        initialEvents = RpgcBattle.takeEvents(fight);
        local count = recording ? budget : tape.orders.len();
        for (local i = 0; i < count; i += 1) {
            if (fight.outcome != "") {
                if (!recording) { success = false; fail("replay.extra-order", "order after battle ended", i); }
                break;
            }
            if (fight.pending == "") RpgcBattle.advanceTurn(fight);
            local actor = RpgcBattle.currentUnit(fight);
            if (actor == 0 || fight.pending == "" || actor.id != fight.pending) {
                success = false; fail("replay.no-actor", "no ally waiting for command", i); break;
            }
            local command = recording ? RpgcBattle.autoCommand(fight, actor) : tape.orders[i];
            if (recording) command.actor <- actor.id;
            if (command.actor != fight.pending) {
                success = false; fail("replay.actor", "command actor does not match pending ally", i); break;
            }
            if (command.skill == "") command.skill = "command.defend";
            local chosen = null;
            foreach (option in RpgcBattle.commandsFor(fight, actor)) {
                if (option.id == command.skill && option.ready && option.affordable) chosen = option;
            }
            if (chosen == null) {
                success = false; fail("replay.command", "skill is not currently available", i); break;
            }
            if (chosen.targetType != "self" && chosen.targetType != "enemyAll" &&
                chosen.targetType != "allyAll" && chosen.targetType != "anyAll") {
                local legal = false;
                foreach (target in RpgcBattle.targetsFor(fight, actor, chosen.targetType)) {
                    if (target.id == command.target) legal = true;
                }
                if (!legal) { success = false; fail("replay.target", "target is not available", i); break; }
            }
            local submitted = RpgcBattle.submitCommand(fight, command);
            if (!submitted.ok) {
                success = false; foreach (d in submitted.diagnostics) diagnostics.append(d); break;
            }
            recorded.append(command);
            rows.append({order=command, events=RpgcBattle.takeEvents(fight), state=snapshot(fight)});
        }
        if (success && (fight.outcome == "" || fight.outcome == "stalled")) {
            success = false;
            fail(recording ? "replay.budget" : "replay.incomplete", "battle did not reach a terminal outcome", recorded.len());
        }
        finalState = snapshot(fight);
        if (success) reward = RpgcBattle.settlement(fight);
    }
}
RpgcToolkitResult <- RpgcJson.encodeCompact({ok=success, validated=false, simulator="RpgcBattle",
    tape={schema="rpgc.battle-tape", version=1, party=tape.party, encounter=tape.encounter,
          seed=tape.seed, orders=recorded},
    initialEvents=initialEvents, steps=rows, final=finalState, settlement=reward, diagnostics=diagnostics});
'''


def recording_source(party, encounter, seed=1, max_orders=512):
    simulation_source(party, encounter, seed, 1, max_orders)
    tape = {'party': party, 'encounter': encounter, 'seed': seed, 'orders': []}
    return f'local tape = RpgcJson.parse({_literal(tape)}).value;\nlocal recording = true; local budget = {max_orders};\n' + _COMMON


def replay_source(tape, max_orders=512):
    tape = validate_tape(tape, max_orders)
    return f'local tape = RpgcJson.parse({_literal(tape)}).value;\nlocal recording = false; local budget = {max_orders};\n' + _COMMON


def _fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                    separators=(',', ':'), allow_nan=False).encode()).hexdigest()


def finish_report(report, expected=None):
    """Attach stable transcript/state hashes and compare optional recorded results."""
    report = deepcopy(report)
    step_hashes = [_fingerprint(row) for row in report['steps']]
    fingerprint = _fingerprint({'initialEvents': report['initialEvents'],
                                'final': report['final'], 'settlement': report['settlement']})
    report['fingerprint'] = fingerprint
    for row, digest in zip(report['steps'], step_hashes):
        row['fingerprint'] = digest
    report['matched'] = None
    if expected is not None:
        differences = [i for i in range(max(len(step_hashes), len(expected['steps'])))
                       if i >= len(step_hashes) or i >= len(expected['steps']) or step_hashes[i] != expected['steps'][i]]
        matched = fingerprint == expected['fingerprint'] and not differences
        report['matched'] = matched
        report['differences'] = differences
        if not matched:
            report['ok'] = False
            report['diagnostics'].append({'severity': 'error', 'code': 'replay.mismatch', 'path': '/expected',
                                          'message': 'recorded state or step transcript differs'})
    if report['ok']:
        report['tape']['expected'] = {'fingerprint': fingerprint, 'steps': step_hashes}
    return report


def record_battle(binary, root, party, encounter, seed=1, max_orders=512, timeout=120):
    return finish_report(run_headless(binary, root, recording_source(party, encounter, seed, max_orders), timeout))


def replay_battle(binary, root, tape, max_orders=512, timeout=120):
    checked = validate_tape(tape, max_orders)
    return finish_report(run_headless(binary, root, replay_source(checked, max_orders), timeout), checked.get('expected'))
