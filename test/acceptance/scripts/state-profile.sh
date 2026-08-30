#!/usr/bin/env bash
#
# state-profile.sh -- summarise how a real OpenTofu/Terraform state uses the
# Proxmox provider, so acceptance tests can be aimed at the schema that is
# actually in production rather than at the whole schema surface.
#
# Reads a state file (or `tofu state pull` output) and reports, for the
# proxmox_* resources only:
#
#   1. provider addresses and aliases    (inputs to `state replace-provider`)
#   2. resource type counts
#   3. which proxmox_vm_qemu attributes are set, and how often
#   4. value distributions for the scalar attributes
#   5. disks: controllers, slots, storages, per-disk settings
#   6. network: model, bridge, VLAN tag, firewall, mtu
#   7. smbios: which sub-fields are populated
#   8. outliers -- instances that differ from the fleet
#   9. proxmox_pool / proxmox_lxc details
#  10. coverage: attributes in use vs. attributes named by the test suite
#
# Secrets are never printed.  Identifying values (UUIDs, MACs, IPs, hostnames)
# are reported as set/unset unless --show-values is given.
#
# Usage:
#   state-profile.sh [--show-values] [--names] [STATE_FILE]
#
#   STATE_FILE   path to a state file.  "-" reads stdin.  If omitted, the
#                script runs `tofu state pull` in the current directory.
#
# Examples:
#   ./state-profile.sh ~/tmp/tofu-int.tfstate
#   ./state-profile.sh > profile.txt        # from a tofu working directory
#   tofu state pull | ./state-profile.sh -

set -euo pipefail

SHOW_VALUES=0
SHOW_NAMES=0
STATE_ARG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --show-values) SHOW_VALUES=1 ;;
        --names)       SHOW_NAMES=1 ;;
        -h|--help)     sed -n '2,30p' "$0" | sed 's/^# \?//'; exit 0 ;;
        -*)            echo "unknown option: $1" >&2; exit 2 ;;
        *)             STATE_ARG="$1" ;;
    esac
    shift
done

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

# --- load the state ---------------------------------------------------------

STATE_JSON=$(
    if [ -z "$STATE_ARG" ]; then
        command -v tofu >/dev/null 2>&1 || { echo "no STATE_FILE given and tofu not on PATH" >&2; exit 1; }
        tofu state pull
    elif [ "$STATE_ARG" = "-" ]; then
        cat
    else
        cat "$STATE_ARG"
    fi
)

echo "$STATE_JSON" | jq -e '.resources' >/dev/null 2>&1 \
    || { echo "not a state file: no .resources array (did you mean 'tofu show -json'?)" >&2; exit 1; }

# jq helpers shared by every query below.  PROXMOX selects the provider's own
# resources; everything else in the state (maas_*, etc.) is ignored.
read -r -d '' JQ_PREAMBLE <<'JQ_EOF' || true
def proxmox: .resources[] | select(.type | startswith("proxmox_"));
def vms: proxmox | select(.type == "proxmox_vm_qemu");
def insts: .instances[]?.attributes // empty;
def set_only($v): if ($v == null or $v == "") then "unset" else "set" end;
def pad($n): tostring | . + (" " * (($n - length) | if . < 0 then 0 else . end));
def tally: group_by(.) | map({k: .[0], n: length}) | sort_by(-.n);
def render: .[] | "  \(.n | pad(6)) \(.k)";
JQ_EOF

jqs() { echo "$STATE_JSON" | jq -r "$JQ_PREAMBLE $1"; }

hdr() { printf '\n%s\n%s\n' "$1" "$(printf '%*s' "${#1}" '' | tr ' ' '=')"; }
sub() { printf '\n-- %s\n' "$1"; }

# ============================================================================
hdr "1. Providers"
# ============================================================================
# The FROM/TO arguments for `tofu state replace-provider`.  Aliases share one
# address, so a single replace-provider run covers all of them.

sub "provider instances (address.alias)"
jqs '[proxmox | .provider] | unique | .[] | "  \(.)"'

sub "distinct addresses to rewrite"
jqs '[proxmox | .provider | capture("provider\\[\"(?<a>[^\"]+)\"\\]").a] | unique | .[] | "  \(.)"'

# ============================================================================
hdr "2. Resource inventory (proxmox_* only)"
# ============================================================================

sub "resources / instances by type"
jqs '[proxmox | {t: .type, i: (.instances | length)}]
     | group_by(.t) | map({k: "\(.[0].t)  (\(length) resources, \(map(.i) | add) instances)", n: (map(.i) | add)})
     | sort_by(-.n) | render'

sub "resources whose instance count != 1 (count / for_each in play)"
jqs '[proxmox | select((.instances | length) != 1) | "  \(.type).\(.name): \(.instances | length) instances"]
     | if length == 0 then "  (none)" else .[] end'

# ============================================================================
hdr "3. proxmox_vm_qemu -- attributes in use"
# ============================================================================
# Presence only.  Note that rc5 writes schema defaults into state, so a
# high count does not mean the attribute was configured deliberately;
# cross-reference section 4 for that.

sub "attributes set to a non-empty / non-zero / non-false value"
jqs '[vms | insts | to_entries[]
      | select(.value != null and .value != "" and .value != false
               and .value != 0 and .value != [] and .value != {})
      | .key] | tally | render'

sub "attributes present in state but always empty/zero/false"
jqs '[vms | insts | to_entries[]] as $e
     | ([$e[] | .key] | unique) as $all
     | ([$e[] | select(.value != null and .value != "" and .value != false
                       and .value != 0 and .value != [] and .value != {})
         | .key] | unique) as $used
     | ($all - $used) | if length == 0 then "  (none)" else .[] | "  \(.)" end'

# ============================================================================
hdr "4. proxmox_vm_qemu -- scalar value distributions"
# ============================================================================
# This is what separates a deliberate setting from a materialised default.

SCALARS="bios scsihw cpu_type cpu sockets cores vcpus numa memory balloon \
vm_state onboot startup protection tablet kvm agent agent_timeout hotplug \
qemu_os boot bootdisk machine pxe full_clone clone target_node pool \
automatic_reboot define_connection_info additional_wait clone_wait \
force_recreate_on_change_of tags hastate hagroup"

for k in $SCALARS; do
    out=$(jqs "[vms | insts | select(has(\"$k\")) | .[\"$k\"]
               | select(. != null) | tostring] | tally | render")
    [ -n "$out" ] && { sub "$k"; echo "$out"; }
done

# ============================================================================
hdr "5. proxmox_vm_qemu -- disks"
# ============================================================================
# rc5 has two mutually exclusive spellings: the legacy flat `disk` list and the
# structured `disks` block (disks[0].<controller>[0].<slot>[0].<kind>[0]).

sub "which spelling is in use"
jqs '[vms | insts | (if ((.disk // []) | length) > 0 then "disk (legacy flat list)" else empty end),
                    (if ((.disks // []) | length) > 0 then "disks (structured block)" else empty end)]
     | tally | render'

sub "controllers and slots"
jqs '[vms | insts | .disks[0]? // {} | to_entries[]
      | select(.value | type == "array" and length > 0)
      | .key as $ctl | .value[0] | to_entries[]
      | select(.value | type == "array" and length > 0)
      | "\($ctl)/\(.key)"] | tally | render'

sub "disk kind per slot (disk / cdrom / passthrough / cloudinit)"
jqs '[vms | insts | .disks[0]? // {} | to_entries[]
      | select(.value | type == "array" and length > 0)
      | .value[0] | to_entries[]
      | select(.value | type == "array" and length > 0)
      | .value[0] | to_entries[]
      | select(.value | type == "array" and length > 0) | .key]
     | tally | render'

sub "storages referenced, incl. unused_disk (these must exist in the test image)"
jqs '[vms | insts | [.. | objects | select(has("storage")) | .storage]
      | .[] | select(. != null and . != "")] | tally | render'

sub "disk settings actually used (leaf objects with a storage key)"
jqs '[vms | insts | .. | objects | select(has("storage") and has("size"))
      | to_entries[]
      | select(.value != null and .value != "" and .value != false and .value != 0)
      | select(.key | IN("storage", "size", "id", "disk_file", "file", "linked_disk_id") | not)
      | "\(.key)=\(.value|tostring)"] | tally | render'

sub "disk sizes"
jqs '[vms | insts | .. | objects | select(has("storage") and has("size")) | .size | tostring] | tally | render'

sub "unused_disk (leftover disks -- a sign of past disk churn)"
jqs '[vms | insts | select(((.unused_disk // []) | length) > 0)
      | "\(.name // "?"): \((.unused_disk | length)) unused"]
     | if length == 0 then "  (none)" else .[] | "  \(.)" end'

# ============================================================================
hdr "6. proxmox_vm_qemu -- network"
# ============================================================================

sub "per-NIC shape"
jqs "[vms | insts | .network[]? |
      \"model=\(.model|tostring) bridge=\(.bridge|tostring) tag=\(.tag|tostring) firewall=\(.firewall|tostring) mtu=\(.mtu|tostring) queues=\(.queues|tostring) rate=\(.rate|tostring) link_down=\(.link_down|tostring) macaddr=\(if $SHOW_VALUES == 1 then (.macaddr|tostring) else (if ((.macaddr // \"\") == \"\") then \"unset\" else \"set\" end) end)\"]
     | tally | render"

sub "NICs per VM"
jqs '[vms | insts | (.network // []) | length | tostring] | tally | render'

sub "distinct bridges (these must exist in the test image)"
jqs '[vms | insts | .network[]?.bridge | select(. != null and . != "")] | tally | render'

sub "VLAN tags in use"
jqs '[vms | insts | .network[]?.tag | select(. != null) | tostring] | tally | render'

# ============================================================================
hdr "7. proxmox_vm_qemu -- smbios"
# ============================================================================
# smbios and smbios.uuid are both Optional+Computed, which is the classic
# source of phantom diffs across a provider swap.

sub "sub-fields populated"
jqs '[vms | insts | .smbios[]? | to_entries[]
      | select(.value != null and .value != "") | .key] | tally | render'

sub "uuid uniqueness (a duplicate would be a real problem)"
jqs '[vms | insts | .smbios[]?.uuid | select(. != null and . != "")]
     | "  \(length) uuids, \(unique | length) distinct"'

if [ "$SHOW_VALUES" = 1 ]; then
    sub "smbios non-uuid values"
    jqs '[vms | insts | .smbios[]? | to_entries[]
          | select(.key != "uuid") | select(.value != null and .value != "")
          | "\(.key)=\(.value)"] | tally | render'
fi

# ============================================================================
hdr "8. Outliers"
# ============================================================================
# Instances that differ from the fleet.  These are the ones most likely to
# produce a non-empty plan after the provider swap, so they deserve a look
# before the migration rehearsal rather than during it.

sub "vmid == 0 or absent (should not happen post-create)"
jqs '[vms as $r | $r.instances[]? | select(((.attributes.vmid // 0) == 0))
      | "  \($r.type).\($r.name) index=\(.index_key // "-") vmid=\(.attributes.vmid // "absent")"]
     | if length == 0 then "  (none)" else .[] end'

sub "pxe not set (differs from the PXE fleet)"
jqs '[vms as $r | $r.instances[]? | select((.attributes.pxe // false) == false)
      | "  \($r.type).\($r.name) index=\(.index_key // "-") clone=\(.attributes.clone // "-")"]
     | if length == 0 then "  (none)" else .[] end'

sub "schema_version per resource type (all should be 0 at rc5)"
jqs '[proxmox | .instances[]? as $i | "\(.type) v\($i.schema_version // 0)"] | tally | render'

sub "instances with a non-empty dependency on another proxmox resource"
jqs '[proxmox | .instances[]?.dependencies[]? | select(startswith("proxmox_"))]
     | if length == 0 then "  (none)" else tally | render end'

# ============================================================================
hdr "9. Other proxmox resources"
# ============================================================================

for t in proxmox_pool proxmox_lxc proxmox_lxc_disk proxmox_cloud_init_disk proxmox_storage_iso; do
    n=$(jqs "[proxmox | select(.type == \"$t\") | .instances[]?] | length")
    [ "$n" = "0" ] && continue
    sub "$t ($n instances) -- attributes in use"
    jqs "[proxmox | select(.type == \"$t\") | insts | to_entries[]
          | select(.value != null and .value != \"\" and .value != false
                   and .value != 0 and .value != [] and .value != {})
          | .key] | tally | render"
done

# ============================================================================
hdr "10. Coverage against the acceptance suite"
# ============================================================================
# Approximate: greps the attribute names that appear in the test files'
# HCL config strings, and diffs them against what the state actually uses.
# It over-reports nothing and under-reports attributes only referenced
# indirectly, so treat a "not covered" line as a prompt, not a verdict.

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../proxmox" 2>/dev/null && pwd || true)"

if [ -n "$TEST_DIR" ] && ls "$TEST_DIR"/*_test.go >/dev/null 2>&1; then
    COVERED=$(grep -hoE '^[[:space:]]+[a-z_][a-z_0-9]*[[:space:]]*=' "$TEST_DIR"/*_test.go 2>/dev/null \
              | tr -d ' \t=' | sort -u)
    USED=$(jqs '[vms | insts | to_entries[]
                 | select(.value != null and .value != "" and .value != false
                          and .value != 0 and .value != [] and .value != {})
                 | .key] | unique | .[]' | sed 's/^ *//')
    # attributes that are read-only outputs, not things a config can set
    COMPUTED_ONLY="id reboot_required default_ipv4_address default_ipv6_address ssh_host ssh_port unused_disk linked_vmid"

    sub "in state, named by a test config"
    { echo "$USED" | while read -r a; do
        [ -z "$a" ] && continue
        if echo "$COVERED" | grep -qx "$a"; then echo "  $a"; fi
      done; } || true

    sub "in state, NOT named by any test config"
    { echo "$USED" | while read -r a; do
        [ -z "$a" ] && continue
        if echo "$COVERED" | grep -qx "$a"; then continue; fi
        case " $COMPUTED_ONLY " in *" $a "*) continue ;; esac
        echo "  $a"
      done; } || true
else
    echo "  (proxmox/*_test.go not found -- run this from inside the provider repo)"
fi

hdr "Notes"
cat <<'NOTE_EOF'
  * Secrets are never printed.  Re-run with --show-values to include MACs,
    SMBIOS strings and other identifying values; check the output before
    sharing it.
  * Section 3 counts presence.  rc5 materialises schema defaults into state
    (tablet/kvm=true, vm_state=running, cpu_type=host, scsihw=lsi,
    bios=seabios, hotplug=network,disk,usb, clone_wait=10, full_clone=true),
    so use section 4 to tell a real setting from a default.
  * Sections 5 and 6 list the storages and bridges the fixtures must provide.
NOTE_EOF
