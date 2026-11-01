import csv
import contextlib
import os
from io import StringIO
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from rpgc_toolkit.database import export_csv,import_csv
from rpgc_toolkit.project import read_json
from rpgc_toolkit.changes import prepare_changes, check_changes
import rpgc


class DatabaseTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name); (self.root/'items').mkdir()
        (self.root/'workflow.json').write_text(json.dumps({'kinds':{'item':{'directory':'items'}}}))
        self.doc={'id':'a','schema':'test','version':1,'name':'药,"好"\n第二行','combat':{'attack':5},'flag':True,'nullable':None,'array':[1,2]}
        (self.root/'items/a.json').write_text(json.dumps(self.doc))

    def replace_cell(self,text,column,value):
        rows=list(csv.reader(StringIO(text))); rows[1][rows[0].index(column)]=value
        out=StringIO(); csv.writer(out).writerows(rows); return out.getvalue()

    def test_lossless_noop_and_typed_edit(self):
        fields=['/name','/combat/attack','/flag','/nullable','/missing']
        text=export_csv(self.root,'item',fields)
        plan=import_csv(self.root,'item',text)
        self.assertEqual(plan['changes'],[])
        self.assertEqual(prepare_changes(self.root,plan),[])
        text=self.replace_cell(text,'/combat/attack','12.5')
        text=self.replace_cell(text,'/missing','"new"')
        plan=import_csv(self.root,'item',text)
        after=plan['changes'][0]['document']
        self.assertEqual(after['combat']['attack'],12.5)
        self.assertEqual(after['missing'],'new')
        self.assertEqual(after['name'],self.doc['name'])
        self.assertEqual(after['flag'],True)
        self.assertEqual(read_json(self.root/'items/a.json'),self.doc)

    def test_stale_identity_and_duplicate_rows(self):
        text=export_csv(self.root,'item',['/name'])
        for column,value in [('_id','renamed'),('_fingerprint','stale'),('_path','../outside')]:
            with self.subTest(column=column),self.assertRaises(ValueError):
                import_csv(self.root,'item',self.replace_cell(text,column,value))
        rows=list(csv.reader(StringIO(text))); rows.append(rows[1]); out=StringIO(); csv.writer(out).writerows(rows)
        with self.assertRaises(ValueError): import_csv(self.root,'item',out.getvalue())

    def test_reserved_overlap_and_unsafe_values(self):
        for fields in [['/id'],['/schema'],['/combat','/combat/attack'],['/name','/name']]:
            with self.assertRaises(ValueError): export_csv(self.root,'item',fields)
        text=export_csv(self.root,'item',['/combat/attack'])
        for value in ('NaN','1e999','{"a":1,"a":2}','=SUM(A1:A5)'):
            with self.assertRaises(ValueError): import_csv(self.root,'item',self.replace_cell(text,'/combat/attack',value))

    def test_missing_array_positions_not_inserted(self):
        text=export_csv(self.root,'item',['/array/5'])
        with self.assertRaises(ValueError): import_csv(self.root,'item',self.replace_cell(text,'/array/5','4'))

    def test_cli_exports_raw_csv_and_reports_malformed_input(self):
        output=StringIO()
        with contextlib.redirect_stdout(output):
            status=rpgc.main(['--root',str(self.root),'toolkit','database','export','item','--fields','/name'])
        self.assertEqual(status,0)
        self.assertTrue(output.getvalue().startswith('_path,_id,_fingerprint,'))
        broken=self.root/'broken.csv'; broken.write_text('_path,_id,_fingerprint,/name\n"unterminated')
        errors=StringIO()
        with contextlib.redirect_stderr(errors):
            status=rpgc.main(['--root',str(self.root),'toolkit','database','import','item','--source',str(broken)])
        self.assertEqual(status,1)
        self.assertFalse(json.loads(errors.getvalue())['ok'])

    @unittest.skipUnless(os.environ.get('RPGC_TEST_EVE'),'requires authoritative project gate')
    def test_real_stat_edit_validates_as_isolated_change_set(self):
        text=export_csv(ROOT,'enemy',['/combat/attack'])
        rows=list(csv.reader(StringIO(text)))
        old=json.loads(rows[1][3]); rows[1][3]=json.dumps(old+1)
        output=StringIO(); csv.writer(output).writerows(rows)
        plan=import_csv(ROOT,'enemy',output.getvalue())
        self.assertEqual(len(plan['changes']),1)
        report=check_changes(os.environ['RPGC_TEST_EVE'],ROOT,plan)
        self.assertTrue(report['ok'],report.get('diagnostics'))
        self.assertFalse(report['applied'])
        self.assertEqual(read_json(ROOT/rows[1][0])['combat']['attack'],old)

if __name__=='__main__': unittest.main()
