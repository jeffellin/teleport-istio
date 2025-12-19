# Envoy SDS Debug Cheatsheet

- Dump Envoy config locally:  
  `kubectl exec front-end-69bcf9f8cf-nthv9 -c istio-proxy -- curl -s http://127.0.0.1:15000/config_dump > /tmp/envoy-config.json`

- List SDS secret names and timestamps:  
  `jq -r '.configs[] | select(."@type"=="type.googleapis.com/envoy.admin.v3.SecretsConfigDump") | .dynamic_active_secrets[] | "\(.name)  last_updated=\(.last_updated)"' /tmp/envoy-config.json`

- Inspect cert for a secret (replace SECRET_NAME):  
  ```bash
  SECRET_NAME="default"
  jq -r --arg name "$SECRET_NAME" '
    .configs[]
    | select(."@type"=="type.googleapis.com/envoy.admin.v3.SecretsConfigDump")
    | .dynamic_active_secrets[]
    | select(.name==$name)
    | .secret.tls_certificate.certificate_chain
    | if has("inline_bytes") then .inline_bytes | @base64d
      elif has("inline_string") then .inline_string
      else empty end
  ' /tmp/envoy-config.json | openssl x509 -inform PEM -noout -subject -issuer -dates
  ```

- Inspect validation CA (SPIFFE validator trust bundle) for a secret (replace VAL_SECRET):  
  ```bash
  VAL_SECRET="ROOTCA"
  jq -r --arg name "$VAL_SECRET" '
    .configs[]
    | select(."@type"=="type.googleapis.com/envoy.admin.v3.SecretsConfigDump")
    | .dynamic_active_secrets[]
    | select(.name==$name)
    | .secret.validation_context.custom_validator_config.typed_config.trust_domains[]
    | .trust_bundle
    | if has("inline_bytes") then .inline_bytes | @base64d
      elif has("inline_string") then .inline_string
      else empty end
  ' /tmp/envoy-config.json | openssl x509 -inform PEM -noout -subject -issuer -dates
  ```

- List SDS secret names referenced by listeners:  
  `jq -r '.configs[] | select(."@type"=="type.googleapis.com/envoy.admin.v3.ListenersConfigDump") | .. | objects | select(has("tls_certificate_sds_secret_configs") or has("validation_context_sds_secret_config")) | [ (.tls_certificate_sds_secret_configs[]?.name // empty), (.validation_context_sds_secret_config.name // empty) ][]' /tmp/envoy-config.json | sort -u`

- List SDS secret names referenced by clusters:  
  `jq -r '.configs[] | select(."@type"=="type.googleapis.com/envoy.admin.v3.ClustersConfigDump") | .. | objects | select(has("tls_certificate_sds_secret_configs") or has("validation_context_sds_secret_config")) | [ (.tls_certificate_sds_secret_configs[]?.name // empty), (.validation_context_sds_secret_config.name // empty) ][]' /tmp/envoy-config.json | sort -u`
