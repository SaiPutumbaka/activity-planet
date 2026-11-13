# Activity Planet place files

These files are a derivative database of OpenStreetMap data, made available under the
[Open Database License 1.0](https://opendatacommons.org/licenses/odbl/1-0/) (ODbL).
Any rights in individual contents of the database are licensed under the
[Database Contents License](https://opendatacommons.org/licenses/dbcl/1-0/).

Data © OpenStreetMap contributors (https://www.openstreetmap.org/copyright).

Built by `scripts/places/build_place_files.py` in https://github.com/SaiPutumbaka/activity-planet.
Each tile file is `{"v", "tile", "rules_version", "license", "attribution", "cols", "rows"}`; a row is
`[osm_ref, lng, lat, kind, name, rule_ids, address, locality, hours, website, tags]`. No member data.
