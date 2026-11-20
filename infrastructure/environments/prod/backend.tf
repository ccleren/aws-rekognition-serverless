# Estado remoto en el bucket creado por infrastructure/bootstrap.
# Configuración parcial: el nombre del bucket no se versiona y se pasa al iniciar:
#
#   terraform init -backend-config="bucket=<TF_STATE_BUCKET>"
#
# Si el bucket de estado está en otra región, añade -backend-config="region=<región>".
# El bloqueo es nativo de S3 (use_lockfile): no hace falta tabla de DynamoDB.

terraform {
  backend "s3" {
    key          = "aws-rekognition-serverless/prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
