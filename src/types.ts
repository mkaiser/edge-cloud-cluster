// Shared domain types used across all modules.

export type ClusterOS = "Talos" | "debian-13" | "ubuntu-24.04";
export type LoadBalancerProvider = "hetzner-ccm" | "k3s-servicelb";
export type ROLLOUT_TYPE = "Testing" | "Production" | "Bootstrap";
export type CERT_TYPE = "letsencrypt-production" | "letsencrypt-staging";

export interface ControlPlaneNode {
    id: string;
    serverType: string;
    location: string;
}

export interface WorkerNode {
    id: string;
    serverType: string;
    location: string;
}
