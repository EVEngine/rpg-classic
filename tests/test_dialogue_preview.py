"""Preview adapter exercises actual dialogue rules and authoritative references."""
import os
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from rpgc_toolkit.dialogue import preview_dialogue


class PreviewInputTests(unittest.TestCase):
    def test_unknown_actions_rejected_before_engine(self):
        for actions in ([{'kind':'exec'}], [{'kind':'choose'}], [{'kind':'advance','revision':True}], [{'kind':'advance','script':'x'}]):
            with self.subTest(actions=actions), self.assertRaises(ValueError):
                preview_dialogue('missing',ROOT,'dialogue.toolkit-guide',actions)


@unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'), 'real SDK required')
class PreviewRuntimeTests(unittest.TestCase):
    def preview(self, actions, **kwargs):
        return preview_dialogue(os.environ['RPGC_TEST_EVE'], ROOT, 'dialogue.toolkit-guide', actions, **kwargs)

    def test_choice_transcript_and_world_commit(self):
        result = self.preview([{'kind':'advance'},{'kind':'choose','optionId':'accept'},{'kind':'advance'}], locale='en')
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['status'],'completed')
        self.assertEqual(result['state']['variables']['toolkit.guide.accepted'],1)
        self.assertEqual(len(result['domainEvents']),1)
        self.assertEqual(result['domainEvents'][0]['kind'],'set_variable')
        self.assertEqual([x['nodeId'] for x in result['transcript']],['greeting','offer','accepted','done'])
        self.assertEqual([x['id'] for x in result['transcript'][1]['options']],['accept','leave'])

    def test_hidden_and_stale_choices_fail_without_reward(self):
        for action in ({'kind':'choose','optionId':'recap'}, {'kind':'choose','optionId':'accept','revision':0}):
            result = self.preview([{'kind':'advance'},action])
            self.assertFalse(result['ok'],result)
            self.assertNotIn('toolkit.guide.accepted',result['state']['variables'])

    def test_cancel_does_not_apply_unselected_choice(self):
        result=self.preview([{'kind':'advance'},{'kind':'cancel'}])
        self.assertTrue(result['ok'],result)
        self.assertEqual(result['status'],'cancelled')
        self.assertEqual(result['state']['variables'],{})

@unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'), 'real SDK required')
class DialogueReferenceTests(unittest.TestCase):
    def test_deleting_referenced_dialogue_fails_isolated_gate(self):
        from rpgc_toolkit.changes import check_changes
        target=ROOT/'content/dialogues/story.village.elderOffer.json'
        before=target.read_bytes()
        result=check_changes(os.environ['RPGC_TEST_EVE'], ROOT,
            {'format':'rpgc.change-set','version':1,'deletions':[{'path':'content/dialogues/story.village.elderOffer.json'}]})
        self.assertFalse(result['ok'],result)
        self.assertTrue(any('story.village.elderOffer' in row.get('message','') for row in result['diagnostics']),result)
        self.assertEqual(target.read_bytes(),before)
