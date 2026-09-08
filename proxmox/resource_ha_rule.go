package proxmox

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"

	pxapi "github.com/Telmate/proxmox-api-go/proxmox"
	"github.com/hashicorp/terraform-plugin-sdk/v2/diag"
	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/schema"
	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/validation"
)

// HA rules are the Proxmox VE 9 replacement for HA groups.  Upgrading a
// cluster from 8 to 9 converts every group into a node-affinity rule, so this
// resource exists mainly to adopt what the upgrade produced -- see the import
// notes below, because the identifiers are not what you would guess.
//
// Implemented against the client's generic request helpers rather than a typed
// HA-rules API.  The client pinned here predates Proxmox 9 and has no such
// API, and bumping it would drag in twenty-one months of behaviour change
// across the whole provider, which is the thing this fork exists to avoid.
// The endpoint is five plain REST calls; the generic helpers are enough.

const haRulesPath = "/cluster/ha/rules"

const (
	haRuleTypeNodeAffinity     = "node-affinity"
	haRuleTypeResourceAffinity = "resource-affinity"
)

func resourceHaRule() *schema.Resource {
	return &schema.Resource{
		CreateContext: resourceHaRuleCreate,
		ReadContext:   resourceHaRuleRead,
		UpdateContext: resourceHaRuleUpdate,
		DeleteContext: resourceHaRuleDelete,
		Importer: &schema.ResourceImporter{
			// The id is the rule name.  After an 8 -> 9 upgrade that is a
			// generated identifier such as "ha-rule-6e12c05d-c269", not the
			// name of the group it came from -- the old group name survives
			// only in `comment`.  List the rules and match on the comment to
			// find what to import; the identifiers differ per cluster, so
			// they cannot be written in advance.
			StateContext: schema.ImportStatePassthroughContext,
		},

		Schema: map[string]*schema.Schema{
			"rule": {
				Type:        schema.TypeString,
				Required:    true,
				ForceNew:    true,
				Description: "Identifier of the rule. Renaming means replacing it.",
			},
			"type": {
				Type:     schema.TypeString,
				Required: true,
				ForceNew: true,
				ValidateFunc: validation.StringInSlice([]string{
					haRuleTypeNodeAffinity,
					haRuleTypeResourceAffinity,
				}, false),
				Description: "node-affinity or resource-affinity.",
			},
			"resources": {
				Type:        schema.TypeSet,
				Required:    true,
				Elem:        &schema.Schema{Type: schema.TypeString},
				Description: "Guests the rule applies to, as sid strings such as \"vm:601\". A set: the API returns them in its own order and that is not a change.",
			},
			"nodes": {
				Type:        schema.TypeMap,
				Optional:    true,
				Elem:        &schema.Schema{Type: schema.TypeInt},
				Description: "node-affinity only: node name to priority. Higher wins. A converted HA group keeps the priorities it had.",
			},
			"affinity": {
				Type:     schema.TypeString,
				Optional: true,
				Computed: true,
				ValidateFunc: validation.StringInSlice([]string{
					"positive", "negative",
				}, false),
				Description: "positive keeps the resources together, negative apart. Proxmox reports it on node-affinity rules too, so it is Computed rather than exclusive to resource-affinity.",
			},
			"strict": {
				Type:        schema.TypeBool,
				Optional:    true,
				Description: "node-affinity only: restrict the resources to the listed nodes rather than merely preferring them. Rules converted from non-restricted groups come back without it.",
			},
			"comment": {
				Type:        schema.TypeString,
				Optional:    true,
				Description: "Free text. After an 8 -> 9 upgrade this holds the name of the HA group the rule was converted from.",
			},
			"disable": {
				Type:     schema.TypeBool,
				Optional: true,
			},
			"order": {
				Type:        schema.TypeInt,
				Computed:    true,
				Description: "Evaluation order, assigned by Proxmox.",
			},
			"digest": {
				Type:        schema.TypeString,
				Computed:    true,
				Description: "Checksum of the whole rules configuration, used for optimistic locking. It is shared by every rule, not per rule.",
			},
		},
		Timeouts: resourceTimeouts(),
	}
}

// --- encoding helpers -------------------------------------------------------

// haRuleNodesToString renders {"a":1,"b":5} as "a:1,b:5", sorted so the same
// map always produces the same string.
func haRuleNodesToString(m map[string]interface{}) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s:%v", k, m[k]))
	}
	return strings.Join(parts, ",")
}

// haRuleNodesFromString parses "a:1,b:5" back to a map.  Proxmox accepts a
// bare node name, meaning the default priority, so tolerate a missing colon.
func haRuleNodesFromString(s string) map[string]interface{} {
	out := map[string]interface{}{}
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		name, prio, found := strings.Cut(part, ":")
		if !found {
			out[name] = 0
			continue
		}
		n, err := strconv.Atoi(strings.TrimSpace(prio))
		if err != nil {
			n = 0
		}
		out[strings.TrimSpace(name)] = n
	}
	return out
}

func haRuleParams(d *schema.ResourceData, includeRule bool) map[string]interface{} {
	params := map[string]interface{}{}
	if includeRule {
		params["rule"] = d.Get("rule").(string)
		params["type"] = d.Get("type").(string)
	}

	res := d.Get("resources").(*schema.Set).List()
	sids := make([]string, 0, len(res))
	for _, r := range res {
		sids = append(sids, r.(string))
	}
	sort.Strings(sids)
	params["resources"] = strings.Join(sids, ",")

	if v, ok := d.GetOk("nodes"); ok {
		if s := haRuleNodesToString(v.(map[string]interface{})); s != "" {
			params["nodes"] = s
		}
	}
	if v, ok := d.GetOk("affinity"); ok {
		params["affinity"] = v.(string)
	}
	if v, ok := d.GetOk("comment"); ok {
		params["comment"] = v.(string)
	}
	if d.Get("strict").(bool) {
		params["strict"] = 1
	}
	if d.Get("disable").(bool) {
		params["disable"] = 1
	}
	return params
}

// --- CRUD -------------------------------------------------------------------

func resourceHaRuleCreate(ctx context.Context, d *schema.ResourceData, meta interface{}) diag.Diagnostics {
	pconf := meta.(*providerConfiguration)
	lock := pmParallelBegin(pconf)
	defer lock.unlock()
	client := pconf.Client

	if err := haRuleRequirePVE9(client); err != nil {
		return diag.FromErr(err)
	}

	if err := client.Post(haRuleParams(d, true), haRulesPath); err != nil {
		return diag.FromErr(fmt.Errorf("creating HA rule %q: %w", d.Get("rule").(string), err))
	}
	d.SetId(d.Get("rule").(string))

	// Release before reading back.  pmParallelBegin is not re-entrant, and
	// resourceHaRuleRead takes the same lock -- holding it across the call
	// deadlocks until the test framework's timeout, with no error to show for
	// it.  unlock() is guarded by its own `locked` flag, so the deferred call
	// above is a harmless no-op after this.  Same shape as
	// resource_vm_qemu.go:911.
	lock.unlock()
	return resourceHaRuleRead(ctx, d, meta)
}

func resourceHaRuleRead(ctx context.Context, d *schema.ResourceData, meta interface{}) diag.Diagnostics {
	pconf := meta.(*providerConfiguration)
	lock := pmParallelBegin(pconf)
	defer lock.unlock()
	client := pconf.Client

	cfg, err := client.GetItemConfigMapStringInterface(
		haRulesPath+"/"+d.Id(), "ha rule", "config")
	if err != nil {
		// A rule that is gone is not an error: let Terraform plan to recreate
		// it rather than failing every subsequent command.
		if strings.Contains(strings.ToLower(err.Error()), "no such") ||
			strings.Contains(err.Error(), "404") {
			d.SetId("")
			return nil
		}
		return diag.FromErr(fmt.Errorf("reading HA rule %q: %w", d.Id(), err))
	}

	d.Set("rule", d.Id())
	if v, ok := cfg["type"].(string); ok {
		d.Set("type", v)
	}
	if v, ok := cfg["comment"].(string); ok {
		d.Set("comment", v)
	}
	if v, ok := cfg["affinity"].(string); ok {
		d.Set("affinity", v)
	}
	if v, ok := cfg["digest"].(string); ok {
		d.Set("digest", v)
	}
	if v, ok := cfg["resources"].(string); ok {
		parts := []string{}
		for _, p := range strings.Split(v, ",") {
			if p = strings.TrimSpace(p); p != "" {
				parts = append(parts, p)
			}
		}
		d.Set("resources", parts)
	}
	if v, ok := cfg["nodes"].(string); ok {
		d.Set("nodes", haRuleNodesFromString(v))
	}
	d.Set("strict", haRuleBool(cfg["strict"]))
	d.Set("disable", haRuleBool(cfg["disable"]))
	if v, ok := cfg["order"].(float64); ok {
		d.Set("order", int(v))
	}
	return nil
}

func resourceHaRuleUpdate(ctx context.Context, d *schema.ResourceData, meta interface{}) diag.Diagnostics {
	pconf := meta.(*providerConfiguration)
	lock := pmParallelBegin(pconf)
	defer lock.unlock()
	client := pconf.Client

	params := haRuleParams(d, false)
	// Optimistic locking: the digest covers the whole rules file, so passing
	// the one we last read makes Proxmox refuse the write if anything else
	// changed a rule in the meantime.
	if v, ok := d.GetOk("digest"); ok {
		params["digest"] = v.(string)
	}
	if err := client.Put(params, haRulesPath+"/"+d.Id()); err != nil {
		return diag.FromErr(fmt.Errorf("updating HA rule %q: %w", d.Id(), err))
	}
	lock.unlock() // see the note in resourceHaRuleCreate
	return resourceHaRuleRead(ctx, d, meta)
}

func resourceHaRuleDelete(ctx context.Context, d *schema.ResourceData, meta interface{}) diag.Diagnostics {
	pconf := meta.(*providerConfiguration)
	lock := pmParallelBegin(pconf)
	defer lock.unlock()

	if err := pconf.Client.Delete(haRulesPath + "/" + d.Id()); err != nil {
		return diag.FromErr(fmt.Errorf("deleting HA rule %q: %w", d.Id(), err))
	}
	d.SetId("")
	return nil
}

// haRuleBool copes with the API returning 0/1, "0"/"1" or a real bool.
func haRuleBool(v interface{}) bool {
	switch t := v.(type) {
	case bool:
		return t
	case float64:
		return t != 0
	case string:
		return t == "1" || strings.EqualFold(t, "true")
	}
	return false
}

// haRuleRequirePVE9 fails with something readable instead of letting a bare
// 501 from the API surface: this endpoint does not exist before Proxmox 9.
func haRuleRequirePVE9(client *pxapi.Client) error {
	v, err := client.GetVersion()
	if err != nil {
		return nil // version unavailable: let the API answer for itself
	}
	if v.Major < 9 {
		return fmt.Errorf(
			"proxmox_ha_rule requires Proxmox VE 9.0 or higher, this cluster reports %d.%d; use hagroup on the guest instead",
			v.Major, v.Minor)
	}
	return nil
}
