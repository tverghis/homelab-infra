host := "admin@ocelot"
remote_dir := "/opt/infra"

update-configs:
    rsync --archive --no-owner --no-group --verbose \
        --exclude copyparty/initial_passwords \
        compose.yml caddy copyparty coredns grafana prometheus \
        "{{host}}:{{remote_dir}}/"

deploy-caddy: update-configs
    ssh {{host}} 'cd {{remote_dir}} && docker compose up -d --build caddy'
