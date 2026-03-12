# Host Provisioning in Slash

A complete Incus + ZFS host bootstrap system written in Slash, demonstrating
infrastructure scripting with `ok`, `unless`, `cmd`, and string lists.

This document is both a spec for the provisioning system and a worked example
of Slash replacing bash for real infrastructure automation.

---

## Why Slash

Infrastructure scripts in bash are 60% ceremony:

```bash
if ! incus info "${name}" >/dev/null 2>&1; then
    incus init "${image}" "${name}"
fi
```

In Slash, the same thing is:

```
unless ok incus info $name
    incus init $image $name
```

The `ok` builtin runs a command with stdout and stderr suppressed and returns
its exit code. Combined with `unless` (run body when condition fails) and
indentation blocks (no `fi`), idempotent checks become one-liners that read
as English.

Five Slash features make infrastructure scripting dramatically cleaner:

| Feature | Bash | Slash |
|---------|------|-------|
| Suppress output + check | `cmd >/dev/null 2>&1` | `ok cmd` |
| Idempotent guard | `if ! cmd >/dev/null 2>&1; then ... fi` | `unless ok cmd` |
| Local variables | `local x=1` (manual, easy to forget) | automatic in `cmd` |
| Export variables | `export FOO=bar` or `set -a; source; set +a` | `FOO = "bar"` (uppercase = exported) |
| Build command arrays | `arr=(); arr+=(...); "${arr[@]}"` | `args = [...]; args += [...]; run $args` |

---

## Architecture

```
host/
  config/
    host.env                  # site-specific variables (uppercase = auto-exported)
  scripts/
    apply-host.sl             # main runner — dispatches numbered scripts in order
    verify.sl                 # validates host + Incus + container state
    stamp-containers.sl       # runs all containers.d/*.sl
    create-gcp-host.sl        # GCP VM + disk creation (local machine)
    lib/
      ensure.sl               # idempotent helpers (ensure_instance, ensure_running, etc.)
      common.sl               # shared utilities (discover_containers, require_root, etc.)
    host.d/
      10-prereqs.sl           # apt packages + unattended-upgrades
      15-firewall.sl          # ufw + fail2ban
      20-zfs-layout.sl        # zpool + datasets
      30-users-groups.sl      # host users and groups
      35-incus-storage.sl     # storage pool validation
      40-apply-profiles.sl    # Incus profiles from YAML
      50-dataset-permissions.sl  # ownership and modes
      55-sshd-hardening.sl    # SSH drop-in config
    containers.d/
      10-foo.sl               # per-container desired state
      20-bar.sl
      35-baz.sl
    base/
      create-base.sl          # create/update base container
      clone-from-base.sl      # clone from stopped base
  incus/
    preseed.yaml.tmpl         # Incus preseed template
    profiles/
      trusted-privileged.yaml
      unprivileged-hardened.yaml
```

### Config loading

`host.env` contains uppercase variable assignments. In Slash, uppercase
variables are automatically exported to child processes — no `set -a` or
`export` ceremony. Scripts `source` the config file and all variables
become available to both the script and any commands it runs.

```
# config/host.env
ZFS_POOL = "tank"
ZFS_DEVICE = "/dev/sdb"
MOUNT_ROOT = "/tank"
INCUS_STORAGE_POOL = "default"
INCUS_DATASET = "incus/default"
HOME_DATASET_ROOT = "home"
SHARED_DATASET_ROOT = "shared"
SHARED_COMMON_DATASET = "shared/common"
BASE_CONTAINER_NAME = "base-2404"
BASE_CONTAINER_IMAGE = "images:ubuntu/24.04"
BASE_PROFILE = "trusted-privileged"
BASE_HOME_DATASET = "home/base"
USER_SHREEVE_UID = "1000"
USER_SHREEVE_GID = "1000"
USER_SHREEVE_NAME = "shreeve"
USER_TRUST_UID = "1001"
USER_TRUST_GID = "1001"
USER_TRUST_NAME = "trust"
GROUP_JAIL_GID = "1002"
GROUP_JAIL_NAME = "jail"
HARDEN_SSH = "false"
```

### Execution model

Every script is run with `slash scriptname.sl`. The `source` builtin loads
library files into the current shell context. `cmd` definitions from sourced
files are available to the sourcing script. `cmd` invocations get fresh local
scope — no variable leakage between helpers.

---

## Library: `lib/common.sl`

Shared utilities sourced by every script.

```
# lib/common.sl

ROOT_DIR = $(cd $(dirname $0)/.. && pwd)

cmd load_host_env
    if not test -f "$ROOT_DIR/config/host.env"
        echo "Missing config/host.env. Copy config/host.env.example and customize it." 2> /dev/null
        exit 1
    source "$ROOT_DIR/config/host.env"

cmd require_root
    if $EUID != 0
        echo "This script must run as root." 2> /dev/null
        exit 1

cmd have_cmd(name)
    ok type $name

cmd incus_is_initialized
    ok incus info

cmd discover_containers
    for script in "$ROOT_DIR/scripts/containers.d"/*.sl
        if test -f $script
            base = $(basename $script .sl)
            # strip leading number prefix: 10-foo -> foo
            echo ${base#*-}
```

---

## Library: `lib/ensure.sl`

Idempotent helpers. Every function follows the same pattern: check with
`ok`, act with `unless`.

```
# lib/ensure.sl

source "$ROOT_DIR/scripts/lib/common.sl"

cmd ensure_instance(name, image)
    unless ok incus info $name
        incus init $image $name

cmd ensure_running(name)
    unless ok incus list --format csv -c ns | grep -q "^$name,RUNNING$"
        incus start $name
    tries = 0
    until ok incus exec $name -- true
        sleep 1
        tries = $tries + 1
        if $tries >= 30
            echo "Container $name did not become ready in 30s" 2> /dev/null
            exit 1

cmd ensure_profile(name, profile)
    attached = $(incus config show $name 2> /dev/null | sed -n '/^profiles:/,/^[^ ]/{ s/^- //p }')
    unless echo $attached | grep -qx $profile
        incus profile add $name $profile

cmd ensure_disk(name, devname, source, path, readonly)
    readonly = $readonly ?? "false"
    cur_source = $(incus config device get $name $devname source 2> /dev/null) ?? ""
    cur_path = $(incus config device get $name $devname path 2> /dev/null) ?? ""
    cur_ro = $(incus config device get $name $devname readonly 2> /dev/null) ?? "false"
    if $cur_source == $source and $cur_path == $path and $cur_ro == $readonly
        return
    if $cur_source != ""
        incus config device remove $name $devname 2> /dev/null
    incus config device add $name $devname disk source=$source path=$path readonly=$readonly

cmd ensure_users(name)
    load_host_env
    unless ok incus list --format csv -c ns | grep -q "^$name,RUNNING$"
        echo "Container $name must be running before creating users." 2> /dev/null
        exit 1
    incus exec $name -- bash -lc """
        groupadd -g $USER_SHREEVE_GID $USER_SHREEVE_NAME || true
        id -u $USER_SHREEVE_NAME >/dev/null 2>&1 || useradd -m -u $USER_SHREEVE_UID -g $USER_SHREEVE_GID -s /bin/bash $USER_SHREEVE_NAME
        groupadd -g $USER_TRUST_GID $USER_TRUST_NAME || true
        id -u $USER_TRUST_NAME >/dev/null 2>&1 || useradd -m -u $USER_TRUST_UID -g $USER_TRUST_GID -s /bin/bash $USER_TRUST_NAME
        groupadd -g $GROUP_JAIL_GID $GROUP_JAIL_NAME || true
        usermod -aG $USER_TRUST_NAME $USER_SHREEVE_NAME || true
        """
```

---

## Main runner: `apply-host.sl`

```
# apply-host.sl

ROOT_DIR = $(cd $(dirname $0)/.. && pwd)
source "$ROOT_DIR/scripts/lib/common.sl"

require_root

# prevent concurrent runs
# TODO: flock equivalent in Slash (or use flock if available)

with_preseed = "false"
preseed_applied = "false"

for arg in $*
    try $arg
        "--with-preseed" { with_preseed = "true" }
        else
            echo "Unknown argument: $arg" 2> /dev/null
            echo "Usage: $0 [--with-preseed]" 2> /dev/null
            exit 1

for script in "$ROOT_DIR/scripts/host.d"/*.sl
    if not test -f $script { continue }
    base = $(basename $script)
    num = ${base%%-*}

    # skip non-numbered scripts
    unless echo $num | grep -qE '^[0-9]+$' { continue }

    if $with_preseed == "true" and $preseed_applied == "false" and $num >= 35
        echo "==> Rendering preseed"
        slash "$ROOT_DIR/scripts/render-preseed.sl"
        echo "==> Initializing Incus from preseed"
        slash "$ROOT_DIR/scripts/init-incus-preseed.sl"
        preseed_applied = "true"

    echo "==> Running $base"
    slash $script

echo "Host setup complete."
```

---

## Host scripts

### `10-prereqs.sl`

```
ROOT_DIR = $(cd $(dirname $0)/../.. && pwd)
source "$ROOT_DIR/scripts/lib/common.sl"

require_root
load_host_env

if have_cmd apt-get
    DEBIAN_FRONTEND = "noninteractive"
    apt-get update
    apt-get install -y zfsutils-linux incus uidmap acl gettext-base \
        openssh-server ripgrep fail2ban ufw unattended-upgrades
    dpkg-reconfigure -f noninteractive unattended-upgrades
else
    echo "Unsupported package manager." 2> /dev/null
    exit 1

echo "Prerequisites installed."
```

### `15-firewall.sl`

```
ROOT_DIR = $(cd $(dirname $0)/../.. && pwd)
source "$ROOT_DIR/scripts/lib/common.sl"

require_root

unless have_cmd ufw
    echo "ufw is not installed. Run 10-prereqs first." 2> /dev/null
    exit 1

ufw default deny incoming
ufw default allow outgoing
ufw allow ssh

unless ufw status | grep -q "Status: active"
    echo y | ufw enable

unless have_cmd fail2ban-client
    echo "fail2ban is not installed. Run 10-prereqs first." 2> /dev/null
    exit 1

unless test -f /etc/fail2ban/jail.local
    cat > /etc/fail2ban/jail.local '''
        [sshd]
        enabled  = true
        port     = ssh
        filter   = sshd
        maxretry = 5
        bantime  = 3600
        findtime = 600
        '''

systemctl enable --now fail2ban 2> /dev/null

echo "Firewall (ufw) and fail2ban configured."
```

### `20-zfs-layout.sl`

```
ROOT_DIR = $(cd $(dirname $0)/../.. && pwd)
source "$ROOT_DIR/scripts/lib/common.sl"

require_root
load_host_env

unless have_cmd zpool and have_cmd zfs
    echo "zfs tools are required. Run 10-prereqs first." 2> /dev/null
    exit 1

unless ok zpool list $ZFS_POOL
    unless test -b $ZFS_DEVICE
        echo "ZFS device $ZFS_DEVICE not found." 2> /dev/null
        exit 1
    if ok blkid $ZFS_DEVICE
        echo "ZFS device $ZFS_DEVICE already contains data (use wipefs to clear if intended)." 2> /dev/null
        exit 1
    zpool create -f -o ashift=12 $ZFS_POOL $ZFS_DEVICE

mkdir -p $MOUNT_ROOT
zfs set mountpoint=$MOUNT_ROOT $ZFS_POOL

# core datasets
for ds in $INCUS_DATASET $HOME_DATASET_ROOT $BASE_HOME_DATASET $SHARED_DATASET_ROOT $SHARED_COMMON_DATASET
    unless ok zfs list "$ZFS_POOL/$ds"
        zfs create "$ZFS_POOL/$ds"

# per-container home datasets
for cname in $(discover_containers)
    unless ok zfs list "$ZFS_POOL/$HOME_DATASET_ROOT/$cname"
        zfs create "$ZFS_POOL/$HOME_DATASET_ROOT/$cname"

zfs set compression=zstd $ZFS_POOL
zfs set atime=off $ZFS_POOL

echo "ZFS pool and datasets are ready."
```

### `30-users-groups.sl`

```
ROOT_DIR = $(cd $(dirname $0)/../.. && pwd)
source "$ROOT_DIR/scripts/lib/common.sl"

require_root
load_host_env

unless ok getent group $USER_SHREEVE_NAME
    groupadd -g $USER_SHREEVE_GID $USER_SHREEVE_NAME
unless ok id -u $USER_SHREEVE_NAME
    useradd -m -u $USER_SHREEVE_UID -g $USER_SHREEVE_GID -s /bin/bash $USER_SHREEVE_NAME

unless ok getent group $USER_TRUST_NAME
    groupadd -g $USER_TRUST_GID $USER_TRUST_NAME
unless ok id -u $USER_TRUST_NAME
    useradd -m -u $USER_TRUST_UID -g $USER_TRUST_GID -s /bin/bash $USER_TRUST_NAME

unless ok getent group $GROUP_JAIL_NAME
    groupadd -g $GROUP_JAIL_GID $GROUP_JAIL_NAME

echo "Host users/groups are ready."
```

### `35-incus-storage.sl`

```
ROOT_DIR = $(cd $(dirname $0)/../.. && pwd)
source "$ROOT_DIR/scripts/lib/common.sl"

require_root
load_host_env

unless have_cmd incus
    echo "incus CLI is missing. Run 10-prereqs first." 2> /dev/null
    exit 1

if have_cmd systemctl
    systemctl enable --now incus 2> /dev/null

unless incus_is_initialized
    echo "Incus is not initialized yet." 2> /dev/null
    echo "Run: slash scripts/apply-host.sl --with-preseed" 2> /dev/null
    exit 1

unless ok incus storage list --format csv -c n | grep -qx $INCUS_STORAGE_POOL
    echo "Incus storage pool '$INCUS_STORAGE_POOL' not found." 2> /dev/null
    echo "It should have been created by preseed. Re-run with --with-preseed." 2> /dev/null
    exit 1

pool_source = $(incus storage get $INCUS_STORAGE_POOL source 2> /dev/null) ?? ""
expected = "$ZFS_POOL/$INCUS_DATASET"

if $pool_source != $expected
    echo "Storage pool source mismatch: got '$pool_source', expected '$expected'." 2> /dev/null
    exit 1

echo "Incus storage pool $INCUS_STORAGE_POOL verified."
```

### `40-apply-profiles.sl`

```
ROOT_DIR = $(cd $(dirname $0)/../.. && pwd)
source "$ROOT_DIR/scripts/lib/common.sl"

require_root

unless incus_is_initialized
    echo "Incus is not initialized; cannot apply profiles." 2> /dev/null
    exit 1

for profile_file in "$ROOT_DIR/incus/profiles"/*.yaml
    if not test -f $profile_file { continue }
    profile_name = $(basename $profile_file .yaml)

    unless ok incus profile show $profile_name
        incus profile create $profile_name
    incus profile edit $profile_name < $profile_file
    echo "Profile $profile_name applied."
```

### `50-dataset-permissions.sl`

```
ROOT_DIR = $(cd $(dirname $0)/../.. && pwd)
source "$ROOT_DIR/scripts/lib/common.sl"

require_root
load_host_env

for cname in $(discover_containers)
    chown "$USER_SHREEVE_UID:$USER_SHREEVE_GID" "$MOUNT_ROOT/$HOME_DATASET_ROOT/$cname"

chown "$USER_SHREEVE_UID:$USER_SHREEVE_GID" "$MOUNT_ROOT/$BASE_HOME_DATASET"
chown "$USER_TRUST_UID:$USER_TRUST_GID" "$MOUNT_ROOT/$SHARED_COMMON_DATASET"
chmod 2775 "$MOUNT_ROOT/$SHARED_COMMON_DATASET"

echo "Dataset ownership and mode applied."
```

### `55-sshd-hardening.sl`

```
ROOT_DIR = $(cd $(dirname $0)/../.. && pwd)
source "$ROOT_DIR/scripts/lib/common.sl"

require_root
load_host_env

if $HARDEN_SSH != "true"
    echo "Skipping SSH hardening (HARDEN_SSH is not 'true' in host.env)."
    exit 0

mkdir -p /etc/ssh/sshd_config.d

unless test -f /etc/ssh/sshd_config.d/99-hardened.conf
    cat > /etc/ssh/sshd_config.d/99-hardened.conf '''
        PasswordAuthentication no
        PermitRootLogin prohibit-password
        PubkeyAuthentication yes
        '''
    echo "Wrote SSH hardening drop-in."

systemctl reload ssh 2> /dev/null or systemctl reload sshd 2> /dev/null

echo "SSH hardening applied."
```

---

## Container scripts

### `containers.d/10-foo.sl`

```
ROOT_DIR = $(cd $(dirname $0)/../.. && pwd)
source "$ROOT_DIR/scripts/lib/common.sl"
source "$ROOT_DIR/scripts/lib/ensure.sl"

require_root
load_host_env

name = "foo"
image = "images:ubuntu/24.04"

ensure_instance $name $image
ensure_profile  $name trusted-privileged
ensure_disk     $name home "$MOUNT_ROOT/$HOME_DATASET_ROOT/foo" /home
ensure_disk     $name shared "$MOUNT_ROOT/$SHARED_COMMON_DATASET" /shared
ensure_running  $name
ensure_users    $name

echo "Stamped $name."
```

### `containers.d/20-bar.sl`

Same structure, `name = "bar"`.

### `containers.d/35-baz.sl`

```
ROOT_DIR = $(cd $(dirname $0)/../.. && pwd)
source "$ROOT_DIR/scripts/lib/common.sl"
source "$ROOT_DIR/scripts/lib/ensure.sl"

require_root
load_host_env

name = "baz"
image = "images:ubuntu/24.04"

ensure_instance $name $image
ensure_profile  $name unprivileged-hardened
ensure_disk     $name home "$MOUNT_ROOT/$HOME_DATASET_ROOT/baz" /home
ensure_disk     $name shared "$MOUNT_ROOT/$SHARED_COMMON_DATASET" /shared true
ensure_running  $name
ensure_users    $name

echo "Stamped $name."
```

---

## Base container workflow

### `base/create-base.sl`

```
ROOT_DIR = $(cd $(dirname $0)/../.. && pwd)
source "$ROOT_DIR/scripts/lib/common.sl"
source "$ROOT_DIR/scripts/lib/ensure.sl"

require_root
load_host_env

unless incus_is_initialized
    echo "Incus is not initialized; run host bootstrap first." 2> /dev/null
    exit 1

ensure_instance $BASE_CONTAINER_NAME $BASE_CONTAINER_IMAGE
ensure_profile  $BASE_CONTAINER_NAME $BASE_PROFILE
ensure_disk     $BASE_CONTAINER_NAME home "$MOUNT_ROOT/$BASE_HOME_DATASET" /home
ensure_running  $BASE_CONTAINER_NAME

# wait for cloud-init before creating users
incus exec $BASE_CONTAINER_NAME -- bash -lc "cloud-init status --wait" 2> /dev/null

ensure_users $BASE_CONTAINER_NAME

incus exec $BASE_CONTAINER_NAME -- bash -lc "apt-get update && apt-get -y upgrade"

if ok incus list --format csv -c ns | grep -q "^$BASE_CONTAINER_NAME,RUNNING$"
    incus stop $BASE_CONTAINER_NAME

echo "Base container $BASE_CONTAINER_NAME is ready (stopped)."
```

### `base/clone-from-base.sl`

```
ROOT_DIR = $(cd $(dirname $0)/../.. && pwd)
source "$ROOT_DIR/scripts/lib/common.sl"
source "$ROOT_DIR/scripts/lib/ensure.sl"

require_root
load_host_env

if $# < 1
    echo "Usage: $0 <new-container-name> [profile]" 2> /dev/null
    exit 1

new_name = $1
profile = $2 ?? $BASE_PROFILE
new_dataset = "$ZFS_POOL/$HOME_DATASET_ROOT/$new_name"
new_home = "$MOUNT_ROOT/$HOME_DATASET_ROOT/$new_name"

unless incus_is_initialized
    echo "Incus is not initialized; run host bootstrap first." 2> /dev/null
    exit 1

unless ok incus info $BASE_CONTAINER_NAME
    echo "Base container $BASE_CONTAINER_NAME not found. Run scripts/base/create-base.sl first." 2> /dev/null
    exit 1

if ok incus list --format csv -c ns | grep -q "^$BASE_CONTAINER_NAME,RUNNING$"
    echo "Base container $BASE_CONTAINER_NAME is running. Stop it before cloning." 2> /dev/null
    exit 1

if ok incus info $new_name
    echo "Container $new_name already exists; skipping clone."
    exit 0

unless ok zfs list $new_dataset
    zfs create $new_dataset
chown "$USER_SHREEVE_UID:$USER_SHREEVE_GID" $new_home

incus copy $BASE_CONTAINER_NAME $new_name
ensure_profile $new_name $profile
ensure_disk    $new_name home $new_home /home
ensure_disk    $new_name shared "$MOUNT_ROOT/$SHARED_COMMON_DATASET" /shared
ensure_running $new_name
ensure_users   $new_name

echo "Cloned $new_name from $BASE_CONTAINER_NAME and started it."
```

---

## Verification: `verify.sl`

```
ROOT_DIR = $(cd $(dirname $0)/.. && pwd)
source "$ROOT_DIR/scripts/lib/common.sl"

require_root
load_host_env

pass_count = 0
warn_count = 0
fail_count = 0

cmd pass(msg)
    pass_count = $pass_count + 1
    echo "PASS: $msg"

cmd warn(msg)
    warn_count = $warn_count + 1
    echo "WARN: $msg"

cmd fail(msg)
    fail_count = $fail_count + 1
    echo "FAIL: $msg"

cmd check_cmd(name)
    if have_cmd $name { pass "command '$name' is available" }
    else              { fail "command '$name' is missing" }

cmd check_dataset(rel)
    full_ds = "$ZFS_POOL/$rel"
    full_path = "$MOUNT_ROOT/$rel"
    if ok zfs list $full_ds    { pass "dataset exists: $full_ds" }
    else                       { fail "dataset missing: $full_ds" }
    if test -d $full_path      { pass "mount path exists: $full_path" }
    else                       { fail "mount path missing: $full_path" }

cmd check_mount(container, dev, expected_source, expected_path)
    unless ok incus info $container
        warn "container '$container' not found (skipping mount check)"
        return
    cur_source = $(incus config device get $container $dev source 2> /dev/null) ?? ""
    cur_path = $(incus config device get $container $dev path 2> /dev/null) ?? ""
    if $cur_source == "" and $cur_path == ""
        fail "container '$container' missing device '$dev'"
        return
    if $cur_source == $expected_source { pass "container '$container' device '$dev' source ok" }
    else                               { fail "container '$container' device '$dev' source mismatch (got '$cur_source')" }
    if $cur_path == $expected_path     { pass "container '$container' device '$dev' path ok" }
    else                               { fail "container '$container' device '$dev' path mismatch (got '$cur_path')" }

# -- prerequisites --
echo "== Verify: prerequisites"
for cmd_name in zpool zfs incus rg ufw fail2ban-client
    check_cmd $cmd_name

# -- ZFS pool --
echo "== Verify: ZFS pool"
if ok zpool list $ZFS_POOL { pass "zpool exists: $ZFS_POOL" }
else                       { fail "zpool missing: $ZFS_POOL" }

# -- datasets --
echo "== Verify: required datasets"
check_dataset $INCUS_DATASET
check_dataset $HOME_DATASET_ROOT

for cname in $(discover_containers)
    check_dataset "$HOME_DATASET_ROOT/$cname"

check_dataset $BASE_HOME_DATASET
check_dataset $SHARED_DATASET_ROOT
check_dataset $SHARED_COMMON_DATASET

# -- Incus daemon and storage --
echo "== Verify: Incus daemon and storage"
if incus_is_initialized { pass "Incus is initialized" }
else                    { fail "Incus is not initialized" }

if ok incus storage list --format csv -c n | grep -x $INCUS_STORAGE_POOL
    pass "Incus storage pool exists: $INCUS_STORAGE_POOL"
else
    fail "Incus storage pool missing: $INCUS_STORAGE_POOL"

# -- profiles --
echo "== Verify: profiles"
for profile in trusted-privileged unprivileged-hardened
    if ok incus profile show $profile { pass "profile exists: $profile" }
    else                              { fail "profile missing: $profile" }

# -- host ownership --
echo "== Verify: host ownership model"
for cname in $(discover_containers)
    local_path = "$MOUNT_ROOT/$HOME_DATASET_ROOT/$cname"
    if test -d $local_path
        owner = $(stat -c "%u:%g" $local_path)
        if $owner == "$USER_SHREEVE_UID:$USER_SHREEVE_GID"
            pass "$cname home ownership is $USER_SHREEVE_UID:$USER_SHREEVE_GID"
        else
            warn "$cname home ownership differs from $USER_SHREEVE_UID:$USER_SHREEVE_GID"

shared_owner = $(stat -c "%u:%g" "$MOUNT_ROOT/$SHARED_COMMON_DATASET")
if $shared_owner == "$USER_TRUST_UID:$USER_TRUST_GID"
    pass "shared ownership is $USER_TRUST_UID:$USER_TRUST_GID"
else
    warn "shared ownership differs from $USER_TRUST_UID:$USER_TRUST_GID"

# -- stamped containers --
echo "== Verify: stamped containers"
for cname in $(discover_containers)
    unless ok incus info $cname
        warn "container not found: $cname"
        continue
    pass "container exists: $cname"

    if ok incus list --format csv -c ns | grep -q "^$cname,RUNNING$"
        pass "container running: $cname"
    else
        warn "container not running: $cname"

    check_mount $cname home "$MOUNT_ROOT/$HOME_DATASET_ROOT/$cname" /home
    check_mount $cname shared "$MOUNT_ROOT/$SHARED_COMMON_DATASET" /shared

# -- container security and limits --
echo "== Verify: container security and limits"
for cname in $(discover_containers)
    unless ok incus info $cname { continue }

    profiles = $(incus config show $cname 2> /dev/null | sed -n '/^profiles:/,/^[^ ]/{ s/^- //p }')

    if echo $profiles | grep -qx trusted-privileged
        priv = $(incus profile get trusted-privileged security.privileged 2> /dev/null) ?? ""
        if $priv == "true" { pass "container '$cname' has trusted-privileged profile (privileged)" }
        else               { fail "container '$cname' has trusted-privileged profile but security.privileged is not set" }

    has_mem = "false"
    for p in $profiles
        if ok incus profile get $p limits.memory
            has_mem = "true"
            break
    instance_mem = $(incus config get $cname limits.memory 2> /dev/null) ?? ""
    if $instance_mem != "" { has_mem = "true" }

    if $has_mem == "true" { pass "container '$cname' has a memory limit" }
    else                  { warn "container '$cname' has no memory limit" }

# -- base container --
echo "== Verify: base container workflow"
if ok incus info $BASE_CONTAINER_NAME
    pass "base container exists: $BASE_CONTAINER_NAME"
    check_mount $BASE_CONTAINER_NAME home "$MOUNT_ROOT/$BASE_HOME_DATASET" /home
else
    warn "base container not found: $BASE_CONTAINER_NAME"

# -- SSH hardening --
echo "== Verify: SSH hardening"
if have_cmd sshd
    if ok sshd -T | grep -q "^passwordauthentication no$"
        pass "SSH password auth disabled"
    else
        warn "SSH password auth may still be enabled"
    if ok sshd -T | grep -q "^permitrootlogin prohibit-password$"
        pass "SSH root login restricted to keys"
    else
        warn "SSH root login is not set to prohibit-password"
else
    warn "sshd not found, cannot verify SSH config"

# -- firewall --
echo "== Verify: firewall and fail2ban"
if have_cmd ufw
    if ufw status | grep -q "Status: active" { pass "ufw is active" }
    else                                      { fail "ufw is not active" }
else
    fail "ufw not installed"

if have_cmd fail2ban-client
    if ok fail2ban-client status sshd { pass "fail2ban sshd jail is running" }
    else                              { warn "fail2ban sshd jail is not running" }
else
    fail "fail2ban not installed"

# -- summary --
echo "== Verify summary"
echo "PASS=$pass_count WARN=$warn_count FAIL=$fail_count"

if $fail_count > 0 { exit 1 }
exit 0
```

---

## GCP host creation: `create-gcp-host.sl`

This runs on your local machine, not the host. Demonstrates string lists
for building gcloud commands and `ok` for idempotency.

```
cmd usage
    cat '''
        Usage:
          create-gcp-host.sl --project <project-id> --zone <zone>

        Optional:
          --name <instance-name>         (default: incus-host)
          --machine-type <type>          (default: n2-standard-8)
          --boot-disk-size <size>        (default: 200GB)
          --zfs-disk-size <size>         (default: 300GB)
          --network <network>            (default: default)
          --subnet <subnet>              (optional)
          --service-account <email>      (optional)
          --tags <csv>                   (default: incus-host)
          --yes                          (skip confirmation)
          --dry-run                      (print commands only)
          -h, --help
        '''

PROJECT_ID = ""
ZONE = ""
INSTANCE_NAME = "incus-host"
MACHINE_TYPE = "n2-standard-8"
BOOT_DISK_SIZE = "200GB"
ZFS_DISK_SIZE = "300GB"
NETWORK = "default"
SUBNET = ""
SERVICE_ACCOUNT = ""
TAGS = "incus-host"
dry_run = "false"
assume_yes = "false"

cmd run_cmd
    if $dry_run == "true"
        echo "$*"
    else
        $*

# parse arguments
while $# > 0
    try $1
        "--project"        { PROJECT_ID = $2;      shift; shift }
        "--zone"           { ZONE = $2;             shift; shift }
        "--name"           { INSTANCE_NAME = $2;    shift; shift }
        "--machine-type"   { MACHINE_TYPE = $2;     shift; shift }
        "--boot-disk-size" { BOOT_DISK_SIZE = $2;   shift; shift }
        "--zfs-disk-size"  { ZFS_DISK_SIZE = $2;    shift; shift }
        "--network"        { NETWORK = $2;          shift; shift }
        "--subnet"         { SUBNET = $2;           shift; shift }
        "--service-account" { SERVICE_ACCOUNT = $2; shift; shift }
        "--tags"           { TAGS = $2;             shift; shift }
        "--dry-run"        { dry_run = "true";      shift }
        "--yes"            { assume_yes = "true";   shift }
        "-h"               { usage; exit 0 }
        "--help"           { usage; exit 0 }
        else
            echo "Unknown argument: $1" 2> /dev/null
            usage 2> /dev/null
            exit 1

if $PROJECT_ID == "" or $ZONE == ""
    echo "Both --project and --zone are required." 2> /dev/null
    usage 2> /dev/null
    exit 1

if $dry_run == "false" and not have_cmd gcloud
    echo "gcloud CLI is required but was not found." 2> /dev/null
    exit 1

REGION = ${ZONE%-*}
ZFS_DISK_NAME = "$INSTANCE_NAME-zfs"
ZFS_DEVICE_BY_ID = "/dev/disk/by-id/google-$ZFS_DISK_NAME"

gcp = [--project $PROJECT_ID --zone $ZONE]

if $dry_run == "true"
    echo "==> Dry run mode: showing commands only"

# create VM
echo "==> Creating host VM: $INSTANCE_NAME"
if $dry_run == "false" and ok gcloud compute instances describe $INSTANCE_NAME $gcp
    echo "    Instance $INSTANCE_NAME already exists; skipping."
else
    args = [gcloud compute instances create $INSTANCE_NAME]
    args += [--machine-type $MACHINE_TYPE]
    args += [--image-family ubuntu-2404-lts --image-project ubuntu-os-cloud]
    args += [--boot-disk-size $BOOT_DISK_SIZE]
    args += [--enable-nested-virtualization]
    args += [--network $NETWORK --tags $TAGS]
    args += $gcp
    if $SUBNET != ""          { args += [--subnet $SUBNET] }
    if $SERVICE_ACCOUNT != "" { args += [--service-account $SERVICE_ACCOUNT] }
    run $args

# create ZFS disk
echo "==> Creating persistent ZFS disk: $ZFS_DISK_NAME"
if $dry_run == "false" and ok gcloud compute disks describe $ZFS_DISK_NAME $gcp
    echo "    Disk $ZFS_DISK_NAME already exists; skipping."
else
    run_cmd gcloud compute disks create $ZFS_DISK_NAME \
        --size $ZFS_DISK_SIZE --type pd-balanced $gcp

# attach disk
echo "==> Attaching disk to host"
if $dry_run == "false" and ok gcloud compute instances describe $INSTANCE_NAME $gcp \
     --format='value(disks[].source)' | grep -q $ZFS_DISK_NAME
    echo "    Disk $ZFS_DISK_NAME already attached; skipping."
else
    run_cmd gcloud compute instances attach-disk $INSTANCE_NAME \
        --disk $ZFS_DISK_NAME --device-name $ZFS_DISK_NAME $gcp

echo """

    Host creation complete.

    Next steps:
      1) SSH to host:
           gcloud compute ssh $INSTANCE_NAME

      2) On host, clone repo and configure:
           cp config/host.env.example config/host.env
           # Set ZFS_DEVICE="$ZFS_DEVICE_BY_ID"

      3) Run host bootstrap:
           slash scripts/apply-host.sl --with-preseed
           slash scripts/stamp-containers.sl
           slash scripts/verify.sl
    """
```

---

## What this demonstrates

### The `unless ok` pattern eliminates boilerplate

Every idempotent check in the system follows the same two-line shape:

```
unless ok <check-command>
    <fix-command>
```

No `>/dev/null 2>&1`. No `!`. No `then`/`fi`. No `set -e` workarounds.
The intent is the entire statement.

### `cmd` scoping prevents variable leakage

Every `ensure_*` helper, every `check_*` verification function, and every
utility command uses `cmd`. Variables assigned inside do not leak back. No
`local` keyword, no discipline required — the scope boundary is the `cmd`.

### String lists make command building safe

The GCP script builds `gcloud` arguments incrementally with `args += [...]`
and dispatches with `run $args`. No word splitting, no quoting accidents,
no `"${array[@]}"`. Each argument stays as a separate argv entry.

### Uppercase export means config is automatic

`host.env` contains uppercase assignments. After `source host.env`, every
variable is available to the script AND automatically exported to child
processes (like `incus exec`, `envsubst`, etc.). No `set -a` / `set +a`.
No `export`.

### Heredocs are clean

The `'''` literal heredoc with auto-dedenting replaces bash's `cat <<'EOF'`
with proper indentation. The closing delimiter's indentation sets the margin.
No `EOF` tokens floating at column zero.

---

## Line count comparison

| Component | Bash | Slash | Reduction |
|-----------|------|-------|-----------|
| lib/common + lib/ensure | 105 + 45 = 150 | ~80 | 47% |
| host.d/* (8 scripts) | ~200 | ~120 | 40% |
| containers.d/* (3 scripts) | ~70 | ~45 | 36% |
| base/* (2 scripts) | ~85 | ~55 | 35% |
| verify.sl | ~270 | ~160 | 41% |
| create-gcp-host.sl | ~267 | ~130 | 51% |
| apply-host.sl + stamp | ~75 | ~45 | 40% |
| **Total** | **~1,100** | **~635** | **~42%** |

The reduction is not from doing less. It is from Slash expressing the same
ideas without the ceremony that bash requires.
