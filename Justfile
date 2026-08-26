host := "admin@ocelot"
remote_dir := "/opt/infra"

update-configs:
    rsync --archive --no-owner --no-group --verbose \
        --exclude copyparty/initial_passwords \
        compose.yml caddy copyparty coredns grafana prometheus \
        "{{host}}:{{remote_dir}}/"
