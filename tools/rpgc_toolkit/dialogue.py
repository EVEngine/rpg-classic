"""Scriptable dialogue preview using the same VM interpreter as the game."""
import json
from .runtime import run_headless


def preview_dialogue(binary, root, dialogue_id, actions=(), state=None, locale='zh-CN', timeout=120):
    if not isinstance(dialogue_id, str) or not dialogue_id or not isinstance(locale, str):
        raise ValueError('dialogue ID and locale must be strings')
    if not isinstance(actions, (list, tuple)) or len(actions) > 512:
        raise ValueError('actions must contain at most 512 commands')
    for action in actions:
        if not isinstance(action, dict) or action.get('kind') not in ('advance', 'choose', 'cancel', 'locale'):
            raise ValueError('unknown dialogue action')
        fields = {'kind', 'revision'}
        if action['kind'] == 'choose':
            fields.add('optionId')
            if not isinstance(action.get('optionId'), str):
                raise ValueError('choose requires optionId')
        if action['kind'] == 'locale':
            fields.add('locale')
            if not isinstance(action.get('locale'), str):
                raise ValueError('locale action requires locale')
        if set(action) - fields:
            raise ValueError('unknown action field')
        if 'revision' in action and (type(action['revision']) is not int or not 0 <= action['revision'] <= 16777215):
            raise ValueError('revision must be an exact nonnegative integer')
    if state is not None and not isinstance(state, dict):
        raise ValueError("state must be an object")
    payload = json.dumps({'id': dialogue_id, 'actions': actions, 'state': state or {}, 'locale': locale}, ensure_ascii=False, allow_nan=False)
    literal = json.dumps(payload, ensure_ascii=False)
    source = '''import { RpgcWorldState } from "game:/lib/rpgc_world_state.nut"
import { RpgcDialogue } from "game:/lib/rpgc_dialogue.nut"
function previewDialogue(input) {
    local loaded = RpgcProject.loadById("dialogue", input.id);
    if (!loaded.ok) return loaded;
    local gate = RpgcValidate.validateDocument("dialogue", loaded.value);
    if (!gate.ok) return gate;
    local made = RpgcWorldState.create(input.state);
    if (!made.ok) return made;
    local state = made.value;
    local started = RpgcDialogue.start(loaded.value, state, input.locale);
    if (!started.ok) return started;
    local session = started.value;
    local transcript = [];
    local domainEvents = RpgcDialogue.takeDomainEvents(session);
    local view = RpgcDialogue.view(session, state);
    if (!view.ok) return view;
    transcript.append(view.value);
    foreach (action in input.actions) {
        local revision = ("revision" in action) ? action.revision : view.value.revision;
        local result = 0;
        if (action.kind == "choose") result = RpgcDialogue.choose(session,state,action.optionId,revision);
        else if (action.kind == "advance") result = RpgcDialogue.advance(session,state,revision);
        else if (action.kind == "cancel") result = RpgcDialogue.cancel(session);
        else result = RpgcDialogue.view(session,state,action.locale);
        if (!result.ok) return {ok=false,diagnostics=result.diagnostics,state=state,transcript=transcript,status=session.status,domainEvents=domainEvents};
        domainEvents.extend(RpgcDialogue.takeDomainEvents(session));
        if (session.status == "cancelled") break;
        view = RpgcDialogue.view(session,state);
        if (!view.ok) return view;
        transcript.append(view.value);
    }
    return {ok=true,diagnostics=[],state=state,transcript=transcript,status=session.status,domainEvents=domainEvents};
}
RpgcToolkitResult <- RpgcJson.encodeCompact(previewDialogue(RpgcJson.parse(PAYLOAD).value));
'''.replace('PAYLOAD', literal)
    return run_headless(binary, root, source, timeout)
