#!/usr/bin/env python3
"""Apply narrow HarmonyOS platform adaptation in an isolated, pinned module copy."""
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
go = sys.argv[1]
module = 'github.com/sagernet/sing-box'
source = Path(subprocess.check_output([go, 'list', '-m', '-f', '{{.Dir}}', module], cwd=root / 'core', text=True).strip())
target = root / 'core/generated/sing-box'
if target.exists():
    target.chmod(0o755)
    for directory in target.rglob('*'):
        if directory.is_dir():
            directory.chmod(0o755)
    shutil.rmtree(target)
shutil.copytree(source, target)
target.chmod(0o755)
for directory in target.rglob('*'):
    if directory.is_dir():
        directory.chmod(0o755)
path = target / 'experimental/libbox/service.go'
text = path.read_text()
old = '\toptions.Name, err = getTunnelName(tunFd)\n'
new = '''\t// HarmonyOS: the app verifies the real interface by assigned dual-stack addresses.
\tif named, ok := w.iif.(interface{ TunName() string }); ok && named.TunName() != "" {
\t\toptions.Name = named.TunName()
\t} else {
\t\toptions.Name, err = getTunnelName(tunFd)
\t}
'''
if text.count(old) != 1:
    raise SystemExit('sing-box TUN name patch anchor changed; refusing to patch')
path.chmod(0o644)
path.write_text(text.replace(old, new))
shutil.copyfile(root / 'core/go.mod', root / 'core/generated/ohos.mod')
shutil.copyfile(root / 'core/go.sum', root / 'core/generated/ohos.sum')
subprocess.run([go, 'mod', 'edit', '-modfile=generated/ohos.mod', '-replace', f'{module}=./generated/sing-box'], cwd=root / 'core', check=True)
print('Prepared isolated sing-box module with verified platform TUN name override.')

def copy_module(module_name: str, short_name: str) -> Path:
    module_source = Path(subprocess.check_output([go, 'list', '-m', '-f', '{{.Dir}}', module_name], cwd=root / 'core', text=True).strip())
    module_target = root / 'core/generated' / short_name
    if module_target.exists():
        module_target.chmod(0o755)
        for directory in module_target.rglob('*'):
            if directory.is_dir():
                directory.chmod(0o755)
        shutil.rmtree(module_target)
    shutil.copytree(module_source, module_target)
    module_target.chmod(0o755)
    for directory in module_target.rglob('*'):
        if directory.is_dir():
            directory.chmod(0o755)
    subprocess.run([go, 'mod', 'edit', '-modfile=generated/ohos.mod', '-replace', f'{module_name}=./generated/{short_name}'], cwd=root / 'core', check=True)
    return module_target

def patch(path: Path, old: str, new: str, count: int = 1) -> None:
    text = path.read_text()
    if text.count(old) != count:
        raise SystemExit(f'Patch anchor changed in {path.name}; refusing to patch')
    path.chmod(0o644)
    path.write_text(text.replace(old, new))

gvisor = copy_module('github.com/sagernet/gvisor', 'gvisor')
endpoint = gvisor / 'pkg/tcpip/link/fdbased/endpoint.go'
patch(endpoint, '\tPreConfigured bool\n', '''\tPreConfigured bool
\t// ForceNonSocket is only for an OS-authorized virtual NIC descriptor whose
\t// metadata access is restricted. Other descriptors retain IsSocketFD checks.
\tForceNonSocket bool
''')
patch(endpoint, '\t\tisSocket, err := IsSocketFD(fd)\n', '''\t\tvar isSocket bool
\t\tvar err error
\t\tif !opts.ForceNonSocket {
\t\t\tisSocket, err = IsSocketFD(fd)
\t\t}
''')
sing_tun = copy_module('github.com/sagernet/sing-tun', 'sing-tun')
patch(sing_tun / 'tun_linux_gvisor.go', '\t\t\tFDs:                  []int{t.tunFd},\n', '''\t\t\tFDs:                  []int{t.tunFd},
\t\t\tForceNonSocket:       true, // HarmonyOS VpnExtension virtual NIC only.
''', count=2)
print('Prepared scoped HarmonyOS TUN non-socket endpoint; ordinary socket probes unchanged.')

# Public NetConn binding already selects the authorized underlying network. Avoid
# an additional Linux SO_BINDTODEVICE pass, which is unavailable in the sandbox.
patch(target / 'common/dialer/default.go', '\treturn &DefaultDialer{\n', '''\t// HarmonyOS: the Control callback binds each socket to the selected NetConn ID.
\tnetworkStrategy = nil
\tdefaultNetworkStrategy = false
\treturn &DefaultDialer{
''')
