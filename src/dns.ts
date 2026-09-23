/**
 * Project: edgecloudinfra
 * File: dns.ts
 * Purpose: DNS component wiring for Pulumi.
 *
 * Author: Martin Kaiser
 * Copyright (c) 2026 Martin Kaiser
 * License: MIT
 * SPDX-License-Identifier: MIT
 */

import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import * as command from "@pulumi/command";
import { project_settings } from "../project_settings";
import type { ClusterNode } from "./nodes-k3s-types";

export class DnsComponent extends pulumi.ComponentResource {
    /** Delete a Hetzner DNS RRset before Pulumi creates/updates it (prevents "duplicate value" errors). */
    public cleanDnsRrset(
        pulumiName: string,
        name: pulumi.Input<string>,
        type: string,
        hcloudToken: pulumi.Input<string>,
    ): command.local.Command {
        return new command.local.Command(
            `clean-dns-${pulumiName}`,
            {
                // ${name} MUST stay quoted: the command runs through /bin/sh -c in the Pulumi
                // project dir, and in bare-domain mode the record name is the single character
                // `*` — unquoted it globs to the repo's file list.
                create: pulumi.interpolate`hcloud dns rrset list ${this._dnsZoneName} --type ${type} -o noheader -o columns=name | grep -qx "${name}" && hcloud dns rrset delete ${this._dnsZoneName} '${name}' ${type} || true`,
                environment: { HCLOUD_TOKEN: hcloudToken },
                triggers: [name],
            },
            { parent: this },
        );
    }

    /** Create a DNS RRset via the hcloud CLI (@pulumi/hcloud v1 has no RRset resource). */
    private createDnsRrset(
        pulumiName: string,
        zoneName: string,
        name: pulumi.Input<string>,
        type: string,
        values: pulumi.Input<string>[],
        hcloudToken: pulumi.Input<string>,
        dependsOn?: pulumi.Resource[],
    ): command.local.Command {
        // Build --record flags for each value
        const recordFlags = pulumi
            .all(values)
            .apply((vals) => vals.map((v) => `--record ${v}`).join(" "));
        return new command.local.Command(
            `dns-rrset-${pulumiName}`,
            {
                // ${name} MUST stay quoted (bare `*` in bare-domain mode would glob against the
                // Pulumi project dir); ${recordFlags} must NOT be — it is several argv words.
                create: pulumi.interpolate`hcloud dns rrset create --name '${name}' --type ${type} ${recordFlags} ${zoneName}`,
                // On destroy, delete the RRset
                delete: pulumi.interpolate`hcloud dns rrset delete ${zoneName} '${name}' ${type} || true`,
                environment: { HCLOUD_TOKEN: hcloudToken },
                triggers: [...values, name],
            },
            { parent: this, dependsOn },
        );
    }

    /**
     * Ensure a DNS RRset the cluster SHARES rather than owns.
     *
     * The apex `@` SPF is the case this exists for: the zone (`mydomain.tld`) also carries the
     * project website and its real mail, whose SPF is the same value the cluster wants. So the
     * cluster must publish it if it is missing, must not fight whatever is already there, and
     * must NEVER delete it on teardown — `make destroy` dropping the apex SPF breaks outbound
     * mail for a domain the cluster does not own.
     *
     * Hence: create is idempotent and non-destructive (skip when a record already exists), and
     * there is no `delete`. Contrast createDnsRrset, which owns its record and deletes it.
     */
    private ensureSharedDnsRrset(
        pulumiName: string,
        zoneName: string,
        name: pulumi.Input<string>,
        type: string,
        values: pulumi.Input<string>[],
        hcloudToken: pulumi.Input<string>,
    ): command.local.Command {
        const recordFlags = pulumi
            .all(values)
            .apply((vals) => vals.map((v) => `--record ${v}`).join(" "));
        return new command.local.Command(
            `dns-rrset-${pulumiName}`,
            {
                // ${name} MUST stay quoted (bare `*`/`@` would glob against the Pulumi project
                // dir); ${recordFlags} must NOT be — it is several argv words.
                create: pulumi.interpolate`if hcloud dns rrset list ${zoneName} --type ${type} -o noheader -o columns=name | grep -qx '${name}'; then echo "rrset ${name} ${type} already present in ${zoneName} — left as is (shared record)"; else hcloud dns rrset create --name '${name}' --type ${type} ${recordFlags} ${zoneName}; fi`,
                // No `delete`, and no `triggers`: a value change must not re-run create either,
                // because re-running it on a populated zone is a no-op by design.
                environment: { HCLOUD_TOKEN: hcloudToken },
            },
            // retainOnDelete belts-and-braces the absent `delete`: even if this resource is
            // ever replaced or removed from the program, Pulumi must not try to unpublish a
            // record the cluster does not own.
            { parent: this, retainOnDelete: true },
        );
    }

    private readonly _dnsZoneName: string;

    constructor(
        name: string,
        hProvider: hcloud.Provider,
        projectSettings: typeof project_settings,
        controlPlane: ClusterNode,
        additionalCpNodes: ClusterNode[],
        opts?: pulumi.ComponentResourceOptions,
    ) {
        super("ecc:infra:Dns", name, {}, opts);
        // Bare-domain mode (empty subdomain) puts the wildcard at the zone apex: `*`, which
        // then answers for every unclaimed name in the zone.
        const wildcardName = projectSettings.general.subdomain
            ? `*.${projectSettings.general.subdomain}`
            : "*";

        this._dnsZoneName = projectSettings.general.domain;

        /////////////////////
        // Wildcard DNS
        /////////////////////

        const ipv4 = [controlPlane.ipv4Address, ...additionalCpNodes.map((n) => n.ipv4Address)];
        // Only emit AAAA for nodes that actually have a public IPv6. A robot node without
        // publicIpv6 reports hasIpv6:false → skipped (an empty AAAA value is rejected by the
        // Hetzner DNS API). hcloud.Server has no hasIpv6 field (undefined) → kept (always
        // has an IPv6). NB: this filters statically, so the AAAA record count is stable.
        const ipv6 = [controlPlane, ...additionalCpNodes]
            .filter((n) => n.hasIpv6 !== false)
            .map((n) => n.ipv6Address);

        // Clean any orphaned RRset before creating — prevents "duplicate value" errors
        // when a prior pulumi up created the record on Hetzner but timed out before
        // recording it in state (so the next run tries to create it again).
        const token = projectSettings.hetzner.hcloudToken;
        const cleanA = this.cleanDnsRrset("wildcard-a", wildcardName, "A", token);
        const cleanAAAA = this.cleanDnsRrset("wildcard-aaaa", wildcardName, "AAAA", token);

        this.createDnsRrset("wildcard-a", this._dnsZoneName, wildcardName, "A", ipv4, token, [
            cleanA,
        ]);

        if (ipv6.length > 0) {
            this.createDnsRrset(
                "wildcard-aaaa",
                this._dnsZoneName,
                wildcardName,
                "AAAA",
                ipv6,
                token,
                [cleanAAAA],
            );
        }

        /////////////////////
        // SPF record
        /////////////////////

        // smtpRelay is a secret (Output) — use interpolate so the SPF value resolves it.
        const spfValue: pulumi.Input<string> = projectSettings.mail.spfInclude
            ? `v=spf1 ${projectSettings.mail.spfInclude} ~all`
            : pulumi.interpolate`v=spf1 a:${projectSettings.mail.smtpRelay} ~all`;

        // The apex `@` TXT is SHARED with whatever else lives in this zone (typically the
        // project website's own mail). Publish it only when absent, and never delete it —
        // see ensureSharedDnsRrset. The per-subdomain SPF below IS ours and is owned normally.
        this.ensureSharedDnsRrset(
            "spf-txt",
            this._dnsZoneName,
            "@",
            "TXT",
            [pulumi.interpolate`"${spfValue}"`],
            token,
        );

        if (projectSettings.general.subdomain) {
            const cleanSpfSub = this.cleanDnsRrset(
                "spf-txt-subdomain",
                projectSettings.general.subdomain,
                "TXT",
                token,
            );
            this.createDnsRrset(
                "spf-txt-subdomain",
                this._dnsZoneName,
                projectSettings.general.subdomain,
                "TXT",
                [pulumi.interpolate`"${spfValue}"`],
                token,
                [cleanSpfSub],
            );
        }
    }
}
