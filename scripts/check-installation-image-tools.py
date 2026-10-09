#!/usr/bin/env python3
"""Run installation-secret scripts in the exact candidate images before making release assets."""
import base64
import os
from pathlib import Path
import re
import subprocess
import tempfile
import yaml

ROOT = Path(__file__).resolve().parents[1]


def candidate(component):
    repo = os.environ[component.upper() + '_REPOSITORY']
    digest = os.environ[component.upper() + '_DIGEST']
    if not re.fullmatch(r'sha256:[a-f0-9]{64}', digest):
        raise ValueError('Candidate ' + component + ' needs a complete immutable digest')
    return repo + '@' + digest


def run():
    with tempfile.TemporaryDirectory(prefix='cda-image-tools-') as directory:
        scratch = Path(directory)
        sources = scratch / 'sources'
        sources.mkdir(mode=0o755)
        secret = base64.b64encode(b'K' * 32).decode('ascii')
        for name in ('kek', 'canary-capability'):
            file = sources / name
            file.write_text(secret)
            file.chmod(0o444)
        values = {'oidc': {'provider': 'auth0', 'appUrl': 'https://image-check.example',
                          'auth0': {'domain': 'image-check.auth0.com', 'clientId': 'image-check', 'audience': 'image-check'}}}
        for component in ('backend', 'frontend'):
            candidate(component)
            values[component] = {'image': {'repository': os.environ[component.upper() + '_REPOSITORY'],
                                         'digest': os.environ[component.upper() + '_DIGEST']}}
        overrides = scratch / 'values.yaml'
        overrides.write_text(yaml.safe_dump(values))
        rendered = subprocess.check_output(['helm', 'template', 'image-check', str(ROOT / 'chart/noves-canton-data-app'),
                                           '--values', str(overrides)], text=True)
        docs = [d for d in yaml.safe_load_all(rendered) if d]
        for component in ('backend', 'frontend'):
            deployment = next(d for d in docs if d.get('kind') == 'Deployment'
                              and d['metadata']['labels'].get('app.kubernetes.io/component') == component)
            spec = deployment['spec']['template']['spec']
            init = next(c for c in spec['initContainers'] if c['name'] == 'installation-secrets')
            uid = init.get('securityContext', {}).get('runAsUser', spec.get('securityContext', {}).get('runAsUser'))
            if not isinstance(uid, int) or uid == 0 or not init['image'].endswith('@' + os.environ[component.upper() + '_DIGEST']):
                raise ValueError('Unexpected candidate init image or runtime uid')
            image = candidate(component)
            script = init['command'][2]
            command = ['docker', 'run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL',
                       '--security-opt', 'no-new-privileges', '--user', str(uid),
                       '--volume', str(sources) + ':/installation-secret-sources:ro',
                       '--tmpfs', '/installation-secrets:rw,mode=0777', '--entrypoint', '/bin/sh', image, '-ec']
            subprocess.run(command + [script], check=True)
            # Fail-closed behavior also runs inside the actual image, not a substitute tool image.
            bad_sources = scratch / ('bad-' + component)
            bad_sources.mkdir(mode=0o755)
            for name in ('kek', 'canary-capability'):
                (bad_sources / name).write_text('invalid')
                (bad_sources / name).chmod(0o444)
            rejected = command.copy()
            rejected[rejected.index('--volume') + 1] = str(bad_sources) + ':/installation-secret-sources:ro'
            result = subprocess.run(rejected + [script], capture_output=True, text=True)
            if result.returncode == 0 or 'must be the base64 encoding of 32 bytes' not in result.stderr:
                raise ValueError(component + ' image did not reject malformed installation secrets')

        # Compose's root permission step needs chown/stat/cat as well as the Helm init tools.
        permission_script = subprocess.check_output(['bash', '-c',
            'source "$1/scripts/lib/installation-secrets.sh"; installation_secret_permission_script', 'image-check', str(ROOT)], text=True)
        seed = '\n'.join('printf %s ' + secret + ' > /state/' + name
                         for name in ('installation-kek', 'installation-canary-backend', 'installation-canary-frontend'))
        subprocess.run(['docker', 'run', '--rm', '--network', 'none', '--read-only', '--user', '0:0',
                        '--tmpfs', '/state:rw', '--entrypoint', '/bin/sh', candidate('backend'), '-ec',
                        seed + '\n' + permission_script], check=True)
    print('Candidate backend/frontend installation-secret image checks passed.')


if __name__ == '__main__':
    try:
        run()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit('Candidate installation-image verification failed; no release manifest was generated. '
                         'Check Docker, Helm, PyYAML and read access to the exact candidate digests. '
                         + (str(error) if isinstance(error, ValueError) else '')) from None
