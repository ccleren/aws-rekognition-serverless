# Infraestructura (Terraform)

```
infrastructure/
├── bootstrap/             # se aplica una vez, en local, con estado local
├── environments/
│   └── prod/              # raíz que despliega GitHub Actions (estado remoto en S3)
└── modules/
    ├── storage/           # buckets data + frontend: bloqueo público, SSE-S3, TLS obligatorio, ciclo de vida
    ├── lambda-function/   # módulo genérico: rol + política + log group + función + zip
    ├── rekognition-sns/   # topic de finalización, rol de servicio de Rekognition, suscripción
    ├── api-gateway/       # HTTP API, ruta POST /upload, CORS, throttling, access logs
    └── cloudfront/        # distribución, OAC, comportamientos, response headers policy (CSP)
```

## Orden de uso

1. **`bootstrap/`** — bucket de estado (versionado, cifrado, privado, `use_lockfile`), proveedor OIDC de GitHub y rol de despliegue. Ver el [README principal](../README.md#1-bootstrap-una-vez-en-local).
2. **`environments/prod/`** — conecta los módulos. Backend S3 con configuración parcial:

   ```bash
   terraform init -backend-config="bucket=<TF_STATE_BUCKET>"
   ```

   El `.terraform.lock.hcl` de cada raíz **se versiona** para fijar las versiones de los providers.

## Notas de diseño

- **Ciclo bucket → Lambda → notificación.** La notificación de S3 necesita el ARN de Process, y la política de Process necesita el ARN del bucket. Se rompe calculando el nombre del bucket en el entorno (`project_name` + sufijo aleatorio) y definiendo la notificación a nivel de entorno, con `depends_on` del permiso de invocación.
- **Log groups gestionados por Terraform** con retención, para que `terraform destroy` no deje grupos huérfanos.
- **`force_destroy = true`** en los buckets para poder destruir la demo; desactívalo con datos reales.

## Comprobaciones locales (no crean recursos)

```bash
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
```
