# Each of the three instances (edge/app/worker, ec2.tf) builds its own piece
# from source at boot (templates/user_data-*.sh.tpl) when its own compiled
# artifact hasn't been published to S3 yet (iam.tf's ReadWriteOwnBinaryCache)
# — this is how each gets the source to build from. One shared archive, not
# three: the frontend build depends on a Go codegen step that needs the
# WHOLE repo regardless of which piece a given instance is building. No git
# clone: no instance depends on a code host being reachable, and this stays
# inside the same trust boundary as the config object already in this
# bucket (s3.tf).

locals {
  # Reuse the repo's own Docker build-context exclusions instead of
  # maintaining a second list that WILL drift from it — this archive
  # becomes the same Dockerfile's build context again, on the instance.
  dockerignore_excludes = [
    for line in split("\n", file("${var.margince_source_dir}/.dockerignore")) :
    trimspace(line) if trimspace(line) != "" && !startswith(trimspace(line), "#")
  ]

  # On top of .dockerignore's list: this archive lands in a persistent,
  # versioned S3 bucket, not a transient local build context, so anything
  # that must never persist there even briefly is excluded here too —
  # local Terraform state/vars (this repo's own tree, if ever run in place)
  # and this session's own worktree debris.
  source_excludes = concat(local.dockerignore_excludes, [
    ".claude",
    "**/.terraform",
    "**/*.tfstate",
    "**/*.tfstate.backup",
    "deploy/terraform/**/terraform.tfvars",
    "deploy/terraform/**/*.auto.tfvars",
  ])
}

data "archive_file" "source" {
  type        = "zip"
  source_dir  = var.margince_source_dir
  output_path = "${path.module}/.terraform/source-archives/${var.image_tag}.zip"
  excludes    = local.source_excludes
}

resource "aws_s3_object" "source" {
  bucket = aws_s3_bucket.blobstore.bucket
  key    = "source/${var.image_tag}.zip"
  source = data.archive_file.source.output_path
  etag   = data.archive_file.source.output_md5

  tags = { Name = "${var.name_prefix}-source-${var.image_tag}", Component = "compute" }
}
