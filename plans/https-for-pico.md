# Plan: Serve Pico over HTTPS

Status: done, except the browser check on a computer and a phone (Part 4 step 8). Production certificate live (Let's Encrypt, first issued 2026-10-12). pico-preview is served from the same wildcard block.

## Goal

Serve `pico.home.tverghis.space` over HTTPS with a certificate that all devices trust.
Do not install a certificate authority on any device.
Keep all services reachable only on the tailnet.

Other sites under `home.tverghis.space` get HTTPS at the same time.

## Current state

- Caddy listens only on `100.110.175.52:80`. See `compose.yml`.
- All sites in `caddy/Caddyfile` use `http://`.
- `home.tverghis.space` exists only in CoreDNS on the tailnet.
  Public DNS has no records and no delegation for `home.`.
- Public DNS for `tverghis.space` is at Namecheap (`dns1.registrar-servers.com`, `dns2.registrar-servers.com`).

## Approach

Caddy gets one wildcard certificate for `*.home.tverghis.space` from Let's Encrypt.
Caddy uses the DNS-01 challenge.
It creates a `_acme-challenge.home.tverghis.space` TXT record in public DNS through the Porkbun API.

Why DNS-01: Let's Encrypt cannot reach Caddy from the internet.
The HTTP-01 and TLS-ALPN-01 challenges need that access. DNS-01 does not.

Why a wildcard certificate:

- New applications get HTTPS with no extra certificate work.
- Certificate Transparency logs are public.
  A wildcard shows only `*.home.tverghis.space`. It does not list the names of each application.

Options that we rejected:

| Option | Reason |
|---|---|
| Tailscale certificates (`*.ts.net`) | One name for each machine. We lose `pico.home.tverghis.space`. |
| Caddy internal CA (`tls internal`) | Each device must trust the root certificate. This is hard on phones. |
| Namecheap API | Needs a minimum account spend and a list of allowed IP addresses. |

## Part 1: Move the domain to Porkbun (manual)

1. Write down every record in the Namecheap zone for `tverghis.space`. Include MX, SPF, DKIM, and verification TXT records.
2. Unlock the domain at Namecheap and get the authorization code.
   A domain that was registered or transferred in the last 60 days cannot move yet.
3. Start the transfer at Porkbun. Wait for it to finish.
4. Create the records from step 1 in Porkbun DNS.
   Do this before you change the nameservers, if Porkbun allows it.
5. Make sure that the domain uses the Porkbun nameservers:

   ```bash
   dig +short NS tverghis.space @1.1.1.1
   ```

6. Make sure that the old records still resolve. For example:

   ```bash
   dig +short MX tverghis.space @1.1.1.1
   ```

Do not create any public records for `home.tverghis.space`.
CoreDNS on the tailnet stays the only source for those names.

## Part 2: Create the Porkbun API key (manual)

1. Open porkbun.com, then **Account**, then **API Access**.
2. Create a key. Copy the API key and the secret key.
3. Open **Domain Management**. Open the settings of `tverghis.space`.
4. Turn on **API Access** for this domain. It is off by default.
   Without this step, the keys are valid but Porkbun refuses all DNS calls.
5. Do not turn on API access for other domains.
   Porkbun keys are not limited to one domain. The key can change every domain that has API access.

## Part 3: Change this repository

### 3.1 Build Caddy with the Porkbun plugin

The `caddy` image has no DNS plugins. Add `caddy/Dockerfile`:

```dockerfile
FROM caddy:2.11.4-builder-alpine AS build
RUN xcaddy build --with github.com/caddy-dns/porkbun@v0.3.1

FROM caddy:2.11.4-alpine
COPY --from=build /usr/bin/caddy /usr/bin/caddy
```

The plugin is pinned to v0.3.1, the newest version, for repeatable builds.
`caddy/.dockerignore` keeps `porkbun.env` out of the build context.

### 3.2 Store the API keys

Create `caddy/porkbun.env` on your computer. Do not commit it.

```
PORKBUN_API_KEY=pk1_...
PORKBUN_SECRET_KEY=sk1_...
```

Add it to `.gitignore`:

```
/caddy/porkbun.env
```

`just update-configs` sends the whole `caddy` folder, so the file goes to the host.
Set its mode to `600` on the host after the first copy.

Note: the `caddy` folder is also mounted in the container at `/etc/caddy`.
The keys are in the environment of the container anyway, so this does not expose more.

### 3.3 Change `compose.yml`

Change the `caddy` service:

```yaml
  caddy:
    build: ./caddy
    image: infra-caddy:2.11.4-porkbun
    container_name: caddy
    restart: unless-stopped

    env_file:
      - ./caddy/porkbun.env

    ports:
      - "100.110.175.52:80:80"
      - "100.110.175.52:443:443"
      - "100.110.175.52:443:443/udp"

    # volumes and depends_on do not change
```

- Keep port 80. Caddy uses it to redirect HTTP to HTTPS.
- Port `443/udp` is for HTTP/3. It is optional.
- The `caddy-data` volume keeps the certificate and the ACME account between restarts. Do not delete it.
- The tailnet access policy already lets `autogroup:member` reach all ports. No policy change is needed.

### 3.4 Change `caddy/Caddyfile`

Use one site block for the wildcard name. Choose the backend by host name.

```
{
	# Optional. Let's Encrypt sends expiry warnings to this address.
	# email <your-email>

	# Use the staging CA for the first test. Remove this line after the test passes.
	acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
}

*.home.tverghis.space {
	tls {
		dns porkbun {
			api_key {env.PORKBUN_API_KEY}
			api_secret_key {env.PORKBUN_SECRET_KEY}
		}
		resolvers 1.1.1.1 9.9.9.9
	}

	@dashboard host dashboard.home.tverghis.space
	handle @dashboard {
		reverse_proxy grafana:3000
	}

	@files host files.home.tverghis.space
	handle @files {
		reverse_proxy copyparty:3923
	}

	@pico host pico.home.tverghis.space
	handle @pico {
		reverse_proxy pico:8080
	}

	# Unknown names under home.tverghis.space.
	handle {
		abort
	}
}
```

**Important: keep the `resolvers` line.**
Before Caddy asks Let's Encrypt to check the TXT record, Caddy checks the record itself.
It looks up the authoritative nameservers for the zone.
On the tailnet, MagicDNS sends `home.tverghis.space` queries to CoreDNS.
CoreDNS says that it is the authority for that zone, but it never has the challenge record.
Without public resolvers, Caddy waits until it times out and the certificate request fails.

### 3.5 Optional: add a Justfile recipe

Today, `update-configs` copies files only. Caddy now needs a build. Add a recipe:

```just
deploy-caddy: update-configs
    ssh {{host}} 'cd {{remote_dir}} && docker compose up -d --build caddy'
```

## Part 4: Deploy and test

1. Copy the files: `just update-configs`.
2. On the host, protect the key file:

   ```bash
   ssh admin@ocelot 'chmod 600 /opt/infra/caddy/porkbun.env'
   ```

3. Build and start Caddy:

   ```bash
   ssh admin@ocelot 'cd /opt/infra && docker compose up -d --build caddy'
   ```

4. Watch the logs. Look for `certificate obtained successfully` for `*.home.tverghis.space`:

   ```bash
   ssh admin@ocelot 'docker logs -f caddy'
   ```

5. Test with the staging certificate. It is not trusted, so use `-k`:

   ```bash
   curl -kv https://pico.home.tverghis.space/
   ```

   Check that the issuer is a Let's Encrypt staging CA.

6. Remove the `acme_ca` line from the Caddyfile. Deploy again.
   Caddy gets a production certificate.
   If Caddy keeps the staging certificate, delete it from the `caddy-data` volume and restart Caddy.

7. Test without `-k`:

   ```bash
   curl -sSI https://pico.home.tverghis.space/
   curl -sSI http://pico.home.tverghis.space/   # must redirect to https
   ```

8. Open all three sites in a browser, on a computer and on a phone.

## Part 5: Change Pico (in the Pico repository)

### 5.1 Fix the health check in `deploy/deploy.sh`

The current check calls `http://` on port 80.
After this change, Caddy answers with a `308` redirect.
`curl -f` fails only for status codes of 400 and higher.
So the check passes **without ever reaching Pico**. Change it to HTTPS:

```sh
    if curl -fsS -o /dev/null \
        --resolve pico.home.tverghis.space:443:100.110.175.52 \
        https://pico.home.tverghis.space/<health-path>; then
```

The host must trust the production certificate. A normal CA bundle does this.
During the staging test, the check fails unless you add `-k`. Do not commit `-k`.

### 5.2 Check how Pico behaves behind HTTPS

Caddy sends `X-Forwarded-Proto: https` and `X-Forwarded-For`.
Check these points in Pico:

- Absolute URLs (redirects, links, OAuth callbacks) use `https`.
- Cookies have the `Secure` flag, if Pico sets cookies.
- Origin or CSRF checks expect `https://pico.home.tverghis.space`.

## Part 6: Update `docs/deploying-an-application.md`

- **1.4**: In the `tests` block, add `<host>:443` to the `deny` list for `tag:ci`.
- **3.2**: Change the health check in the `deploy.sh` template to `https://` and `--resolve <domain>:443:<caddy-ip>`. Explain why `http://` gives a false pass.
- **3.7**: Do not add a new site block. Add a matcher and a `handle` block inside `*.home.tverghis.space`:

  ```
  	@<app> host <domain>
  	handle @<app> {
  		reverse_proxy <app>:<port>
  	}
  ```

  Put it before the final `handle { abort }` block.
  Reload Caddy with `docker exec caddy caddy reload --config /etc/caddy/Caddyfile`. No rebuild is needed.
- **3.8**: Open `https://<domain>`.
- **Troubleshooting**: Add rows for these problems:
  - The certificate request fails with a Porkbun error. Check that API access is on for the domain.
  - The certificate request times out. Check the `resolvers` line.
  - The browser shows an untrusted certificate. The `acme_ca` staging line is still in the Caddyfile.

## Rollback

1. Restore the old `caddy/Caddyfile` and `compose.yml` from git.
2. Run `just update-configs`.
3. On the host, run `docker compose up -d caddy`. The stock image comes back.
4. If Pico's health check is already on HTTPS, restore the HTTP version.

## Risks

- **API key scope.** The key can change all DNS on every domain that has API access on. Keep it only on the host, with mode `600`. Turn on API access for `tverghis.space` only.
- **Renewal.** Caddy renews about 30 days before expiry. Renewal needs the Porkbun API and outgoing DNS to `1.1.1.1` and `9.9.9.9`. Consider an alert on the certificate expiry date in Grafana later.
- **Domain transfer.** Missing records break other services that use `tverghis.space`, such as email. Copy all records before you change the nameservers.

## Checklist

- [x] Domain moved to Porkbun and records copied
- [x] API key created and API access on for `tverghis.space`
- [x] `caddy/Dockerfile` added
- [x] `caddy/porkbun.env` created and in `.gitignore`
- [x] `compose.yml` changed
- [x] `caddy/Caddyfile` changed, with staging CA
- [x] Staging certificate obtained
- [x] Production certificate obtained
- [x] Pico health check changed to HTTPS
- [x] Pico checked behind HTTPS
- [x] Deployment doc updated
