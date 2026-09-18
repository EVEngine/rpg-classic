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
