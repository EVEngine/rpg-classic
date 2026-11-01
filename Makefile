# Standalone rpg-classic project. The engine lives in EVEngine/EVEngine.
EVE ?= eve
PYTHON ?= python

.PHONY: run tilemap skill event battle item mcp validate selftest export

run:
	$(EVE) run .

tilemap:
	$(EVE) run apps/tilemap

skill:
	$(EVE) run apps/skill

event:
	$(EVE) run apps/event

battle:
	$(EVE) run apps/battle

item:
	$(EVE) run apps/item

mcp:
	$(EVE) mcp --root .

validate:
	$(PYTHON) tools/rpgc.py validate

selftest:
	$(PYTHON) tools/rpgc.py selftest

export:
	$(PYTHON) tools/rpgc.py export

.PHONY: toolkit-test doctor validate-headless
toolkit-test:
	$(PYTHON) -m unittest discover -s tests -v

doctor:
	$(PYTHON) tools/rpgc.py toolkit doctor

validate-headless:
	$(PYTHON) tools/rpgc.py --eve $(EVE) validate --headless

.PHONY: selftest-headless check-assets
selftest-headless:
	$(PYTHON) tools/rpgc.py --eve $(EVE) selftest --headless

check-assets:
	$(PYTHON) tools/build_placeholder_anims.py --check
	$(PYTHON) tools/rpgc.py toolkit assets

.PHONY: preflight release-check
preflight:
	$(PYTHON) tools/rpgc.py toolkit preflight --profile quick

release-check:
	$(PYTHON) tools/rpgc.py --eve $(EVE) toolkit preflight --profile-file examples/toolkit/release.profile.json
