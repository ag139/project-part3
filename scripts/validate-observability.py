import json
import sys
import glob
import yaml

failed = 0

for f in sorted(glob.glob("observability/monitors/*.yaml") + glob.glob("observability/rules/*.yaml")):
    try:
        list(yaml.safe_load_all(open(f)))
        print("ok:", f)
    except Exception as e:
        print("INVALID:", f, e)
        failed = 1

for f in sorted(glob.glob("observability/dashboards/*.json")):
    try:
        d = json.load(open(f))
        assert d.get("title"), "no title"
        assert d.get("panels"), "no panels"
        print(f"ok: {f} ({len(d['panels'])} panels)")
    except Exception as e:
        print("INVALID:", f, e)
        failed = 1

sys.exit(failed)
