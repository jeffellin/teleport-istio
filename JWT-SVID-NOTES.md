# JWT SVIDs with Spring Security

Notes on using Teleport Workload Identity JWT SVIDs (or bridging from X.509 SVIDs) with Spring Security–based microservices.

## Capability check
- Teleport Workload Identity primarily issues X.509 SVIDs. JWT SVIDs are available on Teleport v16+ via the Workload API `FetchJWTSVID` method and a published JWKS bundle. If you’re on an older version, use the bridge pattern below.

## Getting a JWT SVID (Teleport v16+)
- Client call: use the Workload API `FetchJWTSVID` with an `aud` list of the target service(s). The RPC returns the JWT SVID and the JWT bundle (JWKS). Typical flow:
  1. Dial the Workload API over the SPIFFE socket (same socket path you use for X.509 SVIDs).
  2. Call `FetchJWTSVID(audience=["orders-service"])`.
  3. Receive a JWT and bundle; cache the token until `exp`, re-fetch on expiry or failure.
  4. Send `Authorization: Bearer <jwt>` on outbound calls.
  5. Validate on the server using the JWKS from the proxy (`/.well-known/spiffe/bundle.jwks`).
- JWKS: the Teleport proxy exposes the JWT bundle JWKS at a well-known path (for the default proxy, `https://<proxy-address>/.well-known/spiffe/bundle.jwks`; adjust if you front the proxy with ingress/hostname). Spring uses this URL for validation.
- TTL/rotation: JWT SVIDs are short-lived; refresh and cache per TTL.

### When JWT SVIDs are useful
- Your services already validate JWTs (e.g., Spring Security resource-server) and you want to avoid mTLS termination in-app.
- You need browser/mobile clients to present a token that upstream services can verify via JWKS (still issued from SPIFFE identity).
- gRPC/HTTP gateways or API gateways that expect Bearer tokens and are easier to wire with JWT auth than with mutual TLS.
- Mixed environments where some stacks don’t support mTLS well but can do JWT validation, yet you still want a single SPIFFE-based identity root.

## Istio egress injection pattern (JWT SVID)
- Pattern: run a tiny helper/sidecar that calls `FetchJWTSVID` and writes a short-lived token to a shared in-pod volume (e.g., `emptyDir` mounted at `/var/run/tokens`). Use an Envoy Lua or Wasm filter on egress to read that file and set `Authorization: Bearer <jwt>` for matching destinations.
- Best fit: egress to services outside Istio mTLS reach (other clusters/off-mesh) where you still want SPIFFE-derived identity and JWT-based auth.

Example `EnvoyFilter` (Lua, file-based cache):
```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: inject-jwt-svid
  namespace: default
spec:
  workloadSelector:
    labels:
      app: my-client
  configPatches:
  - applyTo: HTTP_FILTER
    match:
      context: SIDECAR_OUTBOUND
      listener:
        filterChain:
          filter:
            name: envoy.filters.network.http_connection_manager
            subFilter:
              name: envoy.filters.http.router
    patch:
      operation: INSERT_BEFORE
      value:
        name: envoy.filters.http.lua
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua
          inlineCode: |
            local jwt_path = "/var/run/tokens/orders.jwt"  -- shared emptyDir mount
            function envoy_on_request(handle)
              local file = io.open(jwt_path, "r")
              if file then
                local jwt = file:read("*a")
                file:close()
                if jwt and #jwt > 0 then
                  handle:headers():replace("authorization", "Bearer " .. jwt)
                end
              end
            end
```

Notes:
- Mount the same `emptyDir` into the helper and Envoy at `/var/run/tokens`; do not use hostPath.
- Have the helper refresh JWTs per TTL with the right `aud` per target.
- Scope the filter to intended destinations (e.g., check `:authority`/cluster before injecting) to avoid leaking tokens.
- Best fit: egress to services outside Istio mTLS reach (other clusters/off-mesh). Remote services or gateways must trust Teleport’s JWKS and enforce the right `aud`; keep JWT TTLs short and refresh per audience.

## When JWT SVIDs are available
- Trust source: point Spring Boot at Teleport’s JWT bundle JWKS (`spring.security.oauth2.resourceserver.jwt.jwk-set-uri`).
- Claims to use: `sub` (SPIFFE ID), `aud` (target service), `exp` (short TTL). Treat `sub` as the principal.
- Audience: require an explicit audience per service (e.g., `orders-service`), set in Spring via `audiences`.
- Client flow: call `FetchJWTSVID` with `aud=<target-service>`, then send `Authorization: Bearer <jwt>` on outbound HTTP/gRPC; refresh on expiry.

Example resource-server config:
```yaml
spring:
  security:
    oauth2:
      resourceserver:
        jwt:
          jwk-set-uri: https://teleport.example.com/.well-known/spiffe/bundle.jwks  # adjust to your Teleport JWKS
          audiences: orders-service
```

Minimal converter to use SPIFFE ID as principal:
```java
@Bean
SecurityFilterChain api(HttpSecurity http) throws Exception {
  return http
    .authorizeHttpRequests(auth -> auth
      .requestMatchers("/actuator/health").permitAll()
      .anyRequest().authenticated())
    .oauth2ResourceServer(rs -> rs.jwt(jwt -> jwt.jwtAuthenticationConverter(token -> {
      String spiffeId = token.getClaimAsString("sub");
      var auth = new UsernamePasswordAuthenticationToken(spiffeId, "n/a", List.of());
      auth.setDetails(token.getClaims());
      return auth;
    })))
    .build();
}
```

## If JWT SVIDs are not available
1) Keep using mTLS with X.509 SVIDs (already supported).  
2) Add a small “token service” that trusts the SPIFFE socket, authenticates callers by X.509 SVID, and signs a JWT with your own key/JWKS for Spring to validate.
