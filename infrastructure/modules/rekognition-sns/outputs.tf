output "topic_arn" {
  description = "Topic al que Rekognition publica la finalización (NotificationChannel.SNSTopicArn)."
  value       = aws_sns_topic.video_done.arn
}

output "rekognition_role_arn" {
  description = "Rol de servicio de Rekognition (NotificationChannel.RoleArn). Process necesita iam:PassRole sobre él."
  value       = aws_iam_role.rekognition.arn
}
