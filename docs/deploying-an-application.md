# Deploy an application to a homelab host

This document explains how to set up automatic deployments for a new application.
The application runs in Docker on a homelab host.
GitHub Actions builds the application and deploys it over the tailnet.
Caddy serves the application at a name under `home.tverghis.space`.

The first application that used this method is Pico.
Use its repository as a working example.

## How it works

1. You start a workflow in the GitHub Actions tab.
2. The workflow runs the tests and creates a version tag.
3. The workflow builds a Docker image for the architecture of the host.
4. The workflow joins the tailnet as a temporary node with the tag `tag:ci`.
5. The workflow sends the image to the host over SSH.
6. The workflow starts the new container with Docker Compose.
7. The workflow checks that the application is healthy.

There is no container registry. The image goes straight from the workflow to the host.

Deployments never start by themselves. You start each release or deployment.
This keeps the number of deployments low while you develop.

## Words and placeholders

Replace each placeholder in angle brackets with your own value.

| Placeholder | Meaning | Example |
|---|---|---|
| `<app>` | Short name of the application | `pico` |
| `<host>` | Tailnet name of the host that runs the application | `ocelot` |
| `<host-ip>` | Tailnet IP address of `<host>` | `100.110.175.52` |
| `<caddy-ip>` | Tailnet IP address that Caddy listens on | `100.110.175.52` |
| `<domain>` | Name of the application | `pico.home.tverghis.space` |
| `<port>` | Port that the application listens on in its container | `8080` |
| `<uid>` | User ID that the container runs as | `65532` |

The **deploy user** is a Unix user on the host. The workflow uses it to log in with SSH.

## Before you start

You need these items:

- A host on your tailnet with Docker and Docker Compose installed.
- An account on the host that can use `sudo`. These steps call it `admin`.
- Admin access to your Tailscale account.
- A GitHub account.
- A Dockerfile for the application.
- A health check URL in the application. It must return a success code when the application is ready.

Find the CPU architecture of the host. The build step needs it.

```bash
ssh admin@<host> uname -m
```

`aarch64` means `linux/arm64`. `x86_64` means `linux/amd64`.

## Part 1: Set up the tailnet (once for the whole tailnet)

Do this part one time. Later applications use the same setup.
Skip each step that you did before.

### 1.1 Declare the CI tag

Open the Tailscale admin console. Open **Access controls**.
Add the tag to `tagOwners`:

```json
"tagOwners": {
	"tag:ci": ["autogroup:admin"],
},
```

You must declare a tag before an OAuth client can use it.

### 1.2 Turn on MagicDNS

Open the **DNS** page in the admin console.
Make sure that MagicDNS is on.
The workflow uses the host name `<host>` to find the host.

### 1.3 Create an OAuth client

Open **Settings**. Open **OAuth clients**.
In newer versions of the console, this page is named **Trust credentials**.

1. Create a new OAuth client.
2. Give it the scope **Auth Keys: Write**.
3. Limit it to the tag `tag:ci`.
4. Copy the client ID and the secret. The console shows the secret one time.

The workflow uses this client to add a temporary node to the tailnet.
The temporary node disappears when the workflow ends.
You can use the same client for all applications.

### 1.4 Limit what CI can reach

Edit the access policy.
Give `tag:ci` access to SSH on the deploy hosts only.

If your policy has a rule that allows `*` to reach `*`, replace that rule.
The `*` source includes tagged nodes. It would give CI access to all your devices.
Use `autogroup:member` as the source instead.
`autogroup:member` means the devices of the users in your tailnet.

```json
"hosts": {
	"<host>": "<host-ip>",
},

"grants": [
	// Every user device can reach every machine.
	{
		"src": ["autogroup:member"],
		"dst": ["*"],
		"ip":  ["*"],
	},

	// CI can reach only SSH on the deploy hosts.
	{
		"src": ["tag:ci"],
		"dst": ["<host>"],
		"ip":  ["tcp:22"],
	},
],

"tests": [
	{
		"src":    "tag:ci",
		"accept": ["<host>:22"],
		"deny":   ["<host>:80", "<other-host>:22"],
	},
	{
		"src":    "<your-tailscale-login>",
		"accept": ["<host>:22"],
	},
],
```

Notes:

- Add one entry to `hosts` for each deploy host. Add the same host to the `dst` list of the CI rule.
- If you tag a server, add its tag to the `src` list of the first rule. A tagged device is not in `autogroup:member`.
- The `tests` block stops you from saving a policy that gives CI too much access.
- The `<other-host>` entry in `tests` must be a different device that CI must not reach.

## Part 2: Set up the host (once for each host)

### 2.1 Create the deploy user

The deploy user has no password and no `sudo` access.
It is in the `docker` group, so it can run Docker commands.

```bash
ssh -t admin@<host> '
  sudo useradd --create-home --shell /bin/bash deploy &&
  sudo usermod -aG docker deploy &&
  sudo usermod -p "*" deploy &&
  sudo install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
'
```

**Warning:** Access to Docker is the same as root access.
A person who has the key of the deploy user can get root on the host.
The deploy user prevents mistakes and makes the logs clear.
It is not a security boundary.
Keep your repositories private. Replace a key if you think that it is not secret.

### 2.2 Prepare the routing

Caddy sends requests to the applications.
This repository runs Caddy in `compose.yml`. Caddy listens on one tailnet IP address.

Choose the case that fits your application.

**The application runs on the same host as Caddy.**
Put the application on the Docker network of Caddy.
Caddy then reaches the application by the name of its container.
Find the network name:

```bash
ssh admin@<host> docker network ls
```

This repository starts Caddy from `/opt/infra`, so the network is `infra_default`.
Use that name as `<caddy-network>` in the compose file in part 3.

**The application runs on a different host than Caddy.**
Publish the port of the application on the tailnet IP of its host.
Caddy then sends requests to `<host-ip>:<port>`.
In the compose file, use `ports: ["<host-ip>:<port>:<port>"]`.
Do not use the `networks` section from the template.
Use `reverse_proxy <host-ip>:<port>` in the Caddyfile.

## Part 3: Set up the application

### 3.1 Make the Dockerfile build for the host

Build for the architecture of the host. Do not use emulation if you can avoid it.
For a Go application, cross-compile in the build stage:

```dockerfile
FROM --platform=$BUILDPLATFORM golang:<version>-alpine AS build
ARG TARGETOS
ARG TARGETARCH
# ...
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -o /app ./cmd/app
```

For other languages, the workflow can use QEMU emulation.
Add the step `docker/setup-qemu-action` before the build step.
The build is slower with QEMU.

### 3.2 Add the deployment files

Add a `deploy` folder to the application repository with two files.

`deploy/compose.yml`:

```yaml
services:
  <app>:
    image: <app>:${APP_TAG:-latest}
    container_name: <app>
    restart: unless-stopped
    stop_grace_period: 15s

    volumes:
      - /srv/<app>:/data

    networks:
      - <caddy-network>

networks:
  <caddy-network>:
    external: true
```

Do not publish ports to the host unless you use the second routing case in part 2.2.
Use a bind mount for the data. Then you can copy and back up the data as normal files.

`deploy/deploy.sh`. Make the file executable.

```sh
#!/bin/sh
# Runs on the host, in /opt/<app>, after the image is loaded.
# Usage: APP_TAG=<tag> ./deploy.sh
set -eu

: "${APP_TAG:?APP_TAG is required}"
export APP_TAG

docker compose up -d --remove-orphans

# Check the application through Caddy.
# This tests the route from Caddy to the container.
for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS -o /dev/null \
        --resolve <domain>:80:<caddy-ip> \
        http://<domain>/<health-path>; then
        echo "<app> $APP_TAG is healthy"
        break
    fi
    if [ "$i" = 10 ]; then
        echo "<app> $APP_TAG failed its health check" >&2
        docker compose logs --tail 50 <app> >&2
        exit 1
    fi
    sleep 2
done

# Keep the five newest images for rollbacks.
docker images <app> --format '{{.ID}}' | awk '!seen[$0]++' | tail -n +6 |
    xargs -r docker rmi 2>/dev/null || true
```

### 3.3 Add the workflows

Add three files to `.github/workflows/`.
A workflow file must be on the default branch before it shows in the Actions tab.

`release.yml` runs the tests and creates the next version tag.
It can run by itself or be called by another workflow.
Change the test steps to fit your language.

```yaml
name: Release

on:
  workflow_dispatch:
    inputs:
      bump:
        description: Version part to increase
        type: choice
        options: [patch, minor, major]
        default: patch
  workflow_call:
    inputs:
      bump:
        type: string
        default: patch
    outputs:
      version:
        value: ${{ jobs.release.outputs.version }}

concurrency:
  group: release
  cancel-in-progress: false

jobs:
  release:
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    permissions:
      contents: write
    outputs:
      version: ${{ steps.version.outputs.version }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      # Replace these steps with the tests of your application.
      - uses: actions/setup-go@v5
        with:
          go-version-file: go.mod
      - run: go vet ./...
      - run: go test ./...

      - name: Tag the next version
        id: version
        env:
          BUMP: ${{ inputs.bump }}
        run: |
          latest=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n1)
          IFS=. read -r major minor patch <<< "${latest:-v0.0.0}"
          major=${major#v}
          case "$BUMP" in
            major) major=$((major + 1)); minor=0; patch=0 ;;
            minor) minor=$((minor + 1)); patch=0 ;;
            patch) patch=$((patch + 1)) ;;
            *) echo "unknown bump: $BUMP" >&2; exit 1 ;;
          esac
          version="v$major.$minor.$patch"
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git tag -a "$version" -m "Release $version"
          git push origin "$version"
          echo "version=$version" >> "$GITHUB_OUTPUT"
          echo "Tagged $version (previous: ${latest:-none})" >> "$GITHUB_STEP_SUMMARY"
```

`deploy.yml` deploys one tag, branch, or commit.
It can run by itself or be called by another workflow.
Change `HOST`, `platforms`, and the image name.

```yaml
name: Deploy

on:
  workflow_dispatch:
    inputs:
      ref:
        description: Tag, branch or commit to deploy
        type: string
        required: true
        default: main
  workflow_call:
    inputs:
      ref:
        type: string
        required: true

concurrency:
  group: deploy
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    env:
      HOST: <host>
      USER: deploy
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ inputs.ref }}
          fetch-depth: 0

      # A tag deploys as itself (v0.1.0). Other refs deploy as v0.1.0-3-gabc1234.
      - name: Name the image
        id: version
        run: echo "tag=$(git describe --tags --always)" >> "$GITHUB_OUTPUT"

      - uses: docker/setup-buildx-action@v3

      - name: Build the image
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/arm64   # use linux/amd64 for an x86_64 host
          tags: <app>:${{ steps.version.outputs.tag }},<app>:latest
          outputs: type=docker,dest=${{ runner.temp }}/image.tar
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Join the tailnet
        uses: tailscale/github-action@v3
        with:
          oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
          tags: tag:ci

      - name: Configure SSH
        run: |
          install -m 700 -d ~/.ssh
          echo "${{ secrets.DEPLOY_SSH_KEY }}" > ~/.ssh/id_ed25519
          chmod 600 ~/.ssh/id_ed25519
          # The tailnet authenticates the host, so trust its key on first use.
          ssh-keyscan -T 10 "$HOST" >> ~/.ssh/known_hosts

      - name: Copy the files and the image to the host
        run: |
          scp deploy/compose.yml deploy/deploy.sh "$USER@$HOST:/opt/<app>/"
          gzip -c "${{ runner.temp }}/image.tar" | ssh "$USER@$HOST" 'gunzip | docker load'

      - name: Deploy
        env:
          TAG: ${{ steps.version.outputs.tag }}
        run: |
          ssh "$USER@$HOST" "cd /opt/<app> && APP_TAG=$TAG ./deploy.sh"
          echo "Deployed $TAG" >> "$GITHUB_STEP_SUMMARY"
```

`release-and-deploy.yml` does both steps.
Do not add a `concurrency` setting to this file.
A group with the same name as a called workflow causes a deadlock.

```yaml
name: Release and deploy

on:
  workflow_dispatch:
    inputs:
      bump:
        description: Version part to increase
        type: choice
        options: [patch, minor, major]
        default: patch

jobs:
  release:
    permissions:
      contents: write
    uses: ./.github/workflows/release.yml
    with:
      bump: ${{ inputs.bump }}

  deploy:
    needs: release
    permissions:
      contents: read
    uses: ./.github/workflows/deploy.yml
    with:
      ref: ${{ needs.release.outputs.version }}
    secrets: inherit
```

### 3.4 Prepare the folders on the host

Make a folder for the compose file and a folder for the data.
The deploy user owns the compose folder.
The user ID of the container owns the data folder.
Find the user ID in the Dockerfile. A distroless `nonroot` image uses `65532`.

```bash
ssh -t admin@<host> '
  sudo mkdir -p /opt/<app> /srv/<app> &&
  sudo chown deploy:deploy /opt/<app> &&
  sudo chown <uid>:<uid> /srv/<app>
'
```

### 3.5 Create the SSH key

Make a new key for each application. Then you can replace one key without changing the others.
Use a temporary folder. Delete the key at the end of this guide.

```bash
ssh-keygen -t ed25519 -N "" -C "<app>-ci" -f /tmp/<app>_deploy
```

Install the public key for the deploy user.
The word `restrict` is optional.
It turns off port forwarding, agent forwarding, and terminals for this key.
Commands and file copies still work.

```bash
scp /tmp/<app>_deploy.pub admin@<host>:/tmp/
ssh -t admin@<host> 'printf "restrict %s\n" "$(cat /tmp/<app>_deploy.pub)" | sudo tee -a /home/deploy/.ssh/authorized_keys >/dev/null && sudo chown deploy:deploy /home/deploy/.ssh/authorized_keys && sudo chmod 600 /home/deploy/.ssh/authorized_keys && rm /tmp/<app>_deploy.pub'
```

The command uses `tee -a`. It adds the key and keeps the keys of other applications.

Test the key. The command must show the container names and the word `writable`.
It must not ask for a password.

```bash
ssh -i /tmp/<app>_deploy deploy@<host> 'docker ps --format "{{.Names}}" && touch /opt/<app>/.w && rm /opt/<app>/.w && echo writable'
```

If SSH says that the account is locked, run `sudo usermod -p "*" deploy` on the host.

### 3.6 Set up GitHub

1. Create a private repository for the application.
2. Open **Settings**, then **Secrets and variables**, then **Actions**.
3. Add these three repository secrets:

| Secret | Value |
|---|---|
| `TS_OAUTH_CLIENT_ID` | Client ID from step 1.3 |
| `TS_OAUTH_SECRET` | Secret from step 1.3 |
| `DEPLOY_SSH_KEY` | The full text of the private key file `/tmp/<app>_deploy` |

On macOS, this command copies the key to the clipboard:

```bash
pbcopy < /tmp/<app>_deploy
```

4. Open **Settings**, then **Actions**, then **General**.
   Make sure that workflows can have write permission for the contents of the repository.
   The release workflow needs this permission to push a tag.

### 3.7 Add the route and the DNS record

Do this before the first deployment. The health check uses the route.

Edit these files in this repository.

In `caddy/Caddyfile`, add a block:

```
http://<domain> {
	reverse_proxy <app>:<port>
}
```

In `coredns/db.home.tverghis.space`, add an `A` record. Use the `<caddy-ip>` address.
Increase the serial number in the SOA record.
The serial uses the format `YYYYMMDDnn`. For example, use `2026100301` for the first change on 3 October 2026.

```
<app-name>   IN A   <caddy-ip>
```

Use only the first part of the name as `<app-name>`.
For example, use `pico` for `pico.home.tverghis.space`.

Then do these steps:

1. Commit the changes.
2. Send the files to the host: `just update-configs`.
3. Reload Caddy:

```bash
ssh admin@<host> 'docker exec caddy caddy reload --config /etc/caddy/Caddyfile'
```

CoreDNS reloads its files after 30 seconds. Check the record:

```bash
dig +short @<caddy-ip> <domain>
```

The command must show `<caddy-ip>`.
Caddy can log a warning that `<app>` does not resolve. This is normal before the first deployment.

### 3.8 Make the first release

1. Commit the application files and push them to `main`. Nothing deploys on a push.
2. Open the **Actions** tab on GitHub.
3. Select **Release and deploy**, then **Run workflow**.
4. Use the branch `main`. Choose `minor` for the first release. The version is `v0.1.0`.
5. Wait for both jobs to finish. The first build is slow because it has no cache.
6. Open `http://<domain>` and make sure that the application works.

### 3.9 Copy existing data (optional)

Use this step to start with data from your computer.
This example is for SQLite. Other databases need other tools.

Do not copy a SQLite file that is in use. Make a consistent copy with `.backup`.

```bash
sqlite3 <app>.db ".backup /tmp/<app>-seed.db"
scp /tmp/<app>-seed.db admin@<host>:/tmp/
ssh -t admin@<host> 'cd /opt/<app> && docker compose stop <app> && sudo cp /tmp/<app>-seed.db /srv/<app>/<app>.db && sudo rm -f /srv/<app>/<app>.db-wal /srv/<app>/<app>.db-shm && sudo chown <uid>:<uid> /srv/<app>/<app>.db && docker compose start <app> && rm /tmp/<app>-seed.db'
```

Make sure that the file name matches the database path of the application.
If the application runs migrations when it starts, they apply to the copied data.

### 3.10 Clean up

Delete the temporary files on your computer:

```bash
rm /tmp/<app>_deploy /tmp/<app>_deploy.pub /tmp/<app>-seed.db
```

## Daily use

| Task | Action |
|---|---|
| Create a version tag only | Run **Release**. |
| Deploy an existing tag | Run **Deploy**. Enter the tag as `ref`. |
| Create a tag and deploy it | Run **Release and deploy**. |
| Roll back | Run **Deploy**. Enter an older tag as `ref`. |
| Retry a failed deployment | Open the run. Select **Re-run failed jobs**. |

A rerun of a failed deployment does not create a second tag.

You can also roll back on the host. The host keeps the five newest images.

```bash
ssh deploy@<host> 'cd /opt/<app> && APP_TAG=<old-tag> ./deploy.sh'
```

To see the logs of the application:

```bash
ssh admin@<host> 'docker logs --tail 100 <app>'
```

## Troubleshooting

| Problem | Cause and fix |
|---|---|
| The workflow cannot join the tailnet | Check the OAuth client. It needs the scope **Auth Keys: Write** and the tag `tag:ci`. Check that `tag:ci` is in `tagOwners`. |
| SSH times out | The access policy does not allow `tag:ci` to reach `<host>` on port 22. Check the grants. Check that MagicDNS is on. |
| SSH says `Permission denied` | The public key is not in `/home/deploy/.ssh/authorized_keys`, or the permissions are wrong. The folder must be mode `700`. The file must be mode `600`. |
| SSH says that the account is locked | Run `sudo usermod -p "*" deploy` on the host. |
| `scp` cannot write to `/opt/<app>` | The deploy user must own the folder. See step 3.4. |
| `docker load` is denied | The deploy user must be in the `docker` group. See step 2.1. |
| The health check fails | Read the logs that the script prints. Check the health path. Check the data folder owner. |
| Caddy returns `502` | Caddy cannot reach the container. Make sure that the container is on the Caddy network. Make sure that the port is correct. |
| The name does not resolve | Check the DNS record and the serial number. Wait 30 seconds. Check that your device uses the CoreDNS server for `home.tverghis.space`. |
| The workflow is not in the Actions tab | The workflow file must be on the default branch. |
| The image does not start on the host | The image architecture must match the host. See the start of this document. |
