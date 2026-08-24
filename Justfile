host := "admin@ocelot"
remote_dir := "/opt/infra"

update-configs:
    rsync --archive --no-owner --no-group --verbose \
        compose.yml caddy grafana prometheus \
        "{{host}}:{{remote_dir}}/"
