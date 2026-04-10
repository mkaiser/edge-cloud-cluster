# DONE

- devcontainer
- secret handling
- Hetzner Cloud setup
- control plane
- Certificate management
- DNS management
- ArgoCD setup (webgui, certs, DNS)
- backup and recover etcd storage
- Argocd CLI (see pulumi output)
- Monitoring Promotheus / Grafana
- ArgoCD selfupdate
- HAProxy Ingress
- wildcard DNS & cert issuer in pulumi, can be used in pulumi
- Redo getKubeControl - use env variable set in dockerfile. Don't source it.
- Refactor pulumi ts file
- MIT License
- Add header with author
- Notify eMail configurable by secret
- Add cost & time estimation
- Test renovate

# Next Steps

- Don't expose argocd via ingress. Use kubectl port-forward -n argocd svc/ ums-keycloak 18080:8080
  Then open: http://localhost:18080/admin/
- Create mearmaid chart for architecture overview
- Test Load balancer (Test Hetzner CCM)
- deploy opendesk --> ID management als basis für alle anderen services
- Headscale VPN for edge nodes (managed by ArgoCD and uses nubus as identity provider)
- wird das nfs package für ubuntu wirklich benötigt? Das sollte mit dem helm eigentlich im userspace laufen
- Ryax deploy
- pulumi settings "bootstrap" --> non bootstrap enables stricter firewall settings --> Only use http(s) and jitsi port
- Hetzner Autoscaling
- RBAC
- Test: Talos Linux as cluster OS (etcd backup via ArgoCD, in-place upgrades via talosctl)

# Future Stuff

- Slurm integration
- proxmox hypervisor integration
- Check if https://github.com/mconfalonieri/external-dns-hetzner-webhook supports DNS console comments. Useful to indicate which entries are automated by pulumi / argocd
