import importlib.util
import pathlib
import tempfile
import unittest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
bundle = load("bundle", "check-release-bundle.py")
images = load("images", "upgrade-compose-images.py")

class BundleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.inputs = {"RELEASE_VERSION": "4.1.4"}
        for i, kind in enumerate(images.KINDS):
            self.inputs[kind + "_REPOSITORY"] = f"ghcr.io/noves-inc/noves-canton-{kind.lower()}-v4"
            self.inputs[kind + "_DIGEST"] = "sha256:" + str(i + 1) * 64
        chart = {"version": "4.1.4", "appVersion": "4.1.4"}
        values, compose, env = {}, {"services": {}}, []
        for kind in images.KINDS:
            component = kind.lower()
            repo, digest = self.inputs[kind + "_REPOSITORY"], self.inputs[kind + "_DIGEST"]
            image = f"{repo}:4.1.4@{digest}"
            values[component] = {"image": {"repository": repo, "tag": "4.1.4", "digest": digest}}
            compose["services"][component] = {"image": "${" + kind + "_IMAGE:-" + image + "}"}
            env.append(kind + "_IMAGE=" + image)
        for name, data in zip(bundle.FILES, (chart, values, compose, "\n".join(env) + "\n")):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(data if isinstance(data, str) else yaml.safe_dump(data))

    def test_matching_bundle(self):
        bundle.check(self.root, self.inputs)

    def test_each_shipped_pin_and_version_is_checked(self):
        for name in bundle.FILES:
            with self.subTest(file=name):
                path = self.root / name
                original = path.read_text()
                path.write_text(original.replace("4.1.4", "4.1.3"))
                with self.assertRaises(ValueError):
                    bundle.check(self.root, self.inputs)
                path.write_text(original)
        for component in images.KINDS:
            with self.subTest(component=component):
                changed = dict(self.inputs, **{component + "_DIGEST": "sha256:" + "f" * 64})
                with self.assertRaises(ValueError):
                    bundle.check(self.root, changed)

    def test_upgrade_retains_secrets_and_other_config_and_private_backup(self):
        env = self.root / ".env"
        old = (self.root / bundle.FILES[3]).read_text().replace("4.1.4", "4.1.3") + "PASSWORD='a $literal'\n# kept comment\nAPP_URL=https://customer.example\n"
        env.write_text(old)
        images.upgrade(env, self.root / bundle.FILES[3])
        self.assertEqual(env.read_text(), old.replace("4.1.3", "4.1.4"))
        backup = list(self.root.glob(".env.pre-image-upgrade.*"))
        self.assertEqual(len(backup), 1)
        self.assertEqual(backup[0].read_text(), old)
        self.assertEqual(backup[0].stat().st_mode & 0o777, 0o600)
        images.upgrade(env, self.root / bundle.FILES[3])
        self.assertEqual(len(list(self.root.glob(".env.pre-image-upgrade.*"))), 1)

    def test_custom_and_duplicate_overrides_fail_without_change(self):
        for content in ("BACKEND_IMAGE=custom:tag\n", "BACKEND_IMAGE=one\nBACKEND_IMAGE=two\n"):
            env = self.root / ".env"
            env.write_text(content)
            with self.assertRaises(ValueError):
                images.upgrade(env, self.root / bundle.FILES[3])
            self.assertEqual(env.read_text(), content)
            self.assertFalse(list(self.root.glob(".env.pre-image-upgrade.*")))

    def test_missing_image_overrides_use_the_release_pins(self):
        env = self.root / ".env"
        env.write_text("DATABASE_PASSWORD=retained\n")
        images.upgrade(env, self.root / bundle.FILES[3])
        self.assertEqual(env.read_text(), "DATABASE_PASSWORD=retained\n" + (self.root / bundle.FILES[3]).read_text())

if __name__ == "__main__":
    unittest.main()
