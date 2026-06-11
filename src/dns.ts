import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import * as command from "@pulumi/command";
import { project_settings } from "../project_settings";

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

    constructor(
        name: string,
        hProvider: hcloud.Provider,
        projectSettings: typeof project_settings,
        controlPlane: hcloud.Server,
        additionalCpNodes: hcloud.Server[],
        opts?: pulumi.ComponentResourceOptions,
    ) {
        super("pxCloud:infra:Dns", name, {}, opts);
        const wildcardName = projectSettings.dns.subdomain
            ? `*.${projectSettings.dns.subdomain}`
            : "*";

        this._dnsZoneName = projectSettings.dns.zoneName;

        const dnsZone = pulumi.output(
            hcloud.getZone({ name: projectSettings.dns.zoneName }, { provider: hProvider }),
        );
        this.dnsZoneId = dnsZone.apply((z) => String(z.id!));

        // When tld differs from dnsZoneName (e.g. "sub1.domain.tld" vs "domain.tld"),
        // record names inside the zone need the extra subdomain prefix appended.
        this._dnsSubdomainSuffix =
            projectSettings.dns.tld === projectSettings.dns.zoneName
                ? ""
                : "." + projectSettings.dns.tld.replace(`.${projectSettings.dns.zoneName}`, "");

        /////////////////////
        // Wildcard DNS
        /////////////////////

        const ipv4 = [controlPlane.ipv4Address, ...additionalCpNodes.map((n) => n.ipv4Address)];
        const ipv6 = [controlPlane.ipv6Address, ...additionalCpNodes.map((n) => n.ipv6Address)];

        // Clean any orphaned RRset before creating — prevents "duplicate value" errors
        // when a prior pulumi up created the record on Hetzner but timed out before
        // recording it in state (so the next run tries to create it again).
        const cleanA = this.cleanDnsRrset("wildcard-a", wildcardName, "A");
        const cleanAAAA = this.cleanDnsRrset("wildcard-aaaa", wildcardName, "AAAA");

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
                    {
                        provider: hProvider,
                        parent: this,
                        deleteBeforeReplace: true,
                        dependsOn: [cleanA],
                    },
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
                    {
                        provider: hProvider,
                        parent: this,
                        deleteBeforeReplace: true,
                        dependsOn: [cleanAAAA],
                    },
                ),
        );

        /////////////////////
        // SPF record
        /////////////////////

        const spfValue = projectSettings.mail.spfInclude
            ? `v=spf1 ${projectSettings.mail.spfInclude} ~all`
            : `v=spf1 a:${projectSettings.mail.smtpRelay} ~all`;

        new hcloud.ZoneRecord(
            "spf-txt",
            {
                zone: this.dnsZoneId,
                name: "@",
                type: "TXT",
                comment: "Pulumi-managed: SPF record for outbound mail relay",
                value: `"${spfValue}"`,
            },
            { provider: hProvider, parent: this, deleteBeforeReplace: true },
        );

        // SPF for the subdomain (e.g. myawesomecluster.cape-project.eu) — covers system
        // emails sent from noreply@<subdomain>.<zone> via the same relay.
        if (projectSettings.dns.subdomain) {
            new hcloud.ZoneRecord(
                "spf-txt-subdomain",
                {
                    zone: this.dnsZoneId,
                    name: projectSettings.dns.subdomain,
                    type: "TXT",
                    comment: `Pulumi-managed: SPF for ${projectSettings.dns.subdomain} mail relay`,
                    value: `"${spfValue}"`,
                },
                { provider: hProvider, parent: this, deleteBeforeReplace: true },
            );
        }

        this.registerOutputs({ dnsZoneId: this.dnsZoneId });
    }
}
