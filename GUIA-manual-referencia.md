# Guía manual de referencia — Vision Lab (Rekognition serverless)

> **Para qué sirve esta guía.** Explica, paso a paso, cómo montar a mano (consola de AWS + AWS CLI) la misma arquitectura que despliega Terraform. Es material **educativo**: sirve para entender qué crea cada recurso y por qué. **El método de despliegue del proyecto es Terraform + GitHub Actions**, no esta guía.
>
> **Reglas de esta guía**
> - Los valores entre `<...>` son marcadores: sustitúyelos por los tuyos. No pegues valores reales en el repositorio.
> - No se crean claves de acceso de larga duración. Usa el inicio de sesión de tu usuario (IAM Identity Center o un usuario con MFA) o credenciales temporales.
> - Usa una cuenta de pruebas. Rekognition y CloudFront facturan por uso; al final hay una sección de limpieza.

---

## 0. Requisitos previos

- Cuenta de AWS y AWS CLI v2 configurada (`aws sts get-caller-identity` debe responder).
- Región donde Rekognition esté disponible (por defecto `us-east-1`).
- `zip` instalado y un par de archivos de prueba: una imagen JPEG/PNG y un MP4 con códec **H.264** de menos de 4 MiB.

Variables de trabajo (cada vez que abras una terminal nueva):

```bash
export AWS_REGION=us-east-1
export PROJECT=vision-lab
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export SUFFIX=$(openssl rand -hex 4)          # evita colisiones de nombres de bucket
export DATA_BUCKET=${PROJECT}-data-${SUFFIX}
export FRONT_BUCKET=${PROJECT}-frontend-${SUFFIX}
```

---

## 1. Buckets de S3 (privados)

### 1.1 Crear los dos buckets

```bash
# En us-east-1 NO se indica LocationConstraint; en otras regiones sí.
aws s3api create-bucket --bucket $DATA_BUCKET  --region $AWS_REGION
aws s3api create-bucket --bucket $FRONT_BUCKET --region $AWS_REGION
```

Fuera de `us-east-1` añade `--create-bucket-configuration LocationConstraint=$AWS_REGION`.

### 1.2 Bloqueo de acceso público y cifrado (ambos buckets)

```bash
for B in $DATA_BUCKET $FRONT_BUCKET; do
  aws s3api put-public-access-block --bucket $B --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket $B --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
done
```

**Por qué:** ningún bucket es público. El acceso desde internet se hará solo a través de CloudFront (sección 7).

### 1.3 Ciclo de vida del bucket de datos (borrado automático a 1 día)

```bash
cat > lifecycle.json <<'EOF'
{
  "Rules": [
    { "ID": "expire-input",        "Status": "Enabled", "Filter": {"Prefix": "input/"},        "Expiration": {"Days": 1} },
    { "ID": "expire-output",       "Status": "Enabled", "Filter": {"Prefix": "output/"},       "Expiration": {"Days": 1} },
    { "ID": "expire-output-video", "Status": "Enabled", "Filter": {"Prefix": "output-video/"}, "Expiration": {"Days": 1} },
    { "ID": "abort-multipart",     "Status": "Enabled", "Filter": {"Prefix": ""},
      "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 1} }
  ]
}
EOF
aws s3api put-bucket-lifecycle-configuration --bucket $DATA_BUCKET --lifecycle-configuration file://lifecycle.json
```

**Por qué:** 1 día es la granularidad mínima de S3. Limita coste y exposición de datos de usuarios.

---

## 2. Roles de IAM (un rol por función)

Política de confianza común para Lambda:

```bash
cat > trust-lambda.json <<'EOF'
{ "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole" }] }
EOF
```

### 2.1 Rol de la Lambda Upload

```bash
aws iam create-role --role-name ${PROJECT}-upload --assume-role-policy-document file://trust-lambda.json

cat > upload-policy.json <<'EOF'
{ "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::<DATA_BUCKET>/input/*" },
    { "Effect": "Allow", "Action": ["logs:CreateLogStream","logs:PutLogEvents"],
      "Resource": "arn:aws:logs:<REGION>:<ACCOUNT_ID>:log-group:/aws/lambda/<PROJECT>-upload:*" }
  ] }
EOF
sed -i "s|<DATA_BUCKET>|$DATA_BUCKET|g; s|<REGION>|$AWS_REGION|g; s|<ACCOUNT_ID>|$ACCOUNT_ID|g; s|<PROJECT>|$PROJECT|g" upload-policy.json
aws iam put-role-policy --role-name ${PROJECT}-upload --policy-name inline --policy-document file://upload-policy.json
```

### 2.2 Rol de servicio de Rekognition (para publicar en SNS)

Antes crea el topic (sección 3) y ten a mano su ARN en `$TOPIC_ARN`.

```bash
cat > trust-rekognition.json <<'EOF'
{ "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow",
    "Principal": {"Service": "rekognition.amazonaws.com"},
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": {"aws:SourceAccount": "<ACCOUNT_ID>"},
      "ArnLike": {"aws:SourceArn": "arn:aws:rekognition:<REGION>:<ACCOUNT_ID>:*"} } }] }
EOF
sed -i "s|<ACCOUNT_ID>|$ACCOUNT_ID|g; s|<REGION>|$AWS_REGION|g" trust-rekognition.json
aws iam create-role --role-name ${PROJECT}-rekognition-sns --assume-role-policy-document file://trust-rekognition.json

cat > rek-policy.json <<'EOF'
{ "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow", "Action": "sns:Publish", "Resource": "<TOPIC_ARN>" }] }
EOF
sed -i "s|<TOPIC_ARN>|$TOPIC_ARN|g" rek-policy.json
aws iam put-role-policy --role-name ${PROJECT}-rekognition-sns --policy-name inline --policy-document file://rek-policy.json
export REK_ROLE_ARN=$(aws iam get-role --role-name ${PROJECT}-rekognition-sns --query Role.Arn --output text)
```

**Por qué:** las condiciones `aws:SourceAccount`/`aws:SourceArn` evitan el problema del "confused deputy": solo Rekognition actuando por tu cuenta puede usar este rol.

### 2.3 Rol de la Lambda Process

```bash
aws iam create-role --role-name ${PROJECT}-process --assume-role-policy-document file://trust-lambda.json

cat > process-policy.json <<'EOF'
{ "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::<DATA_BUCKET>/input/*" },
    { "Effect": "Allow", "Action": "s3:PutObject",
      "Resource": ["arn:aws:s3:::<DATA_BUCKET>/output/*", "arn:aws:s3:::<DATA_BUCKET>/output-video/*"] },
    { "Effect": "Allow", "Action": ["rekognition:DetectLabels","rekognition:StartLabelDetection"],
      "Resource": "*" },
    { "Effect": "Allow", "Action": "iam:PassRole",
      "Resource": "<REK_ROLE_ARN>",
      "Condition": {"StringEquals": {"iam:PassedToService": "rekognition.amazonaws.com"}} },
    { "Effect": "Allow", "Action": ["logs:CreateLogStream","logs:PutLogEvents"],
      "Resource": "arn:aws:logs:<REGION>:<ACCOUNT_ID>:log-group:/aws/lambda/<PROJECT>-process:*" }
  ] }
EOF
sed -i "s|<DATA_BUCKET>|$DATA_BUCKET|g; s|<REK_ROLE_ARN>|$REK_ROLE_ARN|g; s|<REGION>|$AWS_REGION|g; s|<ACCOUNT_ID>|$ACCOUNT_ID|g; s|<PROJECT>|$PROJECT|g" process-policy.json
aws iam put-role-policy --role-name ${PROJECT}-process --policy-name inline --policy-document file://process-policy.json
```

**Por qué:** las acciones de Rekognition usadas no admiten recurso específico, por eso `Resource: "*"`. `iam:PassRole` está limitado a un único rol y a un único servicio.

### 2.4 Rol de la Lambda Video Result

```bash
aws iam create-role --role-name ${PROJECT}-video-result --assume-role-policy-document file://trust-lambda.json

cat > video-policy.json <<'EOF'
{ "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "rekognition:GetLabelDetection", "Resource": "*" },
    { "Effect": "Allow", "Action": "s3:PutObject", "Resource": "arn:aws:s3:::<DATA_BUCKET>/output-video/*" },
    { "Effect": "Allow", "Action": ["logs:CreateLogStream","logs:PutLogEvents"],
      "Resource": "arn:aws:logs:<REGION>:<ACCOUNT_ID>:log-group:/aws/lambda/<PROJECT>-video-result:*" }
  ] }
EOF
sed -i "s|<DATA_BUCKET>|$DATA_BUCKET|g; s|<REGION>|$AWS_REGION|g; s|<ACCOUNT_ID>|$ACCOUNT_ID|g; s|<PROJECT>|$PROJECT|g" video-policy.json
aws iam put-role-policy --role-name ${PROJECT}-video-result --policy-name inline --policy-document file://video-policy.json
```

> Los log groups se crean antes de las Lambdas (sección 4.1) para poder fijar la retención. La política de logs solo necesita `CreateLogStream` y `PutLogEvents` porque el grupo ya existe.

---

## 3. Topic de SNS

```bash
export TOPIC_ARN=$(aws sns create-topic --name ${PROJECT}-video-done --query TopicArn --output text)
echo $TOPIC_ARN
```

> Si ya hiciste la sección 2.2 sin el topic, vuelve a ella ahora. El orden real es: **3 → 2.2 → 2.3 → 2.4**.

---

## 4. Funciones Lambda

### 4.1 Log groups con retención

```bash
for F in upload process video-result; do
  aws logs create-log-group --log-group-name /aws/lambda/${PROJECT}-${F}
  aws logs put-retention-policy --log-group-name /aws/lambda/${PROJECT}-${F} --retention-in-days 14
done
```

### 4.2 Empaquetar y crear

El código está en `backend/<función>/handler.py`. Cada zip lleva `handler.py` en la raíz.

```bash
for F in upload process video_result; do (cd backend/$F && zip -q ../../$F.zip handler.py); done

aws lambda create-function --function-name ${PROJECT}-upload \
  --runtime python3.12 --handler handler.handler --zip-file fileb://upload.zip \
  --role arn:aws:iam::$ACCOUNT_ID:role/${PROJECT}-upload --timeout 15 --memory-size 256 \
  --environment "Variables={BUCKET_NAME=$DATA_BUCKET,MAX_UPLOAD_BYTES=4194304}"

aws lambda create-function --function-name ${PROJECT}-process \
  --runtime python3.12 --handler handler.handler --zip-file fileb://process.zip \
  --role arn:aws:iam::$ACCOUNT_ID:role/${PROJECT}-process --timeout 30 --memory-size 256 \
  --environment "Variables={BUCKET_NAME=$DATA_BUCKET,SNS_TOPIC_ARN=$TOPIC_ARN,REKOGNITION_ROLE_ARN=$REK_ROLE_ARN,MIN_CONFIDENCE=75,MAX_LABELS=25}"

aws lambda create-function --function-name ${PROJECT}-video-result \
  --runtime python3.12 --handler handler.handler --zip-file fileb://video_result.zip \
  --role arn:aws:iam::$ACCOUNT_ID:role/${PROJECT}-video-result --timeout 60 --memory-size 256 \
  --environment "Variables={BUCKET_NAME=$DATA_BUCKET}"
```

Si la creación falla con "role cannot be assumed", espera 10–15 s (propagación de IAM) y repite.

### 4.3 Permisos de invocación (quién puede llamar a cada Lambda)

```bash
# S3 -> Process (con source_account)
aws lambda add-permission --function-name ${PROJECT}-process --statement-id s3-invoke \
  --action lambda:InvokeFunction --principal s3.amazonaws.com \
  --source-arn arn:aws:s3:::$DATA_BUCKET --source-account $ACCOUNT_ID

# SNS -> Video Result
aws lambda add-permission --function-name ${PROJECT}-video-result --statement-id sns-invoke \
  --action lambda:InvokeFunction --principal sns.amazonaws.com --source-arn $TOPIC_ARN
```

(El permiso de API Gateway → Upload se añade en la sección 6, cuando exista el API.)

---

## 5. Conectar eventos

### 5.1 S3 → Process (solo prefijo `input/`)

```bash
cat > notification.json <<EOF
{ "LambdaFunctionConfigurations": [{
    "LambdaFunctionArn": "arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:${PROJECT}-process",
    "Events": ["s3:ObjectCreated:*"],
    "Filter": {"Key": {"FilterRules": [{"Name": "prefix", "Value": "input/"}]}} }] }
EOF
aws s3api put-bucket-notification-configuration --bucket $DATA_BUCKET --notification-configuration file://notification.json
```

**Por qué el prefijo:** Process escribe en `output/` y `output-video/`; sin filtro se dispararía a sí misma en bucle.

### 5.2 SNS → Video Result

```bash
aws sns subscribe --topic-arn $TOPIC_ARN --protocol lambda \
  --notification-endpoint arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:${PROJECT}-video-result
```

---

## 6. API Gateway (HTTP API)

El dominio de CloudFront aún no existe. Crea primero la distribución (sección 7) o configura CORS con un valor provisional y corrígelo después (paso 6.4).

### 6.1 Crear API e integración

```bash
export API_ID=$(aws apigatewayv2 create-api --name ${PROJECT}-api --protocol-type HTTP \
  --cors-configuration AllowOrigins="https://<CLOUDFRONT_DOMAIN>",AllowMethods=POST,AllowHeaders=content-type,MaxAge=3600 \
  --query ApiId --output text)

export INT_ID=$(aws apigatewayv2 create-integration --api-id $API_ID --integration-type AWS_PROXY \
  --integration-uri arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:${PROJECT}-upload \
  --payload-format-version 2.0 --query IntegrationId --output text)

aws apigatewayv2 create-route --api-id $API_ID --route-key 'POST /upload' --target integrations/$INT_ID
```

### 6.2 Stage con límite de peticiones

```bash
aws apigatewayv2 create-stage --api-id $API_ID --stage-name '$default' --auto-deploy \
  --default-route-settings ThrottlingRateLimit=5,ThrottlingBurstLimit=10
```

### 6.3 Permiso API Gateway → Upload

```bash
aws lambda add-permission --function-name ${PROJECT}-upload --statement-id apigw-invoke \
  --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT_ID:$API_ID/*/POST/upload"

export API_URL=$(aws apigatewayv2 get-api --api-id $API_ID --query ApiEndpoint --output text)
```

### 6.4 Corregir CORS cuando conozcas el dominio de CloudFront

```bash
aws apigatewayv2 update-api --api-id $API_ID \
  --cors-configuration AllowOrigins="https://$CF_DOMAIN",AllowMethods=POST,AllowHeaders=content-type,MaxAge=3600
```

> Los access logs del API son opcionales en la guía manual (consola: API → Monitor → Logging). En Terraform sí van incluidos.

---

## 7. CloudFront con OAC (consola)

Esta parte es más cómoda en la consola.

1. **Origin access control (OAC):** CloudFront → *Origin access* → *Create control setting*: tipo **S3**, firma **Sign requests**. Crea uno (sirve para ambos orígenes).
2. **Crear distribución** (*Create distribution*):
   - **Origen 1:** bucket `$FRONT_BUCKET` (dominio regional, no el de "website"), acceso **Origin access control** con el OAC anterior. *Default root object:* `index.html`.
   - **Origen 2:** bucket `$DATA_BUCKET`, mismo OAC.
   - **Comportamiento por defecto** → origen 1, redirigir HTTP a HTTPS, política de caché **CachingOptimized**.
   - **Comportamiento `output/*`** → origen 2, política de caché **CachingDisabled**.
   - **Comportamiento `output-video/*`** → origen 2, política de caché **CachingDisabled**.
   - **Clase de precio:** *Use only North America and Europe* (`PriceClass_100`).
3. **Páginas de error personalizadas:** crea una para **403** y otra para **404** con *Error caching minimum TTL* = **0** y **sin** personalizar la respuesta. Sin esto, CloudFront recuerda unos segundos el "aún no existe" y el polling parece bloqueado.
4. **Response headers policy:** *Policies → Response headers → Create*. Activa HSTS, `X-Content-Type-Options`, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin` y una **CSP personalizada** (la del README, *Decisiones de diseño → CSP final*; en el montaje manual puedes poner en `connect-src` el `<API_URL>` exacto en lugar del comodín). Asóciala al comportamiento por defecto.
5. Anota el **ID de la distribución** y su dominio:

```bash
export DIST_ID=<DISTRIBUTION_ID>
export CF_DOMAIN=$(aws cloudfront get-distribution --id $DIST_ID --query Distribution.DomainName --output text)
```

### 7.1 Políticas de bucket (permiten leer solo a esta distribución)

Cuando creas el origen con OAC, la consola ofrece copiar la política. Equivalente por CLI:

```bash
cat > front-policy.json <<'EOF'
{ "Version": "2012-10-17",
  "Statement": [
    { "Sid": "AllowCloudFrontRead", "Effect": "Allow",
      "Principal": {"Service": "cloudfront.amazonaws.com"},
      "Action": "s3:GetObject", "Resource": "arn:aws:s3:::<FRONT_BUCKET>/*",
      "Condition": {"StringEquals": {"AWS:SourceArn": "arn:aws:cloudfront::<ACCOUNT_ID>:distribution/<DIST_ID>"}} },
    { "Sid": "DenyInsecureTransport", "Effect": "Deny", "Principal": "*",
      "Action": "s3:*", "Resource": ["arn:aws:s3:::<FRONT_BUCKET>", "arn:aws:s3:::<FRONT_BUCKET>/*"],
      "Condition": {"Bool": {"aws:SecureTransport": "false"}} }
  ] }
EOF
sed -i "s|<FRONT_BUCKET>|$FRONT_BUCKET|g; s|<ACCOUNT_ID>|$ACCOUNT_ID|g; s|<DIST_ID>|$DIST_ID|g" front-policy.json
aws s3api put-bucket-policy --bucket $FRONT_BUCKET --policy file://front-policy.json
```

Para el bucket de datos la política es igual, pero el permiso de lectura se limita a **`output/*` y `output-video/*`** (nunca `input/`):

```bash
cat > data-policy.json <<'EOF'
{ "Version": "2012-10-17",
  "Statement": [
    { "Sid": "AllowCloudFrontReadResults", "Effect": "Allow",
      "Principal": {"Service": "cloudfront.amazonaws.com"},
      "Action": "s3:GetObject",
      "Resource": ["arn:aws:s3:::<DATA_BUCKET>/output/*", "arn:aws:s3:::<DATA_BUCKET>/output-video/*"],
      "Condition": {"StringEquals": {"AWS:SourceArn": "arn:aws:cloudfront::<ACCOUNT_ID>:distribution/<DIST_ID>"}} },
    { "Sid": "DenyInsecureTransport", "Effect": "Deny", "Principal": "*",
      "Action": "s3:*", "Resource": ["arn:aws:s3:::<DATA_BUCKET>", "arn:aws:s3:::<DATA_BUCKET>/*"],
      "Condition": {"Bool": {"aws:SecureTransport": "false"}} }
  ] }
EOF
sed -i "s|<DATA_BUCKET>|$DATA_BUCKET|g; s|<ACCOUNT_ID>|$ACCOUNT_ID|g; s|<DIST_ID>|$DIST_ID|g" data-policy.json
aws s3api put-bucket-policy --bucket $DATA_BUCKET --policy file://data-policy.json
```

Vuelve ahora al paso 6.4 para fijar el CORS del API con `$CF_DOMAIN`.

---

## 8. Subir la web

### 8.1 `config.js` (no se versiona)

```bash
cat > config.js <<EOF
window.APP_CONFIG = {
  APP_NAME: "Vision Lab",
  API_URL: "$API_URL",
  RESULTS_BASE_URL: "https://$CF_DOMAIN",
  MAX_UPLOAD_BYTES: 4194304,
  MIN_CONFIDENCE: 75,
  POLL_INITIAL_DELAY_MS: 1000,
  POLL_MAX_DELAY_MS: 4000,
  POLL_IMAGE_TIMEOUT_MS: 60000,
  POLL_VIDEO_TIMEOUT_MS: 900000,
  DATA_RETENTION_HOURS: 24
};
EOF
```

> Son las mismas claves que genera Terraform (README, sección *`config.js`*). Solo `API_URL`, `RESULTS_BASE_URL` y `MAX_UPLOAD_BYTES` son obligatorias; el resto tiene valores por defecto en el frontend.

### 8.2 Subir y refrescar caché

```bash
aws s3 sync frontend/ s3://$FRONT_BUCKET --delete --exclude config.js
aws s3 cp config.js s3://$FRONT_BUCKET/config.js --cache-control no-cache --content-type application/javascript
aws cloudfront create-invalidation --distribution-id $DIST_ID --paths '/*'
echo "https://$CF_DOMAIN"
```

---

## 9. Verificación

1. **Web:** abre `https://<CLOUDFRONT_DOMAIN>`; debe cargar la interfaz.
2. **Privacidad del bucket:** `curl -I https://$FRONT_BUCKET.s3.$AWS_REGION.amazonaws.com/index.html` debe devolver **403**.
3. **`input/` no expuesto:** una URL `https://$CF_DOMAIN/input/<archivo>` debe devolver 403/404.
4. **Imagen:** sube una imagen desde la web; en 2–10 s aparecen etiquetas y cajas.
5. **Vídeo:** sube un MP4 H.264 pequeño; tarda de decenas de segundos a unos minutos.
6. **Tipo no válido:** la web rechaza un `.txt` antes de subirlo. Para comprobar el API: `echo hola > notas.txt && curl -s -X POST --data-binary @notas.txt "$API_URL/upload"` debe responder 400 `{"error": "unsupported_type"}`.
7. **Logs:** `aws logs tail /aws/lambda/${PROJECT}-process --since 10m`.
8. **Expiración:** pasadas ~24–48 h, los objetos de `input/` y los resultados han desaparecido.

---

## 10. Limpieza (para no pagar de más)

Orden recomendado:

```bash
aws cloudfront get-distribution-config --id $DIST_ID   # 1) deshabilita la distribución (consola: Disable) y espera a que termine; 2) bórrala
aws apigatewayv2 delete-api --api-id $API_ID
aws lambda delete-function --function-name ${PROJECT}-upload
aws lambda delete-function --function-name ${PROJECT}-process
aws lambda delete-function --function-name ${PROJECT}-video-result
aws sns delete-topic --topic-arn $TOPIC_ARN
for F in upload process video-result; do aws logs delete-log-group --log-group-name /aws/lambda/${PROJECT}-$F; done
for R in upload process video-result rekognition-sns; do
  aws iam delete-role-policy --role-name ${PROJECT}-$R --policy-name inline
  aws iam delete-role --role-name ${PROJECT}-$R
done
aws s3 rb s3://$DATA_BUCKET  --force
aws s3 rb s3://$FRONT_BUCKET --force
```

También borra la política y el OAC de CloudFront (consola) y la response headers policy. Con Terraform todo esto es `terraform destroy`.

---

## 11. Problemas habituales

| Síntoma | Causa probable | Solución |
|---|---|---|
| `create-function`: "role cannot be assumed" | Propagación de IAM | Esperar 10–15 s y repetir |
| El navegador bloquea la subida (CORS) | `AllowOrigins` no coincide con el dominio de CloudFront | Revisar 6.4; debe ser `https://` sin barra final |
| El polling no termina aunque el resultado existe | Error 403/404 cacheado por CloudFront | TTL 0 en las páginas de error (sección 7, paso 3) |
| Imagen subida pero sin resultado | Process no se activó o falló | Revisar notificación S3 (5.1), permiso `s3-invoke`, logs de Process |
| Vídeo en `FAILED` / `unsupported_video_codec` | Códec no compatible | Usar MP4 con H.264 |
| `AccessDenied` en `StartLabelDetection` | Falta `iam:PassRole` o confianza del rol de Rekognition | Revisar 2.2 y 2.3 |
| Vídeo analizado pero Video Result no se ejecuta | Suscripción SNS o permiso `sns-invoke` ausente | Revisar 4.3 y 5.2 |
| 413 / 400 al subir | Archivo > límite | Reducir a < 4 MiB |
| Nuevos objetos no disparan nada tras reconfigurar | Notificación sobrescrita | Rehacer 5.1 (el comando reemplaza la configuración completa) |

---

## 12. Manual frente a Terraform

| Aspecto | Manual (esta guía) | Terraform + Actions |
|---|---|---|
| Reproducibilidad | Depende de seguir los pasos | Total y versionada |
| Orden de dependencias | Lo gestionas tú (ver nota 2.2/3) | Lo resuelve el grafo |
| Revisión de cambios | Ninguna | `terraform plan` + aprobación |
| Credenciales | Tu sesión local | OIDC, sin claves estáticas |
| Limpieza | Muchos comandos y riesgo de dejar recursos | `terraform destroy` |
| Valor | Entender cada pieza | Despliegue real del proyecto |
