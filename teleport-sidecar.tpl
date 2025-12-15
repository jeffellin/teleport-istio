    {{- define "resources"  }}
      {{- if or (isset .ObjectMeta.Annotations `sidecar.istio.io/proxyCPU`) (isset .ObjectMeta.Annotations `sidecar.istio.io/proxyMemory`) (isset .ObjectMeta.Annotations `sidecar.istio.io/proxyCPULimit`) (isset .ObjectMeta.Annotations `sidecar.istio.io/proxyMemoryLimit`) }}
        {{- if or (isset .ObjectMeta.Annotations `sidecar.istio.io/proxyCPU`) (isset .ObjectMeta.Annotations `sidecar.istio.io/proxyMemory`) }}
          requests:
            {{ if (isset .ObjectMeta.Annotations `sidecar.istio.io/proxyCPU`) -}}
            cpu: "{{ index .ObjectMeta.Annotations `sidecar.istio.io/proxyCPU` }}"
            {{ end }}
            {{ if (isset .ObjectMeta.Annotations `sidecar.istio.io/proxyMemory`) -}}
            memory: "{{ index .ObjectMeta.Annotations `sidecar.istio.io/proxyMemory` }}"
            {{ end }}
        {{- end }}
        {{- if or (isset .ObjectMeta.Annotations `sidecar.istio.io/proxyCPULimit`) (isset .ObjectMeta.Annotations `sidecar.istio.io/proxyMemoryLimit`) }}
          limits:
            {{ if (isset .ObjectMeta.Annotations `sidecar.istio.io/proxyCPULimit`) -}}
            cpu: "{{ index .ObjectMeta.Annotations `sidecar.istio.io/proxyCPULimit` }}"
            {{ end }}
            {{ if (isset .ObjectMeta.Annotations `sidecar.istio.io/proxyMemoryLimit`) -}}
            memory: "{{ index .ObjectMeta.Annotations `sidecar.istio.io/proxyMemoryLimit` }}"
            {{ end }}
        {{- end }}
      {{- else }}
        {{- if .Values.global.proxy.resources }}
          {{ toYaml .Values.global.proxy.resources | indent 6 }}
        {{- end }}
      {{- end }}
    {{- end }}
    {{ $tproxy := (eq (annotation .ObjectMeta `sidecar.istio.io/interceptionMode` .ProxyConfig.InterceptionMode) `TPROXY`) }}
    {{ $capNetBindService := (eq (annotation .ObjectMeta `sidecar.istio.io/capNetBindService` .Values.global.proxy.capNetBindService) `true`) }}
    {{ $nativeSidecar := ne (index .ObjectMeta.Annotations `sidecar.istio.io/nativeSidecar` | default (printf "%t" .NativeSidecars)) "false" }}
    {{- $containers := list }}
    {{- range $index, $container := .Spec.Containers }}{{ if not (eq $container.Name "istio-proxy") }}{{ $containers = append $containers $container.Name }}{{end}}{{- end}}
    metadata:
      labels:
        security.istio.io/tlsMode: {{ index .ObjectMeta.Labels `security.istio.io/tlsMode` | default "istio"  | quote }}
        {{- if eq (index .ProxyConfig.ProxyMetadata "ISTIO_META_ENABLE_HBONE") "true" }}
        networking.istio.io/tunnel: {{ index .ObjectMeta.Labels `networking.istio.io/tunnel` | default "http"  | quote }}
        {{- end }}
        service.istio.io/canonical-name: {{ index .ObjectMeta.Labels `service.istio.io/canonical-name` | default (index .ObjectMeta.Labels `app.kubernetes.io/name`) | default (index .ObjectMeta.Labels `app`) | default .DeploymentMeta.Name  | trunc 63 | trimSuffix "-" | quote }}
        service.istio.io/canonical-revision: {{ index .ObjectMeta.Labels `service.istio.io/canonical-revision` | default (index .ObjectMeta.Labels `app.kubernetes.io/version`) | default (index .ObjectMeta.Labels `version`) | default "latest"  | quote }}
      annotations: {
        istio.io/rev: {{ .Revision | default "default" | quote }},
        {{- if ge (len $containers) 1 }}
        {{- if not (isset .ObjectMeta.Annotations `kubectl.kubernetes.io/default-logs-container`) }}
        kubectl.kubernetes.io/default-logs-container: "{{ index $containers 0 }}",
        {{- end }}
        {{- if not (isset .ObjectMeta.Annotations `kubectl.kubernetes.io/default-container`) }}
        kubectl.kubernetes.io/default-container: "{{ index $containers 0 }}",
        {{- end }}
        {{- end }}
    {{- if .Values.pilot.cni.enabled }}
        {{- if eq .Values.pilot.cni.provider "multus" }}
        k8s.v1.cni.cncf.io/networks: '{{ appendMultusNetwork (index .ObjectMeta.Annotations `k8s.v1.cni.cncf.io/networks`) `default/istio-cni` }}',
        {{- end }}
        sidecar.istio.io/interceptionMode: "{{ annotation .ObjectMeta `sidecar.istio.io/interceptionMode` .ProxyConfig.InterceptionMode }}",
        {{ with annotation .ObjectMeta `traffic.sidecar.istio.io/includeOutboundIPRanges` .Values.global.proxy.includeIPRanges }}traffic.sidecar.istio.io/includeOutboundIPRanges: "{{.}}",{{ end }}
        {{ with annotation .ObjectMeta `traffic.sidecar.istio.io/excludeOutboundIPRanges` .Values.global.proxy.excludeOutboundIPRanges }}traffic.sidecar.istio.io/excludeOutboundIPRanges: "{{.}}",{{ end }}
        traffic.sidecar.istio.io/includeInboundPorts: "{{ annotation .ObjectMeta `traffic.sidecar.istio.io/includeInboundPorts` .Values.global.proxy.includeInboundPorts }}",
        traffic.sidecar.istio.io/excludeInboundPorts: "{{ excludeInboundPort (annotation .ObjectMeta `status.sidecar.istio.io/port` .Values.global.proxy.statusPort) (annotation .ObjectMeta `traffic.sidecar.istio.io/excludeInboundPorts` .Values.global.proxy.excludeInboundPorts) }}",
        {{ if or (isset .ObjectMeta.Annotations `traffic.sidecar.istio.io/includeOutboundPorts`) (ne (valueOrDefault .Values.global.proxy.includeOutboundPorts "") "") }}
        traffic.sidecar.istio.io/includeOutboundPorts: "{{ annotation .ObjectMeta `traffic.sidecar.istio.io/includeOutboundPorts` .Values.global.proxy.includeOutboundPorts }}",
        {{- end }}
        {{ if or (isset .ObjectMeta.Annotations `traffic.sidecar.istio.io/excludeOutboundPorts`) (ne .Values.global.proxy.excludeOutboundPorts "") }}
        traffic.sidecar.istio.io/excludeOutboundPorts: "{{ annotation .ObjectMeta `traffic.sidecar.istio.io/excludeOutboundPorts` .Values.global.proxy.excludeOutboundPorts }}",
        {{- end }}
        {{ with index .ObjectMeta.Annotations `traffic.sidecar.istio.io/kubevirtInterfaces` }}traffic.sidecar.istio.io/kubevirtInterfaces: "{{.}}",{{ end }}
        {{ with index .ObjectMeta.Annotations `istio.io/reroute-virtual-interfaces` }}istio.io/reroute-virtual-interfaces: "{{.}}",{{ end }}
        {{ with index .ObjectMeta.Annotations `traffic.sidecar.istio.io/excludeInterfaces` }}traffic.sidecar.istio.io/excludeInterfaces: "{{.}}",{{ end }}
    {{- end }}
      }
    spec:
      {{- $holdProxy := and
          (or .ProxyConfig.HoldApplicationUntilProxyStarts.GetValue .Values.global.proxy.holdApplicationUntilProxyStarts)
          (not $nativeSidecar) }}
      {{- $noInitContainer := and
          (eq (annotation .ObjectMeta `sidecar.istio.io/interceptionMode` .ProxyConfig.InterceptionMode) `NONE`)
          (not $nativeSidecar) }}
      {{ if $noInitContainer }}
      initContainers: []
      {{ else -}}
      initContainers:
      {{ if ne (annotation .ObjectMeta `sidecar.istio.io/interceptionMode` .ProxyConfig.InterceptionMode) `NONE` }}
      {{ if .Values.pilot.cni.enabled -}}
      - name: istio-validation
      {{ else -}}
      - name: istio-init
      {{ end -}}
      {{- if contains "/" (annotation .ObjectMeta `sidecar.istio.io/proxyImage` .Values.global.proxy_init.image) }}
        image: "{{ annotation .ObjectMeta `sidecar.istio.io/proxyImage` .Values.global.proxy_init.image }}"
      {{- else }}
        image: "{{ .ProxyImage }}"
      {{- end }}
        args:
        - istio-iptables
        - "-p"
        - {{ .MeshConfig.ProxyListenPort | default "15001" | quote }}
        - "-z"
        - {{ .MeshConfig.ProxyInboundListenPort | default "15006" | quote }}
        - "-u"
        - {{ if $tproxy }} "1337" {{ else }} {{ .ProxyUID | default "1337" | quote }} {{ end }}
        - "-m"
        - "{{ annotation .ObjectMeta `sidecar.istio.io/interceptionMode` .ProxyConfig.InterceptionMode }}"
        - "-i"
        - "{{ annotation .ObjectMeta `traffic.sidecar.istio.io/includeOutboundIPRanges` .Values.global.proxy.includeIPRanges }}"
        - "-x"
        - "{{ annotation .ObjectMeta `traffic.sidecar.istio.io/excludeOutboundIPRanges` .Values.global.proxy.excludeOutboundIPRanges }}"
        - "-b"
        - "{{ annotation .ObjectMeta `traffic.sidecar.istio.io/includeInboundPorts` .Values.global.proxy.includeInboundPorts }}"
        - "-d"
      {{- if excludeInboundPort (annotation .ObjectMeta `status.sidecar.istio.io/port` .Values.global.proxy.statusPort) (annotation .ObjectMeta `traffic.sidecar.istio.io/excludeInboundPorts` .Values.global.proxy.excludeInboundPorts) }}
        - "15090,15021,{{ excludeInboundPort (annotation .ObjectMeta `status.sidecar.istio.io/port` .Values.global.proxy.statusPort) (annotation .ObjectMeta `traffic.sidecar.istio.io/excludeInboundPorts` .Values.global.proxy.excludeInboundPorts) }}"
      {{- else }}
        - "15090,15021"
      {{- end }}
        {{ if or (isset .ObjectMeta.Annotations `traffic.sidecar.istio.io/includeOutboundPorts`) (ne (valueOrDefault .Values.global.proxy.includeOutboundPorts "") "") -}}
        - "-q"
        - "{{ annotation .ObjectMeta `traffic.sidecar.istio.io/includeOutboundPorts` .Values.global.proxy.includeOutboundPorts }}"
        {{ end -}}
        {{ if or (isset .ObjectMeta.Annotations `traffic.sidecar.istio.io/excludeOutboundPorts`) (ne (valueOrDefault .Values.global.proxy.excludeOutboundPorts "") "") -}}
        - "-o"
        - "{{ annotation .ObjectMeta `traffic.sidecar.istio.io/excludeOutboundPorts` .Values.global.proxy.excludeOutboundPorts }}"
        {{ end -}}
        {{ if (isset .ObjectMeta.Annotations `istio.io/reroute-virtual-interfaces`) -}}
        - "-k"
        - "{{ index .ObjectMeta.Annotations `istio.io/reroute-virtual-interfaces` }}"
        {{ else if (isset .ObjectMeta.Annotations `traffic.sidecar.istio.io/kubevirtInterfaces`) -}}
        - "-k"
        - "{{ index .ObjectMeta.Annotations `traffic.sidecar.istio.io/kubevirtInterfaces` }}"
        {{ end -}}
         {{ if (isset .ObjectMeta.Annotations `traffic.sidecar.istio.io/excludeInterfaces`) -}}
        - "-c"
        - "{{ index .ObjectMeta.Annotations `traffic.sidecar.istio.io/excludeInterfaces` }}"
        {{ end -}}
        - "--log_output_level={{ annotation .ObjectMeta `sidecar.istio.io/agentLogLevel` .Values.global.logging.level }}"
        {{ if .Values.global.logAsJson -}}
        - "--log_as_json"
        {{ end -}}
        {{ if .Values.pilot.cni.enabled -}}
        - "--run-validation"
        - "--skip-rule-apply"
        {{ else if .Values.global.proxy_init.forceApplyIptables -}}
        - "--force-apply"
        {{ end -}}
        {{ if .Values.global.nativeNftables -}}
        - "--native-nftables"
        {{ end -}}
        {{with .Values.global.imagePullPolicy }}imagePullPolicy: "{{.}}"{{end}}
      {{- if .ProxyConfig.ProxyMetadata }}
        env:
        {{- range $key, $value := .ProxyConfig.ProxyMetadata }}
        - name: {{ $key }}
          value: "{{ $value }}"
        {{- end }}
      {{- end }}
        resources:
      {{ template "resources" . }}
        securityContext:
          allowPrivilegeEscalation: {{ .Values.global.proxy.privileged }}
          privileged: {{ .Values.global.proxy.privileged }}
          capabilities:
        {{- if not .Values.pilot.cni.enabled }}
            add:
            - NET_ADMIN
            - NET_RAW
        {{- end }}
            drop:
            - ALL
        {{- if not .Values.pilot.cni.enabled }}
          readOnlyRootFilesystem: false
          runAsGroup: 0
          runAsNonRoot: false
          runAsUser: 0
        {{- else }}
          readOnlyRootFilesystem: true
          runAsGroup: {{ if $tproxy }} 1337 {{ else }} {{ .ProxyGID | default "1337" }} {{ end }}
          runAsUser: {{ if $tproxy }} 1337 {{ else }} {{ .ProxyUID | default "1337" }} {{ end }}
          runAsNonRoot: true
        {{- end }}
        {{- if .Values.global.proxy.seccompProfile }}
          seccompProfile:
        {{- toYaml .Values.global.proxy.seccompProfile | nindent 8 }}
        {{- end }}
      {{ end -}}
      {{ end -}}
      {{ if not $nativeSidecar }}
      containers:
      {{ end }}
      - name: istio-proxy
      {{- if contains "/" (annotation .ObjectMeta `sidecar.istio.io/proxyImage` .Values.global.proxy.image) }}
        image: "{{ annotation .ObjectMeta `sidecar.istio.io/proxyImage` .Values.global.proxy.image }}"
      {{- else }}
        image: "{{ .ProxyImage }}"
      {{- end }}
        {{ if $nativeSidecar }}restartPolicy: Always{{end}}
        ports:
        - containerPort: 15090
          protocol: TCP
          name: http-envoy-prom
        args:
        - proxy
        - sidecar
        - --domain
        - $(POD_NAMESPACE).svc.{{ .Values.global.proxy.clusterDomain }}
        - --proxyLogLevel={{ annotation .ObjectMeta `sidecar.istio.io/logLevel` .Values.global.proxy.logLevel }}
        - --proxyComponentLogLevel={{ annotation .ObjectMeta `sidecar.istio.io/componentLogLevel` .Values.global.proxy.componentLogLevel }}
        - --log_output_level={{ annotation .ObjectMeta `sidecar.istio.io/agentLogLevel` .Values.global.logging.level }}
      {{- if .Values.global.sts.servicePort }}
        - --stsPort={{ .Values.global.sts.servicePort }}
      {{- end }}
      {{- if .Values.global.logAsJson }}
        - --log_as_json
      {{- end }}
      {{- if .Values.global.proxy.outlierLogPath }}
        - --outlierLogPath={{ .Values.global.proxy.outlierLogPath }}
      {{- end}}
      {{- if .Values.global.proxy.lifecycle }}
        lifecycle:
          {{ toYaml .Values.global.proxy.lifecycle | indent 6 }}
      {{- else if $holdProxy }}
        lifecycle:
          postStart:
            exec:
              command:
              - pilot-agent
              - wait
      {{- else if $nativeSidecar }}
        {{- /* preStop is called when the pod starts shutdown. Initialize drain. We will get SIGTERM once applications are torn down. */}}
        lifecycle:
          preStop:
            exec:
              command:
              - pilot-agent
              - request
              - --debug-port={{(annotation .ObjectMeta `status.sidecar.istio.io/port` .Values.global.proxy.statusPort)}}
              - POST
              - drain
      {{- end }}
        env:
        {{- if eq .InboundTrafficPolicyMode "localhost" }}
        - name: REWRITE_PROBE_LEGACY_LOCALHOST_DESTINATION
          value: "true"
        {{- end }}
        - name: PILOT_CERT_PROVIDER
          value: {{ .Values.global.pilotCertProvider }}
        - name: CA_ADDR
        {{- if .Values.global.caAddress }}
          value: {{ .Values.global.caAddress }}
        {{- else }}
          value: istiod{{- if not (eq .Values.revision "") }}-{{ .Values.revision }}{{- end }}.{{ .Values.global.istioNamespace }}.svc:15012
        {{- end }}
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: INSTANCE_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: SERVICE_ACCOUNT
          valueFrom:
            fieldRef:
              fieldPath: spec.serviceAccountName
        - name: HOST_IP
          valueFrom:
            fieldRef:
              fieldPath: status.hostIP
        - name: ISTIO_CPU_LIMIT
          valueFrom:
            resourceFieldRef:
              resource: limits.cpu
        - name: PROXY_CONFIG
          value: |
                 {{ protoToJSON .ProxyConfig }}
        - name: ISTIO_META_POD_PORTS
          value: |-
            [
            {{- $first := true }}
            {{- range $index1, $c := .Spec.Containers }}
              {{- range $index2, $p := $c.Ports }}
                {{- if (structToJSON $p) }}
                {{if not $first}},{{end}}{{ structToJSON $p }}
                {{- $first = false }}
                {{- end }}
              {{- end}}
            {{- end}}
            ]
        - name: ISTIO_META_APP_CONTAINERS
          value: "{{ $containers | join \",\" }}"
        - name: GOMEMLIMIT
          valueFrom:
            resourceFieldRef:
              resource: limits.memory
        - name: GOMAXPROCS
          valueFrom:
            resourceFieldRef:
              resource: limits.cpu
        - name: ISTIO_META_CLUSTER_ID
          value: "{{ valueOrDefault .Values.global.multiCluster.clusterName `Kubernetes` }}"
        - name: ISTIO_META_INTERCEPTION_MODE
          value: "{{ .ProxyConfig.InterceptionMode.String }}"
        - name: ISTIO_META_WORKLOAD_NAME
          value: "{{ include "workloadName" . }}"
        - name: ISTIO_META_OWNER
          value: kubernetes://apis/{{ .TypeMeta.APIVersion }}/namespaces/{{ valueOrDefault .DeploymentMeta.Namespace `default` }}/{{ toLower .TypeMeta.Kind}}s/{{ .DeploymentMeta.Name }}
