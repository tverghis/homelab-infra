FROM caddy:2.11.4-builder-alpine AS build
RUN xcaddy build --with github.com/caddy-dns/porkbun@v0.3.1

FROM caddy:2.11.4-alpine
COPY --from=build /usr/bin/caddy /usr/bin/caddy
