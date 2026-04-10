import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import * as command from "@pulumi/command";

export interface DnsArgs {
    hProvider: hcloud.Provider;
    dns: {
        zoneName: string;
        tld: string;
        testSubdomain: string;
    };
    controlPlane: hcloud.Server;
    additionalCpNodes: hcloud.Server[];
}

export class DnsComponent extends pulumi.ComponentResource {
    public readonly dnsZoneId: pulumi.Output<string>;

    /** Build a DNS record name with the correct subdomain suffix for this zone. */
    public dnsRecordName(subdomain: string): string {
        return `${subdomain}${this._dnsSubdomainSuffix}`;
    }

    /** Delete a Hetzner DNS RRset before Pulumi creates/updates it (prevents "duplicate value" errors). */
    public cleanDnsRrset(
        pulumiName: string,
        name: pulumi.Input<string>,
        type: string,
    ): command.local.Command {
        return new command.local.Command(
            `clean-dns-${pulumiName}`,
            {
                create: pulumi.interpolate`hcloud dns rrset list ${this._dnsZoneName} --type ${type} -o noheader -o columns=name | grep -qx "${name}" && hcloud dns rrset delete ${this._dnsZoneName} ${name} ${type} || true`,
                triggers: [name],
            },
            { parent: this },
        );
    }

    private readonly _dnsSubdomainSuffix: string;
    private readonly _dnsZoneName: string;

    constructor(name: string, args: DnsArgs, opts?: pulumi.ComponentResourceOptions) {
        super("pxCloud:infra:Dns", name, {}, opts);

        const { hProvider, dns, controlPlane, additionalCpNodes } = args;
        const { zoneName: dnsZoneName, tld, testSubdomain } = dns;
        const wildcardName = testSubdomain ? `*.${testSubdomain}` : "*";

        this._dnsZoneName = dnsZoneName;

        const dnsZone = pulumi.output(
            hcloud.getZone({ name: dnsZoneName }, { provider: hProvider }),
        );
        this.dnsZoneId = dnsZone.apply((z) => String(z.id!));

        // When tld differs from dnsZoneName (e.g. "sub1.domain.tld" vs "domain.tld"),
        // record names inside the zone need the extra subdomain prefix appended.
        this._dnsSubdomainSuffix =
            tld === dnsZoneName ? "" : "." + tld.replace(`.${dnsZoneName}`, "");

        /////////////////////
        // Wildcard DNS
        /////////////////////

        const ipv4 = [controlPlane.ipv4Address, ...additionalCpNodes.map((n) => n.ipv4Address)];
        const ipv6 = [controlPlane.ipv6Address, ...additionalCpNodes.map((n) => n.ipv6Address)];

        ipv4.forEach(
            (ip, i) =>
                new hcloud.ZoneRecord(
                    `wildcard-a-${i}`,
                    {
                        zone: this.dnsZoneId,
                        name: wildcardName,
                        type: "A",
                        comment: `Pulumi-managed: wildcard for cluster services (cp${i})`,
                        value: ip,
                    },
                    { provider: hProvider, parent: this, deleteBeforeReplace: true },
                ),
        );

        ipv6.forEach(
            (ip, i) =>
                new hcloud.ZoneRecord(
                    `wildcard-aaaa-${i}`,
                    {
                        zone: this.dnsZoneId,
                        name: wildcardName,
                        type: "AAAA",
                        comment: `Pulumi-managed: wildcard for cluster services (cp${i})`,
                        value: ip,
                    },
                    { provider: hProvider, parent: this, deleteBeforeReplace: true },
                ),
        );

        this.registerOutputs({ dnsZoneId: this.dnsZoneId });
    }
}
