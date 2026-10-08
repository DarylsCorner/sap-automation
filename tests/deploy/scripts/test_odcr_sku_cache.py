import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "deploy" / "scripts" / "odcr_management.sh"
PLAYBOOK = ROOT / "deploy" / "ansible" / "playbook_11_00_00_capacity_reservations.yaml"
SUB = "11111111-1111-1111-1111-111111111111"
RG = "LAC-SECE-SAP04-X00"
REGION = "swedencentral"
NOW = 1791486000

MOCK_AZ = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
import time

args = sys.argv[1:]
with open(os.environ["AZ_CALLS"], "a") as log:
    log.write(json.dumps(args) + "\n")
config = json.loads(Path(os.environ["AZ_FIXTURE"]).read_text())

def value(flag):
    return args[args.index(flag) + 1]

def emit(data):
    print(json.dumps(data))

if value("--subscription") != config["subscription"]:
    sys.exit("Wrong subscription")
if config.get("fail_command") and args[:len(config["fail_command"])] == config["fail_command"]:
    sys.exit("Azure lookup denied")
if args[:2] == ["vm", "list"]:
    if value("--resource-group") != config["resource_group"]:
        sys.exit("Wrong resource group")
    emit(config["vms"])
elif args[:2] == ["vm", "list-skus"]:
    if value("--location") != config["region"] or value("-o") != "json":
        sys.exit("Wrong SKU query")
    time.sleep(config.get("sku_delay", 0))
    if "raw_skus" in config:
        print(config["raw_skus"])
    else:
        emit(config["skus"])
elif args[:2] == ["group", "exists"]:
    print("true")
elif args[:4] == ["capacity", "reservation", "group", "list"]:
    emit(config.get("groups", {}).get(value("--resource-group"), []))
elif args[:4] == ["capacity", "reservation", "group", "show"]:
    print("")
elif args[:3] == ["capacity", "reservation", "list"]:
    emit(config.get("reservations", []))
elif args[:3] == ["capacity", "reservation", "show"]:
    emit(config["reservations"][0])
elif "create" in args or "update" in args:
    if "--location" in args and value("--location") != config["region"]:
        sys.exit("Wrong creation region")
else:
    sys.exit("Unexpected az call: " + repr(args))
'''


def sku(name="Standard_D4ds_v5", supported="True"):
    return {
        "name": name,
        "capabilities": [{"name": "CapacityReservationSupported", "value": supported}],
    }


def vm(name="x00app01", size="Standard_D4ds_v5"):
    return {
        "id": f"/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Compute/virtualMachines/{name}",
        "name": name, "location": REGION, "size": size, "zone": "2", "crg": None,
    }


class SkuCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        for name, content in (
            ("az", MOCK_AZ),
            ("date", '#!/bin/sh\nprintf "%s\\n" "$MOCK_NOW"\n'),
        ):
            tool = self.bin / name
            tool.write_text(content)
            tool.chmod(0o755)
        self.fixture_path = self.work / "fixture.json"
        self.calls_path = self.work / "calls.jsonl"
        self.cache_dir = self.work / "sku cache"
        self.cache_path = self.cache_dir / f"{SUB}-{REGION}.json"
        self.fixture = {
            "subscription": SUB, "resource_group": RG, "region": REGION,
            "vms": [vm(), vm("x00scs01"), vm("x00dhdb01", "Standard_E20ds_v4")],
            "skus": [sku(), sku("Standard_E20ds_v4")],
        }
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("ODCR_", "ANSIBLE_"))
        }
        self.env.update(
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
            AZ_FIXTURE=str(self.fixture_path), AZ_CALLS=str(self.calls_path),
            MOCK_NOW=str(NOW), ODCR_SKU_CACHE_DIR=str(self.cache_dir),
            HOME=str(self.work), XDG_CACHE_HOME=str(self.work / "xdg-cache"),
            ANSIBLE_NOCOLOR="1", ANSIBLE_LOCAL_TEMP=str(self.work / "ansible-temp"),
        )

    def calls(self, prefix=()):
        if not self.calls_path.exists():
            return []
        calls = [json.loads(line) for line in self.calls_path.read_text().splitlines()]
        return [call for call in calls if call[:len(prefix)] == list(prefix)]

    def reset_calls(self):
        self.calls_path.unlink(missing_ok=True)

    def assert_no_mutations(self):
        self.assertFalse([call for call in self.calls() if "create" in call or "update" in call])

    def run_script(self, action="plan", success=True):
        self.fixture_path.write_text(json.dumps(self.fixture))
        result = subprocess.run(
            ["bash", str(SCRIPT), action, self.fixture["resource_group"], self.fixture["subscription"]],
            env=self.env, text=True, capture_output=True, timeout=30,
        )
        output = result.stdout + result.stderr
        if success:
            self.assertEqual(result.returncode, 0, output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
            self.assertIn("ERROR:", output)
            self.assert_no_mutations()
        return output

    def seed_cache(self, age=0, **updates):
        self.cache_dir.mkdir(exist_ok=True)
        data = {
            "schema_version": 1, "subscription": SUB, "location": REGION,
            "fetched_at": NOW - age,
            "skus": {"standard_d4ds_v5": True, "standard_e20ds_v4": True},
        }
        data.update(updates)
        self.cache_path.write_text(json.dumps(data))

    def test_cold_then_warm_plan_reuses_cache_and_keeps_discovery_live(self):
        self.fixture["sku_delay"] = 0.5
        started = time.monotonic()
        cold = self.run_script()
        cold_seconds = time.monotonic() - started
        self.assertIn("Would associate: 3", cold)
        self.assertEqual(len(self.calls(("vm", "list-skus"))), 1)
        self.assertTrue(self.cache_path.exists())
        self.assertEqual(json.loads(self.cache_path.read_text())["fetched_at"], NOW)
        self.assert_no_mutations()
        self.reset_calls()
        self.fixture["vms"].append(vm("x00app02"))
        started = time.monotonic()
        warm = self.run_script()
        warm_seconds = time.monotonic() - started
        self.assertIn("Would associate: 4", warm)
        self.assertIn("local cache", warm)
        self.assertIn("age: 0s", warm)
        self.assertEqual(len(self.calls(("vm", "list-skus"))), 0)
        self.assertEqual(len(self.calls(("vm", "list"))), 1)
        self.assertTrue(self.calls(("capacity", "reservation", "group", "list")))
        self.assertTrue(self.calls(("capacity", "reservation", "list")))
        self.assert_no_mutations()
        print(f"\nMock timing (SKU call adds 0.5s): cold={cold_seconds:.3f}s warm={warm_seconds:.3f}s")

    def test_expiry_is_exactly_24_hours_and_future_timestamp_refreshes(self):
        for age, expected_calls in ((86399, 0), (86400, 1), (86401, 1), (-1, 1)):
            with self.subTest(age=age):
                self.seed_cache(age=age)
                self.reset_calls()
                self.run_script()
                self.assertEqual(len(self.calls(("vm", "list-skus"))), expected_calls)

    def test_force_refresh_replaces_fresh_support_decisions(self):
        self.seed_cache()
        self.env["ODCR_SKU_CACHE_REFRESH"] = "true"
        self.fixture["skus"][1] = sku("Standard_E20ds_v4", "False")
        output = self.run_script()
        self.assertEqual(len(self.calls(("vm", "list-skus"))), 1)
        self.assertIn("Not supported - SKU has no ODCR support: 1", output)
        self.assertFalse(json.loads(self.cache_path.read_text())["skus"]["standard_e20ds_v4"])

    def test_unknown_sku_refresh_rechecks_previously_supported_candidates(self):
        self.seed_cache(skus={"standard_d4ds_v5": True})
        self.fixture["skus"][0] = sku(supported="False")
        output = self.run_script()
        self.assertEqual(len(self.calls(("vm", "list-skus"))), 1)
        self.assertIn("Not supported - SKU has no ODCR support: 2", output)
        self.assertIn("Would associate: 1", output)

    def test_unknown_sku_refreshes_once_and_known_unsupported_does_not(self):
        self.seed_cache(skus={"standard_d4ds_v5": True})
        self.fixture["skus"][1] = sku("Standard_E20ds_v4", "False")
        output = self.run_script()
        self.assertEqual(len(self.calls(("vm", "list-skus"))), 1)
        self.assertIn("Not supported - SKU has no ODCR support: 1", output)
        self.reset_calls()
        self.run_script()
        self.assertEqual(len(self.calls(("vm", "list-skus"))), 0)

    def test_unknown_after_refresh_never_assumes_support(self):
        self.fixture["skus"] = [sku("Standard_Unrelated")]
        output = self.run_script()
        self.assertEqual(len(self.calls(("vm", "list-skus"))), 1)
        self.assertIn("Not supported - SKU has no ODCR support: 3", output)
        self.assertIn("Would associate: 0", output)

    def test_valid_all_unsupported_response_is_not_lookup_failure(self):
        self.fixture["skus"] = [sku(supported="False"), sku("Standard_E20ds_v4", "False")]
        output = self.run_script()
        self.assertIn("Not supported - SKU has no ODCR support: 3", output)

    def test_corrupt_or_wrong_scope_cache_refreshes(self):
        for updates in (
            {"schema_version": 0}, {"subscription": "wrong"}, {"location": "eastus"},
            {"skus": {"standard_d4ds_v5": "true"}}, {"skus": {}}, {"fetched_at": "yesterday"},
        ):
            with self.subTest(updates=updates):
                self.seed_cache(**updates)
                self.reset_calls()
                self.run_script()
                self.assertEqual(len(self.calls(("vm", "list-skus"))), 1)
        self.cache_path.write_text("not json")
        self.reset_calls()
        self.run_script()
        self.assertEqual(len(self.calls(("vm", "list-skus"))), 1)

    def test_required_refresh_failure_never_uses_stale_data_or_writes_azure(self):
        self.fixture["fail_command"] = ["vm", "list-skus"]
        self.env["ODCR_SHARE_SUBSCRIPTIONS"] = "22222222-2222-2222-2222-222222222222"
        for force, age in (("false", 86400), ("true", 0)):
            with self.subTest(force=force):
                self.reset_calls()
                self.seed_cache(age=age)
                previous = self.cache_path.read_bytes()
                self.env["ODCR_SKU_CACHE_REFRESH"] = force
                output = self.run_script("create", success=False)
                self.assertIn("Azure lookup denied", output)
                self.assertEqual(self.cache_path.read_bytes(), previous)
                self.assertEqual(list(self.cache_dir.iterdir()), [self.cache_path])

    def test_malformed_refresh_preserves_old_cache_and_stops(self):
        self.env["ODCR_SKU_CACHE_REFRESH"] = "true"
        for data in (
            "not-json", "", "[]", "null", "{}", '[{"name": "Standard_D4ds_v5"}]',
            json.dumps([sku(), sku()]),
            json.dumps([{"name": "Standard_D4ds_v5", "capabilities": None}]),
            json.dumps([sku(supported="maybe")]),
        ):
            with self.subTest(data=data):
                self.reset_calls()
                self.seed_cache()
                previous = self.cache_path.read_bytes()
                self.fixture["raw_skus"] = data
                self.run_script("create", success=False)
                self.assertEqual(self.cache_path.read_bytes(), previous)

    def test_cache_write_failure_stops_before_azure_changes(self):
        self.cache_dir.write_text("not a directory")
        self.run_script("create", success=False)

    def test_cache_is_scoped_by_subscription_and_region(self):
        self.seed_cache()
        self.fixture["subscription"] = "22222222-2222-2222-2222-222222222222"
        self.fixture["region"] = "eastus"
        for item in self.fixture["vms"]:
            item["location"] = "eastus"
        self.run_script()
        self.assertEqual(len(self.calls(("vm", "list-skus"))), 1)
        self.assertEqual(len(list(self.cache_dir.glob("*.json"))), 2)

    def test_info_never_loads_cache_even_when_refresh_requested(self):
        self.env["ODCR_SKU_CACHE_REFRESH"] = "true"
        self.run_script("info")
        self.assertEqual(self.calls(("vm", "list-skus")), [])
        self.assertFalse(self.cache_dir.exists())
        self.assert_no_mutations()

    def test_skipped_vms_do_not_require_cache_but_manual_refresh_still_works(self):
        self.fixture["vms"] = [vm("x00web01"), vm("unknown"), vm("x00app01")]
        self.fixture["vms"][-1]["crg"] = "/already/associated"
        self.run_script()
        self.assertFalse(self.cache_dir.exists())
        self.env["ODCR_SKU_CACHE_REFRESH"] = "true"
        self.run_script()
        self.assertEqual(len(self.calls(("vm", "list-skus"))), 1)

    def test_invalid_refresh_option_stops(self):
        self.env["ODCR_SKU_CACHE_REFRESH"] = "maybe"
        self.run_script("create", success=False)

    def test_default_cache_location_uses_xdg_cache_home(self):
        self.env.pop("ODCR_SKU_CACHE_DIR")
        self.run_script()
        self.assertTrue(
            (Path(self.env["XDG_CACHE_HOME"]) / "sdaf-odcr" / self.cache_path.name).exists()
        )

    def test_default_cache_location_falls_back_to_home(self):
        self.env.pop("ODCR_SKU_CACHE_DIR")
        self.env.pop("XDG_CACHE_HOME")
        self.run_script()
        self.assertTrue((self.work / ".cache" / "sdaf-odcr" / self.cache_path.name).exists())

    def test_missing_capability_is_cached_as_unsupported(self):
        self.fixture["skus"][1]["capabilities"] = []
        output = self.run_script()
        self.assertIn("Not supported - SKU has no ODCR support: 1", output)
        self.reset_calls()
        self.run_script()
        self.assertEqual(self.calls(("vm", "list-skus")), [])

    def test_constrained_vcpu_sku_names_and_case_are_supported(self):
        self.fixture["vms"] = [vm("x00dhdb01", "Standard_E64-16s_v4")]
        self.fixture["skus"] = [sku("STANDARD_E64-16S_V4", "true")]
        self.run_script()
        self.assertTrue(json.loads(self.cache_path.read_text())["skus"]["standard_e64-16s_v4"])
        self.reset_calls()
        output = self.run_script()
        self.assertIn("Would associate: 1", output)
        self.assertEqual(self.calls(("vm", "list-skus")), [])

    def test_cached_plan_preserves_x00_seven_vm_five_reservation_layout(self):
        self.seed_cache()
        self.fixture["vms"] = [
            vm("x00app01"), vm("x00app02"), vm("x00app03"), vm("x00app04"),
            vm("x00scs01"), vm("x00scs02"), vm("x00dhdb01", "Standard_E20ds_v4"),
        ]
        for index in (1, 3, 5):
            self.fixture["vms"][index]["zone"] = "3"
        output = self.run_script()
        self.assertIn("Would associate: 7", output)
        self.assertIn("Failed: 0", output)
        self.assertEqual(output.count("[plan] az capacity reservation create "), 5)
        self.assertIn("--capacity-reservation-name SECE-AZ02-Apps --sku Standard_D4ds_v5 --capacity 2", output)
        self.assertIn("--capacity-reservation-name SECE-AZ03-Apps --sku Standard_D4ds_v5 --capacity 2", output)
        for name in ("SECE-X00-AZ02-ACS", "SECE-X00-AZ03-ACS", "SECE-X00-AZ02-DB"):
            self.assertIn(f"--capacity-reservation-name {name}", output)
        self.assert_no_mutations()
        self.assertEqual(self.calls(("vm", "list-skus")), [])

    def test_live_vm_errors_are_not_hidden_by_sku_cache(self):
        self.seed_cache()
        for vms in ([], [vm(), {**vm("x00app02"), "location": "eastus"}]):
            with self.subTest(vms=vms):
                self.reset_calls()
                self.fixture["vms"] = vms
                self.run_script("create", success=False)
                self.assertEqual(self.calls(("vm", "list-skus")), [])
        self.fixture["vms"] = [vm()]
        self.fixture["fail_command"] = ["vm", "list"]
        self.run_script("create", success=False)

    def test_region_mismatch_still_stops_before_sku_lookup(self):
        self.fixture["groups"] = {
            RG: [{"name": "SECE-X00-CR", "location": "eastus", "zones": ["2"]}]
        }
        self.run_script("create", success=False)
        self.assertEqual(self.calls(("vm", "list-skus")), [])

    def test_cached_create_preserves_reservation_growth_and_role_placement(self):
        self.seed_cache()
        self.fixture["groups"] = {
            "LAC-SECE-CR": [{"name": "SECE-CR", "location": REGION, "zones": ["2"]}],
            RG: [{"name": "SECE-X00-CR", "location": REGION, "zones": ["2"]}],
        }
        self.fixture["reservations"] = [{
            "name": "SECE-AZ02-Apps", "sku": {"name": "Standard_D4ds_v5", "capacity": 1},
            "zones": ["2"], "virtualMachinesAssociated": [{"id": "/existing"}],
        }]
        self.run_script("create")
        self.assertEqual(self.calls(("vm", "list-skus")), [])
        updates = self.calls(("capacity", "reservation", "update"))
        self.assertTrue(updates)
        for call in updates:
            self.assertEqual(call[call.index("--capacity") + 1], "2")
        associations = self.calls(("vm", "update"))
        self.assertEqual(len(associations), 3)
        for call in associations:
            name = call[call.index("--name") + 1]
            group = call[call.index("--capacity-reservation-group") + 1]
            self.assertTrue(group.endswith("/SECE-CR" if "app" in name else "/SECE-X00-CR"))

    def run_playbook(self, action="plan", refresh=False):
        ansible = shutil.which("ansible-playbook")
        self.assertIsNotNone(ansible, "Ansible required for the ODCR integration test")
        inventory = self.work / "X00_hosts.yaml"
        inventory.write_text(
            f"all:\n  hosts:\n    x00app01:\n      resource_group_name: {RG}\n"
            f"      subscription_id: {SUB}\n"
        )
        self.env["ANSIBLE_INVENTORY"] = inventory.name
        self.env.pop("ODCR_SKU_CACHE_DIR", None)
        self.fixture_path.write_text(json.dumps(self.fixture))
        return subprocess.run(
            [ansible, str(PLAYBOOK), "-e", json.dumps({
                "_workspace_directory": str(self.work), "odcr_action": action,
                "odcr_sku_cache_directory": str(self.cache_dir), "odcr_sku_cache_refresh": refresh,
            })],
            cwd=self.work, env=self.env, capture_output=True, text=True, timeout=90,
        )

    def test_playbook_passes_cache_options_and_refreshes(self):
        self.seed_cache()
        result = self.run_playbook(refresh=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.calls(("vm", "list-skus"))), 1)
        self.assertIn("Would associate: 3", result.stdout)
        self.assertIn(str(self.cache_path), result.stdout)
        self.assertFalse((self.work / ".progress").exists())
        self.assert_no_mutations()

    def test_playbook_automatically_logs_each_action_without_overwriting(self):
        self.seed_cache()
        for action in ("plan", "create", "info", "plan"):
            with self.subTest(action=action):
                before = {
                    path: path.read_bytes() for path in (self.work / "logs" / "odcr").glob("*.log")
                }
                result = self.run_playbook(action)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                after = set((self.work / "logs" / "odcr").glob("*.log"))
                added = after - before.keys()
                self.assertEqual(len(added), 1)
                path = added.pop()
                self.assertRegex(path.name, rf"^odcr-{action}-\d{{8}}T\d{{6}}Z-.+\.log$")
                self.assertIn(str(path), result.stdout)
                log = path.read_text()
                self.assertIn(f"Operation: {action}", log)
                self.assertIn(f"Resource group: {RG}", log)
                self.assertIn(f"Subscription: {SUB}", log)
                self.assertIn("Exit code: 0", log)
                self.assertIn("Status: completed", log)
                self.assertIn("===== ODCR Management Script =====", log)
                self.assertIn("STDOUT:", log)
                self.assertIn("STDERR:", log)
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                for old_path, old_content in before.items():
                    self.assertEqual(old_path.read_bytes(), old_content)
        self.assertTrue((self.work / ".progress" / "odcr-management-done").exists())

    def test_playbook_logs_failed_create_and_does_not_mark_completion(self):
        self.fixture["fail_command"] = ["vm", "list"]
        result = self.run_playbook("create")
        self.assertNotEqual(result.returncode, 0)
        logs = list((self.work / "logs" / "odcr").glob("*.log"))
        self.assertEqual(len(logs), 1)
        self.assertIn(str(logs[0]), result.stdout)
        log = logs[0].read_text()
        self.assertIn("Exit code: 1", log)
        self.assertIn("Azure lookup denied", log)
        self.assertIn("ERROR: unable to list VMs", log)
        self.assertFalse((self.work / ".progress").exists())
        self.assert_no_mutations()

    def test_playbook_stops_before_script_if_log_directory_unavailable(self):
        (self.work / "logs").write_text("not a directory")
        result = self.run_playbook("create")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.work / ".progress").exists())


if __name__ == "__main__":
    unittest.main()
