# Disk health

Pithos reads SMART data for the host's physical disks and exposes it at
`GET /api/disks`, and through the `pithos_disk_health` MCP tool.

Requires `smartutils` (`smartctl`) on the host, and root — which the service
already runs as. Results are cached for `PITHOS_DISK_CACHE_TTL` seconds
(default 600) on the same stale-while-revalidate cache as the inventory, so a
slow `smartctl` never blocks a request.

## Fields

| Field | Meaning |
|---|---|
| `device`, `model`, `serial`, `kind` | Identity; `kind` is `nvme` or `sata` |
| `capacity_gb` | Capacity in GB |
| `power_on_hours` | Lifetime powered-on hours |
| `used_pct` | Percentage of rated life consumed — see caveat below |
| `drive_writes` | Lifetime writes expressed as full-capacity writes |
| `written_tb` | Lifetime host writes, TB |
| `reallocated` | Reallocated sector count (SATA); non-zero is worth attention |
| `spare_pct` | Available spare (NVMe) |
| `temp_c` | Current temperature |
| `healthy` | The drive's own SMART overall-health verdict |
| `wear_source` | Which attribute `used_pct` came from, or null |

## The wear caveat

NVMe drives report `percentage_used` in a standard field, so `used_pct` is
trustworthy there.

SATA drives are inconsistent. Vendors reuse attribute IDs for entirely
different things — ID 233 is `Media_Wearout_Indicator` on Intel drives but
`NAND_GiB_Written` on SanDisk, a byte counter that would decode as 0% wear
forever. Pithos therefore accepts a wear attribute only when its *name*
also looks like a life gauge, and reports `used_pct: null` rather than
guessing when no trustworthy attribute exists.

When `used_pct` is null, use `drive_writes` instead: compare it against the
model's rated endurance. A 120GB drive with 250 full-capacity writes has seen
about 30TB, against a typical consumer rating of 40TB — worth planning a
replacement even though SMART still says PASSED.

`healthy` is the drive's own verdict. It is a useful floor, not a ceiling:
consumer SSDs commonly report PASSED right up until they fail.
