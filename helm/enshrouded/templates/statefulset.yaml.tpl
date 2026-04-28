apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ include "enshrouded.fullname" . }}
  namespace: {{ .Values.namespace }}
  labels:
{{ include "enshrouded.labels" . | indent 4 }}
spec:
  serviceName: {{ include "enshrouded.fullname" . }}
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ include "enshrouded.name" . }}
      app.kubernetes.io/instance: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ include "enshrouded.name" . }}
        app.kubernetes.io/instance: {{ .Release.Name }}
    spec:
      terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
      securityContext:
        runAsUser: {{ .Values.securityContext.runAsUser }}
        runAsGroup: {{ .Values.securityContext.runAsGroup }}
        fsGroup: {{ .Values.securityContext.fsGroup }}
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
{{ toYaml . | indent 8 }}
      {{- end }}
      {{- if .Values.nodeSelector }}
      nodeSelector:
{{ toYaml .Values.nodeSelector | indent 8 }}
      {{- end }}
      containers:
        - name: enshrouded
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          securityContext:
{{ toYaml .Values.containerSecurityContext | indent 12 }}
          env:
            - name: ENSHROUDED_CONFIG
              value: {{ .Values.serverConfig.path | quote }}
            - name: ENSHROUDED_CONFIG_MODE
              value: {{ .Values.serverConfig.mode | quote }}
            - name: SAVE_IMPORT_MODE
              value: {{ .Values.saveImport.mode | quote }}
            - name: SAVE_IMPORT_PORT
              value: {{ .Values.saveImport.port | quote }}
            - name: SAVE_IMPORT_BIND
              value: {{ .Values.saveImport.bind | quote }}
            - name: SAVE_IMPORT_TIMEOUT_SECONDS
              value: {{ .Values.saveImport.timeoutSeconds | quote }}
            - name: AUTO_UPDATE_ON_BOOT
              value: {{ ternary "1" "0" .Values.serverUpdate.autoUpdateOnBoot | quote }}
            {{- if eq .Values.serverConfig.mode "managed" }}
            - name: ENSHROUDED_MANAGED_CONFIG_TEMPLATE
              value: "/etc/enshrouded/managed/enshrouded_server.json"
            {{- if .Values.serverConfig.passwordSecret.name }}
            - name: ENSHROUDED_MANAGED_CONFIG_PASSWORDS
              value: "/etc/enshrouded/secrets/user-group-passwords.json"
            {{- end }}
            {{- else if eq .Values.serverConfig.mode "mutable" }}
            - name: EXTERNAL_CONFIG
              value: "1"
            {{- else }}
            {{- fail (printf "unsupported serverConfig.mode %q (expected managed or mutable)" .Values.serverConfig.mode) }}
            {{- end }}
          ports:
            - name: game-udp
              containerPort: {{ .Values.service.gamePort }}
              {{- if .Values.service.useHostPorts }}
              hostPort: {{ .Values.service.gamePort }}
              {{- end }}
              protocol: UDP
            - name: query-udp
              containerPort: {{ .Values.service.queryPort }}
              {{- if .Values.service.useHostPorts }}
              hostPort: {{ .Values.service.queryPort }}
              {{- end }}
              protocol: UDP
            {{- if .Values.service.saveImport.enabled }}
            - name: import-ui
              containerPort: {{ .Values.service.saveImport.port }}
              protocol: TCP
            {{- end }}
          resources:
{{ toYaml .Values.resources | indent 12 }}
          volumeMounts:
            - name: data
              mountPath: /home/steam
              subPath: {{ .Values.persistence.subPath | quote }}
            {{- if eq .Values.serverConfig.mode "managed" }}
            - name: managed-config-template
              mountPath: /etc/enshrouded/managed
              readOnly: true
            {{- if .Values.serverConfig.passwordSecret.name }}
            - name: managed-config-passwords
              mountPath: /etc/enshrouded/secrets
              readOnly: true
            {{- end }}
            {{- end }}
        {{- if .Values.statsApi.enabled }}
        - name: enshrouded-stats-api
          image: "{{ .Values.statsApi.image.repository }}:{{ .Values.statsApi.image.tag }}"
          imagePullPolicy: {{ .Values.statsApi.image.pullPolicy }}
          securityContext:
{{ toYaml .Values.containerSecurityContext | indent 12 }}
          env:
            - name: ENSHROUDED_API_BIND
              value: {{ .Values.statsApi.bind | quote }}
            - name: ENSHROUDED_API_PORT
              value: {{ .Values.statsApi.port | quote }}
            - name: ENSHROUDED_API_HOST
              value: {{ .Values.statsApi.targetHost | quote }}
            - name: ENSHROUDED_API_TIMEOUT
              value: {{ .Values.statsApi.timeoutSeconds | quote }}
            - name: ENSHROUDED_API_RETRIES
              value: {{ .Values.statsApi.retries | quote }}
            - name: ENSHROUDED_API_CACHE_TTL
              value: {{ .Values.statsApi.cacheTtlSeconds | quote }}
            - name: ENSHROUDED_API_EXPOSE_LOCAL_STATS
              value: {{ ternary "1" "0" .Values.statsApi.exposeLocalStats | quote }}
            - name: ENSHROUDED_API_GAME_PORT
              value: {{ .Values.statsApi.lanePorts.gamePort | quote }}
            - name: ENSHROUDED_API_STEAM_QUERY_PORT
              value: {{ .Values.statsApi.lanePorts.steamQuery | quote }}
            - name: ENSHROUDED_API_SERVER_CONFIG_PATH
              value: {{ .Values.serverConfig.path | quote }}
            {{- with .Values.statsApi.extraEnv }}
{{ toYaml . | indent 12 }}
            {{- end }}
          ports:
            - name: stats-api
              containerPort: {{ .Values.statsApi.port }}
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /healthz
              port: stats-api
            initialDelaySeconds: 3
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: stats-api
            initialDelaySeconds: 10
            periodSeconds: 20
          resources:
{{ toYaml .Values.statsApi.resources | indent 12 }}
          volumeMounts:
            - name: data
              mountPath: /home/steam
              subPath: {{ .Values.persistence.subPath | quote }}
              readOnly: true
        {{- end }}
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: {{ include "enshrouded.pvcName" . }}
        {{- if eq .Values.serverConfig.mode "managed" }}
        - name: managed-config-template
          configMap:
            name: {{ include "enshrouded.managedConfigTemplateName" . }}
        {{- if .Values.serverConfig.passwordSecret.name }}
        - name: managed-config-passwords
          secret:
            secretName: {{ .Values.serverConfig.passwordSecret.name }}
            items:
              - key: {{ .Values.serverConfig.passwordSecret.key | quote }}
                path: user-group-passwords.json
        {{- end }}
        {{- end }}
